//! Raw-message DKIM authentication. Authentication-Results is deliberately unused:
//! provider APIs can contain imported mail with attacker-authored receiver headers.
use super::command_url;
use mail_auth::{
    AuthenticatedMessage, DkimResult, MessageAuthenticator, common::crypto::Algorithm,
    dkim::Signature,
};
use postmere_core::public_network::public_hostname;
use std::time::Duration;
use url::Url;

const MAX_RAW: usize = 8 * 1024 * 1024;
const MAX_HEADERS: usize = 64 * 1024;
const MAX_SIGNATURES: usize = 8;
const UNVERIFIED: &str = "The message's signature could not cryptographically verify both unsubscribe headers. Use the email or website option.";

pub(super) fn has_candidate(headers: &[String]) -> bool {
    !headers.is_empty()
        && headers.len() <= MAX_SIGNATURES
        && headers.iter().any(|header| {
            header.len() <= 8192
                && Signature::parse(header.as_bytes()).is_ok_and(|signature| eligible(&signature))
        })
}

fn eligible(signature: &Signature) -> bool {
    signature.v == 1
        && matches!(signature.a, Algorithm::RsaSha256 | Algorithm::Ed25519Sha256)
        && signature.bh.len() == 32
        && (64..=1024).contains(&signature.b.len())
        && signature.l == 0
        && !signature.r
        && signature.atps.is_none()
        && public_hostname(&signature.d)
        && !signature.s.is_empty()
        && signature.s.len() + signature.d.len() + 13 <= 253
        && signature.s.split('.').all(|part| {
            !part.is_empty()
                && part.len() <= 63
                && part
                    .bytes()
                    .all(|b| b.is_ascii_alphanumeric() || b == b'_' || b == b'-')
        })
        && signature.h.len() <= 128
        && ["from", "list-unsubscribe", "list-unsubscribe-post"]
            .iter()
            .all(|required| {
                signature
                    .h
                    .iter()
                    .any(|name| name.eq_ignore_ascii_case(required))
            })
}

fn prepare(raw: &[u8]) -> Result<(AuthenticatedMessage<'_>, Url), &'static str> {
    if raw.len() > MAX_RAW {
        return Err(UNVERIFIED);
    }
    let boundary = raw
        .windows(4)
        .position(|part| part == b"\r\n\r\n")
        .ok_or(UNVERIFIED)?;
    if boundary > MAX_HEADERS {
        return Err(UNVERIFIED);
    }
    // Bound signature parsing/body hashing before giving any bytes to the verifier.
    for (index, byte) in raw[..boundary].iter().enumerate() {
        if (*byte == b'\n' && (index == 0 || raw[index - 1] != b'\r'))
            || (*byte == b'\r' && raw.get(index + 1) != Some(&b'\n'))
            || *byte == 0
        {
            return Err(UNVERIFIED);
        }
    }
    let headers = std::str::from_utf8(&raw[..boundary]).map_err(|_| UNVERIFIED)?;
    let mut count = 0;
    let mut signatures = 0;
    for line in headers.split("\r\n") {
        if line.starts_with([' ', '\t']) {
            continue;
        }
        count += 1;
        let (name, _) = line.split_once(':').ok_or(UNVERIFIED)?;
        if name.is_empty() || !name.bytes().all(|b| b.is_ascii_graphic() && b != b':') {
            return Err(UNVERIFIED);
        }
        if ["dkim-signature", "dkim2-signature", "arc-message-signature"]
            .iter()
            .any(|auth_name| name.eq_ignore_ascii_case(auth_name))
        {
            signatures += 1;
        }
    }
    if count > 256 || signatures == 0 || signatures > MAX_SIGNATURES {
        return Err(UNVERIFIED);
    }
    let mut message = AuthenticatedMessage::parse(raw).ok_or(UNVERIFIED)?;
    let values = |name: &[u8]| -> Result<Vec<String>, &'static str> {
        message
            .headers
            .iter()
            .filter(|(key, _)| key.eq_ignore_ascii_case(name))
            .map(|(_, value)| {
                std::str::from_utf8(value)
                    .map(|v| v.trim_end_matches(['\r', '\n']).to_owned())
                    .map_err(|_| UNVERIFIED)
            })
            .collect()
    };
    if values(b"from")?.len() != 1 {
        return Err(UNVERIFIED);
    }
    let url = command_url(
        &values(b"list-unsubscribe")?,
        &values(b"list-unsubscribe-post")?,
    )?;
    // Only relevant SHA-256 signatures reach DNS. r=y and ATPS signatures are
    // excluded so verification performs at most eight DKIM TXT key lookups.
    message
        .dkim_headers
        .retain(|header| eligible(&header.header));
    if message.dkim_headers.is_empty() {
        return Err(UNVERIFIED);
    }
    Ok((message, url))
}

pub(super) async fn verify(raw: &[u8]) -> Result<Url, &'static str> {
    let (message, url) = prepare(raw)?;
    // Fixed public recursive resolvers over authenticated TLS. No nameserver or
    // URL supplied by the message is ever used as a transport destination.
    let verifier = MessageAuthenticator::new_cloudflare_tls().map_err(|_| UNVERIFIED)?;
    let results = tokio::time::timeout(Duration::from_secs(8), verifier.verify_dkim(&message))
        .await
        .map_err(|_| UNVERIFIED)?;
    if results.iter().any(|result| {
        result.result() == &DkimResult::Pass && result.signature().is_some_and(eligible)
    }) {
        Ok(url)
    } else {
        Err(UNVERIFIED)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use base64::{Engine, engine::general_purpose::STANDARD};
    use mail_auth::{
        Parameters, ResolverCache, Txt,
        common::{
            crypto::Ed25519Key, headers::HeaderWriter, parse::TxtRecordParser, verify::DomainKey,
        },
        dkim::DkimSigner,
    };
    use std::{borrow::Borrow, collections::HashMap, hash::Hash, time::Instant};

    // Published RFC 8032 Ed25519 test vector; never used for live signing.
    const SEED: &str = "nWGxne/9WmC6hEr0kuwsxERJxWl7MmkZcDusAxyuf2A=";
    const PUBLIC: &str = "11qYAYKxCrfVS/7TyWQHOg7hcvPapiMlrwIaaPcHURo=";
    const BODY: &str = "From: news@example.com\r\nTo: me@example.org\r\nSubject: Signed fixture\r\nList-Unsubscribe: <https://lists.example.com/remove?token=fixture>\r\nList-Unsubscribe-Post: List-Unsubscribe=One-Click\r\n\r\nFixture newsletter.\r\n";
    const URL: &str = "https://lists.example.com/remove?token=fixture";
    struct OfflineKeys(HashMap<Box<str>, Txt>);
    impl ResolverCache<Box<str>, Txt> for OfflineKeys {
        fn get<Q>(&self, name: &Q) -> Option<Txt>
        where
            Box<str>: Borrow<Q>,
            Q: Hash + Eq + ?Sized,
        {
            // Always return a record, even for a miss: fixtures never query DNS.
            Some(self.0.get(name).cloned().unwrap_or_else(|| {
                Txt::Error(mail_auth::Error::Io(
                    "Offline fixture key unavailable".into(),
                ))
            }))
        }
        fn remove<Q>(&self, _: &Q) -> Option<Txt>
        where
            Box<str>: Borrow<Q>,
            Q: Hash + Eq + ?Sized,
        {
            None
        }
        fn insert(&self, _: Box<str>, _: Txt, _: Instant) {
            panic!("offline verifier unexpectedly queried DNS");
        }
    }
    fn signed(cover_list: bool) -> String {
        let key = Ed25519Key::from_seed_and_public_key(
            &STANDARD.decode(SEED).unwrap(),
            &STANDARD.decode(PUBLIC).unwrap(),
        )
        .unwrap();
        let headers = if cover_list {
            vec![
                "From",
                "To",
                "Subject",
                "List-Unsubscribe",
                "List-Unsubscribe-Post",
            ]
        } else {
            vec!["From", "To", "Subject"]
        };
        let signature = DkimSigner::from_key(key)
            .domain("example.com")
            .selector("fixture")
            .headers(headers)
            .sign(BODY.as_bytes())
            .unwrap();
        format!("{}{}", signature.to_header(), BODY)
    }
    async fn check(raw: &str, with_key: bool) -> bool {
        let Ok((message, url)) = prepare(raw.as_bytes()) else {
            return false;
        };
        assert_eq!(url.as_str(), URL);
        let mut records = HashMap::new();
        if with_key {
            records.insert(
                "fixture._domainkey.example.com.".into(),
                Txt::DomainKey(std::sync::Arc::new(
                    DomainKey::parse(format!("v=DKIM1; k=ed25519; p={PUBLIC}").as_bytes()).unwrap(),
                )),
            );
        }
        let keys = OfflineKeys(records);
        let verifier = MessageAuthenticator::new_cloudflare_tls().unwrap();
        verifier
            .verify_dkim(Parameters::new(&message).with_txt_cache(&keys))
            .await
            .iter()
            .any(|result| {
                result.result() == &DkimResult::Pass && result.signature().is_some_and(eligible)
            })
    }
    #[tokio::test]
    async fn valid_signed_message_passes_without_trusting_receiver_headers() {
        let raw = signed(true);
        assert!(check(&raw, true).await);
        assert!(
            check(
                &format!("Authentication-Results: attacker.invalid; dkim=fail\r\n{raw}"),
                true
            )
            .await
        );
        assert!(
            !check(&raw, false).await,
            "An unavailable public key must fail closed"
        );
    }
    #[tokio::test]
    async fn tampering_body_or_signed_headers_and_duplicate_fields_fail() {
        let raw = signed(true);
        assert!(
            !check(
                &raw.replace("Fixture newsletter.", "Altered newsletter."),
                true
            )
            .await
        );
        assert!(
            !check(
                &raw.replace(
                    "List-Unsubscribe=One-Click",
                    "List-Unsubscribe=Something-Else"
                ),
                true
            )
            .await
        );
        assert!(prepare(raw.replace("token=fixture", "token=attacker").as_bytes()).is_ok());
        let altered = raw.replace("token=fixture", "token=attacker");
        let (message, _) = prepare(altered.as_bytes()).unwrap();
        let key = DomainKey::parse(format!("v=DKIM1; k=ed25519; p={PUBLIC}").as_bytes()).unwrap();
        let keys = OfflineKeys(HashMap::from([(
            "fixture._domainkey.example.com.".into(),
            Txt::DomainKey(std::sync::Arc::new(key)),
        )]));
        let verifier = MessageAuthenticator::new_cloudflare_tls().unwrap();
        assert!(
            !verifier
                .verify_dkim(Parameters::new(&message).with_txt_cache(&keys))
                .await
                .iter()
                .any(|r| r.result() == &DkimResult::Pass)
        );
        assert!(
            !check(
                &format!(
                    "List-Unsubscribe: <https://lists.example.com/remove?token=fixture>\r\n{raw}"
                ),
                true
            )
            .await
        );
        assert!(
            !check(
                &format!("List-Unsubscribe-Post: List-Unsubscribe=One-Click\r\n{raw}"),
                true
            )
            .await
        );
        assert!(!check(&format!("From: attacker@example.com\r\n{raw}"), true).await);
    }
    #[tokio::test]
    async fn forged_receiver_pass_or_borrowed_signature_cannot_add_list_coverage() {
        let raw = signed(false);
        assert!(!check(&format!("Authentication-Results: mx.google.com; dkim=pass header.d=example.com header.s=fixture\r\n{raw}"), true).await);
        let signature = raw.split_once("From: news@example.com").unwrap().0;
        let forged = signature.replace("h=", "h=List-Unsubscribe:List-Unsubscribe-Post:");
        assert!(!check(&format!("{forged}{raw}"), true).await);
    }
    #[test]
    fn parsing_is_bounded_before_body_hashing_or_dns() {
        let raw = signed(true);
        let signature = raw.split_once("From: news@example.com").unwrap().0;
        assert!(prepare(format!("{}{}", signature.repeat(9), BODY).as_bytes()).is_err());
        assert!(
            prepare(format!("X-Large: {}\r\n{raw}", "a".repeat(MAX_HEADERS)).as_bytes()).is_err()
        );
        assert!(prepare(format!("{raw}{}", "a".repeat(MAX_RAW)).as_bytes()).is_err());
        assert!(prepare(raw.replace("\r\n", "\n").as_bytes()).is_err());
        assert!(
            prepare(format!("X-Bad: one\nDKIM-Signature: forged\r\n{raw}").as_bytes()).is_err()
        );
        assert!(prepare(raw.replace("a=ed25519-sha256", "a=rsa-sha1").as_bytes()).is_err());
    }
}
