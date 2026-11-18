use crate::GmailConfig;
use base64::{Engine, engine::general_purpose::URL_SAFE_NO_PAD};
use chrono::Utc;
use postmere_core::{AppState, error::AppError};
use serde::Deserialize;
use std::time::{Duration, Instant};

#[derive(Clone, Deserialize)]
pub struct GoogleKey {
    pub kid: String,
    pub kty: String,
    pub alg: String,
    #[serde(rename = "use")]
    pub usage: String,
    pub n: String,
    pub e: String,
}
#[derive(Deserialize)]
struct Header {
    alg: String,
    kid: String,
}
#[derive(Debug, Deserialize)]
pub struct GoogleClaims {
    pub iss: String,
    pub aud: String,
    pub email: String,
    pub email_verified: bool,
    pub sub: String,
    pub iat: i64,
    pub exp: i64,
}

fn header(token: &str) -> Result<Header, AppError> {
    if token.len() > 8192 {
        return Err(AppError::unauthorized());
    }
    let part = token.split('.').next().ok_or_else(AppError::unauthorized)?;
    let bytes = URL_SAFE_NO_PAD
        .decode(part)
        .map_err(|_| AppError::unauthorized())?;
    let header: Header = serde_json::from_slice(&bytes).map_err(|_| AppError::unauthorized())?;
    if header.alg != "RS256" || header.kid.is_empty() || header.kid.len() > 128 {
        return Err(AppError::unauthorized());
    }
    Ok(header)
}

/// Verify the signed bytes with a trusted fixed-origin Google RSA key and then
/// require the deployment's exact audience and verified service-account email.
pub fn verify_google_jwt(
    token: &str,
    config: &GmailConfig,
    keys: &[GoogleKey],
    now: i64,
) -> Result<GoogleClaims, AppError> {
    let header = header(token)?;
    let key = keys
        .iter()
        .find(|k| k.kid == header.kid && k.kty == "RSA" && k.alg == "RS256" && k.usage == "sig")
        .ok_or_else(AppError::unauthorized)?;
    let parts: Vec<_> = token.split('.').collect();
    if parts.len() != 3 {
        return Err(AppError::unauthorized());
    }
    let n = URL_SAFE_NO_PAD
        .decode(&key.n)
        .map_err(|_| AppError::unauthorized())?;
    let e = URL_SAFE_NO_PAD
        .decode(&key.e)
        .map_err(|_| AppError::unauthorized())?;
    let signature = URL_SAFE_NO_PAD
        .decode(parts[2])
        .map_err(|_| AppError::unauthorized())?;
    if !(256..=512).contains(&n.len()) || e.is_empty() || e.len() > 8 || signature.len() > 512 {
        return Err(AppError::unauthorized());
    }
    let signed = token.rsplit_once('.').ok_or_else(AppError::unauthorized)?.0;
    ring::signature::RsaPublicKeyComponents { n: &n, e: &e }
        .verify(
            &ring::signature::RSA_PKCS1_2048_8192_SHA256,
            signed.as_bytes(),
            &signature,
        )
        .map_err(|_| AppError::unauthorized())?;
    let claims: GoogleClaims = serde_json::from_slice(
        &URL_SAFE_NO_PAD
            .decode(parts[1])
            .map_err(|_| AppError::unauthorized())?,
    )
    .map_err(|_| AppError::unauthorized())?;
    if !matches!(
        claims.iss.as_str(),
        "https://accounts.google.com" | "accounts.google.com"
    ) || claims.aud != config.audience
        || claims.email != config.service_account
        || !claims.email_verified
        || claims.sub.is_empty()
        || claims.sub.len() > 255
        || claims.iat <= 0
        || claims.iat > now + 30
        || claims.exp <= now
        || claims.exp <= claims.iat
        || claims.exp.saturating_sub(claims.iat) > 3900
        || now.saturating_sub(claims.iat) > 3900
    {
        return Err(AppError::unauthorized());
    }
    Ok(claims)
}

#[derive(Default)]
pub(crate) struct GoogleKeys {
    keys: Vec<GoogleKey>,
    fetched: Option<Instant>,
    attempted: Option<Instant>,
    cache_ttl: Duration,
}
impl GoogleKeys {
    pub(crate) fn seeded(keys: Vec<GoogleKey>) -> Self {
        Self {
            keys,
            fetched: Some(Instant::now()),
            attempted: Some(Instant::now()),
            cache_ttl: Duration::from_secs(3600),
        }
    }
    pub(crate) async fn verify(
        &mut self,
        state: &AppState,
        token: &str,
        config: &GmailConfig,
    ) -> Result<(), AppError> {
        let header = header(token)?;
        let fresh = self.fetched.is_some_and(|t| t.elapsed() < self.cache_ttl);
        let known = self.keys.iter().any(|k| k.kid == header.kid);
        if (!fresh || !known)
            && self
                .attempted
                .is_none_or(|t| t.elapsed() >= Duration::from_secs(60))
        {
            self.attempted = Some(Instant::now());
            // No JWT header/claim is ever used as a destination or key URL.
            let mut response = state
                .http
                .get("https://www.googleapis.com/oauth2/v3/certs")
                .send()
                .await
                .map_err(|_| AppError::unavailable())?;
            if !response.status().is_success() {
                return Err(AppError::unavailable());
            }
            let cache_ttl = response
                .headers()
                .get(reqwest::header::CACHE_CONTROL)
                .and_then(|v| v.to_str().ok())
                .and_then(|v| {
                    v.split(',').find_map(|part| {
                        part.trim()
                            .strip_prefix("max-age=")
                            .and_then(|n| n.parse::<u64>().ok())
                    })
                })
                .unwrap_or(300)
                .clamp(1, 3600);
            let mut bytes = Vec::new();
            while let Some(chunk) = response
                .chunk()
                .await
                .map_err(|_| AppError::unavailable())?
            {
                if bytes.len() + chunk.len() > 64 * 1024 {
                    return Err(AppError::unavailable());
                }
                bytes.extend_from_slice(&chunk);
            }
            #[derive(Deserialize)]
            struct Keys {
                keys: Vec<GoogleKey>,
            }
            let parsed: Keys =
                serde_json::from_slice(&bytes).map_err(|_| AppError::unavailable())?;
            if parsed.keys.is_empty() || parsed.keys.len() > 16 {
                return Err(AppError::unavailable());
            }
            self.keys = parsed.keys;
            self.fetched = Some(Instant::now());
            self.cache_ttl = Duration::from_secs(cache_ttl);
        }
        if self.fetched.is_none_or(|t| t.elapsed() >= self.cache_ttl) {
            return Err(AppError::unavailable());
        }
        verify_google_jwt(token, config, &self.keys, Utc::now().timestamp()).map(|_| ())
    }
}
