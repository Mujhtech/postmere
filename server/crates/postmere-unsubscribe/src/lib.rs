//! RFC 8058 one-click requests: cryptographically verified DKIM, exact consent URL,
//! pinned public DNS, isolated HTTPS, and no redirect/cookie/credential context.
use axum::{
    Json, Router,
    extract::{DefaultBodyLimit, Path, State},
    routing::get,
};
use postmere_core::public_network::{public_https_url, public_ip};
use postmere_core::{AppState, auth::AuthContext, error::AppError};
use postmere_mail::mail;
use postmere_providers::{self as provider, Message, Provider};
use reqwest::dns::{Addrs, Name, Resolve, Resolving};
use serde::{Deserialize, Serialize};
use std::{net::SocketAddr, sync::Arc, time::Duration};
use url::Url;
use uuid::Uuid;

mod verification;

pub fn router() -> Router<AppState> {
    Router::new().route(
        "/v1/mail/messages/{id}/unsubscribe",
        get(options)
            .post(request)
            .layer(DefaultBodyLimit::max(12000)),
    )
}
#[derive(Serialize)]
struct Options {
    one_click_url: Option<String>,
    reason: Option<&'static str>,
}
#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct Request {
    expected_url: String,
}
#[derive(Serialize)]
struct Outcome {
    accepted: bool,
    http_status: u16,
    host: String,
    message: String,
}
async fn provider_kind(
    state: &AppState,
    auth: &AuthContext,
    account: Uuid,
) -> Result<Provider, AppError> {
    let mut tx = auth.begin(&state.pool).await?;
    let kind: Option<String> = sqlx::query_scalar(
        "SELECT provider FROM provider_accounts WHERE id=$1 AND disabled_at IS NULL",
    )
    .bind(account)
    .fetch_optional(&mut *tx)
    .await?;
    Provider::parse(&kind.ok_or_else(AppError::not_found)?)
}
async fn options(
    auth: AuthContext,
    State(state): State<AppState>,
    Path(id): Path<Uuid>,
) -> Result<Json<Options>, AppError> {
    let message = mail::cached_message(&state, &auth, id).await?;
    let provider = provider_kind(&state, &auth, message.account_id).await?;
    let candidate = candidate_url(&message);
    let result = match candidate {
        Ok(_) => {
            state
                .auth
                .rate_limit("unsubscribe_verify", &auth.user_id.to_string(), 30)
                .await?;
            let account = mail::account_session(&state, &auth, message.account_id).await?;
            let raw = provider::fetch_raw_message(
                &state,
                provider,
                &account.credentials.access_token,
                &message.provider_message_id,
            )
            .await?;
            verification::verify(&raw).await
        }
        Err(reason) => Err(reason),
    };
    match result {
        Ok(url) => Ok(Json(Options {
            one_click_url: Some(url.into()),
            reason: None,
        })),
        Err(reason) => Ok(Json(Options {
            one_click_url: None,
            reason: Some(reason),
        })),
    }
}

async fn request(
    auth: AuthContext,
    State(state): State<AppState>,
    Path(id): Path<Uuid>,
    Json(input): Json<Request>,
) -> Result<Json<Outcome>, AppError> {
    if input.expected_url.len() > 8192 {
        return Err(AppError::bad_request("Unsubscribe address is too long."));
    }
    state
        .auth
        .rate_limit("unsubscribe_user", &auth.user_id.to_string(), 30)
        .await?;
    state
        .auth
        .rate_limit("unsubscribe_message", &format!("{}:{id}", auth.user_id), 4)
        .await?;
    let cached = mail::cached_message(&state, &auth, id).await?;
    let kind = provider_kind(&state, &auth, cached.account_id).await?;
    let cached_url = candidate_url(&cached).map_err(AppError::bad_request)?;
    if cached_url.as_str() != input.expected_url {
        return Err(AppError::conflict(
            "The unsubscribe address does not match this message. Refresh the message before trying again.",
        ));
    }
    let account = mail::account_session(&state, &auth, cached.account_id).await?;
    // Never accept headers or destinations supplied by the caller as proof.
    let fresh = provider::fetch_message(
        &state,
        kind,
        cached.account_id,
        &account.credentials.access_token,
        &cached.provider_message_id,
    )
    .await?;
    let fresh_url = candidate_url(&fresh).map_err(AppError::bad_request)?;
    if fresh_url.as_str() != input.expected_url {
        return Err(AppError::conflict(
            "The sender's unsubscribe address changed. Refresh the message before trying again.",
        ));
    }
    let raw = provider::fetch_raw_message(
        &state,
        kind,
        &account.credentials.access_token,
        &cached.provider_message_id,
    )
    .await?;
    let url = verification::verify(&raw)
        .await
        .map_err(AppError::bad_request)?;
    if url.as_str() != input.expected_url {
        return Err(AppError::conflict(
            "The sender's unsubscribe address changed. Refresh the message before trying again.",
        ));
    }
    let destination = Destination::resolve(url).await?;
    let client = isolated_builder(&destination)
        .build()
        .map_err(|_| AppError::internal("unsubscribe_client"))?;
    let status = send(&client, &destination.url).await?;
    let accepted = status.is_success();
    let message = if accepted {
        "The sender accepted your unsubscribe request. Their mailing list may take time to update."
            .into()
    } else if status.is_redirection() {
        "The sender redirected the request. Postmere did not follow it, and removal was not confirmed.".into()
    } else {
        format!(
            "The sender returned HTTP {}. Removal was not confirmed.",
            status.as_u16()
        )
    };
    Ok(Json(Outcome {
        accepted,
        http_status: status.as_u16(),
        host: destination.host,
        message,
    }))
}

fn candidate_url(message: &Message) -> Result<Url, &'static str> {
    if matches!(message.mailbox.as_str(), "sent" | "drafts" | "draft")
        || message
            .provider_labels
            .iter()
            .any(|v| v == "SENT" || v == "DRAFT")
    {
        return Err("One-click unsubscribe is unavailable for outgoing mail.");
    }
    let url = command_url(&message.list_unsubscribe, &message.list_unsubscribe_post)?;
    if !verification::has_candidate(&message.dkim_signatures) {
        return Err(
            "The message has no eligible signature covering both unsubscribe headers. Use the email or website option.",
        );
    }
    Ok(url)
}

fn command_url(list: &[String], post: &[String]) -> Result<Url, &'static str> {
    if list.len() != 1 || post.len() != 1 {
        return Err("The sender did not supply unambiguous one-click unsubscribe headers.");
    }
    let post = unfold(&post[0]).ok_or("The unsubscribe command is malformed.")?;
    if !post
        .trim()
        .eq_ignore_ascii_case("List-Unsubscribe=One-Click")
    {
        return Err("The sender does not support one-click unsubscribe.");
    }
    let raw = unfold(&list[0]).ok_or("The unsubscribe addresses are malformed.")?;
    let targets = list_targets(&raw).ok_or("The unsubscribe addresses are malformed.")?;
    let web: Vec<&str> = targets
        .iter()
        .filter_map(|v| {
            let scheme = v.split(':').next().unwrap_or("");
            if scheme.eq_ignore_ascii_case("https") || scheme.eq_ignore_ascii_case("http") {
                Some(v.as_str())
            } else {
                None
            }
        })
        .collect();
    if web.len() != 1 {
        return Err("The sender must supply exactly one HTTPS unsubscribe address.");
    }
    let url = public_https_url(web[0])
        .ok_or("The unsubscribe address is not a supported public HTTPS destination.")?;
    Ok(url)
}
fn unfold(value: &str) -> Option<String> {
    if value.len() > 32768 {
        return None;
    }
    let bytes = value.as_bytes();
    let mut out = Vec::with_capacity(bytes.len());
    let mut i = 0;
    while i < bytes.len() {
        if bytes[i] == b'\r'
            && bytes.get(i + 1) == Some(&b'\n')
            && bytes.get(i + 2).is_some_and(|v| matches!(v, b' ' | b'\t'))
        {
            out.push(b' ');
            i += 2;
            while bytes.get(i).is_some_and(|v| matches!(v, b' ' | b'\t')) {
                i += 1;
            }
        } else {
            if (bytes[i] < 32 && bytes[i] != b'\t') || bytes[i] == 127 {
                return None;
            }
            out.push(bytes[i]);
            i += 1;
        }
    }
    String::from_utf8(out).ok()
}
fn skip_comment(bytes: &[u8], i: &mut usize) -> Option<()> {
    let mut depth = 0;
    while *i < bytes.len() {
        let b = bytes[*i];
        *i += 1;
        match b {
            b'\\' => {
                if *i >= bytes.len() {
                    return None;
                }
                *i += 1;
            }
            b'(' => {
                depth += 1;
                if depth > 16 {
                    return None;
                }
            }
            b')' => {
                depth -= 1;
                if depth == 0 {
                    return Some(());
                }
            }
            _ => {}
        }
    }
    None
}
fn skip_cfws(bytes: &[u8], i: &mut usize) -> Option<()> {
    loop {
        match bytes.get(*i) {
            Some(b' ' | b'\t') => *i += 1,
            Some(b'(') => skip_comment(bytes, i)?,
            _ => return Some(()),
        }
    }
}
fn list_targets(value: &str) -> Option<Vec<String>> {
    let bytes = value.as_bytes();
    let mut i = 0;
    let mut result = Vec::new();
    skip_cfws(bytes, &mut i)?;
    while i < bytes.len() {
        if result.len() >= 20 || bytes[i] != b'<' {
            return None;
        }
        i += 1;
        let mut target = Vec::new();
        while i < bytes.len() && bytes[i] != b'>' {
            if bytes[i] == b'<' {
                return None;
            }
            if !bytes[i].is_ascii_whitespace() {
                target.push(bytes[i]);
            }
            i += 1;
        }
        if i == bytes.len() || target.is_empty() {
            return None;
        }
        result.push(String::from_utf8(target).ok()?);
        i += 1;
        skip_cfws(bytes, &mut i)?;
        if i == bytes.len() {
            break;
        }
        if bytes[i] != b',' {
            return None;
        }
        i += 1;
        skip_cfws(bytes, &mut i)?;
        if i == bytes.len() {
            return None;
        }
    }
    if result.is_empty() {
        None
    } else {
        Some(result)
    }
}
struct Destination {
    url: Url,
    host: String,
    addresses: Vec<SocketAddr>,
}
impl Destination {
    async fn resolve(url: Url) -> Result<Self, AppError> {
        let host = url
            .host_str()
            .ok_or_else(|| AppError::bad_request("Unsubscribe host is missing."))?
            .to_owned();
        let addresses = tokio::time::timeout(
            Duration::from_secs(3),
            tokio::net::lookup_host((host.as_str(), 443)),
        )
        .await
        .map_err(|_| AppError::unavailable())?
        .map_err(|_| AppError::unavailable())?
        .take(17)
        .collect();
        Self::checked(url, addresses)
    }
    fn checked(url: Url, addresses: Vec<SocketAddr>) -> Result<Self, AppError> {
        let checked = public_https_url(url.as_str())
            .ok_or_else(|| AppError::bad_request("Unsubscribe destination is not public HTTPS."))?;
        if addresses.is_empty()
            || addresses.len() > 16
            || addresses
                .iter()
                .any(|a| a.port() != 443 || !public_ip(a.ip()))
        {
            return Err(AppError::bad_request(
                "Unsubscribe destination must resolve only to public internet addresses. No request was sent.",
            ));
        }
        Ok(Self {
            host: checked.host_str().unwrap().to_owned(),
            url: checked,
            addresses,
        })
    }
}
struct PinnedResolver {
    host: String,
    addresses: Vec<SocketAddr>,
}
impl Resolve for PinnedResolver {
    fn resolve(&self, name: Name) -> Resolving {
        let matches = name.as_str() == self.host;
        let addresses = self.addresses.clone();
        Box::pin(async move {
            if !matches {
                return Err(std::io::Error::new(
                    std::io::ErrorKind::PermissionDenied,
                    "unapproved DNS name",
                )
                .into());
            }
            Ok(Box::new(addresses.into_iter()) as Addrs)
        })
    }
}
fn isolated_builder(destination: &Destination) -> reqwest::ClientBuilder {
    reqwest::Client::builder()
        .no_proxy()
        .redirect(reqwest::redirect::Policy::none())
        .https_only(true)
        .connect_timeout(Duration::from_secs(5))
        .timeout(Duration::from_secs(20))
        .pool_max_idle_per_host(0)
        .dns_resolver(Arc::new(PinnedResolver {
            host: destination.host.clone(),
            addresses: destination.addresses.clone(),
        }))
}
async fn send(client: &reqwest::Client, url: &Url) -> Result<reqwest::StatusCode, AppError> {
    let response=client.post(url.clone()).header("content-type","application/x-www-form-urlencoded").body("List-Unsubscribe=One-Click").send().await.map_err(|_|AppError::bad_request("The sender's response could not be confirmed. If the request was received, it may still be processed."))?;
    // Do not read or render the untrusted response body. Dropping it immediately
    // bounds response memory even when Content-Length is absent or dishonest.
    Ok(response.status())
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;
    use tokio::io::{AsyncReadExt, AsyncWriteExt};
    fn message() -> Message {
        serde_json::from_value(json!({"id":Uuid::new_v4(),"account_id":Uuid::new_v4(),"provider_message_id":"fixture","provider_thread_id":"fixture","subject":"Newsletter","from":{"name":null,"email":"news@example.com"},"to":[],"cc":[],"bcc":[],"text_body":"","html_body":null,"preview":"","sent_at":"2026-11-17T00:00:00Z","is_read":true,"is_starred":false,"mailbox":"inbox","provider_labels":["INBOX"],"attachments":[],"list_unsubscribe":["<https://lists.example.com/unsubscribe?opaque=fixture>"],"list_unsubscribe_post":["List-Unsubscribe=One-Click"],"authentication_results":["mx.google.com; dkim=pass header.i=@example.com header.s=mail header.b=abcdefgh"],"dkim_signatures":["v=1; a=rsa-sha256; d=example.com; s=mail; h=from:subject:list-unsubscribe:list-unsubscribe-post; b=abcdefgh0123456789; bh=fixture"]})).unwrap()
    }
    #[test]
    fn forged_authentication_results_never_authorize_one_click() {
        let base = message();
        assert!(candidate_url(&base).is_err());
        assert!(command_url(&base.list_unsubscribe, &base.list_unsubscribe_post).is_ok());
        let mut value = base.clone();
        value
            .list_unsubscribe
            .push(base.list_unsubscribe[0].clone());
        assert!(command_url(&value.list_unsubscribe, &value.list_unsubscribe_post).is_err());
        value = base.clone();
        value.list_unsubscribe[0] =
            "<https://lists.example.com/a>, <https://lists.example.com/b>".into();
        assert!(command_url(&value.list_unsubscribe, &value.list_unsubscribe_post).is_err());
        value = base;
        value.list_unsubscribe[0].push_str("\nInjected: bad");
        assert!(command_url(&value.list_unsubscribe, &value.list_unsubscribe_post).is_err());
    }
    #[test]
    fn url_and_dns_policy_rejects_private_mixed_and_encoded_destinations() {
        for raw in [
            "http://example.com/a",
            "https://127.0.0.1/",
            "https://2130706433/",
            "https://0x7f000001/",
            "https://[::1]/",
            "https://[::ffff:127.0.0.1]/",
            "https://localhost/",
            "https://router.local/",
            "https://private.internal/",
            "https://example.com:8080/",
            "https://user:pass@example.com/",
            "https://@example.com/",
            "https://example.com/#x",
            "https://example.com/%0d%0aInjected",
            "https://example.com\\@127.0.0.1/",
            "file:///etc/passwd",
            "https://example.com/bad%",
            "https://example.com./",
        ] {
            assert!(public_https_url(raw).is_none(), "accepted {raw}");
        }
        let url = public_https_url("https://lists.example.com/unsubscribe").unwrap();
        assert!(
            Destination::checked(url.clone(), vec!["93.184.216.34:443".parse().unwrap()]).is_ok()
        );
        assert!(
            Destination::checked(
                url.clone(),
                vec![
                    "93.184.216.34:443".parse().unwrap(),
                    "127.0.0.1:443".parse().unwrap()
                ]
            )
            .is_err()
        );
        assert!(Destination::checked(url.clone(), vec![]).is_err());
        assert!(Destination::checked(url, vec!["8.8.8.8:8080".parse().unwrap()]).is_err());
        for ip in [
            "127.0.0.1",
            "10.2.3.4",
            "172.16.0.1",
            "192.168.1.1",
            "169.254.169.254",
            "100.64.1.2",
            "198.19.1.2",
            "0.0.0.0",
            "224.0.0.1",
            "192.0.2.1",
            "198.51.100.2",
            "203.0.113.1",
            "::1",
            "::",
            "fe80::1",
            "fc00::1",
            "::ffff:127.0.0.1",
            "64:ff9b::7f00:1",
            "2001:db8::1",
            "2002:7f00:1::",
            "3fff::1",
            "2001:20::1",
        ] {
            assert!(!public_ip(ip.parse().unwrap()), "accepted {ip}");
        }
        for ip in [
            "93.184.216.34",
            "8.8.8.8",
            "2001:4860:4860::8888",
            "2606:4700:4700::1111",
        ] {
            assert!(public_ip(ip.parse().unwrap()));
        }
    }
    #[tokio::test]
    async fn resolver_never_requeries_dns_or_falls_back_to_other_names() {
        let addresses = vec!["93.184.216.34:443".parse().unwrap()];
        let resolver = PinnedResolver {
            host: "lists.example.com".into(),
            addresses: addresses.clone(),
        };
        for _ in 0..2 {
            let result = resolver
                .resolve("lists.example.com".parse().unwrap())
                .await
                .unwrap()
                .collect::<Vec<_>>();
            assert_eq!(result, addresses);
        }
        assert!(
            resolver
                .resolve("other.example.com".parse().unwrap())
                .await
                .is_err()
        );
    }
    #[tokio::test]
    async fn transport_sends_only_exact_form_and_does_not_follow_redirect_or_download_body() {
        let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
        let address = listener.local_addr().unwrap();
        // Bypass only destination validation inside this private transport
        // fixture. Production constructors reject HTTP and loopback addresses.
        let destination = Destination {
            url: "http://lists.example.com/unsubscribe?fixture=1"
                .parse()
                .unwrap(),
            host: "lists.example.com".into(),
            addresses: vec![address],
        };
        let server = tokio::spawn(async move {
            let (mut socket, _) = listener.accept().await.unwrap();
            let mut bytes = Vec::new();
            let mut buffer = [0u8; 2048];
            loop {
                let n = socket.read(&mut buffer).await.unwrap();
                assert!(n > 0);
                bytes.extend_from_slice(&buffer[..n]);
                if bytes.ends_with(b"List-Unsubscribe=One-Click") {
                    break;
                }
            }
            let request = String::from_utf8(bytes).unwrap();
            assert!(request.starts_with("POST /unsubscribe?fixture=1 HTTP/1.1\r\n"));
            let lower = request.to_lowercase();
            for forbidden in ["authorization:", "cookie:", "referer:", "origin:"] {
                assert!(!lower.contains(forbidden));
            }
            assert!(lower.contains("content-type: application/x-www-form-urlencoded"));
            assert_eq!(
                request.split("\r\n\r\n").nth(1),
                Some("List-Unsubscribe=One-Click")
            );
            socket.write_all(b"HTTP/1.1 302 Found\r\nLocation: http://other.example.com/should-not-follow\r\nContent-Length: 100000000\r\nSet-Cookie: ignored=1\r\n\r\n").await.unwrap();
            tokio::time::sleep(Duration::from_millis(100)).await;
        });
        let client = isolated_builder(&destination)
            .https_only(false)
            .build()
            .unwrap();
        let status = tokio::time::timeout(Duration::from_secs(2), send(&client, &destination.url))
            .await
            .unwrap()
            .unwrap();
        assert_eq!(status, reqwest::StatusCode::FOUND);
        server.await.unwrap();
    }
}
