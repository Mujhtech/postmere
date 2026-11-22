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
    /// None when the deployment has no AI configured.
    pub ai: Option<AiProvider>,
    pub ai_model: String,
    pub decision_adapter: Option<DecisionAdapter>,
}

#[derive(Clone)]
pub struct DecisionAdapter {
    pub url: Url,
    pub token: Zeroizing<String>,
}

/// Where AI requests go: any endpoint that speaks the OpenAI Responses API.
/// That covers OpenAI, Azure OpenAI and self-hosted servers such as vLLM or
/// Ollama, so a deployment can keep mail on infrastructure it controls.
#[derive(Clone)]
pub struct AiProvider {
    /// The Responses endpoint, for example https://api.openai.com/v1/responses.
    pub url: Url,
    /// Self-hosted servers on a private network may need no key.
    pub key: Option<Zeroizing<String>>,
    pub auth: AiAuth,
    /// Named in the data notice users read before turning AI on.
    pub name: String,
    /// Sender research relies on the provider's hosted web search tool.
    pub web_search: bool,
    /// The operator states this provider keeps no request data, for example
    /// under an OpenAI zero data retention agreement or a self-hosted model.
    pub zero_retention: bool,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum AiAuth {
    /// `Authorization: Bearer <key>` (OpenAI and most compatible servers).
    Bearer,
    /// `api-key: <key>` (Azure OpenAI keys).
    ApiKey,
}

const OPENAI_BASE: &str = "https://api.openai.com/v1";

impl AiProvider {
    /// OpenAI's hosted API with an API key.
    pub fn openai(key: impl Into<String>) -> Self {
        Self {
            url: Url::parse(&format!("{OPENAI_BASE}/responses")).expect("static URL"),
            key: Some(Zeroizing::new(key.into())),
            auth: AiAuth::Bearer,
            name: "OpenAI".into(),
            web_search: true,
            zero_retention: false,
        }
    }
}

/// Plain HTTP is allowed only where traffic cannot leave a private network:
/// loopback, private and link-local addresses, and single-label or .internal
/// and .local names such as a Compose service.
fn private_host(url: &Url) -> bool {
    match url.host() {
        Some(url::Host::Ipv4(ip)) => ip.is_loopback() || ip.is_private() || ip.is_link_local(),
        Some(url::Host::Ipv6(ip)) => ip.is_loopback() || (ip.segments()[0] & 0xfe00) == 0xfc00,
        Some(url::Host::Domain(name)) => {
            let name = name.trim_end_matches('.').to_ascii_lowercase();
            name == "localhost"
                || !name.contains('.')
                || name.ends_with(".internal")
                || name.ends_with(".local")
        }
        None => false,
    }
}

fn flag(value: Option<String>, default: bool) -> Result<bool, AppError> {
    match value
        .as_deref()
        .map(str::trim)
        .map(str::to_ascii_lowercase)
        .as_deref()
    {
        None => Ok(default),
        Some("1" | "true" | "yes" | "on") => Ok(true),
        Some("0" | "false" | "no" | "off") => Ok(false),
        Some(_) => Err(AppError::internal("invalid_ai_flag")),
    }
}

pub struct AiProviderInput {
    pub base_url: Option<String>,
    pub key: Option<String>,
    pub auth: Option<String>,
    pub name: Option<String>,
    pub web_search: Option<String>,
    pub zero_retention: Option<String>,
}

fn ai_provider(input: AiProviderInput) -> Result<Option<AiProvider>, AppError> {
    if input.base_url.is_none() && input.key.is_none() {
        return Ok(None);
    }
    let base = input.base_url.unwrap_or_else(|| OPENAI_BASE.into());
    let base = base.trim().trim_end_matches('/');
    let endpoint = if base.ends_with("/responses") {
        base.to_owned()
    } else {
        format!("{base}/responses")
    };
    let url = Url::parse(&endpoint).map_err(|_| AppError::internal("invalid_ai_base_url"))?;
    if !(url.scheme() == "https" || (url.scheme() == "http" && private_host(&url)))
        || url.host_str().is_none()
        || !url.username().is_empty()
        || url.password().is_some()
        || url.query().is_some()
        || url.fragment().is_some()
    {
        return Err(AppError::internal("invalid_ai_base_url"));
    }
    let host = url.host_str().unwrap_or_default().to_ascii_lowercase();
    let openai = host == "api.openai.com";
    if input
        .key
        .as_deref()
        .is_some_and(|key| key.bytes().any(|b| !b.is_ascii_graphic()))
        || (openai && input.key.is_none())
    {
        return Err(AppError::internal("invalid_ai_key"));
    }
    let auth = match input
        .auth
        .as_deref()
        .map(str::trim)
        .map(str::to_ascii_lowercase)
        .as_deref()
    {
        None | Some("bearer") => AiAuth::Bearer,
        Some("api-key") => AiAuth::ApiKey,
        Some(_) => return Err(AppError::internal("invalid_ai_auth")),
    };
    let name = match input.name.map(|name| name.trim().to_owned()) {
        Some(name) if !name.is_empty() => {
            if name.chars().count() > 60 || name.chars().any(char::is_control) {
                return Err(AppError::internal("invalid_ai_provider_name"));
            }
            name
        }
        _ if openai => "OpenAI".into(),
        _ if host.ends_with(".openai.azure.com") => "Azure OpenAI".into(),
        _ => host.clone(),
    };
    Ok(Some(AiProvider {
        url,
        key: input.key.map(Zeroizing::new),
        auth,
        name,
        web_search: flag(input.web_search, openai)?,
        zero_retention: flag(input.zero_retention, false)?,
    }))
}

fn decision_adapter(
    endpoint: Option<String>,
    token: Option<String>,
) -> Result<Option<DecisionAdapter>, AppError> {
    match (endpoint, token) {
        (None, None) => Ok(None),
        (Some(endpoint), Some(token)) => {
            let url = Url::parse(&endpoint)
                .map_err(|_| AppError::internal("invalid_decision_endpoint"))?;
            if url.scheme() != "https"
                || url.host_str().is_none()
                || !url.username().is_empty()
                || url.password().is_some()
                || url.fragment().is_some()
                || url.query().is_some()
                || token.bytes().any(|b| !b.is_ascii_graphic())
            {
                return Err(AppError::internal("invalid_decision_configuration"));
            }
            Ok(Some(DecisionAdapter {
                url,
                token: Zeroizing::new(token),
            }))
        }
        _ => Err(AppError::internal("incomplete_decision_configuration")),
    }
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
            ai: ai_provider(AiProviderInput {
                base_url: optional("POSTMERE_AI_BASE_URL"),
                key: optional("POSTMERE_AI_API_KEY").or_else(|| optional("OPENAI_API_KEY")),
                auth: optional("POSTMERE_AI_AUTH"),
                name: optional("POSTMERE_AI_PROVIDER_NAME"),
                web_search: optional("POSTMERE_AI_WEB_SEARCH"),
                zero_retention: optional("POSTMERE_AI_ZERO_RETENTION"),
            })?,
            ai_model: env::var("POSTMERE_AI_MODEL").unwrap_or_else(|_| "gpt-6-luna".into()),
            decision_adapter: decision_adapter(
                optional("POSTMERE_DECISION_URL"),
                optional("POSTMERE_DECISION_TOKEN"),
            )?,
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
/// Whether an MCP client may use this OAuth callback. Allowlisted entries
/// match exactly, except that native apps on a loopback address may use any
/// port (RFC 8252 §7.3): CLIs such as Claude Code and Codex listen on a fresh
/// port for each sign-in. Host, path and query must still match an entry.
pub fn mcp_redirect_allowed(allowlist: &[String], uri: &str) -> bool {
    if allowlist.iter().any(|entry| entry == uri) {
        return true;
    }
    let loopback = |url: &Url| {
        url.scheme() == "http"
            && matches!(url.host_str(), Some("localhost" | "127.0.0.1" | "[::1]"))
    };
    let Ok(requested) = Url::parse(uri) else {
        return false;
    };
    if !loopback(&requested)
        || !requested.username().is_empty()
        || requested.password().is_some()
        || requested.fragment().is_some()
    {
        return false;
    }
    allowlist
        .iter()
        .filter_map(|entry| Url::parse(entry).ok())
        .any(|entry| {
            loopback(&entry)
                && entry.host_str() == requested.host_str()
                && entry.path() == requested.path()
                && entry.query() == requested.query()
        })
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
    fn ai(base: Option<&str>, key: Option<&str>) -> AiProviderInput {
        AiProviderInput {
            base_url: base.map(Into::into),
            key: key.map(Into::into),
            auth: None,
            name: None,
            web_search: None,
            zero_retention: None,
        }
    }
    #[test]
    fn ai_provider_defaults_to_openai_and_accepts_compatible_endpoints() {
        assert!(ai_provider(ai(None, None)).unwrap().is_none());
        let openai = ai_provider(ai(None, Some("sk-test"))).unwrap().unwrap();
        assert_eq!(openai.url.as_str(), "https://api.openai.com/v1/responses");
        assert_eq!(
            (
                openai.name.as_str(),
                openai.web_search,
                openai.zero_retention
            ),
            ("OpenAI", true, false)
        );
        // OpenAI itself always needs a key.
        assert!(ai_provider(ai(Some("https://api.openai.com/v1"), None)).is_err());

        let azure = ai_provider(AiProviderInput {
            auth: Some("api-key".into()),
            ..ai(
                Some("https://acme.openai.azure.com/openai/v1/"),
                Some("azure-key"),
            )
        })
        .unwrap()
        .unwrap();
        assert_eq!(
            azure.url.as_str(),
            "https://acme.openai.azure.com/openai/v1/responses"
        );
        assert_eq!(
            (azure.auth, azure.name.as_str(), azure.web_search),
            (AiAuth::ApiKey, "Azure OpenAI", false)
        );

        // A model server on the same private network needs neither TLS nor a key.
        for base in [
            "http://ollama:11434/v1",
            "http://127.0.0.1:8000/v1",
            "http://10.0.0.5/v1",
            "http://host.docker.internal:11434/v1/responses",
        ] {
            let local = ai_provider(ai(Some(base), None)).unwrap().unwrap();
            assert!(local.key.is_none() && !local.web_search, "{base}");
            assert!(local.url.path().ends_with("/v1/responses"), "{base}");
        }
        let attested = ai_provider(AiProviderInput {
            zero_retention: Some("true".into()),
            name: Some("Acme private model".into()),
            ..ai(Some("http://vllm:8000/v1"), None)
        })
        .unwrap()
        .unwrap();
        assert!(attested.zero_retention);
        assert_eq!(attested.name, "Acme private model");
    }
    #[test]
    fn ai_provider_rejects_plaintext_over_the_internet_and_malformed_settings() {
        for base in [
            "http://models.example.com/v1",
            "https://user:pw@models.example.com/v1",
            "https://models.example.com/v1?x=1",
            "ftp://models/v1",
            "not a url",
        ] {
            assert!(ai_provider(ai(Some(base), Some("k"))).is_err(), "{base}");
        }
        assert!(ai_provider(ai(None, Some("key with space"))).is_err());
        assert!(
            ai_provider(AiProviderInput {
                auth: Some("basic".into()),
                ..ai(None, Some("k"))
            })
            .is_err()
        );
        assert!(
            ai_provider(AiProviderInput {
                web_search: Some("maybe".into()),
                ..ai(None, Some("k"))
            })
            .is_err()
        );
    }
    #[test]
    fn decision_adapter_requires_an_explicit_secure_endpoint_and_separate_token() {
        let token = Some("adapter-token".to_owned());
        assert!(decision_adapter(None, None).unwrap().is_none());
        assert!(decision_adapter(None, token.clone()).is_err());
        assert!(decision_adapter(Some("https://fixture.example/check".into()), None).is_err());
        let adapter = decision_adapter(Some("https://fixture.example/check".into()), token.clone())
            .unwrap()
            .unwrap();
        assert_eq!(adapter.url.host_str(), Some("fixture.example"));
        for invalid in [
            "http://fixture.example/check",
            "https://name@fixture.example/check",
            "https://fixture.example/check?token=value",
            "https://fixture.example/check#part",
        ] {
            assert!(decision_adapter(Some(invalid.into()), token.clone()).is_err());
        }
        assert!(
            decision_adapter(
                Some("https://fixture.example/check".into()),
                Some("a\r\nb".into())
            )
            .is_err()
        );
    }
    #[test]
    fn loopback_callbacks_match_any_port_but_nothing_else() {
        let allow = vec![
            "http://localhost/callback".to_string(),
            "https://claude.ai/api/mcp/auth_callback".to_string(),
        ];
        assert!(mcp_redirect_allowed(
            &allow,
            "http://localhost:51023/callback"
        ));
        assert!(mcp_redirect_allowed(&allow, "http://localhost/callback"));
        assert!(mcp_redirect_allowed(
            &allow,
            "https://claude.ai/api/mcp/auth_callback"
        ));
        for denied in [
            "http://localhost:51023/other",
            "http://127.0.0.1:51023/callback",
            "http://localhost:51023/callback?x=1",
            "http://evil.example:51023/callback",
            "https://claude.ai:8443/api/mcp/auth_callback",
            "http://user@localhost:51023/callback",
        ] {
            assert!(!mcp_redirect_allowed(&allow, denied), "{denied}");
        }
    }
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
