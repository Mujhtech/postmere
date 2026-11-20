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
            let limit = if provider == Provider::Gmail
                && checkpoint
                    .gmail_recovering_until
                    .is_some_and(|until| until > Utc::now())
            {
                10
            } else {
                25
            };
            let mut batch = provider::sync_batch(
                state,
                provider,
                session.account.id,
                &session.credentials.access_token,
                checkpoint,
                limit,
            )
            .await
            .map_err(sync_provider_error)?;
            // Microsoft changed-message listings and an expired Gmail history
            // bookmark may miss deletions. Rotate a few exact-ID checks; only a
            // provider 404 may hide a cached item. Page omissions never remove mail.
            if provider == Provider::Gmail && !batch.has_more && verify_ids.is_empty() {
                batch.checkpoint.gmail_reconcile_before = None;
            }
            let verification_limit = if batch.has_more {
                0
            } else if provider == Provider::Gmail {
                1
            } else {
                5
            };
            for id in verify_ids.iter().take(verification_limit) {
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
                    Err(error) => {
                        // This is supplemental reconciliation. Its failure must
                        // not discard a successful batch of new messages.
                        tracing::warn!(event = "mail_sync_verify", reason = ?error, "cached message verification deferred");
                        break;
                    }
                }
            }
            batch.checkpoint.junk_label = mail::classify_mailboxes(
                state,
                session,
                &mut batch.messages,
                batch.checkpoint.junk_label.as_deref(),
            )
            .await?;
            Ok(batch)
        })
    }
}

fn sync_provider_error(error: ProviderError) -> AppError {
    let mut response = AppError::from(error);
    response.code = match error {
        ProviderError::Unauthorized => "sync_provider_authorization",
        ProviderError::MissingScope => "sync_provider_scope",
        ProviderError::ProviderPolicy => "sync_provider_policy",
        ProviderError::Forbidden => "sync_provider_forbidden",
        ProviderError::RateLimited { .. } => "sync_provider_rate_limited",
        ProviderError::NotFound => "sync_provider_not_found",
        ProviderError::Rejected => "sync_provider_rejected",
        ProviderError::Unavailable => "sync_provider_unavailable",
        ProviderError::InvalidResponse => "sync_provider_invalid_response",
        ProviderError::Ambiguous | ProviderError::CategoryConflict => "sync_provider_conflict",
    };
    response
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

// A full Gmail message costs 60 quota units. Pacing older 25-message
// pages leaves capacity for history, incoming messages, and reader actions.
fn gmail_backfill(provider: &str, checkpoint: &SyncCheckpoint) -> bool {
    provider == "gmail"
        && checkpoint.phase != "history"
        && checkpoint.cursor.is_some()
        && checkpoint.initial_history_id.is_some()
}

fn next_backfill(now: chrono::DateTime<Utc>, checkpoint: &SyncCheckpoint) -> chrono::DateTime<Utc> {
    let next = now + Duration::seconds(20);
    checkpoint
        .last_history_check
        .map_or(now, |last| next.min(last + Duration::seconds(60)))
}

fn importing(checkpoint: &SyncCheckpoint) -> bool {
    checkpoint.phase == "full"
        || checkpoint.backfill_cursor.is_some()
        || (checkpoint.phase.is_empty() && checkpoint.cursor.is_some())
}

async fn notify_account_status(
    tx: &mut Transaction<'_, Postgres>,
    workspace: Uuid,
    user: Uuid,
) -> Result<(), AppError> {
    // The normal accounts invalidation causes clients to reread the scoped status.
    // PostgreSQL publishes it only once the checkpoint and next due time commit.
    sqlx::query("SELECT pg_notify('postmere_events_v1',json_build_object('workspace_id',$1::uuid,'user_id',$2::uuid,'kind','accounts')::text)")
        .bind(workspace).bind(user).execute(&mut **tx).await?;
    Ok(())
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
        let mut error = AppError::conflict("This account is already synchronizing.");
        error.code = "sync_in_progress";
        return Err(error);
    }
    // Observe without locking: callbacks must be able to coalesce a newer hint
    // while this transaction waits on the provider. Consume only this version.
    let signal_generation: Option<i64> =
        sqlx::query_scalar("SELECT generation FROM mail_sync_signals WHERE account_id=$1")
            .bind(account)
            .fetch_optional(&mut *tx)
            .await?;
    schedule_account(&mut tx, workspace, user, account).await?;
    let sync_state=sqlx::query("SELECT checkpoint,last_error,updated_at FROM mail_sync_state WHERE account_id=$1 FOR UPDATE")
        .bind(account).fetch_one(&mut *tx).await?;
    let encoded: serde_json::Value = sync_state.try_get("checkpoint")?;
    // A cooldown survives app relaunches and applies to both foreground and
    // background opens. The provider cursor is kept exactly where it failed.
    #[derive(serde::Deserialize, serde::Serialize)]
    struct ProviderBackoff {
        until: chrono::DateTime<Utc>,
        attempts: u32,
    }
    let backoff: Option<ProviderBackoff> = encoded
        .get("provider_backoff")
        .cloned()
        .map(serde_json::from_value)
        .transpose()
        .map_err(|_| AppError::internal("sync_backoff_decode"))?;
    if let Some(previous) = &backoff
        && previous.until > Utc::now()
    {
        let remaining = (previous.until - Utc::now()).num_seconds().max(1) as u32;
        return Err(sync_provider_error(ProviderError::RateLimited {
            retry_after: Some(remaining),
        }));
    }
    let mut checkpoint: SyncCheckpoint = serde_json::from_value(encoded)
        .map_err(|_| AppError::internal("sync_checkpoint_decode"))?;
    let was_importing = session.account.last_synced_at.is_none() || importing(&checkpoint);
    let had_error = sync_state
        .try_get::<Option<String>, _>("last_error")?
        .is_some();
    if session.account.provider == "gmail"
        && let Some(next) = checkpoint
            .gmail_history_read_after
            .take()
            .filter(|t| *t > Utc::now())
    {
        // Remaining history must still be consumed in order, even if another
        // webhook or client wakes the same account during the quota window.
        sqlx::query("UPDATE mail_sync_wakeups SET due_at=$2,lease_until=$2 WHERE account_id=$1")
            .bind(account)
            .bind(next)
            .execute(&mut *tx)
            .await?;
        tx.commit().await?;
        return Ok(MessagePage {
            messages: vec![],
            next_cursor: checkpoint.cursor,
            has_more: true,
        });
    }
    if gmail_backfill(&session.account.provider, &checkpoint) {
        if signal_generation.is_some() {
            // An arrival hint should poll history immediately, preserving the import cursor.
            checkpoint.last_history_check = None;
        } else if !had_error {
            let next = next_backfill(sync_state.try_get("updated_at")?, &checkpoint);
            if next > Utc::now() {
                // Foreground refreshes may also arrive between scheduled import
                // pages. Serve the cache immediately and keep the worker scheduled.
                sqlx::query(
                    "UPDATE mail_sync_wakeups SET due_at=$2,lease_until=NULL WHERE account_id=$1",
                )
                .bind(account)
                .bind(next)
                .execute(&mut *tx)
                .await?;
                tx.commit().await?;
                return Ok(MessagePage {
                    messages: vec![],
                    next_cursor: checkpoint.cursor,
                    has_more: true,
                });
            }
        }
    }
    // Healthy Gmail history explicitly reports deletions. Only an expired
    // watermark leaves uncertain cached IDs behind after a fresh listing.
    let verify_ids = if session.account.provider == "gmail"
        && checkpoint.gmail_reconcile_before.is_none()
    {
        Vec::new()
    } else {
        sqlx::query_scalar("SELECT provider_message_id FROM mail_messages WHERE account_id=$1 AND deleted_at IS NULL AND ($2::timestamptz IS NULL OR last_verified_at<$2) ORDER BY last_verified_at,id LIMIT 5")
            .bind(account).bind(checkpoint.gmail_reconcile_before).fetch_all(&mut *tx).await?
    };
    let previous_junk_label = checkpoint.junk_label.clone();
    let mut batch = match transport
        .fetch(state, &session, checkpoint, &verify_ids)
        .await
    {
        Ok(batch) => batch,
        Err(mut error) if error.code == "sync_provider_rate_limited" => {
            let attempts = backoff.map_or(1, |old| old.attempts.saturating_add(1).min(7));
            let delay = error.retry_after_seconds.unwrap_or(60 << (attempts - 1));
            let next = Utc::now() + Duration::seconds(i64::from(delay));
            let backoff = serde_json::to_value(ProviderBackoff {
                until: next,
                attempts,
            })
            .map_err(|_| AppError::internal("sync_backoff_encode"))?;
            // Keep a lower sustained rate after a successful retry. Resetting
            // immediately to full import speed reproduces the same throttle.
            let recovery = if session.account.provider == "gmail" {
                serde_json::json!({"gmail_recovering_until":next+Duration::minutes(15)})
            } else {
                serde_json::json!({})
            };
            sqlx::query("UPDATE mail_sync_state SET checkpoint=jsonb_set(checkpoint,'{provider_backoff}',$2) || $4::jsonb,last_error=$3,updated_at=now() WHERE account_id=$1")
                .bind(account).bind(backoff).bind(error.code).bind(recovery).execute(&mut *tx).await?;
            // lease_until also protects against newly arriving webhook signals
            // asking the worker to poll again before the provider is ready.
            sqlx::query(
                "UPDATE mail_sync_wakeups SET due_at=$2,lease_until=$2 WHERE account_id=$1",
            )
            .bind(account)
            .bind(next)
            .execute(&mut *tx)
            .await?;
            notify_account_status(&mut tx, workspace, user).await?;
            tx.commit().await?;
            error.retry_after_seconds = Some(delay);
            return Err(error);
        }
        Err(error) => return Err(error),
    };
    // The account could be disconnected or membership revoked during the HTTP
    // request. Verify again before committing any resulting mailbox state.
    let active:bool=sqlx::query_scalar("SELECT EXISTS(SELECT 1 FROM provider_accounts a JOIN memberships m ON m.workspace_id=a.workspace_id AND m.user_id=a.user_id JOIN users u ON u.id=a.user_id JOIN workspaces w ON w.id=a.workspace_id WHERE a.id=$1 AND a.disabled_at IS NULL AND m.revoked_at IS NULL AND u.disabled_at IS NULL AND w.disabled_at IS NULL)").bind(account).fetch_one(&mut *tx).await?;
    if !active {
        return Err(AppError::forbidden());
    }
    cache_write_lock(&mut tx, workspace, user, account).await?;
    // Reclassify rows from older imports without re-fetching message bodies.
    // Advancing updated_at delivers the correction through ordinary cache cursors.
    if let Some(label) = &batch.checkpoint.junk_label
        && Some(label) != previous_junk_label.as_ref()
    {
        sqlx::query(
            "UPDATE mail_messages SET normalized=jsonb_set(normalized,'{mailbox}','\"junk\"'),
                updated_at=clock_timestamp()
             WHERE account_id=$1 AND deleted_at IS NULL AND normalized->>'mailbox'<>'junk'
                AND (normalized->'provider_labels') ? $2
                AND ($3 <> 'gmail' OR NOT ((normalized->'provider_labels') ? 'TRASH'))",
        )
        .bind(account)
        .bind(label)
        .bind(&session.account.provider)
        .execute(&mut *tx)
        .await?;
    }
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
    let now = Utc::now();
    if batch
        .checkpoint
        .gmail_recovering_until
        .is_some_and(|until| until <= now)
    {
        batch.checkpoint.gmail_recovering_until = None;
    }
    let more_history = session.account.provider == "gmail"
        && batch.has_more
        && batch.checkpoint.phase == "history"
        && (batch.checkpoint.cursor.is_some() || !batch.checkpoint.pending_ids.is_empty());
    let next = if more_history {
        // Full GETs cost 60 units. Keep substantial history continuations
        // within the same per-user budget as imports. Lightweight watermark
        // advances and small bursts of new mail remain quick.
        let recovery = batch.checkpoint.gmail_recovering_until.is_some();
        let seconds = (batch.messages.len() as i64 * if recovery { 2 } else { 1 }).clamp(2, 60);
        let next = now + Duration::seconds(seconds);
        batch.checkpoint.gmail_history_read_after = Some(next);
        next
    } else if batch.has_more && gmail_backfill(&session.account.provider, &batch.checkpoint) {
        next_backfill(now, &batch.checkpoint)
    } else {
        now + Duration::seconds(if batch.has_more { 2 } else { 60 })
    };
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
    if had_error || was_importing != importing(&batch.checkpoint) {
        notify_account_status(&mut tx, workspace, user).await?;
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
                    if let Err(error) = process_one_sync_with(&state, transport.as_ref()).await {
                        tracing::warn!(
                            event = "mail_sync_worker",
                            reason = error.code,
                            status = error.status.as_u16(),
                            "mail synchronization deferred"
                        );
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
    let row=sqlx::query("UPDATE mail_sync_wakeups SET lease_until=now()+interval '5 minutes' WHERE account_id=(SELECT w.account_id FROM mail_sync_wakeups w WHERE (w.due_at<=now() OR EXISTS(SELECT 1 FROM mail_sync_signals s WHERE s.account_id=w.account_id AND s.due_at<=now())) AND (w.lease_until IS NULL OR w.lease_until<now()) ORDER BY w.due_at,w.account_id FOR UPDATE OF w SKIP LOCKED LIMIT 1) RETURNING account_id,workspace_id,user_id,lease_until").fetch_optional(&state.pool).await?;
    let Some(row) = row else { return Ok(false) };
    let account: Uuid = row.try_get("account_id")?;
    let workspace: Uuid = row.try_get("workspace_id")?;
    let user: Uuid = row.try_get("user_id")?;
    if let Err(error) = sync_account_with(state, workspace, user, account, transport).await {
        let mut tx = db::scoped_transaction(&state.pool, workspace, user).await?;
        // A concurrent foreground sync can finish after our failed attempt.
        // Only the worker that still owns this lease can reschedule its work.
        let lease: chrono::DateTime<Utc> = row.try_get("lease_until")?;
        let owned: Option<Uuid> = sqlx::query_scalar("SELECT account_id FROM mail_sync_wakeups WHERE account_id=$1 AND lease_until=$2 FOR UPDATE")
            .bind(account).bind(lease).fetch_optional(&mut *tx).await?;
        if owned.is_none() {
            return Ok(false);
        }
        if error.code == "sync_in_progress" {
            sqlx::query("UPDATE mail_sync_wakeups SET lease_until=now()+interval '2 seconds' WHERE account_id=$1")
                .bind(account).execute(&mut *tx).await?;
            tx.commit().await?;
            return Ok(false);
        }
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
            sqlx::query(
                "UPDATE mail_sync_state SET last_error=$2,updated_at=now() WHERE account_id=$1",
            )
            .bind(account)
            .bind(error.code)
            .execute(&mut *tx)
            .await?;
            sqlx::query("UPDATE mail_sync_signals SET due_at=clock_timestamp()+interval '60 seconds' WHERE account_id=$1").bind(account).execute(&mut *tx).await?;
            notify_account_status(&mut tx, workspace, user).await?;
        }
        tx.commit().await?;
        return Err(error);
    }
    Ok(true)
}
