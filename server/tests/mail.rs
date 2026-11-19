mod common;
use axum::{
    Router,
    body::Body,
    http::{Request, StatusCode},
};
use base64::{Engine, engine::general_purpose::URL_SAFE_NO_PAD};
use chrono::{Duration, Utc};
use http_body_util::BodyExt;
use postmere_core::AppState;
use postmere_core::auth::{AuthContext, SessionResponse, hash_password};
use postmere_core::db;
use postmere_mail::mail::{self, DeliveryTransport};
use postmere_mail::mail_sync::{self, SyncTransport};
use postmere_providers::{
    self as provider, Credentials, Outgoing, Provider, ProviderError, SyncBatch, SyncCheckpoint,
};
use postmere_server::application;
use postmere_tracking as tracking;
use serde_json::{Value, json};
use sha2::{Digest, Sha256};
use sqlx::{PgPool, Row};
use std::sync::{
    Mutex,
    atomic::{AtomicUsize, Ordering},
};
use tower::ServiceExt;
use uuid::Uuid;
use zeroize::Zeroizing;

async fn raw(
    app: &Router,
    method: &str,
    path: &str,
    token: Option<&str>,
    body: Value,
) -> (StatusCode, axum::http::HeaderMap, Vec<u8>) {
    let mut request = Request::builder()
        .method(method)
        .uri(path)
        .header("content-type", "application/json")
        .header("user-agent", "Postmere fixture Mac OS");
    if let Some(token) = token {
        request = request.header("authorization", format!("Bearer {token}"))
    }
    let response = app
        .clone()
        .oneshot(request.body(Body::from(body.to_string())).unwrap())
        .await
        .unwrap();
    let status = response.status();
    let headers = response.headers().clone();
    let bytes = response
        .into_body()
        .collect()
        .await
        .unwrap()
        .to_bytes()
        .to_vec();
    (status, headers, bytes)
}
async fn request(
    app: &Router,
    method: &str,
    path: &str,
    token: Option<&str>,
    body: Value,
) -> (StatusCode, Value) {
    let (status, _, bytes) = raw(app, method, path, token, body).await;
    (
        status,
        serde_json::from_slice(&bytes).unwrap_or(Value::Null),
    )
}
async fn seed(pool: &PgPool, workspace: Uuid, email: &str, hash: &str) -> Uuid {
    let user = Uuid::new_v4();
    sqlx::query("INSERT INTO users(id,email,password_hash) VALUES($1,$2,$3)")
        .bind(user)
        .bind(email)
        .bind(hash)
        .execute(pool)
        .await
        .unwrap();
    sqlx::query("INSERT INTO workspaces(id,name) VALUES($1,'Mail fixture') ON CONFLICT DO NOTHING")
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
    user
}
async fn login(app: &Router, email: &str, workspace: Uuid) -> SessionResponse {
    let(status,body)=request(app,"POST","/v1/auth/login",None,json!({"email":email,"password":"mail fixture password long enough","workspace_id":workspace})).await;
    assert_eq!(status, StatusCode::OK, "{body}");
    serde_json::from_value(body).unwrap()
}
async fn seed_account(state: &AppState, auth: &AuthContext, email: &str) -> Uuid {
    let id = Uuid::new_v4();
    let credentials = Credentials {
        access_token: "fixture-never-sent-to-network".into(),
        refresh_token: Some("fixture-refresh".into()),
        expires_at: Utc::now() + Duration::days(1),
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
    sqlx::query("INSERT INTO provider_accounts(id,workspace_id,user_id,provider,email,encrypted_credentials) VALUES($1,$2,$3,'gmail',$4,$5)").bind(id).bind(auth.workspace_id).bind(auth.user_id).bind(email).bind(encrypted).execute(&mut *tx).await.unwrap();
    tx.commit().await.unwrap();
    id
}
fn outgoing(account: Uuid) -> Value {
    json!({"client_id":Uuid::new_v4(),"account_id":account,"to":[{"name":"Reader","email":"reader@example.com"}],"cc":[],"bcc":[],"subject":"Mail worker fixture","text_body":"Hello","html_body":"<p>Hello <a href=\"https://example.com/visit?a=1&amp;b=2\">link</a></p>","attachments":[],"undo_seconds":10,"track_opens":false,"track_links":false})
}
async fn queue(app: &Router, token: &str, body: Value) -> Uuid {
    let (status, response) = request(app, "POST", "/v1/mail/outbox", Some(token), body).await;
    assert_eq!(status, StatusCode::OK, "{response}");
    serde_json::from_value(response["id"].clone()).unwrap()
}
async fn due(state: &AppState, auth: &AuthContext, id: Uuid) {
    let mut tx = auth.begin(&state.pool).await.unwrap();
    sqlx::query("UPDATE mail_outbox SET undo_until=now()-interval '1 minute',scheduled_at=now()-interval '1 minute' WHERE id=$1").bind(id).execute(&mut *tx).await.unwrap();
    sqlx::query("UPDATE mail_delivery_wakeups SET due_at=now()-interval '1 minute',lease_until=NULL WHERE job_id=$1").bind(id).execute(&mut *tx).await.unwrap();
    tx.commit().await.unwrap()
}
async fn status(state: &AppState, auth: &AuthContext, id: Uuid) -> String {
    let mut tx = auth.begin(&state.pool).await.unwrap();
    sqlx::query_scalar("SELECT status FROM mail_outbox WHERE id=$1")
        .bind(id)
        .fetch_one(&mut *tx)
        .await
        .unwrap()
}

struct FixtureDelivery {
    result: Result<Option<String>, ProviderError>,
    calls: AtomicUsize,
    messages: Mutex<Vec<Outgoing>>,
}
impl FixtureDelivery {
    fn new(result: Result<Option<String>, ProviderError>) -> Self {
        Self {
            result,
            calls: AtomicUsize::new(0),
            messages: Mutex::new(vec![]),
        }
    }
}
impl DeliveryTransport for FixtureDelivery {
    fn send<'a>(
        &'a self,
        _: &'a AppState,
        _: Provider,
        _: &'a str,
        _: &'a str,
        message: &'a Outgoing,
    ) -> std::pin::Pin<
        Box<dyn std::future::Future<Output = Result<Option<String>, ProviderError>> + Send + 'a>,
    > {
        Box::pin(async move {
            self.calls.fetch_add(1, Ordering::SeqCst);
            self.messages.lock().unwrap().push(message.clone());
            self.result.clone()
        })
    }
}
struct FixtureSync {
    batches: Mutex<std::collections::VecDeque<SyncBatch>>,
    seen: Mutex<Vec<SyncCheckpoint>>,
    calls: AtomicUsize,
}
impl FixtureSync {
    fn new(batches: Vec<SyncBatch>) -> Self {
        Self {
            batches: Mutex::new(batches.into()),
            seen: Mutex::new(vec![]),
            calls: AtomicUsize::new(0),
        }
    }
}
impl SyncTransport for FixtureSync {
    fn fetch<'a>(
        &'a self,
        _: &'a AppState,
        _: &'a mail::AccountSession,
        checkpoint: SyncCheckpoint,
        _: &'a [String],
    ) -> std::pin::Pin<
        Box<
            dyn std::future::Future<Output = Result<SyncBatch, postmere_core::error::AppError>>
                + Send
                + 'a,
        >,
    > {
        Box::pin(async move {
            self.calls.fetch_add(1, Ordering::SeqCst);
            self.seen.lock().unwrap().push(checkpoint);
            Ok(self
                .batches
                .lock()
                .unwrap()
                .pop_front()
                .expect("fixture sync batch"))
        })
    }
}

#[tokio::test]
async fn mail_scope_oauth_idempotency_worker_and_tracking_without_live_network() {
    let url = std::env::var("POSTMERE_TEST_DATABASE_URL")
        .expect("Set the isolated non-bypass PostgreSQL test database URL");
    let pool = db::connect(&url).await.unwrap();
    db::migrate(&pool).await.unwrap();
    let mut config = common::config(url);
    config.google_client_id = Some("fixture-client".into());
    config.google_client_secret = Some("fixture-secret".into());
    let state = AppState::new(pool.clone(), config).await.unwrap();
    let app = application(state.clone(), mail::router().merge(tracking::router()));
    let workspace = Uuid::new_v4();
    let foreign = Uuid::new_v4();
    let email = format!("mail-{}@example.test", Uuid::new_v4());
    let peer_email = format!("mail-{}@example.test", Uuid::new_v4());
    let outsider_email = format!("mail-{}@example.test", Uuid::new_v4());
    let hash = hash_password(Zeroizing::new("mail fixture password long enough".into()))
        .await
        .unwrap();
    let user = seed(&pool, workspace, &email, &hash).await;
    let peer = seed(&pool, workspace, &peer_email, &hash).await;
    let outsider = seed(&pool, foreign, &outsider_email, &hash).await;
    let session = login(&app, &email, workspace).await;
    let peer_session = login(&app, &peer_email, workspace).await;
    let outside_session = login(&app, &outsider_email, foreign).await;
    let auth = state.auth.authenticate(&session.token).await.unwrap();
    let peer_auth = state.auth.authenticate(&peer_session.token).await.unwrap();
    let account = seed_account(&state, &auth, "owner@gmail.example").await;
    let peer_account = seed_account(&state, &peer_auth, "peer@gmail.example").await;
    let listed = request(
        &app,
        "GET",
        "/v1/mail/accounts",
        Some(&session.token),
        Value::Null,
    )
    .await;
    assert_eq!(listed.1.as_array().unwrap().len(), 1);
    assert_eq!(listed.1[0]["id"], json!(account));
    assert!(!listed.1.to_string().contains("fixture-never"));
    assert_eq!(
        request(&app, "GET", "/v1/mail/accounts", None, Value::Null)
            .await
            .0,
        StatusCode::UNAUTHORIZED
    );

    let fixture = json!({"id":"provider-fixture","threadId":"thread-fixture","internalDate":"1730610000000","snippet":"Scoped message","labelIds":["INBOX"],"payload":{"mimeType":"multipart/mixed","headers":[{"name":"Subject","value":"Scope fixture"},{"name":"From","value":"pat@example.com"}],"parts":[{"partId":"0","mimeType":"text/plain","body":{"data":URL_SAFE_NO_PAD.encode("Private body")}},{"partId":"1","mimeType":"text/plain","filename":"note.txt","body":{"data":URL_SAFE_NO_PAD.encode("private attachment"),"size":18}}]}});
    let message = provider::normalize_gmail(account, &fixture).unwrap();
    let mut tx = auth.begin(&pool).await.unwrap();
    sqlx::query("INSERT INTO mail_messages(id,workspace_id,user_id,account_id,provider_message_id,provider_thread_id,sent_at,normalized,search_text) VALUES($1,$2,$3,$4,$5,$6,$7,$8,'Scope fixture Private body')").bind(message.id).bind(workspace).bind(user).bind(account).bind(&message.provider_message_id).bind(&message.provider_thread_id).bind(message.sent_at).bind(serde_json::to_value(&message).unwrap()).execute(&mut *tx).await.unwrap();
    tx.commit().await.unwrap();
    let message_path = format!("/v1/mail/messages/{}", message.id);
    assert_eq!(
        request(
            &app,
            "GET",
            &message_path,
            Some(&session.token),
            Value::Null
        )
        .await
        .0,
        StatusCode::OK
    );
    let envelope_path = format!("{message_path}?view=envelope");
    let (envelope_status, envelope) = request(
        &app,
        "GET",
        &envelope_path,
        Some(&session.token),
        Value::Null,
    )
    .await;
    assert_eq!(envelope_status, StatusCode::OK);
    assert_eq!(envelope["account_id"], account.to_string());
    assert_eq!(envelope["id"], message.id.to_string());
    assert!(envelope["to"].is_array());
    assert!(envelope.get("html_body").is_none() && envelope.get("text_body").is_none());
    for other in [&peer_session.token, &outside_session.token] {
        assert_eq!(
            request(&app, "GET", &envelope_path, Some(other), Value::Null)
                .await
                .0,
            StatusCode::NOT_FOUND
        );
        assert_eq!(
            request(&app, "GET", &message_path, Some(other), Value::Null)
                .await
                .0,
            StatusCode::NOT_FOUND
        );
        assert!(
            request(
                &app,
                "GET",
                &format!("/v1/mail/messages?account_id={account}"),
                Some(other),
                Value::Null
            )
            .await
            .1["messages"]
                .as_array()
                .unwrap()
                .is_empty()
        );
    }
    let attachment_path = format!("{message_path}/attachments/{}", message.attachments[0].id);
    let download = raw(
        &app,
        "GET",
        &attachment_path,
        Some(&session.token),
        Value::Null,
    )
    .await;
    assert_eq!(download.0, StatusCode::OK);
    assert_eq!(download.2, b"private attachment");
    assert_eq!(
        request(
            &app,
            "GET",
            &attachment_path,
            Some(&peer_session.token),
            Value::Null
        )
        .await
        .0,
        StatusCode::NOT_FOUND
    );
    let mut peer_tx = peer_auth.begin(&pool).await.unwrap();
    let malicious=sqlx::query("INSERT INTO mail_messages(id,workspace_id,user_id,account_id,provider_message_id,provider_thread_id,sent_at,normalized,search_text) VALUES($1,$2,$3,$4,'fake','fake',now(),'{}','')").bind(Uuid::new_v4()).bind(workspace).bind(peer).bind(account).execute(&mut *peer_tx).await;
    assert!(
        malicious.is_err(),
        "same-workspace account foreign key must also include its owner"
    );
    peer_tx.rollback().await.unwrap();

    let start = request(
        &app,
        "POST",
        "/v1/mail/oauth/gmail/start",
        Some(&session.token),
        json!({}),
    )
    .await;
    assert_eq!(start.0, StatusCode::OK);
    let connection: Uuid = serde_json::from_value(start.1["connection_id"].clone()).unwrap();
    let authorization = url::Url::parse(start.1["authorization_url"].as_str().unwrap()).unwrap();
    let params: std::collections::HashMap<_, _> =
        authorization.query_pairs().into_owned().collect();
    let token = &params["state"];
    assert_eq!(params["code_challenge_method"], "S256");
    assert_eq!(authorization.host_str(), Some("accounts.google.com"));
    assert!(
        !params["scope"].contains("calendar"),
        "ordinary mail connection cannot request calendar access"
    );
    let calendar = request(
        &app,
        "POST",
        "/v1/mail/oauth/gmail/start",
        Some(&session.token),
        json!({"calendar_access":true}),
    )
    .await;
    let calendar_url = url::Url::parse(calendar.1["authorization_url"].as_str().unwrap()).unwrap();
    assert!(
        calendar_url
            .query_pairs()
            .any(|(k, v)| k == "scope" && v.contains("calendar.events")),
        "calendar grant requires explicit intent"
    );
    let mut tx = auth.begin(&pool).await.unwrap();
    let row =
        sqlx::query("SELECT state_hash,encrypted_verifier FROM mail_oauth_connections WHERE id=$1")
            .bind(connection)
            .fetch_one(&mut *tx)
            .await
            .unwrap();
    let hash: Vec<u8> = row.get("state_hash");
    assert_eq!(hash, postmere_core::tokens::token_hash(token));
    let verifier = state
        .crypto
        .open(
            workspace,
            connection,
            &row.get::<Vec<u8>, _>("encrypted_verifier"),
        )
        .unwrap();
    assert_eq!(
        params["code_challenge"],
        URL_SAFE_NO_PAD.encode(Sha256::digest(&*verifier))
    );
    tx.commit().await.unwrap();
    assert_eq!(
        request(
            &app,
            "GET",
            &format!("/v1/mail/oauth/connections/{connection}"),
            Some(&peer_session.token),
            Value::Null
        )
        .await
        .0,
        StatusCode::NOT_FOUND
    );
    let forged = postmere_core::tokens::scoped_token(workspace, user, connection).unwrap();
    assert_eq!(
        raw(
            &app,
            "GET",
            &format!("/v1/mail/oauth/gmail/callback?state={forged}&error=access_denied"),
            None,
            Value::Null
        )
        .await
        .0,
        StatusCode::NOT_FOUND
    );
    let declined = format!("/v1/mail/oauth/gmail/callback?state={token}&error=access_denied");
    assert_eq!(
        raw(&app, "GET", &declined, None, Value::Null).await.0,
        StatusCode::OK
    );
    assert_eq!(
        raw(&app, "GET", &declined, None, Value::Null).await.0,
        StatusCode::NOT_FOUND,
        "OAuth state is single use"
    );
    assert_eq!(
        request(
            &app,
            "GET",
            &format!("/v1/mail/oauth/connections/{connection}"),
            Some(&session.token),
            Value::Null
        )
        .await
        .1["status"],
        "failed"
    );

    let body = outgoing(account);
    let first = queue(&app, &session.token, body.clone()).await;
    let duplicate = queue(&app, &session.token, body.clone()).await;
    assert_eq!(first, duplicate, "repeated upload uses one durable job");
    let mut changed = body.clone();
    changed["subject"] = json!("Different content");
    assert_eq!(
        request(
            &app,
            "POST",
            "/v1/mail/outbox",
            Some(&session.token),
            changed
        )
        .await
        .0,
        StatusCode::CONFLICT
    );
    assert_eq!(
        request(
            &app,
            "POST",
            "/v1/mail/outbox",
            Some(&peer_session.token),
            outgoing(account)
        )
        .await
        .0,
        StatusCode::NOT_FOUND
    );
    let mut wrong_thread = outgoing(account);
    wrong_thread["provider_thread_id"] = json!("unknown-foreign-thread");
    assert_eq!(
        request(
            &app,
            "POST",
            "/v1/mail/outbox",
            Some(&session.token),
            wrong_thread
        )
        .await
        .0,
        StatusCode::NOT_FOUND
    );
    assert_eq!(
        request(
            &app,
            "POST",
            &format!("/v1/mail/outbox/{first}/cancel"),
            Some(&peer_session.token),
            json!({})
        )
        .await
        .0,
        StatusCode::NOT_FOUND
    );
    assert_eq!(
        request(
            &app,
            "POST",
            &format!("/v1/mail/outbox/{first}/cancel"),
            Some(&session.token),
            json!({})
        )
        .await
        .1["status"],
        "cancelled"
    );
    assert_eq!(
        request(
            &app,
            "POST",
            &format!("/v1/mail/outbox/{first}/retry"),
            Some(&session.token),
            json!({})
        )
        .await
        .0,
        StatusCode::CONFLICT
    );
    let success = FixtureDelivery::new(Ok(Some("provider-sent-fixture".into())));
    assert!(
        !mail::process_one_delivery_with(&state, &success)
            .await
            .unwrap()
    );

    let mut scheduled = outgoing(account);
    scheduled["scheduled_at"] = json!(Utc::now() + Duration::hours(1));
    let scheduled_id = queue(&app, &session.token, scheduled).await;
    assert!(
        !mail::process_one_delivery_with(&state, &success)
            .await
            .unwrap()
    );
    request(
        &app,
        "POST",
        &format!("/v1/mail/outbox/{scheduled_id}/cancel"),
        Some(&session.token),
        json!({}),
    )
    .await;
    let untracked = queue(&app, &session.token, outgoing(account)).await;
    due(&state, &auth, untracked).await;
    assert!(
        mail::process_one_delivery_with(&state, &success)
            .await
            .unwrap()
    );
    assert_eq!(status(&state, &auth, untracked).await, "sent");
    assert_eq!(success.calls.load(Ordering::SeqCst), 1);
    assert!(
        !success.messages.lock().unwrap()[0]
            .html_body
            .as_ref()
            .unwrap()
            .contains("/t/"),
        "tracking is off by default"
    );
    let mut tracked = outgoing(account);
    tracked["track_opens"] = json!(true);
    tracked["track_links"] = json!(true);
    let tracked_id = queue(&app, &session.token, tracked).await;
    due(&state, &auth, tracked_id).await;
    assert!(
        mail::process_one_delivery_with(&state, &success)
            .await
            .unwrap()
    );
    assert_eq!(status(&state, &auth, tracked_id).await, "sent");
    let html = success.messages.lock().unwrap()[1]
        .html_body
        .clone()
        .unwrap();
    let open_url = html
        .split("src=\"")
        .nth(1)
        .unwrap()
        .split('"')
        .next()
        .unwrap();
    let click_url = html
        .split("href=\"")
        .nth(1)
        .unwrap()
        .split('"')
        .next()
        .unwrap();
    let open_path = url::Url::parse(open_url).unwrap().path().to_owned();
    let click_path = url::Url::parse(click_url).unwrap().path().to_owned();
    let pixel = raw(&app, "GET", &open_path, None, Value::Null).await;
    assert_eq!(pixel.0, StatusCode::OK);
    assert_eq!(pixel.1["content-type"], "image/gif");
    let clicked = raw(&app, "GET", &click_path, None, Value::Null).await;
    assert_eq!(clicked.0, StatusCode::FOUND);
    assert_eq!(clicked.1["location"], "https://example.com/visit?a=1&b=2");
    raw(&app, "GET", &open_path, None, Value::Null).await;
    let activity = request(
        &app,
        "GET",
        &format!("/v1/mail/activity?message_id={tracked_id}"),
        Some(&session.token),
        Value::Null,
    )
    .await
    .1;
    assert_eq!(
        activity["items"][0]["opens"], 1,
        "rapid duplicate image probes are coalesced"
    );
    assert_eq!(activity["items"][0]["clicks"], 1);
    assert_eq!(
        activity["items"][0]["events"][0]["recipient"],
        "reader@example.com"
    );
    assert!(
        activity["attribution_notice"]
            .as_str()
            .unwrap()
            .contains("not verified reads")
    );
    assert!(
        request(
            &app,
            "GET",
            &format!("/v1/mail/activity?message_id={tracked_id}"),
            Some(&peer_session.token),
            Value::Null
        )
        .await
        .1["items"]
            .as_array()
            .unwrap()
            .is_empty()
    );

    let ambiguous = FixtureDelivery::new(Err(ProviderError::Ambiguous));
    let uncertain = queue(&app, &session.token, outgoing(account)).await;
    due(&state, &auth, uncertain).await;
    mail::process_one_delivery_with(&state, &ambiguous)
        .await
        .unwrap();
    assert_eq!(status(&state, &auth, uncertain).await, "uncertain");
    assert_eq!(
        request(
            &app,
            "POST",
            &format!("/v1/mail/outbox/{uncertain}/retry"),
            Some(&session.token),
            json!({})
        )
        .await
        .0,
        StatusCode::CONFLICT
    );
    assert!(
        !mail::process_one_delivery_with(&state, &ambiguous)
            .await
            .unwrap()
    );
    assert_eq!(ambiguous.calls.load(Ordering::SeqCst), 1);
    let rejected = FixtureDelivery::new(Err(ProviderError::Rejected));
    let failed = queue(&app, &session.token, outgoing(account)).await;
    due(&state, &auth, failed).await;
    mail::process_one_delivery_with(&state, &rejected)
        .await
        .unwrap();
    assert_eq!(status(&state, &auth, failed).await, "failed");
    assert_eq!(
        request(
            &app,
            "POST",
            &format!("/v1/mail/outbox/{failed}/retry"),
            Some(&session.token),
            json!({})
        )
        .await
        .1["status"],
        "pending"
    );
    due(&state, &auth, failed).await;
    mail::process_one_delivery_with(&state, &success)
        .await
        .unwrap();
    assert_eq!(status(&state, &auth, failed).await, "sent");
    let interrupted = queue(&app, &session.token, outgoing(account)).await;
    due(&state, &auth, interrupted).await;
    let mut tx = auth.begin(&pool).await.unwrap();
    sqlx::query("UPDATE mail_outbox SET status='delivering',claimed_at=now()-interval '10 minutes' WHERE id=$1").bind(interrupted).execute(&mut *tx).await.unwrap();
    tx.commit().await.unwrap();
    let before = success.calls.load(Ordering::SeqCst);
    mail::process_one_delivery_with(&state, &success)
        .await
        .unwrap();
    assert_eq!(status(&state, &auth, interrupted).await, "uncertain");
    assert_eq!(
        success.calls.load(Ordering::SeqCst),
        before,
        "interrupted delivery never sends a second time"
    );
    let mut second = message.clone();
    second.id = Uuid::new_v4();
    second.provider_message_id = "provider-two".into();
    second.subject = "Second cached message".into();
    let mut third = message.clone();
    third.id = Uuid::new_v4();
    third.provider_message_id = "provider-three".into();
    third.subject = "Third cached message".into();
    let originals = vec![message.clone(), second, third];
    let initial_sync = FixtureSync::new(vec![SyncBatch {
        messages: originals.clone(),
        deleted_ids: vec![],
        checkpoint: SyncCheckpoint {
            phase: "history".into(),
            cursor: Some("fixture-next-page".into()),
            ..Default::default()
        },
        has_more: true,
    }]);
    mail_sync::sync_account_with(&state, workspace, user, account, &initial_sync)
        .await
        .unwrap();
    let first_page = mail::cached_changes(&state, &auth, account, None, 1)
        .await
        .unwrap();
    assert!(first_page.has_more);
    assert_eq!(first_page.messages.len(), 1);
    assert!(
        mail::cached_changes(
            &state,
            &peer_auth,
            account,
            Some(&first_page.next_cursor),
            1
        )
        .await
        .is_err(),
        "encrypted cursor is scoped to its user"
    );
    assert!(
        mail::cached_changes(
            &state,
            &auth,
            peer_account,
            Some(&first_page.next_cursor),
            1
        )
        .await
        .is_err(),
        "encrypted cursor is bound to its account"
    );
    let mut tampered = first_page.next_cursor.clone();
    tampered.replace_range(0..1, if &tampered[..1] == "A" { "B" } else { "A" });
    assert!(
        mail::cached_changes(&state, &auth, account, Some(&tampered), 1)
            .await
            .is_err()
    );
    let mut changed = originals
        .iter()
        .find(|m| m.id != first_page.messages[0].id)
        .unwrap()
        .clone();
    changed.subject = "Changed during pagination".into();
    let update_sync = FixtureSync::new(vec![SyncBatch {
        messages: vec![changed.clone()],
        deleted_ids: vec![],
        checkpoint: SyncCheckpoint {
            phase: "history".into(),
            history_id: Some("next-history".into()),
            ..Default::default()
        },
        has_more: false,
    }]);
    mail_sync::sync_account_with(&state, workspace, user, account, &update_sync)
        .await
        .unwrap();
    assert_eq!(
        update_sync.seen.lock().unwrap()[0].cursor.as_deref(),
        Some("fixture-next-page"),
        "provider checkpoint survives service calls"
    );
    let second_page =
        mail::cached_changes(&state, &auth, account, Some(&first_page.next_cursor), 1)
            .await
            .unwrap();
    assert!(
        !second_page.has_more,
        "upper watermark excludes later modifications from the current cycle"
    );
    let following_cycle =
        mail::cached_changes(&state, &auth, account, Some(&second_page.next_cursor), 100)
            .await
            .unwrap();
    assert!(
        following_cycle
            .messages
            .iter()
            .any(|m| m.id == changed.id && m.subject == changed.subject),
        "a row changed mid-page is delivered in the next cycle"
    );
    let empty_cycle = mail::cached_changes(
        &state,
        &auth,
        account,
        Some(&following_cycle.next_cursor),
        100,
    )
    .await
    .unwrap();
    assert!(
        empty_cycle.messages.is_empty()
            && empty_cycle.deleted_message_ids.is_empty()
            && !empty_cycle.next_cursor.is_empty(),
        "empty sync advances a durable opaque cursor"
    );
    let no_deletion = FixtureSync::new(vec![SyncBatch {
        messages: vec![],
        deleted_ids: vec![],
        checkpoint: SyncCheckpoint::default(),
        has_more: false,
    }]);
    mail_sync::sync_account_with(&state, workspace, user, account, &no_deletion)
        .await
        .unwrap();
    assert!(
        mail::cached_message(&state, &auth, changed.id)
            .await
            .is_ok(),
        "an empty provider page does not imply deletion"
    );
    let explicit_deletion = FixtureSync::new(vec![SyncBatch {
        messages: vec![],
        deleted_ids: vec![changed.provider_message_id.clone()],
        checkpoint: SyncCheckpoint::default(),
        has_more: false,
    }]);
    mail_sync::sync_account_with(&state, workspace, user, account, &explicit_deletion)
        .await
        .unwrap();
    let deleted = mail::cached_changes(&state, &auth, account, Some(&empty_cycle.next_cursor), 100)
        .await
        .unwrap();
    assert_eq!(deleted.deleted_message_ids, vec![changed.id]);
    assert!(
        mail::cached_message(&state, &auth, changed.id)
            .await
            .is_err()
    );
    sqlx::query("UPDATE mail_sync_wakeups SET due_at=now()-interval '1 second',lease_until=NULL WHERE account_id=$1").bind(account).execute(&pool).await.unwrap();
    let background = FixtureSync::new(vec![SyncBatch {
        messages: vec![],
        deleted_ids: vec![],
        checkpoint: SyncCheckpoint::default(),
        has_more: false,
    }]);
    assert!(
        mail_sync::process_one_sync_with(&state, &background)
            .await
            .unwrap()
    );
    assert_eq!(
        background.calls.load(Ordering::SeqCst),
        1,
        "worker fetches one account page without an app session"
    );
    let revoked = queue(&app, &peer_session.token, outgoing(peer_account)).await;
    due(&state, &peer_auth, revoked).await;
    let mut tx = peer_auth.begin(&pool).await.unwrap();
    mail_sync::schedule_account(&mut tx, workspace, peer, peer_account)
        .await
        .unwrap();
    tx.commit().await.unwrap();
    sqlx::query("UPDATE memberships SET revoked_at=now() WHERE workspace_id=$1 AND user_id=$2")
        .bind(workspace)
        .bind(peer)
        .execute(&pool)
        .await
        .unwrap();
    mail::process_one_delivery_with(&state, &success)
        .await
        .unwrap();
    assert_eq!(status(&state, &peer_auth, revoked).await, "failed");
    assert_eq!(
        success.calls.load(Ordering::SeqCst),
        before,
        "revoked users cannot deliver background mail"
    );
    assert!(
        mail_sync::process_one_sync_with(&state, &background)
            .await
            .is_err()
    );
    assert_eq!(
        background.calls.load(Ordering::SeqCst),
        1,
        "revoked memberships stop background synchronization before provider access"
    );

    sqlx::query("DELETE FROM workspaces WHERE id=ANY($1)")
        .bind(vec![workspace, foreign])
        .execute(&pool)
        .await
        .unwrap();
    sqlx::query("DELETE FROM users WHERE id=ANY($1)")
        .bind(vec![user, peer, outsider])
        .execute(&pool)
        .await
        .unwrap();
}
