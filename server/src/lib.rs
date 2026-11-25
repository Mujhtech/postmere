//! HTTP composition and common request boundaries for the Postmere server.
//! Feature behavior lives in workspace crates with explicit dependencies.
use axum::{
    Router,
    extract::{DefaultBodyLimit, Request, State},
    http::{HeaderValue, Method, StatusCode, header},
    middleware::{self, Next},
    response::{IntoResponse, Response},
    routing::get,
};
use postmere_core::{AppState, auth, error::AppError};
use serde::Serialize;
use std::time::Duration;

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
        .merge(postmere_plugins::router())
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
        .layer(middleware::from_fn(request_deadline))
        .layer(middleware::from_fn(response_headers))
        .with_state(state)
}

async fn request_deadline(request: Request, next: Next) -> Response {
    let path = request.uri().path();
    let researches_sender = request.method() == Method::POST
        && path.starts_with("/v1/mail/messages/")
        && path.ends_with("/sender-profile");
    let generates_mail_assistance = request.method() == Method::POST
        && (matches!(
            path,
            "/v1/ai/summary"
                | "/v1/decisions/triage"
                | "/v1/ai/draft"
                | "/v1/ai/ask"
                | "/v1/ai/suggestions"
                | "/v1/decisions/spam"
        ) || (path.starts_with("/v1/mail/messages/") && path.ends_with("/sender-profile")));
    // Allow the model's 90s deadline plus time to load the authorized messages.
    // Once headers are sent, streaming bodies follow the provider's deadline.
    // Sender research runs several web searches: 155s plus loading.
    let seconds = if researches_sender {
        170
    } else if generates_mail_assistance {
        105
    } else {
        30
    };
    match tokio::time::timeout(Duration::from_secs(seconds), next.run(request)).await {
        Ok(response) => response,
        Err(_) if generates_mail_assistance => AppError {
            retry_after_seconds: None,
            status: StatusCode::GATEWAY_TIMEOUT,
            code: "ai_timeout",
            message: "The AI request timed out. Try again.".into(),
        }
        .into_response(),
        Err(_) => StatusCode::REQUEST_TIMEOUT.into_response(),
    }
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

async fn response_headers(request: Request, next: Next) -> Response {
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

#[cfg(test)]
mod tests {
    use super::*;
    use axum::{body::Body, routing::post};
    use tower::ServiceExt;

    #[tokio::test(start_paused = true)]
    async fn slow_generation_has_its_own_deadline() {
        let delayed = || async { tokio::time::sleep(Duration::from_secs(60)).await };
        let app = Router::new()
            .route("/v1/ai/summary", post(delayed))
            .route("/v1/decisions/spam", post(delayed))
            .route("/v1/mail/messages/{id}/sender-profile", post(delayed))
            .route("/v1/ai/settings", get(delayed))
            .route("/v1/ai/draft", post(std::future::pending::<()>))
            .layer(middleware::from_fn(request_deadline));
        for (method, path, expected) in [
            (Method::POST, "/v1/ai/summary", StatusCode::OK),
            (Method::POST, "/v1/decisions/spam", StatusCode::OK),
            (
                Method::POST,
                "/v1/mail/messages/00000000-0000-0000-0000-000000000001/sender-profile",
                StatusCode::OK,
            ),
            (Method::GET, "/v1/ai/settings", StatusCode::REQUEST_TIMEOUT),
            (Method::POST, "/v1/ai/draft", StatusCode::GATEWAY_TIMEOUT),
        ] {
            let request = Request::builder()
                .method(method)
                .uri(path)
                .body(Body::empty())
                .unwrap();
            let response = app.clone().oneshot(request).await.unwrap();
            assert_eq!(response.status(), expected, "{path}");
        }
    }
}
