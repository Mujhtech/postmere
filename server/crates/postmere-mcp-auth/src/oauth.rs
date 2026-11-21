use axum::{
    Form, Json,
    extract::{ConnectInfo, Path, Query, State},
    http::{HeaderMap, StatusCode, header},
    response::{IntoResponse, Redirect, Response},
};
use base64::{
    Engine,
    engine::general_purpose::{STANDARD, URL_SAFE_NO_PAD},
};
use chrono::{DateTime, Duration, Utc};
use postmere_core::{AppState, auth::AuthContext, error::AppError};
use serde::Deserialize;
use serde_json::{Value, json};
use sha2::{Digest, Sha256};
use sqlx::{Postgres, Row, Transaction, postgres::PgRow};
use std::net::SocketAddr;
use uuid::Uuid;

use crate::{
    SCOPES,
    browser::{
        browser_session, escape, login_redirect, no_store, page, session_expiry,
        verify_browser_post,
    },
    checked_hash, endpoint, hash, issuer, random_token, resource, scopes,
};

pub(crate) async fn resource_metadata(State(state): State<AppState>) -> Json<Value> {
    Json(
        json!({"resource":resource(&state),"authorization_servers":[issuer(&state)],"scopes_supported":SCOPES,"bearer_methods_supported":["header"]}),
    )
}
pub(crate) async fn server_metadata(State(state): State<AppState>) -> Json<Value> {
    Json(json!({
        "issuer":issuer(&state), "authorization_endpoint":endpoint(&state,"mcp/authorize"),
        "token_endpoint":endpoint(&state,"mcp/token"), "registration_endpoint":endpoint(&state,"mcp/register"),
        "revocation_endpoint":endpoint(&state,"mcp/revoke"), "response_types_supported":["code"],
        "grant_types_supported":["authorization_code","refresh_token"], "scopes_supported":SCOPES,
        "token_endpoint_auth_methods_supported":["none","client_secret_basic"],
        "code_challenge_methods_supported":["S256"], "authorization_response_iss_parameter_supported":true
    }))
}

#[derive(Deserialize)]
pub(crate) struct Registration {
    client_name: String,
    redirect_uris: Vec<String>,
    token_endpoint_auth_method: Option<String>,
    grant_types: Option<Vec<String>>,
    response_types: Option<Vec<String>>,
}

fn client_address(peer: Option<axum::Extension<ConnectInfo<SocketAddr>>>) -> String {
    peer.map(|axum::Extension(ConnectInfo(address))| address.ip().to_string())
        .unwrap_or_else(|| "unknown-peer".into())
}

pub(crate) async fn register(
    State(state): State<AppState>,
    peer: Option<axum::Extension<ConnectInfo<SocketAddr>>>,
    Json(input): Json<Registration>,
) -> Result<Response, AppError> {
    state
        .auth
        .rate_limit("mcp_registration", &client_address(peer), 30)
        .await?;
    let method = input
        .token_endpoint_auth_method
        .as_deref()
        .unwrap_or("client_secret_basic");
    let name = input.client_name.trim();
    if name.is_empty()
        || name.len() > 120
        || name.chars().any(char::is_control)
        || !["none", "client_secret_basic"].contains(&method)
        || input.redirect_uris.is_empty()
        || input.redirect_uris.len() > 8
        || input.redirect_uris.iter().any(|uri| {
            !postmere_core::config::mcp_redirect_allowed(&state.config.mcp_redirect_uris, uri)
        })
        || input.grant_types.as_ref().is_some_and(|v| {
            v.is_empty()
                || v.iter()
                    .any(|t| !["authorization_code", "refresh_token"].contains(&t.as_str()))
        })
        || input
            .response_types
            .as_ref()
            .is_some_and(|v| v != &["code"])
    {
        return Ok(oauth_error("invalid_client_metadata"));
    }
    let client_id = Uuid::new_v4().to_string();
    let secret = if method == "client_secret_basic" {
        Some(random_token("pm_mcs_")?)
    } else {
        None
    };
    sqlx::query("INSERT INTO mcp_oauth_clients(id,name,redirect_uris,auth_method,secret_hash) VALUES($1,$2,$3,$4,$5)")
        .bind(&client_id).bind(name).bind(&input.redirect_uris).bind(method).bind(secret.as_deref().map(hash)).execute(&state.pool).await?;
    let mut body = json!({"client_id":client_id,"client_id_issued_at":Utc::now().timestamp(),"client_name":name,"redirect_uris":input.redirect_uris,
        "token_endpoint_auth_method":method,"grant_types":["authorization_code","refresh_token"],"response_types":["code"]});
    if let Some(secret) = secret {
        body["client_secret"] = json!(secret);
        body["client_secret_expires_at"] = json!(0);
    }
    Ok(no_store((StatusCode::CREATED, Json(body)).into_response()))
}

#[derive(Deserialize)]
pub(crate) struct Authorize {
    response_type: String,
    client_id: String,
    redirect_uri: String,
    resource: String,
    scope: Option<String>,
    state: Option<String>,
    code_challenge: String,
    code_challenge_method: String,
}

pub(crate) async fn authorize(
    State(state): State<AppState>,
    peer: Option<axum::Extension<ConnectInfo<SocketAddr>>>,
    headers: HeaderMap,
    Query(input): Query<Authorize>,
) -> Result<Response, AppError> {
    state
        .auth
        .rate_limit("mcp_authorize", &client_address(peer), 120)
        .await?;
    if input.response_type != "code"
        || input.resource != resource(&state)
        || input.code_challenge_method != "S256"
        || checked_hash(&input.code_challenge, "").is_err()
        || input.state.as_ref().is_some_and(|s| s.len() > 2048)
        || input.client_id.len() > 120
        || !postmere_core::config::mcp_redirect_allowed(
            &state.config.mcp_redirect_uris,
            &input.redirect_uri,
        )
    {
        return Ok(oauth_error("invalid_request"));
    }
    let allowed: bool = sqlx::query_scalar(
        "SELECT EXISTS(SELECT 1 FROM mcp_oauth_clients WHERE id=$1 AND $2=ANY(redirect_uris))",
    )
    .bind(&input.client_id)
    .bind(&input.redirect_uri)
    .fetch_one(&state.pool)
    .await?;
    // Do not redirect on an invalid/unregistered URI, including error responses.
    if !allowed {
        return Ok(oauth_error("invalid_request"));
    }
    let requested = match scopes(input.scope.as_deref().unwrap_or("mail:read")) {
        Ok(s) => s,
        Err(_) => return Ok(oauth_error("invalid_scope")),
    };
    let browser = match browser_session(&state, &headers).await {
        Ok(b) => Some(b),
        Err(e) if e.status == StatusCode::UNAUTHORIZED => None,
        Err(e) => return Err(e),
    };
    let id = Uuid::new_v4();
    sqlx::query("INSERT INTO mcp_oauth_requests(id,client_id,redirect_uri,resource,scopes,state,code_challenge,session_id,expires_at) VALUES($1,$2,$3,$4,$5,$6,$7,$8,now()+interval '10 minutes')")
        .bind(id).bind(input.client_id).bind(input.redirect_uri).bind(input.resource).bind(requested).bind(input.state.unwrap_or_default())
        .bind(input.code_challenge).bind(browser.map(|b|b.auth.session_id)).execute(&state.pool).await?;
    Ok(no_store(
        Redirect::to(&format!("/mcp/consent/{id}")).into_response(),
    ))
}

async fn request_for_browser(
    tx: &mut Transaction<'_, Postgres>,
    id: Uuid,
    auth: &AuthContext,
) -> Result<PgRow, AppError> {
    let row = sqlx::query("SELECT r.*,c.name FROM mcp_oauth_requests r JOIN mcp_oauth_clients c ON c.id=r.client_id WHERE r.id=$1 AND r.used_at IS NULL AND r.expires_at>now() FOR UPDATE OF r")
        .bind(id).fetch_optional(&mut **tx).await?.ok_or_else(||AppError::bad_request("This connection request expired. Start again from your assistant."))?;
    if row.get::<DateTime<Utc>, _>("expires_at") <= Utc::now() {
        return Err(AppError::bad_request(
            "This connection request expired. Start again from your assistant.",
        ));
    }
    if row
        .get::<Option<Uuid>, _>("session_id")
        .is_some_and(|s| s != auth.session_id)
    {
        return Err(AppError::forbidden());
    }
    sqlx::query("UPDATE mcp_oauth_requests SET session_id=$1 WHERE id=$2")
        .bind(auth.session_id)
        .bind(id)
        .execute(&mut **tx)
        .await?;
    Ok(row)
}

pub(crate) async fn consent(
    State(state): State<AppState>,
    Path(id): Path<Uuid>,
    headers: HeaderMap,
) -> Result<Response, AppError> {
    let browser = match browser_session(&state, &headers).await {
        Ok(b) => b,
        Err(e) if e.status == StatusCode::UNAUTHORIZED => {
            return Ok(login_redirect(&format!("/mcp/consent/{id}")));
        }
        Err(e) => return Err(e),
    };
    let mut tx = browser.auth.begin_authorized(&state.pool).await?;
    let row = request_for_browser(&mut tx, id, &browser.auth).await?;
    let email: String = sqlx::query_scalar("SELECT email FROM users WHERE id=$1")
        .bind(browser.auth.user_id)
        .fetch_one(&mut *tx)
        .await?;
    let workspace: String = sqlx::query_scalar("SELECT name FROM workspaces WHERE id=$1")
        .bind(browser.auth.workspace_id)
        .fetch_one(&mut *tx)
        .await?;
    tx.commit().await?;
    let descriptions = row
        .get::<Vec<String>, _>("scopes")
        .iter()
        .map(|scope| format!("<li>{}</li>", scope_description(scope)))
        .collect::<String>();
    Ok(page(
        "Connect your assistant",
        &format!(
            "<p><strong>{}</strong> wants access to <strong>{}</strong> in workspace <strong>{}</strong>.</p><ul>{descriptions}</ul><p>Sending mail and other sensitive changes require your separate approval. Access stays connected until you sign out of this workspace or revoke access.</p><p>Return address: <code>{}</code></p><form method=\"post\" action=\"/mcp/consent/{id}\"><input type=\"hidden\" name=\"csrf_token\" value=\"{}\"><button name=\"decision\" value=\"approve\">Allow access</button><button name=\"decision\" value=\"deny\">Cancel</button></form>",
            escape(row.get::<String, _>("name").as_str()),
            escape(&email),
            escape(&workspace),
            escape(row.get::<String, _>("redirect_uri").as_str()),
            escape(&browser.csrf_token)
        ),
    ))
}

pub(crate) fn scope_description(scope: &str) -> &'static str {
    match scope {
        "mail:read" => "Read and search your mail",
        "mail:draft" => "Create and edit drafts",
        "mail:manage" => "Manage messages and mailbox state",
        "mail:send" => "Request sending mail, subject to your approval",
        _ => "Unknown permission",
    }
}
#[derive(Deserialize)]
pub(crate) struct Decision {
    csrf_token: String,
    decision: String,
}

pub(crate) async fn decide(
    State(state): State<AppState>,
    Path(id): Path<Uuid>,
    headers: HeaderMap,
    Form(input): Form<Decision>,
) -> Result<Response, AppError> {
    let browser = verify_browser_post(&state, &headers, &input.csrf_token).await?;
    if !["approve", "deny"].contains(&input.decision.as_str()) {
        return Err(AppError::bad_request("Choose Allow access or Cancel."));
    }
    let mut tx = browser.auth.begin_authorized(&state.pool).await?;
    let row = request_for_browser(&mut tx, id, &browser.auth).await?;
    let redirect: String = row.get("redirect_uri");
    if !postmere_core::config::mcp_redirect_allowed(&state.config.mcp_redirect_uris, &redirect)
        || row.get::<String, _>("resource") != resource(&state)
    {
        return Err(AppError::forbidden());
    }
    sqlx::query("UPDATE mcp_oauth_requests SET used_at=now() WHERE id=$1")
        .bind(id)
        .execute(&mut *tx)
        .await?;
    let mut target = url::Url::parse(&redirect).map_err(|_| AppError::internal("mcp_redirect"))?;
    if input.decision == "approve" {
        // Each grant owns an independent, persistent sign-in. The browser
        // cookie and its bounded approval session cannot expire this grant.
        let grant_session = Uuid::new_v4();
        sqlx::query("INSERT INTO sessions(id,workspace_id,user_id,token_hash,expires_at,absolute_expires_at,kind,created_at) VALUES($1,$2,$3,$4,NULL,NULL,'mcp_grant',clock_timestamp())")
            .bind(grant_session).bind(browser.auth.workspace_id).bind(browser.auth.user_id)
            .bind(hash(&random_token("")?)).execute(&mut *tx).await?;
        let expiry: Option<DateTime<Utc>> = None;
        let grant_id = Uuid::new_v4();
        let code = random_token("pm_mcc_")?;
        sqlx::query("INSERT INTO mcp_oauth_grants(id,session_id,client_id,resource,scopes,expires_at) VALUES($1,$2,$3,$4,$5,$6)")
            .bind(grant_id).bind(grant_session).bind(row.get::<String,_>("client_id")).bind(resource(&state)).bind(row.get::<Vec<String>,_>("scopes")).bind(expiry).execute(&mut *tx).await?;
        sqlx::query("INSERT INTO mcp_oauth_codes(token_hash,grant_id,redirect_uri,code_challenge,expires_at) VALUES($1,$2,$3,$4,$5)")
            .bind(hash(&code)).bind(grant_id).bind(&redirect).bind(row.get::<String,_>("code_challenge")).bind(Utc::now()+Duration::minutes(5)).execute(&mut *tx).await?;
        target.query_pairs_mut().append_pair("code", &code);
    } else {
        target
            .query_pairs_mut()
            .append_pair("error", "access_denied");
    }
    let client_state: String = row.get("state");
    if !client_state.is_empty() {
        target.query_pairs_mut().append_pair("state", &client_state);
    }
    target.query_pairs_mut().append_pair("iss", &issuer(&state));
    tx.commit().await?;
    Ok(no_store(Redirect::to(target.as_str()).into_response()))
}

#[derive(Deserialize)]
pub(crate) struct TokenInput {
    grant_type: String,
    client_id: Option<String>,
    code: Option<String>,
    redirect_uri: Option<String>,
    code_verifier: Option<String>,
    refresh_token: Option<String>,
    resource: Option<String>,
    scope: Option<String>,
    client_secret: Option<String>,
}

#[derive(Debug)]
struct OAuthFailure(&'static str);
impl From<AppError> for OAuthFailure {
    fn from(error: AppError) -> Self {
        if error.status == StatusCode::UNAUTHORIZED || error.status == StatusCode::FORBIDDEN {
            Self("invalid_grant")
        } else {
            Self("server_error")
        }
    }
}
impl From<sqlx::Error> for OAuthFailure {
    fn from(error: sqlx::Error) -> Self {
        AppError::from(error).into()
    }
}

fn oauth_error(code: &'static str) -> Response {
    let status = match code {
        "invalid_client" => StatusCode::UNAUTHORIZED,
        "server_error" => StatusCode::INTERNAL_SERVER_ERROR,
        _ => StatusCode::BAD_REQUEST,
    };
    let mut response = no_store((status, Json(json!({"error":code}))).into_response());
    if code == "invalid_client" {
        response.headers_mut().insert(
            header::WWW_AUTHENTICATE,
            "Basic realm=\"Postmere MCP\"".parse().unwrap(),
        );
    }
    response
}

async fn authenticate_client(
    state: &AppState,
    headers: &HeaderMap,
    body_id: Option<&str>,
    body_secret: Option<&str>,
) -> Result<String, OAuthFailure> {
    if body_secret.is_some() || headers.get_all(header::AUTHORIZATION).iter().count() > 1 {
        return Err(OAuthFailure("invalid_client"));
    }
    let credentials = match headers.get(header::AUTHORIZATION) {
        Some(value) => {
            let value = value
                .to_str()
                .ok()
                .and_then(|v| v.strip_prefix("Basic "))
                .ok_or(OAuthFailure("invalid_client"))?;
            let decoded = STANDARD
                .decode(value)
                .ok()
                .and_then(|b| String::from_utf8(b).ok())
                .ok_or(OAuthFailure("invalid_client"))?;
            let (id, secret) = decoded
                .split_once(':')
                .ok_or(OAuthFailure("invalid_client"))?;
            if body_id.is_some_and(|body| body != id) {
                return Err(OAuthFailure("invalid_client"));
            }
            (id.to_string(), Some(secret.to_string()))
        }
        None => (
            body_id.ok_or(OAuthFailure("invalid_client"))?.to_string(),
            None,
        ),
    };
    if credentials.0.len() > 120 || credentials.1.as_ref().is_some_and(|s| s.len() > 256) {
        return Err(OAuthFailure("invalid_client"));
    }
    let valid:bool=sqlx::query_scalar("SELECT EXISTS(SELECT 1 FROM mcp_oauth_clients WHERE id=$1 AND ((auth_method='none' AND $2::bytea IS NULL) OR (auth_method='client_secret_basic' AND secret_hash=$2)))")
        .bind(&credentials.0).bind(credentials.1.as_deref().map(hash)).fetch_one(&state.pool).await?;
    if !valid {
        return Err(OAuthFailure("invalid_client"));
    }
    Ok(credentials.0)
}

pub(crate) async fn token(
    State(state): State<AppState>,
    peer: Option<axum::Extension<ConnectInfo<SocketAddr>>>,
    headers: HeaderMap,
    input: Result<Form<TokenInput>, axum::extract::rejection::FormRejection>,
) -> Response {
    let Ok(Form(input)) = input else {
        return oauth_error("invalid_request");
    };
    if let Err(error) = state
        .auth
        .rate_limit("mcp_token", &client_address(peer), 120)
        .await
    {
        return error.into_response();
    }
    match exchange(&state, &headers, input).await {
        Ok(body) => no_store(Json(body).into_response()),
        Err(error) => oauth_error(error.0),
    }
}

async fn grant_auth(state: &AppState, grant: Uuid) -> Result<AuthContext, OAuthFailure> {
    let row=sqlx::query("SELECT s.id,s.user_id,s.workspace_id,m.role FROM mcp_oauth_grants g JOIN sessions s ON s.id=g.session_id JOIN memberships m ON m.workspace_id=s.workspace_id AND m.user_id=s.user_id WHERE g.id=$1")
        .bind(grant).fetch_optional(&state.pool).await?.ok_or(OAuthFailure("invalid_grant"))?;
    Ok(AuthContext {
        assistant: false,
        session_id: row.get("id"),
        user_id: row.get("user_id"),
        workspace_id: row.get("workspace_id"),
        role: row.get("role"),
    })
}

async fn exchange(
    state: &AppState,
    headers: &HeaderMap,
    input: TokenInput,
) -> Result<Value, OAuthFailure> {
    let client = authenticate_client(
        state,
        headers,
        input.client_id.as_deref(),
        input.client_secret.as_deref(),
    )
    .await?;
    if input.resource.as_deref() != Some(resource(state).as_str()) {
        return Err(OAuthFailure("invalid_target"));
    }
    let (table, prefix, value) = match input.grant_type.as_str() {
        "authorization_code" => ("mcp_oauth_codes", "pm_mcc_", input.code.as_deref()),
        "refresh_token" => (
            "mcp_refresh_tokens",
            "pm_mcr_",
            input.refresh_token.as_deref(),
        ),
        _ => return Err(OAuthFailure("unsupported_grant_type")),
    };
    let token_hash = checked_hash(value.ok_or(OAuthFailure("invalid_request"))?, prefix)
        .map_err(|_| OAuthFailure("invalid_grant"))?;
    let grant: Uuid = if table == "mcp_oauth_codes" {
        sqlx::query_scalar("SELECT grant_id FROM mcp_oauth_codes WHERE token_hash=$1")
    } else {
        sqlx::query_scalar("SELECT grant_id FROM mcp_refresh_tokens WHERE token_hash=$1")
    }
    .bind(&token_hash)
    .fetch_optional(&state.pool)
    .await?
    .ok_or(OAuthFailure("invalid_grant"))?;
    let auth = grant_auth(state, grant).await?;
    // Match tool execution's grant -> identity order. Acquiring identity first
    // can deadlock with an in-flight tool plus a queued membership revocation.
    let mut tx = auth.begin(&state.pool).await?;
    let grant_row=sqlx::query("SELECT * FROM mcp_oauth_grants WHERE id=$1 AND client_id=$2 AND resource=$3 AND revoked_at IS NULL AND (expires_at IS NULL OR expires_at>now()) FOR UPDATE")
        .bind(grant).bind(client).bind(resource(state)).fetch_optional(&mut *tx).await?.ok_or(OAuthFailure("invalid_grant"))?;
    let row = if table == "mcp_oauth_codes" {
        sqlx::query("SELECT * FROM mcp_oauth_codes WHERE token_hash=$1 FOR UPDATE")
    } else {
        sqlx::query("SELECT * FROM mcp_refresh_tokens WHERE token_hash=$1 FOR UPDATE")
    }
    .bind(&token_hash)
    .fetch_optional(&mut *tx)
    .await?
    .ok_or(OAuthFailure("invalid_grant"))?;
    auth.authorize_in_transaction(&mut tx).await?;
    if grant_row
        .get::<Option<DateTime<Utc>>, _>("expires_at")
        .is_some_and(|expiry| expiry <= Utc::now())
    {
        return Err(OAuthFailure("invalid_grant"));
    }
    if table == "mcp_oauth_codes" {
        let verifier = input
            .code_verifier
            .as_deref()
            .ok_or(OAuthFailure("invalid_request"))?;
        if !(43..=128).contains(&verifier.len())
            || !verifier
                .bytes()
                .all(|b| b.is_ascii_alphanumeric() || b"-._~".contains(&b))
            || URL_SAFE_NO_PAD.encode(Sha256::digest(verifier.as_bytes()))
                != row.get::<String, _>("code_challenge")
            || input.redirect_uri.as_deref() != Some(row.get::<String, _>("redirect_uri").as_str())
        {
            return Err(OAuthFailure("invalid_grant"));
        }
    }
    if row.get::<Option<DateTime<Utc>>, _>("used_at").is_some() {
        // Serialize the family on the grant row. Reusing any spent refresh/code
        // revokes its descendants, including a simultaneously rotated token.
        // A spent code still detects replay after its five-minute expiry.
        sqlx::query("UPDATE mcp_oauth_grants SET revoked_at=now() WHERE id=$1")
            .bind(grant)
            .execute(&mut *tx)
            .await?;
        tx.commit().await?;
        return Err(OAuthFailure("invalid_grant"));
    }
    if row
        .get::<Option<DateTime<Utc>>, _>("expires_at")
        .is_some_and(|expiry| expiry <= Utc::now())
    {
        return Err(OAuthFailure("invalid_grant"));
    }
    let granted = grant_row.get::<Vec<String>, _>("scopes");
    let requested = match input.scope {
        Some(value) => {
            let requested = scopes(&value).map_err(|_| OAuthFailure("invalid_scope"))?;
            if requested.iter().any(|s| !granted.contains(s)) {
                return Err(OAuthFailure("invalid_scope"));
            }
            requested
        }
        None => granted,
    };
    // Scope reduction is permanent for the grant and all subsequent refreshes.
    sqlx::query("UPDATE mcp_oauth_grants SET scopes=$1 WHERE id=$2")
        .bind(&requested)
        .bind(grant)
        .execute(&mut *tx)
        .await?;
    if table == "mcp_oauth_codes" {
        sqlx::query("UPDATE mcp_oauth_codes SET used_at=now() WHERE token_hash=$1")
    } else {
        sqlx::query("UPDATE mcp_refresh_tokens SET used_at=now() WHERE token_hash=$1")
    }
    .bind(token_hash)
    .execute(&mut *tx)
    .await?;
    let expires = match (
        grant_row.get::<Option<DateTime<Utc>>, _>("expires_at"),
        session_expiry(&mut tx, &auth).await?,
    ) {
        (Some(a), Some(b)) => Some(a.min(b)),
        (a, b) => a.or(b),
    };
    let response = issue_tokens(&mut tx, grant, &requested, expires).await?;
    tx.commit().await?;
    Ok(response)
}

async fn issue_tokens(
    tx: &mut Transaction<'_, Postgres>,
    grant: Uuid,
    scopes: &[String],
    expiry: Option<DateTime<Utc>>,
) -> Result<Value, OAuthFailure> {
    let access = random_token("pm_mcp_")?;
    let refresh = random_token("pm_mcr_")?;
    let access_limit = Utc::now() + Duration::minutes(15);
    let access_expiry = expiry.map_or(access_limit, |limit| limit.min(access_limit));
    if access_expiry <= Utc::now() {
        return Err(OAuthFailure("invalid_grant"));
    }
    sqlx::query("INSERT INTO mcp_access_tokens(token_hash,grant_id,expires_at) VALUES($1,$2,$3)")
        .bind(hash(&access))
        .bind(grant)
        .bind(access_expiry)
        .execute(&mut **tx)
        .await?;
    sqlx::query("INSERT INTO mcp_refresh_tokens(token_hash,grant_id,expires_at) VALUES($1,$2,$3)")
        .bind(hash(&refresh))
        .bind(grant)
        .bind(expiry)
        .execute(&mut **tx)
        .await?;
    Ok(
        json!({"access_token":access,"token_type":"Bearer","expires_in":(access_expiry-Utc::now()).num_seconds().max(0),"refresh_token":refresh,"scope":scopes.join(" ")}),
    )
}

#[derive(Deserialize)]
pub(crate) struct RevokeInput {
    client_id: Option<String>,
    client_secret: Option<String>,
    token: String,
}
pub(crate) async fn revoke(
    State(state): State<AppState>,
    peer: Option<axum::Extension<ConnectInfo<SocketAddr>>>,
    headers: HeaderMap,
    Form(input): Form<RevokeInput>,
) -> Response {
    if let Err(error) = state
        .auth
        .rate_limit("mcp_revoke", &client_address(peer), 120)
        .await
    {
        return error.into_response();
    }
    let result:Result<(),OAuthFailure>=async {
        let client=authenticate_client(&state,&headers,input.client_id.as_deref(),input.client_secret.as_deref()).await?;
        if input.token.len()>256 {return Ok(());}
        sqlx::query("UPDATE mcp_oauth_grants SET revoked_at=COALESCE(revoked_at,now()) WHERE client_id=$1 AND id IN (SELECT grant_id FROM mcp_access_tokens WHERE token_hash=$2 UNION SELECT grant_id FROM mcp_refresh_tokens WHERE token_hash=$2)")
            .bind(client).bind(hash(&input.token)).execute(&state.pool).await?;
        Ok(())
    }.await;
    match result {
        Ok(()) => no_store(StatusCode::OK.into_response()),
        Err(e) => oauth_error(e.0),
    }
}
