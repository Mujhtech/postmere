//! BIMI evidence documents. Only the subject logo inside an authenticated VMC
//! may be returned. A sender's website, a DNS logo URL and ordinary TLS roots
//! are not sources of authority for a verified mark.
use crate::sender_mark::resolver;
use chrono::{DateTime, Utc};
use mail_auth::hickory_resolver::{
    net::{DnsError, NetError},
    proto::{op::ResponseCode, rr::RData},
};
use postmere_core::{
    error::AppError,
    public_network::{public_hostname, public_https_url, public_ip},
};
use rustls_pki_types::{CertificateDer, UnixTime, pem::PemObject};
use std::{
    collections::{HashMap, HashSet},
    net::SocketAddr,
    sync::{Arc, LazyLock, Mutex},
    time::Duration,
};
use url::Url;
use webpki::{
    BorrowedCertRevocationList, CertRevocationList, EndEntityCert, ExpirationPolicy, KeyUsage,
    RevocationOptionsBuilder,
};
use x509_cert::{
    Certificate,
    crl::CertificateList,
    der::{Decode, Encode, asn1::ObjectIdentifier},
    ext::pkix::{
        CertificatePolicies, CrlDistributionPoints, ExtendedKeyUsage, SubjectAltName,
        name::{DistributionPointName, GeneralName},
    },
};

#[path = "bimi/logo.rs"]
mod logo;
#[path = "bimi/transparency.rs"]
mod transparency;

const BIMI_PURPOSE: ObjectIdentifier = ObjectIdentifier::new_unwrap("1.3.6.1.5.5.7.3.31");
const VMC_POLICY: ObjectIdentifier = ObjectIdentifier::new_unwrap("1.3.6.1.4.1.53087.1.1");
const MARK_TYPE: ObjectIdentifier = ObjectIdentifier::new_unwrap("1.3.6.1.4.1.53087.1.13");
// Root certificates only, from https://bimigroup.org/vmc-issuers/ (DigiCert,
// GlobalSign and SSL.com). Never trust a root supplied by the sender.
const MARK_ROOTS: &[u8] = include_bytes!("bimi/mark-roots.pem");

#[derive(Clone)]
pub(crate) struct CertifiedLogo {
    pub(crate) logo_svg: Vec<u8>,
    pub(crate) expires_at: DateTime<Utc>,
}

async fn assertion(domain: &str, selector: &str) -> Result<Assertion, AppError> {
    let Some(org) = psl::domain_str(domain) else {
        return Ok(Assertion::Ineligible);
    };
    if !public_hostname(domain)
        || selector.is_empty()
        || selector.len() > 63
        || !selector
            .bytes()
            .all(|b| b.is_ascii_alphanumeric() || b == b'-')
        || format!("{selector}._bimi.{domain}").len() > 253
    {
        return Ok(Assertion::Ineligible);
    }
    let exact = lookup(selector, domain).await?;
    if matches!(exact, Assertion::Missing) && org != domain {
        lookup(selector, org).await
    } else {
        Ok(exact)
    }
}

pub(super) async fn has_assertion(domain: &str, selector: &str) -> Result<bool, AppError> {
    Ok(matches!(
        assertion(domain, selector).await?,
        Assertion::Evidence(..)
    ))
}

type CachedEvidence = Arc<tokio::sync::Mutex<Option<CertifiedLogo>>>;
static EVIDENCE: LazyLock<Mutex<HashMap<(String, String, Url), CachedEvidence>>> =
    LazyLock::new(Mutex::default);

pub(crate) async fn certified_logo(
    domain: &str,
    selector: &str,
) -> Result<Option<CertifiedLogo>, AppError> {
    let Some(org) = psl::domain_str(domain) else {
        return Ok(None);
    };
    let published = assertion(domain, selector).await?;
    let Assertion::Evidence(url, ttl) = published else {
        return Ok(None);
    };
    // Bound memory and coalesce concurrent opens for the same published mark.
    // Looking up DNS first also observes an opt-out or changed evidence URL.
    let key = (domain.to_owned(), selector.to_owned(), url.clone());
    let cell = {
        let mut cache = EVIDENCE.lock().unwrap_or_else(|e| e.into_inner());
        if cache.len() >= 128 && !cache.contains_key(&key) {
            if let Some(victim) = cache.keys().next().cloned() {
                cache.remove(&victim);
            }
        }
        Arc::clone(cache.entry(key).or_default())
    };
    let mut cached = cell.lock().await;
    let deadline = Utc::now() + chrono::Duration::seconds(i64::from(ttl.min(3600)));
    if let Some(logo) = cached.as_ref().filter(|v| v.expires_at > Utc::now()) {
        return Ok(Some(CertifiedLogo {
            logo_svg: logo.logo_svg.clone(),
            expires_at: logo.expires_at.min(deadline),
        }));
    }
    let Some(pem) = download(&url, 96 * 1024).await? else {
        return Ok(None);
    };
    let Some(path) = evidence_chain(&pem) else {
        return Ok(None);
    };
    let Some((svg, mut expires_at)) = validate_mark(&path, domain, org, selector, Utc::now())
    else {
        return Ok(None);
    };
    expires_at = expires_at.min(deadline);
    // Consult only CRL addresses from the CA-signed path after verifying it.
    let mut lists = Vec::new();
    for cert in &path {
        let Some(urls) = crl_urls(cert) else {
            return Ok(None);
        };
        let mut found = None;
        for url in urls.into_iter().take(2) {
            if let Ok(Some(bytes)) = download(&url, 2 * 1024 * 1024).await {
                if let Some(expiration) = crl_valid_until(&bytes, Utc::now()) {
                    found = Some((bytes, expiration));
                    break;
                }
            }
        }
        let Some((bytes, expiration)) = found else {
            return Err(AppError::unavailable());
        };
        lists.push(bytes);
        expires_at = expires_at.min(expiration);
    }
    if !verified_path(&path, &lists, Utc::now()) || expires_at <= Utc::now() {
        return Ok(None);
    }
    let verified = CertifiedLogo {
        logo_svg: svg,
        expires_at,
    };
    *cached = Some(verified.clone());
    Ok(Some(verified))
}

enum Assertion {
    Missing,
    Ineligible,
    Evidence(Url, u32),
}

async fn lookup(selector: &str, domain: &str) -> Result<Assertion, AppError> {
    let lookup = match resolver()?
        .resolver()
        .txt_lookup(format!("{selector}._bimi.{domain}."))
        .await
    {
        Ok(records) => records,
        Err(NetError::Dns(DnsError::NoRecordsFound(r)))
            if matches!(
                r.response_code,
                ResponseCode::NXDomain | ResponseCode::NoError
            ) =>
        {
            return Ok(Assertion::Missing);
        }
        Err(_) => return Err(AppError::unavailable()),
    };
    let remaining_ttl = u32::try_from(
        lookup
            .valid_until()
            .saturating_duration_since(std::time::Instant::now())
            .as_secs(),
    )
    .unwrap_or(u32::MAX);
    let mut assertion = Assertion::Missing;
    for answer in lookup.answers() {
        let RData::TXT(txt) = &answer.data else {
            continue;
        };
        let data = txt.txt_data.concat();
        let Ok(line) = std::str::from_utf8(&data) else {
            continue;
        };
        let mut fields = line.split(';').map(str::trim);
        if fields.next() != Some("v=BIMI1") {
            continue;
        }
        if !matches!(assertion, Assertion::Missing) {
            return Ok(Assertion::Ineligible);
        }
        let mut seen = HashSet::from(["v"]);
        let mut evidence = None;
        for field in fields.filter(|f| !f.is_empty()) {
            let Some((tag, value)) = field.split_once('=') else {
                return Ok(Assertion::Ineligible);
            };
            if !seen.insert(tag.trim()) {
                return Ok(Assertion::Ineligible);
            }
            if tag.trim() == "a" {
                evidence = public_https_url(value.trim());
            }
        }
        assertion = evidence.map_or(Assertion::Ineligible, |url| {
            Assertion::Evidence(url, remaining_ttl.min(answer.ttl))
        });
    }
    Ok(assertion)
}

async fn download(url: &Url, limit: usize) -> Result<Option<Vec<u8>>, AppError> {
    let Some(host) = url.host_str() else {
        return Ok(None);
    };
    let Some(port) = url.port_or_known_default() else {
        return Ok(None);
    };
    let timeout = Duration::from_secs(5);
    let lookup = tokio::time::timeout(timeout, tokio::net::lookup_host((host, port)))
        .await
        .map_err(|_| AppError::unavailable())?
        .map_err(|_| AppError::unavailable())?;
    let addresses: Vec<SocketAddr> = lookup.take(17).collect();
    if addresses.is_empty() || addresses.len() > 16 || !addresses.iter().all(|a| public_ip(a.ip()))
    {
        return Ok(None);
    }
    let client = reqwest::Client::builder()
        .https_only(url.scheme() == "https")
        .no_proxy()
        .redirect(reqwest::redirect::Policy::none())
        .resolve_to_addrs(host, &addresses)
        .timeout(timeout)
        .build()
        .map_err(|_| AppError::unavailable())?;
    let mut response = client
        .get(url.clone())
        .send()
        .await
        .map_err(|_| AppError::unavailable())?;
    if response.status().is_server_error() {
        return Err(AppError::unavailable());
    }
    if !response.status().is_success()
        || response.content_length().is_some_and(|n| n > limit as u64)
    {
        return Ok(None);
    }
    let mut data = Vec::new();
    while let Some(chunk) = response
        .chunk()
        .await
        .map_err(|_| AppError::unavailable())?
    {
        if data.len() + chunk.len() > limit {
            return Ok(None);
        }
        data.extend_from_slice(&chunk);
    }
    Ok(Some(data))
}

fn evidence_chain(bytes: &[u8]) -> Option<Vec<Certificate>> {
    let chain = CertificateDer::pem_slice_iter(bytes)
        .take(7)
        .map(|v| Certificate::from_der(v.ok()?.as_ref()).ok())
        .collect::<Option<Vec<_>>>()?;
    if chain.is_empty()
        || chain.len() > 6
        || !chain
            .windows(2)
            .all(|pair| pair[0].tbs_certificate.issuer == pair[1].tbs_certificate.subject)
    {
        return None;
    }
    let mut chain = chain;
    if chain
        .last()
        .is_some_and(|c| c.tbs_certificate.issuer == c.tbs_certificate.subject)
    {
        let supplied = chain.pop()?.to_der().ok()?;
        if !CertificateDer::pem_slice_iter(MARK_ROOTS)
            .flatten()
            .any(|root| root.as_ref() == supplied)
        {
            return None;
        }
    }
    (!chain.is_empty()).then_some(chain)
}

fn verified_path(chain: &[Certificate], lists: &[Vec<u8>], now: DateTime<Utc>) -> bool {
    let Ok(seconds) = u64::try_from(now.timestamp()) else {
        return false;
    };
    let Some(ders): Option<Vec<CertificateDer>> = chain
        .iter()
        .map(|c| c.to_der().ok().map(CertificateDer::from))
        .collect()
    else {
        return false;
    };
    let roots: Vec<_> = CertificateDer::pem_slice_iter(MARK_ROOTS)
        .flatten()
        .collect();
    let anchors: Vec<_> = roots
        .iter()
        .filter_map(|r| webpki::anchor_from_trusted_cert(r).ok())
        .collect();
    let Some((first, rest)) = ders.split_first() else {
        return false;
    };
    let Ok(leaf) = EndEntityCert::try_from(first) else {
        return false;
    };
    let Some(crls): Option<Vec<_>> = lists
        .iter()
        .map(|b| {
            BorrowedCertRevocationList::from_der(b)
                .ok()
                .map(CertRevocationList::from)
        })
        .collect()
    else {
        return false;
    };
    let refs: Vec<_> = crls.iter().collect();
    let options = RevocationOptionsBuilder::new(&refs)
        .ok()
        .map(|b| b.with_expiration_policy(ExpirationPolicy::Enforce).build());
    // The leaf EKU is explicitly required below. CAs without a restricting EKU
    // may sign VMCs, but a CA with a different restrictive EKU may not.
    leaf.verify_for_usage(
        webpki::ALL_VERIFICATION_ALGS,
        &anchors,
        rest,
        UnixTime::since_unix_epoch(Duration::from_secs(seconds)),
        KeyUsage::required_if_present(BIMI_PURPOSE.as_bytes()),
        options,
        None,
    )
    .is_ok_and(|path| path.intermediate_certificates().count() == rest.len())
}

fn validate_mark(
    chain: &[Certificate],
    domain: &str,
    org: &str,
    selector: &str,
    now: DateTime<Utc>,
) -> Option<(Vec<u8>, DateTime<Utc>)> {
    if !verified_path(chain, &[], now) {
        return None;
    }
    let leaf = &chain.first()?.tbs_certificate;
    if !leaf
        .get::<ExtendedKeyUsage>()
        .ok()??
        .1
        .0
        .contains(&BIMI_PURPOSE)
        || !leaf
            .get::<CertificatePolicies>()
            .ok()??
            .1
            .0
            .iter()
            .any(|p| p.policy_identifier == VMC_POLICY)
    {
        return None;
    }
    let mut types = leaf
        .subject
        .0
        .iter()
        .flat_map(|r| r.0.iter())
        .filter(|a| a.oid == MARK_TYPE);
    if !matches!(
        types.next()?.value.value(),
        b"Registered Mark" | b"Government Mark"
    ) || types.next().is_some()
    {
        return None;
    }
    let author_selector = format!("{selector}._bimi.{domain}");
    let org_selector = format!("{selector}._bimi.{org}");
    let names = leaf.get::<SubjectAltName>().ok()??.1;
    let accepted = [domain, org, author_selector.as_str(), org_selector.as_str()];
    let aligned = names.0.iter().any(|name| {
        let GeneralName::DnsName(san) = name else {
            return false;
        };
        accepted
            .iter()
            .any(|value| san.as_str().eq_ignore_ascii_case(value))
    });
    if !aligned {
        return None;
    }
    let issuer = chain.get(1).cloned().or_else(|| {
        CertificateDer::pem_slice_iter(MARK_ROOTS)
            .flatten()
            .filter_map(|r| Certificate::from_der(r.as_ref()).ok())
            .find(|r| r.tbs_certificate.subject == leaf.issuer)
    })?;
    if !transparency::verified(leaf, &issuer, now) {
        return None;
    }
    let expires_at = chain
        .iter()
        .map(|c| DateTime::<Utc>::from(c.tbs_certificate.validity.not_after.to_system_time()))
        .min()?;
    Some((logo::subject_svg(leaf)?, expires_at))
}

fn crl_urls(cert: &Certificate) -> Option<Vec<Url>> {
    let dps = cert.tbs_certificate.get::<CrlDistributionPoints>().ok()??.1;
    let mut urls = Vec::new();
    for point in dps.0 {
        let Some(DistributionPointName::FullName(names)) = point.distribution_point else {
            continue;
        };
        for name in names {
            if let GeneralName::UniformResourceIdentifier(uri) = name {
                let raw = uri.as_str();
                // CRLs are issuer-signed. Some CA distribution points support
                // HTTP only. Their scheme and port come from the verified path.
                if let Some(rest) = raw.strip_prefix("http://") {
                    if let Some(mut url) = public_https_url(&format!("https://{rest}")) {
                        if !rest.split('/').next().unwrap_or_default().contains(':')
                            && url.set_scheme("http").is_ok()
                        {
                            urls.push(url);
                        }
                    }
                } else if let Some(url) = public_https_url(raw) {
                    urls.push(url);
                }
            }
        }
    }
    (!urls.is_empty()).then_some(urls)
}

fn crl_valid_until(der: &[u8], now: DateTime<Utc>) -> Option<DateTime<Utc>> {
    let crl = CertificateList::from_der(der).ok()?.tbs_cert_list;
    let next = DateTime::<Utc>::from(crl.next_update?.to_system_time());
    (DateTime::<Utc>::from(crl.this_update.to_system_time()) <= now && next > now).then_some(next)
}

#[cfg(test)]
mod tests {
    use super::*;
    #[tokio::test]
    #[ignore = "live sender domain and CA endpoints"]
    async fn current_published_mark() {
        let logo = certified_logo("eu.temuemail.com", "default")
            .await
            .expect("public verification endpoints");
        assert!(logo.is_some(), "current published Temu evidence");
    }

    // Public evidence captured 2026-11-20; keep the verification clock fixed.
    #[test]
    fn registered_mark_requires_valid_certified_logo_and_revocation_status() {
        let now = DateTime::parse_from_rfc3339("2026-11-20T06:00:00Z")
            .unwrap()
            .to_utc();
        let path = evidence_chain(include_bytes!("../tests/fixtures/bimi/temu.pem")).unwrap();
        let crls = vec![
            include_bytes!("../tests/fixtures/bimi/mark-issuer.crl").to_vec(),
            include_bytes!("../tests/fixtures/bimi/mark-root.crl").to_vec(),
        ];
        assert!(
            crls.iter()
                .all(|bytes| crl_valid_until(bytes, now).is_some())
        );
        assert!(verified_path(&path, &crls, now));
        assert!(!verified_path(&path, &crls[1..], now));
        assert!(!verified_path(
            &path,
            &crls,
            now + chrono::Duration::days(15)
        ));
        let (svg, _) =
            validate_mark(&path, "eu.temuemail.com", "temuemail.com", "default", now).unwrap();
        assert_eq!(svg.len(), 3574);
        assert!(validate_mark(&path, "other.example", "other.example", "default", now).is_none());
        let mut changed = path.clone();
        changed[0].tbs_certificate.serial_number =
            x509_cert::serial_number::SerialNumber::from(1u8);
        assert!(!transparency::verified(
            &changed[0].tbs_certificate,
            &changed[1],
            now
        ));
        assert!(!verified_path(&changed, &crls, now));
    }
}
