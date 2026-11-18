use base64::{Engine, engine::general_purpose::URL_SAFE_NO_PAD};
use chrono::{DateTime, Utc};
use p256::{
    ecdsa::{Signature, SigningKey, signature::Signer},
    pkcs8::DecodePrivateKey,
};
use postmere_core::error::AppError;
use serde_json::{Value, json};
use std::{env, future::Future, io::Read, pin::Pin, sync::Mutex, time::Duration};
use uuid::Uuid;
use zeroize::Zeroizing;

pub struct PushRequest {
    pub id: Uuid,
    pub token: Zeroizing<String>,
    pub environment: String,
    pub expires_at: DateTime<Utc>,
    pub payload: Value,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum DeliveryResult {
    Accepted,
    /// Apple explicitly rejected this request. No automatic resend.
    Rejected,
    /// A token was invalidated before this server registration timestamp.
    InvalidToken(Option<i64>),
    /// The network outcome is unknown. Never repeat this delivery.
    Uncertain,
}

pub trait PushTransport: Send + Sync {
    fn send(
        &self,
        request: PushRequest,
    ) -> Pin<Box<dyn Future<Output = DeliveryResult> + Send + '_>>;
}

/// No Debug/Serialize: key material and provider tokens must never reach logs.
pub struct APNsTransport {
    environment: String,
    topic: String,
    team_id: String,
    key_id: String,
    signing_key: SigningKey,
    jwt: Mutex<Option<(i64, Zeroizing<String>)>>,
    http: reqwest::Client,
}

impl APNsTransport {
    pub fn from_env() -> Result<Option<Self>, AppError> {
        let names = [
            "POSTMERE_APNS_KEY_FILE",
            "POSTMERE_APNS_KEY_ID",
            "POSTMERE_APNS_TEAM_ID",
            "POSTMERE_APNS_TOPIC",
            "POSTMERE_APNS_ENVIRONMENT",
        ];
        let values: Vec<Option<String>> = names
            .iter()
            .map(|name| env::var(name).ok().filter(|v| !v.trim().is_empty()))
            .collect();
        if values.iter().all(Option::is_none) {
            return Ok(None);
        }
        if values.iter().any(Option::is_none) {
            return Err(AppError::internal("incomplete_apns_configuration"));
        }
        let values: Vec<String> = values.into_iter().map(Option::unwrap).collect();
        let valid_id = |v: &str| {
            v.len() == 10
                && v.bytes()
                    .all(|b| b.is_ascii_uppercase() || b.is_ascii_digit())
        };
        if !valid_id(&values[1])
            || !valid_id(&values[2])
            || values[3].is_empty()
            || values[3].len() > 255
            || !values[3]
                .bytes()
                .all(|b| b.is_ascii_alphanumeric() || b == b'.' || b == b'-')
            || !matches!(values[4].as_str(), "sandbox" | "production")
        {
            return Err(AppError::internal("invalid_apns_configuration"));
        }
        let mut pem = Zeroizing::new(String::new());
        std::fs::File::open(&values[0])
            .map_err(|_| AppError::internal("apns_key_file"))?
            .take(16_385)
            .read_to_string(&mut pem)
            .map_err(|_| AppError::internal("apns_key_file"))?;
        if pem.len() > 16_384 {
            return Err(AppError::internal("apns_key_file_too_large"));
        }
        let signing_key = SigningKey::from_pkcs8_pem(&pem)
            .map_err(|_| AppError::internal("invalid_apns_signing_key"))?;
        let http = reqwest::Client::builder()
            .https_only(true)
            .http2_prior_knowledge()
            .redirect(reqwest::redirect::Policy::none())
            .retry(reqwest::retry::never())
            .no_proxy()
            .connect_timeout(Duration::from_secs(5))
            .timeout(Duration::from_secs(15))
            .build()
            .map_err(|_| AppError::internal("apns_http_client"))?;
        Ok(Some(Self {
            environment: values[4].clone(),
            topic: values[3].clone(),
            team_id: values[2].clone(),
            key_id: values[1].clone(),
            signing_key,
            jwt: Mutex::new(None),
            http,
        }))
    }
    pub fn environment(&self) -> &str {
        &self.environment
    }

    fn provider_token(&self, now: i64) -> Result<Zeroizing<String>, AppError> {
        let mut cached = self
            .jwt
            .lock()
            .map_err(|_| AppError::internal("apns_token_lock"))?;
        if let Some((issued, token)) = &*cached {
            // APNs permits one refresh per 20–60 minutes on a connection.
            if now < *issued {
                return Err(AppError::internal("apns_clock_moved_backwards"));
            }
            if now >= *issued && now - *issued < 50 * 60 {
                return Ok(Zeroizing::new(token.to_string()));
            }
        }
        let header = URL_SAFE_NO_PAD.encode(json!({"alg":"ES256","kid":self.key_id}).to_string());
        let claims = URL_SAFE_NO_PAD.encode(json!({"iss":self.team_id,"iat":now}).to_string());
        let unsigned = format!("{header}.{claims}");
        let signature: Signature = self.signing_key.sign(unsigned.as_bytes());
        let token = Zeroizing::new(format!(
            "{unsigned}.{}",
            URL_SAFE_NO_PAD.encode(signature.to_bytes())
        ));
        *cached = Some((now, Zeroizing::new(token.to_string())));
        Ok(token)
    }
}

impl PushTransport for APNsTransport {
    fn send(
        &self,
        request: PushRequest,
    ) -> Pin<Box<dyn Future<Output = DeliveryResult> + Send + '_>> {
        Box::pin(async move {
            if request.environment != self.environment
                || request.expires_at <= Utc::now()
                || !valid_token(&request.token)
            {
                return DeliveryResult::Rejected;
            }
            let Ok(token) = self.provider_token(Utc::now().timestamp()) else {
                return DeliveryResult::Rejected;
            };
            let host = if self.environment == "sandbox" {
                "api.sandbox.push.apple.com"
            } else {
                "api.push.apple.com"
            };
            let Ok(payload) = serde_json::to_vec(&request.payload) else {
                return DeliveryResult::Rejected;
            };
            if payload.len() > 4096 {
                return DeliveryResult::Rejected;
            }
            let mut authorization =
                match reqwest::header::HeaderValue::from_str(&format!("bearer {}", token.as_str()))
                {
                    Ok(value) => value,
                    Err(_) => return DeliveryResult::Rejected,
                };
            authorization.set_sensitive(true);
            let result = self
                .http
                .post(format!(
                    "https://{host}/3/device/{}",
                    request.token.as_str()
                ))
                .header(reqwest::header::AUTHORIZATION, authorization)
                .header("apns-push-type", "alert")
                .header("apns-priority", "5")
                .header("apns-topic", &self.topic)
                .header("apns-id", request.id.to_string())
                .header("apns-collapse-id", request.id.to_string())
                .header(
                    "apns-expiration",
                    request.expires_at.timestamp().to_string(),
                )
                .header(reqwest::header::CONTENT_TYPE, "application/json")
                .body(payload)
                .send()
                .await;
            let Ok(mut response) = result else {
                return DeliveryResult::Uncertain;
            };
            if response.version() != reqwest::Version::HTTP_2 {
                return DeliveryResult::Uncertain;
            }
            let status = response.status().as_u16();
            if status == 200 {
                return DeliveryResult::Accepted;
            }
            let mut body = Vec::new();
            while let Ok(Some(chunk)) = response.chunk().await {
                if body.len() + chunk.len() > 4096 {
                    return DeliveryResult::Rejected;
                }
                body.extend_from_slice(&chunk);
            }
            let value: Value = serde_json::from_slice(&body).unwrap_or(Value::Null);
            match (status, value.get("reason").and_then(Value::as_str)) {
                (410, _) => {
                    DeliveryResult::InvalidToken(value.get("timestamp").and_then(Value::as_i64))
                }
                (400, Some("BadDeviceToken" | "DeviceTokenNotForTopic")) => {
                    DeliveryResult::InvalidToken(None)
                }
                _ => DeliveryResult::Rejected,
            }
        })
    }
}

pub fn valid_token(value: &str) -> bool {
    // Treat tokens as opaque variable-length bytes, with a defensive body bound.
    !value.is_empty()
        && value.len() <= 4096
        && value.len() % 2 == 0
        && value.bytes().all(|c| c.is_ascii_hexdigit())
}

#[cfg(test)]
mod tests {
    use super::*;
    use p256::ecdsa::signature::Verifier;

    #[test]
    fn jwt_is_raw_es256_signed_and_reused_for_fifty_minutes() {
        let key = SigningKey::from_bytes((&[7u8; 32]).into()).unwrap();
        let verifier = *key.verifying_key();
        let transport = APNsTransport {
            environment: "sandbox".into(),
            topic: "example.fixture".into(),
            team_id: "ABCDEFGHIJ".into(),
            key_id: "KLMNOPQRST".into(),
            signing_key: key,
            jwt: Mutex::new(None),
            http: reqwest::Client::new(),
        };
        let first = transport.provider_token(1_000_000).unwrap();
        let pieces = first.split('.').collect::<Vec<_>>();
        assert_eq!(pieces.len(), 3);
        let header: Value =
            serde_json::from_slice(&URL_SAFE_NO_PAD.decode(pieces[0]).unwrap()).unwrap();
        let claims: Value =
            serde_json::from_slice(&URL_SAFE_NO_PAD.decode(pieces[1]).unwrap()).unwrap();
        assert_eq!(header, json!({"alg":"ES256","kid":"KLMNOPQRST"}));
        assert_eq!(claims, json!({"iss":"ABCDEFGHIJ","iat":1_000_000}));
        let raw = URL_SAFE_NO_PAD.decode(pieces[2]).unwrap();
        assert_eq!(raw.len(), 64);
        verifier
            .verify(
                format!("{}.{}", pieces[0], pieces[1]).as_bytes(),
                &Signature::from_slice(&raw).unwrap(),
            )
            .unwrap();
        assert_eq!(*first, *transport.provider_token(1_002_999).unwrap());
        assert_ne!(*first, *transport.provider_token(1_003_000).unwrap());
        assert!(transport.provider_token(999_999).is_err());
        assert!(valid_token("ab"));
        assert!(valid_token(&"ab".repeat(1024)));
        assert!(!valid_token("a"));
        assert!(!valid_token("../token"));
        assert!(!valid_token(&"a".repeat(4098)));
    }
}
