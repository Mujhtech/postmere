use crate::error::AppError;
use base64::{Engine, engine::general_purpose::STANDARD};
use std::{collections::BTreeMap, env, net::SocketAddr};
use url::Url;
use zeroize::Zeroizing;

/// Intentionally no Debug: this struct contains deployment secrets.
#[derive(Clone)]
pub struct Config {
    pub database_url: String,
    pub bind_addr: SocketAddr,
    pub public_base_url: Url,
    /// Exact browser callback URLs approved by the deployment administrator.
    /// An empty list leaves remote MCP client registration disabled.
    pub mcp_redirect_uris: Vec<String>,
    pub max_body_bytes: usize,
    /// Bounded browser authorization lifetime; native sessions are persistent.
    pub session_hours: i64,
    pub session_absolute_days: i64,
    pub credential_keys: BTreeMap<u32, Zeroizing<Vec<u8>>>,
    pub active_credential_key: u32,
    pub rate_limit_key: Zeroizing<Vec<u8>>,
    pub google_client_id: Option<String>,
    pub google_client_secret: Option<String>,
    pub microsoft_client_id: Option<String>,
    pub microsoft_client_secret: Option<String>,
    pub microsoft_tenant: String,
    pub ai_api_key: Option<String>,
    pub ai_model: String,
}

impl Config {
    pub fn from_env() -> Result<Self, AppError> {
        let database_url = required("DATABASE_URL")?;
        validate_database_url(&database_url)?;
        let bind_addr = env::var("POSTMERE_BIND")
            .unwrap_or_else(|_| "127.0.0.1:8080".into())
            .parse()
            .map_err(|_| AppError::internal("invalid_bind_address"))?;
        let public_base_url = Url::parse(&required("POSTMERE_PUBLIC_URL")?)
            .map_err(|_| AppError::internal("invalid_public_url"))?;
        let local = matches!(
            public_base_url.host_str(),
            Some("localhost" | "127.0.0.1" | "[::1]")
        );
        if (public_base_url.scheme() != "https" && !(public_base_url.scheme() == "http" && local))
            || !public_base_url.username().is_empty()
            || public_base_url.password().is_some()
            || public_base_url.query().is_some()
            || public_base_url.fragment().is_some()
            || public_base_url.path() != "/"
        {
            return Err(AppError::internal("public_url_requires_https"));
        }
        let mcp_redirect_uris = parse_mcp_redirect_uris(
            optional("POSTMERE_MCP_REDIRECT_URIS")
                .as_deref()
                .unwrap_or("[]"),
        )?;
        let keys: BTreeMap<u32, String> =
            serde_json::from_str(&required("POSTMERE_CREDENTIAL_KEYS")?)
                .map_err(|_| AppError::internal("invalid_credential_keyring"))?;
        let mut credential_keys = BTreeMap::new();
        for (version, key) in keys {
            credential_keys.insert(version, decode_key(&key)?);
        }
        let active_credential_key = required("POSTMERE_ACTIVE_CREDENTIAL_KEY")?
            .parse()
            .map_err(|_| AppError::internal("invalid_active_key"))?;
        if !credential_keys.contains_key(&active_credential_key) {
            return Err(AppError::internal("missing_active_key"));
        }
        let rate_limit_key = decode_key(&required("POSTMERE_RATE_LIMIT_KEY")?)?;
        let google_client_id = optional("GOOGLE_CLIENT_ID");
        let google_client_secret = optional("GOOGLE_CLIENT_SECRET");
        let microsoft_client_id = optional("MICROSOFT_CLIENT_ID");
        let microsoft_client_secret = optional("MICROSOFT_CLIENT_SECRET");
        if google_client_id.is_some() != google_client_secret.is_some()
            || microsoft_client_id.is_some() != microsoft_client_secret.is_some()
        {
            return Err(AppError::internal("incomplete_provider_configuration"));
        }
        let microsoft_tenant = env::var("MICROSOFT_TENANT").unwrap_or_else(|_| "common".into());
        if microsoft_tenant.is_empty()
            || !microsoft_tenant
                .bytes()
                .all(|c| c.is_ascii_alphanumeric() || c == b'-' || c == b'.')
        {
            return Err(AppError::internal("invalid_microsoft_tenant"));
        }
        Ok(Self {
            database_url,
            bind_addr,
            public_base_url,
            mcp_redirect_uris,
            max_body_bytes: 30 * 1024 * 1024,
            session_hours: 24,
            session_absolute_days: 30,
            credential_keys,
            active_credential_key,
            rate_limit_key,
            google_client_id,
            google_client_secret,
            microsoft_client_id,
            microsoft_client_secret,
            microsoft_tenant,
            ai_api_key: optional("OPENAI_API_KEY"),
            ai_model: env::var("POSTMERE_AI_MODEL").unwrap_or_else(|_| "gpt-6-luna".into()),
        })
    }
}
fn parse_mcp_redirect_uris(value: &str) -> Result<Vec<String>, AppError> {
    let entries: Vec<String> = serde_json::from_str(value)
        .map_err(|_| AppError::internal("invalid_mcp_redirect_allowlist"))?;
    if entries.len() > 64 {
        return Err(AppError::internal("mcp_redirect_allowlist_too_large"));
    }
    for value in &entries {
        let url = Url::parse(value).map_err(|_| AppError::internal("invalid_mcp_redirect_uri"))?;
        let local = matches!(url.host_str(), Some("localhost" | "127.0.0.1" | "[::1]"));
        if value.len() > 2048
            || value.trim() != value
            || value.bytes().any(|b| b.is_ascii_control())
            || url.host_str().is_none()
            || !(url.scheme() == "https" || (url.scheme() == "http" && local))
            || !url.username().is_empty()
            || url.password().is_some()
            || url.fragment().is_some()
        {
            return Err(AppError::internal("invalid_mcp_redirect_uri"));
        }
    }
    Ok(entries)
}
fn required(name: &'static str) -> Result<String, AppError> {
    optional(name).ok_or_else(|| AppError::internal(name))
}
fn optional(name: &str) -> Option<String> {
    env::var(name).ok().filter(|value| !value.trim().is_empty())
}
fn decode_key(encoded: &str) -> Result<Zeroizing<Vec<u8>>, AppError> {
    let decoded = Zeroizing::new(
        STANDARD
            .decode(encoded)
            .map_err(|_| AppError::internal("invalid_secret_encoding"))?,
    );
    if decoded.len() != 32 {
        return Err(AppError::internal("secret_must_be_32_bytes"));
    }
    Ok(decoded)
}
fn validate_database_url(value: &str) -> Result<(), AppError> {
    let url = Url::parse(value).map_err(|_| AppError::internal("invalid_database_url"))?;
    if !matches!(url.scheme(), "postgres" | "postgresql") {
        return Err(AppError::internal("invalid_database_scheme"));
    }
    let loopback = matches!(url.host_str(), Some("localhost" | "127.0.0.1" | "[::1]"));
    let socket = url
        .query_pairs()
        .any(|(key, value)| key == "host" && value.starts_with('/'));
    let tls = url
        .query_pairs()
        .filter(|(key, _)| key == "sslmode")
        .map(|(_, value)| value.into_owned())
        .collect::<Vec<_>>();
    if !loopback && !socket && tls != ["verify-full"] {
        return Err(AppError::internal("remote_database_requires_verified_tls"));
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn mcp_redirects_require_explicit_secure_callbacks() {
        assert!(parse_mcp_redirect_uris("[]").unwrap().is_empty());
        assert!(
            parse_mcp_redirect_uris(
                r#"["https://client.example/callback?tenant=one","http://127.0.0.1:8910/callback"]"#
            )
            .is_ok()
        );
        for value in [
            r#"["http://client.example/callback"]"#,
            r#"["https://user:password@client.example/callback"]"#,
            r#"["https://client.example/callback#fragment"]"#,
            r#"["https://cli\nent.example/callback"]"#,
            r#"["javascript:alert(1)"]"#,
            r#"{"url":"https://client.example"}"#,
        ] {
            assert!(parse_mcp_redirect_uris(value).is_err());
        }
    }
    #[test]
    fn remote_database_requires_verified_tls() {
        for value in [
            "postgres://user:fixture@db.example.com/postmere?sslmode=verify-full",
            "postgres://user:fixture@127.0.0.1:55439/postmere",
            "postgres://user:fixture@[::1]/postmere",
            "postgresql:///postmere?host=/var/run/postgresql",
        ] {
            assert!(validate_database_url(value).is_ok());
        }
        for value in [
            "postgres://user:fixture@db.example.com/postmere",
            "postgres://user:fixture@db.example.com/postmere?sslmode=disable",
            "postgres://user:fixture@db.example.com/postmere?sslmode=require",
            "postgres://user:fixture@db.example.com/postmere?sslmode=verify-full&sslmode=disable",
            "http://db.example.com/postmere",
        ] {
            assert!(validate_database_url(value).is_err());
        }
    }
}
