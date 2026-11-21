//! Account-scoped Gmail labels and Outlook categories. Provider IDs are opaque
//! and a message mutation changes only the requested label.
/// The cached names of the labels on message row `m`, as a SQL expression.
macro_rules! label_text {
    () => {
        "coalesce((SELECT string_agg(n.name, ', ' ORDER BY n.name) FROM mail_label_names n \
         WHERE n.account_id=m.account_id AND (m.normalized->'provider_labels') ? n.label_id), '')"
    };
}
pub(crate) use label_text;

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

/// Caches an account's Gmail label names and rewrites each message's
/// `label_text`, so questions and search can match labels by name. Outlook
/// categories are stored on messages by name and need no cache.
pub(crate) async fn store_label_names(
    tx: &mut Transaction<'_, Postgres>,
    workspace: Uuid,
    user: Uuid,
    account: Uuid,
    labels: &[MailLabel],
) -> Result<(), AppError> {
    let ids: Vec<&str> = labels.iter().map(|label| label.id.as_str()).collect();
    let names: Vec<&str> = labels.iter().map(|label| label.name.as_str()).collect();
    sqlx::query("DELETE FROM mail_label_names WHERE account_id=$1 AND NOT (label_id=ANY($2))")
        .bind(account)
        .bind(&ids)
        .execute(&mut **tx)
        .await?;
    sqlx::query(
        "INSERT INTO mail_label_names(workspace_id,user_id,account_id,label_id,name)
         SELECT $1,$2,$3,id,name FROM unnest($4::text[],$5::text[]) AS l(id,name)
         ON CONFLICT(account_id,label_id) DO UPDATE SET name=excluded.name,updated_at=now()",
    )
    .bind(workspace)
    .bind(user)
    .bind(account)
    .bind(&ids)
    .bind(&names)
    .execute(&mut **tx)
    .await?;
    sqlx::query(concat!(
        "UPDATE mail_messages m SET label_text=", label_text!(),
        " WHERE m.account_id=$1 AND m.deleted_at IS NULL AND m.label_text IS DISTINCT FROM ", label_text!()
    ))
    .bind(account)
    .execute(&mut **tx)
    .await?;
    Ok(())
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
    let (mut tx, session) = label_session(&state, &auth, account).await?;
    let labels = provider.list(&state, &session).await?;
    if session.account.provider == "gmail" {
        store_label_names(&mut tx, auth.workspace_id, auth.user_id, account, &labels).await?;
    }
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
    let (mut tx, session) = label_session(&state, &auth, account).await?;
    let label = provider.create(&state, &session, name).await?;
    if session.account.provider == "gmail" {
        sqlx::query("INSERT INTO mail_label_names(workspace_id,user_id,account_id,label_id,name) VALUES($1,$2,$3,$4,$5)
                     ON CONFLICT(account_id,label_id) DO UPDATE SET name=excluded.name,updated_at=now()")
            .bind(auth.workspace_id).bind(auth.user_id).bind(account).bind(&label.id).bind(&label.name)
            .execute(&mut *tx).await?;
    }
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
