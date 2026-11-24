use crate::{
    AccountPreference, PushService, SENDER_POLICY_VERSION, sender_policy::policy_resource_id,
    transport::valid_token,
};
use axum::{
    Extension, Json, Router,
    extract::{DefaultBodyLimit, Path, State},
    routing::get,
};
use chrono::{DateTime, Utc};
use postmere_core::{AppState, auth::AuthContext, error::AppError};
use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};
use sqlx::{Postgres, Row, Transaction};
use std::{collections::HashSet, sync::Arc};
use uuid::Uuid;
use zeroize::Zeroizing;

pub fn router() -> Router<AppState> {
    Router::new()
        .route(
            "/v1/push/devices/{installation}",
            get(status)
                .put(register)
                .patch(update_preferences)
                .delete(unregister),
        )
        .merge(crate::live::router())
        .layer(DefaultBodyLimit::max(2 * 1024 * 1024))
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct Registration {
    token: String,
    environment: String,
    enabled: bool,
    accounts: Vec<AccountPreference>,
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct PreferenceUpdate {
    enabled: bool,
    accounts: Vec<AccountPreference>,
}

#[derive(Serialize)]
struct DeviceStatus {
    sender_policy_version: u32,
    configured: bool,
    enabled: bool,
    active: bool,
    environment: Option<String>,
    device_id: Uuid,
    account_ids: Vec<Uuid>,
    expires_at: Option<DateTime<Utc>>,
}

async fn status(
    State(state): State<AppState>,
    auth: AuthContext,
    Path(installation): Path<Uuid>,
    service: Option<Extension<Arc<PushService>>>,
) -> Result<Json<DeviceStatus>, AppError> {
    device_status(
        &state,
        &auth,
        installation,
        service.as_ref().map(|e| e.0.as_ref()),
    )
    .await
    .map(Json)
}

async fn device_status(
    state: &AppState,
    auth: &AuthContext,
    installation: Uuid,
    service: Option<&PushService>,
) -> Result<DeviceStatus, AppError> {
    let configured = service.is_some_and(PushService::configured);
    let environment = service.and_then(|s| s.environment.clone());
    let mut result = DeviceStatus {
        sender_policy_version: SENDER_POLICY_VERSION,
        configured,
        enabled: false,
        active: false,
        environment: environment.clone(),
        device_id: installation,
        account_ids: vec![],
        expires_at: None,
    };
    let mut tx = auth.begin_authorized(&state.pool).await?;
    let row=sqlx::query("SELECT d.id,d.enabled,d.environment,least(s.expires_at,s.absolute_expires_at) expires_at FROM push_devices d JOIN sessions s ON s.id=d.session_id JOIN push_token_bindings b ON b.token_hash=d.token_hash AND b.environment=d.environment AND b.device_id=d.id WHERE d.installation_id=$1 AND d.session_id=$2 AND d.disabled_at IS NULL")
        .bind(installation).bind(auth.session_id).fetch_optional(&mut *tx).await?;
    if let Some(row) = row {
        let device: Uuid = row.try_get("id")?;
        result.active = configured
            && environment.as_deref() == Some(row.get::<String, _>("environment").as_str());
        result.enabled = result.active && row.try_get::<bool, _>("enabled")?;
        // Persistent workspace sessions have no registration age deadline.
        // Finite browser/legacy sessions still report their effective expiry.
        result.expires_at = row.try_get("expires_at")?;
        if result.enabled {
            result.account_ids=sqlx::query_scalar("SELECT p.account_id FROM push_preferences p JOIN provider_accounts a ON a.id=p.account_id WHERE p.device_id=$1 AND p.enabled AND a.disabled_at IS NULL AND a.status='connected' ORDER BY p.account_id")
                .bind(device).fetch_all(&mut *tx).await?;
        }
    }
    tx.commit().await?;
    Ok(result)
}

async fn register(
    State(state): State<AppState>,
    auth: AuthContext,
    Path(installation): Path<Uuid>,
    service: Option<Extension<Arc<PushService>>>,
    Json(input): Json<Registration>,
) -> Result<Json<DeviceStatus>, AppError> {
    let mut token = Zeroizing::new(input.token);
    token.make_ascii_lowercase();
    if !valid_token(&token) || !matches!(input.environment.as_str(), "sandbox" | "production") {
        return Err(AppError::bad_request("Invalid push registration."));
    }
    let unique = validate_preferences(&input.accounts)?;
    state
        .auth
        .rate_limit(
            "push_registration",
            &format!("{}:{}", auth.workspace_id, auth.user_id),
            120,
        )
        .await?;
    let effective_enabled = input.enabled
        && service.as_ref().is_some_and(|s| {
            s.0.configured() && s.0.environment.as_deref() == Some(input.environment.as_str())
        });
    let mut tx = auth.begin_authorized(&state.pool).await?;
    sqlx::query("SELECT pg_advisory_xact_lock(hashtextextended($1,0))")
        .bind(format!(
            "pushdevices:{}:{}",
            auth.workspace_id, auth.user_id
        ))
        .execute(&mut *tx)
        .await?;
    for preference in &input.accounts {
        let exists: bool = sqlx::query_scalar(
            "SELECT EXISTS(SELECT 1 FROM provider_accounts WHERE id=$1 AND disabled_at IS NULL)",
        )
        .bind(preference.account_id)
        .fetch_one(&mut *tx)
        .await?;
        if !exists {
            return Err(AppError::not_found());
        }
    }
    let existing: Option<Uuid> =
        sqlx::query_scalar("SELECT id FROM push_devices WHERE installation_id=$1")
            .bind(installation)
            .fetch_optional(&mut *tx)
            .await?;
    if existing.is_none() {
        let count: i64 =
            sqlx::query_scalar("SELECT count(*) FROM push_devices d JOIN sessions s ON s.id=d.session_id WHERE d.disabled_at IS NULL AND s.revoked_at IS NULL AND (s.expires_at IS NULL OR s.expires_at>clock_timestamp()) AND (s.absolute_expires_at IS NULL OR s.absolute_expires_at>clock_timestamp())")
                .fetch_one(&mut *tx)
                .await?;
        if count >= 32 {
            return Err(AppError::conflict(
                "Remove an old notification device before adding another.",
            ));
        }
    }
    let device = existing.unwrap_or_else(Uuid::new_v4);
    let encrypted = state
        .crypto
        .seal(auth.workspace_id, device, token.as_bytes())?;
    let hash = Sha256::digest(token.as_bytes()).to_vec();
    // Lock token binding before device rows in both registration and delivery.
    sqlx::query("INSERT INTO push_token_bindings(token_hash,environment,device_id) SELECT $1,$2,$3 WHERE EXISTS(SELECT 1 FROM push_devices WHERE id=$3) ON CONFLICT(token_hash,environment) DO UPDATE SET device_id=excluded.device_id")
        .bind(&hash).bind(&input.environment).bind(device).execute(&mut *tx).await?;
    sqlx::query("INSERT INTO push_devices(id,installation_id,workspace_id,user_id,session_id,encrypted_token,token_hash,environment,enabled) VALUES($1,$2,$3,$4,$5,$6,$7,$8,$9) ON CONFLICT(workspace_id,user_id,installation_id) DO UPDATE SET session_id=excluded.session_id,encrypted_token=excluded.encrypted_token,token_hash=excluded.token_hash,environment=excluded.environment,enabled=excluded.enabled,first_registered_at=CASE WHEN push_devices.session_id<>excluded.session_id OR push_devices.disabled_at IS NOT NULL OR (NOT push_devices.enabled AND excluded.enabled) THEN clock_timestamp() ELSE push_devices.first_registered_at END,registered_at=clock_timestamp(),disabled_at=NULL")
        .bind(device).bind(installation).bind(auth.workspace_id).bind(auth.user_id).bind(auth.session_id).bind(encrypted).bind(&hash).bind(&input.environment).bind(effective_enabled).execute(&mut *tx).await?;
    sqlx::query("INSERT INTO push_token_bindings(token_hash,environment,device_id) VALUES($1,$2,$3) ON CONFLICT(token_hash,environment) DO UPDATE SET device_id=excluded.device_id")
        .bind(hash).bind(&input.environment).bind(device).execute(&mut *tx).await?;
    save_preferences(&state, &auth, &mut tx, device, input.accounts, unique).await?;
    auth.authorize_in_transaction(&mut tx).await?;
    tx.commit().await?;
    device_status(
        &state,
        &auth,
        installation,
        service.as_ref().map(|e| e.0.as_ref()),
    )
    .await
    .map(Json)
}

fn validate_preferences(accounts: &[AccountPreference]) -> Result<HashSet<Uuid>, AppError> {
    let mut unique = HashSet::new();
    for preference in accounts {
        preference.validate()?;
        if !unique.insert(preference.account_id) {
            return Err(AppError::bad_request("Duplicate notification account."));
        }
    }
    Ok(unique)
}

async fn save_preferences(
    state: &AppState,
    auth: &AuthContext,
    tx: &mut Transaction<'_, Postgres>,
    device: Uuid,
    accounts: Vec<AccountPreference>,
    unique: HashSet<Uuid>,
) -> Result<(), AppError> {
    sqlx::query(
        "UPDATE push_preferences SET enabled=false WHERE device_id=$1 AND NOT(account_id=ANY($2))",
    )
    .bind(device)
    .bind(unique.into_iter().collect::<Vec<_>>())
    .execute(&mut **tx)
    .await?;
    for mut preference in accounts {
        let encrypted = preference
            .sender_policy
            .take()
            .map(|policy| {
                let bytes = Zeroizing::new(
                    serde_json::to_vec(&policy)
                        .map_err(|_| AppError::internal("push_policy_encode"))?,
                );
                state.crypto.seal(
                    auth.workspace_id,
                    policy_resource_id(auth.user_id, device, preference.account_id),
                    &bytes,
                )
            })
            .transpose()?;
        sqlx::query("INSERT INTO push_preferences(workspace_id,user_id,device_id,account_id,enabled,settings,encrypted_sender_policy) VALUES($1,$2,$3,$4,$5,$6,$7) ON CONFLICT(device_id,account_id) DO UPDATE SET enabled=excluded.enabled,settings=excluded.settings,encrypted_sender_policy=excluded.encrypted_sender_policy,enabled_since=CASE WHEN NOT push_preferences.enabled AND excluded.enabled THEN clock_timestamp() ELSE push_preferences.enabled_since END")
            .bind(auth.workspace_id).bind(auth.user_id).bind(device).bind(preference.account_id).bind(preference.enabled)
            .bind(serde_json::to_value(preference).map_err(|_|AppError::internal("push_preferences_encode"))?).bind(encrypted).execute(&mut **tx).await?;
    }
    // Re-evaluate quiet-hour jobs promptly after policy/consent changes instead
    // of waiting for their old delivery window. The worker still takes locks.
    // Preserve an active worker lease: resetting it could let another worker
    // interpret the first worker's committed claim as an interrupted send.
    sqlx::query("UPDATE push_delivery_wakeups w SET due_at=least(w.due_at,clock_timestamp()) FROM push_deliveries j WHERE j.id=w.job_id AND j.device_id=$1 AND j.status='pending'")
        .bind(device).execute(&mut **tx).await?;
    Ok(())
}

async fn update_preferences(
    State(state): State<AppState>,
    auth: AuthContext,
    Path(installation): Path<Uuid>,
    service: Option<Extension<Arc<PushService>>>,
    Json(input): Json<PreferenceUpdate>,
) -> Result<Json<DeviceStatus>, AppError> {
    let unique = validate_preferences(&input.accounts)?;
    state
        .auth
        .rate_limit(
            "push_registration",
            &format!("{}:{}", auth.workspace_id, auth.user_id),
            120,
        )
        .await?;
    let mut tx = auth.begin_authorized(&state.pool).await?;
    sqlx::query("SELECT pg_advisory_xact_lock(hashtextextended($1,0))")
        .bind(format!(
            "pushdevices:{}:{}",
            auth.workspace_id, auth.user_id
        ))
        .execute(&mut *tx)
        .await?;
    let row = sqlx::query("SELECT id,token_hash,environment FROM push_devices WHERE installation_id=$1 AND session_id=$2 AND disabled_at IS NULL")
        .bind(installation).bind(auth.session_id).fetch_optional(&mut *tx).await?.ok_or_else(AppError::not_found)?;
    let device: Uuid = row.try_get("id")?;
    let hash: Vec<u8> = row.try_get("token_hash")?;
    let environment: String = row.try_get("environment")?;
    let binding: Option<Uuid> = sqlx::query_scalar("SELECT device_id FROM push_token_bindings WHERE token_hash=$1 AND environment=$2 FOR SHARE")
        .bind(&hash).bind(&environment).fetch_optional(&mut *tx).await?;
    if binding != Some(device) {
        return Err(AppError::not_found());
    }
    for preference in &input.accounts {
        let exists: bool = sqlx::query_scalar(
            "SELECT EXISTS(SELECT 1 FROM provider_accounts WHERE id=$1 AND disabled_at IS NULL)",
        )
        .bind(preference.account_id)
        .fetch_one(&mut *tx)
        .await?;
        if !exists {
            return Err(AppError::not_found());
        }
    }
    let enabled = input.enabled
        && service.as_ref().is_some_and(|s| {
            s.0.configured() && s.0.environment.as_deref() == Some(environment.as_str())
        });
    let updated = sqlx::query("UPDATE push_devices SET enabled=$3,first_registered_at=CASE WHEN NOT enabled AND $3 THEN clock_timestamp() ELSE first_registered_at END WHERE id=$1 AND session_id=$2 AND token_hash=$4 AND environment=$5 AND disabled_at IS NULL")
        .bind(device).bind(auth.session_id).bind(enabled).bind(hash).bind(environment).execute(&mut *tx).await?;
    if updated.rows_affected() != 1 {
        return Err(AppError::not_found());
    }
    save_preferences(&state, &auth, &mut tx, device, input.accounts, unique).await?;
    auth.authorize_in_transaction(&mut tx).await?;
    tx.commit().await?;
    device_status(
        &state,
        &auth,
        installation,
        service.as_ref().map(|e| e.0.as_ref()),
    )
    .await
    .map(Json)
}

async fn unregister(
    State(state): State<AppState>,
    auth: AuthContext,
    Path(installation): Path<Uuid>,
) -> Result<Json<serde_json::Value>, AppError> {
    let mut tx = auth.begin_authorized(&state.pool).await?;
    sqlx::query("UPDATE push_devices SET enabled=false,disabled_at=clock_timestamp() WHERE installation_id=$1 AND session_id=$2").bind(installation).bind(auth.session_id).execute(&mut *tx).await?;
    auth.authorize_in_transaction(&mut tx).await?;
    tx.commit().await?;
    Ok(Json(serde_json::json!({})))
}
