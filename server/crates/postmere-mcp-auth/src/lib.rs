//! Dedicated OAuth grants for remote MCP clients. Workspace session tokens are
//! never accepted as MCP tokens or disclosed to an OAuth client.
mod browser;
mod connections;
mod oauth;

pub use browser::{BrowserSession, browser_session, login_redirect, verify_browser_post};

use axum::{
    Router,
    extract::DefaultBodyLimit,
    http::{HeaderMap, header},
    routing::{delete, get, post},
};
use base64::{Engine, engine::general_purpose::URL_SAFE_NO_PAD};
use postmere_core::{AppState, auth::AuthContext, error::AppError};
use sha2::{Digest, Sha256};
use sqlx::{PgPool, Postgres, Row, Transaction};
use std::collections::BTreeSet;
use uuid::Uuid;

pub const SCOPES: [&str; 4] = ["mail:read", "mail:draft", "mail:manage", "mail:send"];

#[derive(Clone, Debug)]
pub struct McpAuth {
    pub auth: AuthContext,
    pub scopes: BTreeSet<String>,
    pub grant_id: Uuid,
    access_token_hash: Vec<u8>,
    resource: String,
}
impl McpAuth {
    pub fn require_scope(&self, scope: &str) -> Result<(), AppError> {
        if self.scopes.contains(scope) {
            Ok(())
        } else {
            Err(AppError::forbidden())
        }
    }

    /// Hold this grant/token lock until a tool operation finishes. Workspace
    /// authorization belongs to the operation's own transaction. All MCP
    /// routes acquire grant locks before taking workspace identity locks.
    pub async fn begin_authorized<'a>(
        &self,
        pool: &'a PgPool,
    ) -> Result<Transaction<'a, Postgres>, AppError> {
        let mut tx = pool.begin().await?;
        let row = sqlx::query("SELECT g.scopes,g.revoked_at,g.expires_at AS grant_expires_at,t.expires_at AS token_expires_at FROM mcp_oauth_grants g JOIN mcp_access_tokens t ON t.grant_id=g.id WHERE g.id=$1 AND t.token_hash=$2 AND g.resource=$3 FOR SHARE OF g,t")
            .bind(self.grant_id).bind(&self.access_token_hash).bind(&self.resource)
            .fetch_optional(&mut *tx).await?.ok_or_else(AppError::unauthorized)?;
        let current_scopes: BTreeSet<String> =
            row.get::<Vec<String>, _>("scopes").into_iter().collect();
        if row
            .get::<Option<chrono::DateTime<chrono::Utc>>, _>("revoked_at")
            .is_some()
            || current_scopes != self.scopes
        {
            return Err(AppError::unauthorized());
        }
        // A lock may have waited past expiration. PostgreSQL now() is fixed at
        // transaction start, so evaluate wall time after acquiring the locks.
        let active: bool = sqlx::query_scalar(
            "SELECT ($1::timestamptz IS NULL OR clock_timestamp() < $1) AND clock_timestamp() < $2",
        )
        .bind(row.get::<Option<chrono::DateTime<chrono::Utc>>, _>("grant_expires_at"))
        .bind(row.get::<chrono::DateTime<chrono::Utc>, _>("token_expires_at"))
        .fetch_one(&mut *tx)
        .await?;
        if !active {
            return Err(AppError::unauthorized());
        }
        Ok(tx)
    }
}

pub fn router() -> Router<AppState> {
    Router::new()
        .route(
            "/.well-known/oauth-protected-resource/mcp",
            get(oauth::resource_metadata),
        )
        .route(
            "/.well-known/oauth-authorization-server",
            get(oauth::server_metadata),
        )
        .route("/mcp/register", post(oauth::register))
        .route("/mcp/authorize", get(oauth::authorize))
        .route("/mcp/consent/{id}", get(oauth::consent).post(oauth::decide))
        .route("/mcp/token", post(oauth::token))
        .route("/mcp/revoke", post(oauth::revoke))
        .route("/mcp/login", get(browser::login_page).post(browser::login))
        .route("/mcp/connected", get(connections::browser_connections))
        .route(
            "/mcp/connections/{id}/revoke",
            post(connections::browser_revoke),
        )
        .route("/mcp/logout", post(browser::logout))
        .route("/v1/mcp/connections", get(connections::list))
        .route("/v1/mcp/connections/{id}", delete(connections::revoke))
        .layer(DefaultBodyLimit::max(16 * 1024))
}

pub async fn authenticate(state: &AppState, headers: &HeaderMap) -> Result<McpAuth, AppError> {
    if headers.get_all(header::AUTHORIZATION).iter().count() != 1 {
        return Err(AppError::unauthorized());
    }
    let token = headers
        .get(header::AUTHORIZATION)
        .and_then(|h| h.to_str().ok())
        .and_then(|h| h.strip_prefix("Bearer "))
        .ok_or_else(AppError::unauthorized)?;
    let token_hash = checked_hash(token, "pm_mcp_")?;
    let row = sqlx::query("SELECT g.id,g.scopes,s.id AS session_id,s.user_id,s.workspace_id,m.role FROM mcp_access_tokens t JOIN mcp_oauth_grants g ON g.id=t.grant_id JOIN sessions s ON s.id=g.session_id JOIN memberships m ON m.workspace_id=s.workspace_id AND m.user_id=s.user_id JOIN users u ON u.id=s.user_id JOIN workspaces w ON w.id=s.workspace_id WHERE t.token_hash=$1 AND t.expires_at>now() AND g.resource=$2 AND g.revoked_at IS NULL AND (g.expires_at IS NULL OR g.expires_at>now()) AND s.revoked_at IS NULL AND (s.expires_at IS NULL OR s.expires_at>now()) AND (s.absolute_expires_at IS NULL OR s.absolute_expires_at>now()) AND m.revoked_at IS NULL AND u.disabled_at IS NULL AND w.disabled_at IS NULL")
        .bind(&token_hash).bind(resource(state)).fetch_optional(&state.pool).await?.ok_or_else(AppError::unauthorized)?;
    Ok(McpAuth {
        auth: AuthContext {
            session_id: row.get("session_id"),
            user_id: row.get("user_id"),
            workspace_id: row.get("workspace_id"),
            role: row.get("role"),
        },
        scopes: row.get::<Vec<String>, _>("scopes").into_iter().collect(),
        grant_id: row.get("id"),
        access_token_hash: token_hash,
        resource: resource(state),
    })
}

pub(crate) fn resource(state: &AppState) -> String {
    endpoint(state, "mcp")
}
pub(crate) fn issuer(state: &AppState) -> String {
    state
        .config
        .public_base_url
        .as_str()
        .trim_end_matches('/')
        .to_string()
}
pub(crate) fn endpoint(state: &AppState, path: &str) -> String {
    format!("{}/{path}", issuer(state))
}
pub(crate) fn random_token(prefix: &str) -> Result<String, AppError> {
    let mut bytes = [0u8; 32];
    getrandom::fill(&mut bytes).map_err(|_| AppError::internal("mcp_secure_random"))?;
    Ok(format!("{prefix}{}", URL_SAFE_NO_PAD.encode(bytes)))
}
pub(crate) fn hash(value: &str) -> Vec<u8> {
    Sha256::digest(value.as_bytes()).to_vec()
}
pub(crate) fn checked_hash(token: &str, prefix: &str) -> Result<Vec<u8>, AppError> {
    let value = token
        .strip_prefix(prefix)
        .ok_or_else(AppError::unauthorized)?;
    if value.len() != 43
        || URL_SAFE_NO_PAD
            .decode(value)
            .ok()
            .is_none_or(|b| b.len() != 32)
    {
        return Err(AppError::unauthorized());
    }
    Ok(hash(token))
}
pub(crate) fn scopes(value: &str) -> Result<Vec<String>, AppError> {
    if value.len() > 256 {
        return Err(AppError::bad_request("Invalid requested scopes."));
    }
    let values: BTreeSet<_> = value.split_whitespace().map(str::to_string).collect();
    if values.is_empty() || values.iter().any(|v| !SCOPES.contains(&v.as_str())) {
        return Err(AppError::bad_request("Choose supported mail scopes."));
    }
    Ok(values.into_iter().collect())
}
