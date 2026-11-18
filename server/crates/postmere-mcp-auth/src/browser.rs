use axum::{
    Form,
    extract::{ConnectInfo, Query, State},
    http::{HeaderMap, header},
    response::{Html, IntoResponse, Redirect, Response},
};
use chrono::{DateTime, Utc};
use postmere_core::{
    AppState,
    auth::{AuthContext, LoginRequest},
    error::AppError,
};
use serde::Deserialize;
use sqlx::Row;
use std::net::SocketAddr;
use uuid::Uuid;

use crate::{checked_hash, hash, random_token};

const BROWSER_COOKIE: &str = "postmere_mcp_browser";
const LOGIN_COOKIE: &str = "postmere_mcp_login";

pub struct BrowserSession {
    pub auth: AuthContext,
    pub csrf_token: String,
}

pub async fn browser_session(
    state: &AppState,
    headers: &HeaderMap,
) -> Result<BrowserSession, AppError> {
    let token = cookie(headers, BROWSER_COOKIE).ok_or_else(AppError::unauthorized)?;
    let row = sqlx::query("SELECT b.csrf_token,s.id,s.user_id,s.workspace_id,m.role FROM mcp_browser_sessions b JOIN sessions s ON s.id=b.session_id JOIN memberships m ON m.workspace_id=s.workspace_id AND m.user_id=s.user_id JOIN users u ON u.id=s.user_id JOIN workspaces w ON w.id=s.workspace_id WHERE b.token_hash=$1 AND b.expires_at>now() AND s.revoked_at IS NULL AND (s.expires_at IS NULL OR s.expires_at>now()) AND (s.absolute_expires_at IS NULL OR s.absolute_expires_at>now()) AND m.revoked_at IS NULL AND u.disabled_at IS NULL AND w.disabled_at IS NULL")
        .bind(checked_hash(&token, "")?).fetch_optional(&state.pool).await?.ok_or_else(AppError::unauthorized)?;
    Ok(BrowserSession {
        auth: AuthContext {
            session_id: row.get("id"),
            user_id: row.get("user_id"),
            workspace_id: row.get("workspace_id"),
            role: row.get("role"),
        },
        csrf_token: row.get("csrf_token"),
    })
}

pub async fn verify_browser_post(
    state: &AppState,
    headers: &HeaderMap,
    csrf: &str,
) -> Result<BrowserSession, AppError> {
    check_origin(state, headers)?;
    let session = browser_session(state, headers).await?;
    if !same_secret(csrf, &session.csrf_token) {
        return Err(AppError::forbidden());
    }
    Ok(session)
}

pub(crate) fn check_origin(state: &AppState, headers: &HeaderMap) -> Result<(), AppError> {
    if headers.get_all(header::ORIGIN).iter().count() != 1
        || headers.get(header::ORIGIN).and_then(|v| v.to_str().ok())
            != Some(
                state
                    .config
                    .public_base_url
                    .origin()
                    .ascii_serialization()
                    .as_str(),
            )
    {
        return Err(AppError::forbidden());
    }
    Ok(())
}

fn same_secret(left: &str, right: &str) -> bool {
    if left.len() != 43 || right.len() != 43 {
        return false;
    }
    hash(left)
        .iter()
        .zip(hash(right))
        .fold(0u8, |diff, (a, b)| diff | (a ^ b))
        == 0
}

fn cookie(headers: &HeaderMap, name: &str) -> Option<String> {
    let mut found = None;
    for header in headers.get_all(header::COOKIE) {
        for pair in header.to_str().ok()?.split(';') {
            let Some((key, value)) = pair.trim().split_once('=') else {
                continue;
            };
            if key == name {
                if found.is_some() {
                    return None;
                }
                found = Some(value.to_owned());
            }
        }
    }
    found
}

fn safe_next(next: &str) -> Option<&str> {
    if next == "/mcp/connected" {
        return Some(next);
    }
    for prefix in ["/mcp/consent/", "/mcp/approvals/"] {
        if let Some(id) = next.strip_prefix(prefix)
            && Uuid::parse_str(id).is_ok()
            && id.len() == 36
        {
            return Some(next);
        }
    }
    None
}

pub fn login_redirect(next: &str) -> Response {
    let next = safe_next(next).unwrap_or("/mcp/connected");
    let query = url::form_urlencoded::Serializer::new(String::new())
        .append_pair("next", next)
        .finish();
    no_store(Redirect::to(&format!("/mcp/login?{query}")).into_response())
}

#[derive(Default, Deserialize)]
pub(crate) struct LoginQuery {
    next: Option<String>,
}

pub(crate) async fn login_page(
    State(state): State<AppState>,
    Query(query): Query<LoginQuery>,
) -> Result<Response, AppError> {
    let next = query
        .next
        .as_deref()
        .and_then(safe_next)
        .unwrap_or("/mcp/connected");
    let csrf = random_token("")?;
    let mut response = login_form(&csrf, next, None);
    set_cookie(&mut response, &state, LOGIN_COOKIE, &csrf, 600)?;
    Ok(response)
}

#[derive(Deserialize)]
pub(crate) struct LoginForm {
    csrf_token: String,
    next: String,
    email: String,
    password: String,
    workspace_id: Uuid,
}

pub(crate) async fn login(
    State(state): State<AppState>,
    peer: Option<axum::Extension<ConnectInfo<SocketAddr>>>,
    headers: HeaderMap,
    Form(form): Form<LoginForm>,
) -> Result<Response, AppError> {
    check_origin(&state, &headers)?;
    let csrf = cookie(&headers, LOGIN_COOKIE).ok_or_else(AppError::forbidden)?;
    if !same_secret(&form.csrf_token, &csrf) {
        return Err(AppError::forbidden());
    }
    let next =
        safe_next(&form.next).ok_or_else(|| AppError::bad_request("Invalid return location."))?;
    let client = peer
        .map(|axum::Extension(ConnectInfo(addr))| addr.ip().to_string())
        .unwrap_or_else(|| "unknown-peer".into());
    let result = state
        .auth
        .login_browser(
            LoginRequest {
                email: form.email,
                password: form.password,
                workspace_id: form.workspace_id,
            },
            &client,
        )
        .await;
    let session = match result {
        Ok(session) => session,
        Err(error) => {
            let mut response = login_form(&csrf, next, Some(&error.message));
            *response.status_mut() = error.status;
            return Ok(response);
        }
    };
    let expires_at = session
        .expires_at
        .ok_or_else(|| AppError::internal("browser_session_lifetime"))?;
    let auth = AuthContext {
        user_id: session.user_id,
        workspace_id: session.workspace_id,
        session_id: session.session_id,
        role: session.role,
    };
    let mut tx = auth.begin_authorized(&state.pool).await?;
    let browser_token = random_token("")?;
    let browser_csrf = random_token("")?;
    sqlx::query("INSERT INTO mcp_browser_sessions(token_hash,session_id,csrf_token,expires_at) VALUES($1,$2,$3,$4)")
        .bind(hash(&browser_token)).bind(auth.session_id).bind(browser_csrf).bind(expires_at).execute(&mut *tx).await?;
    tx.commit().await?;
    // The workspace token returned by password login is deliberately discarded.
    // Browser and OAuth clients receive independent, narrowly accepted tokens.
    let mut response = no_store(Redirect::to(next).into_response());
    set_cookie(
        &mut response,
        &state,
        BROWSER_COOKIE,
        &browser_token,
        (expires_at - Utc::now()).num_seconds().max(0),
    )?;
    set_cookie(&mut response, &state, LOGIN_COOKIE, "", 0)?;
    Ok(response)
}

fn set_cookie(
    response: &mut Response,
    state: &AppState,
    name: &str,
    value: &str,
    age: i64,
) -> Result<(), AppError> {
    let secure = if state.config.public_base_url.scheme() == "https" {
        "; Secure"
    } else {
        ""
    };
    response.headers_mut().append(
        header::SET_COOKIE,
        format!("{name}={value}; Path=/mcp; HttpOnly; SameSite=Lax; Max-Age={age}{secure}")
            .parse()
            .map_err(|_| AppError::internal("mcp_cookie"))?,
    );
    Ok(())
}

fn login_form(csrf: &str, next: &str, error: Option<&str>) -> Response {
    page(
        "Sign in to Postmere",
        &format!(
            "<p>Sign in to your workspace to connect an assistant or approve an action.</p>{}<form method=\"post\" action=\"/mcp/login\"><input type=\"hidden\" name=\"csrf_token\" value=\"{}\"><input type=\"hidden\" name=\"next\" value=\"{}\"><label>Workspace ID<input name=\"workspace_id\" required autocomplete=\"off\"></label><label>Email<input type=\"email\" name=\"email\" required autocomplete=\"username\"></label><label>Password<input type=\"password\" name=\"password\" required autocomplete=\"current-password\"></label><button type=\"submit\">Sign in</button></form>",
            error
                .map(|e| format!("<p role=\"alert\">{}</p>", escape(e)))
                .unwrap_or_default(),
            escape(csrf),
            escape(next)
        ),
    )
}

#[derive(Deserialize)]
pub(crate) struct LogoutForm {
    csrf_token: String,
}
pub(crate) async fn logout(
    State(state): State<AppState>,
    headers: HeaderMap,
    Form(input): Form<LogoutForm>,
) -> Result<Response, AppError> {
    let browser = verify_browser_post(&state, &headers, &input.csrf_token).await?;
    postmere_core::auth::sign_out(&state, &browser.auth, None, true).await?;
    let mut response = page(
        "Signed out",
        "<p>Your assistant connections for this workspace have been revoked.</p><p><a href=\"/mcp/login\">Sign in again</a></p>",
    );
    set_cookie(&mut response, &state, BROWSER_COOKIE, "", 0)?;
    Ok(response)
}

pub(crate) fn escape(value: &str) -> String {
    value
        .replace('&', "&amp;")
        .replace('<', "&lt;")
        .replace('>', "&gt;")
        .replace('"', "&quot;")
        .replace('\'', "&#39;")
}

pub(crate) fn no_store(mut response: Response) -> Response {
    response
        .headers_mut()
        .insert(header::CACHE_CONTROL, "no-store".parse().unwrap());
    response
        .headers_mut()
        .insert("referrer-policy", "no-referrer".parse().unwrap());
    response
        .headers_mut()
        .insert("x-content-type-options", "nosniff".parse().unwrap());
    response
}
pub(crate) fn page(title: &str, body: &str) -> Response {
    let mut response = no_store(Html(format!("<!doctype html><html lang=\"en\"><meta charset=\"utf-8\"><meta name=\"viewport\" content=\"width=device-width,initial-scale=1\"><title>{} · Postmere</title><style>body{{background:#f5f4ef;color:#222f26;font:16px system-ui;margin:0;padding:40px 20px}}main{{max-width:560px;margin:5vh auto;background:white;border:1px solid #dedfd7;border-radius:16px;padding:32px}}h1{{font:30px Georgia,serif}}p,li{{line-height:1.6}}label{{display:block;margin:16px 0}}input{{box-sizing:border-box;width:100%;padding:10px;margin-top:6px;border:1px solid #bbb;border-radius:6px;font:inherit}}button{{padding:12px 20px;border:0;border-radius:7px;background:#264934;color:white;font:inherit;margin:8px 8px 0 0}}button[value=deny]{{background:#eee;color:#333}}small{{color:#666}}code{{overflow-wrap:anywhere}}</style><main><small>POSTMERE</small><h1>{}</h1>{body}</main></html>", escape(title), escape(title))).into_response());
    response.headers_mut().insert("content-security-policy", "default-src 'none'; style-src 'unsafe-inline'; form-action 'self'; frame-ancestors 'none'; base-uri 'none'".parse().unwrap());
    response
}

pub(crate) async fn session_expiry(
    tx: &mut sqlx::Transaction<'_, sqlx::Postgres>,
    auth: &AuthContext,
) -> Result<Option<DateTime<Utc>>, AppError> {
    let expires_at: Option<DateTime<Utc>> = sqlx::query_scalar(
        "SELECT LEAST(expires_at,absolute_expires_at) FROM sessions WHERE id=$1",
    )
    .bind(auth.session_id)
    .fetch_one(&mut **tx)
    .await?;
    Ok(expires_at)
}
