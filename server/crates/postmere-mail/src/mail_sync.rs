//! Bounded account synchronization runs without an app session. Checkpoints are
//! persisted under RLS; the public scheduler index carries identifiers only.
use crate::mail::{self, AccountSession};
use chrono::{Duration, Utc};
use postmere_core::{AppState, db, error::AppError};
use postmere_providers::{
    self as provider, MessagePage, Provider, ProviderError, SyncBatch, SyncCheckpoint,
};
use sqlx::{Postgres, Row, Transaction};
use std::sync::Arc;
use uuid::Uuid;

pub trait SyncTransport: Send + Sync {
    fn fetch<'a>(
        &'a self,
        state: &'a AppState,
        session: &'a AccountSession,
        checkpoint: SyncCheckpoint,
        verify_ids: &'a [String],
    ) -> std::pin::Pin<Box<dyn std::future::Future<Output = Result<SyncBatch, AppError>> + Send + 'a>>;
}
pub struct HttpSync;
impl SyncTransport for HttpSync {
    fn fetch<'a>(
        &'a self,
        state: &'a AppState,
        session: &'a AccountSession,
        checkpoint: SyncCheckpoint,
        verify_ids: &'a [String],
    ) -> std::pin::Pin<Box<dyn std::future::Future<Output = Result<SyncBatch, AppError>> + Send + 'a>>
    {
        Box::pin(async move {
            let provider = Provider::parse(&session.account.provider)?;
            let mut batch = provider::sync_batch(
                state,
                provider,
                session.account.id,
                &session.credentials.access_token,
                checkpoint,
                25,
            )
            .await?;
            // Microsoft changed-message listings and an expired Gmail history
            // bookmark may miss deletions. Rotate a few exact-ID checks; only a
            // provider 404 may hide a cached item. Page omissions never remove mail.
            for id in verify_ids.iter().take(5) {
                if batch.messages.iter().any(|m| m.provider_message_id == *id) {
                    continue;
                }
                match provider::fetch_message(
                    state,
                    provider,
                    session.account.id,
                    &session.credentials.access_token,
                    id,
                )
                .await
                {
                    Ok(message) => batch.messages.push(message),
                    Err(ProviderError::NotFound) => batch.deleted_ids.push(id.clone()),
                    Err(error) => return Err(error.into()),
                }
            }
            mail::classify_graph(state, session, &mut batch.messages).await?;
            Ok(batch)
        })
    }
}

pub async fn cache_write_lock(
    tx: &mut Transaction<'_, Postgres>,
    workspace: Uuid,
    user: Uuid,
    account: Uuid,
) -> Result<(), AppError> {
    sqlx::query("SELECT pg_advisory_xact_lock(hashtextextended($1,0))")
        .bind(format!("mail-cache:{workspace}:{user}:{account}"))
        .execute(&mut **tx)
        .await?;
    Ok(())
}
pub async fn account_operation_lock(
    tx: &mut Transaction<'_, Postgres>,
    workspace: Uuid,
    user: Uuid,
    account: Uuid,
) -> Result<(), AppError> {
    sqlx::query("SELECT pg_advisory_xact_lock(hashtextextended($1,0))")
        .bind(format!("mail-sync:{workspace}:{user}:{account}"))
        .execute(&mut **tx)
        .await?;
    Ok(())
}

pub async fn schedule_account(
    tx: &mut Transaction<'_, Postgres>,
    workspace: Uuid,
    user: Uuid,
    account: Uuid,
) -> Result<(), AppError> {
    sqlx::query("INSERT INTO mail_sync_state(account_id,workspace_id,user_id) VALUES($1,$2,$3) ON CONFLICT(account_id) DO NOTHING").bind(account).bind(workspace).bind(user).execute(&mut **tx).await?;
    sqlx::query("INSERT INTO mail_sync_wakeups(account_id,workspace_id,user_id,due_at) VALUES($1,$2,$3,now()) ON CONFLICT(account_id) DO UPDATE SET due_at=LEAST(mail_sync_wakeups.due_at,now())").bind(account).bind(workspace).bind(user).execute(&mut **tx).await?;
    Ok(())
}

pub async fn sync_account(
    state: &AppState,
    workspace: Uuid,
    user: Uuid,
    account: Uuid,
) -> Result<MessagePage, AppError> {
    sync_account_with(state, workspace, user, account, &HttpSync).await
}

pub async fn sync_account_with(
    state: &AppState,
    workspace: Uuid,
    user: Uuid,
    account: Uuid,
    transport: &(impl SyncTransport + ?Sized),
) -> Result<MessagePage, AppError> {
    let session = mail::service_account_session(state, workspace, user, account).await?;
    let mut tx = db::scoped_transaction(&state.pool, workspace, user).await?;
    // The transaction lock covers provider fetch + checkpoint commit, preventing
    // two app/worker requests from advancing the same cursor out of order.
    let acquired: bool =
        sqlx::query_scalar("SELECT pg_try_advisory_xact_lock(hashtextextended($1,0))")
            .bind(format!("mail-sync:{workspace}:{user}:{account}"))
            .fetch_one(&mut *tx)
            .await?;
    if !acquired {
        return Err(AppError::conflict("This account is already synchronizing."));
    }
    // Observe without locking: callbacks must be able to coalesce a newer hint
    // while this transaction waits on the provider. Consume only this version.
    let signal_generation: Option<i64> =
        sqlx::query_scalar("SELECT generation FROM mail_sync_signals WHERE account_id=$1")
            .bind(account)
            .fetch_optional(&mut *tx)
            .await?;
    schedule_account(&mut tx, workspace, user, account).await?;
    let encoded: serde_json::Value =
        sqlx::query_scalar("SELECT checkpoint FROM mail_sync_state WHERE account_id=$1 FOR UPDATE")
            .bind(account)
            .fetch_one(&mut *tx)
            .await?;
    let checkpoint: SyncCheckpoint = serde_json::from_value(encoded)
        .map_err(|_| AppError::internal("sync_checkpoint_decode"))?;
    let verify_ids:Vec<String>=sqlx::query_scalar("SELECT provider_message_id FROM mail_messages WHERE account_id=$1 AND deleted_at IS NULL ORDER BY last_verified_at,id LIMIT 5").bind(account).fetch_all(&mut *tx).await?;
    let mut batch = transport
        .fetch(state, &session, checkpoint, &verify_ids)
        .await?;
    // The account could be disconnected or membership revoked during the HTTP
    // request. Verify again before committing any resulting mailbox state.
    let active:bool=sqlx::query_scalar("SELECT EXISTS(SELECT 1 FROM provider_accounts a JOIN memberships m ON m.workspace_id=a.workspace_id AND m.user_id=a.user_id JOIN users u ON u.id=a.user_id JOIN workspaces w ON w.id=a.workspace_id WHERE a.id=$1 AND a.disabled_at IS NULL AND m.revoked_at IS NULL AND u.disabled_at IS NULL AND w.disabled_at IS NULL)").bind(account).fetch_one(&mut *tx).await?;
    if !active {
        return Err(AppError::forbidden());
    }
    cache_write_lock(&mut tx, workspace, user, account).await?;
    for message in &mut batch.messages {
        if message.account_id != account {
            return Err(AppError::internal("provider_account_mismatch"));
        }
        if let Some(existing) = sqlx::query_scalar::<_, Uuid>(
            "SELECT id FROM mail_messages WHERE account_id=$1 AND provider_message_id=$2",
        )
        .bind(account)
        .bind(&message.provider_message_id)
        .fetch_optional(&mut *tx)
        .await?
        {
            message.id = existing
        }
        mail::persist_message(&mut tx, workspace, user, message).await?;
    }
    if !batch.deleted_ids.is_empty() {
        sqlx::query("UPDATE mail_messages SET deleted_at=clock_timestamp(),last_verified_at=clock_timestamp(),updated_at=clock_timestamp() WHERE account_id=$1 AND provider_message_id=ANY($2)").bind(account).bind(&batch.deleted_ids).execute(&mut *tx).await?;
    }
    let verified: Vec<String> = batch
        .messages
        .iter()
        .map(|m| m.provider_message_id.clone())
        .collect();
    if !verified.is_empty() {
        sqlx::query("UPDATE mail_messages SET last_verified_at=now() WHERE account_id=$1 AND provider_message_id=ANY($2)").bind(account).bind(verified).execute(&mut *tx).await?;
    }
    let cursor = batch.checkpoint.cursor.clone();
    let next = Utc::now() + Duration::seconds(if batch.has_more { 2 } else { 60 });
    sqlx::query("UPDATE mail_sync_state SET checkpoint=$2,last_error=NULL,updated_at=now() WHERE account_id=$1").bind(account).bind(serde_json::to_value(&batch.checkpoint).map_err(|_|AppError::internal("sync_checkpoint_encode"))?).execute(&mut *tx).await?;
    sqlx::query("UPDATE provider_accounts SET last_synced_at=now(),sync_cursor=$2,updated_at=now() WHERE id=$1").bind(account).bind(&cursor).execute(&mut *tx).await?;
    sqlx::query("UPDATE mail_sync_wakeups SET due_at=$2,lease_until=NULL WHERE account_id=$1")
        .bind(account)
        .bind(next)
        .execute(&mut *tx)
        .await?;
    if let Some(observed) = signal_generation {
        sqlx::query("DELETE FROM mail_sync_signals WHERE account_id=$1 AND generation<=$2")
            .bind(account)
            .bind(observed)
            .execute(&mut *tx)
            .await?;
    }
    tx.commit().await?;
    Ok(MessagePage {
        messages: batch.messages,
        next_cursor: cursor,
        has_more: batch.has_more,
    })
}

pub fn spawn_sync_worker(state: AppState) -> tokio::task::JoinHandle<()> {
    spawn_sync_worker_with(state, Arc::new(HttpSync))
}

pub fn spawn_sync_worker_with(
    state: AppState,
    transport: Arc<dyn SyncTransport>,
) -> tokio::task::JoinHandle<()> {
    tokio::spawn(async move {
        // Bound provider/database work, not the number of connected accounts.
        // Independent lanes keep one slow mailbox from delaying every other
        // account. Dropping this JoinSet on shutdown aborts all child workers.
        let mut lanes = tokio::task::JoinSet::new();
        for _ in 0..4 {
            let state = state.clone();
            let transport = transport.clone();
            lanes.spawn(async move {
                let mut interval = tokio::time::interval(std::time::Duration::from_secs(2));
                interval.set_missed_tick_behavior(tokio::time::MissedTickBehavior::Delay);
                loop {
                    interval.tick().await;
                    if process_one_sync_with(&state, transport.as_ref())
                        .await
                        .is_err()
                    {
                        tracing::warn!(event = "mail_sync_worker", "mail synchronization deferred");
                    }
                }
            });
        }
        while let Some(result) = lanes.join_next().await {
            if result.is_err() {
                tracing::warn!(
                    event = "mail_sync_worker",
                    "mail synchronization worker stopped"
                );
            }
        }
    })
}
pub async fn process_one_sync(state: &AppState) -> Result<bool, AppError> {
    process_one_sync_with(state, &HttpSync).await
}
pub async fn process_one_sync_with(
    state: &AppState,
    transport: &(impl SyncTransport + ?Sized),
) -> Result<bool, AppError> {
    let row=sqlx::query("UPDATE mail_sync_wakeups SET lease_until=now()+interval '5 minutes' WHERE account_id=(SELECT w.account_id FROM mail_sync_wakeups w WHERE (w.due_at<=now() OR EXISTS(SELECT 1 FROM mail_sync_signals s WHERE s.account_id=w.account_id AND s.due_at<=now())) AND (w.lease_until IS NULL OR w.lease_until<now()) ORDER BY w.due_at,w.account_id FOR UPDATE OF w SKIP LOCKED LIMIT 1) RETURNING account_id,workspace_id,user_id").fetch_optional(&state.pool).await?;
    let Some(row) = row else { return Ok(false) };
    let account: Uuid = row.try_get("account_id")?;
    let workspace: Uuid = row.try_get("workspace_id")?;
    let user: Uuid = row.try_get("user_id")?;
    if let Err(error) = sync_account_with(state, workspace, user, account, transport).await {
        let mut tx = db::scoped_transaction(&state.pool, workspace, user).await?;
        let active:bool=sqlx::query_scalar("SELECT EXISTS(SELECT 1 FROM provider_accounts a JOIN memberships m ON m.workspace_id=a.workspace_id AND m.user_id=a.user_id JOIN users u ON u.id=a.user_id JOIN workspaces w ON w.id=a.workspace_id WHERE a.id=$1 AND a.disabled_at IS NULL AND a.status='connected' AND m.revoked_at IS NULL AND u.disabled_at IS NULL AND w.disabled_at IS NULL)").bind(account).fetch_one(&mut *tx).await?;
        if !active {
            sqlx::query("DELETE FROM mail_sync_wakeups WHERE account_id=$1")
                .bind(account)
                .execute(&mut *tx)
                .await?;
            sqlx::query("DELETE FROM mail_sync_signals WHERE account_id=$1")
                .bind(account)
                .execute(&mut *tx)
                .await?;
        } else {
            sqlx::query("UPDATE mail_sync_wakeups SET due_at=now()+interval '60 seconds',lease_until=NULL WHERE account_id=$1").bind(account).execute(&mut *tx).await?;
            sqlx::query("UPDATE mail_sync_state SET last_error='provider_sync_deferred',updated_at=now() WHERE account_id=$1").bind(account).execute(&mut *tx).await?;
            sqlx::query("UPDATE mail_sync_signals SET due_at=clock_timestamp()+interval '60 seconds' WHERE account_id=$1").bind(account).execute(&mut *tx).await?;
        }
        tx.commit().await?;
        return Err(error);
    }
    Ok(true)
}
