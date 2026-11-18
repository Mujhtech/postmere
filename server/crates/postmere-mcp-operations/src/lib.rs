//! Typed mail operations shared by the MCP transport and authenticated approval UI.
//! Principal IDs never come from tool arguments. Approval execution belongs only
//! to the browser consent route; requesting an approval does not authorize it.
mod approvals;
mod drafts;
mod read;

pub use approvals::*;
pub use drafts::*;
pub use read::*;

use postmere_core::{auth::AuthContext, error::AppError};
use sqlx::{Postgres, Transaction};

async fn operation_lock(
    tx: &mut Transaction<'_, Postgres>,
    auth: &AuthContext,
    kind: &str,
) -> Result<(), AppError> {
    sqlx::query("SELECT pg_advisory_xact_lock(hashtextextended($1,0))")
        .bind(format!("mcp:{kind}:{}:{}", auth.workspace_id, auth.user_id))
        .execute(&mut **tx)
        .await?;
    // An advisory lock may have waited beyond session expiry.
    check_session(tx, auth).await
}

async fn check_session(
    tx: &mut Transaction<'_, Postgres>,
    auth: &AuthContext,
) -> Result<(), AppError> {
    let active:bool=sqlx::query_scalar("SELECT (expires_at IS NULL OR expires_at>clock_timestamp()) AND (absolute_expires_at IS NULL OR absolute_expires_at>clock_timestamp()) FROM sessions WHERE id=$1")
        .bind(auth.session_id).fetch_one(&mut **tx).await?;
    if !active {
        return Err(AppError::unauthorized());
    }
    Ok(())
}

fn truncate(value: &str, max: usize) -> String {
    if value.len() <= max {
        return value.to_owned();
    }
    let mut end = max;
    while !value.is_char_boundary(end) {
        end -= 1;
    }
    value[..end].to_owned()
}
