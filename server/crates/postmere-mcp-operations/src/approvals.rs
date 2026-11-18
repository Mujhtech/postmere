use base64::{Engine, engine::general_purpose::STANDARD};
use chrono::{DateTime, Utc};
use postmere_core::{AppState, auth::AuthContext, error::AppError};
use postmere_mail::mail;
use postmere_providers::{Address, Message, Mutation, Outgoing};
use serde::{Deserialize, Serialize};
use serde_json::{Value, json};
use sha2::{Digest, Sha256};
use sqlx::{Postgres, Row, Transaction, postgres::PgRow};
use uuid::Uuid;
use zeroize::Zeroizing;

#[derive(Deserialize, Serialize)]
#[serde(tag = "kind", rename_all = "snake_case")]
pub enum ApprovalInput {
    SendDraft {
        request_id: Uuid,
        draft_id: Uuid,
        expected_version: i64,
    },
    TrashMessage {
        request_id: Uuid,
        message_id: Uuid,
    },
    DisconnectAccount {
        request_id: Uuid,
        account_id: Uuid,
    },
}
impl ApprovalInput {
    fn request_id(&self) -> Uuid {
        match self {
            Self::SendDraft { request_id, .. }
            | Self::TrashMessage { request_id, .. }
            | Self::DisconnectAccount { request_id, .. } => *request_id,
        }
    }
    fn kind(&self) -> &'static str {
        match self {
            Self::SendDraft { .. } => "send_draft",
            Self::TrashMessage { .. } => "trash_message",
            Self::DisconnectAccount { .. } => "disconnect_account",
        }
    }
}
#[derive(Serialize, Deserialize)]
pub struct ReviewAttachment {
    pub filename: String,
    pub mime_type: String,
    pub size_bytes: usize,
}
#[derive(Serialize, Deserialize)]
#[serde(tag = "kind", rename_all = "snake_case")]
pub enum ApprovalReview {
    SendDraft {
        draft_id: Uuid,
        draft_version: i64,
        account_id: Uuid,
        account_email: String,
        to: Vec<Address>,
        cc: Vec<Address>,
        bcc: Vec<Address>,
        subject: String,
        text_body: String,
        html_body: Option<String>,
        attachments: Vec<ReviewAttachment>,
        scheduled_at: Option<DateTime<Utc>>,
        undo_seconds: Option<i64>,
        track_opens: bool,
        track_links: bool,
        in_reply_to: Option<String>,
        references: Vec<String>,
        provider_thread_id: Option<String>,
    },
    TrashMessage {
        message_id: Uuid,
        account_id: Uuid,
        account_email: String,
        subject: String,
        from: Address,
        preview: String,
    },
    DisconnectAccount {
        account_id: Uuid,
        email: String,
        provider: String,
        display_name: Option<String>,
    },
}
#[derive(Serialize)]
pub struct Approval {
    pub id: Uuid,
    pub kind: String,
    pub status: String,
    pub created_at: DateTime<Utc>,
    pub expires_at: DateTime<Utc>,
    pub review: ApprovalReview,
    pub result: Option<Value>,
    pub error_code: Option<String>,
}
#[derive(Serialize, Deserialize)]
enum Action {
    Send {
        message: Outgoing,
        account_email: String,
    },
    Trash {
        message_id: Uuid,
        account_id: Uuid,
        provider_message_id: String,
        account_email: String,
    },
    Disconnect {
        account_id: Uuid,
        email: String,
    },
}
#[derive(Serialize, Deserialize)]
struct StoredApproval {
    review: ApprovalReview,
    action: Action,
}

fn stored(state: &AppState, auth: &AuthContext, row: &PgRow) -> Result<StoredApproval, AppError> {
    let id: Uuid = row.try_get("id")?;
    let encrypted: Vec<u8> = row.try_get("encrypted_payload")?;
    let bytes = state.crypto.open(auth.workspace_id, id, &encrypted)?;
    serde_json::from_slice(&bytes).map_err(|_| AppError::internal("mcp_approval_decode"))
}
fn approval(state: &AppState, auth: &AuthContext, row: &PgRow) -> Result<Approval, AppError> {
    let mut status: String = row.try_get("status")?;
    let expires_at: DateTime<Utc> = row.try_get("expires_at")?;
    let updated_at: DateTime<Utc> = row.try_get("updated_at")?;
    let mut error_code: Option<String> = row.try_get("error_code")?;
    // GET and MCP reads remain side-effect free. Expiry and interrupted work
    // are displayed without updating the persisted approval.
    if status == "pending" && expires_at <= Utc::now() {
        status = "expired".into();
    } else if status == "executing" && updated_at < Utc::now() - chrono::Duration::minutes(10) {
        status = "uncertain".into();
        error_code = Some("execution_interrupted".into());
    }
    Ok(Approval {
        id: row.try_get("id")?,
        kind: row.try_get("kind")?,
        status,
        created_at: row.try_get("created_at")?,
        expires_at,
        review: stored(state, auth, row)?.review,
        result: row.try_get("result")?,
        error_code,
    })
}
async fn active_account(tx: &mut Transaction<'_, Postgres>, id: Uuid) -> Result<PgRow, AppError> {
    sqlx::query("SELECT id,email,provider,display_name FROM provider_accounts WHERE id=$1 AND disabled_at IS NULL AND status='connected' FOR SHARE")
        .bind(id).fetch_optional(&mut **tx).await?.ok_or_else(AppError::not_found)
}
async fn refresh_status(tx: &mut Transaction<'_, Postgres>) -> Result<(), AppError> {
    sqlx::query("UPDATE mcp_mail_approvals SET status='expired',updated_at=clock_timestamp() WHERE status='pending' AND expires_at<=clock_timestamp()")
        .execute(&mut **tx).await?;
    // A process crash cannot cause a provider mutation to be silently repeated.
    sqlx::query("UPDATE mcp_mail_approvals SET status='uncertain',error_code='execution_interrupted',updated_at=clock_timestamp() WHERE status='executing' AND updated_at<clock_timestamp()-interval '10 minutes'")
        .execute(&mut **tx).await?;
    Ok(())
}

pub async fn request_approval(
    state: &AppState,
    auth: &AuthContext,
    input: ApprovalInput,
) -> Result<Approval, AppError> {
    let request_hash = Sha256::digest(
        serde_json::to_vec(&input).map_err(|_| AppError::internal("mcp_approval_encode"))?,
    )
    .to_vec();
    let mut tx = auth.begin_authorized(&state.pool).await?;
    super::operation_lock(&mut tx, auth, "approvals").await?;
    refresh_status(&mut tx).await?;
    if let Some(row) = sqlx::query("SELECT * FROM mcp_mail_approvals WHERE request_id=$1")
        .bind(input.request_id())
        .fetch_optional(&mut *tx)
        .await?
    {
        if row.try_get::<Vec<u8>, _>("request_hash")? != request_hash {
            return Err(AppError::conflict(
                "This approval identifier was used for a different action.",
            ));
        }
        let result = approval(state, auth, &row)?;
        super::check_session(&mut tx, auth).await?;
        tx.commit().await?;
        return Ok(result);
    }
    let count: i64 = sqlx::query_scalar(
        "SELECT count(*) FROM mcp_mail_approvals WHERE status IN ('pending','executing')",
    )
    .fetch_one(&mut *tx)
    .await?;
    if count >= 100 {
        return Err(AppError::rate_limited());
    }
    let id = Uuid::new_v4();
    let payload = match &input {
        ApprovalInput::SendDraft {
            draft_id,
            expected_version,
            ..
        } => {
            let row = sqlx::query("SELECT * FROM mcp_mail_drafts WHERE id=$1 FOR SHARE")
                .bind(draft_id)
                .fetch_optional(&mut *tx)
                .await?
                .ok_or_else(AppError::not_found)?;
            let draft = crate::drafts::decode_draft(state, auth, &row)?;
            if draft.version != *expected_version {
                return Err(AppError::conflict(
                    "This draft changed. Read it before requesting approval.",
                ));
            }
            let message = draft.content.outgoing(id)?;
            mail::validate_outgoing(&message)?;
            let account = active_account(&mut tx, message.account_id).await?;
            let email: String = account.try_get("email")?;
            let attachments = message
                .attachments
                .iter()
                .map(|a| {
                    Ok(ReviewAttachment {
                        filename: a.filename.clone(),
                        mime_type: a.mime_type.clone(),
                        size_bytes: STANDARD
                            .decode(&a.data_base64)
                            .map_err(|_| AppError::internal("mcp_attachment_decode"))?
                            .len(),
                    })
                })
                .collect::<Result<Vec<_>, AppError>>()?;
            let review = ApprovalReview::SendDraft {
                draft_id: *draft_id,
                draft_version: draft.version,
                account_id: message.account_id,
                account_email: email.clone(),
                to: message.to.clone(),
                cc: message.cc.clone(),
                bcc: message.bcc.clone(),
                subject: message.subject.clone(),
                text_body: message.text_body.clone(),
                html_body: message.html_body.clone(),
                attachments,
                scheduled_at: message.scheduled_at,
                undo_seconds: message.undo_seconds,
                track_opens: message.track_opens,
                track_links: message.track_links,
                in_reply_to: message.in_reply_to.clone(),
                references: message.references.clone(),
                provider_thread_id: message.provider_thread_id.clone(),
            };
            StoredApproval {
                review,
                action: Action::Send {
                    message,
                    account_email: email,
                },
            }
        }
        ApprovalInput::TrashMessage { message_id, .. } => {
            let value: Value = sqlx::query_scalar(
                "SELECT normalized FROM mail_messages WHERE id=$1 AND deleted_at IS NULL FOR SHARE",
            )
            .bind(message_id)
            .fetch_optional(&mut *tx)
            .await?
            .ok_or_else(AppError::not_found)?;
            let m: Message =
                serde_json::from_value(value).map_err(|_| AppError::internal("mail_decode"))?;
            let account = active_account(&mut tx, m.account_id).await?;
            let email: String = account.try_get("email")?;
            let review = ApprovalReview::TrashMessage {
                message_id: *message_id,
                account_id: m.account_id,
                account_email: email.clone(),
                subject: super::truncate(&m.subject, 500),
                from: m.from,
                preview: super::truncate(&m.preview, 1000),
            };
            StoredApproval {
                review,
                action: Action::Trash {
                    message_id: *message_id,
                    account_id: m.account_id,
                    provider_message_id: m.provider_message_id,
                    account_email: email,
                },
            }
        }
        ApprovalInput::DisconnectAccount { account_id, .. } => {
            // A reconnect-required account can still be disconnected.
            let a=sqlx::query("SELECT email,provider,display_name FROM provider_accounts WHERE id=$1 AND disabled_at IS NULL FOR SHARE").bind(account_id).fetch_optional(&mut *tx).await?.ok_or_else(AppError::not_found)?;
            let email: String = a.try_get("email")?;
            StoredApproval {
                review: ApprovalReview::DisconnectAccount {
                    account_id: *account_id,
                    email: email.clone(),
                    provider: a.try_get("provider")?,
                    display_name: a.try_get("display_name")?,
                },
                action: Action::Disconnect {
                    account_id: *account_id,
                    email,
                },
            }
        }
    };
    let plain = Zeroizing::new(
        serde_json::to_vec(&payload).map_err(|_| AppError::internal("mcp_approval_encode"))?,
    );
    let encrypted = state.crypto.seal(auth.workspace_id, id, &plain)?;
    let row=sqlx::query("INSERT INTO mcp_mail_approvals(id,workspace_id,user_id,request_id,request_hash,kind,encrypted_payload,expires_at) VALUES($1,$2,$3,$4,$5,$6,$7,clock_timestamp()+interval '15 minutes') RETURNING *")
        .bind(id).bind(auth.workspace_id).bind(auth.user_id).bind(input.request_id()).bind(request_hash).bind(input.kind()).bind(encrypted).fetch_one(&mut *tx).await?;
    let result = approval(state, auth, &row)?;
    super::check_session(&mut tx, auth).await?;
    tx.commit().await?;
    Ok(result)
}

pub async fn get_approval(
    state: &AppState,
    auth: &AuthContext,
    id: Uuid,
) -> Result<Approval, AppError> {
    let mut tx = auth.begin_authorized(&state.pool).await?;
    let row = sqlx::query("SELECT * FROM mcp_mail_approvals WHERE id=$1")
        .bind(id)
        .fetch_optional(&mut *tx)
        .await?
        .ok_or_else(AppError::not_found)?;
    let result = approval(state, auth, &row)?;
    tx.commit().await?;
    Ok(result)
}
pub async fn list_approvals(
    state: &AppState,
    auth: &AuthContext,
) -> Result<Vec<Approval>, AppError> {
    let mut tx = auth.begin_authorized(&state.pool).await?;
    let rows = sqlx::query("SELECT * FROM mcp_mail_approvals ORDER BY created_at DESC,id LIMIT 25")
        .fetch_all(&mut *tx)
        .await?;
    let result = rows
        .iter()
        .map(|row| approval(state, auth, row))
        .collect::<Result<Vec<_>, _>>()?;
    tx.commit().await?;
    Ok(result)
}
pub async fn cancel_action(
    state: &AppState,
    auth: &AuthContext,
    id: Uuid,
) -> Result<Approval, AppError> {
    let mut tx = auth.begin_authorized(&state.pool).await?;
    let row = sqlx::query("SELECT * FROM mcp_mail_approvals WHERE id=$1 FOR UPDATE")
        .bind(id)
        .fetch_optional(&mut *tx)
        .await?
        .ok_or_else(AppError::not_found)?;
    super::check_session(&mut tx, auth).await?;
    if row.try_get::<String, _>("status")? == "pending" {
        sqlx::query("UPDATE mcp_mail_approvals SET status='cancelled',updated_at=clock_timestamp() WHERE id=$1").bind(id).execute(&mut *tx).await?;
    }
    let row = sqlx::query("SELECT * FROM mcp_mail_approvals WHERE id=$1")
        .bind(id)
        .fetch_one(&mut *tx)
        .await?;
    let result = approval(state, auth, &row)?;
    tx.commit().await?;
    Ok(result)
}

/// Browser consent route only. Never register this as an MCP tool.
/// DB-only actions commit with the approval outcome. Provider mutations claim
/// execution before I/O and never retry an ambiguous or interrupted outcome.
pub async fn approve_action(
    state: &AppState,
    auth: &AuthContext,
    id: Uuid,
) -> Result<Approval, AppError> {
    approve_action_with(state, auth, id, &mail::HttpMessageMutation).await
}
/// Same browser-consent operation with provider I/O substitution for fixtures.
/// This operation must never be registered as an MCP tool either.
pub async fn approve_action_with(
    state: &AppState,
    auth: &AuthContext,
    id: Uuid,
    transport: &(impl mail::MessageMutationTransport + ?Sized),
) -> Result<Approval, AppError> {
    let mut tx = auth.begin_authorized(&state.pool).await?;
    let row = sqlx::query("SELECT * FROM mcp_mail_approvals WHERE id=$1 FOR UPDATE")
        .bind(id)
        .fetch_optional(&mut *tx)
        .await?
        .ok_or_else(AppError::not_found)?;
    super::check_session(&mut tx, auth).await?;
    if row.try_get::<String, _>("status")? != "pending" {
        let result = approval(state, auth, &row)?;
        tx.commit().await?;
        return Ok(result);
    }
    let expired: bool = sqlx::query_scalar(
        "SELECT expires_at<=clock_timestamp() FROM mcp_mail_approvals WHERE id=$1",
    )
    .bind(id)
    .fetch_one(&mut *tx)
    .await?;
    if expired {
        sqlx::query("UPDATE mcp_mail_approvals SET status='expired',updated_at=clock_timestamp() WHERE id=$1").bind(id).execute(&mut *tx).await?;
        tx.commit().await?;
        return get_approval(state, auth, id).await;
    }
    let payload = stored(state, auth, &row)?;
    match payload.action {
        Action::Send {
            message,
            account_email,
        } => {
            let account = active_account(&mut tx, message.account_id).await?;
            if account.try_get::<String, _>("email")? != account_email {
                return Err(AppError::conflict(
                    "The sending account changed. Request a new approval.",
                ));
            }
            let item = mail::queue_in_transaction(state, auth, &mut tx, &message).await?;
            check_execution(&mut tx, auth, id).await?;
            finish(&mut tx,id,"completed",Some(json!({"outbox_id":item.id,"status":item.status,"scheduled_at":item.scheduled_at,"undo_until":item.undo_until})),None).await?;
        }
        Action::Disconnect { account_id, email } => {
            postmere_mail::mail_sync::account_operation_lock(
                &mut tx,
                auth.workspace_id,
                auth.user_id,
                account_id,
            )
            .await?;
            let current:Option<String>=sqlx::query_scalar("SELECT email FROM provider_accounts WHERE id=$1 AND disabled_at IS NULL FOR UPDATE").bind(account_id).fetch_optional(&mut *tx).await?;
            if current.as_deref() != Some(email.as_str()) {
                return Err(AppError::conflict(
                    "The account changed or was disconnected. Request a new approval.",
                ));
            }
            mail::disconnect_in_transaction(&mut tx, auth, account_id).await?;
            check_execution(&mut tx, auth, id).await?;
            finish(
                &mut tx,
                id,
                "completed",
                Some(json!({"account_id":account_id,"disconnected":true})),
                None,
            )
            .await?;
        }
        Action::Trash {
            message_id,
            account_id,
            provider_message_id,
            account_email,
        } => {
            let account = active_account(&mut tx, account_id).await?;
            if account.try_get::<String, _>("email")? != account_email {
                return Err(AppError::conflict(
                    "The account changed. Request a new approval.",
                ));
            }
            let current:Option<String>=sqlx::query_scalar("SELECT provider_message_id FROM mail_messages WHERE id=$1 AND account_id=$2 AND deleted_at IS NULL").bind(message_id).bind(account_id).fetch_optional(&mut *tx).await?;
            if current.as_deref() != Some(provider_message_id.as_str()) {
                return Err(AppError::conflict(
                    "The message changed. Request a new approval.",
                ));
            }
            check_execution(&mut tx, auth, id).await?;
            finish(&mut tx, id, "executing", None, None).await?;
            tx.commit().await?;
            let outcome = mail::apply_message_mutation_with(
                state,
                auth,
                message_id,
                Some(&provider_message_id),
                Mutation {
                    is_read: None,
                    is_starred: None,
                    mailbox: Some("trash".into()),
                },
                transport,
            )
            .await;
            let mut tx = auth.begin_authorized(&state.pool).await?;
            match outcome {
                Ok(_) => {
                    finish(
                        &mut tx,
                        id,
                        "completed",
                        Some(json!({"message_id":message_id,"mailbox":"trash"})),
                        None,
                    )
                    .await?
                }
                Err(_) => {
                    finish(
                        &mut tx,
                        id,
                        "uncertain",
                        None,
                        Some("provider_outcome_unconfirmed"),
                    )
                    .await?
                }
            }
            tx.commit().await?;
            return get_approval(state, auth, id).await;
        }
    }
    let row = sqlx::query("SELECT * FROM mcp_mail_approvals WHERE id=$1")
        .bind(id)
        .fetch_one(&mut *tx)
        .await?;
    let result = approval(state, auth, &row)?;
    tx.commit().await?;
    Ok(result)
}
async fn finish(
    tx: &mut Transaction<'_, Postgres>,
    id: Uuid,
    status: &str,
    result: Option<Value>,
    error: Option<&str>,
) -> Result<(), AppError> {
    sqlx::query("UPDATE mcp_mail_approvals SET status=$2,result=$3,error_code=$4,updated_at=clock_timestamp() WHERE id=$1").bind(id).bind(status).bind(result).bind(error).execute(&mut **tx).await?;
    Ok(())
}
async fn check_execution(
    tx: &mut Transaction<'_, Postgres>,
    auth: &AuthContext,
    id: Uuid,
) -> Result<(), AppError> {
    super::check_session(tx, auth).await?;
    let current: bool = sqlx::query_scalar(
        "SELECT expires_at>clock_timestamp() FROM mcp_mail_approvals WHERE id=$1",
    )
    .bind(id)
    .fetch_one(&mut **tx)
    .await?;
    if !current {
        return Err(AppError::conflict(
            "This approval expired. Request a new approval.",
        ));
    }
    Ok(())
}
