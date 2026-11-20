//! Tenant- and user-scoped mail storage, OAuth, and a durable send queue.
use axum::{
    Json, Router,
    extract::{Path, Query, State},
    http::{HeaderMap, HeaderValue, header},
    response::{Html, IntoResponse},
    routing::{get, post},
};
use base64::{
    Engine,
    engine::general_purpose::{STANDARD, URL_SAFE_NO_PAD},
};
use chrono::{DateTime, Duration, Utc};
use postmere_core::{
    AppState,
    auth::AuthContext,
    db,
    error::AppError,
    tokens::{parse_scoped_token, random_token, scoped_token, token_hash},
};
use postmere_providers::{
    self as provider, Credentials, Identity, Message, MessagePage, Mutation, Outgoing, Provider,
    ProviderError,
};
use postmere_tracking as tracking;
use serde::{Deserialize, Serialize};
use serde_json::{Value, json};
use sha2::{Digest, Sha256};
use sqlx::{Postgres, Row, Transaction};
use uuid::Uuid;
use zeroize::Zeroizing;

pub fn router() -> Router<AppState> {
    Router::new()
        .merge(crate::mail_labels::router(crate::mail_labels::HttpLabels))
        .route("/v1/mail/accounts", get(accounts))
        .route("/v1/mail/accounts/{id}", axum::routing::delete(disconnect))
        .route("/v1/mail/oauth/{provider}/start", post(oauth_start))
        .route("/v1/mail/oauth/{provider}/callback", get(oauth_callback))
        .route("/v1/mail/oauth/connections/{id}", get(oauth_status))
        .route("/v1/mail/accounts/{id}/sync", post(sync))
        .route("/v1/mail/accounts/{id}/search", post(deep_search))
        .route("/v1/mail/messages", get(list_messages))
        .route(
            "/v1/mail/messages/{id}",
            get(get_message).patch(mutate_message),
        )
        .route(
            "/v1/mail/messages/{id}/sender-mark",
            get(crate::sender_mark::get),
        )
        .route(
            "/v1/mail/messages/{id}/calendar-invitation",
            get(calendar_invitation),
        )
        .route(
            "/v1/mail/messages/{id}/attachments/{attachment}",
            get(attachment),
        )
        .route("/v1/mail/outbox", post(queue_message).get(outbox))
        .route("/v1/mail/outbox/{id}/cancel", post(cancel))
        .route("/v1/mail/outbox/{id}/retry", post(retry))
}

#[derive(Serialize, Deserialize)]
pub struct AccountSyncStatus {
    pub phase: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub retry_at: Option<DateTime<Utc>>,
}

// Summarize the durable scheduler state without scanning mail or exposing a
// provider cursor. Both public read paths use this same projection under RLS.
macro_rules! account_status_query {
    ($fields:literal, $filter:literal) => {
        concat!("SELECT ", $fields, "CASE WHEN a.status <> 'connected' THEN NULL ELSE jsonb_strip_nulls(jsonb_build_object(
    'phase', CASE
        WHEN s.last_error IS NOT NULL AND w.due_at>now() THEN 'retrying'
        WHEN s.last_error IS NOT NULL THEN 'syncing'
        WHEN a.last_synced_at IS NULL OR s.checkpoint->>'phase'='full' OR s.checkpoint->>'backfill_cursor' IS NOT NULL
            OR (coalesce(s.checkpoint->>'phase','')='' AND s.checkpoint->>'cursor' IS NOT NULL) THEN 'importing'
        WHEN w.lease_until>now() OR s.checkpoint->>'cursor' IS NOT NULL
            OR coalesce(jsonb_array_length(s.checkpoint->'pending_ids'),0)>0 THEN 'syncing'
        ELSE 'up_to_date' END,
    'retry_at',CASE WHEN s.last_error IS NOT NULL AND w.due_at>now() THEN w.due_at END)) END AS sync_status ", "FROM provider_accounts a LEFT JOIN mail_sync_state s ON s.account_id=a.id LEFT JOIN mail_sync_wakeups w ON w.account_id=a.id ", $filter)
    };
}

fn status_column(row: &sqlx::postgres::PgRow) -> Result<Option<AccountSyncStatus>, AppError> {
    Ok(row
        .try_get::<Option<sqlx::types::Json<AccountSyncStatus>>, _>("sync_status")?
        .map(|value| value.0))
}

#[derive(Serialize)]
pub struct Account {
    pub id: Uuid,
    pub provider: String,
    pub email: String,
    pub display_name: Option<String>,
    pub status: String,
    pub last_synced_at: Option<DateTime<Utc>>,
    pub capabilities: Vec<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub sync_status: Option<AccountSyncStatus>,
}
pub struct AccountSession {
    pub account: Account,
    pub credentials: Credentials,
}

fn account_row(row: &sqlx::postgres::PgRow) -> Result<Account, AppError> {
    Ok(Account {
        id: row.try_get("id")?,
        provider: row.try_get("provider")?,
        email: row.try_get("email")?,
        display_name: row.try_get("display_name")?,
        status: row.try_get("status")?,
        last_synced_at: row.try_get("last_synced_at")?,
        capabilities: row.try_get("capabilities")?,
        sync_status: None,
    })
}

async fn accounts(
    State(state): State<AppState>,
    auth: AuthContext,
) -> Result<Json<Vec<Account>>, AppError> {
    Ok(Json(list_accounts(&state, &auth).await?))
}

pub async fn list_accounts(state: &AppState, auth: &AuthContext) -> Result<Vec<Account>, AppError> {
    let mut tx = auth.begin_authorized(&state.pool).await?;
    let query = account_status_query!(
        "a.id,a.provider,a.email,a.display_name,a.status,a.last_synced_at,a.capabilities,",
        "WHERE a.disabled_at IS NULL ORDER BY a.created_at,a.id"
    );
    let rows = sqlx::query(query).fetch_all(&mut *tx).await?;
    let mut result = Vec::with_capacity(rows.len());
    for row in &rows {
        let mut account = account_row(row)?;
        account.sync_status = status_column(row)?;
        result.push(account);
    }
    tx.commit().await?;
    Ok(result)
}

async fn disconnect(
    State(state): State<AppState>,
    auth: AuthContext,
    Path(id): Path<Uuid>,
) -> Result<Json<Value>, AppError> {
    let mut tx = auth.begin_authorized(&state.pool).await?;
    disconnect_in_transaction(&mut tx, &auth, id).await?;
    tx.commit().await?;
    Ok(Json(json!({})))
}

/// Hold current authorization and serialize with mailbox synchronization before
/// locking account/wakeup rows. Callers which inspect the account FOR UPDATE
/// first must acquire the same account-operation lock before that inspection.
pub async fn disconnect_in_transaction(
    tx: &mut Transaction<'_, Postgres>,
    auth: &AuthContext,
    id: Uuid,
) -> Result<(), AppError> {
    auth.authorize_in_transaction(tx).await?;
    crate::mail_sync::account_operation_lock(tx, auth.workspace_id, auth.user_id, id).await?;
    auth.authorize_in_transaction(tx).await?;
    let changed=sqlx::query("UPDATE provider_accounts SET disabled_at=now(),updated_at=now() WHERE id=$1 AND disabled_at IS NULL").bind(id).execute(&mut **tx).await?;
    if changed.rows_affected() == 0 {
        return Err(AppError::not_found());
    }
    sqlx::query("UPDATE mail_outbox SET status='cancelled',updated_at=now() WHERE account_id=$1 AND status='pending'").bind(id).execute(&mut **tx).await?;
    sqlx::query("UPDATE calendar_sharing SET enabled=false,updated_at=now() WHERE account_id=$1")
        .bind(id)
        .execute(&mut **tx)
        .await?;
    sqlx::query("DELETE FROM mail_sync_wakeups WHERE account_id=$1")
        .bind(id)
        .execute(&mut **tx)
        .await?;
    Ok(())
}

/// Called only after the bearer session has been authenticated.
pub async fn account_session(
    state: &AppState,
    auth: &AuthContext,
    id: Uuid,
) -> Result<AccountSession, AppError> {
    scoped_account_session(state, auth.workspace_id, auth.user_id, id).await
}
/// Only for a nonce-verified booking or a server-owned background job. Active
/// membership and account ownership are checked again before tokens are opened.
pub async fn service_account_session(
    state: &AppState,
    workspace: Uuid,
    user: Uuid,
    id: Uuid,
) -> Result<AccountSession, AppError> {
    scoped_account_session(state, workspace, user, id).await
}

async fn scoped_account_session(
    state: &AppState,
    workspace: Uuid,
    user: Uuid,
    id: Uuid,
) -> Result<AccountSession, AppError> {
    let mut tx = db::scoped_transaction(&state.pool, workspace, user).await?;
    if !active_membership(&mut tx, workspace, user).await? {
        return Err(AppError::forbidden());
    }
    // Row locking serializes refresh-token rotation across all server instances.
    let row = sqlx::query(
        "SELECT * FROM provider_accounts WHERE id=$1 AND disabled_at IS NULL FOR UPDATE",
    )
    .bind(id)
    .fetch_optional(&mut *tx)
    .await?
    .ok_or_else(AppError::not_found)?;
    let mut account = account_row(&row)?;
    let encrypted: Vec<u8> = row.try_get("encrypted_credentials")?;
    let bytes = state.crypto.open(workspace, id, &encrypted)?;
    let mut credentials: Credentials = serde_json::from_slice(&bytes)
        .map_err(|_| AppError::internal("invalid_provider_credentials"))?;
    if credentials.expires_at < Utc::now() + Duration::seconds(90) {
        match provider::refresh(state, Provider::parse(&account.provider)?, &credentials).await {
            Ok(updated) => {
                credentials = updated;
                if !provider::has_calendar_scope(Provider::parse(&account.provider)?, &credentials)
                {
                    account.capabilities.retain(|c| c != "calendar");
                }
                account.status = "connected".into();
                let encoded = Zeroizing::new(
                    serde_json::to_vec(&credentials)
                        .map_err(|_| AppError::internal("provider_credentials_encode"))?,
                );
                let encrypted = state.crypto.seal(workspace, id, &encoded)?;
                sqlx::query("UPDATE provider_accounts SET encrypted_credentials=$2,status='connected',capabilities=$3,updated_at=now() WHERE id=$1").bind(id).bind(encrypted).bind(&account.capabilities).execute(&mut *tx).await?;
            }
            Err(error) => {
                if error.status.is_client_error() {
                    sqlx::query("UPDATE provider_accounts SET status='reconnect_required',updated_at=now() WHERE id=$1").bind(id).execute(&mut *tx).await?;
                    tx.commit().await?;
                }
                return Err(error);
            }
        }
    }
    tx.commit().await?;
    Ok(AccountSession {
        account,
        credentials,
    })
}

async fn active_membership(
    tx: &mut Transaction<'_, Postgres>,
    workspace: Uuid,
    user: Uuid,
) -> Result<bool, AppError> {
    Ok(sqlx::query_scalar("SELECT EXISTS(SELECT 1 FROM memberships m JOIN users u ON u.id=m.user_id JOIN workspaces w ON w.id=m.workspace_id WHERE m.workspace_id=$1 AND m.user_id=$2 AND m.revoked_at IS NULL AND u.disabled_at IS NULL AND w.disabled_at IS NULL)").bind(workspace).bind(user).fetch_one(&mut **tx).await?)
}

#[derive(Default, Deserialize)]
struct OAuthStartRequest {
    #[serde(default)]
    calendar_access: bool,
}
async fn oauth_start(
    State(state): State<AppState>,
    auth: AuthContext,
    Path(provider): Path<String>,
    Json(request): Json<OAuthStartRequest>,
) -> Result<Json<Value>, AppError> {
    let provider = Provider::parse(&provider)?;
    let id = Uuid::new_v4();
    let token = scoped_token(auth.workspace_id, auth.user_id, id)?;
    let verifier = Zeroizing::new(random_token()?);
    let authorization_url = provider.authorize_url_with_calendar(
        &state.config,
        &token,
        &verifier,
        request.calendar_access,
    )?;
    let expires_at = Utc::now() + Duration::minutes(10);
    let encrypted = state
        .crypto
        .seal(auth.workspace_id, id, verifier.as_bytes())?;
    let mut tx = auth.begin(&state.pool).await?;
    // Serialize only this user's unfinished handshakes. This bounds concurrent
    // OAuth work without imposing any limit on connected mail accounts.
    sqlx::query("SELECT pg_advisory_xact_lock(hashtextextended($1,0))")
        .bind(format!("mail-oauth:{}:{}", auth.workspace_id, auth.user_id))
        .execute(&mut *tx)
        .await?;
    sqlx::query("DELETE FROM mail_oauth_connections WHERE expires_at<now()-interval '1 day'")
        .execute(&mut *tx)
        .await?;
    let pending:i64=sqlx::query_scalar("SELECT count(*) FROM mail_oauth_connections WHERE status IN ('pending','exchanging') AND expires_at>now()").fetch_one(&mut *tx).await?;
    if pending >= 10 {
        return Err(AppError::rate_limited());
    }
    sqlx::query("INSERT INTO mail_oauth_connections(id,workspace_id,user_id,provider,state_hash,encrypted_verifier,expires_at,requested_calendar) VALUES($1,$2,$3,$4,$5,$6,$7,$8)").bind(id).bind(auth.workspace_id).bind(auth.user_id).bind(provider.as_str()).bind(token_hash(&token)).bind(encrypted).bind(expires_at).bind(request.calendar_access).execute(&mut *tx).await?;
    tx.commit().await?;
    Ok(Json(
        json!({"connection_id":id,"authorization_url":authorization_url,"expires_at":expires_at}),
    ))
}

#[derive(Deserialize)]
struct Callback {
    state: String,
    code: Option<String>,
    error: Option<String>,
}

pub type OAuthFuture<'a> = std::pin::Pin<
    Box<dyn std::future::Future<Output = Result<(Credentials, Identity), AppError>> + Send + 'a>,
>;

/// Only provider I/O is substituted in fixtures. Nonce validation, account
/// ownership, identity persistence and reconnect behavior use the same path.
pub trait OAuthTransport: Send + Sync {
    fn connect<'a>(
        &'a self,
        state: &'a AppState,
        provider: Provider,
        code: &'a str,
        verifier: &'a str,
    ) -> OAuthFuture<'a>;
}

struct HttpOAuth;
impl OAuthTransport for HttpOAuth {
    fn connect<'a>(
        &'a self,
        state: &'a AppState,
        provider: Provider,
        code: &'a str,
        verifier: &'a str,
    ) -> OAuthFuture<'a> {
        Box::pin(async move {
            let credentials = provider::exchange_code(state, provider, code, verifier).await?;
            let identity = provider::identity(state, provider, &credentials.access_token).await?;
            Ok((credentials, identity))
        })
    }
}

async fn oauth_callback(
    State(state): State<AppState>,
    Path(provider): Path<String>,
    Query(callback): Query<Callback>,
) -> Result<Html<&'static str>, AppError> {
    let provider = Provider::parse(&provider)?;
    complete_oauth_with(
        &state,
        provider,
        &callback.state,
        callback.code.as_deref(),
        callback.error.is_some(),
        &HttpOAuth,
    )
    .await
}

pub async fn complete_oauth_with(
    state: &AppState,
    provider: Provider,
    token: &str,
    code: Option<&str>,
    declined: bool,
    transport: &impl OAuthTransport,
) -> Result<Html<&'static str>, AppError> {
    let (workspace, user, id) = parse_scoped_token(token)?;
    let mut tx = db::scoped_transaction(&state.pool, workspace, user).await?;
    let row=sqlx::query("SELECT encrypted_verifier,requested_calendar FROM mail_oauth_connections WHERE id=$1 AND state_hash=$2 AND provider=$3 AND status='pending' AND expires_at>now() FOR UPDATE").bind(id).bind(token_hash(token)).bind(provider.as_str()).fetch_optional(&mut *tx).await?.ok_or_else(AppError::not_found)?;
    if !active_membership(&mut tx, workspace, user).await? {
        return Err(AppError::forbidden());
    }
    let encrypted: Vec<u8> = row.try_get("encrypted_verifier")?;
    let requested_calendar: bool = row.try_get("requested_calendar")?;
    sqlx::query("UPDATE mail_oauth_connections SET status='exchanging' WHERE id=$1")
        .bind(id)
        .execute(&mut *tx)
        .await?;
    tx.commit().await?;
    let result=async{
        if declined{return Err(AppError::bad_request("Account connection was declined."))}
        let code=code.filter(|c|!c.is_empty()&&c.len()<16_384).ok_or_else(||AppError::bad_request("The provider returned no authorization code."))?;
        let plain=state.crypto.open(workspace,id,&encrypted)?;
        let verifier=std::str::from_utf8(&plain).map_err(|_|AppError::internal("oauth_verifier_decode"))?;
        let (credentials,mut identity)=transport.connect(state,provider,code,verifier).await?;
        let capabilities:Vec<String>=if requested_calendar&&provider::has_calendar_scope(provider,&credentials){vec!["calendar".into()]}else{vec![]};
        identity.email=identity.email.to_lowercase();
        if !provider::valid_email(&identity.email){return Err(AppError::bad_request("The provider returned an invalid account identity."))}
        let mut tx=db::scoped_transaction(&state.pool,workspace,user).await?;
        if !active_membership(&mut tx,workspace,user).await?{return Err(AppError::forbidden())}
        // Row locks cannot serialize the first insert when no account exists.
        // Keep simultaneous callbacks for one scoped provider identity on the
        // same stable account ID without blocking other connected accounts.
        sqlx::query("SELECT pg_advisory_xact_lock(hashtextextended($1,0))")
            .bind(format!("mail-account:{workspace}:{user}:{}:{}",provider.as_str(),identity.email))
            .execute(&mut *tx).await?;
        let existing:Option<Uuid>=sqlx::query_scalar("SELECT id FROM provider_accounts WHERE provider=$1 AND email=$2 FOR UPDATE").bind(provider.as_str()).bind(&identity.email).fetch_optional(&mut *tx).await?;
        // Authorization may change while either identity or account locks wait.
        // Hold the current membership through commit so revocation cannot race
        // the final credential installation.
        let active:Option<Uuid>=sqlx::query_scalar("SELECT m.user_id FROM memberships m JOIN users u ON u.id=m.user_id JOIN workspaces w ON w.id=m.workspace_id WHERE m.workspace_id=$1 AND m.user_id=$2 AND m.revoked_at IS NULL AND u.disabled_at IS NULL AND w.disabled_at IS NULL FOR SHARE OF m,u,w").bind(workspace).bind(user).fetch_optional(&mut *tx).await?;
        if active.is_none(){return Err(AppError::forbidden())}
        let account_id=existing.unwrap_or_else(Uuid::new_v4);
        let encoded=Zeroizing::new(serde_json::to_vec(&credentials).map_err(|_|AppError::internal("provider_credentials_encode"))?);
        let sealed=state.crypto.seal(workspace,account_id,&encoded)?;
        sqlx::query("INSERT INTO provider_accounts(id,workspace_id,user_id,provider,email,encrypted_credentials,display_name,status,capabilities) VALUES($1,$2,$3,$4,$5,$6,$7,'connected',$8) ON CONFLICT(id) DO UPDATE SET encrypted_credentials=excluded.encrypted_credentials,display_name=excluded.display_name,status='connected',disabled_at=NULL,capabilities=excluded.capabilities,updated_at=now()").bind(account_id).bind(workspace).bind(user).bind(provider.as_str()).bind(identity.email).bind(sealed).bind(identity.display_name).bind(capabilities).execute(&mut *tx).await?;
        sqlx::query("UPDATE mail_oauth_connections SET status='connected',account_id=$2,encrypted_verifier=''::bytea WHERE id=$1").bind(id).bind(account_id).execute(&mut *tx).await?;
        crate::mail_sync::schedule_account(&mut tx,workspace,user,account_id).await?;
        tx.commit().await?;Ok::<(),AppError>(())
    }.await;
    if result.is_err() {
        let mut tx = db::scoped_transaction(&state.pool, workspace, user).await?;
        sqlx::query("UPDATE mail_oauth_connections SET status='failed',error_code='connection_failed',encrypted_verifier=''::bytea WHERE id=$1").bind(id).execute(&mut *tx).await?;
        tx.commit().await?;
        return Ok(Html(
            "<!doctype html><title>Postmere</title><p>The mail account could not be connected. Return to Postmere to try again.</p>",
        ));
    }
    Ok(Html(
        "<!doctype html><title>Postmere</title><p>Your mail account is connected. You can close this window and return to Postmere.</p>",
    ))
}

async fn oauth_status(
    State(state): State<AppState>,
    auth: AuthContext,
    Path(id): Path<Uuid>,
) -> Result<Json<Value>, AppError> {
    let mut tx = auth.begin(&state.pool).await?;
    let row = sqlx::query(
        "SELECT status,account_id,error_code,expires_at FROM mail_oauth_connections WHERE id=$1",
    )
    .bind(id)
    .fetch_optional(&mut *tx)
    .await?
    .ok_or_else(AppError::not_found)?;
    let mut status: String = row.try_get("status")?;
    let expires: DateTime<Utc> = row.try_get("expires_at")?;
    if expires < Utc::now() && (status == "pending" || status == "exchanging") {
        status = "failed".into()
    }
    let value = json!({"status":status,"account_id":row.try_get::<Option<Uuid>,_>("account_id")?,"error":row.try_get::<Option<String>,_>("error_code")?});
    tx.commit().await?;
    Ok(Json(value))
}

#[derive(Default, Deserialize)]
struct SyncRequest {
    cursor: Option<String>,
    limit: Option<usize>,
    /// False consumes durable cache changes without starting another provider
    /// request. Realtime invalidations use this path to avoid refresh loops.
    refresh_provider: Option<bool>,
}
#[derive(Deserialize)]
struct SearchRequest {
    query: String,
    cursor: Option<String>,
    limit: Option<usize>,
}
async fn sync(
    State(state): State<AppState>,
    auth: AuthContext,
    Path(id): Path<Uuid>,
    Json(request): Json<SyncRequest>,
) -> Result<Json<ChangePage>, AppError> {
    // A client cache cursor is independent of the server's provider checkpoint.
    // It catches changes already fetched while the desktop app was closed.
    if request.refresh_provider.unwrap_or(true) {
        // The worker owns provider I/O. Returning the cache immediately also
        // prevents desktop pagination and simultaneous windows doing duplicate
        // mailbox fetches or waiting behind a slow Gmail page.
        let mut tx = auth.begin_authorized(&state.pool).await?;
        let connected: Option<bool> = sqlx::query_scalar(
            "SELECT status='connected' FROM provider_accounts WHERE id=$1 AND disabled_at IS NULL",
        )
        .bind(id)
        .fetch_optional(&mut *tx)
        .await?;
        let connected = connected.ok_or_else(AppError::not_found)?;
        let idle: bool =
            sqlx::query_scalar("SELECT pg_try_advisory_xact_lock(hashtextextended($1,0))")
                .bind(format!(
                    "mail-sync:{}:{}:{id}",
                    auth.workspace_id, auth.user_id
                ))
                .fetch_one(&mut *tx)
                .await?;
        // An active worker already owns the wakeup row while fetching. Skip the
        // upsert so returning the cache cannot block on that transaction.
        if connected && idle {
            sqlx::query("INSERT INTO mail_sync_wakeups(account_id,workspace_id,user_id,due_at) VALUES($1,$2,$3,now()) ON CONFLICT(account_id) DO UPDATE SET due_at=now() WHERE mail_sync_wakeups.due_at>now() AND (mail_sync_wakeups.lease_until IS NULL OR mail_sync_wakeups.lease_until<now())")
                .bind(id).bind(auth.workspace_id).bind(auth.user_id).execute(&mut *tx).await?;
        }
        tx.commit().await?;
    }
    Ok(Json(
        cached_changes(
            &state,
            &auth,
            id,
            request.cursor.as_deref(),
            request.limit.unwrap_or(100),
        )
        .await?,
    ))
}

async fn deep_search(
    State(state): State<AppState>,
    auth: AuthContext,
    Path(id): Path<Uuid>,
    Json(request): Json<SearchRequest>,
) -> Result<Json<MessagePage>, AppError> {
    if request.query.len() > 4_096 {
        return Err(AppError::bad_request("Use a shorter provider search."));
    }
    let session = account_session(&state, &auth, id).await?;
    let mut tx = auth.begin(&state.pool).await?;
    crate::mail_sync::account_operation_lock(&mut tx, auth.workspace_id, auth.user_id, id).await?;
    let mut page = provider::fetch_page(
        &state,
        Provider::parse(&session.account.provider)?,
        id,
        &session.credentials.access_token,
        Some(&request.query),
        request.cursor.as_deref(),
        request.limit.unwrap_or(25),
    )
    .await?;
    classify_mailboxes(&state, &session, &mut page.messages, None).await?;
    persist_messages(&mut tx, &auth, &mut page.messages).await?;
    tx.commit().await?;
    Ok(Json(page))
}
pub(crate) async fn classify_mailboxes(
    state: &AppState,
    session: &AccountSession,
    messages: &mut [Message],
    cached_junk_label: Option<&str>,
) -> Result<Option<String>, AppError> {
    if session.account.provider != "microsoft" {
        return Ok(Some("SPAM".into()));
    }
    let folders =
        provider::graph_folders(state, &session.credentials.access_token, cached_junk_label)
            .await?;
    Ok(apply_graph_folders(messages, folders))
}

fn apply_graph_folders(messages: &mut [Message], folders: Vec<(String, String)>) -> Option<String> {
    for message in messages {
        if let Some((_, mailbox)) = folders
            .iter()
            .find(|(id, _)| message.provider_labels.contains(id))
        {
            message.mailbox = mailbox.clone()
        }
    }
    folders
        .into_iter()
        .find_map(|(id, mailbox)| (mailbox == "junk").then_some(id))
}

async fn persist_messages(
    tx: &mut Transaction<'_, Postgres>,
    auth: &AuthContext,
    messages: &mut [Message],
) -> Result<(), AppError> {
    for message in messages {
        if let Some(existing) = sqlx::query_scalar::<_, Uuid>(
            "SELECT id FROM mail_messages WHERE account_id=$1 AND provider_message_id=$2",
        )
        .bind(message.account_id)
        .bind(&message.provider_message_id)
        .fetch_optional(&mut **tx)
        .await?
        {
            message.id = existing
        }
        persist_message(tx, auth.workspace_id, auth.user_id, message).await?;
    }
    Ok(())
}
pub(crate) async fn persist_message(
    tx: &mut Transaction<'_, Postgres>,
    workspace: Uuid,
    user: Uuid,
    message: &Message,
) -> Result<(), AppError> {
    crate::mail_sync::cache_write_lock(tx, workspace, user, message.account_id).await?;
    let searchable = format!(
        "{} {} {} {} {}",
        message.from.email,
        message.from.name.as_deref().unwrap_or(""),
        message.subject,
        message.text_body,
        message
            .attachments
            .iter()
            .map(|a| a.filename.as_str())
            .collect::<Vec<_>>()
            .join(" ")
    );
    sqlx::query("INSERT INTO mail_messages(id,workspace_id,user_id,account_id,provider_message_id,provider_thread_id,sent_at,normalized,search_text,updated_at) VALUES($1,$2,$3,$4,$5,$6,$7,$8,$9,clock_timestamp()) ON CONFLICT(id) DO UPDATE SET provider_message_id=excluded.provider_message_id,provider_thread_id=excluded.provider_thread_id,sent_at=excluded.sent_at,normalized=excluded.normalized,search_text=excluded.search_text,deleted_at=NULL,updated_at=clock_timestamp() WHERE mail_messages.normalized IS DISTINCT FROM excluded.normalized OR mail_messages.deleted_at IS NOT NULL")
        .bind(message.id).bind(workspace).bind(user).bind(message.account_id).bind(&message.provider_message_id).bind(&message.provider_thread_id).bind(message.sent_at).bind(serde_json::to_value(message).map_err(|_|AppError::internal("mail_encode"))?).bind(searchable).execute(&mut **tx).await?;
    Ok(())
}

#[derive(Serialize)]
pub struct ChangePage {
    #[serde(skip_serializing_if = "Option::is_none")]
    pub sync_status: Option<AccountSyncStatus>,
    pub messages: Vec<Message>,
    pub deleted_message_ids: Vec<Uuid>,
    pub next_cursor: String,
    pub has_more: bool,
}
#[derive(Serialize, Deserialize)]
struct ChangeCursor {
    user: Uuid,
    date: DateTime<Utc>,
    id: Uuid,
    upper: Option<DateTime<Utc>>,
}
/// AEAD makes the cursor opaque and tamper-proof, binds it to the account and
/// workspace, and includes the user. Each multi-page read retains one upper
/// watermark; changes after it are returned in the next cycle.
pub async fn cached_changes(
    state: &AppState,
    auth: &AuthContext,
    account: Uuid,
    cursor: Option<&str>,
    limit: usize,
) -> Result<ChangePage, AppError> {
    let decoded = if let Some(cursor) = cursor {
        if cursor.len() > 4_096 {
            return Err(AppError::bad_request("Invalid sync cursor."));
        }
        let bytes = URL_SAFE_NO_PAD
            .decode(cursor)
            .map_err(|_| AppError::bad_request("Invalid sync cursor."))?;
        let plain = state
            .crypto
            .open(auth.workspace_id, account, &bytes)
            .map_err(|_| AppError::bad_request("Invalid sync cursor."))?;
        let cursor: ChangeCursor = serde_json::from_slice(&plain)
            .map_err(|_| AppError::bad_request("Invalid sync cursor."))?;
        if cursor.user != auth.user_id {
            return Err(AppError::bad_request("Invalid sync cursor."));
        }
        cursor
    } else {
        ChangeCursor {
            user: auth.user_id,
            date: DateTime::<Utc>::UNIX_EPOCH,
            id: Uuid::nil(),
            upper: None,
        }
    };
    let mut tx = auth.begin_authorized(&state.pool).await?;
    let query = account_status_query!("", "WHERE a.id=$1 AND a.disabled_at IS NULL");
    let status_row = sqlx::query(query)
        .bind(account)
        .fetch_optional(&mut *tx)
        .await?
        .ok_or_else(AppError::not_found)?;
    let sync_status = status_column(&status_row)?;
    crate::mail_sync::cache_write_lock(&mut tx, auth.workspace_id, auth.user_id, account).await?;
    let active:bool=sqlx::query_scalar("SELECT (expires_at IS NULL OR expires_at>clock_timestamp()) AND (absolute_expires_at IS NULL OR absolute_expires_at>clock_timestamp()) FROM sessions WHERE id=$1")
        .bind(auth.session_id).fetch_one(&mut *tx).await?;
    if !active {
        return Err(AppError::unauthorized());
    }

    let upper = if let Some(upper) = decoded.upper {
        upper
    } else {
        sqlx::query_scalar::<_, DateTime<Utc>>("SELECT clock_timestamp()")
            .fetch_one(&mut *tx)
            .await?
    };
    let limit = limit.clamp(1, 200);
    let mut rows=sqlx::query("SELECT id,normalized,deleted_at,updated_at FROM mail_messages WHERE account_id=$1 AND (updated_at,id)>($2,$3) AND updated_at<=$4 ORDER BY updated_at,id LIMIT $5").bind(account).bind(decoded.date).bind(decoded.id).bind(upper).bind(limit as i64+1).fetch_all(&mut *tx).await?;
    let has_more = rows.len() > limit;
    rows.truncate(limit);
    let mut messages = vec![];
    let mut deleted_message_ids = vec![];
    for row in &rows {
        if row
            .try_get::<Option<DateTime<Utc>>, _>("deleted_at")?
            .is_some()
        {
            deleted_message_ids.push(row.try_get("id")?)
        } else {
            messages.push(decode_message(row)?);
        }
    }
    let next = if has_more {
        let row = rows
            .last()
            .ok_or_else(|| AppError::internal("empty_change_page"))?;
        ChangeCursor {
            user: auth.user_id,
            date: row.try_get("updated_at")?,
            id: row.try_get("id")?,
            upper: Some(upper),
        }
    } else {
        ChangeCursor {
            user: auth.user_id,
            date: upper,
            id: Uuid::nil(),
            upper: None,
        }
    };
    let next_cursor = if let Some(existing) =
        cursor.filter(|_| rows.is_empty() && decoded.upper.is_none())
    {
        existing.to_owned()
    } else {
        URL_SAFE_NO_PAD.encode(state.crypto.seal(
            auth.workspace_id,
            account,
            &serde_json::to_vec(&next).map_err(|_| AppError::internal("change_cursor_encode"))?,
        )?)
    };
    tx.commit().await?;
    Ok(ChangePage {
        sync_status,
        messages,
        deleted_message_ids,
        next_cursor,
        has_more,
    })
}

#[derive(Default, Deserialize)]
pub struct ListRequest {
    pub account_id: Option<Uuid>,
    pub query: Option<String>,
    pub cursor: Option<String>,
    pub limit: Option<i64>,
}
#[derive(Serialize, Deserialize)]
struct PageCursor {
    date: DateTime<Utc>,
    id: Uuid,
}
async fn list_messages(
    State(state): State<AppState>,
    auth: AuthContext,
    Query(request): Query<ListRequest>,
) -> Result<Json<MessagePage>, AppError> {
    Ok(Json(cached_messages(&state, &auth, request).await?))
}

pub async fn cached_messages(
    state: &AppState,
    auth: &AuthContext,
    request: ListRequest,
) -> Result<MessagePage, AppError> {
    let cursor = page_cursor(request.cursor.as_deref())?;
    let limit = request.limit.unwrap_or(50).clamp(1, 200);
    let pattern = search_pattern(request.query.as_deref().unwrap_or_default())?;
    let mut tx = auth.begin_authorized(&state.pool).await?;
    let rows=sqlx::query("SELECT normalized FROM mail_messages WHERE deleted_at IS NULL AND ($1::uuid IS NULL OR account_id=$1) AND search_text ILIKE $2 AND ($3::timestamptz IS NULL OR (sent_at,id)<($3,$4)) ORDER BY sent_at DESC,id DESC LIMIT $5")
        .bind(request.account_id).bind(pattern).bind(cursor.as_ref().map(|c|c.date)).bind(cursor.as_ref().map(|c|c.id)).bind(limit+1).fetch_all(&mut *tx).await?;
    let mut messages = rows
        .iter()
        .map(decode_message)
        .collect::<Result<Vec<_>, _>>()?;
    let has_more = messages.len() > limit as usize;
    messages.truncate(limit as usize);
    let next_cursor = if has_more {
        messages
            .last()
            .map(|m| {
                serde_json::to_vec(&PageCursor {
                    date: m.sent_at,
                    id: m.id,
                })
                .map(|b| URL_SAFE_NO_PAD.encode(b))
            })
            .transpose()
            .map_err(|_| AppError::internal("page_cursor_encode"))?
    } else {
        None
    };
    tx.commit().await?;
    Ok(MessagePage {
        messages,
        next_cursor,
        has_more,
    })
}
fn page_cursor(value: Option<&str>) -> Result<Option<PageCursor>, AppError> {
    match value {
        Some(c) if c.len() <= 1024 => Ok(Some(
            serde_json::from_slice(
                &URL_SAFE_NO_PAD
                    .decode(c)
                    .map_err(|_| AppError::bad_request("Invalid page cursor."))?,
            )
            .map_err(|_| AppError::bad_request("Invalid page cursor."))?,
        )),
        Some(_) => Err(AppError::bad_request("Invalid page cursor.")),
        None => Ok(None),
    }
}
fn search_pattern(query: &str) -> Result<String, AppError> {
    if query.len() > 4096 {
        return Err(AppError::bad_request("Use a shorter search."));
    }
    Ok(format!(
        "%{}%",
        query
            .replace('\\', "\\\\")
            .replace('%', "\\%")
            .replace('_', "\\_")
    ))
}
#[derive(Serialize)]
pub struct MessageSummary {
    pub id: Uuid,
    pub account_id: Uuid,
    pub subject: String,
    pub from: provider::Address,
    pub preview: String,
    pub sent_at: DateTime<Utc>,
    pub is_read: bool,
    pub is_starred: bool,
    pub mailbox: String,
    pub attachment_count: usize,
}
#[derive(Serialize)]
pub struct MessageSummaryPage {
    pub messages: Vec<MessageSummary>,
    pub next_cursor: Option<String>,
    pub has_more: bool,
}
/// Project only bounded metadata in PostgreSQL. A summary page must never load
/// whole bodies or inline attachment blobs for every message into server memory.
pub async fn cached_message_summaries(
    state: &AppState,
    auth: &AuthContext,
    request: ListRequest,
) -> Result<MessageSummaryPage, AppError> {
    let cursor = page_cursor(request.cursor.as_deref())?;
    let limit = request.limit.unwrap_or(25).clamp(1, 50);
    let pattern = search_pattern(request.query.as_deref().unwrap_or_default())?;
    let mut tx = auth.begin_authorized(&state.pool).await?;
    let rows=sqlx::query("SELECT id,account_id,sent_at,left(normalized->>'subject',500) AS subject,left(normalized->>'preview',1000) AS preview,left(normalized#>>'{from,email}',320) AS sender_email,left(normalized#>>'{from,name}',200) AS sender_name,(normalized->>'is_read')::boolean AS is_read,(normalized->>'is_starred')::boolean AS is_starred,left(normalized->>'mailbox',100) AS mailbox,jsonb_array_length(normalized->'attachments') AS attachment_count FROM mail_messages WHERE deleted_at IS NULL AND ($1::uuid IS NULL OR account_id=$1) AND search_text ILIKE $2 AND ($3::timestamptz IS NULL OR (sent_at,id)<($3,$4)) ORDER BY sent_at DESC,id DESC LIMIT $5")
        .bind(request.account_id).bind(pattern).bind(cursor.as_ref().map(|c|c.date)).bind(cursor.as_ref().map(|c|c.id)).bind(limit+1).fetch_all(&mut *tx).await?;
    let messages = rows
        .iter()
        .take(limit as usize)
        .map(|row| {
            Ok(MessageSummary {
                id: row.try_get("id")?,
                account_id: row.try_get("account_id")?,
                sent_at: row.try_get("sent_at")?,
                subject: row.try_get("subject")?,
                preview: row.try_get("preview")?,
                from: provider::Address {
                    email: row.try_get("sender_email")?,
                    name: row.try_get("sender_name")?,
                },
                is_read: row.try_get("is_read")?,
                is_starred: row.try_get("is_starred")?,
                mailbox: row.try_get("mailbox")?,
                attachment_count: row.try_get::<i32, _>("attachment_count")? as usize,
            })
        })
        .collect::<Result<Vec<_>, AppError>>()?;
    let has_more = rows.len() > limit as usize;
    let next_cursor = if has_more {
        messages
            .last()
            .map(|m| {
                serde_json::to_vec(&PageCursor {
                    date: m.sent_at,
                    id: m.id,
                })
                .map(|b| URL_SAFE_NO_PAD.encode(b))
            })
            .transpose()
            .map_err(|_| AppError::internal("page_cursor_encode"))?
    } else {
        None
    };
    tx.commit().await?;
    Ok(MessageSummaryPage {
        messages,
        next_cursor,
        has_more,
    })
}
fn decode_message(row: &sqlx::postgres::PgRow) -> Result<Message, AppError> {
    serde_json::from_value(row.try_get("normalized")?)
        .map_err(|_| AppError::internal("mail_decode"))
}
pub async fn cached_message(
    state: &AppState,
    auth: &AuthContext,
    id: Uuid,
) -> Result<Message, AppError> {
    let mut tx = auth.begin(&state.pool).await?;
    let row =
        sqlx::query("SELECT normalized FROM mail_messages WHERE id=$1 AND deleted_at IS NULL")
            .bind(id)
            .fetch_optional(&mut *tx)
            .await?
            .ok_or_else(AppError::not_found)?;
    let message = decode_message(&row)?;
    tx.commit().await?;
    Ok(message)
}
#[derive(Deserialize)]
#[serde(rename_all = "snake_case")]
enum MessageView {
    Envelope,
}

#[derive(Deserialize)]
struct MessageQuery {
    view: Option<MessageView>,
}

async fn get_message(
    State(state): State<AppState>,
    auth: AuthContext,
    Path(id): Path<Uuid>,
    Query(query): Query<MessageQuery>,
) -> Result<axum::response::Response, AppError> {
    if let Some(MessageView::Envelope) = query.view {
        let mut tx = auth.begin(&state.pool).await?;
        let envelope = sqlx::query_scalar::<_, Value>(
            "SELECT jsonb_build_object(
                'id', id, 'account_id', account_id,
                'to', normalized->'to', 'cc', normalized->'cc', 'bcc', normalized->'bcc',
                'dkim_signatures', normalized->'dkim_signatures',
                'delivery_headers', normalized->'delivery_headers')
             FROM mail_messages WHERE id=$1 AND deleted_at IS NULL",
        )
        .bind(id)
        .fetch_optional(&mut *tx)
        .await?
        .ok_or_else(AppError::not_found)?;
        tx.commit().await?;
        return Ok(Json(envelope).into_response());
    }
    Ok(Json(cached_message(&state, &auth, id).await?).into_response())
}
async fn mutate_message(
    State(state): State<AppState>,
    auth: AuthContext,
    Path(id): Path<Uuid>,
    Json(mutation): Json<Mutation>,
) -> Result<Json<Value>, AppError> {
    apply_message_mutation(&state, &auth, id, None, mutation).await?;
    Ok(Json(json!({})))
}

/// Apply a message operation with current authorization held across provider I/O.
/// An approval may bind the exact provider target to prevent a moved/replaced
/// cached message from changing what the user reviewed.
pub async fn apply_message_mutation(
    state: &AppState,
    auth: &AuthContext,
    id: Uuid,
    expected_provider_id: Option<&str>,
    mutation: Mutation,
) -> Result<Message, AppError> {
    apply_message_mutation_with(
        state,
        auth,
        id,
        expected_provider_id,
        mutation,
        &HttpMessageMutation,
    )
    .await
}

pub type MessageMutationFuture<'a> =
    std::pin::Pin<Box<dyn std::future::Future<Output = Result<Message, AppError>> + Send + 'a>>;
/// Fixtures replace only provider I/O; authorization, target binding, locks,
/// and cache persistence follow the production operation.
pub trait MessageMutationTransport: Send + Sync {
    fn apply<'a>(
        &'a self,
        state: &'a AppState,
        session: &'a AccountSession,
        old: &'a Message,
        mutation: &'a Mutation,
    ) -> MessageMutationFuture<'a>;
}
pub struct HttpMessageMutation;
impl MessageMutationTransport for HttpMessageMutation {
    fn apply<'a>(
        &'a self,
        state: &'a AppState,
        session: &'a AccountSession,
        old: &'a Message,
        mutation: &'a Mutation,
    ) -> MessageMutationFuture<'a> {
        Box::pin(async move {
            let provider = Provider::parse(&session.account.provider)?;
            let new_id = provider::mutate(
                state,
                provider,
                &session.credentials.access_token,
                &old.provider_message_id,
                mutation,
            )
            .await?;
            let mut updated = provider::fetch_message(
                state,
                provider,
                old.account_id,
                &session.credentials.access_token,
                new_id.as_deref().unwrap_or(&old.provider_message_id),
            )
            .await?;
            classify_mailboxes(state, session, std::slice::from_mut(&mut updated), None).await?;
            Ok(updated)
        })
    }
}
pub async fn apply_message_mutation_with(
    state: &AppState,
    auth: &AuthContext,
    id: Uuid,
    expected_provider_id: Option<&str>,
    mutation: Mutation,
    transport: &(impl MessageMutationTransport + ?Sized),
) -> Result<Message, AppError> {
    let mut tx = auth.begin_authorized(&state.pool).await?;
    let old = cached_message(state, auth, id).await?;
    if expected_provider_id.is_some_and(|expected| expected != old.provider_message_id) {
        return Err(AppError::conflict(
            "This message changed. Review a new approval request.",
        ));
    }
    if mutation.is_read.is_none() && mutation.is_starred.is_none() && mutation.mailbox.is_none() {
        return Ok(old);
    }
    let session = account_session(state, auth, old.account_id).await?;
    crate::mail_sync::account_operation_lock(
        &mut tx,
        auth.workspace_id,
        auth.user_id,
        old.account_id,
    )
    .await?;
    let available:Option<Uuid> = sqlx::query_scalar("SELECT id FROM provider_accounts WHERE id=$1 AND disabled_at IS NULL AND status='connected' FOR SHARE")
        .bind(old.account_id).fetch_optional(&mut *tx).await?;
    available.ok_or_else(AppError::not_found)?;
    let current: Option<String> = sqlx::query_scalar(
        "SELECT provider_message_id FROM mail_messages WHERE id=$1 AND deleted_at IS NULL",
    )
    .bind(id)
    .fetch_optional(&mut *tx)
    .await?;
    if current.as_deref() != Some(old.provider_message_id.as_str()) {
        return Err(AppError::conflict(
            "This message changed. Try again with its current state.",
        ));
    }
    let active:bool=sqlx::query_scalar("SELECT (expires_at IS NULL OR expires_at>clock_timestamp()) AND (absolute_expires_at IS NULL OR absolute_expires_at>clock_timestamp()) FROM sessions WHERE id=$1")
        .bind(auth.session_id).fetch_one(&mut *tx).await?;
    if !active {
        return Err(AppError::unauthorized());
    }
    let mut updated = transport.apply(state, &session, &old, &mutation).await?;
    if updated.account_id != old.account_id {
        return Err(AppError::internal("provider_account_mismatch"));
    }
    updated.id = old.id;
    crate::mail_sync::cache_write_lock(&mut tx, auth.workspace_id, auth.user_id, old.account_id)
        .await?;
    persist_message(&mut tx, auth.workspace_id, auth.user_id, &updated).await?;
    tx.commit().await?;
    Ok(updated)
}
async fn calendar_invitation(
    State(state): State<AppState>,
    auth: AuthContext,
    Path(id): Path<Uuid>,
) -> Result<impl IntoResponse, AppError> {
    // Old caches may predate invitation normalization. Only the message owner
    // can request recovery, and the database supplies the provider message ID.
    let mut tx = auth.begin_authorized(&state.pool).await?;
    let (account_id, provider_id): (Uuid, String) = sqlx::query_as(
        "SELECT account_id, provider_message_id FROM mail_messages WHERE id=$1 AND deleted_at IS NULL",
    )
    .bind(id)
    .fetch_optional(&mut *tx)
    .await?
    .ok_or_else(AppError::not_found)?;
    tx.commit().await?;
    let session = account_session(&state, &auth, account_id).await?;
    let bytes = provider::fetch_calendar_invitation(
        &state,
        Provider::parse(&session.account.provider)?,
        &session.credentials.access_token,
        &provider_id,
    )
    .await?;
    Ok((
        [
            (header::CONTENT_TYPE, "text/calendar; charset=utf-8"),
            (header::CACHE_CONTROL, "private, no-store"),
        ],
        bytes,
    ))
}

async fn attachment(
    State(state): State<AppState>,
    auth: AuthContext,
    Path((id, attachment_id)): Path<(Uuid, Uuid)>,
) -> Result<impl IntoResponse, AppError> {
    let message = cached_message(&state, &auth, id).await?;
    let item = message
        .attachments
        .iter()
        .find(|a| a.id == attachment_id)
        .ok_or_else(AppError::not_found)?;
    let bytes = if let Some(inline) = &item.inline_data_base64 {
        URL_SAFE_NO_PAD
            .decode(inline.trim_end_matches('='))
            .map_err(|_| AppError::internal("attachment_decode"))?
    } else {
        let session = account_session(&state, &auth, message.account_id).await?;
        let provider = Provider::parse(&session.account.provider)?;
        if provider == Provider::Microsoft
            && provider::is_graph_mime_invitation(
                message.account_id,
                &message.provider_message_id,
                item,
            )
        {
            provider::fetch_calendar_invitation(
                &state,
                provider,
                &session.credentials.access_token,
                &message.provider_message_id,
            )
            .await?
        } else {
            provider::fetch_attachment(
                &state,
                provider,
                &session.credentials.access_token,
                &message.provider_message_id,
                item.provider_attachment_id
                    .as_deref()
                    .ok_or_else(AppError::not_found)?,
            )
            .await?
        }
    };
    if bytes.len() > 25 * 1024 * 1024 {
        return Err(AppError::bad_request(
            "This attachment exceeds the download limit.",
        ));
    }
    let mut headers = HeaderMap::new();
    headers.insert(
        header::CONTENT_TYPE,
        HeaderValue::from_str(if provider::valid_mime_type(&item.mime_type) {
            &item.mime_type
        } else {
            "application/octet-stream"
        })
        .map_err(|_| AppError::internal("attachment_content_type"))?,
    );
    headers.insert(
        header::CONTENT_DISPOSITION,
        HeaderValue::from_static("attachment"),
    );
    Ok((headers, bytes))
}

#[derive(Serialize)]
pub struct OutboxItem {
    pub id: Uuid,
    pub client_id: Uuid,
    pub account_id: Uuid,
    pub status: String,
    pub scheduled_at: DateTime<Utc>,
    pub undo_until: DateTime<Utc>,
    pub provider_message_id: Option<String>,
    pub error_code: Option<String>,
    pub created_at: DateTime<Utc>,
}
pub fn outbox_row(row: &sqlx::postgres::PgRow) -> Result<OutboxItem, AppError> {
    Ok(OutboxItem {
        id: row.try_get("id")?,
        client_id: row.try_get("client_id")?,
        account_id: row.try_get("account_id")?,
        status: row.try_get("status")?,
        scheduled_at: row.try_get("scheduled_at")?,
        undo_until: row.try_get("undo_until")?,
        provider_message_id: row.try_get("provider_message_id")?,
        error_code: row.try_get("error_code")?,
        created_at: row.try_get("created_at")?,
    })
}

pub fn validate_outgoing(message: &Outgoing) -> Result<(), AppError> {
    let recipients = message.to.len() + message.cc.len() + message.bcc.len();
    if recipients == 0 || recipients > 100 {
        return Err(AppError::bad_request("Use between 1 and 100 recipients."));
    }
    if message
        .to
        .iter()
        .chain(&message.cc)
        .chain(&message.bcc)
        .any(|a| !provider::valid_email(&a.email) || a.name.as_ref().is_some_and(|n| n.len() > 200))
    {
        return Err(AppError::bad_request("Check the recipient addresses."));
    }
    if message.subject.len() > 500
        || message.text_body.len() > 2 * 1024 * 1024
        || message
            .html_body
            .as_ref()
            .is_some_and(|b| b.len() > 2 * 1024 * 1024)
    {
        return Err(AppError::bad_request("This message is too large."));
    }
    if message.attachments.len() > 50 {
        return Err(AppError::bad_request("Use no more than 50 attachments."));
    }
    let mut total = 0;
    for attachment in &message.attachments {
        if attachment.filename.is_empty()
            || attachment.filename.len() > 255
            || attachment.filename.chars().any(char::is_control)
            || !provider::valid_mime_type(&attachment.mime_type)
        {
            return Err(AppError::bad_request("Check the attachment name and type."));
        }
        total += STANDARD
            .decode(&attachment.data_base64)
            .map_err(|_| AppError::bad_request("An attachment is not valid base64."))?
            .len();
        if total > 20 * 1024 * 1024 {
            return Err(AppError::bad_request(
                "Attachments exceed the 20 MB send limit.",
            ));
        }
    }
    if message
        .scheduled_at
        .is_some_and(|d| d > Utc::now() + Duration::days(366))
    {
        return Err(AppError::bad_request(
            "Schedule messages no more than one year ahead.",
        ));
    }
    if message
        .in_reply_to
        .as_ref()
        .is_some_and(|s| !provider::valid_message_id(s))
        || message.references.len() > 100
        || message
            .references
            .iter()
            .any(|s| !provider::valid_message_id(s))
    {
        return Err(AppError::bad_request("The reply headers are invalid."));
    }
    if message
        .provider_thread_id
        .as_ref()
        .is_some_and(|s| s.is_empty() || s.len() > 4_096 || s.chars().any(char::is_control))
    {
        return Err(AppError::bad_request("The provider thread is invalid."));
    }
    Ok(())
}
async fn queue_message(
    State(state): State<AppState>,
    auth: AuthContext,
    Json(message): Json<Outgoing>,
) -> Result<Json<OutboxItem>, AppError> {
    let mut tx = auth.begin(&state.pool).await?;
    let item = queue_in_transaction(&state, &auth, &mut tx, &message).await?;
    tx.commit().await?;
    Ok(Json(item))
}

/// Caller must hold current authorization in the supplied RLS transaction.
/// Persist only: provider delivery is handled by the durable background worker.
pub async fn queue_in_transaction(
    state: &AppState,
    auth: &AuthContext,
    tx: &mut Transaction<'_, Postgres>,
    message: &Outgoing,
) -> Result<OutboxItem, AppError> {
    validate_outgoing(&message)?;
    let encoded = Zeroizing::new(
        serde_json::to_vec(&message).map_err(|_| AppError::internal("outbox_encode"))?,
    );
    let hash = Sha256::digest(&*encoded).to_vec();
    // A transaction-scoped advisory lock makes simultaneous retries of the same
    // client UUID observe one job. A reused key with a different body is rejected.
    sqlx::query("SELECT pg_advisory_xact_lock(hashtextextended($1,0))")
        .bind(format!(
            "{}:{}:{}",
            auth.workspace_id, auth.user_id, message.client_id
        ))
        .execute(&mut **tx)
        .await?;
    if let Some(row) = sqlx::query("SELECT * FROM mail_outbox WHERE client_id=$1")
        .bind(message.client_id)
        .fetch_optional(&mut **tx)
        .await?
    {
        let old: Vec<u8> = row.try_get("payload_hash")?;
        if old != hash {
            return Err(AppError::conflict(
                "This send identifier was already used for different content.",
            ));
        }
        let item = outbox_row(&row)?;
        return Ok(item);
    }
    let available:bool=sqlx::query_scalar("SELECT EXISTS(SELECT 1 FROM provider_accounts WHERE id=$1 AND disabled_at IS NULL AND status='connected')").bind(message.account_id).fetch_one(&mut **tx).await?;
    if !available {
        return Err(AppError::not_found());
    }
    if let Some(thread) = &message.provider_thread_id {
        let owned:bool=sqlx::query_scalar("SELECT EXISTS(SELECT 1 FROM mail_messages WHERE account_id=$1 AND provider_thread_id=$2)").bind(message.account_id).bind(thread).fetch_one(&mut **tx).await?;
        if !owned {
            return Err(AppError::not_found());
        }
    }
    let count: i64 = sqlx::query_scalar(
        "SELECT count(*) FROM mail_outbox WHERE status IN ('pending','delivering')",
    )
    .fetch_one(&mut **tx)
    .await?;
    if count >= 1_000 {
        return Err(AppError::rate_limited());
    }
    let id = Uuid::new_v4();
    let undo_until =
        Utc::now() + Duration::seconds(message.undo_seconds.unwrap_or(10).clamp(5, 60));
    let scheduled_at = message.scheduled_at.unwrap_or(undo_until).max(undo_until);
    let encrypted = state.crypto.seal(auth.workspace_id, id, &encoded)?;
    let row=sqlx::query("INSERT INTO mail_outbox(id,client_id,workspace_id,user_id,account_id,encrypted_payload,payload_hash,scheduled_at,undo_until) VALUES($1,$2,$3,$4,$5,$6,$7,$8,$9) RETURNING *").bind(id).bind(message.client_id).bind(auth.workspace_id).bind(auth.user_id).bind(message.account_id).bind(encrypted).bind(hash).bind(scheduled_at).bind(undo_until).fetch_one(&mut **tx).await?;
    sqlx::query(
        "INSERT INTO mail_delivery_wakeups(job_id,workspace_id,user_id,due_at) VALUES($1,$2,$3,$4)",
    )
    .bind(id)
    .bind(auth.workspace_id)
    .bind(auth.user_id)
    .bind(scheduled_at)
    .execute(&mut **tx)
    .await?;
    let item = outbox_row(&row)?;
    Ok(item)
}
async fn outbox(State(state): State<AppState>, auth: AuthContext) -> Result<Json<Value>, AppError> {
    let mut tx = auth.begin(&state.pool).await?;
    let rows = sqlx::query("SELECT * FROM mail_outbox ORDER BY created_at DESC LIMIT 200")
        .fetch_all(&mut *tx)
        .await?;
    let items = rows.iter().map(outbox_row).collect::<Result<Vec<_>, _>>()?;
    tx.commit().await?;
    Ok(Json(json!({"items":items})))
}
async fn cancel(
    State(state): State<AppState>,
    auth: AuthContext,
    Path(id): Path<Uuid>,
) -> Result<Json<OutboxItem>, AppError> {
    let mut tx = auth.begin(&state.pool).await?;
    let item = cancel_in_transaction(&mut tx, id).await?;
    tx.commit().await?;
    Ok(Json(item))
}

/// Caller must hold current authorization in the supplied RLS transaction.
pub async fn cancel_in_transaction(
    tx: &mut Transaction<'_, Postgres>,
    id: Uuid,
) -> Result<OutboxItem, AppError> {
    let row = sqlx::query("SELECT * FROM mail_outbox WHERE id=$1 FOR UPDATE")
        .bind(id)
        .fetch_optional(&mut **tx)
        .await?
        .ok_or_else(AppError::not_found)?;
    let status: String = row.try_get("status")?;
    if status == "cancelled" {
        let item = outbox_row(&row)?;
        return Ok(item);
    }
    if status != "pending" && status != "failed" {
        return Err(AppError::conflict(
            "Delivery has already started. Check Sent before composing another copy.",
        ));
    }
    let row = sqlx::query(
        "UPDATE mail_outbox SET status='cancelled',updated_at=now() WHERE id=$1 RETURNING *",
    )
    .bind(id)
    .fetch_one(&mut **tx)
    .await?;
    sqlx::query("DELETE FROM mail_delivery_wakeups WHERE job_id=$1")
        .bind(id)
        .execute(&mut **tx)
        .await?;
    let item = outbox_row(&row)?;
    Ok(item)
}
async fn retry(
    State(state): State<AppState>,
    auth: AuthContext,
    Path(id): Path<Uuid>,
) -> Result<Json<OutboxItem>, AppError> {
    let mut tx = auth.begin(&state.pool).await?;
    let row=sqlx::query("UPDATE mail_outbox SET status='pending',error_code=NULL,claimed_at=NULL,scheduled_at=now()+interval '10 seconds',undo_until=now()+interval '10 seconds',updated_at=now() WHERE id=$1 AND status='failed' RETURNING *").bind(id).fetch_optional(&mut *tx).await?.ok_or_else(||AppError::conflict("Only a message with a confirmed delivery failure can be retried."))?;
    let item = outbox_row(&row)?;
    sqlx::query("INSERT INTO mail_delivery_wakeups(job_id,workspace_id,user_id,due_at) VALUES($1,$2,$3,$4) ON CONFLICT(job_id) DO UPDATE SET due_at=excluded.due_at,lease_until=NULL").bind(id).bind(auth.workspace_id).bind(auth.user_id).bind(item.scheduled_at).execute(&mut *tx).await?;
    tx.commit().await?;
    Ok(Json(item))
}

pub fn spawn_delivery_worker(state: AppState) -> tokio::task::JoinHandle<()> {
    tokio::spawn(async move {
        let mut interval = tokio::time::interval(std::time::Duration::from_secs(2));
        loop {
            interval.tick().await;
            if let Err(_) = process_one_delivery(&state).await {
                tracing::warn!(event = "mail_delivery_worker", "delivery processing failed");
            }
        }
    })
}

/// Tests inject a transport here so worker transactions and races are exercised
/// without contacting providers or sending mail. Production uses HttpDelivery.
pub trait DeliveryTransport: Send + Sync {
    fn send<'a>(
        &'a self,
        state: &'a AppState,
        provider: Provider,
        token: &'a str,
        from: &'a str,
        message: &'a Outgoing,
    ) -> std::pin::Pin<
        Box<dyn std::future::Future<Output = Result<Option<String>, ProviderError>> + Send + 'a>,
    >;
}
pub struct HttpDelivery;
impl DeliveryTransport for HttpDelivery {
    fn send<'a>(
        &'a self,
        state: &'a AppState,
        provider: Provider,
        token: &'a str,
        from: &'a str,
        message: &'a Outgoing,
    ) -> std::pin::Pin<
        Box<dyn std::future::Future<Output = Result<Option<String>, ProviderError>> + Send + 'a>,
    > {
        Box::pin(provider::send(state, provider, token, from, message))
    }
}

/// Claims a single job with a lease, checks its active account/membership under
/// RLS, then marks delivery started before contacting the provider. A crash or
/// network ambiguity becomes `uncertain`, never an automatic second send.
pub async fn process_one_delivery(state: &AppState) -> Result<bool, AppError> {
    process_one_delivery_with(state, &HttpDelivery).await
}
pub async fn process_one_delivery_with(
    state: &AppState,
    transport: &impl DeliveryTransport,
) -> Result<bool, AppError> {
    let row=sqlx::query("UPDATE mail_delivery_wakeups SET lease_until=now()+interval '5 minutes' WHERE job_id=(SELECT job_id FROM mail_delivery_wakeups WHERE due_at<=now() AND (lease_until IS NULL OR lease_until<now()) ORDER BY due_at FOR UPDATE SKIP LOCKED LIMIT 1) RETURNING job_id,workspace_id,user_id").fetch_optional(&state.pool).await?;
    let Some(row) = row else { return Ok(false) };
    let id: Uuid = row.try_get("job_id")?;
    let workspace: Uuid = row.try_get("workspace_id")?;
    let user: Uuid = row.try_get("user_id")?;
    let mut tx = db::scoped_transaction(&state.pool, workspace, user).await?;
    let row = sqlx::query("SELECT * FROM mail_outbox WHERE id=$1 FOR UPDATE")
        .bind(id)
        .fetch_optional(&mut *tx)
        .await?;
    let Some(row) = row else {
        tx.commit().await?;
        sqlx::query("DELETE FROM mail_delivery_wakeups WHERE job_id=$1")
            .bind(id)
            .execute(&state.pool)
            .await?;
        return Ok(true);
    };
    let status: String = row.try_get("status")?;
    if status == "delivering" {
        sqlx::query("UPDATE mail_outbox SET status='uncertain',error_code='interrupted_delivery',updated_at=now() WHERE id=$1").bind(id).execute(&mut *tx).await?;
    }
    if status != "pending" {
        sqlx::query("DELETE FROM mail_delivery_wakeups WHERE job_id=$1")
            .bind(id)
            .execute(&mut *tx)
            .await?;
        tx.commit().await?;
        return Ok(true);
    }
    if !active_membership(&mut tx, workspace, user).await? {
        sqlx::query("UPDATE mail_outbox SET status='failed',error_code='account_access_revoked',updated_at=now() WHERE id=$1").bind(id).execute(&mut *tx).await?;
        sqlx::query("DELETE FROM mail_delivery_wakeups WHERE job_id=$1")
            .bind(id)
            .execute(&mut *tx)
            .await?;
        tx.commit().await?;
        return Ok(true);
    }
    let account_id: Uuid = row.try_get("account_id")?;
    let encrypted: Vec<u8> = row.try_get("encrypted_payload")?;
    // Keep the job pending during preflight refresh so a user can still cancel.
    tx.commit().await?;
    let session = match scoped_account_session(state, workspace, user, account_id).await {
        Ok(s) => s,
        Err(_) => {
            finish_delivery(
                state,
                workspace,
                user,
                id,
                "failed",
                None,
                Some("account_unavailable"),
            )
            .await?;
            return Ok(true);
        }
    };
    let encoded = state.crypto.open(workspace, id, &encrypted)?;
    let mut message: Outgoing =
        serde_json::from_slice(&encoded).map_err(|_| AppError::internal("outbox_decode"))?;
    let mut tx = db::scoped_transaction(&state.pool, workspace, user).await?;
    if !active_membership(&mut tx, workspace, user).await? {
        tx.rollback().await?;
        finish_delivery(
            state,
            workspace,
            user,
            id,
            "failed",
            None,
            Some("account_access_revoked"),
        )
        .await?;
        return Ok(true);
    }
    let claimed=sqlx::query("UPDATE mail_outbox SET status='delivering',claimed_at=now(),updated_at=now() WHERE id=$1 AND status='pending' AND scheduled_at<=now() AND EXISTS(SELECT 1 FROM provider_accounts a WHERE a.id=mail_outbox.account_id AND a.disabled_at IS NULL)").bind(id).execute(&mut *tx).await?.rows_affected()==1;
    if !claimed {
        sqlx::query("UPDATE mail_outbox SET status='failed',error_code='account_unavailable',updated_at=now() WHERE id=$1 AND status='pending' AND NOT EXISTS(SELECT 1 FROM provider_accounts a WHERE a.id=mail_outbox.account_id AND a.disabled_at IS NULL)").bind(id).execute(&mut *tx).await?;
        sqlx::query("UPDATE mail_delivery_wakeups SET due_at=o.scheduled_at,lease_until=NULL FROM mail_outbox o WHERE job_id=$1 AND o.id=job_id AND o.status='pending'").bind(id).execute(&mut *tx).await?;
        sqlx::query("DELETE FROM mail_delivery_wakeups WHERE job_id=$1 AND NOT EXISTS(SELECT 1 FROM mail_outbox o WHERE o.id=job_id AND o.status='pending')").bind(id).execute(&mut *tx).await?;
        tx.commit().await?;
        return Ok(true);
    }
    tracking::prepare_tracking(state, &mut tx, workspace, user, id, &mut message).await?;
    tx.commit().await?;
    match transport
        .send(
            state,
            Provider::parse(&session.account.provider)?,
            &session.credentials.access_token,
            &session.account.email,
            &message,
        )
        .await
    {
        Ok(receipt) => {
            finish_delivery(state, workspace, user, id, "sent", receipt.as_deref(), None).await?
        }
        Err(ProviderError::Rejected | ProviderError::Unauthorized) => {
            finish_delivery(
                state,
                workspace,
                user,
                id,
                "failed",
                None,
                Some("provider_rejected"),
            )
            .await?
        }
        Err(_) => {
            finish_delivery(
                state,
                workspace,
                user,
                id,
                "uncertain",
                None,
                Some("delivery_unconfirmed"),
            )
            .await?
        }
    }
    Ok(true)
}
async fn finish_delivery(
    state: &AppState,
    workspace: Uuid,
    user: Uuid,
    id: Uuid,
    status: &str,
    receipt: Option<&str>,
    error: Option<&str>,
) -> Result<(), AppError> {
    let mut tx = db::scoped_transaction(&state.pool, workspace, user).await?;
    // Preflight failure must not overwrite a concurrent user cancellation.
    sqlx::query("UPDATE mail_outbox SET status=$2,provider_message_id=$3,error_code=$4,updated_at=now() WHERE id=$1 AND status IN ('pending','delivering')").bind(id).bind(status).bind(receipt).bind(error).execute(&mut *tx).await?;
    sqlx::query("DELETE FROM mail_delivery_wakeups WHERE job_id=$1")
        .bind(id)
        .execute(&mut *tx)
        .await?;
    tx.commit().await?;
    Ok(())
}

#[cfg(test)]
mod folder_tests {
    use super::*;

    #[test]
    fn graph_junk_uses_the_owning_folder_id_preserving_other_mailboxes() {
        let account = Uuid::new_v4();
        let mut messages = ["AGkJunk", "AGkInbox", "AGkTrash", "agkjunk", "AGkOther"].map(|id| {
            provider::normalize_graph(
                account,
                &serde_json::json!({
                    "id": id, "parentFolderId": id, "receivedDateTime": "2026-11-19T12:00:00Z",
                    "categories": ["Junk"]
                }),
            )
            .unwrap()
        });
        let junk_id = apply_graph_folders(
            &mut messages,
            vec![
                ("AGkJunk".into(), "junk".into()),
                ("AGkInbox".into(), "inbox".into()),
                ("AGkTrash".into(), "trash".into()),
            ],
        );
        assert_eq!(junk_id.as_deref(), Some("AGkJunk"));
        assert_eq!(
            messages.map(|msg| msg.mailbox),
            ["junk", "inbox", "trash", "archive", "archive"]
        );
    }
}
