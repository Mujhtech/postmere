//! Verified provider hints only schedule the existing durable mailbox sync.
//! Polling remains a fallback for missing, delayed and rejected notifications.
mod auth;
mod routes;
mod transport;
mod worker;

pub use auth::{GoogleClaims, GoogleKey, verify_google_jwt};
use postmere_core::{AppState, error::AppError};
pub use routes::router;
use std::sync::Arc;
use tokio::sync::Mutex;
pub use transport::{
    HttpSubscriptions, Subscription, SubscriptionRequest, SubscriptionTransport, TransportFuture,
};
pub use worker::{process_one, spawn_worker};

#[derive(Clone)]
pub struct GmailConfig {
    pub topic: String,
    pub subscription: String,
    pub audience: String,
    pub service_account: String,
}

pub struct WebhookService {
    pub(crate) gmail: Option<GmailConfig>,
    pub(crate) microsoft: bool,
    pub(crate) transport: Arc<dyn SubscriptionTransport>,
    pub(crate) keys: Mutex<auth::GoogleKeys>,
}
impl WebhookService {
    pub fn from_env(state: &AppState) -> Result<Self, AppError> {
        fn value(name: &str) -> Option<String> {
            std::env::var(name).ok().filter(|v| !v.trim().is_empty())
        }
        let values = [
            "POSTMERE_GMAIL_PUBSUB_TOPIC",
            "POSTMERE_GMAIL_PUBSUB_SUBSCRIPTION",
            "POSTMERE_GMAIL_PUSH_AUDIENCE",
            "POSTMERE_GMAIL_PUSH_SERVICE_ACCOUNT",
        ]
        .map(value);
        let gmail = if values.iter().all(Option::is_none) {
            None
        } else {
            let [
                Some(topic),
                Some(subscription),
                Some(audience),
                Some(service_account),
            ] = values
            else {
                return Err(AppError::internal("incomplete_gmail_webhook_config"));
            };
            Some(GmailConfig {
                topic,
                subscription,
                audience,
                service_account,
            })
        };
        let microsoft = match value("POSTMERE_MICROSOFT_WEBHOOKS").as_deref() {
            None | Some("false") => false,
            Some("true") => true,
            _ => return Err(AppError::internal("invalid_microsoft_webhook_config")),
        };
        Self::with_transport(state, gmail, microsoft, Arc::new(HttpSubscriptions))
    }
    pub fn disabled() -> Self {
        Self {
            gmail: None,
            microsoft: false,
            transport: Arc::new(HttpSubscriptions),
            keys: Mutex::new(auth::GoogleKeys::default()),
        }
    }
    /// Dependency injection keeps tests entirely local, including token verification.
    pub fn with_transport(
        state: &AppState,
        gmail: Option<GmailConfig>,
        microsoft: bool,
        transport: Arc<dyn SubscriptionTransport>,
    ) -> Result<Self, AppError> {
        if (gmail.is_some() || microsoft) && state.config.public_base_url.scheme() != "https" {
            return Err(AppError::internal("webhooks_require_public_https"));
        }
        if let Some(gmail) = &gmail {
            fn resource(value: &str, kind: &str) -> bool {
                let parts: Vec<_> = value.split('/').collect();
                parts.len() == 4
                    && parts[0] == "projects"
                    && parts[2] == kind
                    && parts.iter().all(|p| {
                        !p.is_empty()
                            && p.len() <= 255
                            && p.bytes()
                                .all(|b| b.is_ascii_alphanumeric() || b"-_.~+%".contains(&b))
                    })
            }
            if !resource(&gmail.topic, "topics")
                || !resource(&gmail.subscription, "subscriptions")
                || gmail.audience.len() > 2048
                || gmail.audience.trim() != gmail.audience
                || gmail.audience.bytes().any(|b| b.is_ascii_control())
                || !postmere_providers::valid_email(&gmail.service_account)
                || !gmail.service_account.ends_with(".gserviceaccount.com")
            {
                return Err(AppError::internal("invalid_gmail_webhook_config"));
            }
            let audience = url::Url::parse(&gmail.audience)
                .map_err(|_| AppError::internal("invalid_gmail_push_audience"))?;
            if audience.scheme() != "https"
                || audience.host_str().is_none()
                || !audience.username().is_empty()
                || audience.password().is_some()
                || audience.fragment().is_some()
            {
                return Err(AppError::internal("invalid_gmail_push_audience"));
            }
        }
        Ok(Self {
            gmail,
            microsoft,
            transport,
            keys: Mutex::new(auth::GoogleKeys::default()),
        })
    }
    pub fn configured(&self) -> bool {
        self.gmail.is_some() || self.microsoft
    }
    pub(crate) fn enabled(&self, provider: &str) -> bool {
        match provider {
            "gmail" => self.gmail.is_some(),
            "microsoft" => self.microsoft,
            _ => false,
        }
    }
    pub async fn set_test_google_keys(&self, keys: Vec<GoogleKey>) {
        *self.keys.lock().await = auth::GoogleKeys::seeded(keys);
    }
}
