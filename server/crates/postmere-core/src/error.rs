use axum::{
    Json,
    http::StatusCode,
    response::{IntoResponse, Response},
};
use serde::Serialize;

/// Public errors never include SQL, credentials, provider bodies, or internals.
#[derive(Debug, thiserror::Error)]
#[error("{code}: {message}")]
pub struct AppError {
    pub status: StatusCode,
    pub code: &'static str,
    pub message: String,
}

impl AppError {
    fn new(status: StatusCode, code: &'static str, message: impl Into<String>) -> Self {
        Self {
            status,
            code,
            message: message.into(),
        }
    }
    pub fn bad_request(message: &str) -> Self {
        Self::new(StatusCode::BAD_REQUEST, "bad_request", message)
    }
    pub fn unauthorized() -> Self {
        Self::new(
            StatusCode::UNAUTHORIZED,
            "unauthorized",
            "Authentication required or credentials invalid.",
        )
    }
    pub fn forbidden() -> Self {
        Self::new(
            StatusCode::FORBIDDEN,
            "forbidden",
            "You do not have permission for this action.",
        )
    }
    pub fn not_found() -> Self {
        Self::new(StatusCode::NOT_FOUND, "not_found", "Resource not found.")
    }
    pub fn conflict(message: &str) -> Self {
        Self::new(StatusCode::CONFLICT, "conflict", message)
    }
    pub fn rate_limited() -> Self {
        Self::new(
            StatusCode::TOO_MANY_REQUESTS,
            "rate_limited",
            "Too many requests. Try again later.",
        )
    }
    pub fn unavailable() -> Self {
        Self::new(
            StatusCode::SERVICE_UNAVAILABLE,
            "unavailable",
            "This service is temporarily unavailable.",
        )
    }
    pub fn internal(event: &'static str) -> Self {
        tracing::error!(event, "request failed");
        Self::new(
            StatusCode::INTERNAL_SERVER_ERROR,
            "internal",
            "The request could not be completed.",
        )
    }
}

impl From<sqlx::Error> for AppError {
    fn from(_: sqlx::Error) -> Self {
        Self::internal("database_operation")
    }
}

impl IntoResponse for AppError {
    fn into_response(self) -> Response {
        #[derive(Serialize)]
        struct ErrorBody<'a> {
            code: &'a str,
            message: &'a str,
        }
        #[derive(Serialize)]
        struct Envelope<'a> {
            error: ErrorBody<'a>,
        }
        let mut response = (
            self.status,
            Json(Envelope {
                error: ErrorBody {
                    code: self.code,
                    message: &self.message,
                },
            }),
        )
            .into_response();
        if self.status == StatusCode::UNAUTHORIZED {
            response
                .headers_mut()
                .insert("www-authenticate", "Bearer".parse().unwrap());
        }
        if self.status == StatusCode::TOO_MANY_REQUESTS {
            response
                .headers_mut()
                .insert("retry-after", "900".parse().unwrap());
        }
        response
    }
}
