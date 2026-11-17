//! Shared authentication, configuration, encryption, and tenant database boundaries.

pub mod auth;
pub mod config;
pub mod crypto;
pub mod db;
pub mod error;
pub mod tokens;

use std::{sync::Arc, time::Duration};

use sqlx::PgPool;

use auth::AuthService;
use config::Config;
use crypto::CredentialCipher;
use error::AppError;

#[derive(Clone)]
pub struct AppState {
    pub pool: PgPool,
    pub config: Arc<Config>,
    pub crypto: Arc<CredentialCipher>,
    pub auth: Arc<AuthService>,
    /// Fixed provider API calls only. Untrusted destinations need a separately
    /// validated and pinned resolver; this client is not an SSRF boundary.
    pub http: reqwest::Client,
}

impl AppState {
    pub async fn new(pool: PgPool, config: Config) -> Result<Self, AppError> {
        db::verify_runtime_role(&pool).await?;
        let crypto = Arc::new(CredentialCipher::from_config(&config)?);
        let auth = Arc::new(AuthService::new(pool.clone(), &config).await?);
        let http = reqwest::Client::builder()
            .redirect(reqwest::redirect::Policy::none())
            .no_proxy()
            .connect_timeout(Duration::from_secs(5))
            .timeout(Duration::from_secs(20))
            .build()
            .map_err(|_| AppError::internal("http_client_init"))?;
        Ok(Self {
            pool,
            config: Arc::new(config),
            crypto,
            auth,
            http,
        })
    }
}
