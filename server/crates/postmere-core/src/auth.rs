use crate::{AppState, config::Config, db, error::AppError};
use argon2::{
    Algorithm, Argon2, Params, Version,
    password_hash::{PasswordHasher, PasswordVerifier, phc::PasswordHash},
};
use axum::{
    Extension, Json, Router,
    extract::{ConnectInfo, DefaultBodyLimit, FromRequestParts, State},
    http::{StatusCode, header, request::Parts},
    routing::{get, post},
};
use base64::{Engine, engine::general_purpose::URL_SAFE_NO_PAD};
use chrono::{DateTime, Duration, Utc};
use hmac::{Hmac, Mac};
use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};
use sqlx::{PgPool, Postgres, Row, Transaction};
use std::{net::SocketAddr, sync::Arc};
use tokio::sync::Semaphore;
use uuid::Uuid;
use zeroize::Zeroizing;

#[derive(Clone, Debug, Serialize)]
pub struct AuthContext {
    pub user_id: Uuid,
    pub workspace_id: Uuid,
    pub session_id: Uuid,
    pub role: String,
}
impl AuthContext {
    pub async fn begin(&self, pool: &PgPool) -> Result<Transaction<'static, Postgres>, AppError> {
        db::tenant_transaction(pool, self).await
    }
    pub fn require_admin(&self) -> Result<(), AppError> {
        if matches!(self.role.as_str(), "owner" | "admin") {
            Ok(())
        } else {
            Err(AppError::forbidden())
        }
    }
}
impl FromRequestParts<AppState> for AuthContext {
    type Rejection = AppError;
    async fn from_request_parts(
        parts: &mut Parts,
        state: &AppState,
    ) -> Result<Self, Self::Rejection> {
        if parts.headers.get_all(header::AUTHORIZATION).iter().count() != 1 {
            return Err(AppError::unauthorized());
        }
        let header = parts
            .headers
            .get(header::AUTHORIZATION)
            .and_then(|v| v.to_str().ok())
            .ok_or_else(AppError::unauthorized)?;
        let token = header
            .strip_prefix("Bearer ")
            .ok_or_else(AppError::unauthorized)?;
        state.auth.authenticate(token).await
    }
}

pub struct AuthService {
    pool: PgPool,
    rate_key: Zeroizing<Vec<u8>>,
    dummy_hash: String,
    password_slots: Arc<Semaphore>,
    session_hours: i64,
    absolute_days: i64,
}
#[derive(Serialize, Deserialize)]
pub struct SessionResponse {
    pub token: String,
    pub expires_at: DateTime<Utc>,
    pub absolute_expires_at: DateTime<Utc>,
    pub session_id: Uuid,
    pub user_id: Uuid,
    pub workspace_id: Uuid,
    pub role: String,
}
impl AuthService {
    pub async fn hash_new_password(&self, password: Zeroizing<String>) -> Result<String, AppError> {
        let permit = self
            .password_slots
            .clone()
            .try_acquire_owned()
            .map_err(|_| AppError::rate_limited())?;
        tokio::task::spawn_blocking(move || {
            let _permit = permit;
            hash_password_sync(&password)
        })
        .await
        .map_err(|_| AppError::internal("password_worker"))?
    }
    pub async fn new(pool: PgPool, config: &Config) -> Result<Self, AppError> {
        let mut random = [0u8; 32];
        getrandom::fill(&mut random).map_err(|_| AppError::internal("secure_random"))?;
        let dummy_password = Zeroizing::new(URL_SAFE_NO_PAD.encode(random));
        let dummy_hash = hash_password(dummy_password).await?;
        Ok(Self {
            pool,
            rate_key: config.rate_limit_key.clone(),
            dummy_hash,
            password_slots: Arc::new(Semaphore::new(4)),
            session_hours: config.session_hours,
            absolute_days: config.session_absolute_days,
        })
    }
    pub async fn authenticate(&self, token: &str) -> Result<AuthContext, AppError> {
        let hash = token_hash(token)?;
        let row = sqlx::query("SELECT s.id,s.user_id,s.workspace_id,m.role FROM sessions s JOIN users u ON u.id=s.user_id JOIN memberships m ON m.workspace_id=s.workspace_id AND m.user_id=s.user_id JOIN workspaces w ON w.id=s.workspace_id WHERE s.token_hash=$1 AND s.revoked_at IS NULL AND s.expires_at>now() AND s.absolute_expires_at>now() AND u.disabled_at IS NULL AND m.revoked_at IS NULL AND w.disabled_at IS NULL")
            .bind(hash).fetch_optional(&self.pool).await?.ok_or_else(AppError::unauthorized)?;
        Ok(AuthContext {
            session_id: row.get("id"),
            user_id: row.get("user_id"),
            workspace_id: row.get("workspace_id"),
            role: row.get("role"),
        })
    }
    async fn login(&self, input: LoginRequest, client: &str) -> Result<SessionResponse, AppError> {
        let password = Zeroizing::new(input.password);
        let email = input.email.trim().to_lowercase();
        if email.len() > 254 || password.is_empty() || password.len() > 1024 {
            return Err(AppError::unauthorized());
        }
        self.rate_limit("login_ip", client, 60).await?;
        self.rate_limit("login_email", &email, 10).await?;
        let permit = self
            .password_slots
            .clone()
            .try_acquire_owned()
            .map_err(|_| AppError::rate_limited())?;
        let row = sqlx::query("SELECT u.id,u.password_hash,m.role FROM users u JOIN memberships m ON m.user_id=u.id JOIN workspaces w ON w.id=m.workspace_id WHERE u.email=$1 AND m.workspace_id=$2 AND u.disabled_at IS NULL AND m.revoked_at IS NULL AND w.disabled_at IS NULL")
            .bind(&email).bind(input.workspace_id).fetch_optional(&self.pool).await?;
        let hash = row
            .as_ref()
            .map(|r| r.get::<String, _>("password_hash"))
            .unwrap_or_else(|| self.dummy_hash.clone());
        let valid = tokio::task::spawn_blocking(move || {
            let _permit = permit;
            PasswordHash::new(&hash).ok().is_some_and(|parsed| {
                Argon2::default()
                    .verify_password(password.as_bytes(), &parsed)
                    .is_ok()
            })
        })
        .await
        .map_err(|_| AppError::internal("password_worker"))?;
        if !valid {
            return Err(AppError::unauthorized());
        }
        let row = row.ok_or_else(AppError::unauthorized)?;
        let mut tx = self.pool.begin().await?;
        // Recheck and lock identity state after expensive password verification.
        let active = sqlx::query("SELECT m.role FROM memberships m JOIN users u ON u.id=m.user_id JOIN workspaces w ON w.id=m.workspace_id WHERE m.user_id=$1 AND m.workspace_id=$2 AND m.revoked_at IS NULL AND u.disabled_at IS NULL AND w.disabled_at IS NULL AND u.password_hash=$3 FOR SHARE OF m,u,w")
            .bind(row.get::<Uuid,_>("id")).bind(input.workspace_id).bind(row.get::<String,_>("password_hash")).fetch_optional(&mut *tx).await?.ok_or_else(AppError::unauthorized)?;
        let auth = AuthContext {
            user_id: row.get("id"),
            workspace_id: input.workspace_id,
            session_id: Uuid::new_v4(),
            role: active.get("role"),
        };
        let result = self
            .issue(
                &mut tx,
                &auth,
                Utc::now() + Duration::days(self.absolute_days),
            )
            .await?;
        tx.commit().await?;
        Ok(result)
    }
    async fn issue(
        &self,
        tx: &mut Transaction<'_, Postgres>,
        auth: &AuthContext,
        absolute: DateTime<Utc>,
    ) -> Result<SessionResponse, AppError> {
        let mut bytes = [0u8; 32];
        getrandom::fill(&mut bytes).map_err(|_| AppError::internal("secure_random"))?;
        let token = URL_SAFE_NO_PAD.encode(bytes);
        let expires = (Utc::now() + Duration::hours(self.session_hours)).min(absolute);
        let session_id = Uuid::new_v4();
        sqlx::query("INSERT INTO sessions (id,workspace_id,user_id,token_hash,expires_at,absolute_expires_at) VALUES ($1,$2,$3,$4,$5,$6)")
            .bind(session_id).bind(auth.workspace_id).bind(auth.user_id).bind(Sha256::digest(token.as_bytes()).as_slice()).bind(expires).bind(absolute).execute(&mut **tx).await?;
        Ok(SessionResponse {
            token,
            expires_at: expires,
            absolute_expires_at: absolute,
            session_id,
            user_id: auth.user_id,
            workspace_id: auth.workspace_id,
            role: auth.role.clone(),
        })
    }
    async fn rotate(&self, auth: &AuthContext) -> Result<SessionResponse, AppError> {
        let mut tx = self.pool.begin().await?;
        // Serialize rotation and logout-all, including sessions created by a
        // rotation that was already in flight when logout-all began.
        sqlx::query("SELECT id FROM users WHERE id=$1 FOR UPDATE")
            .bind(auth.user_id)
            .fetch_one(&mut *tx)
            .await?;
        let row = sqlx::query("SELECT s.absolute_expires_at,m.role FROM sessions s JOIN users u ON u.id=s.user_id JOIN memberships m ON m.workspace_id=s.workspace_id AND m.user_id=s.user_id JOIN workspaces w ON w.id=s.workspace_id WHERE s.id=$1 AND s.user_id=$2 AND s.workspace_id=$3 AND s.revoked_at IS NULL AND s.expires_at>now() AND s.absolute_expires_at>now() AND u.disabled_at IS NULL AND m.revoked_at IS NULL AND w.disabled_at IS NULL FOR UPDATE OF s")
            .bind(auth.session_id).bind(auth.user_id).bind(auth.workspace_id).fetch_optional(&mut *tx).await?.ok_or_else(AppError::unauthorized)?;
        let current_auth = AuthContext {
            role: row.get("role"),
            ..auth.clone()
        };
        let result = self
            .issue(&mut tx, &current_auth, row.get("absolute_expires_at"))
            .await?;
        sqlx::query("UPDATE sessions SET revoked_at=now(),replaced_by=$1 WHERE id=$2")
            .bind(result.session_id)
            .bind(auth.session_id)
            .execute(&mut *tx)
            .await?;
        tx.commit().await?;
        Ok(result)
    }
    pub async fn rate_limit(
        &self,
        domain: &str,
        identity: &str,
        limit: i32,
    ) -> Result<(), AppError> {
        let mut mac = Hmac::<Sha256>::new_from_slice(&self.rate_key)
            .map_err(|_| AppError::internal("rate_limit_key"))?;
        mac.update(domain.as_bytes());
        mac.update(&[0]);
        mac.update(identity.as_bytes());
        let bucket = mac.finalize().into_bytes().to_vec();
        let row = sqlx::query("INSERT INTO login_rate_limits (bucket,window_started_at,attempts,expires_at) VALUES ($1,now(),1,now()+interval '15 minutes') ON CONFLICT (bucket) DO UPDATE SET attempts=CASE WHEN login_rate_limits.expires_at<=now() THEN 1 ELSE login_rate_limits.attempts+1 END,window_started_at=CASE WHEN login_rate_limits.expires_at<=now() THEN now() ELSE login_rate_limits.window_started_at END,expires_at=CASE WHEN login_rate_limits.expires_at<=now() THEN now()+interval '15 minutes' ELSE login_rate_limits.expires_at END RETURNING attempts")
            .bind(bucket).fetch_one(&self.pool).await?;
        if row.get::<i32, _>("attempts") > limit {
            return Err(AppError::rate_limited());
        }
        Ok(())
    }
}

pub async fn hash_password(password: Zeroizing<String>) -> Result<String, AppError> {
    tokio::task::spawn_blocking(move || hash_password_sync(&password))
        .await
        .map_err(|_| AppError::internal("password_worker"))?
}
fn hash_password_sync(password: &str) -> Result<String, AppError> {
    let params = Params::new(19456, 2, 1, None).map_err(|_| AppError::internal("argon_params"))?;
    Argon2::new(Algorithm::Argon2id, Version::V0x13, params)
        .hash_password(password.as_bytes())
        .map(|v| v.to_string())
        .map_err(|_| AppError::internal("password_hash"))
}
fn token_hash(token: &str) -> Result<Vec<u8>, AppError> {
    if token.len() != 43
        || URL_SAFE_NO_PAD
            .decode(token)
            .ok()
            .is_none_or(|v| v.len() != 32)
    {
        return Err(AppError::unauthorized());
    }
    Ok(Sha256::digest(token.as_bytes()).to_vec())
}
#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct LoginRequest {
    email: String,
    password: String,
    workspace_id: Uuid,
}

pub fn router() -> Router<AppState> {
    Router::new()
        .route(
            "/v1/auth/login",
            post(login).layer(DefaultBodyLimit::max(4096)),
        )
        .route("/v1/auth/rotate", post(rotate))
        .route("/v1/auth/logout", post(logout))
        .route("/v1/auth/logout-all", post(logout_all))
        .route("/v1/auth/me", get(me))
}
async fn login(
    State(state): State<AppState>,
    client: Option<Extension<ConnectInfo<SocketAddr>>>,
    Json(input): Json<LoginRequest>,
) -> Result<Json<SessionResponse>, AppError> {
    let client = client
        .map(|Extension(ConnectInfo(addr))| addr.ip().to_string())
        .unwrap_or_else(|| "unknown-peer".into());
    state.auth.login(input, &client).await.map(Json)
}
async fn rotate(
    auth: AuthContext,
    State(state): State<AppState>,
) -> Result<Json<SessionResponse>, AppError> {
    state.auth.rotate(&auth).await.map(Json)
}
async fn logout(auth: AuthContext, State(state): State<AppState>) -> Result<StatusCode, AppError> {
    sqlx::query("UPDATE sessions SET revoked_at=now() WHERE id=$1 AND user_id=$2 AND workspace_id=$3 AND revoked_at IS NULL").bind(auth.session_id).bind(auth.user_id).bind(auth.workspace_id).execute(&state.pool).await?;
    Ok(StatusCode::NO_CONTENT)
}
async fn logout_all(
    auth: AuthContext,
    State(state): State<AppState>,
) -> Result<StatusCode, AppError> {
    let mut tx = state.pool.begin().await?;
    sqlx::query("SELECT id FROM users WHERE id=$1 FOR UPDATE")
        .bind(auth.user_id)
        .fetch_one(&mut *tx)
        .await?;
    sqlx::query("UPDATE sessions SET revoked_at=now() WHERE user_id=$1 AND revoked_at IS NULL")
        .bind(auth.user_id)
        .execute(&mut *tx)
        .await?;
    tx.commit().await?;
    Ok(StatusCode::NO_CONTENT)
}
async fn me(
    auth: AuthContext,
    State(state): State<AppState>,
) -> Result<Json<serde_json::Value>, AppError> {
    let email: String = sqlx::query_scalar("SELECT email FROM users WHERE id=$1")
        .bind(auth.user_id)
        .fetch_one(&state.pool)
        .await?;
    Ok(Json(
        serde_json::json!({"session_id":auth.session_id,"user_id":auth.user_id,"workspace_id":auth.workspace_id,"role":auth.role,"email":email}),
    ))
}
