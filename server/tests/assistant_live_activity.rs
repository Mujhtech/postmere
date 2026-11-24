//! Live Activities for connected assistants: tokens, start, update, throttle, end.
mod common;
use axum::{
    Extension, Router,
    body::Body,
    http::{Request, StatusCode},
};
use base64::{Engine, engine::general_purpose::URL_SAFE_NO_PAD};
use chrono::Utc;
use http_body_util::BodyExt;
use postmere_core::{AppState, auth::AuthContext, db};
use postmere_push::{
    DeliveryResult, PushKind, PushRequest, PushService, PushTransport, process_live_activity,
    record_assistant_activity,
};
use postmere_server::application;
use serde_json::{Value, json};
use sha2::{Digest, Sha256};
use sqlx::PgPool;
use std::{
    future::Future,
    pin::Pin,
    sync::{Arc, Mutex},
};
use tower::ServiceExt;
use uuid::Uuid;

#[derive(Default)]
struct FakeApple {
    sent: Mutex<Vec<(String, PushKind, Value)>>,
}
impl PushTransport for FakeApple {
    fn send(
        &self,
        request: PushRequest,
    ) -> Pin<Box<dyn Future<Output = DeliveryResult> + Send + '_>> {
        Box::pin(async move {
            assert!(request.expires_at > Utc::now());
            assert_eq!(request.environment, "sandbox");
            assert!(serde_json::to_vec(&request.payload).unwrap().len() <= 4096);
            self.sent.lock().unwrap().push((
                request.token.to_string(),
                request.kind,
                request.payload,
            ));
            DeliveryResult::Accepted
        })
    }
}
impl FakeApple {
    fn take(&self) -> Vec<(String, PushKind, Value)> {
        std::mem::take(&mut *self.sent.lock().unwrap())
    }
}

async fn identity(pool: &PgPool) -> (AuthContext, String) {
    let (user, workspace, session) = (Uuid::new_v4(), Uuid::new_v4(), Uuid::new_v4());
    let token = URL_SAFE_NO_PAD.encode(Sha256::digest(session.as_bytes()));
    sqlx::query("INSERT INTO users(id,email,password_hash) VALUES($1,$2,'fixture-only')")
        .bind(user)
        .bind(format!("live-{user}@example.test"))
        .execute(pool)
        .await
        .unwrap();
    sqlx::query("INSERT INTO workspaces(id,name) VALUES($1,'Live fixture')")
        .bind(workspace)
        .execute(pool)
        .await
        .unwrap();
    sqlx::query("INSERT INTO memberships(workspace_id,user_id,role) VALUES($1,$2,'owner')")
        .bind(workspace)
        .bind(user)
        .execute(pool)
        .await
        .unwrap();
    sqlx::query("INSERT INTO sessions(id,workspace_id,user_id,token_hash,expires_at,absolute_expires_at) VALUES($1,$2,$3,$4,now()+interval '1 day',now()+interval '2 days')")
        .bind(session).bind(workspace).bind(user).bind(Sha256::digest(token.as_bytes()).to_vec()).execute(pool).await.unwrap();
    let auth = AuthContext {
        assistant: false,
        workspace_id: workspace,
        user_id: user,
        session_id: session,
        role: "owner".into(),
    };
    (auth, token)
}

/// An assistant connected through this person's session.
async fn grant(pool: &PgPool, auth: &AuthContext, name: &str) -> Uuid {
    let client = format!("client-{}", Uuid::new_v4().simple());
    sqlx::query("INSERT INTO mcp_oauth_clients(id,name,redirect_uris,auth_method) VALUES($1,$2,ARRAY['https://client.example/callback'],'none')")
        .bind(&client).bind(name).execute(pool).await.unwrap();
    let id = Uuid::new_v4();
    sqlx::query("INSERT INTO mcp_oauth_grants(id,session_id,client_id,resource,scopes,expires_at) VALUES($1,$2,$3,'https://example.test/mcp',ARRAY['mail:read'],now()+interval '1 day')")
        .bind(id).bind(auth.session_id).bind(&client).execute(pool).await.unwrap();
    id
}

async fn call(app: &Router, method: &str, path: String, token: &str, body: Value) -> StatusCode {
    let response = app
        .clone()
        .oneshot(
            Request::builder()
                .method(method)
                .uri(path)
                .header("authorization", format!("Bearer {token}"))
                .header("content-type", "application/json")
                .body(if body.is_null() {
                    Body::empty()
                } else {
                    Body::from(body.to_string())
                })
                .unwrap(),
        )
        .await
        .unwrap();
    let status = response.status();
    let _ = response.into_body().collect().await;
    status
}

async fn drain(state: &AppState, service: &PushService) {
    for _ in 0..50 {
        if !process_live_activity(state, service).await.unwrap() {
            return;
        }
    }
    panic!("the live activity queue should be bounded");
}

/// Makes the activity look quiet and due, as if two minutes passed.
async fn go_quiet(pool: &PgPool, auth: &AuthContext, grant: Uuid) {
    let mut tx = auth.begin(pool).await.unwrap();
    sqlx::query("UPDATE assistant_live_activities SET last_event_at=now()-interval '3 minutes',last_pushed_at=now()-interval '3 minutes' WHERE grant_id=$1")
        .bind(grant).execute(&mut *tx).await.unwrap();
    tx.commit().await.unwrap();
    sqlx::query("UPDATE assistant_live_activity_wakeups SET due_at=now()-interval '1 second',lease_until=NULL WHERE grant_id=$1")
        .bind(grant).execute(pool).await.unwrap();
}

#[tokio::test]
async fn assistant_live_activities_start_update_throttle_and_end() {
    let url = std::env::var("POSTMERE_TEST_DATABASE_URL")
        .expect("Set isolated non-bypass test database URL");
    let pool = db::connect(&url).await.unwrap();
    db::migrate(&pool).await.unwrap();
    let state = AppState::new(pool.clone(), common::config(url))
        .await
        .unwrap();
    let apple = Arc::new(FakeApple::default());
    let service = Arc::new(PushService::with_transport("sandbox", apple.clone()).unwrap());
    let app = application(state.clone(), postmere_push::router()).layer(Extension(service.clone()));
    let (owner, token) = identity(&pool).await;
    let (other, other_token) = identity(&pool).await;
    let installation = Uuid::new_v4();
    let device_token = format!("ab{}", Uuid::new_v4().simple());
    let start_token = format!("ab{}", Uuid::new_v4().simple());
    let activity_token = format!("ab{}", Uuid::new_v4().simple());
    let devices = format!("/v1/push/devices/{installation}");

    // Live Activity tokens ride on a registered notification device.
    assert_eq!(
        call(
            &app,
            "PUT",
            format!("{devices}/live-activities/start-token"),
            &token,
            json!({"token": start_token})
        )
        .await,
        StatusCode::NOT_FOUND
    );
    assert_eq!(call(&app, "PUT", devices.clone(), &token,
                    json!({"token": device_token, "environment": "sandbox", "enabled": false, "accounts": []})).await,
               StatusCode::OK);
    let claude = grant(&pool, &owner, "Claude Code").await;
    let foreign = grant(&pool, &other, "Someone else's assistant").await;

    // No start token yet: tool calls queue nothing.
    record_assistant_activity(&state, claude, "list_messages")
        .await
        .unwrap();
    assert!(!process_live_activity(&state, &service).await.unwrap());
    assert!(apple.take().is_empty());

    assert_eq!(
        call(
            &app,
            "PUT",
            format!("{devices}/live-activities/start-token"),
            &token,
            json!({"token": "not-hex"})
        )
        .await,
        StatusCode::BAD_REQUEST
    );
    assert_eq!(
        call(
            &app,
            "PUT",
            format!("{devices}/live-activities/start-token"),
            &other_token,
            json!({"token": start_token})
        )
        .await,
        StatusCode::NOT_FOUND,
        "another user can't use this installation"
    );
    assert_eq!(
        call(
            &app,
            "PUT",
            format!("{devices}/live-activities/start-token"),
            &token,
            json!({"token": start_token.to_uppercase()})
        )
        .await,
        StatusCode::NO_CONTENT
    );

    // The first tool call starts an activity with push-to-start.
    record_assistant_activity(&state, claude, "list_messages")
        .await
        .unwrap();
    drain(&state, &service).await;
    let sent = apple.take();
    assert_eq!(sent.len(), 1);
    let (to, kind, payload) = &sent[0];
    assert_eq!(to, &start_token, "tokens are stored lowercase and sealed");
    assert_eq!(*kind, PushKind::LiveActivity { urgent: true });
    let aps = &payload["aps"];
    assert_eq!(aps["event"], "start");
    assert_eq!(aps["attributes-type"], "AssistantActivityAttributes");
    assert_eq!(
        aps["attributes"],
        json!({"grantID": claude.to_string(), "clientName": "Claude Code"})
    );
    assert_eq!(aps["content-state"]["tool"], "list_messages");
    assert_eq!(aps["content-state"]["calls"], 1);
    assert_eq!(aps["content-state"]["working"], true);
    assert!(aps["stale-date"].as_i64().unwrap() > Utc::now().timestamp());
    let text = payload.to_string();
    assert!(
        !text.contains("example.test") && !text.contains(&owner.user_id.to_string()),
        "no mail or identity in the payload"
    );

    // Until the device reports the activity's token, nothing more is sent.
    record_assistant_activity(&state, claude, "read_message")
        .await
        .unwrap();
    drain(&state, &service).await;
    assert!(apple.take().is_empty(), "a start isn't repeated");

    // Activity tokens belong to the owner's own assistants.
    assert_eq!(
        call(
            &app,
            "PUT",
            format!("{devices}/live-activities/assistants/{foreign}"),
            &token,
            json!({"token": activity_token})
        )
        .await,
        StatusCode::NOT_FOUND
    );
    assert_eq!(
        call(
            &app,
            "PUT",
            format!("{devices}/live-activities/assistants/{claude}"),
            &token,
            json!({"token": activity_token})
        )
        .await,
        StatusCode::NO_CONTENT
    );
    drain(&state, &service).await;
    let sent = apple.take();
    assert_eq!(sent.len(), 1, "the new activity is brought up to date");
    let (to, kind, payload) = &sent[0];
    assert_eq!(
        (to, *kind),
        (&activity_token, PushKind::LiveActivity { urgent: false })
    );
    assert_eq!(payload["aps"]["event"], "update");
    assert_eq!(payload["aps"]["content-state"]["tool"], "read_message");
    assert_eq!(payload["aps"]["content-state"]["calls"], 2);
    assert_eq!(
        payload["aps"]["content-state"]["recent"],
        json!(["read_message", "list_messages"])
    );

    // Bursts are throttled; the latest state lands once the window passes.
    record_assistant_activity(&state, claude, "create_draft")
        .await
        .unwrap();
    drain(&state, &service).await;
    assert!(
        apple.take().is_empty(),
        "a second update within three seconds waits"
    );
    let due: chrono::DateTime<Utc> =
        sqlx::query_scalar("SELECT due_at FROM assistant_live_activity_wakeups WHERE grant_id=$1")
            .bind(claude)
            .fetch_one(&pool)
            .await
            .unwrap();
    assert!(due > Utc::now(), "rescheduled for after the throttle");
    sqlx::query("UPDATE assistant_live_activity_wakeups SET due_at=now()-interval '1 second' WHERE grant_id=$1").bind(claude).execute(&pool).await.unwrap();
    {
        let mut tx = owner.begin(&pool).await.unwrap();
        sqlx::query("UPDATE assistant_live_activities SET last_pushed_at=now()-interval '5 seconds' WHERE grant_id=$1").bind(claude).execute(&mut *tx).await.unwrap();
        tx.commit().await.unwrap();
    }
    drain(&state, &service).await;
    let sent = apple.take();
    assert_eq!(sent.len(), 1);
    assert_eq!(sent[0].2["aps"]["content-state"]["tool"], "create_draft");
    assert_eq!(sent[0].2["aps"]["content-state"]["calls"], 3);

    // Two quiet minutes end it, and the spent token is dropped.
    go_quiet(&pool, &owner, claude).await;
    drain(&state, &service).await;
    let sent = apple.take();
    assert_eq!(sent.len(), 1);
    assert_eq!(
        (sent[0].0.as_str(), sent[0].1),
        (
            activity_token.as_str(),
            PushKind::LiveActivity { urgent: true }
        )
    );
    assert_eq!(sent[0].2["aps"]["event"], "end");
    assert_eq!(sent[0].2["aps"]["content-state"]["working"], false);
    assert!(sent[0].2["aps"]["dismissal-date"].as_i64().unwrap() > Utc::now().timestamp());
    {
        let mut tx = owner.begin(&pool).await.unwrap();
        let spent: bool = sqlx::query_scalar("SELECT ended_at IS NOT NULL AND encrypted_token IS NULL FROM assistant_live_activities WHERE grant_id=$1")
            .bind(claude).fetch_one(&mut *tx).await.unwrap();
        tx.commit().await.unwrap();
        assert!(spent);
    }

    // The next tool call starts a fresh activity, counting from one.
    record_assistant_activity(&state, claude, "list_drafts")
        .await
        .unwrap();
    drain(&state, &service).await;
    let sent = apple.take();
    assert_eq!(sent.len(), 1);
    assert_eq!(sent[0].2["aps"]["event"], "start");
    assert_eq!(sent[0].2["aps"]["content-state"]["calls"], 1);
    assert_eq!(
        sent[0].2["aps"]["content-state"]["recent"],
        json!(["list_drafts"])
    );

    // Dismissing it on the phone stops updates; revoking the assistant ends it.
    assert_eq!(
        call(
            &app,
            "PUT",
            format!("{devices}/live-activities/assistants/{claude}"),
            &token,
            json!({"token": activity_token})
        )
        .await,
        StatusCode::NO_CONTENT
    );
    drain(&state, &service).await;
    apple.take();
    sqlx::query("UPDATE mcp_oauth_grants SET revoked_at=now() WHERE id=$1")
        .bind(claude)
        .execute(&pool)
        .await
        .unwrap();
    sqlx::query("UPDATE assistant_live_activity_wakeups SET due_at=now()-interval '1 second' WHERE grant_id=$1").bind(claude).execute(&pool).await.unwrap();
    drain(&state, &service).await;
    let sent = apple.take();
    assert_eq!(sent.len(), 1);
    assert_eq!(
        sent[0].2["aps"]["event"], "end",
        "a revoked assistant's activity ends at once"
    );
    record_assistant_activity(&state, claude, "list_messages")
        .await
        .unwrap();
    drain(&state, &service).await;
    assert!(
        apple.take().is_empty(),
        "a revoked assistant starts nothing"
    );

    // Turning Live Activities off removes push-to-start: tool calls start nothing.
    assert_eq!(
        call(
            &app,
            "DELETE",
            format!("{devices}/live-activities/start-token"),
            &token,
            Value::Null
        )
        .await,
        StatusCode::NO_CONTENT
    );
    let cursor = grant(&pool, &owner, "Cursor").await;
    record_assistant_activity(&state, cursor, "list_messages")
        .await
        .unwrap();
    drain(&state, &service).await;
    assert!(apple.take().is_empty());

    let opencode = grant(&pool, &owner, "OpenCode").await;
    assert_eq!(
        call(
            &app,
            "DELETE",
            format!("{devices}/live-activities/assistants/{opencode}"),
            &token,
            Value::Null
        )
        .await,
        StatusCode::NO_CONTENT
    );
}
