use crate::browser::{
    browser_session, escape, login_redirect, no_store, page, verify_browser_post,
};
use axum::{
    Form, Json,
    extract::{Path, State},
    http::{HeaderMap, StatusCode},
    response::{IntoResponse, Redirect, Response},
};
use chrono::{DateTime, Utc};
use postmere_core::{AppState, auth::AuthContext, error::AppError};
use serde::{Deserialize, Serialize};
use sqlx::Row;
use uuid::Uuid;

#[derive(Serialize)]
pub(crate) struct Connection {
    id: Uuid,
    client_name: String,
    scopes: Vec<String>,
    created_at: DateTime<Utc>,
}
async fn connections(state: &AppState, auth: &AuthContext) -> Result<Vec<Connection>, AppError> {
    let mut tx = auth.begin_authorized(&state.pool).await?;
    let rows = sqlx::query("SELECT g.id,c.name,g.scopes,g.created_at FROM mcp_oauth_grants g JOIN mcp_oauth_clients c ON c.id=g.client_id JOIN sessions s ON s.id=g.session_id WHERE s.workspace_id=$1 AND s.user_id=$2 AND s.revoked_at IS NULL AND (s.expires_at IS NULL OR s.expires_at>clock_timestamp()) AND (s.absolute_expires_at IS NULL OR s.absolute_expires_at>clock_timestamp()) AND g.revoked_at IS NULL AND (g.expires_at IS NULL OR g.expires_at>clock_timestamp()) ORDER BY g.created_at DESC,g.id")
        .bind(auth.workspace_id).bind(auth.user_id).fetch_all(&mut *tx).await?;
    tx.commit().await?;
    Ok(rows
        .into_iter()
        .map(|row| Connection {
            id: row.get("id"),
            client_name: row.get("name"),
            scopes: row.get("scopes"),
            created_at: row.get("created_at"),
        })
        .collect())
}
async fn revoke_connection(state: &AppState, auth: &AuthContext, id: Uuid) -> Result<(), AppError> {
    let mut tx = auth.begin(&state.pool).await?;
    // Match token/tool lock ordering. Another workspace's grant is never locked.
    let found = sqlx::query("SELECT g.id FROM mcp_oauth_grants g JOIN sessions s ON s.id=g.session_id WHERE g.id=$1 AND s.user_id=$2 AND s.workspace_id=$3 FOR UPDATE OF g")
        .bind(id).bind(auth.user_id).bind(auth.workspace_id).fetch_optional(&mut *tx).await?;
    found.ok_or_else(AppError::not_found)?;
    auth.authorize_in_transaction(&mut tx).await?;
    sqlx::query(
        "UPDATE mcp_oauth_grants SET revoked_at=COALESCE(revoked_at,clock_timestamp()) WHERE id=$1",
    )
    .bind(id)
    .execute(&mut *tx)
    .await?;
    tx.commit().await?;
    Ok(())
}
pub(crate) async fn list(
    State(state): State<AppState>,
    auth: AuthContext,
) -> Result<Json<Vec<Connection>>, AppError> {
    Ok(Json(connections(&state, &auth).await?))
}
pub(crate) async fn revoke(
    State(state): State<AppState>,
    auth: AuthContext,
    Path(id): Path<Uuid>,
) -> Result<StatusCode, AppError> {
    revoke_connection(&state, &auth, id).await?;
    Ok(StatusCode::NO_CONTENT)
}
pub(crate) async fn browser_connections(
    State(state): State<AppState>,
    headers: HeaderMap,
) -> Result<Response, AppError> {
    let browser = match browser_session(&state, &headers).await {
        Ok(browser) => browser,
        Err(error) if error.status == StatusCode::UNAUTHORIZED => {
            return Ok(login_redirect("/mcp/connected"));
        }
        Err(error) => return Err(error),
    };
    let clients = connections(&state, &browser.auth).await?;
    let mut body = String::from(
        "<p>These assistants can access your workspace until you sign out or revoke access.</p>",
    );
    if clients.is_empty() {
        body.push_str("<p>No assistants are connected.</p>");
    }
    for client in clients {
        body.push_str(&format!("<section><h2>{}</h2><p>{}</p><p>Connected {}</p><form method=\"post\" action=\"/mcp/connections/{}/revoke\"><input type=\"hidden\" name=\"csrf_token\" value=\"{}\"><button type=\"submit\">Revoke access</button></form></section>",escape(&client.client_name),escape(&client.scopes.iter().map(|scope| crate::oauth::scope_description(scope)).collect::<Vec<_>>().join(", ")),client.created_at.format("%d %b %Y"),client.id,escape(&browser.csrf_token)));
    }
    body.push_str(&format!("<hr><form method=\"post\" action=\"/mcp/logout\"><input type=\"hidden\" name=\"csrf_token\" value=\"{}\"><button type=\"submit\">Sign out and revoke all assistants</button></form>",escape(&browser.csrf_token)));
    Ok(page("Connected assistants", &body))
}
#[derive(Deserialize)]
pub(crate) struct RevokeForm {
    csrf_token: String,
}
pub(crate) async fn browser_revoke(
    State(state): State<AppState>,
    Path(id): Path<Uuid>,
    headers: HeaderMap,
    Form(input): Form<RevokeForm>,
) -> Result<Response, AppError> {
    let browser = verify_browser_post(&state, &headers, &input.csrf_token).await?;
    revoke_connection(&state, &browser.auth, id).await?;
    Ok(no_store(Redirect::to("/mcp/connected").into_response()))
}
