mod common;
use axum::{
    Router,
    body::Body,
    http::{Request, StatusCode},
};
use base64::{
    Engine,
    engine::general_purpose::{STANDARD, URL_SAFE_NO_PAD},
};
use chrono::Utc;
use http_body_util::BodyExt;
use postmere_collaboration as collaboration;
use postmere_core::AppState;
use postmere_core::auth::AuthContext;
use postmere_core::db;
use postmere_server::application;
use serde_json::{Value, json};
use sha2::{Digest, Sha256};
use sqlx::PgPool;
use tower::ServiceExt;
use uuid::Uuid;

#[derive(Clone)]
struct Identity {
    auth: AuthContext,
    token: String,
    email: String,
}
async fn identity(pool: &PgPool, workspace: Uuid, role: &str) -> Identity {
    let user = Uuid::new_v4();
    let session = Uuid::new_v4();
    let email = format!("collab-{user}@example.test");
    let token = URL_SAFE_NO_PAD
        .encode([user.as_bytes().as_slice(), session.as_bytes().as_slice()].concat());
    sqlx::query(
        "INSERT INTO users(id,email,password_hash) VALUES($1,$2,'unused fixture password hash')",
    )
    .bind(user)
    .bind(&email)
    .execute(pool)
    .await
    .unwrap();
    sqlx::query(
        "INSERT INTO workspaces(id,name) VALUES($1,'Collaboration fixture') ON CONFLICT DO NOTHING",
    )
    .bind(workspace)
    .execute(pool)
    .await
    .unwrap();
    sqlx::query("INSERT INTO memberships(workspace_id,user_id,role) VALUES($1,$2,$3)")
        .bind(workspace)
        .bind(user)
        .bind(role)
        .execute(pool)
        .await
        .unwrap();
    sqlx::query("INSERT INTO sessions(id,workspace_id,user_id,token_hash,expires_at,absolute_expires_at) VALUES($1,$2,$3,$4,now()+interval '1 day',now()+interval '30 days')").bind(session).bind(workspace).bind(user).bind(Sha256::digest(token.as_bytes()).as_slice()).execute(pool).await.unwrap();
    Identity {
        auth: AuthContext {
            assistant: false,
            user_id: user,
            workspace_id: workspace,
            session_id: session,
            role: role.into(),
        },
        token,
        email,
    }
}
async fn call(
    app: &Router,
    user: &Identity,
    method: &str,
    path: &str,
    body: Value,
) -> (StatusCode, Value) {
    let response = app
        .clone()
        .oneshot(
            Request::builder()
                .method(method)
                .uri(path)
                .header("authorization", format!("Bearer {}", user.token))
                .header("content-type", "application/json")
                .body(Body::from(body.to_string()))
                .unwrap(),
        )
        .await
        .unwrap();
    let status = response.status();
    let bytes = response.into_body().collect().await.unwrap().to_bytes();
    (
        status,
        serde_json::from_slice(&bytes).unwrap_or(Value::Null),
    )
}
fn mail(account: Uuid, message: Uuid) -> Value {
    json!({"id":message,"account_id":account,"provider_message_id":format!("provider-{message}"),"provider_thread_id":"fixture-thread","subject":"Shared planning","from":{"name":"Sender","email":"sender@example.test"},"to":[],"cc":[],"bcc":[{"name":null,"email":"private-bcc@example.test"}],"text_body":"A shared conversation","html_body":null,"preview":"A shared conversation","sent_at":Utc::now(),"is_read":true,"is_starred":false,"mailbox":"inbox","provider_labels":["INBOX"],"attachments":[{"id":Uuid::new_v4(),"filename":"brief.txt","mime_type":"text/plain","size_bytes":5,"provider_attachment_id":"private-provider-attachment","inline_data_base64":STANDARD.encode(b"brief")}],"list_unsubscribe":["https://sender.example/unsubscribe/secret"],"list_unsubscribe_post":["List-Unsubscribe=One-Click"],"authentication_results":["private header"],"dkim_signatures":["private signature"]})
}
async fn cached_message(pool: &PgPool, owner: &Identity, account: Uuid) -> Uuid {
    let id = Uuid::new_v4();
    let mut tx = owner.auth.begin(pool).await.unwrap();
    sqlx::query("INSERT INTO mail_messages(id,workspace_id,user_id,account_id,provider_message_id,provider_thread_id,sent_at,normalized,search_text) VALUES($1,$2,$3,$4,$5,'fixture-thread',now(),$6,'Shared planning')").bind(id).bind(owner.auth.workspace_id).bind(owner.auth.user_id).bind(account).bind(format!("provider-{id}")).bind(mail(account,id)).execute(&mut *tx).await.unwrap();
    tx.commit().await.unwrap();
    id
}
#[tokio::test]
async fn explicit_sharing_enforces_acls_versions_and_workspace_isolation() {
    let url = std::env::var("POSTMERE_TEST_DATABASE_URL")
        .expect("Set POSTMERE_TEST_DATABASE_URL to an isolated NOBYPASSRLS test database");
    let pool = db::connect(&url).await.unwrap();
    db::migrate(&pool).await.unwrap();
    let state = AppState::new(pool.clone(), common::config(url))
        .await
        .unwrap();
    let app = application(state.clone(), collaboration::router());
    let ws = Uuid::new_v4();
    let foreign_ws = Uuid::new_v4();
    let owner = identity(&pool, ws, "owner").await;
    let editor = identity(&pool, ws, "member").await;
    let viewer = identity(&pool, ws, "member").await;
    let unshared = identity(&pool, ws, "member").await;
    let outsider = identity(&pool, foreign_ws, "owner").await;
    let account = Uuid::new_v4();
    let mut tx = owner.auth.begin(&pool).await.unwrap();
    sqlx::query("INSERT INTO provider_accounts(id,workspace_id,user_id,provider,email,encrypted_credentials) VALUES($1,$2,$3,'gmail',$4,$5)").bind(account).bind(ws).bind(owner.auth.user_id).bind(&owner.email).bind(state.crypto.seal(ws,account,b"not used for sharing").unwrap()).execute(&mut *tx).await.unwrap();
    tx.commit().await.unwrap();
    cached_message(&pool, &owner, account).await;
    let share = json!({"account_id":account,"provider_thread_id":"fixture-thread","members":[{"user_id":editor.auth.user_id,"permission":"comment"},{"user_id":viewer.auth.user_id,"permission":"view"}]});
    assert_eq!(
        call(&app, &editor, "POST", "/v1/shared/threads", share.clone())
            .await
            .0,
        StatusCode::BAD_REQUEST,
        "cannot list oneself as a share recipient"
    );
    let stealing = json!({"account_id":account,"provider_thread_id":"fixture-thread","members":[{"user_id":viewer.auth.user_id,"permission":"view"}]});
    assert_eq!(
        call(&app, &editor, "POST", "/v1/shared/threads", stealing)
            .await
            .0,
        StatusCode::NOT_FOUND,
        "private source mail stays owner-scoped"
    );
    let foreign_share = json!({"account_id":account,"provider_thread_id":"fixture-thread","members":[{"user_id":outsider.auth.user_id,"permission":"comment"}]});
    assert_eq!(
        call(&app, &owner, "POST", "/v1/shared/threads", foreign_share)
            .await
            .0,
        StatusCode::BAD_REQUEST
    );
    let (status, shared) = call(&app, &owner, "POST", "/v1/shared/threads", share).await;
    assert_eq!(status, StatusCode::CREATED, "{shared}");
    let id = shared["id"].as_str().unwrap();
    let path = format!("/v1/shared/threads/{id}");
    assert_eq!(shared["permission"], "owner");
    assert_eq!(shared["message_count"], 1);
    for person in [&editor, &viewer] {
        let (status, detail) = call(&app, person, "GET", &path, Value::Null).await;
        assert_eq!(status, StatusCode::OK, "{detail}");
        assert_eq!(detail["messages"][0]["bcc"], json!([]));
        assert_eq!(detail["messages"][0]["list_unsubscribe"], json!([]));
        assert_eq!(detail["messages"][0]["authentication_results"], json!([]));
        assert!(detail["messages"][0]["attachments"][0]["provider_attachment_id"].is_null());
        assert!(detail["messages"][0]["attachments"][0]["inline_data_base64"].is_null());
    }
    for person in [&unshared, &outsider] {
        assert_eq!(
            call(&app, person, "GET", &path, Value::Null).await.0,
            StatusCode::NOT_FOUND
        );
        assert_eq!(
            call(&app, person, "GET", "/v1/shared/threads", Value::Null)
                .await
                .1["threads"],
            json!([])
        );
    }
    let mut raw = unshared.auth.begin(&pool).await.unwrap();
    let visible: i64 = sqlx::query_scalar("SELECT count(*) FROM shared_threads WHERE id=$1")
        .bind(Uuid::parse_str(id).unwrap())
        .fetch_one(&mut *raw)
        .await
        .unwrap();
    assert_eq!(visible, 0);
    raw.rollback().await.unwrap();
    let comments_path = format!("{path}/comments");
    let (status, comment) = call(
        &app,
        &editor,
        "POST",
        &comments_path,
        json!({"body":"I can prepare the draft."}),
    )
    .await;
    assert_eq!(status, StatusCode::CREATED, "{comment}");
    assert_eq!(
        call(
            &app,
            &viewer,
            "POST",
            &comments_path,
            json!({"body":"not allowed"})
        )
        .await
        .0,
        StatusCode::FORBIDDEN
    );
    assert_eq!(
        call(
            &app,
            &unshared,
            "POST",
            &comments_path,
            json!({"body":"not allowed"})
        )
        .await
        .0,
        StatusCode::NOT_FOUND
    );
    assert_eq!(
        call(
            &app,
            &viewer,
            "DELETE",
            &format!("{comments_path}/{}", comment["id"].as_str().unwrap()),
            Value::Null
        )
        .await
        .0,
        StatusCode::NOT_FOUND
    );
    let presence_path = format!("{path}/presence");
    assert_eq!(
        call(&app, &editor, "PUT", &presence_path, json!({"active":true}))
            .await
            .0,
        StatusCode::NO_CONTENT
    );
    assert_eq!(
        call(&app, &viewer, "PUT", &presence_path, json!({"active":true}))
            .await
            .0,
        StatusCode::FORBIDDEN
    );
    let detail = call(&app, &viewer, "GET", &path, Value::Null).await.1;
    assert_eq!(
        detail["presence"][0]["user_id"],
        editor.auth.user_id.to_string()
    );
    assert_eq!(detail["comments"][0]["body"], "I can prepare the draft.");
    let mut raw = editor.auth.begin(&pool).await.unwrap();
    sqlx::query(
        "UPDATE shared_reply_presence SET expires_at=now()-interval '1 second' WHERE thread_id=$1",
    )
    .bind(Uuid::parse_str(id).unwrap())
    .execute(&mut *raw)
    .await
    .unwrap();
    raw.commit().await.unwrap();
    assert_eq!(
        call(&app, &owner, "GET", &path, Value::Null).await.1["presence"],
        json!([])
    );
    let replace = json!({"members":[{"user_id":viewer.auth.user_id,"permission":"view"}],"expected_version":1});
    let members_path = format!("{path}/members");
    assert_eq!(
        call(&app, &editor, "PUT", &members_path, replace.clone())
            .await
            .0,
        StatusCode::FORBIDDEN
    );
    assert_eq!(
        call(&app, &owner, "PUT", &members_path, replace.clone())
            .await
            .0,
        StatusCode::OK
    );
    assert_eq!(
        call(&app, &owner, "PUT", &members_path, replace).await.0,
        StatusCode::CONFLICT
    );
    assert_eq!(
        call(&app, &editor, "GET", &path, Value::Null).await.0,
        StatusCode::NOT_FOUND,
        "revoked share access must end immediately"
    );
    cached_message(&pool, &owner, account).await;
    assert_eq!(
        call(&app, &viewer, "GET", &path, Value::Null).await.1["thread"]["message_count"],
        1,
        "new private replies must not be shared implicitly"
    );
    assert_eq!(
        call(
            &app,
            &owner,
            "POST",
            &format!("{path}/refresh"),
            json!({"expected_version":2})
        )
        .await
        .0,
        StatusCode::OK
    );
    assert_eq!(
        call(&app, &viewer, "GET", &path, Value::Null).await.1["thread"]["message_count"],
        2
    );
    let template = json!({"title":"Team update","body":"Hello {{name}}","kind":"template","body_rtf_base64":STANDARD.encode(b"{\\rtf1 Hello}"),"to":"{{email}}","cc":null,"bcc":null,"subject":"Update","attachments":[{"filename":"brief.txt","mime_type":"text/plain","data_base64":STANDARD.encode(b"brief")} ]});
    let (status, snippet) = call(
        &app,
        &editor,
        "POST",
        "/v1/shared/snippets",
        json!({"template":template}),
    )
    .await;
    assert_eq!(status, StatusCode::CREATED, "{snippet}");
    let snippet_path = format!("/v1/shared/snippets/{}", snippet["id"].as_str().unwrap());
    assert_eq!(
        call(&app, &viewer, "GET", &snippet_path, Value::Null)
            .await
            .1["template"],
        template,
        "shared files/formatting must persist"
    );
    assert_eq!(
        call(&app, &outsider, "GET", &snippet_path, Value::Null)
            .await
            .0,
        StatusCode::NOT_FOUND
    );
    let list = call(&app, &viewer, "GET", "/v1/shared/snippets", Value::Null)
        .await
        .1;
    assert_eq!(list["snippets"][0]["title"], "Team update");
    assert!(
        list["snippets"][0]["template"].is_null(),
        "list must not download attachment bodies"
    );
    assert_eq!(
        call(
            &app,
            &viewer,
            "PUT",
            &snippet_path,
            json!({"template":template,"expected_version":1})
        )
        .await
        .0,
        StatusCode::FORBIDDEN
    );
    assert_eq!(
        call(
            &app,
            &editor,
            "PUT",
            &snippet_path,
            json!({"template":template,"expected_version":1})
        )
        .await
        .0,
        StatusCode::OK
    );
    assert_eq!(
        call(
            &app,
            &editor,
            "PUT",
            &snippet_path,
            json!({"template":template,"expected_version":1})
        )
        .await
        .0,
        StatusCode::CONFLICT
    );
    let mut invalid = template.clone();
    invalid["attachments"][0]["filename"] = json!("../secret");
    assert_eq!(
        call(
            &app,
            &editor,
            "POST",
            "/v1/shared/snippets",
            json!({"template":invalid})
        )
        .await
        .0,
        StatusCode::BAD_REQUEST
    );
    let provision = json!({"email":format!("provisioned-{}@example.test",Uuid::new_v4()),"initial_password":"provisioned fixture password","role":"member"});
    assert_eq!(
        call(
            &app,
            &viewer,
            "POST",
            "/v1/workspace/members",
            provision.clone()
        )
        .await
        .0,
        StatusCode::FORBIDDEN
    );
    let (status, member) = call(
        &app,
        &owner,
        "POST",
        "/v1/workspace/members",
        provision.clone(),
    )
    .await;
    assert_eq!(status, StatusCode::CREATED, "{member}");
    let new_user = Uuid::parse_str(member["user_id"].as_str().unwrap()).unwrap();
    assert_eq!(
        call(&app, &owner, "POST", "/v1/workspace/members", provision)
            .await
            .0,
        StatusCode::CONFLICT,
        "existing password must never be reset by provisioning"
    );
    assert_eq!(
        call(
            &app,
            &owner,
            "DELETE",
            &format!("/v1/workspace/members/{}", viewer.auth.user_id),
            Value::Null
        )
        .await
        .0,
        StatusCode::NO_CONTENT
    );
    assert_eq!(
        call(&app, &viewer, "GET", &path, Value::Null).await.0,
        StatusCode::UNAUTHORIZED
    );
    assert_eq!(
        call(&app, &owner, "DELETE", &path, Value::Null).await.0,
        StatusCode::NO_CONTENT
    );
    assert_eq!(
        call(&app, &editor, "DELETE", &snippet_path, Value::Null)
            .await
            .0,
        StatusCode::NO_CONTENT
    );
    sqlx::query("DELETE FROM workspaces WHERE id=ANY($1)")
        .bind(vec![ws, foreign_ws])
        .execute(&pool)
        .await
        .unwrap();
    sqlx::query("DELETE FROM users WHERE id=ANY($1)")
        .bind(vec![
            owner.auth.user_id,
            editor.auth.user_id,
            viewer.auth.user_id,
            unshared.auth.user_id,
            outsider.auth.user_id,
            new_user,
        ])
        .execute(&pool)
        .await
        .unwrap();
}

#[tokio::test]
async fn member_revocation_rechecks_actor_after_waiting_for_target() {
    let url = std::env::var("POSTMERE_TEST_DATABASE_URL")
        .expect("Set POSTMERE_TEST_DATABASE_URL to an isolated NOBYPASSRLS test database");
    let pool = db::connect(&url).await.unwrap();
    db::migrate(&pool).await.unwrap();
    let state = AppState::new(pool.clone(), common::config(url))
        .await
        .unwrap();
    let app = application(state, collaboration::router());

    for change in ["membership", "role", "session", "workspace"] {
        let workspace = Uuid::new_v4();
        let actor = identity(&pool, workspace, "admin").await;
        let target = identity(&pool, workspace, "member").await;
        let mut blocker = pool.begin().await.unwrap();
        sqlx::query("SELECT id FROM users WHERE id=$1 FOR UPDATE")
            .bind(target.auth.user_id)
            .execute(&mut *blocker)
            .await
            .unwrap();
        let blocker_pid: i32 = sqlx::query_scalar("SELECT pg_backend_pid()")
            .fetch_one(&mut *blocker)
            .await
            .unwrap();
        let request_app = app.clone();
        let request_actor = actor.clone();
        let path = format!("/v1/workspace/members/{}", target.auth.user_id);
        let pending = tokio::spawn(async move {
            call(&request_app, &request_actor, "DELETE", &path, Value::Null).await
        });

        // Observe the database wait, rather than hoping authentication finishes
        // during a fixed sleep. The actor's AuthContext is now already captured.
        tokio::time::timeout(std::time::Duration::from_secs(5), async {
            loop {
                let blocked: bool = sqlx::query_scalar("SELECT EXISTS(SELECT 1 FROM pg_stat_activity WHERE $1=ANY(pg_blocking_pids(pid)))")
                    .bind(blocker_pid).fetch_one(&pool).await.unwrap();
                if blocked { break; }
                tokio::time::sleep(std::time::Duration::from_millis(10)).await;
            }
        }).await.expect("the authenticated request must wait on the target row");

        // These state changes commit while the target is locked. No target
        // identity data is changed by this transaction.
        let mut revoked = pool.begin().await.unwrap();
        match change {
            "membership" => {
                sqlx::query(
                    "UPDATE memberships SET revoked_at=now() WHERE workspace_id=$1 AND user_id=$2",
                )
                .bind(workspace)
                .bind(actor.auth.user_id)
                .execute(&mut *revoked)
                .await
                .unwrap();
            }
            "role" => {
                sqlx::query(
                    "UPDATE memberships SET role='member' WHERE workspace_id=$1 AND user_id=$2",
                )
                .bind(workspace)
                .bind(actor.auth.user_id)
                .execute(&mut *revoked)
                .await
                .unwrap();
            }
            "session" => {
                sqlx::query("UPDATE sessions SET revoked_at=now() WHERE id=$1")
                    .bind(actor.auth.session_id)
                    .execute(&mut *revoked)
                    .await
                    .unwrap();
            }
            "workspace" => {
                sqlx::query("UPDATE workspaces SET disabled_at=now() WHERE id=$1")
                    .bind(workspace)
                    .execute(&mut *revoked)
                    .await
                    .unwrap();
            }
            _ => unreachable!(),
        }
        revoked.commit().await.unwrap();
        blocker.commit().await.unwrap();
        let (status, body) = pending.await.unwrap();
        assert_eq!(
            status,
            StatusCode::FORBIDDEN,
            "stale {change} must not authorize revocation: {body}"
        );
        let target_active: bool = sqlx::query_scalar(
            "SELECT revoked_at IS NULL FROM memberships WHERE workspace_id=$1 AND user_id=$2",
        )
        .bind(workspace)
        .bind(target.auth.user_id)
        .fetch_one(&pool)
        .await
        .unwrap();
        assert!(
            target_active,
            "target membership survives the actor's {change} change"
        );
        let target_session_active: bool =
            sqlx::query_scalar("SELECT revoked_at IS NULL FROM sessions WHERE id=$1")
                .bind(target.auth.session_id)
                .fetch_one(&pool)
                .await
                .unwrap();
        assert!(target_session_active);

        sqlx::query("DELETE FROM workspaces WHERE id=$1")
            .bind(workspace)
            .execute(&pool)
            .await
            .unwrap();
        sqlx::query("DELETE FROM users WHERE id=ANY($1)")
            .bind(vec![actor.auth.user_id, target.auth.user_id])
            .execute(&pool)
            .await
            .unwrap();
    }
}
