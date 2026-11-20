//! Guardrails for requests to public hosts derived from mail or DNS.
use std::net::IpAddr;
use url::{Host, Url};

pub fn public_hostname(host: &str) -> bool {
    if host.len() > 253 || host.starts_with('.') || host.ends_with('.') || host.contains("..") {
        return false;
    }
    let labels: Vec<_> = host.split('.').collect();
    let Some(last) = labels.last() else {
        return false;
    };
    if labels.len() < 2
        || [
            "localhost",
            "local",
            "localdomain",
            "lan",
            "internal",
            "intranet",
            "home",
            "corp",
            "test",
            "invalid",
            "example",
            "onion",
            "arpa",
        ]
        .contains(last)
        || !last.bytes().any(|b| b.is_ascii_alphabetic())
    {
        return false;
    }
    labels.iter().all(|label| {
        !label.is_empty()
            && label.len() <= 63
            && !label.starts_with('-')
            && !label.ends_with('-')
            && label
                .bytes()
                .all(|b| b.is_ascii_alphanumeric() || b == b'-')
    })
}
pub fn public_https_url(raw: &str) -> Option<Url> {
    if raw.len() > 8192 || raw.bytes().any(|b| b <= 32 || b == 127 || b == b'\\') {
        return None;
    }
    let lower = raw.to_ascii_lowercase();
    if ["%00", "%0a", "%0d", "%5c", "%7f"]
        .iter()
        .any(|v| lower.contains(v))
    {
        return None;
    }
    for (i, b) in raw.bytes().enumerate() {
        if b == b'%'
            && (!raw.as_bytes().get(i + 1).is_some_and(u8::is_ascii_hexdigit)
                || !raw.as_bytes().get(i + 2).is_some_and(u8::is_ascii_hexdigit))
        {
            return None;
        }
    }
    let url = Url::parse(raw).ok()?;
    if url.scheme() != "https"
        || !url.username().is_empty()
        || url.password().is_some()
        || url.fragment().is_some()
        || url.port().is_some_and(|p| p != 443)
    {
        return None;
    }
    if raw.split("://").nth(1)?.split('/').next()?.contains('@') {
        return None;
    }
    match url.host()? {
        Host::Domain(host) if public_hostname(host) => Some(url),
        _ => None,
    }
}
pub fn public_ip(ip: IpAddr) -> bool {
    match ip {
        IpAddr::V4(ip) => {
            let [a, b, c, _] = ip.octets();
            !(a == 0
                || a == 10
                || a == 127
                || a >= 224
                || (a == 100 && (64..=127).contains(&b))
                || (a == 169 && b == 254)
                || (a == 172 && (16..=31).contains(&b))
                || (a == 192 && b == 168)
                || (a == 192 && b == 0 && (c == 0 || c == 2))
                || (a == 192 && b == 88 && c == 99)
                || (a == 198 && (b == 18 || b == 19))
                || (a == 198 && b == 51 && c == 100)
                || (a == 203 && b == 0 && c == 113))
        }
        IpAddr::V6(ip) => {
            let b = ip.octets();
            b[0] & 0xe0 == 0x20
                && !(b[0] == 0x20 && b[1] == 0x02)
                && !(b[0] == 0x20
                    && b[1] == 0x01
                    && ((b[2] & 0xfe == 0) || (b[2] == 0x0d && b[3] == 0xb8)))
                && !(b[0] == 0x3f && b[1] == 0xff && b[2] & 0xf0 == 0)
        }
    }
}
