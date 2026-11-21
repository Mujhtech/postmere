mod common;
use axum::{
    Extension, Router,
    body::Body,
    http::{Request, StatusCode},
};
use base64::{Engine, engine::general_purpose::URL_SAFE_NO_PAD};
use chrono::{Duration, Utc};
use http_body_util::BodyExt;
use postmere_core::{AppState, auth::AuthContext, db, error::AppError};
use postmere_mail::{
    mail,
    mail_sync::{self, SyncTransport},
};
use postmere_providers::{Credentials, Provider, SyncBatch, SyncCheckpoint};
use postmere_server::application;
use postmere_webhooks::{
    GmailConfig, GoogleKey, Subscription, SubscriptionRequest, SubscriptionTransport,
    TransportFuture, WebhookService, process_one, verify_google_jwt,
};
use serde_json::{Value, json};
use sha2::{Digest, Sha256};
use sqlx::Row;
use std::sync::{
    Arc, Mutex,
    atomic::{AtomicBool, Ordering},
};
use tokio::sync::Notify;
use tower::ServiceExt;
use uuid::Uuid;

fn gmail_config() -> GmailConfig {
    GmailConfig {
        topic: "projects/fixture/topics/mail".into(),
        subscription: "projects/fixture/subscriptions/mail".into(),
        audience: "https://postmere.example.test/v1/webhooks/gmail".into(),
        service_account: "push@fixture.iam.gserviceaccount.com".into(),
    }
}
fn google_key() -> GoogleKey {
    // This public fixture key has no connection to Google or any live account.
    let modulus = "8CADAC0B2A37404C7F4B2E90B70EE80D959767982273EF7865627DE76C967E05F3F277BA4FFC7C17F75DADBCB10CEED2461762DD8947A2303BB786D323092B63FF1164428C8E9060B0F8DDA9537B23247AD3323CBEA2883515407486DE056EE732C73A16DA716B9F92281962DC42874884B8AF1C3A3C9FCA70E05A6FCC2627061988449DC5292AD505921303A31594848B853B279BFE6D97E0510BFC2C16FA50449DA37C4DC07E9CFF7C90876A5405436D1CE6DB172D6681959EAC6045EF413173BBEC957821933D973A8CF5CD74FA7E2EB3252EB03D959E784102C647BC7E1F89D79CCE462AFCC4ABC8C11A9C3307FC3DA53C483843938F87E54CB732794CAF";
    let bytes: Vec<u8> = (0..modulus.len())
        .step_by(2)
        .map(|i| u8::from_str_radix(&modulus[i..i + 2], 16).unwrap())
        .collect();
    GoogleKey {
        kid: "fixture".into(),
        kty: "RSA".into(),
        alg: "RS256".into(),
        usage: "sig".into(),
        n: URL_SAFE_NO_PAD.encode(bytes),
        e: "AQAB".into(),
    }
}
fn claims() -> Value {
    let config = gmail_config();
    let now = Utc::now().timestamp();
    json!({"iss":"https://accounts.google.com","aud":config.audience,"email":config.service_account,"email_verified":true,"sub":"12345678","iat":now-10,"exp":now+3500})
}
fn jwt(value: Value) -> String {
    let key =
        ring::signature::RsaKeyPair::from_pkcs8(include_bytes!("fixtures/webhook-test-rsa.der"))
            .unwrap();
    let signed = format!(
        "{}.{}",
        URL_SAFE_NO_PAD.encode(br#"{"alg":"RS256","kid":"fixture"}"#),
        URL_SAFE_NO_PAD.encode(serde_json::to_vec(&value).unwrap())
    );
    let mut signature = vec![0; key.public().modulus_len()];
    key.sign(
        &ring::signature::RSA_PKCS1_SHA256,
        &ring::rand::SystemRandom::new(),
        signed.as_bytes(),
        &mut signature,
    )
    .unwrap();
    format!("{signed}.{}", URL_SAFE_NO_PAD.encode(signature))
}
#[test]
fn pubsub_jwt_requires_signature_audience_verified_service_identity_and_valid_time() {
    let config = gmail_config();
    let keys = [google_key()];
    let now = Utc::now().timestamp();
    assert!(verify_google_jwt(&jwt(claims()), &config, &keys, now).is_ok());
    for (field, value) in [
        ("iss", json!("https://attacker.test")),
        ("aud", json!("https://other.test")),
        ("email", json!("other@fixture.iam.gserviceaccount.com")),
        ("email_verified", json!(false)),
        ("iat", json!(now + 60)),
        ("exp", json!(now - 1)),
        ("exp", json!(now + 7200)),
        ("sub", json!("")),
    ] {
        let mut payload = claims();
        payload[field] = value;
        assert!(
            verify_google_jwt(&jwt(payload), &config, &keys, now).is_err(),
            "{field}"
        );
    }
    let valid = jwt(claims());
    let mut parts: Vec<_> = valid.split('.').map(str::to_owned).collect();
    parts[1] = URL_SAFE_NO_PAD.encode(serde_json::to_vec(&json!({"email":"forged"})).unwrap());
    assert!(verify_google_jwt(&parts.join("."), &config, &keys, now).is_err());
    assert!(verify_google_jwt(&format!("{valid}.extra"), &config, &keys, now).is_err());
    parts[0] = URL_SAFE_NO_PAD.encode(br#"{"alg":"none","kid":"fixture"}"#);
    assert!(verify_google_jwt(&parts.join("."), &config, &keys, now).is_err());
}

#[derive(Default)]
struct FakeSubscriptions {
    ensured: Mutex<Vec<(Provider, Option<String>)>>,
    removed: Mutex<Vec<Provider>>,
    fail: AtomicBool,
}
impl SubscriptionTransport for FakeSubscriptions {
    fn ensure<'a>(
        &'a self,
        _: &'a AppState,
        request: &'a SubscriptionRequest,
    ) -> TransportFuture<'a, Subscription> {
        Box::pin(async move {
            assert!(
                request
                    .callback
                    .starts_with("https://postmere.example.test/")
            );
            assert_eq!(request.client_state.len(), 43);
            self.ensured
                .lock()
                .unwrap()
                .push((request.provider, request.subscription_id.clone()));
            if self.fail.load(Ordering::SeqCst) {
                return Err(AppError::unavailable());
            }
            Ok(Subscription {
                id: if request.provider == Provider::Microsoft {
                    Some(
                        request
                            .subscription_id
                            .clone()
                            .unwrap_or_else(|| Uuid::new_v4().to_string()),
                    )
                } else {
                    None
                },
                expires_at: Utc::now() + Duration::days(2),
            })
        })
    }
    fn remove<'a>(
        &'a self,
        _: &'a AppState,
        request: &'a SubscriptionRequest,
    ) -> TransportFuture<'a, ()> {
        Box::pin(async move {
            self.removed.lock().unwrap().push(request.provider);
            Ok(())
        })
    }
}
async fn identity(state: &AppState) -> AuthContext {
    let user = Uuid::new_v4();
    let workspace = Uuid::new_v4();
    sqlx::query("INSERT INTO users(id,email,password_hash) VALUES($1,$2,'fixture')")
        .bind(user)
        .bind(format!("{user}@fixture.test"))
        .execute(&state.pool)
        .await
        .unwrap();
    sqlx::query("INSERT INTO workspaces(id,name) VALUES($1,'Webhook fixture')")
        .bind(workspace)
        .execute(&state.pool)
        .await
        .unwrap();
    sqlx::query("INSERT INTO memberships(workspace_id,user_id,role) VALUES($1,$2,'owner')")
        .bind(workspace)
        .bind(user)
        .execute(&state.pool)
        .await
        .unwrap();
    let session_id = Uuid::new_v4();
    sqlx::query("INSERT INTO sessions(id,workspace_id,user_id,token_hash,expires_at,absolute_expires_at) VALUES($1,$2,$3,$4,NULL,NULL)")
        .bind(session_id).bind(workspace).bind(user).bind(Sha256::digest(session_id.as_bytes()).as_slice()).execute(&state.pool).await.unwrap();
    AuthContext {
        assistant: false,
        workspace_id: workspace,
        user_id: user,
        session_id,
        role: "owner".into(),
    }
}
async fn account(state: &AppState, auth: &AuthContext, provider: Provider, email: &str) -> Uuid {
    let id = Uuid::new_v4();
    let credentials = Credentials {
        access_token: "fixture-token".into(),
        refresh_token: Some("fixture-refresh".into()),
        expires_at: Utc::now() + Duration::days(3),
        scopes: vec![],
    };
    let encrypted = state
        .crypto
        .seal(
            auth.workspace_id,
            id,
            &serde_json::to_vec(&credentials).unwrap(),
        )
        .unwrap();
    let mut tx = auth.begin(&state.pool).await.unwrap();
    sqlx::query("INSERT INTO provider_accounts(id,workspace_id,user_id,provider,email,encrypted_credentials) VALUES($1,$2,$3,$4,$5,$6)")
        .bind(id).bind(auth.workspace_id).bind(auth.user_id).bind(provider.as_str()).bind(email).bind(encrypted).execute(&mut *tx).await.unwrap();
    mail_sync::schedule_account(&mut tx, auth.workspace_id, auth.user_id, id)
        .await
        .unwrap();
    tx.commit().await.unwrap();
    id
}
async fn post(app: &Router, path: &str, token: Option<&str>, body: Value) -> (StatusCode, String) {
    let mut req = Request::builder()
        .method("POST")
        .uri(path)
        .header("content-type", "application/json");
    if let Some(token) = token {
        req = req.header("authorization", format!("Bearer {token}"));
    }
    let response = app
        .clone()
        .oneshot(req.body(Body::from(body.to_string())).unwrap())
        .await
        .unwrap();
    let status = response.status();
    let bytes = response.into_body().collect().await.unwrap().to_bytes();
    (status, String::from_utf8(bytes.to_vec()).unwrap())
}
fn gmail_hint(email: &str, history: u64) -> Value {
    json!({"subscription":gmail_config().subscription,"message":{"messageId":history.to_string(),"publishTime":Utc::now(),"data":URL_SAFE_NO_PAD.encode(serde_json::to_vec(&json!({"emailAddress":email,"historyId":history.to_string()})).unwrap())}})
}
async fn signal_generation(state: &AppState, account: Uuid) -> Option<i64> {
    sqlx::query_scalar("SELECT generation FROM mail_sync_signals WHERE account_id=$1")
        .bind(account)
        .fetch_optional(&state.pool)
        .await
        .unwrap()
}
async fn graph_state(state: &AppState, account: Uuid) -> (Uuid, String, String) {
    let row=sqlx::query("SELECT id,workspace_id,provider_subscription,encrypted_state FROM provider_webhooks WHERE account_id=$1").bind(account).fetch_one(&state.pool).await.unwrap();
    let id: Uuid = row.get("id");
    let bytes = state
        .crypto
        .open(
            row.get("workspace_id"),
            id,
            &row.get::<Vec<u8>, _>("encrypted_state"),
        )
        .unwrap();
    (
        id,
        row.get("provider_subscription"),
        String::from_utf8(bytes.to_vec()).unwrap(),
    )
}
fn graph_hint(subscription: &str, secret: &str, event: &str) -> Value {
    let mut hint =
        json!({"subscriptionId":subscription,"clientState":secret,"id":Uuid::new_v4().to_string()});
    if matches!(event, "created" | "updated" | "deleted") {
        hint["changeType"] = json!(event);
        hint["resource"] = json!("users/untrusted-payload-user/messages/hint-only");
    } else {
        hint["lifecycleEvent"] = json!(event);
    }
    json!({"value":[hint]})
}
struct PausedSync {
    entered: Notify,
    release: Notify,
}
impl SyncTransport for PausedSync {
    fn fetch<'a>(
        &'a self,
        _: &'a AppState,
        _: &'a mail::AccountSession,
        checkpoint: SyncCheckpoint,
        _: &'a [String],
    ) -> std::pin::Pin<Box<dyn std::future::Future<Output = Result<SyncBatch, AppError>> + Send + 'a>>
    {
        Box::pin(async move {
            self.entered.notify_one();
            self.release.notified().await;
            Ok(SyncBatch {
                messages: vec![],
                deleted_ids: vec![],
                checkpoint,
                has_more: false,
            })
        })
    }
}
struct EmptySync;
impl SyncTransport for EmptySync {
    fn fetch<'a>(
        &'a self,
        _: &'a AppState,
        _: &'a mail::AccountSession,
        checkpoint: SyncCheckpoint,
        _: &'a [String],
    ) -> std::pin::Pin<Box<dyn std::future::Future<Output = Result<SyncBatch, AppError>> + Send + 'a>>
    {
        Box::pin(async move {
            Ok(SyncBatch {
                messages: vec![],
                deleted_ids: vec![],
                checkpoint,
                has_more: false,
            })
        })
    }
}

#[tokio::test]
async fn authenticated_callbacks_renewal_revocation_and_sync_hint_races() {
    let _ = tracing_subscriber::fmt()
        .with_max_level(tracing::Level::ERROR)
        .try_init();
    let url =
        std::env::var("POSTMERE_TEST_DATABASE_URL").expect("isolated non-bypass test DB required");
    let base = db::connect(&url).await.unwrap();
    // Background queues are global by design; isolate this fixture's schema so
    // unrelated integration tests cannot become worker input.
    let schema = format!("webhook_fixture_{}", Uuid::new_v4().simple());
    sqlx::query(sqlx::AssertSqlSafe(format!("CREATE SCHEMA {schema}")))
        .execute(&base)
        .await
        .unwrap();
    let connection_schema = schema.clone();
    let pool = sqlx::postgres::PgPoolOptions::new()
        .max_connections(20)
        .after_connect(move |connection, _| {
            let schema = connection_schema.clone();
            Box::pin(async move {
                sqlx::query("SELECT set_config('search_path',$1,false)")
                    .bind(schema)
                    .execute(connection)
                    .await?;
                Ok(())
            })
        })
        .connect(&url)
        .await
        .unwrap();
    db::migrate(&pool).await.unwrap();
    let mut config = common::config(url);
    config.public_base_url = "https://postmere.example.test".parse().unwrap();
    let state = AppState::new(pool, config).await.unwrap();
    let owner = identity(&state).await;
    let peer = identity(&state).await;
    let mailbox = format!("{}@example.test", Uuid::new_v4());
    let gmail = account(&state, &owner, Provider::Gmail, &mailbox).await;
    let gmail_peer = account(&state, &peer, Provider::Gmail, &mailbox).await;
    let graph = account(&state, &owner, Provider::Microsoft, "graph@example.test").await;
    let fake = Arc::new(FakeSubscriptions::default());
    let service = Arc::new(
        WebhookService::with_transport(&state, Some(gmail_config()), true, fake.clone()).unwrap(),
    );
    service.set_test_google_keys(vec![google_key()]).await;
    let app =
        application(state.clone(), postmere_webhooks::router()).layer(Extension(service.clone()));
    for _ in 0..3 {
        assert!(process_one(&state, &service).await.unwrap());
    }
    assert!(!process_one(&state, &service).await.unwrap());
    assert_eq!(fake.ensured.lock().unwrap().len(), 3);
    sqlx::query("DELETE FROM mail_sync_signals WHERE account_id=ANY($1)")
        .bind(vec![gmail, gmail_peer, graph])
        .execute(&state.pool)
        .await
        .unwrap();
    let (route, subscription, secret) = graph_state(&state, graph).await;
    let path = format!("/v1/webhooks/microsoft/{route}");
    assert_eq!(
        post(
            &app,
            &format!("{path}?validationToken=plain%20challenge"),
            None,
            Value::Null
        )
        .await,
        (StatusCode::OK, "plain challenge".into())
    );
    assert_eq!(
        post(
            &app,
            &path,
            None,
            graph_hint(&subscription, "wrong", "created")
        )
        .await
        .0,
        StatusCode::ACCEPTED
    );
    assert!(signal_generation(&state, graph).await.is_none());
    let valid = graph_hint(&subscription, &secret, "created");
    assert_eq!(
        post(&app, &path, None, valid.clone()).await.0,
        StatusCode::ACCEPTED
    );
    assert_eq!(signal_generation(&state, graph).await, Some(1));
    post(&app, &path, None, valid).await;
    assert_eq!(signal_generation(&state, graph).await, Some(1));
    let token = jwt(claims());
    assert_eq!(
        post(&app, "/v1/webhooks/gmail", None, gmail_hint(&mailbox, 100))
            .await
            .0,
        StatusCode::UNAUTHORIZED
    );
    let mut wrong = claims();
    wrong["aud"] = json!("https://wrong.test");
    assert_eq!(
        post(
            &app,
            "/v1/webhooks/gmail",
            Some(&jwt(wrong)),
            gmail_hint(&mailbox, 100)
        )
        .await
        .0,
        StatusCode::UNAUTHORIZED
    );
    assert_eq!(
        post(
            &app,
            "/v1/webhooks/gmail",
            Some(&token),
            gmail_hint(&mailbox, 100)
        )
        .await
        .0,
        StatusCode::NO_CONTENT
    );
    assert_eq!(signal_generation(&state, gmail).await, Some(1));
    assert_eq!(signal_generation(&state, gmail_peer).await, Some(1));
    post(
        &app,
        "/v1/webhooks/gmail",
        Some(&token),
        gmail_hint(&mailbox, 99),
    )
    .await;
    post(
        &app,
        "/v1/webhooks/gmail",
        Some(&token),
        gmail_hint(&mailbox, 100),
    )
    .await;
    assert_eq!(signal_generation(&state, gmail).await, Some(1));
    let mut stale = gmail_hint(&mailbox, 1000);
    stale["message"]["publishTime"] = json!(Utc::now() - Duration::days(2));
    post(&app, "/v1/webhooks/gmail", Some(&token), stale).await;
    assert_eq!(signal_generation(&state, gmail).await, Some(1));
    let mut tx = owner.begin(&state.pool).await.unwrap();
    let checkpoint: Value =
        sqlx::query_scalar("SELECT checkpoint FROM mail_sync_state WHERE account_id=$1")
            .bind(gmail)
            .fetch_one(&mut *tx)
            .await
            .unwrap();
    assert_eq!(
        checkpoint,
        json!({}),
        "notifications never advance the authoritative provider checkpoint"
    );
    tx.commit().await.unwrap();

    post(
        &app,
        &path,
        None,
        graph_hint(&subscription, &secret, "reauthorizationRequired"),
    )
    .await;
    assert!(process_one(&state, &service).await.unwrap());
    assert_eq!(
        graph_state(&state, graph).await.1,
        subscription,
        "reauthorization renews the same subscription"
    );
    post(
        &app,
        &path,
        None,
        graph_hint(&subscription, &secret, "subscriptionRemoved"),
    )
    .await;
    assert!(process_one(&state, &service).await.unwrap());
    let (_, replacement, new_secret) = graph_state(&state, graph).await;
    assert_ne!(replacement, subscription);
    let before = signal_generation(&state, graph).await;
    post(
        &app,
        &path,
        None,
        graph_hint(&subscription, &secret, "updated"),
    )
    .await;
    assert_eq!(
        signal_generation(&state, graph).await,
        before,
        "old subscription cannot schedule work after replacement"
    );
    post(
        &app,
        &path,
        None,
        graph_hint(&replacement, &new_secret, "missed"),
    )
    .await;
    assert_eq!(
        signal_generation(&state, graph).await,
        before.map(|v| v + 1)
    );

    let paused = Arc::new(PausedSync {
        entered: Notify::new(),
        release: Notify::new(),
    });
    let run_state = state.clone();
    let run_pause = paused.clone();
    let run_owner = owner.clone();
    let sync = tokio::spawn(async move {
        mail_sync::sync_account_with(
            &run_state,
            run_owner.workspace_id,
            run_owner.user_id,
            gmail,
            run_pause.as_ref(),
        )
        .await
    });
    tokio::time::timeout(std::time::Duration::from_secs(5), paused.entered.notified())
        .await
        .unwrap();
    let hint = tokio::time::timeout(
        std::time::Duration::from_secs(2),
        post(
            &app,
            "/v1/webhooks/gmail",
            Some(&token),
            gmail_hint(&mailbox, 101),
        ),
    )
    .await
    .expect("callbacks must not block on the in-flight provider request");
    assert_eq!(hint.0, StatusCode::NO_CONTENT);
    paused.release.notify_one();
    sync.await.unwrap().unwrap();
    assert_eq!(
        signal_generation(&state, gmail).await,
        Some(2),
        "a hint arriving during sync survives its commit"
    );
    sqlx::query("UPDATE mail_sync_wakeups SET due_at=clock_timestamp()+interval '1 hour' WHERE account_id=ANY($1)").bind(vec![gmail,gmail_peer,graph]).execute(&state.pool).await.unwrap();
    sqlx::query("DELETE FROM mail_sync_signals WHERE account_id=ANY($1)")
        .bind(vec![gmail_peer, graph])
        .execute(&state.pool)
        .await
        .unwrap();
    assert!(
        mail_sync::process_one_sync_with(&state, &EmptySync)
            .await
            .unwrap()
    );
    assert!(
        signal_generation(&state, gmail).await.is_none(),
        "the durable signal wakes a sync despite a future polling deadline"
    );

    let mut tx = owner.begin(&state.pool).await.unwrap();
    mail::disconnect_in_transaction(&mut tx, &owner, gmail)
        .await
        .unwrap();
    tx.commit().await.unwrap();
    assert!(process_one(&state, &service).await.unwrap());
    assert!(
        fake.removed.lock().unwrap().is_empty(),
        "disconnecting one Gmail binding must not stop a peer's mailbox watch"
    );
    post(
        &app,
        "/v1/webhooks/gmail",
        Some(&token),
        gmail_hint(&mailbox, 102),
    )
    .await;
    assert!(signal_generation(&state, gmail).await.is_none());
    assert_eq!(signal_generation(&state, gmail_peer).await, Some(1));
    let mut tx = peer.begin(&state.pool).await.unwrap();
    mail::disconnect_in_transaction(&mut tx, &peer, gmail_peer)
        .await
        .unwrap();
    tx.commit().await.unwrap();
    assert!(process_one(&state, &service).await.unwrap());
    assert_eq!(*fake.removed.lock().unwrap(), vec![Provider::Gmail]);
    sqlx::query("UPDATE memberships SET revoked_at=clock_timestamp() WHERE user_id=$1")
        .bind(owner.user_id)
        .execute(&state.pool)
        .await
        .unwrap();
    let before = signal_generation(&state, graph).await;
    post(
        &app,
        &path,
        None,
        graph_hint(&replacement, &new_secret, "updated"),
    )
    .await;
    assert_eq!(
        signal_generation(&state, graph).await,
        before,
        "membership revocation takes effect before callbacks can queue"
    );
    sqlx::query("UPDATE provider_webhooks SET renew_at=clock_timestamp() WHERE account_id=$1")
        .bind(graph)
        .execute(&state.pool)
        .await
        .unwrap();
    assert!(process_one(&state, &service).await.unwrap());
    assert_eq!(
        *fake.removed.lock().unwrap(),
        vec![Provider::Gmail, Provider::Microsoft]
    );
    sqlx::query("UPDATE memberships SET revoked_at=NULL WHERE user_id=$1")
        .bind(owner.user_id)
        .execute(&state.pool)
        .await
        .unwrap();
    sqlx::query("UPDATE provider_webhooks SET renew_at=clock_timestamp() WHERE account_id=$1")
        .bind(graph)
        .execute(&state.pool)
        .await
        .unwrap();
    fake.fail.store(true, Ordering::SeqCst);
    assert!(process_one(&state, &service).await.is_err());
    let delayed:bool=sqlx::query_scalar("SELECT attempts=1 AND lease_until IS NULL AND renew_at>clock_timestamp() AND last_error='subscription_deferred' FROM provider_webhooks WHERE account_id=$1").bind(graph).fetch_one(&state.pool).await.unwrap();
    assert!(
        delayed,
        "provider failure releases the job with bounded retry backoff"
    );
    let cleanup_pending:bool=sqlx::query_scalar("SELECT expires_at>clock_timestamp() AND provider_subscription IS NULL FROM provider_webhooks WHERE account_id=$1")
        .bind(graph).fetch_one(&state.pool).await.unwrap();
    assert!(
        cleanup_pending,
        "an ambiguous initial creation retains a cancellation horizon before receiving its provider ID"
    );
    let mut tx = owner.begin(&state.pool).await.unwrap();
    mail::disconnect_in_transaction(&mut tx, &owner, graph)
        .await
        .unwrap();
    tx.commit().await.unwrap();
    let ensures = fake.ensured.lock().unwrap().len();
    assert!(process_one(&state, &service).await.unwrap());
    assert_eq!(
        fake.ensured.lock().unwrap().len(),
        ensures,
        "disconnect only cancels an uncertain subscription, never renews it"
    );
    assert_eq!(
        *fake.removed.lock().unwrap(),
        vec![Provider::Gmail, Provider::Microsoft, Provider::Microsoft]
    );
    for auth in [owner, peer] {
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
    state.pool.close().await;
    // Only this test-generated UUID schema is removed.
    sqlx::query(sqlx::AssertSqlSafe(format!("DROP SCHEMA {schema} CASCADE")))
        .execute(&base)
        .await
        .unwrap();
}
