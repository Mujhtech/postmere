use chrono::{DateTime, Utc};
use postmere_core::{AppState, auth::AuthContext, error::AppError};
use postmere_mail::mail;
use postmere_providers::{Address, Outgoing, SendAttachment};
use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};
use sqlx::{Postgres, Row, Transaction, postgres::PgRow};
use uuid::Uuid;
use zeroize::Zeroizing;

#[derive(Clone, Default, Deserialize, Serialize)]
#[serde(default)]
pub struct DraftContent {
    pub account_id: Option<Uuid>,
    pub to: Vec<Address>,
    pub cc: Vec<Address>,
    pub bcc: Vec<Address>,
    pub subject: String,
    pub text_body: String,
    pub html_body: Option<String>,
    pub attachments: Vec<SendAttachment>,
    pub scheduled_at: Option<DateTime<Utc>>,
    pub undo_seconds: Option<i64>,
    pub track_opens: bool,
    pub track_links: bool,
    pub in_reply_to: Option<String>,
    pub references: Vec<String>,
    pub provider_thread_id: Option<String>,
}
impl DraftContent {
    pub(crate) fn outgoing(&self, client_id: Uuid) -> Result<Outgoing, AppError> {
        Ok(Outgoing {
            client_id,
            account_id: self
                .account_id
                .ok_or_else(|| AppError::bad_request("Choose a sending account first."))?,
            to: self.to.clone(),
            cc: self.cc.clone(),
            bcc: self.bcc.clone(),
            subject: self.subject.clone(),
            text_body: self.text_body.clone(),
            html_body: self.html_body.clone(),
            attachments: self.attachments.clone(),
            scheduled_at: self.scheduled_at,
            undo_seconds: self.undo_seconds,
            track_opens: self.track_opens,
            track_links: self.track_links,
            in_reply_to: self.in_reply_to.clone(),
            references: self.references.clone(),
            provider_thread_id: self.provider_thread_id.clone(),
        })
    }
    fn validate(&self) -> Result<(), AppError> {
        let mut probe = self.clone();
        probe.account_id = Some(probe.account_id.unwrap_or(Uuid::nil()));
        // Incomplete drafts may omit recipients; all supplied addresses and all
        // content/file bounds still pass through the production send validator.
        if probe.to.is_empty() && probe.cc.is_empty() && probe.bcc.is_empty() {
            probe.to.push(Address {
                name: None,
                email: "draft@example.test".into(),
            });
        }
        mail::validate_outgoing(&probe.outgoing(Uuid::nil())?)
    }
}
#[derive(Deserialize)]
pub struct CreateDraft {
    pub request_id: Uuid,
    pub content: DraftContent,
}
#[derive(Deserialize)]
pub struct UpdateDraft {
    pub draft_id: Uuid,
    pub expected_version: i64,
    pub content: DraftContent,
}
#[derive(Serialize)]
pub struct Draft {
    pub id: Uuid,
    pub version: i64,
    pub created_at: DateTime<Utc>,
    pub updated_at: DateTime<Utc>,
    pub content: DraftContent,
}
#[derive(Serialize)]
pub struct DraftSummary {
    pub id: Uuid,
    pub version: i64,
    pub account_id: Option<Uuid>,
    pub subject: String,
    pub recipient_count: usize,
    pub attachment_count: usize,
    pub created_at: DateTime<Utc>,
    pub updated_at: DateTime<Utc>,
}

pub(crate) fn decode_draft(
    state: &AppState,
    auth: &AuthContext,
    row: &PgRow,
) -> Result<Draft, AppError> {
    let id: Uuid = row.try_get("id")?;
    let encrypted: Vec<u8> = row.try_get("encrypted_content")?;
    let plain = state.crypto.open(auth.workspace_id, id, &encrypted)?;
    let content =
        serde_json::from_slice(&plain).map_err(|_| AppError::internal("mcp_draft_decode"))?;
    Ok(Draft {
        id,
        version: row.try_get("version")?,
        created_at: row.try_get("created_at")?,
        updated_at: row.try_get("updated_at")?,
        content,
    })
}
async fn validate_account(
    tx: &mut Transaction<'_, Postgres>,
    content: &DraftContent,
) -> Result<(), AppError> {
    if let Some(account) = content.account_id {
        let found: Option<Uuid> = sqlx::query_scalar(
            "SELECT id FROM provider_accounts WHERE id=$1 AND disabled_at IS NULL FOR SHARE",
        )
        .bind(account)
        .fetch_optional(&mut **tx)
        .await?;
        found.ok_or_else(AppError::not_found)?;
    }
    Ok(())
}
pub async fn create_draft(
    state: &AppState,
    auth: &AuthContext,
    input: CreateDraft,
) -> Result<Draft, AppError> {
    input.content.validate()?;
    let plain = Zeroizing::new(
        serde_json::to_vec(&input.content).map_err(|_| AppError::internal("mcp_draft_encode"))?,
    );
    let hash = Sha256::digest(&*plain).to_vec();
    let mut tx = auth.begin_authorized(&state.pool).await?;
    super::operation_lock(&mut tx, auth, "drafts").await?;
    if let Some(row) = sqlx::query("SELECT * FROM mcp_mail_drafts WHERE request_id=$1")
        .bind(input.request_id)
        .fetch_optional(&mut *tx)
        .await?
    {
        if row.try_get::<Vec<u8>, _>("creation_hash")? != hash {
            return Err(AppError::conflict(
                "This draft request identifier was used with different content.",
            ));
        }
        let result = decode_draft(state, auth, &row)?;
        super::check_session(&mut tx, auth).await?;
        tx.commit().await?;
        return Ok(result);
    }
    validate_account(&mut tx, &input.content).await?;
    let count: i64 = sqlx::query_scalar("SELECT count(*) FROM mcp_mail_drafts")
        .fetch_one(&mut *tx)
        .await?;
    if count >= 200 {
        return Err(AppError::rate_limited());
    }
    let id = Uuid::new_v4();
    let encrypted = state.crypto.seal(auth.workspace_id, id, &plain)?;
    let row=sqlx::query("INSERT INTO mcp_mail_drafts(id,workspace_id,user_id,request_id,creation_hash,encrypted_content) VALUES($1,$2,$3,$4,$5,$6) RETURNING *")
        .bind(id).bind(auth.workspace_id).bind(auth.user_id).bind(input.request_id).bind(hash).bind(encrypted).fetch_one(&mut *tx).await?;
    let result = decode_draft(state, auth, &row)?;
    super::check_session(&mut tx, auth).await?;
    tx.commit().await?;
    Ok(result)
}
pub async fn update_draft(
    state: &AppState,
    auth: &AuthContext,
    input: UpdateDraft,
) -> Result<Draft, AppError> {
    input.content.validate()?;
    let mut tx = auth.begin_authorized(&state.pool).await?;
    super::operation_lock(&mut tx, auth, "drafts").await?;
    validate_account(&mut tx, &input.content).await?;
    let plain = Zeroizing::new(
        serde_json::to_vec(&input.content).map_err(|_| AppError::internal("mcp_draft_encode"))?,
    );
    let encrypted = state
        .crypto
        .seal(auth.workspace_id, input.draft_id, &plain)?;
    let row=sqlx::query("UPDATE mcp_mail_drafts SET encrypted_content=$3,version=version+1,updated_at=clock_timestamp() WHERE id=$1 AND version=$2 RETURNING *")
        .bind(input.draft_id).bind(input.expected_version).bind(encrypted).fetch_optional(&mut *tx).await?.ok_or_else(||AppError::conflict("This draft was changed or deleted. Read it before editing again."))?;
    let result = decode_draft(state, auth, &row)?;
    super::check_session(&mut tx, auth).await?;
    tx.commit().await?;
    Ok(result)
}
pub async fn get_draft(state: &AppState, auth: &AuthContext, id: Uuid) -> Result<Draft, AppError> {
    let mut tx = auth.begin_authorized(&state.pool).await?;
    let row = sqlx::query("SELECT * FROM mcp_mail_drafts WHERE id=$1")
        .bind(id)
        .fetch_optional(&mut *tx)
        .await?
        .ok_or_else(AppError::not_found)?;
    let result = decode_draft(state, auth, &row)?;
    super::check_session(&mut tx, auth).await?;
    tx.commit().await?;
    Ok(result)
}
pub async fn list_drafts(
    state: &AppState,
    auth: &AuthContext,
) -> Result<Vec<DraftSummary>, AppError> {
    let mut tx = auth.begin_authorized(&state.pool).await?;
    let rows = sqlx::query("SELECT * FROM mcp_mail_drafts ORDER BY updated_at DESC,id LIMIT 50")
        .fetch_all(&mut *tx)
        .await?;
    let mut result = Vec::with_capacity(rows.len());
    for row in rows {
        let d = decode_draft(state, auth, &row)?;
        result.push(DraftSummary {
            id: d.id,
            version: d.version,
            account_id: d.content.account_id,
            subject: d.content.subject,
            recipient_count: d.content.to.len() + d.content.cc.len() + d.content.bcc.len(),
            attachment_count: d.content.attachments.len(),
            created_at: d.created_at,
            updated_at: d.updated_at,
        });
    }
    super::check_session(&mut tx, auth).await?;
    tx.commit().await?;
    Ok(result)
}
pub async fn delete_draft(
    state: &AppState,
    auth: &AuthContext,
    id: Uuid,
    expected_version: i64,
) -> Result<(), AppError> {
    let mut tx = auth.begin_authorized(&state.pool).await?;
    let changed = sqlx::query("DELETE FROM mcp_mail_drafts WHERE id=$1 AND version=$2")
        .bind(id)
        .bind(expected_version)
        .execute(&mut *tx)
        .await?;
    if changed.rows_affected() != 1 {
        return Err(AppError::conflict(
            "This draft was changed or deleted. Read it before deleting again.",
        ));
    }
    super::check_session(&mut tx, auth).await?;
    tx.commit().await?;
    Ok(())
}
