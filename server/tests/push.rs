mod common;
use axum::{
    Extension, Router,
    body::Body,
    http::{Request, StatusCode},
};
use base64::{Engine, engine::general_purpose::URL_SAFE_NO_PAD};
use chrono::{DateTime, Duration, Timelike, Utc};
use http_body_util::BodyExt;
use postmere_core::{AppState, auth::AuthContext, db};
use postmere_push::{DeliveryResult, PushRequest, PushService, PushTransport, process_one};
use postmere_server::application;
use serde_json::{Value, json};
use sha2::{Digest, Sha256};
use sqlx::{PgPool, Row};
use std::{
    future::Future,
    pin::Pin,
    sync::{Arc, Mutex},
};
use uuid::Uuid;

#[derive(Default)]
struct FakeApple {
    requests: Mutex<Vec<Value>>,
    result: Mutex<Option<DeliveryResult>>,
}
impl PushTransport for FakeApple {
    fn send(
        &self,
        request: PushRequest,
    ) -> Pin<Box<dyn Future<Output = DeliveryResult> + Send + '_>> {
        Box::pin(async move {
            assert!(request.expires_at > Utc::now());
            assert_eq!(request.environment, "sandbox");
            assert!(request.token.starts_with("ab"));
            assert!(serde_json::to_vec(&request.payload).unwrap().len() <= 4096);
            self.requests.lock().unwrap().push(request.payload);
            self.result
                .lock()
                .unwrap()
                .take()
                .unwrap_or(DeliveryResult::Accepted)
        })
    }
}
async fn identity(pool: &PgPool) -> (AuthContext, String) {
    let user = Uuid::new_v4();
    let workspace = Uuid::new_v4();
    let session = Uuid::new_v4();
    let token = URL_SAFE_NO_PAD.encode(Sha256::digest(session.as_bytes()));
    sqlx::query("INSERT INTO users(id,email,password_hash) VALUES($1,$2,'fixture-only')")
        .bind(user)
        .bind(format!("push-{user}@example.test"))
        .execute(pool)
        .await
        .unwrap();
    sqlx::query("INSERT INTO workspaces(id,name) VALUES($1,'Push fixture')")
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
    (
        AuthContext {
            assistant: false,
            workspace_id: workspace,
            user_id: user,
            session_id: session,
            role: "owner".into(),
        },
        token,
    )
}
async fn create_account(state: &AppState, auth: &AuthContext) -> Uuid {
    create_account_with_email(state, auth, "self@example.test").await
}
async fn create_account_with_email(state: &AppState, auth: &AuthContext, email: &str) -> Uuid {
    let id = Uuid::new_v4();
    let mut tx = auth.begin(&state.pool).await.unwrap();
    sqlx::query("INSERT INTO provider_accounts(id,workspace_id,user_id,provider,email,encrypted_credentials) VALUES($1,$2,$3,'gmail',$4,$5)")
        .bind(id).bind(auth.workspace_id).bind(auth.user_id).bind(email).bind(vec![7u8;64]).execute(&mut *tx).await.unwrap();
    tx.commit().await.unwrap();
    id
}
async fn message(
    state: &AppState,
    auth: &AuthContext,
    account: Uuid,
    date: DateTime<Utc>,
    mailbox: &str,
    read: bool,
    sender: &str,
) -> Uuid {
    let id = Uuid::new_v4();
    let mut tx = auth.begin(&state.pool).await.unwrap();
    let normalized = json!({"id":id,"account_id":account,"subject":"Private fixture subject","from":{"email":sender},"provider_thread_id":"provider-secret-thread","mailbox":mailbox,"is_read":read,"text_body":"Never include this private body","sent_at":date});
    sqlx::query("INSERT INTO mail_messages(id,workspace_id,user_id,account_id,provider_message_id,provider_thread_id,sent_at,normalized,search_text) VALUES($1,$2,$3,$4,$5,'provider-secret-thread',$6,$7,'fixture')")
        .bind(id).bind(auth.workspace_id).bind(auth.user_id).bind(account).bind(id.to_string()).bind(date).bind(normalized).execute(&mut *tx).await.unwrap();
    tx.commit().await.unwrap();
    id
}
async fn request(
    app: &Router,
    method: &str,
    installation: Uuid,
    token: &str,
    body: Value,
) -> (StatusCode, Value) {
    let response = app
        .clone()
        .oneshot(
            Request::builder()
                .method(method)
                .uri(format!("/v1/push/devices/{installation}"))
                .header("authorization", format!("Bearer {token}"))
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
use tower::ServiceExt;
fn registration(account: Uuid, token: &str, preview: bool) -> Value {
    json!({"token":token,"environment":"sandbox","enabled":true,"accounts":[{"account_id":account,"enabled":true,"schedule_enabled":false,"start_minute":540,"end_minute":1080,"weekdays":[2,3,4,5,6],"time_zone":"America/New_York","show_subject":preview,"filter_criteria":format!("remote:fixture:{account}")}]})
}
async fn job_status(state: &AppState, auth: &AuthContext, message: Uuid) -> Option<String> {
    let mut tx = auth.begin(&state.pool).await.unwrap();
    let value = sqlx::query_scalar("SELECT status FROM push_deliveries WHERE message_id=$1")
        .bind(message)
        .fetch_optional(&mut *tx)
        .await
        .unwrap();
    tx.commit().await.unwrap();
    value
}
async fn drain(state: &AppState, service: &PushService) {
    for _ in 0..100 {
        if !process_one(state, service).await.unwrap() {
            return;
        }
    }
    panic!("fixture queue should be bounded");
}

async fn wait_for_blocked(pool: &PgPool, blocking_pid: i32) {
    tokio::time::timeout(std::time::Duration::from_secs(3),async {
        loop {
            let blocked:bool=sqlx::query_scalar("SELECT EXISTS(SELECT 1 FROM pg_stat_activity a WHERE $1=ANY(pg_blocking_pids(a.pid)) AND a.wait_event_type='Lock')")
                .bind(blocking_pid).fetch_one(pool).await.unwrap();
            if blocked {return;}
            tokio::time::sleep(std::time::Duration::from_millis(10)).await;
        }
    }).await.expect("fixture operation must reach the held lock");
}

#[tokio::test]
async fn push_is_opt_in_scoped_private_idempotent_and_revocation_safe() {
    let url = std::env::var("POSTMERE_TEST_DATABASE_URL")
        .expect("Set isolated non-bypass test database URL");
    let pool = db::connect(&url).await.unwrap();
    db::migrate(&pool).await.unwrap();
    let state = AppState::new(pool.clone(), common::config(url))
        .await
        .unwrap();
    let fake = Arc::new(FakeApple::default());
    let service = Arc::new(PushService::with_transport("sandbox", fake.clone()).unwrap());
    let app = application(state.clone(), postmere_push::router()).layer(Extension(service.clone()));
    let disabled = application(state.clone(), postmere_push::router());
    let (owner, token) = identity(&pool).await;
    let (other, other_token) = identity(&pool).await;
    let account = create_account(&state, &owner).await;
    let foreign = create_account(&state, &other).await;
    let installation = Uuid::new_v4();
    let apple_token = format!("ab{}", Uuid::new_v4().simple());
    assert_eq!(
        request(&app, "GET", installation, "invalid", Value::Null)
            .await
            .0,
        StatusCode::UNAUTHORIZED
    );
    assert_eq!(
        request(
            &app,
            "PUT",
            installation,
            &token,
            registration(foreign, &apple_token, false)
        )
        .await
        .0,
        StatusCode::NOT_FOUND
    );
    let (status, value) = request(
        &disabled,
        "PUT",
        installation,
        &token,
        registration(account, &apple_token, false),
    )
    .await;
    assert_eq!(status, StatusCode::OK);
    assert_eq!(value["configured"], false);
    assert_eq!(value["enabled"], false);
    let before = message(
        &state,
        &owner,
        account,
        Utc::now(),
        "inbox",
        false,
        "sender@example.test",
    )
    .await;
    assert_eq!(job_status(&state, &owner, before).await, None);
    let (status, value) = request(
        &app,
        "PUT",
        installation,
        &token,
        registration(account, &apple_token, false),
    )
    .await;
    assert_eq!(status, StatusCode::OK, "{value}");
    assert_eq!(value["active"], true);
    assert_eq!(value["account_ids"], json!([account]));
    // Only encrypted token bytes are persisted in tenant storage.
    let mut tx = owner.begin(&pool).await.unwrap();
    let row = sqlx::query("SELECT id,encrypted_token FROM push_devices WHERE installation_id=$1")
        .bind(installation)
        .fetch_one(&mut *tx)
        .await
        .unwrap();
    let sealed: Vec<u8> = row.get("encrypted_token");
    assert!(
        !sealed
            .windows(apple_token.len())
            .any(|v| v == apple_token.as_bytes())
    );
    assert_eq!(
        state
            .crypto
            .open(owner.workspace_id, row.get("id"), &sealed)
            .unwrap()
            .as_slice(),
        apple_token.as_bytes()
    );
    tx.commit().await.unwrap();
    let cases = [
        (
            Utc::now() - Duration::days(2),
            "inbox",
            false,
            "sender@example.test",
        ),
        (Utc::now(), "inbox", true, "sender@example.test"),
        (Utc::now(), "sent", false, "sender@example.test"),
        (Utc::now(), "trash", false, "sender@example.test"),
        (Utc::now(), "inbox", false, "self@example.test"),
    ];
    for (date, mailbox, read, sender) in cases {
        let id = message(&state, &owner, account, date, mailbox, read, sender).await;
        assert_eq!(job_status(&state, &owner, id).await, None);
    }
    let incoming = message(
        &state,
        &owner,
        account,
        Utc::now(),
        "inbox",
        false,
        "sender@example.test",
    )
    .await;
    assert_eq!(
        job_status(&state, &owner, incoming).await.as_deref(),
        Some("pending")
    );
    drain(&state, &service).await;
    assert_eq!(
        job_status(&state, &owner, incoming).await.as_deref(),
        Some("accepted")
    );
    let payload = fake.requests.lock().unwrap().last().unwrap().clone();
    assert_eq!(payload["message_id"], incoming.to_string());
    assert_eq!(payload["workspace_id"], owner.workspace_id.to_string());
    assert_eq!(
        payload["aps"]["alert"]["body"],
        "Open Postmere to view the message."
    );
    assert_eq!(
        payload["aps"]["filter-criteria"],
        format!("remote:fixture:{account}")
    );
    for forbidden in [
        "Private fixture subject",
        "sender@example.test",
        "Never include",
        "provider-secret-thread",
    ] {
        assert!(!payload.to_string().contains(forbidden));
    }
    let mut tx = owner.begin(&pool).await.unwrap();
    sqlx::query("UPDATE mail_messages SET normalized=jsonb_set(normalized,'{is_read}','false'::jsonb) WHERE id=$1").bind(incoming).execute(&mut *tx).await.unwrap();
    tx.commit().await.unwrap();
    let count = fake.requests.lock().unwrap().len();
    drain(&state, &service).await;
    assert_eq!(fake.requests.lock().unwrap().len(), count);

    // Match provider sync's message-before-account write order. The push must
    // wait on its operation lock, not hold the account while awaiting a message.
    let serialized = message(
        &state,
        &owner,
        account,
        Utc::now(),
        "inbox",
        false,
        "sender@example.test",
    )
    .await;
    let mut held = owner.begin(&pool).await.unwrap();
    postmere_mail::mail_sync::account_operation_lock(
        &mut held,
        owner.workspace_id,
        owner.user_id,
        account,
    )
    .await
    .unwrap();
    postmere_mail::mail_sync::cache_write_lock(
        &mut held,
        owner.workspace_id,
        owner.user_id,
        account,
    )
    .await
    .unwrap();
    let pid: i32 = sqlx::query_scalar("SELECT pg_backend_pid()")
        .fetch_one(&mut *held)
        .await
        .unwrap();
    sqlx::query("UPDATE mail_messages SET updated_at=clock_timestamp() WHERE id=$1")
        .bind(serialized)
        .execute(&mut *held)
        .await
        .unwrap();
    let task_state = state.clone();
    let task_service = service.clone();
    let worker = tokio::spawn(async move { process_one(&task_state, &task_service).await });
    wait_for_blocked(&pool, pid).await;
    tokio::time::timeout(
        std::time::Duration::from_secs(1),
        sqlx::query("UPDATE provider_accounts SET last_synced_at=now() WHERE id=$1")
            .bind(account)
            .execute(&mut *held),
    )
    .await
    .expect("push must not invert provider row locks")
    .unwrap();
    assert_eq!(
        job_status(&state, &owner, serialized).await.as_deref(),
        Some("pending")
    );
    held.commit().await.unwrap();
    assert!(
        tokio::time::timeout(std::time::Duration::from_secs(5), worker)
            .await
            .unwrap()
            .unwrap()
            .unwrap()
    );
    assert_eq!(
        job_status(&state, &owner, serialized).await.as_deref(),
        Some("accepted")
    );

    // Latest preference wins even after the mail arrival was durably queued.
    let count = fake.requests.lock().unwrap().len();
    let queued = message(
        &state,
        &owner,
        account,
        Utc::now(),
        "inbox",
        false,
        "sender@example.test",
    )
    .await;
    let mut preferences = registration(account, &apple_token, true);
    preferences["accounts"][0]["enabled"] = json!(false);
    request(&app, "PUT", installation, &token, preferences).await;
    drain(&state, &service).await;
    assert_eq!(
        job_status(&state, &owner, queued).await.as_deref(),
        Some("cancelled")
    );
    assert_eq!(fake.requests.lock().unwrap().len(), count);
    request(
        &app,
        "PUT",
        installation,
        &token,
        registration(account, &apple_token, true),
    )
    .await;
    let preview = message(
        &state,
        &owner,
        account,
        Utc::now(),
        "inbox",
        false,
        "sender@example.test",
    )
    .await;
    drain(&state, &service).await;
    assert_eq!(
        job_status(&state, &owner, preview).await.as_deref(),
        Some("accepted")
    );
    assert_eq!(
        fake.requests.lock().unwrap().last().unwrap()["aps"]["alert"]["body"],
        "Private fixture subject"
    );

    // A transport ambiguity is terminal; restart cannot generate a duplicate.
    *fake.result.lock().unwrap() = Some(DeliveryResult::Uncertain);
    let uncertain = message(
        &state,
        &owner,
        account,
        Utc::now(),
        "inbox",
        false,
        "sender@example.test",
    )
    .await;
    drain(&state, &service).await;
    assert_eq!(
        job_status(&state, &owner, uncertain).await.as_deref(),
        Some("uncertain")
    );
    let count = fake.requests.lock().unwrap().len();
    drain(&state, &service).await;
    assert_eq!(fake.requests.lock().unwrap().len(), count);
    let interrupted = message(
        &state,
        &owner,
        account,
        Utc::now(),
        "inbox",
        false,
        "sender@example.test",
    )
    .await;
    let mut tx = owner.begin(&pool).await.unwrap();
    sqlx::query("UPDATE push_deliveries SET status='sending' WHERE message_id=$1")
        .bind(interrupted)
        .execute(&mut *tx)
        .await
        .unwrap();
    tx.commit().await.unwrap();
    drain(&state, &service).await;
    assert_eq!(
        job_status(&state, &owner, interrupted).await.as_deref(),
        Some("uncertain")
    );
    assert_eq!(fake.requests.lock().unwrap().len(), count);

    // 410 timestamp predating a fresh registration must not disable it.
    *fake.result.lock().unwrap() = Some(DeliveryResult::InvalidToken(Some(
        (Utc::now() - Duration::days(1)).timestamp_millis(),
    )));
    message(
        &state,
        &owner,
        account,
        Utc::now(),
        "inbox",
        false,
        "sender@example.test",
    )
    .await;
    drain(&state, &service).await;
    assert_eq!(
        request(&app, "GET", installation, &token, Value::Null)
            .await
            .1["active"],
        true
    );
    *fake.result.lock().unwrap() = Some(DeliveryResult::InvalidToken(Some(
        Utc::now().timestamp_millis() + 1000,
    )));
    message(
        &state,
        &owner,
        account,
        Utc::now(),
        "inbox",
        false,
        "sender@example.test",
    )
    .await;
    drain(&state, &service).await;
    assert_eq!(
        request(&app, "GET", installation, &token, Value::Null)
            .await
            .1["active"],
        false
    );
    request(
        &app,
        "PUT",
        installation,
        &token,
        registration(account, &apple_token, false),
    )
    .await;

    // An APNs token transferred to a different signed-in workspace no longer
    // receives old-workspace alerts even if its previous DELETE never arrived.
    let old = message(
        &state,
        &owner,
        account,
        Utc::now(),
        "inbox",
        false,
        "sender@example.test",
    )
    .await;
    let new_installation = Uuid::new_v4();
    request(
        &app,
        "PUT",
        new_installation,
        &other_token,
        registration(foreign, &apple_token, false),
    )
    .await;
    assert_eq!(
        request(&app, "GET", installation, &token, Value::Null)
            .await
            .1["active"],
        false
    );
    let count = fake.requests.lock().unwrap().len();
    drain(&state, &service).await;
    assert_eq!(
        job_status(&state, &owner, old).await.as_deref(),
        Some("cancelled")
    );
    assert_eq!(fake.requests.lock().unwrap().len(), count);
    let recent = message(
        &state,
        &other,
        foreign,
        Utc::now(),
        "inbox",
        false,
        "sender@example.test",
    )
    .await;
    sqlx::query("UPDATE sessions SET revoked_at=now() WHERE id=$1")
        .bind(other.session_id)
        .execute(&pool)
        .await
        .unwrap();
    drain(&state, &service).await;
    assert_eq!(
        job_status(&state, &other, recent).await.as_deref(),
        Some("cancelled")
    );
    assert_eq!(fake.requests.lock().unwrap().len(), count);

    // Account disconnect and explicit device deletion also cancel pending jobs.
    request(
        &app,
        "PUT",
        installation,
        &token,
        registration(account, &apple_token, false),
    )
    .await;
    let disconnect = message(
        &state,
        &owner,
        account,
        Utc::now(),
        "inbox",
        false,
        "sender@example.test",
    )
    .await;
    let mut tx = owner.begin(&pool).await.unwrap();
    sqlx::query("UPDATE provider_accounts SET disabled_at=now() WHERE id=$1")
        .bind(account)
        .execute(&mut *tx)
        .await
        .unwrap();
    tx.commit().await.unwrap();
    drain(&state, &service).await;
    assert_eq!(
        job_status(&state, &owner, disconnect).await.as_deref(),
        Some("cancelled")
    );
    let mut tx = owner.begin(&pool).await.unwrap();
    sqlx::query("UPDATE provider_accounts SET disabled_at=NULL WHERE id=$1")
        .bind(account)
        .execute(&mut *tx)
        .await
        .unwrap();
    tx.commit().await.unwrap();
    let old_import = message(
        &state,
        &owner,
        account,
        Utc::now() - Duration::minutes(1),
        "inbox",
        false,
        "sender@example.test",
    )
    .await;
    assert_eq!(job_status(&state, &owner, old_import).await, None);
    let delete = message(
        &state,
        &owner,
        account,
        Utc::now(),
        "inbox",
        false,
        "sender@example.test",
    )
    .await;
    assert_eq!(
        request(&app, "DELETE", installation, &token, Value::Null)
            .await
            .0,
        StatusCode::OK
    );
    drain(&state, &service).await;
    assert_eq!(
        job_status(&state, &owner, delete).await.as_deref(),
        Some("cancelled")
    );

    // Authorization must still be valid after a registration waits on locks;
    // returning 401 after committing token ownership would be too late.
    let (expiring, expiring_token) = identity(&pool).await;
    let expiring_account = create_account(&state, &expiring).await;
    let expiring_installation = Uuid::new_v4();
    sqlx::query("UPDATE sessions SET expires_at=clock_timestamp()+interval '1 second' WHERE id=$1")
        .bind(expiring.session_id)
        .execute(&pool)
        .await
        .unwrap();
    let mut held = expiring.begin(&pool).await.unwrap();
    sqlx::query("SELECT pg_advisory_xact_lock(hashtextextended($1,0))")
        .bind(format!(
            "pushdevices:{}:{}",
            expiring.workspace_id, expiring.user_id
        ))
        .execute(&mut *held)
        .await
        .unwrap();
    let pid: i32 = sqlx::query_scalar("SELECT pg_backend_pid()")
        .fetch_one(&mut *held)
        .await
        .unwrap();
    let task_app = app.clone();
    let task_token = expiring_token.clone();
    let task_body = registration(
        expiring_account,
        &format!("ab{}", Uuid::new_v4().simple()),
        false,
    );
    let registering = tokio::spawn(async move {
        request(
            &task_app,
            "PUT",
            expiring_installation,
            &task_token,
            task_body,
        )
        .await
    });
    wait_for_blocked(&pool, pid).await;
    tokio::time::sleep(std::time::Duration::from_millis(1100)).await;
    held.commit().await.unwrap();
    assert_eq!(registering.await.unwrap().0, StatusCode::UNAUTHORIZED);
    let mut tx = expiring.begin(&pool).await.unwrap();
    let devices: i64 = sqlx::query_scalar("SELECT count(*) FROM push_devices")
        .fetch_one(&mut *tx)
        .await
        .unwrap();
    assert_eq!(devices, 0);
    tx.commit().await.unwrap();

    // Persistent sessions keep the same registration active beyond the former
    // 24-hour/30-day deadlines. Only each message's own alert lifetime is finite.
    let (persistent, persistent_token) = identity(&pool).await;
    let persistent_account = create_account(&state, &persistent).await;
    let persistent_installation = Uuid::new_v4();
    sqlx::query("UPDATE sessions SET expires_at=NULL,absolute_expires_at=NULL WHERE id=$1")
        .bind(persistent.session_id)
        .execute(&pool)
        .await
        .unwrap();
    let persistent_apple_token = format!("ab{}", Uuid::new_v4().simple());
    let (status, value) = request(
        &app,
        "PUT",
        persistent_installation,
        &persistent_token,
        registration(persistent_account, &persistent_apple_token, false),
    )
    .await;
    assert_eq!(status, StatusCode::OK, "{value}");
    assert!(value["expires_at"].is_null());
    for days in [2, 45, 400] {
        let since = Utc::now() - Duration::days(days);
        let mut tx = persistent.begin(&pool).await.unwrap();
        sqlx::query("UPDATE sessions SET created_at=$2 WHERE id=$1")
            .bind(persistent.session_id)
            .bind(since)
            .execute(&mut *tx)
            .await
            .unwrap();
        sqlx::query("UPDATE provider_accounts SET created_at=$2,push_connected_at=$2 WHERE id=$1")
            .bind(persistent_account)
            .bind(since)
            .execute(&mut *tx)
            .await
            .unwrap();
        sqlx::query("UPDATE push_devices SET first_registered_at=$1,registered_at=$1")
            .bind(since)
            .execute(&mut *tx)
            .await
            .unwrap();
        sqlx::query("UPDATE push_preferences SET enabled_since=$1")
            .bind(since)
            .execute(&mut *tx)
            .await
            .unwrap();
        tx.commit().await.unwrap();
        let (status, value) = request(
            &app,
            "GET",
            persistent_installation,
            &persistent_token,
            Value::Null,
        )
        .await;
        assert_eq!(status, StatusCode::OK);
        assert_eq!(value["enabled"], true);
        assert!(value["expires_at"].is_null());
        let arrived = message(
            &state,
            &persistent,
            persistent_account,
            Utc::now(),
            "inbox",
            false,
            "sender@example.test",
        )
        .await;
        let mut tx = persistent.begin(&pool).await.unwrap();
        let expiry: DateTime<Utc> =
            sqlx::query_scalar("SELECT expires_at FROM push_deliveries WHERE message_id=$1")
                .bind(arrived)
                .fetch_one(&mut *tx)
                .await
                .unwrap();
        assert!(expiry > Utc::now() + Duration::hours(23));
        assert!(expiry <= Utc::now() + Duration::hours(24));
        tx.commit().await.unwrap();
        drain(&state, &service).await;
        assert_eq!(
            job_status(&state, &persistent, arrived).await.as_deref(),
            Some("accepted")
        );
    }
    let stale = message(
        &state,
        &persistent,
        persistent_account,
        Utc::now() - Duration::days(2),
        "inbox",
        false,
        "sender@example.test",
    )
    .await;
    assert_eq!(job_status(&state, &persistent, stale).await, None);
    let before_rotation = message(
        &state,
        &persistent,
        persistent_account,
        Utc::now(),
        "inbox",
        false,
        "sender@example.test",
    )
    .await;
    let response = app
        .clone()
        .oneshot(
            Request::builder()
                .method("POST")
                .uri("/v1/auth/rotate")
                .header("authorization", format!("Bearer {persistent_token}"))
                .body(Body::empty())
                .unwrap(),
        )
        .await
        .unwrap();
    assert_eq!(response.status(), StatusCode::OK);
    let response: Value =
        serde_json::from_slice(&response.into_body().collect().await.unwrap().to_bytes()).unwrap();
    assert_eq!(response["persistent"], true);
    assert!(response["expires_at"].is_null());
    let rotated_token = response["token"].as_str().unwrap().to_string();
    assert_eq!(
        request(
            &app,
            "GET",
            persistent_installation,
            &persistent_token,
            Value::Null
        )
        .await
        .0,
        StatusCode::UNAUTHORIZED
    );
    let (status, value) = request(
        &app,
        "GET",
        persistent_installation,
        &rotated_token,
        Value::Null,
    )
    .await;
    assert_eq!(status, StatusCode::OK);
    assert_eq!(value["enabled"], true);
    assert_eq!(value["account_ids"], json!([persistent_account]));
    drain(&state, &service).await;
    assert_eq!(
        job_status(&state, &persistent, before_rotation)
            .await
            .as_deref(),
        Some("accepted")
    );
    let pending = message(
        &state,
        &persistent,
        persistent_account,
        Utc::now(),
        "inbox",
        false,
        "sender@example.test",
    )
    .await;
    let count = fake.requests.lock().unwrap().len();
    let response = app
        .clone()
        .oneshot(
            Request::builder()
                .method("POST")
                .uri("/v1/auth/logout")
                .header("authorization", format!("Bearer {rotated_token}"))
                .body(Body::empty())
                .unwrap(),
        )
        .await
        .unwrap();
    assert_eq!(response.status(), StatusCode::NO_CONTENT);
    drain(&state, &service).await;
    assert_eq!(
        job_status(&state, &persistent, pending).await.as_deref(),
        Some("cancelled")
    );
    assert_eq!(fake.requests.lock().unwrap().len(), count);
    assert_eq!(
        request(
            &app,
            "GET",
            persistent_installation,
            &rotated_token,
            Value::Null
        )
        .await
        .0,
        StatusCode::UNAUTHORIZED
    );
    let after_logout = message(
        &state,
        &persistent,
        persistent_account,
        Utc::now(),
        "inbox",
        false,
        "sender@example.test",
    )
    .await;
    assert_eq!(job_status(&state, &persistent, after_logout).await, None);

    // Removing the old arbitrary count cutoff supports many mail identities;
    // the request remains bounded by bytes and every account is ownership-checked.
    let (many, many_token) = identity(&pool).await;
    let mut preferences = vec![];
    let mut tx = many.begin(&pool).await.unwrap();
    for _ in 0..129 {
        let id = Uuid::new_v4();
        sqlx::query("INSERT INTO provider_accounts(id,workspace_id,user_id,provider,email,encrypted_credentials) VALUES($1,$2,$3,'gmail',$4,$5)")
            .bind(id).bind(many.workspace_id).bind(many.user_id).bind(format!("{id}@example.test")).bind(vec![7u8;64]).execute(&mut *tx).await.unwrap();
        preferences.push(registration(id, "ab", false)["accounts"][0].clone());
    }
    tx.commit().await.unwrap();
    let mut body = registration(
        Uuid::nil(),
        &format!("ab{}", Uuid::new_v4().simple()),
        false,
    );
    body["accounts"] = json!(preferences);
    let (status, value) = request(&app, "PUT", Uuid::new_v4(), &many_token, body).await;
    assert_eq!(status, StatusCode::OK, "{value}");
    assert_eq!(value["account_ids"].as_array().unwrap().len(), 129);
    sender_policy_contract(&state, &app, &service, &fake).await;
    for auth in [&owner, &other, &expiring, &many, &persistent] {
        sqlx::query("DELETE FROM workspaces WHERE id=$1")
            .bind(auth.workspace_id)
            .execute(&pool)
            .await
            .unwrap();
        sqlx::query("DELETE FROM users WHERE id=$1")
            .bind(auth.user_id)
            .execute(&pool)
            .await
            .unwrap();
    }
}

fn sender_policy(screen: bool, rules: &[(&str, &str)]) -> Value {
    json!({"version":1,"screen_unknown_senders":screen,"rules":rules.iter()
        .map(|(email, route)|json!({"email":email,"route":route})).collect::<Vec<_>>()})
}

fn preferences(body: &Value) -> Value {
    json!({"enabled":body["enabled"],"accounts":body["accounts"]})
}

fn policy_resource(user: Uuid, device: Uuid, account: Uuid) -> Uuid {
    let mut hash = Sha256::new();
    hash.update(b"postmere.push.sender-policy.v1\0");
    hash.update(user.as_bytes());
    hash.update(device.as_bytes());
    hash.update(account.as_bytes());
    Uuid::from_bytes(hash.finalize()[..16].try_into().unwrap())
}

async fn sender_policy_contract(
    state: &AppState,
    app: &Router,
    service: &PushService,
    fake: &FakeApple,
) {
    // Run alongside the existing fixture, not as a parallel test: the worker
    // intentionally claims a global durable queue across all workspaces.
    let (owner, token) = identity(&state.pool).await;
    let (other, other_token) = identity(&state.pool).await;
    let account = create_account(state, &owner).await;
    let second_account = create_account_with_email(state, &owner, "second@example.test").await;
    let foreign = create_account(state, &other).await;
    let installation = Uuid::new_v4();
    let apple_token = format!("ab{}", Uuid::new_v4().simple());
    let mut body = registration(account, &apple_token, false);
    let policy = sender_policy(
        true,
        &[
            ("accepted@example.test", "inbox"),
            ("reply@example.test", "needsReply"),
            ("archive@example.test", "archive"),
            ("blocked@example.test", "blocked"),
            ("deny-first@example.test", "blocked"),
            ("deny-first@example.test", "inbox"),
            ("allow-first@example.test", "inbox"),
            ("allow-first@example.test", "blocked"),
        ],
    );
    body["accounts"][0]["sender_policy"] = policy.clone();
    let mut second_preference = registration(second_account, "ab", false)["accounts"][0].clone();
    second_preference["sender_policy"] = sender_policy(false, &[]);
    body["accounts"]
        .as_array_mut()
        .unwrap()
        .push(second_preference);
    let (status, value) = request(app, "GET", installation, &token, Value::Null).await;
    assert_eq!(status, StatusCode::OK);
    assert_eq!(value["sender_policy_version"], 1);
    assert_eq!(
        request(app, "PATCH", installation, &token, preferences(&body))
            .await
            .0,
        StatusCode::NOT_FOUND
    );
    let (status, value) = request(app, "PUT", installation, &token, body.clone()).await;
    assert_eq!(status, StatusCode::OK, "{value}");
    assert_eq!(value["sender_policy_version"], 1);
    assert_eq!(value["account_ids"].as_array().unwrap().len(), 2);
    assert!(!value.to_string().contains("accepted@example.test"));

    // Neither API status nor plaintext preference JSON reveals sender rules.
    // The private envelope cannot be moved to another workspace/user/device/account.
    let mut tx = owner.begin(&state.pool).await.unwrap();
    let saved = sqlx::query("SELECT d.id,d.encrypted_token,d.token_hash,d.session_id,d.environment,d.registered_at,d.first_registered_at,p.settings,p.encrypted_sender_policy,p.enabled_since FROM push_devices d JOIN push_preferences p ON p.device_id=d.id WHERE d.installation_id=$1 AND p.account_id=$2")
        .bind(installation).bind(account).fetch_one(&mut *tx).await.unwrap();
    tx.commit().await.unwrap();
    let device: Uuid = saved.get("id");
    let settings: Value = saved.get("settings");
    let encrypted: Vec<u8> = saved.get("encrypted_sender_policy");
    assert!(settings.get("sender_policy").is_none());
    assert!(!settings.to_string().contains("accepted@example.test"));
    assert!(
        !encrypted
            .windows(b"accepted@example.test".len())
            .any(|bytes| bytes == b"accepted@example.test")
    );
    let clear = state
        .crypto
        .open(
            owner.workspace_id,
            policy_resource(owner.user_id, device, account),
            &encrypted,
        )
        .unwrap();
    assert_eq!(serde_json::from_slice::<Value>(&clear).unwrap(), policy);
    for (workspace, user, candidate_device, candidate_account) in [
        (other.workspace_id, owner.user_id, device, account),
        (owner.workspace_id, other.user_id, device, account),
        (owner.workspace_id, owner.user_id, Uuid::new_v4(), account),
        (owner.workspace_id, owner.user_id, device, second_account),
    ] {
        assert!(
            state
                .crypto
                .open(
                    workspace,
                    policy_resource(user, candidate_device, candidate_account),
                    &encrypted
                )
                .is_err()
        );
    }
    assert!(
        state
            .crypto
            .open(owner.workspace_id, device, &encrypted)
            .is_err(),
        "policy must not use the token's encryption domain"
    );

    let count = fake.requests.lock().unwrap().len();
    let mut expected = vec![];
    for (sender, allowed) in [
        ("ACCEPTED@example.test", true),
        ("reply@example.test", true),
        ("archive@example.test", false),
        ("blocked@example.test", false),
        ("unknown@example.test", false),
        ("deny-first@example.test", false),
        ("allow-first@example.test", true),
    ] {
        expected.push((
            message(state, &owner, account, Utc::now(), "inbox", false, sender).await,
            allowed,
        ));
    }
    expected.push((
        message(
            state,
            &owner,
            second_account,
            Utc::now(),
            "inbox",
            false,
            "blocked@example.test",
        )
        .await,
        true,
    ));
    // An allow rule never promotes read mail or a provider-archived message.
    for (mailbox, read) in [("archive", false), ("inbox", true)] {
        let id = message(
            state,
            &owner,
            account,
            Utc::now(),
            mailbox,
            read,
            "accepted@example.test",
        )
        .await;
        assert_eq!(job_status(state, &owner, id).await, None);
    }
    drain(state, service).await;
    for (id, allowed) in expected {
        assert_eq!(
            job_status(state, &owner, id).await.as_deref(),
            Some(if allowed { "accepted" } else { "cancelled" })
        );
    }
    assert_eq!(fake.requests.lock().unwrap().len(), count + 4);

    // PATCH needs only preferences. It changes no APNs token, binding, session,
    // registration age or existing account consent cutoff.
    body["accounts"][0]["sender_policy"] = sender_policy(
        false,
        &[
            ("blocked@example.test", "blocked"),
            ("archive@example.test", "archive"),
        ],
    );
    let (status, value) = request(app, "PATCH", installation, &token, preferences(&body)).await;
    assert_eq!(status, StatusCode::OK, "{value}");
    let mut tx = owner.begin(&state.pool).await.unwrap();
    let updated = sqlx::query("SELECT d.id,d.encrypted_token,d.token_hash,d.session_id,d.environment,d.registered_at,d.first_registered_at,p.enabled_since FROM push_devices d JOIN push_preferences p ON p.device_id=d.id WHERE d.installation_id=$1 AND p.account_id=$2")
        .bind(installation).bind(account).fetch_one(&mut *tx).await.unwrap();
    tx.commit().await.unwrap();
    for name in ["encrypted_token", "token_hash"] {
        assert_eq!(
            saved.get::<Vec<u8>, _>(name),
            updated.get::<Vec<u8>, _>(name)
        );
    }
    for name in ["id", "session_id"] {
        assert_eq!(saved.get::<Uuid, _>(name), updated.get::<Uuid, _>(name));
    }
    for name in ["registered_at", "first_registered_at", "enabled_since"] {
        assert_eq!(
            saved.get::<DateTime<Utc>, _>(name),
            updated.get::<DateTime<Utc>, _>(name)
        );
    }
    assert_eq!(
        saved.get::<String, _>("environment"),
        updated.get::<String, _>("environment")
    );
    let count = fake.requests.lock().unwrap().len();
    let unknown = message(
        state,
        &owner,
        account,
        Utc::now(),
        "inbox",
        false,
        "unknown@example.test",
    )
    .await;
    let blocked = message(
        state,
        &owner,
        account,
        Utc::now(),
        "inbox",
        false,
        "blocked@example.test",
    )
    .await;
    let archived = message(
        state,
        &owner,
        account,
        Utc::now(),
        "inbox",
        false,
        "archive@example.test",
    )
    .await;
    drain(state, service).await;
    assert_eq!(
        job_status(state, &owner, unknown).await.as_deref(),
        Some("accepted")
    );
    for id in [blocked, archived] {
        assert_eq!(
            job_status(state, &owner, id).await.as_deref(),
            Some("cancelled")
        );
    }
    assert_eq!(fake.requests.lock().unwrap().len(), count + 1);

    // The policy is read after acquiring delivery locks. An edit while the
    // worker waits for provider sync must stop an already queued notification.
    let pending = message(
        state,
        &owner,
        account,
        Utc::now(),
        "inbox",
        false,
        "newly-blocked@example.test",
    )
    .await;
    let mut held = owner.begin(&state.pool).await.unwrap();
    postmere_mail::mail_sync::account_operation_lock(
        &mut held,
        owner.workspace_id,
        owner.user_id,
        account,
    )
    .await
    .unwrap();
    let pid: i32 = sqlx::query_scalar("SELECT pg_backend_pid()")
        .fetch_one(&mut *held)
        .await
        .unwrap();
    let worker_state = state.clone();
    let worker_service =
        PushService::with_transport("sandbox", Arc::new(FakeApple::default())).unwrap();
    let worker = tokio::spawn(async move { process_one(&worker_state, &worker_service).await });
    wait_for_blocked(&state.pool, pid).await;
    body["accounts"][0]["sender_policy"] = sender_policy(true, &[]);
    let (status, value) = request(app, "PATCH", installation, &token, preferences(&body)).await;
    assert_eq!(status, StatusCode::OK, "{value}");
    // A policy edit wakes queued work but must not relinquish a worker's lease.
    let lease: bool = sqlx::query_scalar("SELECT w.lease_until>clock_timestamp() FROM push_delivery_wakeups w JOIN push_deliveries j ON j.id=w.job_id WHERE j.message_id=$1")
        .bind(pending).fetch_one(&mut *held).await.unwrap();
    assert!(lease);
    held.commit().await.unwrap();
    assert!(
        tokio::time::timeout(std::time::Duration::from_secs(5), worker)
            .await
            .unwrap()
            .unwrap()
            .unwrap()
    );
    assert_eq!(
        job_status(state, &owner, pending).await.as_deref(),
        Some("cancelled")
    );

    // A sender edit wakes quiet-hour jobs now, so suppressed messages are
    // cancelled without waiting until the former delivery window opens.
    let minute = Utc::now().hour() * 60 + Utc::now().minute();
    body["accounts"][0]["schedule_enabled"] = json!(true);
    body["accounts"][0]["start_minute"] = json!((minute + 60) % 1440);
    body["accounts"][0]["end_minute"] = json!((minute + 120) % 1440);
    body["accounts"][0]["weekdays"] = json!([1, 2, 3, 4, 5, 6, 7]);
    body["accounts"][0]["time_zone"] = json!("UTC");
    body["accounts"][0]["sender_policy"] = sender_policy(false, &[]);
    assert_eq!(
        request(app, "PATCH", installation, &token, preferences(&body))
            .await
            .0,
        StatusCode::OK
    );
    let quiet = message(
        state,
        &owner,
        account,
        Utc::now(),
        "inbox",
        false,
        "quiet@example.test",
    )
    .await;
    drain(state, service).await;
    assert_eq!(
        job_status(state, &owner, quiet).await.as_deref(),
        Some("pending")
    );
    let mut tx = owner.begin(&state.pool).await.unwrap();
    let due: DateTime<Utc> = sqlx::query_scalar("SELECT w.due_at FROM push_delivery_wakeups w JOIN push_deliveries j ON j.id=w.job_id WHERE j.message_id=$1")
        .bind(quiet).fetch_one(&mut *tx).await.unwrap();
    assert!(due > Utc::now() + Duration::minutes(30));
    tx.commit().await.unwrap();
    body["accounts"][0]["sender_policy"] = sender_policy(true, &[]);
    assert_eq!(
        request(app, "PATCH", installation, &token, preferences(&body))
            .await
            .0,
        StatusCode::OK
    );
    drain(state, service).await;
    assert_eq!(
        job_status(state, &owner, quiet).await.as_deref(),
        Some("cancelled")
    );

    // Complete validation happens before writes; malformed or overlarge rules
    // cannot clear another valid account's policy or partially enable delivery.
    body["accounts"][0]["schedule_enabled"] = json!(false);
    let mut invalid_policies = vec![
        json!({"version":2,"screen_unknown_senders":false,"rules":[]}),
        sender_policy(false, &[("bad address@example.test", "inbox")]),
        json!({"version":1,"screen_unknown_senders":false,"rules":vec![json!({"email":"a@example.test","route":"inbox"});4097]}),
        json!({"version":1,"screen_unknown_senders":false,"rules":vec![json!({"email":format!("{}@example.test","x".repeat(300)),"route":"inbox"});4096]}),
    ];
    for invalid in invalid_policies.drain(..) {
        let mut candidate = preferences(&body);
        candidate["accounts"][0]["sender_policy"] = sender_policy(false, &[]);
        candidate["accounts"][1]["sender_policy"] = invalid;
        assert_eq!(
            request(app, "PATCH", installation, &token, candidate.clone())
                .await
                .0,
            StatusCode::BAD_REQUEST
        );
        candidate["token"] = json!(apple_token);
        candidate["environment"] = json!("sandbox");
        assert_eq!(
            request(app, "PUT", installation, &token, candidate).await.0,
            StatusCode::BAD_REQUEST
        );
    }
    let mut invalid = preferences(&body);
    invalid["accounts"][0]["sender_policy"]["rules"] =
        json!([{"email":"a@example.test","route":"delete"}]);
    assert_eq!(
        request(app, "PATCH", installation, &token, invalid).await.0,
        StatusCode::UNPROCESSABLE_ENTITY
    );
    let mut excessive = preferences(&body);
    excessive["accounts"][0]["sender_policy"]["rules"] =
        json!([{"email":"x".repeat(2 * 1024 * 1024),"route":"inbox"}]);
    assert_eq!(
        request(app, "PATCH", installation, &token, excessive)
            .await
            .0,
        StatusCode::PAYLOAD_TOO_LARGE
    );
    let still_screened = message(
        state,
        &owner,
        account,
        Utc::now(),
        "inbox",
        false,
        "unknown@example.test",
    )
    .await;
    drain(state, service).await;
    assert_eq!(
        job_status(state, &owner, still_screened).await.as_deref(),
        Some("cancelled")
    );

    // PATCH cannot create a registration, change token ownership or attach it
    // to another login, even for another valid session of the same user.
    assert_eq!(
        request(app, "PATCH", installation, &other_token, preferences(&body))
            .await
            .0,
        StatusCode::NOT_FOUND
    );
    let mut wrong_account = preferences(&body);
    wrong_account["accounts"][1]["account_id"] = json!(foreign);
    assert_eq!(
        request(app, "PATCH", installation, &token, wrong_account)
            .await
            .0,
        StatusCode::NOT_FOUND
    );
    let mut duplicated = preferences(&body);
    duplicated["accounts"][1]["account_id"] = json!(account);
    assert_eq!(
        request(app, "PATCH", installation, &token, duplicated)
            .await
            .0,
        StatusCode::BAD_REQUEST
    );
    let session = Uuid::new_v4();
    let second_token = URL_SAFE_NO_PAD.encode(Sha256::digest(session.as_bytes()));
    sqlx::query("INSERT INTO sessions(id,workspace_id,user_id,token_hash,expires_at,absolute_expires_at) VALUES($1,$2,$3,$4,now()+interval '1 day',now()+interval '2 days')")
        .bind(session).bind(owner.workspace_id).bind(owner.user_id).bind(Sha256::digest(second_token.as_bytes()).to_vec()).execute(&state.pool).await.unwrap();
    assert_eq!(
        request(
            app,
            "PATCH",
            installation,
            &second_token,
            preferences(&body)
        )
        .await
        .0,
        StatusCode::NOT_FOUND
    );
    for field in ["token", "environment"] {
        let mut forbidden = preferences(&body);
        forbidden[field] = json!("replacement");
        assert_eq!(
            request(app, "PATCH", installation, &token, forbidden)
                .await
                .0,
            StatusCode::UNPROCESSABLE_ENTITY
        );
    }

    // Omitting sender_policy is backward compatible and removes the envelope.
    body["accounts"][0]
        .as_object_mut()
        .unwrap()
        .remove("sender_policy");
    assert_eq!(
        request(app, "PATCH", installation, &token, preferences(&body))
            .await
            .0,
        StatusCode::OK
    );
    let mut tx = owner.begin(&state.pool).await.unwrap();
    let removed: bool = sqlx::query_scalar("SELECT encrypted_sender_policy IS NULL FROM push_preferences WHERE device_id=$1 AND account_id=$2")
        .bind(device).bind(account).fetch_one(&mut *tx).await.unwrap();
    tx.commit().await.unwrap();
    assert!(removed);
    let legacy = message(
        state,
        &owner,
        account,
        Utc::now(),
        "inbox",
        false,
        "unknown@example.test",
    )
    .await;
    drain(state, service).await;
    assert_eq!(
        job_status(state, &owner, legacy).await.as_deref(),
        Some("accepted")
    );

    // Re-enabling via PATCH uses the same consent cutoffs as registration and
    // cannot alert for messages received before device or account re-enable.
    for device_toggle in [true, false] {
        let before_enable = Utc::now();
        let queued = message(
            state,
            &owner,
            account,
            before_enable,
            "inbox",
            false,
            "unknown@example.test",
        )
        .await;
        if device_toggle {
            body["enabled"] = json!(false);
        } else {
            body["accounts"][0]["enabled"] = json!(false);
        }
        assert_eq!(
            request(app, "PATCH", installation, &token, preferences(&body))
                .await
                .0,
            StatusCode::OK
        );
        if device_toggle {
            body["enabled"] = json!(true);
        } else {
            body["accounts"][0]["enabled"] = json!(true);
        }
        assert_eq!(
            request(app, "PATCH", installation, &token, preferences(&body))
                .await
                .0,
            StatusCode::OK
        );
        let old = message(
            state,
            &owner,
            account,
            before_enable,
            "inbox",
            false,
            "unknown@example.test",
        )
        .await;
        assert_eq!(job_status(state, &owner, old).await, None);
        drain(state, service).await;
        assert_eq!(
            job_status(state, &owner, queued).await.as_deref(),
            Some("cancelled")
        );
        let fresh = message(
            state,
            &owner,
            account,
            Utc::now(),
            "inbox",
            false,
            "unknown@example.test",
        )
        .await;
        drain(state, service).await;
        assert_eq!(
            job_status(state, &owner, fresh).await.as_deref(),
            Some("accepted")
        );
    }
    // A token moved to another workspace can only be reclaimed by a fresh
    // registration carrying that token. PATCH must not change its binding.
    assert_eq!(
        request(
            app,
            "PUT",
            Uuid::new_v4(),
            &other_token,
            registration(foreign, &apple_token, false),
        )
        .await
        .0,
        StatusCode::OK
    );
    assert_eq!(
        request(app, "PATCH", installation, &token, preferences(&body))
            .await
            .0,
        StatusCode::NOT_FOUND
    );
    assert_eq!(
        request(app, "GET", installation, &token, Value::Null)
            .await
            .1["active"],
        false
    );
    for auth in [&owner, &other] {
        sqlx::query("DELETE FROM workspaces WHERE id=$1")
            .bind(auth.workspace_id)
            .execute(&state.pool)
            .await
            .unwrap();
        sqlx::query("DELETE FROM users WHERE id=$1")
            .bind(auth.user_id)
            .execute(&state.pool)
            .await
            .unwrap();
    }
}
