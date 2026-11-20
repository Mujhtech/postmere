//! Account-scoped Gmail labels and Outlook categories. Provider IDs are opaque
//! and a message mutation changes only the requested label.
use crate::mail::{self, AccountSession};
use axum::{
    Extension, Json, Router,
    extract::{Path, State},
    routing::get,
};
use postmere_core::{AppState, auth::AuthContext, error::AppError};
use postmere_providers::{self as provider, MailLabel, Message, Provider};
use serde::{Deserialize, Serialize};
use sqlx::{Postgres, Transaction};
use std::collections::HashSet;
use uuid::Uuid;

pub fn router<T: LabelTransport>(transport: T) -> Router<AppState> {
    Router::new()
        .route(
            "/v1/mail/accounts/{account}/labels",
            get(catalog::<T>).post(create::<T>),
        )
        .route(
            "/v1/mail/accounts/{account}/messages/{message}/label",
            get(picker::<T>).put(set::<T>),
        )
        .layer(Extension(transport))
}

#[derive(Serialize)]
struct Catalog {
    labels: Vec<MailLabel>,
}

#[derive(Serialize)]
struct Picker {
    labels: Vec<MailLabel>,
    applied_label_ids: Vec<String>,
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct CreateLabel {
    name: String,
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct SetLabel {
    label_id: String,
    applied: bool,
}

/// A fixture can replace provider I/O while the real routes enforce account
/// ownership, session validity, sync ordering and persistence.
pub trait LabelTransport: Clone + Send + Sync + 'static {
    fn list(
        &self,
        state: &AppState,
        session: &AccountSession,
    ) -> impl Future<Output = Result<Vec<MailLabel>, AppError>> + Send;
    fn create(
        &self,
        state: &AppState,
        session: &AccountSession,
        name: &str,
    ) -> impl Future<Output = Result<MailLabel, AppError>> + Send;
    fn membership(
        &self,
        state: &AppState,
        session: &AccountSession,
        message: &str,
    ) -> impl Future<Output = Result<Vec<String>, AppError>> + Send;
    fn set(
        &self,
        state: &AppState,
        session: &AccountSession,
        message: &str,
        label: &str,
        applied: bool,
    ) -> impl Future<Output = Result<Message, AppError>> + Send;
}

#[derive(Clone)]
pub struct HttpLabels;

impl LabelTransport for HttpLabels {
    async fn list(
        &self,
        state: &AppState,
        session: &AccountSession,
    ) -> Result<Vec<MailLabel>, AppError> {
        Ok(provider::list_labels(
            state,
            Provider::parse(&session.account.provider)?,
            &session.credentials.access_token,
        )
        .await?)
    }
    async fn create(
        &self,
        state: &AppState,
        session: &AccountSession,
        name: &str,
    ) -> Result<MailLabel, AppError> {
        Ok(provider::create_label(
            state,
            Provider::parse(&session.account.provider)?,
            &session.credentials.access_token,
            name,
        )
        .await?)
    }
    async fn membership(
        &self,
        state: &AppState,
        session: &AccountSession,
        message: &str,
    ) -> Result<Vec<String>, AppError> {
        Ok(provider::message_label_membership(
            state,
            Provider::parse(&session.account.provider)?,
            &session.credentials.access_token,
            message,
        )
        .await?)
    }
    async fn set(
        &self,
        state: &AppState,
        session: &AccountSession,
        message: &str,
        label: &str,
        applied: bool,
    ) -> Result<Message, AppError> {
        let kind = Provider::parse(&session.account.provider)?;
        let token = &session.credentials.access_token;
        provider::set_message_label(state, kind, token, message, label, applied).await?;
        let mut updated =
            provider::fetch_message(state, kind, session.account.id, token, message).await?;
        mail::classify_mailboxes(state, session, std::slice::from_mut(&mut updated), None).await?;
        Ok(updated)
    }
}

async fn label_session(
    state: &AppState,
    auth: &AuthContext,
    account: Uuid,
) -> Result<(Transaction<'static, Postgres>, AccountSession), AppError> {
    let session = mail::account_session(state, auth, account).await?;
    let mut tx = auth.begin_authorized(&state.pool).await?;
    crate::mail_sync::account_operation_lock(&mut tx, auth.workspace_id, auth.user_id, account)
        .await?;
    let connected: Option<Uuid> = sqlx::query_scalar("SELECT id FROM provider_accounts WHERE id=$1 AND status='connected' AND disabled_at IS NULL FOR SHARE")
        .bind(account).fetch_optional(&mut *tx).await?;
    connected.ok_or_else(AppError::not_found)?;
    auth.authorize_in_transaction(&mut tx).await?;
    let kind = Provider::parse(&session.account.provider)?;
    if !provider::has_label_scope(kind, &session.credentials) {
        let message = match kind {
            Provider::Gmail => "Reconnect this Google account in Settings to manage Gmail labels.",
            Provider::Microsoft => {
                "Reconnect this Microsoft account in Settings to manage Outlook categories."
            }
        };
        return Err(AppError {
            retry_after_seconds: None,
            status: axum::http::StatusCode::PRECONDITION_FAILED,
            code: "label_permission_required",
            message: message.into(),
        });
    }
    Ok((tx, session))
}

async fn provider_message(
    tx: &mut Transaction<'_, Postgres>,
    account: Uuid,
    message: Uuid,
) -> Result<String, AppError> {
    sqlx::query_scalar("SELECT provider_message_id FROM mail_messages WHERE id=$1 AND account_id=$2 AND deleted_at IS NULL")
        .bind(message).bind(account).fetch_optional(&mut **tx).await?.ok_or_else(AppError::not_found)
}

async fn catalog<T: LabelTransport>(
    State(state): State<AppState>,
    auth: AuthContext,
    Path(account): Path<Uuid>,
    Extension(provider): Extension<T>,
) -> Result<Json<Catalog>, AppError> {
    let (tx, session) = label_session(&state, &auth, account).await?;
    let labels = provider.list(&state, &session).await?;
    tx.commit().await?;
    Ok(Json(Catalog { labels }))
}

async fn create<T: LabelTransport>(
    State(state): State<AppState>,
    auth: AuthContext,
    Path(account): Path<Uuid>,
    Extension(provider): Extension<T>,
    Json(input): Json<CreateLabel>,
) -> Result<Json<MailLabel>, AppError> {
    let name = input.name.trim();
    if name.is_empty() || name.len() > 4096 || name.chars().any(char::is_control) {
        return Err(AppError::bad_request(
            "Enter a valid label or category name.",
        ));
    }
    let (tx, session) = label_session(&state, &auth, account).await?;
    let label = provider.create(&state, &session, name).await?;
    tx.commit().await?;
    Ok(Json(label))
}

async fn picker<T: LabelTransport>(
    State(state): State<AppState>,
    auth: AuthContext,
    Path((account, message)): Path<(Uuid, Uuid)>,
    Extension(provider): Extension<T>,
) -> Result<Json<Picker>, AppError> {
    let (mut tx, session) = label_session(&state, &auth, account).await?;
    let message = provider_message(&mut tx, account, message).await?;
    let (labels, membership) = tokio::try_join!(
        provider.list(&state, &session),
        provider.membership(&state, &session, &message)
    )?;
    let by_name = session.account.provider == "microsoft";
    let keys: HashSet<_> = membership
        .into_iter()
        .map(|entry| if by_name { entry.to_lowercase() } else { entry })
        .collect();
    let applied_label_ids = labels
        .iter()
        .filter(|label| {
            if by_name {
                keys.contains(&label.name.to_lowercase())
            } else {
                keys.contains(&label.id)
            }
        })
        .map(|label| label.id.clone())
        .collect();
    tx.commit().await?;
    Ok(Json(Picker {
        labels,
        applied_label_ids,
    }))
}

async fn set<T: LabelTransport>(
    State(state): State<AppState>,
    auth: AuthContext,
    Path((account, message)): Path<(Uuid, Uuid)>,
    Extension(provider): Extension<T>,
    Json(input): Json<SetLabel>,
) -> Result<Json<Message>, AppError> {
    if input.label_id.trim().is_empty()
        || input.label_id.len() > 4096
        || input.label_id.chars().any(char::is_control)
    {
        return Err(AppError::bad_request("Choose a valid label or category."));
    }
    let (mut tx, session) = label_session(&state, &auth, account).await?;
    let remote_id = provider_message(&mut tx, account, message).await?;
    let mut updated = provider
        .set(&state, &session, &remote_id, &input.label_id, input.applied)
        .await?;
    if updated.account_id != account || updated.provider_message_id != remote_id {
        return Err(AppError::internal("provider_message_mismatch"));
    }
    updated.id = message;
    mail::persist_message(&mut tx, auth.workspace_id, auth.user_id, &updated).await?;
    tx.commit().await?;
    Ok(Json(updated))
}
