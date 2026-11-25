//! Session-bound APNs alerts. SSE refreshes the app; APNs can alert while closed.
mod live;
mod routes;
mod schedule;
mod sender_policy;
mod transport;
mod worker;

pub use live::{process_live_activity, record_assistant_activity, spawn_live_activity_worker};
use postmere_core::error::AppError;
pub use routes::router;
pub use schedule::AccountPreference;
pub use sender_policy::{SENDER_POLICY_VERSION, SenderPolicy, SenderRoute, SenderRule};
use std::sync::Arc;
pub use transport::{DeliveryResult, PushKind, PushRequest, PushTransport};
pub use worker::{process_one, spawn_worker};

pub struct PushService {
    pub(crate) environment: Option<String>,
    pub(crate) transport: Option<Arc<dyn PushTransport>>,
}
impl PushService {
    pub fn from_env() -> Result<Self, AppError> {
        match transport::APNsTransport::from_env()? {
            Some(transport) => Ok(Self {
                environment: Some(transport.environment().to_string()),
                transport: Some(Arc::new(transport)),
            }),
            None => Ok(Self::disabled()),
        }
    }
    pub fn disabled() -> Self {
        Self {
            environment: None,
            transport: None,
        }
    }
    /// Dependency injection permits protocol tests without an Apple connection.
    pub fn with_transport(
        environment: &str,
        transport: Arc<dyn PushTransport>,
    ) -> Result<Self, AppError> {
        if !matches!(environment, "sandbox" | "production") {
            return Err(AppError::bad_request("Invalid APNs environment."));
        }
        Ok(Self {
            environment: Some(environment.into()),
            transport: Some(transport),
        })
    }
    pub fn configured(&self) -> bool {
        self.transport.is_some()
    }
}
