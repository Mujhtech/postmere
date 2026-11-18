use std::sync::Arc;

use axum::{
    body::{Body, to_bytes},
    extract::{Request, State},
    http::{HeaderValue, Method, StatusCode, header},
    response::{IntoResponse, Response},
};
use postmere_core::{AppState, error::AppError};
use rmcp::transport::streamable_http_server::{
    StreamableHttpServerConfig, StreamableHttpService, session::never::NeverSessionManager,
};
use serde_json::Value;
use url::Url;

use crate::{catalog, server::PostmereMcp};

const MAX_REQUEST_BYTES: usize = 1024 * 1024;
// Each tool holds a grant transaction while its domain transaction runs.
// Reserve pool capacity for those second connections and for mail workers.
static IN_FLIGHT: tokio::sync::Semaphore = tokio::sync::Semaphore::const_new(6);

pub async fn endpoint(State(state): State<AppState>, request: Request) -> Response {
    if let Err(error) = validate_envelope(&state, &request) {
        return error.into_response();
    }
    let Ok(_permit) = IN_FLIGHT.try_acquire() else {
        return AppError::rate_limited().into_response();
    };
    let (mut parts, body) = request.into_parts();
    let bytes = match to_bytes(body, MAX_REQUEST_BYTES).await {
        Ok(bytes) => bytes,
        Err(_) => {
            return (StatusCode::PAYLOAD_TOO_LARGE, "MCP request exceeds 1 MiB.").into_response();
        }
    };
    // Authenticate after receiving the bounded body; a slow upload cannot hold
    // an earlier identity snapshot alive. Credentials never enter tool inputs.
    let principal = match postmere_mcp_auth::authenticate(&state, &parts.headers).await {
        Ok(principal) => principal,
        Err(error) => return challenge(&state, error, None),
    };
    if let Err(error) = state
        .auth
        .rate_limit("mcp_request", &principal.grant_id.to_string(), 900)
        .await
    {
        return error.into_response();
    }
    if parts.method == Method::POST {
        // OAuth scope challenges must be HTTP 403 responses, so inspect only
        // the routing fields here; the SDK performs protocol/schema validation.
        if let Ok(value) = serde_json::from_slice::<Value>(&bytes)
            && value.get("method").and_then(Value::as_str) == Some("tools/call")
            && let Some(name) = value.pointer("/params/name").and_then(Value::as_str)
            && let Some(scope) = catalog::required_scope(name)
            && let Err(error) = principal.require_scope(scope)
        {
            let mut requested = principal.scopes.clone();
            requested.insert(scope.into());
            return challenge(
                &state,
                error,
                Some(&requested.into_iter().collect::<Vec<_>>().join(" ")),
            );
        }
    }
    parts.extensions.insert(principal);
    let public = &state.config.public_base_url;
    let host = public.host_str().expect("validated public URL").to_string();
    let port = public.port_or_known_default().expect("HTTP public URL");
    let origin = format!("{}://{host}:{port}", public.scheme());
    let config = StreamableHttpServerConfig::default()
        .with_legacy_session_mode(false)
        .with_json_response(true)
        .with_max_request_body_bytes(MAX_REQUEST_BYTES)
        .with_allowed_hosts([host])
        .with_allowed_origins([origin])
        .enforce_origin_validation();
    // No caller-specific handler or MCP session survives this request.
    let service = StreamableHttpService::new(
        move || Ok(PostmereMcp::new(state.clone())),
        Arc::new(NeverSessionManager::default()),
        config,
    );
    service
        .handle(Request::from_parts(parts, Body::from(bytes)))
        .await
        .map(Body::new)
}

fn validate_envelope(state: &AppState, request: &Request) -> Result<(), AppError> {
    let headers = request.headers();
    if headers.get_all(header::HOST).iter().count() > 1
        || headers.get_all(header::ORIGIN).iter().count() > 1
    {
        return Err(AppError::bad_request("Ambiguous request origin."));
    }
    let authority = headers
        .get(header::HOST)
        .and_then(|h| h.to_str().ok())
        .or_else(|| request.uri().authority().map(|a| a.as_str()))
        .ok_or_else(|| AppError::bad_request("A Host header is required."))?;
    let public = &state.config.public_base_url;
    let host_url = Url::parse(&format!("{}://{authority}", public.scheme()))
        .map_err(|_| AppError::bad_request("Invalid Host header."))?;
    if host_url.origin() != public.origin()
        || host_url.path() != "/"
        || !host_url.username().is_empty()
        || host_url.password().is_some()
        || host_url.query().is_some()
        || host_url.fragment().is_some()
    {
        return Err(AppError::forbidden());
    }
    if let Some(value) = headers.get(header::ORIGIN) {
        let origin = value
            .to_str()
            .ok()
            .and_then(|v| Url::parse(v).ok())
            .ok_or_else(AppError::forbidden)?;
        if origin.origin() != public.origin()
            || origin.path() != "/"
            || !origin.username().is_empty()
            || origin.password().is_some()
            || origin.query().is_some()
            || origin.fragment().is_some()
        {
            return Err(AppError::forbidden());
        }
    }
    Ok(())
}

fn challenge(state: &AppState, error: AppError, scope: Option<&str>) -> Response {
    let status = error.status;
    let mut response = error.into_response();
    if status == StatusCode::UNAUTHORIZED || (status == StatusCode::FORBIDDEN && scope.is_some()) {
        let metadata = format!(
            "{}.well-known/oauth-protected-resource/mcp",
            state.config.public_base_url
        );
        let value = match scope {
            Some(scope) => format!(
                "Bearer error=\"insufficient_scope\", error_description=\"Additional permission is required\", resource_metadata=\"{metadata}\", scope=\"{scope}\""
            ),
            None => format!(
                "Bearer resource_metadata=\"{metadata}\", scope=\"mail:read mail:draft mail:manage mail:send\""
            ),
        };
        if let Ok(value) = HeaderValue::from_str(&value) {
            response
                .headers_mut()
                .insert(header::WWW_AUTHENTICATE, value);
        }
    }
    response
}
