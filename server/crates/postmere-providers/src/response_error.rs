//! Keep endpoint and reason diagnostics within a fixed vocabulary. Provider
//! error text may contain addresses, IDs or excerpts, even for read requests.
use super::ProviderError;
use chrono::{DateTime, Utc};
use reqwest::{Response, StatusCode, header::RETRY_AFTER};
use serde_json::Value;
use zeroize::Zeroizing;

const MAX_ERROR_BODY: usize = 8 * 1024;
pub(crate) async fn classify(mut response: Response) -> ProviderError {
    let status = response.status();
    if status == StatusCode::NOT_FOUND {
        return ProviderError::NotFound;
    }
    if status.is_server_error() {
        return ProviderError::Unavailable;
    }
    if !matches!(status.as_u16(), 401 | 403 | 429) {
        return ProviderError::Rejected;
    }
    let endpoint = safe_endpoint(response.url());
    let retry_after = response
        .headers()
        .get(RETRY_AFTER)
        .and_then(|h| h.to_str().ok())
        .and_then(|h| parse_retry(h, Utc::now()));
    let mut bytes = Zeroizing::new(Vec::new());
    if !response
        .content_length()
        .is_some_and(|n| n > MAX_ERROR_BODY as u64)
    {
        while let Ok(Some(chunk)) = response.chunk().await {
            if bytes.len() + chunk.len() > MAX_ERROR_BODY {
                bytes.clear();
                break;
            }
            bytes.extend_from_slice(&chunk);
        }
    }
    let value = serde_json::from_slice::<Value>(&bytes).ok();
    let reason = value
        .as_ref()
        .and_then(known_reason)
        .unwrap_or("unspecified");
    let error = classified(status, reason, retry_after);
    tracing::warn!(
        event = "mail_provider_read",
        endpoint,
        status = status.as_u16(),
        reason,
        retry_after_seconds = retry_after,
        "provider request deferred"
    );
    error
}

fn safe_endpoint(url: &url::Url) -> &'static str {
    match (url.host_str(), url.path()) {
        (Some("gmail.googleapis.com"), "/gmail/v1/users/me/history") => "gmail_history",
        (Some("gmail.googleapis.com"), "/gmail/v1/users/me/messages") => "gmail_message_list",
        (Some("gmail.googleapis.com"), p) if p.starts_with("/gmail/v1/users/me/messages/") => {
            "gmail_message"
        }
        (Some("gmail.googleapis.com"), "/gmail/v1/users/me/profile") => "gmail_profile",
        (Some("gmail.googleapis.com"), _) => "gmail_other",
        (Some("graph.microsoft.com"), _) => "microsoft_graph",
        (Some("oauth2.googleapis.com" | "login.microsoftonline.com"), _) => "oauth",
        _ => "other",
    }
}

fn known_reason(value: &Value) -> Option<&'static str> {
    // Google may include both legacy errors[].reason and a modern status.
    // Graph exposes a code on the error object.
    let error = value.get("error")?;
    let reasons = error
        .get("errors")
        .and_then(Value::as_array)
        .into_iter()
        .flatten()
        .take(8)
        .filter_map(|item| item.get("reason").and_then(Value::as_str))
        .chain(
            error
                .get("details")
                .and_then(Value::as_array)
                .into_iter()
                .flatten()
                .take(8)
                .filter_map(|item| item.get("reason").and_then(Value::as_str)),
        )
        .chain(error.get("code").and_then(Value::as_str))
        .chain(error.get("status").and_then(Value::as_str));
    const ALLOWED: &[&str] = &[
        "authError",
        "invalidCredentials",
        "InvalidAuthenticationToken",
        "userRateLimitExceeded",
        "rateLimitExceeded",
        "dailyLimitExceeded",
        "quotaExceeded",
        "RESOURCE_EXHAUSTED",
        "TooManyRequests",
        "ErrorTooManyRequests",
        "ErrorQuotaExceeded",
        "ErrorServerBusy",
        "insufficientPermissions",
        "ACCESS_TOKEN_SCOPE_INSUFFICIENT",
        "domainPolicy",
        "accessNotConfigured",
        "SERVICE_DISABLED",
        "forbidden",
        "ErrorAccessDenied",
        "Authorization_RequestDenied",
        "PERMISSION_DENIED",
    ];
    for reason in reasons {
        if let Some(value) = ALLOWED.iter().copied().find(|value| *value == reason) {
            return Some(value);
        }
    }
    None
}

fn classified(status: StatusCode, reason: &str, retry_after: Option<u32>) -> ProviderError {
    if status == StatusCode::UNAUTHORIZED {
        return ProviderError::Unauthorized;
    }
    if status == StatusCode::TOO_MANY_REQUESTS
        || matches!(
            reason,
            "userRateLimitExceeded"
                | "rateLimitExceeded"
                | "dailyLimitExceeded"
                | "quotaExceeded"
                | "RESOURCE_EXHAUSTED"
                | "TooManyRequests"
                | "ErrorTooManyRequests"
                | "ErrorQuotaExceeded"
                | "ErrorServerBusy"
        )
    {
        return ProviderError::RateLimited { retry_after };
    }
    match reason {
        "authError" | "invalidCredentials" | "InvalidAuthenticationToken" => {
            ProviderError::Unauthorized
        }
        "insufficientPermissions" | "ACCESS_TOKEN_SCOPE_INSUFFICIENT" => {
            ProviderError::MissingScope
        }
        "domainPolicy" | "accessNotConfigured" | "SERVICE_DISABLED" => {
            ProviderError::ProviderPolicy
        }
        _ => ProviderError::Forbidden,
    }
}

fn parse_retry(value: &str, now: DateTime<Utc>) -> Option<u32> {
    let seconds = value.trim().parse::<u64>().ok().or_else(|| {
        let target = DateTime::parse_from_rfc2822(value)
            .ok()?
            .with_timezone(&Utc);
        Some((target - now).num_seconds().max(0) as u64)
    })?;
    Some(seconds.clamp(1, 86400) as u32)
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;
    #[test]
    fn distinguishes_throttling_from_permissions_without_echoing_unknown_reasons() {
        for (reason, expected) in [
            (
                "userRateLimitExceeded",
                ProviderError::RateLimited {
                    retry_after: Some(120),
                },
            ),
            ("insufficientPermissions", ProviderError::MissingScope),
            ("domainPolicy", ProviderError::ProviderPolicy),
            ("private context", ProviderError::Forbidden),
        ] {
            let status = StatusCode::FORBIDDEN;
            let value = json!({"error":{"errors":[{"reason":reason}],"message":"ignored"}});
            assert_eq!(
                classified(
                    status,
                    known_reason(&value).unwrap_or("unspecified"),
                    Some(120)
                ),
                expected
            );
        }
        assert_eq!(
            classified(StatusCode::TOO_MANY_REQUESTS, "unspecified", None),
            ProviderError::RateLimited { retry_after: None }
        );
        assert_eq!(
            classified(StatusCode::UNAUTHORIZED, "unspecified", None),
            ProviderError::Unauthorized
        );
        assert_eq!(parse_retry("120", Utc::now()), Some(120));
        assert_eq!(parse_retry("later", Utc::now()), None);
    }
}
