use postmere_core::{AppState, auth::AuthContext, error::AppError};
use postmere_mail::mail::{self, Account, OutboxItem};
pub use postmere_mail::mail::{MessageSummary, MessageSummaryPage};
use postmere_providers::{Address, Message, Mutation};
use serde::{Deserialize, Serialize};
use sqlx::Row;
use uuid::Uuid;

#[derive(Default, Deserialize)]
pub struct ListMessagesInput {
    pub account_id: Option<Uuid>,
    pub query: Option<String>,
    pub cursor: Option<String>,
    pub limit: Option<i64>,
}
#[derive(Serialize)]
pub struct AttachmentSummary {
    pub id: Uuid,
    pub filename: String,
    pub mime_type: String,
    pub size_bytes: i64,
}
#[derive(Serialize)]
pub struct MessageDetail {
    #[serde(flatten)]
    pub summary: MessageSummary,
    pub to: Vec<Address>,
    pub cc: Vec<Address>,
    pub bcc: Vec<Address>,
    pub text_body: String,
    pub body_truncated: bool,
    pub attachments: Vec<AttachmentSummary>,
    pub attachments_truncated: bool,
    pub provider_thread_id: String,
    pub rfc_message_id: Option<String>,
    pub references: Vec<String>,
}
fn address(mut value: Address) -> Address {
    value.email = super::truncate(&value.email, 320);
    value.name = value.name.map(|n| super::truncate(&n, 200));
    value
}
fn summary(m: &Message) -> MessageSummary {
    MessageSummary {
        id: m.id,
        account_id: m.account_id,
        subject: super::truncate(&m.subject, 500),
        from: address(m.from.clone()),
        preview: super::truncate(&m.preview, 1000),
        sent_at: m.sent_at,
        is_read: m.is_read,
        is_starred: m.is_starred,
        mailbox: super::truncate(&m.mailbox, 100),
        attachment_count: m.attachments.len(),
    }
}
fn detail(m: Message) -> MessageDetail {
    MessageDetail {
        summary: summary(&m),
        to: m.to.into_iter().take(100).map(address).collect(),
        cc: m.cc.into_iter().take(100).map(address).collect(),
        bcc: m.bcc.into_iter().take(100).map(address).collect(),
        body_truncated: m.text_body.len() > 65_536,
        text_body: super::truncate(&m.text_body, 65_536),
        attachments_truncated: m.attachments.len() > 50,
        attachments: m
            .attachments
            .into_iter()
            .take(50)
            .map(|a| AttachmentSummary {
                id: a.id,
                filename: super::truncate(&a.filename, 255),
                mime_type: super::truncate(&a.mime_type, 200),
                size_bytes: a.size_bytes,
            })
            .collect(),
        provider_thread_id: super::truncate(&m.provider_thread_id, 4096),
        rfc_message_id: m.rfc_message_id.map(|v| super::truncate(&v, 1000)),
        references: m
            .references
            .into_iter()
            .take(100)
            .map(|v| super::truncate(&v, 1000))
            .collect(),
    }
}
pub async fn list_accounts(state: &AppState, auth: &AuthContext) -> Result<Vec<Account>, AppError> {
    mail::list_accounts(state, auth).await
}
pub async fn list_messages(
    state: &AppState,
    auth: &AuthContext,
    input: ListMessagesInput,
) -> Result<MessageSummaryPage, AppError> {
    mail::cached_message_summaries(
        state,
        auth,
        mail::ListRequest {
            account_id: input.account_id,
            query: input.query,
            cursor: input.cursor,
            limit: Some(input.limit.unwrap_or(25).clamp(1, 50)),
        },
    )
    .await
}
pub async fn read_message(
    state: &AppState,
    auth: &AuthContext,
    id: Uuid,
) -> Result<MessageDetail, AppError> {
    let mut tx = auth.begin_authorized(&state.pool).await?;
    let row =
        sqlx::query("SELECT normalized FROM mail_messages WHERE id=$1 AND deleted_at IS NULL")
            .bind(id)
            .fetch_optional(&mut *tx)
            .await?
            .ok_or_else(AppError::not_found)?;
    let message: Message = serde_json::from_value(row.try_get("normalized")?)
        .map_err(|_| AppError::internal("mail_decode"))?;
    tx.commit().await?;
    Ok(detail(message))
}
pub async fn list_outbox(
    state: &AppState,
    auth: &AuthContext,
) -> Result<Vec<OutboxItem>, AppError> {
    let mut tx = auth.begin_authorized(&state.pool).await?;
    let rows = sqlx::query("SELECT id,client_id,account_id,status,scheduled_at,undo_until,provider_message_id,error_code,created_at FROM mail_outbox ORDER BY created_at DESC,id LIMIT 50")
        .fetch_all(&mut *tx)
        .await?;
    let result = rows
        .iter()
        .map(mail::outbox_row)
        .collect::<Result<Vec<_>, _>>()?;
    tx.commit().await?;
    Ok(result)
}
pub async fn cancel_outbox(
    state: &AppState,
    auth: &AuthContext,
    id: Uuid,
) -> Result<OutboxItem, AppError> {
    let mut tx = auth.begin_authorized(&state.pool).await?;
    let result = mail::cancel_in_transaction(&mut tx, id).await?;
    super::check_session(&mut tx, auth).await?;
    tx.commit().await?;
    Ok(result)
}
#[derive(Deserialize)]
pub struct ManageMessageInput {
    pub message_id: Uuid,
    pub is_read: Option<bool>,
    pub is_starred: Option<bool>,
    pub mailbox: Option<String>,
}
#[derive(Serialize)]
pub struct MessageState {
    pub id: Uuid,
    pub account_id: Uuid,
    pub is_read: bool,
    pub is_starred: bool,
    pub mailbox: String,
}
pub async fn manage_message(
    state: &AppState,
    auth: &AuthContext,
    input: ManageMessageInput,
) -> Result<MessageState, AppError> {
    if input
        .mailbox
        .as_deref()
        .is_some_and(|v| !matches!(v, "archive" | "inbox"))
    {
        return Err(AppError::bad_request(
            "Use an approval request to move a message to trash.",
        ));
    }
    let message = mail::apply_message_mutation(
        state,
        auth,
        input.message_id,
        None,
        Mutation {
            is_read: input.is_read,
            is_starred: input.is_starred,
            mailbox: input.mailbox,
        },
    )
    .await?;
    Ok(MessageState {
        id: message.id,
        account_id: message.account_id,
        is_read: message.is_read,
        is_starred: message.is_starred,
        mailbox: super::truncate(&message.mailbox, 100),
    })
}
