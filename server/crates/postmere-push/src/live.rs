//! Live Activities showing what a connected assistant is doing, on the user's
//! iPhone, updated over APNs while the app is closed.
//!
//! Each MCP tool call marks the user's activity for that assistant as changed
//! and queues a wakeup. The worker then starts an activity with the device's
//! push-to-start token, updates it once the device reports the activity's own
//! token, and ends it after two quiet minutes. Updates are throttled to one
//! every three seconds per activity; the latest state always lands.

use crate::{DeliveryResult, PushKind, PushRequest, PushService, transport::valid_token};
use axum::{
    Json, Router,
    extract::{Path, State},
    http::StatusCode,
    routing::put,
};
use chrono::{DateTime, Duration, Utc};
use postmere_core::{AppState, auth::AuthContext, db, error::AppError};
use serde::Deserialize;
use serde_json::{Value, json};
use sha2::{Digest, Sha256};
use sqlx::{Postgres, Row, Transaction};
use std::sync::Arc;
use uuid::Uuid;
use zeroize::Zeroizing;

/// An activity ends after this long without a tool call.
const IDLE: Duration = Duration::seconds(120);
/// At most one update per activity this often; Apple throttles busier senders.
const THROTTLE: Duration = Duration::seconds(3);

pub(crate) fn router() -> Router<AppState> {
    Router::new()
        .route(
            "/v1/push/devices/{installation}/live-activities/start-token",
            put(register_start_token).delete(remove_start_token),
        )
        .route(
            "/v1/push/devices/{installation}/live-activities/assistants/{grant}",
            put(register_activity_token).delete(end_activity),
        )
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct TokenInput {
    token: String,
}

fn normalized_token(token: String) -> Result<Zeroizing<String>, AppError> {
    let mut token = Zeroizing::new(token);
    token.make_ascii_lowercase();
    if !valid_token(&token) {
        return Err(AppError::bad_request("Invalid Live Activity token."));
    }
    Ok(token)
}

/// This session's registered device for the installation. Live Activity tokens
/// ride on the notification registration and end with it.
async fn device(
    tx: &mut Transaction<'_, Postgres>,
    auth: &AuthContext,
    installation: Uuid,
) -> Result<Uuid, AppError> {
    sqlx::query_scalar("SELECT id FROM push_devices WHERE installation_id=$1 AND session_id=$2 AND disabled_at IS NULL FOR SHARE")
        .bind(installation)
        .bind(auth.session_id)
        .fetch_optional(&mut **tx)
        .await?
        .ok_or_else(AppError::not_found)
}

/// The grant must be one of this user's live assistant connections in this workspace.
async fn owned_grant(
    tx: &mut Transaction<'_, Postgres>,
    auth: &AuthContext,
    grant: Uuid,
) -> Result<(), AppError> {
    let owned: bool = sqlx::query_scalar("SELECT EXISTS(SELECT 1 FROM mcp_oauth_grants g JOIN sessions s ON s.id=g.session_id WHERE g.id=$1 AND s.workspace_id=$2 AND s.user_id=$3 AND g.revoked_at IS NULL AND s.revoked_at IS NULL)")
        .bind(grant)
        .bind(auth.workspace_id)
        .bind(auth.user_id)
        .fetch_one(&mut **tx)
        .await?;
    if owned {
        Ok(())
    } else {
        Err(AppError::not_found())
    }
}

async fn rate_limit(state: &AppState, auth: &AuthContext) -> Result<(), AppError> {
    state
        .auth
        .rate_limit(
            "live_activity_tokens",
            &format!("{}:{}", auth.workspace_id, auth.user_id),
            240,
        )
        .await
}

async fn register_start_token(
    State(state): State<AppState>,
    auth: AuthContext,
    Path(installation): Path<Uuid>,
    Json(input): Json<TokenInput>,
) -> Result<StatusCode, AppError> {
    if auth.assistant {
        return Err(AppError::forbidden());
    }
    let token = normalized_token(input.token)?;
    rate_limit(&state, &auth).await?;
    let mut tx = auth.begin_authorized(&state.pool).await?;
    let device = device(&mut tx, &auth, installation).await?;
    let token_id = Uuid::new_v4();
    let encrypted = state
        .crypto
        .seal(auth.workspace_id, token_id, token.as_bytes())?;
    sqlx::query("INSERT INTO live_activity_start_tokens(device_id,workspace_id,user_id,token_id,encrypted_token,token_hash) VALUES($1,$2,$3,$4,$5,$6) ON CONFLICT(device_id) DO UPDATE SET token_id=excluded.token_id,encrypted_token=excluded.encrypted_token,token_hash=excluded.token_hash,registered_at=clock_timestamp()")
        .bind(device).bind(auth.workspace_id).bind(auth.user_id).bind(token_id).bind(encrypted)
        .bind(Sha256::digest(token.as_bytes()).to_vec()).execute(&mut *tx).await?;
    auth.authorize_in_transaction(&mut tx).await?;
    tx.commit().await?;
    Ok(StatusCode::NO_CONTENT)
}

/// The person turned assistant Live Activities off on this device.
async fn remove_start_token(
    State(state): State<AppState>,
    auth: AuthContext,
    Path(installation): Path<Uuid>,
) -> Result<StatusCode, AppError> {
    if auth.assistant {
        return Err(AppError::forbidden());
    }
    let mut tx = auth.begin_authorized(&state.pool).await?;
    let device = device(&mut tx, &auth, installation).await?;
    sqlx::query("DELETE FROM live_activity_start_tokens WHERE device_id=$1")
        .bind(device)
        .execute(&mut *tx)
        .await?;
    tx.commit().await?;
    Ok(StatusCode::NO_CONTENT)
}

/// The token of an activity now showing on the device, whether the server
/// started it or the app did. Updates flow to it from here on.
async fn register_activity_token(
    State(state): State<AppState>,
    auth: AuthContext,
    Path((installation, grant)): Path<(Uuid, Uuid)>,
    Json(input): Json<TokenInput>,
) -> Result<StatusCode, AppError> {
    if auth.assistant {
        return Err(AppError::forbidden());
    }
    let token = normalized_token(input.token)?;
    rate_limit(&state, &auth).await?;
    let mut tx = auth.begin_authorized(&state.pool).await?;
    let device = device(&mut tx, &auth, installation).await?;
    owned_grant(&mut tx, &auth, grant).await?;
    let token_id = Uuid::new_v4();
    let encrypted = state
        .crypto
        .seal(auth.workspace_id, token_id, token.as_bytes())?;
    sqlx::query("INSERT INTO assistant_live_activities(device_id,grant_id,workspace_id,user_id,token_id,encrypted_token,token_hash,tool,recent,started_at,last_event_at,start_sent_at)
        SELECT $1,$2,$3,$4,$5,$6,$7,coalesce(r.tool,'working'),coalesce(r.recent,'{}'),coalesce(g.last_used_at,clock_timestamp()),coalesce(g.last_used_at,clock_timestamp()),clock_timestamp()
        FROM mcp_oauth_grants g
        LEFT JOIN LATERAL (SELECT (array_agg(tool ORDER BY at DESC))[1] tool,(array_agg(tool ORDER BY at DESC))[1:3] recent FROM mcp_activity WHERE grant_id=g.id) r ON true
        WHERE g.id=$2
        ON CONFLICT(device_id,grant_id) DO UPDATE SET token_id=excluded.token_id,encrypted_token=excluded.encrypted_token,token_hash=excluded.token_hash,
            start_sent_at=coalesce(assistant_live_activities.start_sent_at,clock_timestamp()),
            ended_at=NULL,last_pushed_at=NULL")
        .bind(device).bind(grant).bind(auth.workspace_id).bind(auth.user_id).bind(token_id).bind(encrypted)
        .bind(Sha256::digest(token.as_bytes()).to_vec()).execute(&mut *tx).await?;
    // Bring the new activity up to date now, and end it once it goes quiet.
    sqlx::query("INSERT INTO assistant_live_activity_wakeups(device_id,grant_id,workspace_id,user_id,due_at) VALUES($1,$2,$3,$4,clock_timestamp()) ON CONFLICT(device_id,grant_id) DO UPDATE SET due_at=clock_timestamp(),lease_until=NULL")
        .bind(device).bind(grant).bind(auth.workspace_id).bind(auth.user_id).execute(&mut *tx).await?;
    auth.authorize_in_transaction(&mut tx).await?;
    tx.commit().await?;
    Ok(StatusCode::NO_CONTENT)
}

/// The person dismissed the activity, or the app ended it.
async fn end_activity(
    State(state): State<AppState>,
    auth: AuthContext,
    Path((installation, grant)): Path<(Uuid, Uuid)>,
) -> Result<StatusCode, AppError> {
    if auth.assistant {
        return Err(AppError::forbidden());
    }
    let mut tx = auth.begin_authorized(&state.pool).await?;
    let device = device(&mut tx, &auth, installation).await?;
    sqlx::query("UPDATE assistant_live_activities SET ended_at=clock_timestamp(),token_id=NULL,encrypted_token=NULL,token_hash=NULL WHERE device_id=$1 AND grant_id=$2")
        .bind(device).bind(grant).execute(&mut *tx).await?;
    sqlx::query("DELETE FROM assistant_live_activity_wakeups WHERE device_id=$1 AND grant_id=$2")
        .bind(device)
        .bind(grant)
        .execute(&mut *tx)
        .await?;
    tx.commit().await?;
    Ok(StatusCode::NO_CONTENT)
}

/// Called for every MCP tool call: tells open apps right away, and marks the
/// assistant's Live Activity on each of the user's iPhones as changed.
pub async fn record_assistant_activity(
    state: &AppState,
    grant: Uuid,
    tool: &str,
) -> Result<(), AppError> {
    let tool: String = tool
        .chars()
        .filter(|c| c.is_ascii_alphanumeric() || *c == '_')
        .take(64)
        .collect();
    if tool.is_empty() {
        return Ok(());
    }
    let owner = sqlx::query("SELECT s.workspace_id,s.user_id FROM mcp_oauth_grants g JOIN sessions s ON s.id=g.session_id WHERE g.id=$1 AND g.revoked_at IS NULL AND s.revoked_at IS NULL")
        .bind(grant).fetch_optional(&state.pool).await?;
    let Some(owner) = owner else { return Ok(()) };
    let workspace: Uuid = owner.try_get("workspace_id")?;
    let user: Uuid = owner.try_get("user_id")?;
    sqlx::query("SELECT pg_notify('postmere_events_v1',json_build_object('workspace_id',$1::uuid,'user_id',$2::uuid,'kind','assistants')::text)")
        .bind(workspace).bind(user).execute(&state.pool).await?;
    let mut tx = db::scoped_transaction(&state.pool, workspace, user).await?;
    // An activity still showing continues; one that ended starts afresh.
    sqlx::query("UPDATE assistant_live_activities SET
            calls=CASE WHEN ended_at IS NULL THEN calls+1 ELSE 1 END,
            recent=CASE WHEN ended_at IS NULL THEN (ARRAY[$2::text] || recent[1:2]) ELSE ARRAY[$2::text] END,
            started_at=CASE WHEN ended_at IS NULL THEN started_at ELSE clock_timestamp() END,
            start_sent_at=CASE WHEN ended_at IS NULL THEN start_sent_at ELSE NULL END,
            tool=$2,last_event_at=clock_timestamp(),ended_at=NULL
        WHERE grant_id=$1")
        .bind(grant).bind(&tool).execute(&mut *tx).await?;
    // Devices that can be woken with push-to-start get an activity even when none is showing.
    sqlx::query("INSERT INTO assistant_live_activities(device_id,grant_id,workspace_id,user_id,tool,recent)
        SELECT t.device_id,$1,$2,$3,$4,ARRAY[$4::text] FROM live_activity_start_tokens t JOIN push_devices d ON d.id=t.device_id
        JOIN sessions s ON s.id=d.session_id
        WHERE d.disabled_at IS NULL AND s.revoked_at IS NULL
        ON CONFLICT(device_id,grant_id) DO NOTHING")
        .bind(grant).bind(workspace).bind(user).bind(&tool).execute(&mut *tx).await?;
    sqlx::query("INSERT INTO assistant_live_activity_wakeups(device_id,grant_id,workspace_id,user_id,due_at)
        SELECT device_id,grant_id,workspace_id,user_id,clock_timestamp() FROM assistant_live_activities WHERE grant_id=$1 AND ended_at IS NULL
        ON CONFLICT(device_id,grant_id) DO UPDATE SET due_at=least(assistant_live_activity_wakeups.due_at,excluded.due_at)")
        .bind(grant).execute(&mut *tx).await?;
    tx.commit().await?;
    Ok(())
}

pub fn spawn_live_activity_worker(
    state: AppState,
    service: Arc<PushService>,
) -> tokio::task::JoinHandle<()> {
    tokio::spawn(async move {
        loop {
            match process_live_activity(&state, &service).await {
                Ok(true) => {}
                Ok(false) => tokio::time::sleep(std::time::Duration::from_millis(750)).await,
                Err(_) => tokio::time::sleep(std::time::Duration::from_secs(5)).await,
            }
        }
    })
}

enum Event {
    Start,
    Update,
    End,
}

/// Handles one due activity. Public for fixture tests and bounded workers.
pub async fn process_live_activity(
    state: &AppState,
    service: &PushService,
) -> Result<bool, AppError> {
    let Some(transport) = service.transport.as_ref() else {
        return Ok(false);
    };
    let wakeup = sqlx::query("UPDATE assistant_live_activity_wakeups SET lease_until=clock_timestamp()+interval '30 seconds' WHERE (device_id,grant_id)=(SELECT device_id,grant_id FROM assistant_live_activity_wakeups WHERE due_at<=clock_timestamp() AND (lease_until IS NULL OR lease_until<clock_timestamp()) ORDER BY due_at FOR UPDATE SKIP LOCKED LIMIT 1) RETURNING device_id,grant_id,workspace_id,user_id")
        .fetch_optional(&state.pool).await?;
    let Some(wakeup) = wakeup else {
        return Ok(false);
    };
    let device: Uuid = wakeup.try_get("device_id")?;
    let grant: Uuid = wakeup.try_get("grant_id")?;
    let workspace: Uuid = wakeup.try_get("workspace_id")?;
    let user: Uuid = wakeup.try_get("user_id")?;

    let mut lookup = db::scoped_transaction(&state.pool, workspace, user).await?;
    let identity = sqlx::query("SELECT d.session_id,d.environment,m.role FROM push_devices d JOIN memberships m ON m.workspace_id=d.workspace_id AND m.user_id=d.user_id WHERE d.id=$1 AND d.disabled_at IS NULL")
        .bind(device).fetch_optional(&mut *lookup).await?;
    lookup.commit().await?;
    let Some(identity) = identity else {
        remove_wakeup(state, device, grant).await?;
        return Ok(true);
    };
    let auth = AuthContext {
        assistant: false,
        workspace_id: workspace,
        user_id: user,
        session_id: identity.try_get("session_id")?,
        role: identity.try_get("role")?,
    };
    let environment: String = identity.try_get("environment")?;
    let mut tx = match auth.begin_authorized(&state.pool).await {
        Ok(tx) => tx,
        Err(error) if error.status == StatusCode::UNAUTHORIZED => {
            remove_wakeup(state, device, grant).await?;
            return Ok(true);
        }
        Err(error) => return Err(error),
    };
    let row = sqlx::query("SELECT a.token_id,a.encrypted_token,a.tool,a.recent,a.calls,a.started_at,a.last_event_at,a.last_pushed_at,a.start_sent_at,a.ended_at,
            t.token_id start_token_id,t.encrypted_token start_token,c.name client_name,(g.revoked_at IS NOT NULL) revoked
        FROM assistant_live_activities a
        JOIN mcp_oauth_grants g ON g.id=a.grant_id JOIN mcp_oauth_clients c ON c.id=g.client_id
        LEFT JOIN live_activity_start_tokens t ON t.device_id=a.device_id
        WHERE a.device_id=$1 AND a.grant_id=$2 FOR UPDATE OF a")
        .bind(device).bind(grant).fetch_optional(&mut *tx).await?;
    let Some(row) = row else {
        tx.commit().await?;
        remove_wakeup(state, device, grant).await?;
        return Ok(true);
    };
    let now = Utc::now();
    let last_event: DateTime<Utc> = row.try_get("last_event_at")?;
    let last_pushed: Option<DateTime<Utc>> = row.try_get("last_pushed_at")?;
    let ended: Option<DateTime<Utc>> = row.try_get("ended_at")?;
    let revoked: bool = row.try_get("revoked")?;
    let token_id: Option<Uuid> = row.try_get("token_id")?;
    let encrypted: Option<Vec<u8>> = row.try_get("encrypted_token")?;
    let start_sent: Option<DateTime<Utc>> = row.try_get("start_sent_at")?;
    if ended.is_some() {
        delete_wakeup(&mut tx, device, grant).await?;
        tx.commit().await?;
        return Ok(true);
    }
    let idle = revoked || now - last_event >= IDLE;
    let (event, sealed) = match (&token_id, &encrypted) {
        (Some(id), Some(bytes)) if idle => (Some(Event::End), Some((*id, bytes.clone()))),
        (Some(id), Some(bytes)) => {
            if last_pushed.is_some_and(|pushed| pushed >= last_event) {
                (None, None)
            } else if let Some(pushed) = last_pushed.filter(|pushed| now - *pushed < THROTTLE) {
                schedule(&mut tx, device, grant, pushed + THROTTLE).await?;
                tx.commit().await?;
                return Ok(true);
            } else {
                (Some(Event::Update), Some((*id, bytes.clone())))
            }
        }
        _ if idle => (Some(Event::End), None),
        _ if start_sent.is_none() => {
            let start_id: Option<Uuid> = row.try_get("start_token_id")?;
            let start: Option<Vec<u8>> = row.try_get("start_token")?;
            match (start_id, start) {
                (Some(id), Some(bytes)) => (Some(Event::Start), Some((id, bytes))),
                _ => (None, None),
            }
        }
        _ => (None, None),
    };
    if let (Some(event), Some((id, bytes))) = (&event, sealed) {
        let token = Zeroizing::new(
            String::from_utf8(state.crypto.open(workspace, id, &bytes)?.to_vec())
                .map_err(|_| AppError::internal("invalid_live_activity_token"))?,
        );
        let payload = payload(event, &row, grant, now, idle)?;
        let urgent = !matches!(event, Event::Update);
        let result = transport
            .send(PushRequest {
                id: Uuid::new_v4(),
                token,
                environment: environment.clone(),
                expires_at: now + Duration::minutes(10),
                payload,
                kind: PushKind::LiveActivity { urgent },
            })
            .await;
        match (event, result) {
            (Event::Start, DeliveryResult::InvalidToken(_)) => {
                sqlx::query("DELETE FROM live_activity_start_tokens WHERE device_id=$1")
                    .bind(device)
                    .execute(&mut *tx)
                    .await?;
            }
            (_, DeliveryResult::InvalidToken(_)) => {
                sqlx::query("UPDATE assistant_live_activities SET ended_at=clock_timestamp(),token_id=NULL,encrypted_token=NULL,token_hash=NULL WHERE device_id=$1 AND grant_id=$2")
                    .bind(device).bind(grant).execute(&mut *tx).await?;
                delete_wakeup(&mut tx, device, grant).await?;
                tx.commit().await?;
                return Ok(true);
            }
            (Event::Start, _) => {
                sqlx::query("UPDATE assistant_live_activities SET start_sent_at=clock_timestamp(),last_pushed_at=clock_timestamp() WHERE device_id=$1 AND grant_id=$2")
                    .bind(device).bind(grant).execute(&mut *tx).await?;
            }
            _ => {
                sqlx::query("UPDATE assistant_live_activities SET last_pushed_at=clock_timestamp() WHERE device_id=$1 AND grant_id=$2")
                    .bind(device).bind(grant).execute(&mut *tx).await?;
            }
        }
    }
    if idle {
        // An ended activity's token is spent; the next tool call starts a new one.
        sqlx::query("UPDATE assistant_live_activities SET ended_at=clock_timestamp(),token_id=NULL,encrypted_token=NULL,token_hash=NULL WHERE device_id=$1 AND grant_id=$2")
            .bind(device).bind(grant).execute(&mut *tx).await?;
        delete_wakeup(&mut tx, device, grant).await?;
    } else {
        schedule(&mut tx, device, grant, last_event + IDLE).await?;
    }
    tx.commit().await?;
    Ok(true)
}

/// The Live Activity push: what the assistant is doing, in the shape the app's
/// `AssistantActivityAttributes.ContentState` decodes. Times are Unix seconds.
fn payload(
    event: &Event,
    row: &sqlx::postgres::PgRow,
    grant: Uuid,
    now: DateTime<Utc>,
    idle: bool,
) -> Result<Value, AppError> {
    let started: DateTime<Utc> = row.try_get("started_at")?;
    let last: DateTime<Utc> = row.try_get("last_event_at")?;
    let tool: String = row.try_get("tool")?;
    let recent: Vec<String> = row.try_get("recent")?;
    let calls: i32 = row.try_get("calls")?;
    let client: String = row.try_get("client_name")?;
    let client: String = client.chars().take(60).collect();
    let state = json!({
        "tool": tool,
        "recent": recent,
        "calls": calls,
        "startedAt": started.timestamp() as f64,
        "lastAt": last.timestamp() as f64,
        "working": !idle,
    });
    let mut aps = json!({ "timestamp": now.timestamp(), "content-state": state });
    match event {
        Event::Start => {
            aps["event"] = json!("start");
            aps["attributes-type"] = json!("AssistantActivityAttributes");
            aps["attributes"] = json!({ "grantID": grant.to_string(), "clientName": client });
            aps["stale-date"] = json!((last + IDLE).timestamp());
            aps["alert"] = json!({ "title": format!("{client} is working"), "body": "It’s using your Postmere mail." });
        }
        Event::Update => {
            aps["event"] = json!("update");
            aps["stale-date"] = json!((last + IDLE).timestamp());
        }
        Event::End => {
            aps["event"] = json!("end");
            aps["dismissal-date"] = json!((now + Duration::minutes(2)).timestamp());
        }
    }
    Ok(json!({ "aps": aps }))
}

async fn schedule(
    tx: &mut Transaction<'_, Postgres>,
    device: Uuid,
    grant: Uuid,
    due: DateTime<Utc>,
) -> Result<(), AppError> {
    sqlx::query("UPDATE assistant_live_activity_wakeups SET due_at=$3,lease_until=NULL WHERE device_id=$1 AND grant_id=$2")
        .bind(device).bind(grant).bind(due).execute(&mut **tx).await?;
    Ok(())
}

async fn delete_wakeup(
    tx: &mut Transaction<'_, Postgres>,
    device: Uuid,
    grant: Uuid,
) -> Result<(), AppError> {
    sqlx::query("DELETE FROM assistant_live_activity_wakeups WHERE device_id=$1 AND grant_id=$2")
        .bind(device)
        .bind(grant)
        .execute(&mut **tx)
        .await?;
    Ok(())
}

async fn remove_wakeup(state: &AppState, device: Uuid, grant: Uuid) -> Result<(), AppError> {
    sqlx::query("DELETE FROM assistant_live_activity_wakeups WHERE device_id=$1 AND grant_id=$2")
        .bind(device)
        .bind(grant)
        .execute(&state.pool)
        .await?;
    Ok(())
}
