//! Remote MCP transport and user-reviewed action pages. The protocol adapter
//! delegates all tenant data operations and OAuth to their owning crates.
mod approvals;
mod catalog;
mod server;
mod transport;

use axum::{Router, routing::any};
use postmere_core::AppState;

pub fn router() -> Router<AppState> {
    Router::new()
        .route("/mcp", any(transport::endpoint))
        .route("/mcp/", any(transport::endpoint))
        .merge(approvals::router())
        .merge(postmere_mcp_auth::router())
}
