//! Workspace sharing is explicit. A shared snapshot never grants provider access.
use axum::{
    Json, Router,
    extract::{DefaultBodyLimit, Path, Query, State},
    http::StatusCode,
    routing::{delete, get, post, put},
};
use base64::{Engine, engine::general_purpose::STANDARD};
use chrono::{DateTime, Utc};
use postmere_core::{AppState, auth::AuthContext, error::AppError};
use postmere_providers::{Message, SendAttachment};
use serde::{Deserialize, Serialize};
use serde_json::{Value, json};
use sqlx::{Postgres, Row, Transaction, postgres::PgRow};
use std::collections::HashSet;
use uuid::Uuid;
use zeroize::Zeroizing;

pub fn router() -> Router<AppState> {
    Router::new()
        .route(
            "/v1/workspace/members",
            get(list_members)
                .post(provision_member)
                .layer(DefaultBodyLimit::max(8192)),
        )
        .route("/v1/workspace/members/{id}", delete(revoke_member))
        .route("/v1/shared/threads", get(list_threads).post(share_thread))
        .route(
            "/v1/shared/threads/{id}",
            get(thread_detail).delete(delete_thread),
        )
        .route("/v1/shared/threads/{id}/members", put(replace_members))
        .route("/v1/shared/threads/{id}/refresh", post(refresh_thread))
        .route(
            "/v1/shared/threads/{id}/comments",
            get(comments)
                .post(add_comment)
                .layer(DefaultBodyLimit::max(45000)),
        )
        .route(
            "/v1/shared/threads/{id}/comments/{comment_id}",
            delete(delete_comment),
        )
        .route("/v1/shared/threads/{id}/presence", put(presence))
        .route(
            "/v1/shared/snippets",
            get(list_snippets).post(create_snippet),
        )
        .route(
            "/v1/shared/snippets/{id}",
            get(get_snippet).put(update_snippet).delete(delete_snippet),
        )
}

#[derive(Serialize)]
struct Member {
    user_id: Uuid,
    email: String,
    role: String,
}
async fn list_members(
    auth: AuthContext,
    State(state): State<AppState>,
) -> Result<Json<Value>, AppError> {
    let rows=sqlx::query("SELECT m.user_id,u.email,m.role FROM memberships m JOIN users u ON u.id=m.user_id WHERE m.workspace_id=$1 AND m.revoked_at IS NULL AND u.disabled_at IS NULL ORDER BY u.email LIMIT 500").bind(auth.workspace_id).fetch_all(&state.pool).await?;
    let members: Vec<Member> = rows
        .iter()
        .map(|r| Member {
            user_id: r.get("user_id"),
            email: r.get("email"),
            role: r.get("role"),
        })
        .collect();
    Ok(Json(json!({"members":members})))
}
#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct ProvisionMember {
    email: String,
    initial_password: String,
    role: String,
}
async fn provision_member(
    auth: AuthContext,
    State(state): State<AppState>,
    Json(input): Json<ProvisionMember>,
) -> Result<(StatusCode, Json<Member>), AppError> {
    auth.require_admin()?;
    state
        .auth
        .rate_limit("provision_member", &auth.user_id.to_string(), 10)
        .await?;
    let password = Zeroizing::new(input.initial_password);
    let email = input.email.trim().to_lowercase();
    if !(12..=1024).contains(&password.len()) {
        return Err(AppError::bad_request(
            "Initial password must contain 12–1024 bytes.",
        ));
    }
    if email.len() > 254
        || email
            .bytes()
            .any(|b| b.is_ascii_control() || b.is_ascii_whitespace())
        || !valid_email(&email)
    {
        return Err(AppError::bad_request("Enter a valid email address."));
    }
    if !matches!(input.role.as_str(), "member" | "admin")
        || (input.role == "admin" && auth.role != "owner")
    {
        return Err(AppError::forbidden());
    }
    let hash = state.auth.hash_new_password(password).await?;
    let user_id = Uuid::new_v4();
    let mut tx = auth.begin(&state.pool).await?;
    // A concurrent demotion cannot authorize account provisioning.
    let role:Option<String>=sqlx::query_scalar("SELECT role FROM memberships WHERE workspace_id=$1 AND user_id=$2 AND revoked_at IS NULL FOR SHARE").bind(auth.workspace_id).bind(auth.user_id).fetch_optional(&mut *tx).await?;
    if !matches!(role.as_deref(), Some("owner" | "admin"))
        || (input.role == "admin" && role.as_deref() != Some("owner"))
    {
        return Err(AppError::forbidden());
    }
    let result = sqlx::query("INSERT INTO users(id,email,password_hash) VALUES($1,$2,$3)")
        .bind(user_id)
        .bind(&email)
        .bind(hash)
        .execute(&mut *tx)
        .await;
    match result {
        Ok(_) => {}
        Err(sqlx::Error::Database(e)) if e.code().as_deref() == Some("23505") => {
            return Err(AppError::conflict(
                "This email already belongs to a user. Its password has not been changed.",
            ));
        }
        Err(e) => return Err(e.into()),
    }
    sqlx::query("INSERT INTO memberships(workspace_id,user_id,role) VALUES($1,$2,$3)")
        .bind(auth.workspace_id)
        .bind(user_id)
        .bind(&input.role)
        .execute(&mut *tx)
        .await?;
    tx.commit().await?;
    Ok((
        StatusCode::CREATED,
        Json(Member {
            user_id,
            email,
            role: input.role,
        }),
    ))
}
fn valid_email(value: &str) -> bool {
    match mailparse::addrparse(value) {
        Ok(list) if list.len() == 1 => {
            matches!(&list[0],mailparse::MailAddr::Single(single) if single.addr==value && value.split('@').count()==2 && !value.starts_with('@') && !value.ends_with('@'))
        }
        _ => false,
    }
}
async fn revoke_member(
    auth: AuthContext,
    State(state): State<AppState>,
    Path(id): Path<Uuid>,
) -> Result<StatusCode, AppError> {
    auth.require_admin()?;
    if id == auth.user_id {
        return Err(AppError::bad_request(
            "You cannot revoke your own membership here.",
        ));
    }
    let mut tx = auth.begin(&state.pool).await?;
    // Take user locks before membership/session locks, as session rotation
    // does. A stable order for both identities also prevents cross-revocations
    // from each holding the other user's row. Non-key locks permit FK checks.
    let mut identities = vec![auth.user_id, id];
    identities.sort_unstable();
    sqlx::query("SELECT id FROM users WHERE id=ANY($1) ORDER BY id FOR NO KEY UPDATE")
        .bind(&identities)
        .fetch_all(&mut *tx)
        .await?;
    let memberships = sqlx::query("SELECT user_id,role,revoked_at FROM memberships WHERE workspace_id=$1 AND user_id=ANY($2) ORDER BY user_id FOR NO KEY UPDATE")
        .bind(auth.workspace_id).bind(&identities).fetch_all(&mut *tx).await?;
    // Authentication may have happened before a target-row wait. Recheck the
    // actor AFTER those waits, and hold the session/workspace state until commit.
    let role:Option<String>=sqlx::query_scalar("SELECT m.role FROM memberships m JOIN users u ON u.id=m.user_id JOIN workspaces w ON w.id=m.workspace_id JOIN sessions s ON s.workspace_id=m.workspace_id AND s.user_id=m.user_id WHERE m.workspace_id=$1 AND m.user_id=$2 AND s.id=$3 AND m.revoked_at IS NULL AND u.disabled_at IS NULL AND w.disabled_at IS NULL AND s.revoked_at IS NULL AND s.expires_at>now() AND s.absolute_expires_at>now() FOR SHARE OF s,w")
        .bind(auth.workspace_id).bind(auth.user_id).bind(auth.session_id).fetch_optional(&mut *tx).await?;
    let role = role
        .filter(|role| matches!(role.as_str(), "owner" | "admin"))
        .ok_or_else(AppError::forbidden)?;
    let target = memberships
        .iter()
        .find(|row| {
            row.get::<Uuid, _>("user_id") == id
                && row.get::<Option<DateTime<Utc>>, _>("revoked_at").is_none()
        })
        .ok_or_else(AppError::not_found)?;
    let target: String = target.get("role");
    if target == "owner" || (role == "admin" && target != "member") {
        return Err(AppError::forbidden());
    }
    sqlx::query("UPDATE memberships SET revoked_at=now() WHERE workspace_id=$1 AND user_id=$2")
        .bind(auth.workspace_id)
        .bind(id)
        .execute(&mut *tx)
        .await?;
    sqlx::query("UPDATE sessions SET revoked_at=now() WHERE workspace_id=$1 AND user_id=$2 AND revoked_at IS NULL").bind(auth.workspace_id).bind(id).execute(&mut *tx).await?;
    tx.commit().await?;
    Ok(StatusCode::NO_CONTENT)
}

#[derive(Deserialize, Serialize, Clone)]
#[serde(deny_unknown_fields)]
struct ShareMember {
    user_id: Uuid,
    permission: String,
}
#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct ShareInput {
    account_id: Uuid,
    provider_thread_id: String,
    members: Vec<ShareMember>,
}
#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct MembersInput {
    members: Vec<ShareMember>,
    expected_version: i64,
}
#[derive(Serialize)]
struct ThreadSummary {
    id: Uuid,
    owner_id: Uuid,
    owner_email: String,
    subject: String,
    created_at: DateTime<Utc>,
    updated_at: DateTime<Utc>,
    permission: String,
    message_count: i64,
    version: i64,
}
fn thread_summary(row: &PgRow) -> ThreadSummary {
    ThreadSummary {
        id: row.get("id"),
        owner_id: row.get("owner_id"),
        owner_email: row.get("owner_email"),
        subject: row.get("subject"),
        created_at: row.get("created_at"),
        updated_at: row.get("updated_at"),
        permission: row.get("permission"),
        message_count: row.get("message_count"),
        version: row.get("version"),
    }
}
async fn load_thread(
    tx: &mut Transaction<'_, Postgres>,
    user: Uuid,
    id: Uuid,
) -> Result<PgRow, AppError> {
    sqlx::query("SELECT t.*,u.email AS owner_email,jsonb_array_length(t.messages)::bigint AS message_count,CASE WHEN t.owner_id=$1 THEN 'owner' ELSE a.permission END AS permission FROM shared_threads t JOIN users u ON u.id=t.owner_id LEFT JOIN shared_thread_members a ON a.thread_id=t.id AND a.user_id=$1 WHERE t.id=$2").bind(user).bind(id).fetch_optional(&mut **tx).await?.ok_or_else(AppError::not_found)
}
async fn validate_members(
    tx: &mut Transaction<'_, Postgres>,
    auth: &AuthContext,
    members: &[ShareMember],
) -> Result<(), AppError> {
    if members.len() > 50 {
        return Err(AppError::bad_request(
            "Share with at most 50 workspace members.",
        ));
    }
    let mut unique = HashSet::new();
    for member in members {
        if member.user_id == auth.user_id
            || !unique.insert(member.user_id)
            || !matches!(member.permission.as_str(), "view" | "comment")
        {
            return Err(AppError::bad_request(
                "Choose distinct workspace members and a valid permission.",
            ));
        }
    }
    let ids: Vec<Uuid> = members.iter().map(|m| m.user_id).collect();
    let active:Vec<Uuid>=sqlx::query_scalar("SELECT m.user_id FROM memberships m JOIN users u ON u.id=m.user_id WHERE m.workspace_id=$1 AND m.user_id=ANY($2) AND m.revoked_at IS NULL AND u.disabled_at IS NULL FOR SHARE OF m").bind(auth.workspace_id).bind(ids).fetch_all(&mut **tx).await?;
    if active.len() != members.len() {
        return Err(AppError::bad_request(
            "Every recipient must be an active member of this workspace.",
        ));
    }
    Ok(())
}
async fn snapshot(
    tx: &mut Transaction<'_, Postgres>,
    account: Uuid,
    thread: &str,
) -> Result<Vec<Message>, AppError> {
    let size:i64=sqlx::query_scalar("SELECT COALESCE(sum(octet_length(normalized::text)),0)::bigint FROM mail_messages WHERE account_id=$1 AND provider_thread_id=$2 AND deleted_at IS NULL").bind(account).bind(thread).fetch_one(&mut **tx).await?;
    if size > 10 * 1024 * 1024 {
        return Err(AppError::bad_request(
            "This thread exceeds the 10 MiB sharing limit.",
        ));
    }
    let rows:Vec<Value>=sqlx::query_scalar("SELECT normalized FROM mail_messages WHERE account_id=$1 AND provider_thread_id=$2 AND deleted_at IS NULL ORDER BY sent_at,id LIMIT 101").bind(account).bind(thread).fetch_all(&mut **tx).await?;
    if rows.is_empty() {
        return Err(AppError::not_found());
    }
    if rows.len() > 100 {
        return Err(AppError::bad_request(
            "This thread exceeds the 100-message sharing limit.",
        ));
    }
    let mut messages = Vec::with_capacity(rows.len());
    let mut size = 0;
    for row in rows {
        let mut message: Message =
            serde_json::from_value(row).map_err(|_| AppError::internal("shared_message_decode"))?;
        message.bcc.clear();
        message.list_unsubscribe.clear();
        message.list_unsubscribe_post.clear();
        message.authentication_results.clear();
        message.dkim_signatures.clear();
        for attachment in &mut message.attachments {
            attachment.inline_data_base64 = None;
            attachment.provider_attachment_id = None;
        }
        size += message.text_body.len() + message.html_body.as_ref().map_or(0, String::len);
        if size > 10 * 1024 * 1024 {
            return Err(AppError::bad_request(
                "This thread exceeds the 10 MiB sharing limit.",
            ));
        }
        messages.push(message);
    }
    Ok(messages)
}
async fn share_thread(
    auth: AuthContext,
    State(state): State<AppState>,
    Json(input): Json<ShareInput>,
) -> Result<(StatusCode, Json<ThreadSummary>), AppError> {
    if input.provider_thread_id.is_empty()
        || input.provider_thread_id.len() > 512
        || input.members.is_empty()
    {
        return Err(AppError::bad_request(
            "Select a thread and at least one workspace member.",
        ));
    }
    state
        .auth
        .rate_limit("share_thread", &auth.user_id.to_string(), 30)
        .await?;
    let mut tx = auth.begin(&state.pool).await?;
    validate_members(&mut tx, &auth, &input.members).await?;
    let messages = snapshot(&mut tx, input.account_id, &input.provider_thread_id).await?;
    let subject: String = messages
        .last()
        .unwrap()
        .subject
        .chars()
        .take(1000)
        .collect();
    let id = Uuid::new_v4();
    sqlx::query("INSERT INTO shared_threads(id,workspace_id,owner_id,account_id,provider_thread_id,subject,messages) VALUES($1,$2,$3,$4,$5,$6,$7)").bind(id).bind(auth.workspace_id).bind(auth.user_id).bind(input.account_id).bind(input.provider_thread_id).bind(subject).bind(serde_json::to_value(messages).map_err(|_|AppError::internal("shared_message_encode"))?).execute(&mut *tx).await?;
    for member in input.members {
        sqlx::query("INSERT INTO shared_thread_members(workspace_id,thread_id,owner_id,user_id,permission) VALUES($1,$2,$3,$4,$5)").bind(auth.workspace_id).bind(id).bind(auth.user_id).bind(member.user_id).bind(member.permission).execute(&mut *tx).await?;
    }
    let result = thread_summary(&load_thread(&mut tx, auth.user_id, id).await?);
    tx.commit().await?;
    Ok((StatusCode::CREATED, Json(result)))
}
async fn list_threads(
    auth: AuthContext,
    State(state): State<AppState>,
) -> Result<Json<Value>, AppError> {
    let mut tx = auth.begin(&state.pool).await?;
    let rows=sqlx::query("SELECT t.id,t.owner_id,t.subject,t.version,t.created_at,t.updated_at,u.email AS owner_email,jsonb_array_length(t.messages)::bigint AS message_count,CASE WHEN t.owner_id=$1 THEN 'owner' ELSE a.permission END AS permission FROM shared_threads t JOIN users u ON u.id=t.owner_id LEFT JOIN shared_thread_members a ON a.thread_id=t.id AND a.user_id=$1 ORDER BY t.updated_at DESC,t.id DESC LIMIT 100").bind(auth.user_id).fetch_all(&mut *tx).await?;
    let threads: Vec<ThreadSummary> = rows.iter().map(thread_summary).collect();
    Ok(Json(json!({"threads":threads})))
}
async fn thread_detail(
    auth: AuthContext,
    State(state): State<AppState>,
    Path(id): Path<Uuid>,
) -> Result<Json<Value>, AppError> {
    let mut tx = auth.begin(&state.pool).await?;
    let row = load_thread(&mut tx, auth.user_id, id).await?;
    let summary = thread_summary(&row);
    let messages: Value = row.get("messages");
    let members=sqlx::query("SELECT a.user_id,u.email,a.permission FROM shared_thread_members a JOIN users u ON u.id=a.user_id JOIN memberships m ON m.workspace_id=a.workspace_id AND m.user_id=a.user_id WHERE a.thread_id=$1 AND m.revoked_at IS NULL AND u.disabled_at IS NULL ORDER BY u.email").bind(id).fetch_all(&mut *tx).await?;
    let members:Vec<Value>=members.iter().map(|r|json!({"user_id":r.get::<Uuid,_>("user_id"),"email":r.get::<String,_>("email"),"permission":r.get::<String,_>("permission")})).collect();
    let page = comment_page(&mut tx, id, None).await?;
    let present=sqlx::query("SELECT p.user_id,u.email,p.expires_at FROM shared_reply_presence p JOIN users u ON u.id=p.user_id JOIN memberships m ON m.workspace_id=p.workspace_id AND m.user_id=p.user_id WHERE p.thread_id=$1 AND p.expires_at>now() AND m.revoked_at IS NULL AND u.disabled_at IS NULL ORDER BY u.email").bind(id).fetch_all(&mut *tx).await?;
    let presence:Vec<Value>=present.iter().map(|r|json!({"user_id":r.get::<Uuid,_>("user_id"),"email":r.get::<String,_>("email"),"expires_at":r.get::<DateTime<Utc>,_>("expires_at")})).collect();
    Ok(Json(
        json!({"thread":summary,"messages":messages,"members":members,"comments":page.comments,"comments_next_before":page.next_before,"presence":presence}),
    ))
}
async fn replace_members(
    auth: AuthContext,
    State(state): State<AppState>,
    Path(id): Path<Uuid>,
    Json(input): Json<MembersInput>,
) -> Result<Json<ThreadSummary>, AppError> {
    let mut tx = auth.begin(&state.pool).await?;
    let row = load_thread(&mut tx, auth.user_id, id).await?;
    if row.get::<Uuid, _>("owner_id") != auth.user_id {
        return Err(AppError::forbidden());
    }
    validate_members(&mut tx, &auth, &input.members).await?;
    let result = sqlx::query(
        "UPDATE shared_threads SET version=version+1,updated_at=now() WHERE id=$1 AND version=$2",
    )
    .bind(id)
    .bind(input.expected_version)
    .execute(&mut *tx)
    .await?;
    if result.rows_affected() != 1 {
        return Err(AppError::conflict(
            "The share changed. Reload before updating permissions.",
        ));
    }
    sqlx::query("DELETE FROM shared_reply_presence WHERE thread_id=$1 AND user_id<>$2")
        .bind(id)
        .bind(auth.user_id)
        .execute(&mut *tx)
        .await?;
    sqlx::query("DELETE FROM shared_thread_members WHERE thread_id=$1")
        .bind(id)
        .execute(&mut *tx)
        .await?;
    for member in input.members {
        sqlx::query("INSERT INTO shared_thread_members(workspace_id,thread_id,owner_id,user_id,permission) VALUES($1,$2,$3,$4,$5)").bind(auth.workspace_id).bind(id).bind(auth.user_id).bind(member.user_id).bind(member.permission).execute(&mut *tx).await?;
    }
    let result = thread_summary(&load_thread(&mut tx, auth.user_id, id).await?);
    tx.commit().await?;
    Ok(Json(result))
}
#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct VersionInput {
    expected_version: i64,
}
async fn refresh_thread(
    auth: AuthContext,
    State(state): State<AppState>,
    Path(id): Path<Uuid>,
    Json(input): Json<VersionInput>,
) -> Result<Json<ThreadSummary>, AppError> {
    let mut tx = auth.begin(&state.pool).await?;
    let row = load_thread(&mut tx, auth.user_id, id).await?;
    if row.get::<Uuid, _>("owner_id") != auth.user_id {
        return Err(AppError::forbidden());
    }
    let messages = snapshot(
        &mut tx,
        row.get("account_id"),
        &row.get::<String, _>("provider_thread_id"),
    )
    .await?;
    let result=sqlx::query("UPDATE shared_threads SET messages=$1,version=version+1,updated_at=now() WHERE id=$2 AND version=$3").bind(serde_json::to_value(messages).map_err(|_|AppError::internal("shared_snapshot_encode"))?).bind(id).bind(input.expected_version).execute(&mut *tx).await?;
    if result.rows_affected() != 1 {
        return Err(AppError::conflict(
            "The share changed. Reload before refreshing.",
        ));
    }
    let result = thread_summary(&load_thread(&mut tx, auth.user_id, id).await?);
    tx.commit().await?;
    Ok(Json(result))
}
async fn delete_thread(
    auth: AuthContext,
    State(state): State<AppState>,
    Path(id): Path<Uuid>,
) -> Result<StatusCode, AppError> {
    let mut tx = auth.begin(&state.pool).await?;
    let row = load_thread(&mut tx, auth.user_id, id).await?;
    if row.get::<Uuid, _>("owner_id") != auth.user_id {
        return Err(AppError::forbidden());
    }
    sqlx::query("DELETE FROM shared_threads WHERE id=$1")
        .bind(id)
        .execute(&mut *tx)
        .await?;
    tx.commit().await?;
    Ok(StatusCode::NO_CONTENT)
}

#[derive(Serialize)]
struct Comment {
    id: Uuid,
    author_id: Uuid,
    author_email: String,
    body: String,
    created_at: DateTime<Utc>,
}
fn comment(row: &PgRow) -> Comment {
    Comment {
        id: row.get("id"),
        author_id: row.get("author_id"),
        author_email: row.get("author_email"),
        body: row.get("body"),
        created_at: row.get("created_at"),
    }
}
#[derive(Serialize)]
struct CommentPage {
    comments: Vec<Comment>,
    next_before: Option<Uuid>,
}
#[derive(Deserialize)]
struct CommentQuery {
    before: Option<Uuid>,
}
async fn comment_page(
    tx: &mut Transaction<'_, Postgres>,
    id: Uuid,
    before: Option<Uuid>,
) -> Result<CommentPage, AppError> {
    let rows=sqlx::query("SELECT c.*,u.email AS author_email FROM shared_comments c JOIN users u ON u.id=c.author_id WHERE c.thread_id=$1 AND ($2::uuid IS NULL OR (c.created_at,c.id)<(SELECT created_at,id FROM shared_comments WHERE id=$2 AND thread_id=$1)) ORDER BY c.created_at DESC,c.id DESC LIMIT 101").bind(id).bind(before).fetch_all(&mut **tx).await?;
    let has_more = rows.len() > 100;
    let mut comments: Vec<Comment> = rows.iter().take(100).map(comment).collect();
    comments.reverse();
    let next_before = if has_more {
        comments.first().map(|c| c.id)
    } else {
        None
    };
    Ok(CommentPage {
        comments,
        next_before,
    })
}
async fn comments(
    auth: AuthContext,
    State(state): State<AppState>,
    Path(id): Path<Uuid>,
    Query(query): Query<CommentQuery>,
) -> Result<Json<CommentPage>, AppError> {
    let mut tx = auth.begin(&state.pool).await?;
    load_thread(&mut tx, auth.user_id, id).await?;
    Ok(Json(comment_page(&mut tx, id, query.before).await?))
}
#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct CommentInput {
    body: String,
}
async fn add_comment(
    auth: AuthContext,
    State(state): State<AppState>,
    Path(id): Path<Uuid>,
    Json(input): Json<CommentInput>,
) -> Result<(StatusCode, Json<Comment>), AppError> {
    let body = input.body.trim();
    if body.is_empty() || body.chars().count() > 10000 || body.contains('\0') {
        return Err(AppError::bad_request(
            "Comment must contain 1–10,000 characters.",
        ));
    }
    state
        .auth
        .rate_limit("shared_comment", &auth.user_id.to_string(), 60)
        .await?;
    let mut tx = auth.begin(&state.pool).await?;
    let row = load_thread(&mut tx, auth.user_id, id).await?;
    if row.get::<String, _>("permission") == "view" {
        return Err(AppError::forbidden());
    }
    let comment_id = Uuid::new_v4();
    sqlx::query("INSERT INTO shared_comments(id,workspace_id,thread_id,owner_id,author_id,body) VALUES($1,$2,$3,$4,$5,$6)").bind(comment_id).bind(auth.workspace_id).bind(id).bind(row.get::<Uuid,_>("owner_id")).bind(auth.user_id).bind(body).execute(&mut *tx).await?;
    let row=sqlx::query("SELECT c.*,u.email AS author_email FROM shared_comments c JOIN users u ON u.id=c.author_id WHERE c.id=$1").bind(comment_id).fetch_one(&mut *tx).await?;
    tx.commit().await?;
    Ok((StatusCode::CREATED, Json(comment(&row))))
}
async fn delete_comment(
    auth: AuthContext,
    State(state): State<AppState>,
    Path((id, comment_id)): Path<(Uuid, Uuid)>,
) -> Result<StatusCode, AppError> {
    let mut tx = auth.begin(&state.pool).await?;
    load_thread(&mut tx, auth.user_id, id).await?;
    let result = sqlx::query("DELETE FROM shared_comments WHERE id=$1 AND thread_id=$2")
        .bind(comment_id)
        .bind(id)
        .execute(&mut *tx)
        .await?;
    if result.rows_affected() != 1 {
        return Err(AppError::not_found());
    }
    tx.commit().await?;
    Ok(StatusCode::NO_CONTENT)
}
#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct PresenceInput {
    active: bool,
}
async fn presence(
    auth: AuthContext,
    State(state): State<AppState>,
    Path(id): Path<Uuid>,
    Json(input): Json<PresenceInput>,
) -> Result<StatusCode, AppError> {
    state
        .auth
        .rate_limit("reply_presence", &auth.user_id.to_string(), 120)
        .await?;
    let mut tx = auth.begin(&state.pool).await?;
    let row = load_thread(&mut tx, auth.user_id, id).await?;
    if input.active {
        if row.get::<String, _>("permission") == "view" {
            return Err(AppError::forbidden());
        }
        sqlx::query("INSERT INTO shared_reply_presence(workspace_id,thread_id,owner_id,user_id,expires_at) VALUES($1,$2,$3,$4,now()+interval '60 seconds') ON CONFLICT(thread_id,user_id) DO UPDATE SET expires_at=excluded.expires_at").bind(auth.workspace_id).bind(id).bind(row.get::<Uuid,_>("owner_id")).bind(auth.user_id).execute(&mut *tx).await?;
    } else {
        sqlx::query("DELETE FROM shared_reply_presence WHERE thread_id=$1 AND user_id=$2")
            .bind(id)
            .bind(auth.user_id)
            .execute(&mut *tx)
            .await?;
    }
    tx.commit().await?;
    Ok(StatusCode::NO_CONTENT)
}

#[derive(Deserialize, Serialize)]
#[serde(deny_unknown_fields)]
struct SharedTemplate {
    title: String,
    body: String,
    kind: String,
    body_rtf_base64: Option<String>,
    to: Option<String>,
    cc: Option<String>,
    bcc: Option<String>,
    subject: Option<String>,
    #[serde(default)]
    attachments: Vec<SendAttachment>,
}
#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct SnippetInput {
    template: SharedTemplate,
}
#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct SnippetUpdate {
    template: SharedTemplate,
    expected_version: i64,
}
fn validate_template(template: &SharedTemplate) -> Result<(), AppError> {
    if template.title.trim().is_empty()
        || template.title.chars().count() > 120
        || template.title.contains('\0')
        || template.body.len() > 1024 * 1024
        || template.body.contains('\0')
        || !matches!(template.kind.as_str(), "snippet" | "template")
    {
        return Err(AppError::bad_request(
            "Template title, kind, or body is invalid.",
        ));
    }
    for field in [&template.to, &template.cc, &template.bcc, &template.subject]
        .into_iter()
        .flatten()
    {
        if field.len() > 2000 || field.contains(['\r', '\n', '\0']) {
            return Err(AppError::bad_request(
                "Template headers must be single-line text under 2,000 bytes.",
            ));
        }
    }
    if let Some(rtf) = &template.body_rtf_base64 {
        if rtf.len() > 1500000 {
            return Err(AppError::bad_request("Rich text exceeds the size limit."));
        }
        let data = STANDARD
            .decode(rtf)
            .map_err(|_| AppError::bad_request("Rich text is not valid base64."))?;
        if data.len() > 1024 * 1024 || !data.starts_with(b"{\\rtf") {
            return Err(AppError::bad_request("Rich text must be RTF under 1 MiB."));
        }
    }
    if template.attachments.len() > 20 {
        return Err(AppError::bad_request(
            "A template can contain at most 20 attachments.",
        ));
    }
    let mut total = 0usize;
    for file in &template.attachments {
        if file.filename.is_empty()
            || file.filename.len() > 240
            || file.filename.contains(['\r', '\n', '\0', '/', '\\'])
            || file.mime_type.len() > 200
            || !file.mime_type.contains('/')
            || file
                .mime_type
                .bytes()
                .any(|b| !b.is_ascii_graphic() || b == b';')
        {
            return Err(AppError::bad_request(
                "Attachment filename or content type is invalid.",
            ));
        }
        if file.data_base64.len() > 28 * 1024 * 1024 {
            return Err(AppError::bad_request(
                "Attachments exceed the 20 MiB limit.",
            ));
        }
        let bytes = STANDARD
            .decode(&file.data_base64)
            .map_err(|_| AppError::bad_request("Attachment content is not valid base64."))?;
        total += bytes.len();
        if total > 20 * 1024 * 1024 {
            return Err(AppError::bad_request(
                "Attachments exceed the 20 MiB limit.",
            ));
        }
    }
    Ok(())
}
fn snippet_value(row: &PgRow, full: bool) -> Value {
    let template: Value = row.get("template");
    let mut result = json!({"id":row.get::<Uuid,_>("id"),"owner_id":row.get::<Uuid,_>("owner_id"),"owner_email":row.get::<String,_>("owner_email"),"version":row.get::<i64,_>("version"),"created_at":row.get::<DateTime<Utc>,_>("created_at"),"updated_at":row.get::<DateTime<Utc>,_>("updated_at")});
    if full {
        result["template"] = template;
    } else {
        result["title"] = template["title"].clone();
        result["kind"] = template["kind"].clone();
    }
    result
}
async fn load_snippet(tx: &mut Transaction<'_, Postgres>, id: Uuid) -> Result<PgRow, AppError> {
    sqlx::query("SELECT s.*,u.email AS owner_email FROM shared_snippets s JOIN users u ON u.id=s.owner_id WHERE s.id=$1").bind(id).fetch_optional(&mut **tx).await?.ok_or_else(AppError::not_found)
}
async fn list_snippets(
    auth: AuthContext,
    State(state): State<AppState>,
) -> Result<Json<Value>, AppError> {
    let mut tx = auth.begin(&state.pool).await?;
    let rows=sqlx::query("SELECT s.id,s.owner_id,s.version,s.created_at,s.updated_at,u.email AS owner_email,jsonb_build_object('title',s.template->'title','kind',s.template->'kind') AS template FROM shared_snippets s JOIN users u ON u.id=s.owner_id ORDER BY s.updated_at DESC,s.id DESC LIMIT 100").fetch_all(&mut *tx).await?;
    Ok(Json(
        json!({"snippets":rows.iter().map(|r|snippet_value(r,false)).collect::<Vec<_>>()}),
    ))
}
async fn get_snippet(
    auth: AuthContext,
    State(state): State<AppState>,
    Path(id): Path<Uuid>,
) -> Result<Json<Value>, AppError> {
    let mut tx = auth.begin(&state.pool).await?;
    Ok(Json(snippet_value(&load_snippet(&mut tx, id).await?, true)))
}
async fn create_snippet(
    auth: AuthContext,
    State(state): State<AppState>,
    Json(input): Json<SnippetInput>,
) -> Result<(StatusCode, Json<Value>), AppError> {
    validate_template(&input.template)?;
    state
        .auth
        .rate_limit("shared_snippet", &auth.user_id.to_string(), 30)
        .await?;
    let mut tx = auth.begin(&state.pool).await?;
    let id = Uuid::new_v4();
    sqlx::query(
        "INSERT INTO shared_snippets(id,workspace_id,owner_id,template) VALUES($1,$2,$3,$4)",
    )
    .bind(id)
    .bind(auth.workspace_id)
    .bind(auth.user_id)
    .bind(serde_json::to_value(input.template).map_err(|_| AppError::internal("template_encode"))?)
    .execute(&mut *tx)
    .await?;
    let value = snippet_value(&load_snippet(&mut tx, id).await?, true);
    tx.commit().await?;
    Ok((StatusCode::CREATED, Json(value)))
}
async fn update_snippet(
    auth: AuthContext,
    State(state): State<AppState>,
    Path(id): Path<Uuid>,
    Json(input): Json<SnippetUpdate>,
) -> Result<Json<Value>, AppError> {
    validate_template(&input.template)?;
    let mut tx = auth.begin(&state.pool).await?;
    let row = load_snippet(&mut tx, id).await?;
    if row.get::<Uuid, _>("owner_id") != auth.user_id {
        return Err(AppError::forbidden());
    }
    let changed=sqlx::query("UPDATE shared_snippets SET template=$1,version=version+1,updated_at=now() WHERE id=$2 AND version=$3").bind(serde_json::to_value(input.template).map_err(|_|AppError::internal("template_encode"))?).bind(id).bind(input.expected_version).execute(&mut *tx).await?;
    if changed.rows_affected() != 1 {
        return Err(AppError::conflict(
            "The template changed. Reload before saving.",
        ));
    }
    let value = snippet_value(&load_snippet(&mut tx, id).await?, true);
    tx.commit().await?;
    Ok(Json(value))
}
async fn delete_snippet(
    auth: AuthContext,
    State(state): State<AppState>,
    Path(id): Path<Uuid>,
) -> Result<StatusCode, AppError> {
    let mut tx = auth.begin(&state.pool).await?;
    let row = load_snippet(&mut tx, id).await?;
    if row.get::<Uuid, _>("owner_id") != auth.user_id {
        return Err(AppError::forbidden());
    }
    sqlx::query("DELETE FROM shared_snippets WHERE id=$1")
        .bind(id)
        .execute(&mut *tx)
        .await?;
    tx.commit().await?;
    Ok(StatusCode::NO_CONTENT)
}
