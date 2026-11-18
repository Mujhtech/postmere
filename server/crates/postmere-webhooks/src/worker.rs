use crate::{
    SubscriptionRequest, WebhookService,
    routes::{active, signal},
};
use base64::{Engine, engine::general_purpose::URL_SAFE_NO_PAD};
use chrono::{DateTime, Duration, Utc};
use postmere_core::{AppState, db, error::AppError};
use postmere_mail::mail;
use postmere_providers::{Credentials, Provider};
use sha2::{Digest, Sha256};
use sqlx::Row;
use std::sync::Arc;
use uuid::Uuid;
use zeroize::Zeroizing;

pub fn spawn_worker(state: AppState, service: Arc<WebhookService>) -> tokio::task::JoinHandle<()> {
    tokio::spawn(async move {
        // Bound concurrent provider calls while keeping one slow mailbox from
        // blocking all renewals. Dropping the parent cancels every child lane.
        let mut lanes = tokio::task::JoinSet::new();
        for _ in 0..4 {
            let state = state.clone();
            let service = service.clone();
            lanes.spawn(async move {
                let mut interval = tokio::time::interval(std::time::Duration::from_secs(5));
                interval.set_missed_tick_behavior(tokio::time::MissedTickBehavior::Delay);
                loop {
                    interval.tick().await;
                    if process_one(&state, &service).await.is_err() {
                        tracing::warn!(
                            event = "provider_webhook_deferred",
                            "Provider notification renewal deferred; polling remains active"
                        );
                    }
                }
            });
        }
        while let Some(result) = lanes.join_next().await {
            if result.is_err() {
                tracing::warn!(
                    event = "provider_webhook_worker",
                    "Provider notification renewal worker stopped"
                );
            }
        }
    })
}

pub async fn process_one(state: &AppState, service: &WebhookService) -> Result<bool, AppError> {
    let row=sqlx::query("UPDATE provider_webhooks SET lease_until=clock_timestamp()+interval '2 minutes' WHERE id=(SELECT id FROM provider_webhooks WHERE renew_at<=clock_timestamp() AND (lease_until IS NULL OR lease_until<clock_timestamp()) AND (enabled OR expires_at IS NOT NULL OR provider_subscription IS NOT NULL) AND ((provider='gmail' AND $1) OR (provider='microsoft' AND $2)) ORDER BY renew_at,id FOR UPDATE SKIP LOCKED LIMIT 1) RETURNING id,workspace_id,user_id,account_id,generation")
        .bind(service.enabled("gmail")).bind(service.enabled("microsoft")).fetch_optional(&state.pool).await?;
    let Some(row) = row else {
        return Ok(false);
    };
    let id: Uuid = row.get("id");
    let workspace = row.get("workspace_id");
    let user = row.get("user_id");
    let account = row.get("account_id");
    let generation: i64 = row.get("generation");
    let outcome = tokio::time::timeout(
        std::time::Duration::from_secs(60),
        maintain(state, service, id, workspace, user, account, generation),
    )
    .await
    .unwrap_or_else(|_| Err(AppError::unavailable()));
    if let Err(error) = outcome {
        sqlx::query("UPDATE provider_webhooks SET attempts=LEAST(attempts+1,20),last_error='subscription_deferred',renew_at=clock_timestamp()+make_interval(secs=>LEAST(3600,5*power(2,LEAST(attempts,10)))::double precision),lease_until=NULL WHERE id=$1 AND generation=$2")
            .bind(id).bind(generation).execute(&state.pool).await?;
        return Err(error);
    }
    Ok(true)
}

async fn maintain(
    state: &AppState,
    service: &WebhookService,
    id: Uuid,
    workspace: Uuid,
    user: Uuid,
    account: Uuid,
    generation: i64,
) -> Result<(), AppError> {
    // Refresh active credentials before holding account/identity locks over the
    // subscription request. Disabled accounts are opened only for cancellation.
    let mut preflight = db::scoped_transaction(&state.pool, workspace, user).await?;
    let available = active(&mut preflight, workspace, user, account).await?;
    preflight.commit().await?;
    let credentials = if available {
        mail::service_account_session(state, workspace, user, account)
            .await?
            .credentials
    } else {
        let mut tx = db::scoped_transaction(&state.pool, workspace, user).await?;
        let encrypted: Vec<u8> =
            sqlx::query_scalar("SELECT encrypted_credentials FROM provider_accounts WHERE id=$1")
                .bind(account)
                .fetch_one(&mut *tx)
                .await?;
        let bytes = state.crypto.open(workspace, account, &encrypted)?;
        serde_json::from_slice::<Credentials>(&bytes)
            .map_err(|_| AppError::internal("webhook_cleanup_credentials"))?
    };
    // Persist the secret before Graph creates the subscription. If a process
    // dies after POST, the next attempt reconciles by this callback and secret.
    let mut prepare = db::scoped_transaction(&state.pool, workspace, user).await?;
    let row=sqlx::query("SELECT provider,mailbox_hash,encrypted_state FROM provider_webhooks WHERE id=$1 AND generation=$2 FOR UPDATE")
        .bind(id).bind(generation).fetch_optional(&mut *prepare).await?;
    let Some(row) = row else {
        return Ok(());
    };
    let provider = Provider::parse(&row.get::<String, _>("provider"))?;
    let mailbox: Vec<u8> = row.get("mailbox_hash");
    let encrypted: Option<Vec<u8>> = row.get("encrypted_state");
    let client_state = if let Some(encrypted) = encrypted {
        let bytes = state.crypto.open(workspace, id, &encrypted)?;
        Zeroizing::new(
            String::from_utf8(bytes.to_vec())
                .map_err(|_| AppError::internal("webhook_state_decode"))?,
        )
    } else {
        let mut bytes = [0_u8; 32];
        getrandom::fill(&mut bytes).map_err(|_| AppError::internal("secure_random"))?;
        let secret = Zeroizing::new(URL_SAFE_NO_PAD.encode(bytes));
        let sealed = state.crypto.seal(workspace, id, secret.as_bytes())?;
        sqlx::query("UPDATE provider_webhooks SET encrypted_state=$2,state_hash=$3 WHERE id=$1")
            .bind(id)
            .bind(sealed)
            .bind(Sha256::digest(secret.as_bytes()).as_slice())
            .execute(&mut *prepare)
            .await?;
        secret
    };
    if available {
        // Record a bounded cancellation horizon before the external write. A
        // crash after creation must leave a cleanup job even without its ID.
        sqlx::query("UPDATE provider_webhooks SET expires_at=CASE WHEN expires_at IS NULL OR expires_at<=clock_timestamp() THEN clock_timestamp()+make_interval(days=>$3) ELSE expires_at END WHERE id=$1 AND generation=$2 AND enabled")
            .bind(id).bind(generation).bind(if provider==Provider::Gmail {8_i32} else {3_i32}).execute(&mut *prepare).await?;
    }
    prepare.commit().await?;

    let mut tx = db::scoped_transaction(&state.pool, workspace, user).await?;
    // Lifecycle hints can invalidate a lease while HTTP is in flight. Serialize
    // replacement workers even across processes; callbacks never take this lock.
    sqlx::query("SELECT pg_advisory_xact_lock(hashtextextended($1,0))")
        .bind(format!("provider-webhook:{id}"))
        .execute(&mut *tx)
        .await?;
    if provider == Provider::Gmail {
        // Gmail has one watch per mailbox/project, even if several workspace
        // users connect the same mailbox. A departing user must not stop peers.
        sqlx::query("SELECT pg_advisory_xact_lock(hashtextextended($1,0))")
            .bind(format!("gmail-watch:{}", URL_SAFE_NO_PAD.encode(&mailbox)))
            .execute(&mut *tx)
            .await?;
    }
    let is_active = active(&mut tx, workspace, user, account).await?;
    if !is_active {
        // Serialize cancellation with a reconnect without granting this inactive
        // identity permission to renew or fetch provider content.
        sqlx::query("SELECT id FROM provider_accounts WHERE id=$1 FOR SHARE")
            .bind(account)
            .fetch_one(&mut *tx)
            .await?;
    }
    let current=sqlx::query("SELECT enabled,provider_subscription,expires_at FROM provider_webhooks WHERE id=$1 AND generation=$2")
        .bind(id).bind(generation).fetch_optional(&mut *tx).await?;
    let Some(current) = current else {
        return Ok(());
    };
    let enabled: bool = current.get("enabled");
    let previous: Option<String> = current.get("provider_subscription");
    let expires_at: Option<DateTime<Utc>> = current.get("expires_at");
    let callback = state
        .config
        .public_base_url
        .join(&format!("/v1/webhooks/microsoft/{id}"))
        .map_err(|_| AppError::internal("webhook_callback"))?
        .to_string();
    let request = SubscriptionRequest {
        provider,
        access_token: Zeroizing::new(credentials.access_token.clone()),
        subscription_id: previous.clone(),
        callback,
        client_state,
        gmail_topic: service.gmail.as_ref().map(|c| c.topic.clone()),
    };
    if !enabled || !is_active {
        let peer: bool = if provider == Provider::Gmail {
            sqlx::query_scalar("SELECT EXISTS(SELECT 1 FROM provider_webhooks WHERE provider='gmail' AND mailbox_hash=$1 AND enabled AND id<>$2)")
                .bind(&mailbox).bind(id).fetch_one(&mut *tx).await?
        } else {
            false
        };
        if !peer && expires_at.is_some_and(|e| e > Utc::now()) {
            service.transport.remove(state, &request).await?;
        }
        sqlx::query("UPDATE provider_webhooks SET provider_subscription=NULL,expires_at=NULL,lease_until=NULL,attempts=0,last_error=NULL,renew_at=clock_timestamp()+interval '1 hour' WHERE id=$1 AND generation=$2")
            .bind(id).bind(generation).execute(&mut *tx).await?;
        tx.commit().await?;
        return Ok(());
    }
    let subscription = service.transport.ensure(state, &request).await?;
    if subscription.expires_at <= Utc::now() + Duration::minutes(1)
        || subscription.expires_at > Utc::now() + Duration::days(8)
        || (provider == Provider::Microsoft
            && subscription
                .id
                .as_ref()
                .is_none_or(|id| id.is_empty() || id.len() > 512))
    {
        return Err(AppError::unavailable());
    }
    let next = Utc::now() + ((subscription.expires_at - Utc::now()) / 2).min(Duration::days(1));
    let applied=sqlx::query("UPDATE provider_webhooks SET provider_subscription=$3,expires_at=$4,renew_at=$5,lease_until=NULL,attempts=0,last_error=NULL,last_success_at=clock_timestamp() WHERE id=$1 AND generation=$2 AND enabled")
        .bind(id).bind(generation).bind(&subscription.id).bind(subscription.expires_at).bind(next).execute(&mut *tx).await?.rows_affected()==1;
    if applied {
        // Catch the initial watch boundary and any notifications lost during renewal.
        signal(&mut tx, workspace, user, account).await?;
    } else if provider == Provider::Microsoft && subscription.id != previous {
        let cleanup = SubscriptionRequest {
            subscription_id: subscription.id,
            ..request
        };
        let _ = service.transport.remove(state, &cleanup).await;
    }
    tx.commit().await?;
    Ok(())
}
