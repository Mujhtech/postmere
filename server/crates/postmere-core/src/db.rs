use crate::{auth::AuthContext, error::AppError};
use sqlx::{PgPool, Postgres, Row, Transaction, postgres::PgPoolOptions};
use uuid::Uuid;

pub async fn connect(database_url: &str) -> Result<PgPool, AppError> {
    let pool = PgPoolOptions::new()
        .max_connections(20)
        .acquire_timeout(std::time::Duration::from_secs(5))
        .connect(database_url)
        .await
        .map_err(|_| AppError::internal("database_connect"))?;
    verify_runtime_role(&pool).await?;
    Ok(pool)
}
pub async fn verify_runtime_role(pool: &PgPool) -> Result<(), AppError> {
    let row =
        sqlx::query("SELECT rolsuper, rolbypassrls FROM pg_roles WHERE rolname = current_user")
            .fetch_one(pool)
            .await?;
    if row.get::<bool, _>("rolsuper") || row.get::<bool, _>("rolbypassrls") {
        return Err(AppError::internal("unsafe_database_role"));
    }
    Ok(())
}
pub async fn migrate(pool: &PgPool) -> Result<(), AppError> {
    sqlx::migrate!("../../migrations")
        .run(pool)
        .await
        .map_err(|_| AppError::internal("database_migrate"))
}
pub async fn tenant_transaction(
    pool: &PgPool,
    auth: &AuthContext,
) -> Result<Transaction<'static, Postgres>, AppError> {
    scoped_transaction(pool, auth.workspace_id, auth.user_id).await
}

/// Only use this directly for a verified service job or a nonce-authenticated
/// OAuth callback. Caller-supplied IDs are not authentication on their own.
pub async fn scoped_transaction(
    pool: &PgPool,
    workspace_id: Uuid,
    user_id: Uuid,
) -> Result<Transaction<'static, Postgres>, AppError> {
    let mut tx = pool.begin().await?;
    sqlx::query("SELECT set_config('postmere.workspace_id', $1, true), set_config('postmere.user_id', $2, true), set_config('statement_timeout', '15000', true)")
        .bind(workspace_id.to_string()).bind(user_id.to_string()).execute(&mut *tx).await?;
    Ok(tx)
}
