//! Verify the particular message before displaying a certified sender logo.
//! Gmail's API exposes raw headers, including headers from imported messages,
//! but no authenticated BIMI verdict. Attribute this verification to Postmere.
use crate::{
    bimi_cert::{certified_logo, has_assertion},
    mail::account_session,
};
use axum::{
    Json,
    extract::{Path, State},
};
use base64::{Engine, engine::general_purpose::STANDARD};
use chrono::{DateTime, Utc};
use mail_auth::{
    AuthenticatedMessage, DkimResult, MessageAuthenticator,
    common::crypto::Algorithm,
    dkim::Signature,
    hickory_resolver::{
        net::{DnsError, NetError},
        proto::{op::ResponseCode, rr::RData},
    },
};
use postmere_core::{
    AppState, auth::AuthContext, error::AppError, public_network::public_hostname,
};
use postmere_providers::{Provider, fetch_raw_message};
use serde::Serialize;
use sqlx::Row;
use std::{collections::HashMap, sync::OnceLock, time::Duration};
use uuid::Uuid;

const MAX_HEADER_BYTES: usize = 128 * 1024;
const MAX_RAW_BYTES: usize = 8 * 1024 * 1024;
const MAX_SIGNATURES: usize = 8;

#[derive(Serialize)]
pub(crate) struct SenderMarkResponse {
    verified_sender_mark: Option<VerifiedSenderMark>,
}

#[derive(Serialize)]
struct VerifiedSenderMark {
    domain: String,
    provider: &'static str,
    verified_by: &'static str,
    logo_svg: String,
    expires_at: DateTime<Utc>,
}

pub(crate) async fn get(
    State(state): State<AppState>,
    auth: AuthContext,
    Path(id): Path<Uuid>,
) -> Result<Json<SenderMarkResponse>, AppError> {
    // Use only the cached envelope for eligibility, even for very large messages.
    let mut tx = auth.begin_authorized(&state.pool).await?;
    let row = sqlx::query(
        "SELECT m.account_id, m.provider_message_id, a.provider,
                m.normalized->'from'->>'email' AS sender,
                CASE WHEN jsonb_typeof(m.normalized->'dkim_signatures') = 'array'
                     AND pg_column_size(m.normalized->'dkim_signatures') <= 65536
                     THEN m.normalized->'dkim_signatures' END AS signatures,
                lower(m.normalized->>'mailbox') IN ('drafts','sent','outbox')
                  OR coalesce(m.normalized->'provider_labels' ?| ARRAY['DRAFT','SENT'], false)
                  AS outgoing
         FROM mail_messages m JOIN provider_accounts a ON a.id=m.account_id
         WHERE m.id=$1 AND m.deleted_at IS NULL AND a.disabled_at IS NULL",
    )
    .bind(id)
    .fetch_optional(&mut *tx)
    .await?
    .ok_or_else(AppError::not_found)?;
    tx.commit().await?;
    let sender: String = row.try_get("sender")?;
    let absent = || {
        Json(SenderMarkResponse {
            verified_sender_mark: None,
        })
    };
    if row.try_get::<&str, _>("provider")? != "gmail" || row.try_get::<bool, _>("outgoing")? {
        return Ok(absent());
    }
    let Some(domain) = sender_domain(&sender) else {
        return Ok(absent());
    };
    let signatures = row.try_get::<Option<sqlx::types::Json<Vec<String>>>, _>("signatures")?;
    let candidate = cached_candidate(signatures.as_deref().map(Vec::as_slice), &domain);
    if matches!(candidate, Candidate::Ineligible) {
        return Ok(absent());
    }
    state
        .auth
        .rate_limit("sender_mark", &auth.user_id.to_string(), 240)
        .await?;
    let account_id: Uuid = row.try_get("account_id")?;
    let provider_id: String = row.try_get("provider_message_id")?;
    let mark = tokio::time::timeout(Duration::from_secs(22), async {
        let resolver = resolver()?;
        // For most messages the cached signature header already tells us only
        // the default selector could be signed. Rule out missing BIMI records
        // through DNS before downloading a potentially large raw message.
        if matches!(candidate, Candidate::Default) && !has_assertion(&domain, "default").await? {
            return Ok(None);
        }
        if !enforcing_dmarc(resolver, &domain).await? {
            return Ok(None);
        }
        let account = account_session(&state, &auth, account_id).await?;
        let raw = fetch_raw_message(
            &state,
            Provider::Gmail,
            &account.credentials.access_token,
            &provider_id,
        )
        .await?;
        let Some((message, selector)) = prepare(&raw, &sender, &domain) else {
            return Ok(None);
        };
        let results = resolver.verify_dkim(&message).await;
        let Some(sig) = results
            .iter()
            .find(|r| r.result() == &DkimResult::Pass)
            .and_then(|r| r.signature())
        else {
            if results
                .iter()
                .any(|r| matches!(r.result(), DkimResult::TempError(_)))
            {
                return Err(AppError::unavailable());
            }
            return Ok(None);
        };
        let now = Utc::now();
        let mut expires_at = now + chrono::Duration::hours(24);
        if sig.x != 0 {
            let Some(expiry) = i64::try_from(sig.x)
                .ok()
                .and_then(|s| DateTime::from_timestamp(s, 0))
            else {
                return Ok(None);
            };
            expires_at = expires_at.min(expiry);
        }
        let Some(logo) = certified_logo(&domain, &selector).await? else {
            return Ok(None);
        };
        expires_at = expires_at.min(logo.expires_at);
        if expires_at <= Utc::now() {
            return Ok(None);
        }
        Ok(Some(VerifiedSenderMark {
            domain,
            provider: "gmail",
            verified_by: "postmere",
            logo_svg: STANDARD.encode(logo.logo_svg),
            expires_at,
        }))
    })
    .await
    .map_err(|_| AppError::unavailable())??;
    Ok(Json(SenderMarkResponse {
        verified_sender_mark: mark,
    }))
}

enum Candidate {
    Ineligible,
    Default,
    InspectRaw,
}

fn cached_candidate(headers: Option<&[String]>, domain: &str) -> Candidate {
    // Older cached messages can lack signature metadata. They can still earn
    // a mark through the same raw-message verification as newly synced mail.
    let Some(headers) = headers.filter(|headers| !headers.is_empty()) else {
        return Candidate::InspectRaw;
    };
    if headers.len() > MAX_SIGNATURES {
        return Candidate::Ineligible;
    }
    let mut candidate = Candidate::Ineligible;
    for value in headers {
        let Ok(signature) = Signature::parse(value.as_bytes()) else {
            return Candidate::InspectRaw;
        };
        if eligible(&signature, domain, false, false) {
            if signature
                .h
                .iter()
                .any(|h| h.eq_ignore_ascii_case("bimi-selector"))
            {
                return Candidate::InspectRaw;
            }
            candidate = Candidate::Default;
        }
    }
    candidate
}

pub(super) fn resolver() -> Result<&'static MessageAuthenticator, AppError> {
    static RESOLVER: OnceLock<Option<MessageAuthenticator>> = OnceLock::new();
    RESOLVER
        .get_or_init(|| MessageAuthenticator::new_cloudflare_tls().ok())
        .as_ref()
        .ok_or_else(AppError::unavailable)
}

fn dns_label(label: &str) -> bool {
    (1..=63).contains(&label.len())
        && !label.starts_with('-')
        && !label.ends_with('-')
        && label
            .bytes()
            .all(|b| b.is_ascii_alphanumeric() || b == b'-')
}

fn sender_domain(address: &str) -> Option<String> {
    let (local, domain) = address.split_once('@')?;
    let domain = domain.to_ascii_lowercase();
    if local.is_empty()
        || address.len() > 254
        || !public_hostname(&domain)
        || !psl::suffix(domain.as_bytes()).is_some_and(|s| s.is_known())
        || psl::domain_str(&domain).is_none()
    {
        return None;
    }
    Some(domain)
}

fn eligible(signature: &Signature, domain: &str, custom_selector: bool, has_subject: bool) -> bool {
    let covers = |key: &str| signature.h.iter().any(|h| h.eq_ignore_ascii_case(key));
    signature.v == 1
        && signature.d.eq_ignore_ascii_case(domain)
        && matches!(signature.a, Algorithm::Ed25519Sha256 | Algorithm::RsaSha256)
        && signature.bh.len() == 32
        && (64..=1024).contains(&signature.b.len())
        && signature.l == 0
        && !signature.r
        && signature.atps.is_none()
        && signature.s.len() + domain.len() + 13 <= 253
        && signature.s.split('.').all(|label| {
            (1..=63).contains(&label.len())
                && label
                    .bytes()
                    .all(|b| b.is_ascii_alphanumeric() || b == b'_' || b == b'-')
        })
        && signature.h.len() <= 128
        && covers("from")
        && (!has_subject || covers("subject"))
        && (!custom_selector || covers("bimi-selector"))
}

fn prepare<'a>(
    raw: &'a [u8],
    sender: &str,
    domain: &str,
) -> Option<(AuthenticatedMessage<'a>, String)> {
    if raw.len() > MAX_RAW_BYTES {
        return None;
    }
    let prefix = &raw[..raw.len().min(MAX_HEADER_BYTES + 4)];
    let end = prefix.windows(4).position(|w| w == b"\r\n\r\n")?;
    let headers = std::str::from_utf8(&prefix[..end]).ok()?;
    let mut signatures = 0;
    for (index, line) in headers.split("\r\n").enumerate() {
        if index >= 1024 || line.contains(['\0', '\r', '\n']) {
            return None;
        }
        if line.starts_with([' ', '\t']) {
            continue;
        }
        let (name, _) = line.split_once(':')?;
        if name.is_empty() || !name.bytes().all(|b| b.is_ascii_graphic() && b != b':') {
            return None;
        }
        if ["dkim-signature", "dkim2-signature", "arc-message-signature"]
            .iter()
            .any(|h| name.eq_ignore_ascii_case(h))
        {
            signatures += 1;
        }
    }
    if !(1..=MAX_SIGNATURES).contains(&signatures) {
        return None;
    }
    let mut message = AuthenticatedMessage::parse(raw)?;
    let count = |name: &[u8]| {
        message
            .headers
            .iter()
            .filter(|(k, _)| k.eq_ignore_ascii_case(name))
            .count()
    };
    if count(b"from") != 1
        || message.from.len() != 1
        || !message.from[0].eq_ignore_ascii_case(sender)
        || count(b"subject") > 1
        || count(b"bimi-selector") > 1
    {
        return None;
    }
    let has_subject = count(b"subject") > 0;
    let selector = message
        .headers
        .iter()
        .find(|(name, _)| name.eq_ignore_ascii_case(b"bimi-selector"))
        .map(|(_, value)| std::str::from_utf8(value).ok().and_then(parse_selector))
        .unwrap_or_else(|| Some("default".to_string()))?;
    message
        .dkim_headers
        .retain(|h| eligible(&h.header, domain, selector != "default", has_subject));
    if message.dkim_headers.is_empty() {
        return None;
    }
    Some((message, selector))
}

fn parse_selector(value: &str) -> Option<String> {
    let mut parts = value.trim().trim_end_matches(';').split(';').map(str::trim);
    if parts.next()? != "v=BIMI1" {
        return None;
    }
    let selector = parts.next()?.strip_prefix("s=")?.trim();
    if parts.next().is_some() || !dns_label(selector) {
        return None;
    }
    Some(selector.to_ascii_lowercase())
}

#[derive(Clone, Copy)]
struct DmarcPolicy {
    domain: bool,
    subdomains: bool,
}

fn parse_policy(record: &str) -> Option<DmarcPolicy> {
    let mut tags = HashMap::new();
    let mut fields = record
        .trim()
        .trim_end_matches(';')
        .split(';')
        .map(str::trim);
    if !fields.next()?.eq_ignore_ascii_case("v=DMARC1") {
        return None;
    }
    for field in fields {
        let (key, value) = field.split_once('=')?;
        if tags
            .insert(
                key.trim().to_ascii_lowercase(),
                value.trim().to_ascii_lowercase(),
            )
            .is_some()
        {
            return None;
        }
    }
    let enforcement = |policy: &str| match policy {
        "reject" | "quarantine" => Some(true),
        "none" => Some(false),
        _ => None,
    };
    let domain = enforcement(tags.get("p")?)?;
    if let Some(np) = tags.get("np") {
        enforcement(np)?;
    }
    let subdomains = match tags.get("sp") {
        Some(sp) => enforcement(sp)?,
        None => domain,
    };
    let full = tags.get("pct").is_none_or(|pct| pct == "100")
        && tags.get("t").is_none_or(|testing| testing == "n");
    Some(DmarcPolicy {
        domain: domain && full,
        subdomains: subdomains && full,
    })
}

async fn policy(
    resolver: &MessageAuthenticator,
    domain: &str,
) -> Result<Option<DmarcPolicy>, AppError> {
    let lookup = match resolver
        .resolver()
        .txt_lookup(format!("_dmarc.{domain}."))
        .await
    {
        Ok(records) => records,
        Err(NetError::Dns(DnsError::NoRecordsFound(r)))
            if matches!(
                r.response_code,
                ResponseCode::NXDomain | ResponseCode::NoError
            ) =>
        {
            return Ok(None);
        }
        Err(_) => return Err(AppError::unavailable()),
    };
    let mut policy = None;
    for answer in lookup.answers() {
        let RData::TXT(txt) = &answer.data else {
            continue;
        };
        let value: Vec<u8> = txt
            .txt_data
            .iter()
            .flat_map(|p| p.iter().copied())
            .collect();
        let Ok(value) = std::str::from_utf8(&value) else {
            continue;
        };
        if !value
            .split(';')
            .next()
            .is_some_and(|v| v.trim().eq_ignore_ascii_case("v=DMARC1"))
        {
            continue;
        }
        // A malformed or ambiguous policy must not fall back to an ancestor.
        let unenforced = DmarcPolicy {
            domain: false,
            subdomains: false,
        };
        if policy.is_some() {
            return Ok(Some(unenforced));
        }
        policy = Some(parse_policy(value).unwrap_or(unenforced));
    }
    Ok(policy)
}

async fn enforcing_dmarc(resolver: &MessageAuthenticator, domain: &str) -> Result<bool, AppError> {
    let Some(org) = psl::domain_str(domain) else {
        return Ok(false);
    };
    let Some(parent) = policy(resolver, org).await? else {
        return Ok(false);
    };
    if !parent.domain {
        return Ok(false);
    }
    if domain == org {
        return Ok(true);
    }
    if let Some(exact) = policy(resolver, domain).await? {
        return Ok(exact.domain);
    }
    // A delegated organizational domain may publish its own subdomain policy.
    // Require enforcement at each discovered boundary within this bounded walk.
    if !parent.subdomains || domain.split('.').count() > 8 {
        return Ok(false);
    }
    let mut current = domain;
    while let Some((_, ancestor)) = current.split_once('.') {
        if ancestor == org {
            break;
        }
        if policy(resolver, ancestor)
            .await?
            .is_some_and(|p| !p.subdomains || !p.domain)
        {
            return Ok(false);
        }
        current = ancestor;
    }
    Ok(true)
}

#[cfg(test)]
mod tests {
    use super::*;
    use mail_auth::{
        Parameters, ResolverCache, Txt,
        common::{
            crypto::Ed25519Key, headers::HeaderWriter, parse::TxtRecordParser, verify::DomainKey,
        },
        dkim::DkimSigner,
    };
    use std::{borrow::Borrow, hash::Hash, sync::Arc, time::Instant};

    // RFC 8032's public test vector. Verification uses its in-memory DNS record.
    const PUBLIC: &str = "11qYAYKxCrfVS/7TyWQHOg7hcvPapiMlrwIaaPcHURo=";
    const EMAIL: &str = "letters@mail.example.com";
    const DOMAIN: &str = "mail.example.com";
    struct TestKey(Txt);
    impl ResolverCache<Box<str>, Txt> for TestKey {
        fn get<Q>(&self, _: &Q) -> Option<Txt>
        where
            Box<str>: Borrow<Q>,
            Q: Hash + Eq + ?Sized,
        {
            Some(self.0.clone())
        }
        fn remove<Q>(&self, _: &Q) -> Option<Txt>
        where
            Box<str>: Borrow<Q>,
            Q: Hash + Eq + ?Sized,
        {
            None
        }
        fn insert(&self, _: Box<str>, _: Txt, _: Instant) {
            panic!("unexpected DNS access");
        }
    }
    fn signed(domain: &str, extra: &str, sign_selector: bool) -> String {
        let body = format!(
            "From: Editorial <{EMAIL}>\r\nSubject: March edition\r\n{extra}\r\nNewsletter.\r\n"
        );
        let key = Ed25519Key::from_seed_and_public_key(
            &STANDARD
                .decode("nWGxne/9WmC6hEr0kuwsxERJxWl7MmkZcDusAxyuf2A=")
                .unwrap(),
            &STANDARD.decode(PUBLIC).unwrap(),
        )
        .unwrap();
        let mut headers = vec!["From", "Subject"];
        if sign_selector {
            headers.push("BIMI-Selector");
        }
        let signature = DkimSigner::from_key(key)
            .domain(domain)
            .selector("mail")
            .headers(headers)
            .sign(body.as_bytes())
            .unwrap();
        format!("{}{body}", signature.to_header())
    }
    async fn checked(raw: &str) -> Option<String> {
        let (message, selector) = prepare(raw.as_bytes(), EMAIL, DOMAIN)?;
        let record =
            DomainKey::parse(format!("v=DKIM1; k=ed25519; p={PUBLIC}").as_bytes()).unwrap();
        let keys = TestKey(Txt::DomainKey(Arc::new(record)));
        let auth = resolver().unwrap();
        auth.verify_dkim(Parameters::new(&message).with_txt_cache(&keys))
            .await
            .iter()
            .any(|r| r.result() == &DkimResult::Pass)
            .then_some(selector)
    }

    #[tokio::test]
    async fn message_specific_proof_requires_covered_sender_and_intact_content() {
        let raw = signed(DOMAIN, "", false);
        assert_eq!(checked(&raw).await.as_deref(), Some("default"));
        assert!(
            checked(&raw.replace("Newsletter.", "Other text."))
                .await
                .is_none()
        );
        assert!(
            checked(&raw.replace("March edition", "December edition"))
                .await
                .is_none()
        );
        assert!(checked(&format!("From: {EMAIL}\r\n{raw}")).await.is_none());
        assert!(prepare(raw.as_bytes(), "someone@mail.example.com", DOMAIN).is_none());
        assert!(
            checked(&signed("other.example.com", "", false))
                .await
                .is_none()
        );
        let headers_only = format!(
            "From: {EMAIL}\r\nAuthentication-Results: mx.google.com; bimi=pass\r\nBIMI-Indicator: logo\r\n\r\nNewsletter.\r\n"
        );
        assert!(checked(&headers_only).await.is_none());
    }

    #[tokio::test]
    async fn nondefault_bimi_selector_requires_an_aligned_signature_covering_it() {
        let selector = "BIMI-Selector: v=BIMI1; s=editorial\r\n";
        assert_eq!(
            checked(&signed(DOMAIN, selector, true)).await.as_deref(),
            Some("editorial")
        );
        assert!(checked(&signed(DOMAIN, selector, false)).await.is_none());
        assert!(
            checked(&signed(DOMAIN, &selector.repeat(2), true))
                .await
                .is_none()
        );
        assert!(
            checked(&signed(
                DOMAIN,
                "BIMI-Selector: v=BIMI1; s=localhost/mark\r\n",
                true
            ))
            .await
            .is_none()
        );
    }

    #[test]
    fn cached_signatures_only_short_circuit_definite_misses() {
        let signature = |domain, include_selector| {
            let raw = signed(domain, "", include_selector);
            let raw = raw.split_once("From: Editorial").unwrap().0;
            vec![raw.split_once(':').unwrap().1.to_string()]
        };
        assert!(matches!(
            cached_candidate(None, DOMAIN),
            Candidate::InspectRaw
        ));
        assert!(matches!(
            cached_candidate(Some(&[]), DOMAIN),
            Candidate::InspectRaw
        ));
        assert!(matches!(
            cached_candidate(Some(&signature(DOMAIN, false)), DOMAIN),
            Candidate::Default
        ));
        assert!(matches!(
            cached_candidate(Some(&signature(DOMAIN, true)), DOMAIN),
            Candidate::InspectRaw
        ));
        assert!(matches!(
            cached_candidate(Some(&signature("different.example.com", false)), DOMAIN),
            Candidate::Ineligible
        ));
    }

    #[test]
    fn rejects_ambiguous_or_partial_enforcement_and_nonpublic_names() {
        for record in [
            "v=DMARC1; p=none",
            "v=DMARC1; p=reject; pct=50",
            "v=DMARC1; p=quarantine; t=y",
        ] {
            assert!(!parse_policy(record).unwrap().domain);
        }
        assert!(parse_policy("v=DMARC1; p=reject; p=none").is_none());
        assert!(parse_policy("v=DMARC1; p=unknown").is_none());
        let policy = parse_policy("v=DMARC1; p=reject; sp=none; pct=100;").unwrap();
        assert!(policy.domain && !policy.subdomains);
        for sender in [
            "help@127.0.0.1",
            "help@com",
            "one@more@example.com",
            "help@intranet.local",
        ] {
            assert!(sender_domain(sender).is_none());
        }
        assert_eq!(
            sender_domain("one@EU.Example.COM").as_deref(),
            Some("eu.example.com")
        );
    }
}
