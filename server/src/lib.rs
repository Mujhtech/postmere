//! HTTP composition and common request boundaries for the Postmere server.
//! Feature behavior lives in workspace crates with explicit dependencies.
use axum::{
    Router,
    extract::{DefaultBodyLimit, State},
    http::{HeaderValue, StatusCode, header},
    middleware::{self, Next},
    response::{IntoResponse, Response},
    routing::get,
};
use postmere_core::{AppState, auth, error::AppError};
use serde::Serialize;
use std::time::Duration;
use tower_http::timeout::TimeoutLayer;

/// Compose the production feature routes in one place.
pub fn feature_routes() -> Router<AppState> {
    postmere_mail::mail::router()
        .merge(postmere_tracking::router())
        .merge(postmere_collaboration::router())
        .merge(postmere_ai::router())
        .merge(postmere_unsubscribe::router())
        .merge(postmere_calendar::router())
        .merge(postmere_mcp::router())
        .merge(postmere_realtime::router())
        .merge(postmere_push::router())
        .merge(postmere_webhooks::router())
}

pub fn router() -> Router<AppState> {
    Router::new()
        .route("/health/live", get(live))
        .route("/health/ready", get(ready))
        .merge(auth::router())
}

/// Merge feature routers before applying the common request/security boundary.
pub fn application(state: AppState, feature_routes: Router<AppState>) -> Router {
    router()
        .merge(feature_routes)
        .fallback(|| async { AppError::not_found() })
        .layer(DefaultBodyLimit::max(state.config.max_body_bytes))
        .layer(TimeoutLayer::with_status_code(
            StatusCode::REQUEST_TIMEOUT,
            Duration::from_secs(30),
        ))
        .layer(middleware::from_fn(response_headers))
        .with_state(state)
}

#[derive(Serialize)]
struct Health {
    status: &'static str,
}

async fn live() -> impl IntoResponse {
    axum::Json(Health { status: "live" })
}

async fn ready(State(state): State<AppState>) -> Result<impl IntoResponse, AppError> {
    sqlx::query("SELECT 1")
        .execute(&state.pool)
        .await
        .map_err(|_| AppError::unavailable())?;
    Ok(axum::Json(Health { status: "ready" }))
}

async fn response_headers(request: axum::extract::Request, next: Next) -> Response {
    let mut response = next.run(request).await;
    let headers = response.headers_mut();
    headers.insert(header::CACHE_CONTROL, HeaderValue::from_static("no-store"));
    headers.insert(
        header::X_CONTENT_TYPE_OPTIONS,
        HeaderValue::from_static("nosniff"),
    );
    headers.insert(
        header::REFERRER_POLICY,
        HeaderValue::from_static("no-referrer"),
    );
    if !headers.contains_key(header::CONTENT_SECURITY_POLICY) {
        headers.insert(
            header::CONTENT_SECURITY_POLICY,
            HeaderValue::from_static("default-src 'none'; frame-ancestors 'none'"),
        );
    }
    response
}
