mod common;

use axum::{
    Router,
    body::Body,
    http::{Request, StatusCode},
};
use http_body_util::BodyExt;
use postmere_ai::sender_profile::{self, SearchTransport};
use postmere_core::{
    AppState,
    auth::{AuthContext, SessionResponse, hash_password},
    db,
    error::AppError,
};
use postmere_server::application;
use serde_json::{Value, json};
use std::sync::{
    Arc, Mutex,
    atomic::{AtomicUsize, Ordering},
};
use tokio::sync::Semaphore;
use tower::ServiceExt;
use uuid::Uuid;
use zeroize::Zeroizing;

#[derive(Clone)]
struct FixtureSearch {
    calls: Arc<AtomicUsize>,
    requests: Arc<Mutex<Vec<Value>>>,
    started: Arc<Semaphore>,
    resume: Option<Arc<Semaphore>>,
    no_match: bool,
}
impl FixtureSearch {
    fn new(paused: bool, no_match: bool) -> Self {
        Self {
            calls: Arc::new(AtomicUsize::new(0)),
            requests: Arc::new(Mutex::new(Vec::new())),
            started: Arc::new(Semaphore::new(0)),
            resume: paused.then(|| Arc::new(Semaphore::new(0))),
            no_match,
        }
    }
}
impl SearchTransport for FixtureSearch {
    async fn search(&self, _: &AppState, request: Value) -> Result<Value, AppError> {
        self.calls.fetch_add(1, Ordering::SeqCst);
        self.requests.lock().unwrap().push(request.clone());
        self.started.add_permits(1);
        if let Some(resume) = &self.resume {
            resume.acquire().await.unwrap().forget();
        }
        let input: Value =
            serde_json::from_str(request["input"][1]["content"].as_str().unwrap()).unwrap();
        let result = if self.no_match {
            json!({"match":"none","matched_email":null,"matched_name":null,"matched_domain":null,"identity_source_urls":[],
                "name":null,"job_title":null,"company":null,"location":null,"bio":null,"links":[],"citations":[]})
        } else {
            json!({"match":"email","matched_email":input["sender_email"],"matched_name":null,"matched_domain":null,
                "identity_source_urls":["https://analytical.org/team/ada"],"name":"Ada Lovelace","job_title":null,
                "company":null,"location":null,"bio":null,
                "links":[{"label":"Website","url":"https://analytical.org/team/ada"}],
                "citations":[{"field":"name","source_urls":["https://analytical.org/team/ada"]},
                    {"field":"links","source_urls":["https://analytical.org/team/ada"]}]})
        };
        Ok(json!({"status":"completed","output":[
            {"type":"web_search_call","status":"completed","action":{"type":"search","sources":[{"type":"url","url":"https://analytical.org/team/ada","title":"Ada's professional page"}]}},
            {"type":"message","content":[{"type":"output_text","text":result.to_string(),"annotations":[]}]}]}))
    }
}

async fn call(
    app: &Router,
    method: &str,
    path: &str,
    token: Option<&str>,
    body: Value,
) -> (StatusCode, Value) {
    let mut request = Request::builder()
        .method(method)
        .uri(path)
        .header("content-type", "application/json");
    if let Some(token) = token {
        request = request.header("authorization", format!("Bearer {token}"));
    }
    let response = app
        .clone()
        .oneshot(request.body(Body::from(body.to_string())).unwrap())
        .await
        .unwrap();
    let status = response.status();
    let body = response.into_body().collect().await.unwrap().to_bytes();
    (status, serde_json::from_slice(&body).unwrap_or(Value::Null))
}
fn path(message: Uuid) -> String {
    format!("/v1/mail/messages/{message}/sender-profile")
}

struct Fixture {
    state: AppState,
    app: Router,
    users: Vec<(AuthContext, String, Uuid, Uuid)>,
}
impl Fixture {
    async fn new(transport: FixtureSearch, count: usize) -> Self {
        let url = std::env::var("POSTMERE_TEST_DATABASE_URL")
            .expect("Use the isolated non-superuser test database");
        let pool = db::connect(&url).await.unwrap();
        db::migrate(&pool).await.unwrap();
        let mut config = common::config(url);
        config.ai_api_key = Some("fixture-never-transmitted".into());
        let mut state = AppState::new(pool.clone(), config).await.unwrap();
        state.http = reqwest::Client::builder()
            .no_proxy()
            .resolve("api.openai.com", "127.0.0.1:9".parse().unwrap())
            .build()
            .unwrap();
        let app = application(state.clone(), sender_profile::router(transport));
        let workspace = Uuid::new_v4();
        let hash = hash_password(Zeroizing::new(
            "profile fixture password long enough".into(),
        ))
        .await
        .unwrap();
        let mut users = Vec::new();
        for index in 0..count {
            let ws = if index == 2 {
                Uuid::new_v4()
            } else {
                workspace
            };
            let user = Uuid::new_v4();
            let email = format!("profile-{user}@example.test");
            sqlx::query("INSERT INTO workspaces(id,name) VALUES($1,'Sender profile fixture') ON CONFLICT DO NOTHING").bind(ws).execute(&pool).await.unwrap();
            sqlx::query("INSERT INTO users(id,email,password_hash) VALUES($1,$2,$3)")
                .bind(user)
                .bind(&email)
                .bind(&hash)
                .execute(&pool)
                .await
                .unwrap();
            sqlx::query(
                "INSERT INTO memberships(workspace_id,user_id,role) VALUES($1,$2,'member')",
            )
            .bind(ws)
            .bind(user)
            .execute(&pool)
            .await
            .unwrap();
            let (status, session) = call(&app, "POST", "/v1/auth/login", None,
                json!({"email":email,"password":"profile fixture password long enough","workspace_id":ws})).await;
            assert_eq!(status, StatusCode::OK, "{session}");
            let session: SessionResponse = serde_json::from_value(session).unwrap();
            let auth = state.auth.authenticate(&session.token).await.unwrap();
            let account = seed_account(&state, &auth).await;
            let message = seed_message(&state, &auth, account, "ada@analytical.org", "inbox").await;
            users.push((auth, session.token, account, message));
        }
        Self { state, app, users }
    }
}
async fn seed_account(state: &AppState, auth: &AuthContext) -> Uuid {
    let account = Uuid::new_v4();
    let mut tx = auth.begin(&state.pool).await.unwrap();
    sqlx::query("INSERT INTO provider_accounts(id,workspace_id,user_id,provider,email,encrypted_credentials) VALUES($1,$2,$3,'gmail',$4,$5)")
        .bind(account).bind(auth.workspace_id).bind(auth.user_id).bind(format!("mail-{account}@example.test"))
        .bind(state.crypto.seal(auth.workspace_id, account, b"fixture-credentials").unwrap()).execute(&mut *tx).await.unwrap();
    sqlx::query("INSERT INTO ai_preferences(workspace_id,user_id,enabled) VALUES($1,$2,true) ON CONFLICT(workspace_id,user_id) DO UPDATE SET enabled=true")
        .bind(auth.workspace_id).bind(auth.user_id).execute(&mut *tx).await.unwrap();
    tx.commit().await.unwrap();
    account
}
async fn seed_message(
    state: &AppState,
    auth: &AuthContext,
    account: Uuid,
    email: &str,
    mailbox: &str,
) -> Uuid {
    let message = Uuid::new_v4();
    let mut tx = auth.begin(&state.pool).await.unwrap();
    sqlx::query("INSERT INTO mail_messages(id,workspace_id,user_id,account_id,provider_message_id,provider_thread_id,sent_at,normalized,search_text) VALUES($1,$2,$3,$4,$5,$5,now(),$6,'Private mailbox history must not leave the server')")
        .bind(message).bind(auth.workspace_id).bind(auth.user_id).bind(account).bind(message.to_string())
        .bind(json!({"from":{"email":email,"name":"Ada Lovelace"},"subject":"Private subject marker",
            "text_body":"Private message marker","html_body":"Private HTML marker","mailbox":mailbox,"provider_labels":[]}))
        .execute(&mut *tx).await.unwrap();
    tx.commit().await.unwrap();
    message
}

#[tokio::test]
async fn sender_profile_ownership_consent_cache_and_envelope_minimization() {
    let transport = FixtureSearch::new(false, false);
    let fixture = Fixture::new(transport.clone(), 3).await;
    let (auth, token, account, message) = &fixture.users[0];
    assert_eq!(
        call(&fixture.app, "POST", &path(*message), None, json!({}))
            .await
            .0,
        StatusCode::UNAUTHORIZED
    );
    for (_, peer, _, _) in &fixture.users[1..] {
        assert_eq!(
            call(&fixture.app, "POST", &path(*message), Some(peer), json!({}))
                .await
                .0,
            StatusCode::NOT_FOUND
        );
    }
    for refresh in [false, false, true] {
        let result = call(
            &fixture.app,
            "POST",
            &path(*message),
            Some(token),
            json!({"refresh":refresh}),
        )
        .await;
        assert_eq!(result.0, StatusCode::OK, "{}", result.1);
        assert_eq!(result.1["status"], "matched");
        assert_eq!(result.1["profile"]["sources"].as_array().unwrap().len(), 1);
    }
    assert_eq!(transport.calls.load(Ordering::SeqCst), 1);
    let request = transport.requests.lock().unwrap()[0].clone();
    assert!(!request.to_string().contains("Private"));
    let input: Value =
        serde_json::from_str(request["input"][1]["content"].as_str().unwrap()).unwrap();
    assert_eq!(input.as_object().unwrap().len(), 3);
    assert_eq!(input["sender_email"], "ada@analytical.org");
    // A second owned account must not reuse the first account's cache.
    let second_account = seed_account(&fixture.state, auth).await;
    let second_message = seed_message(
        &fixture.state,
        auth,
        second_account,
        "ada@analytical.org",
        "inbox",
    )
    .await;
    assert_eq!(
        call(
            &fixture.app,
            "POST",
            &path(second_message),
            Some(token),
            json!({})
        )
        .await
        .1["status"],
        "matched"
    );
    assert_eq!(transport.calls.load(Ordering::SeqCst), 2);
    for (_, peer, _, peer_message) in &fixture.users[1..] {
        assert_eq!(
            call(
                &fixture.app,
                "POST",
                &path(*peer_message),
                Some(peer),
                json!({})
            )
            .await
            .1["status"],
            "matched"
        );
    }
    assert_eq!(transport.calls.load(Ordering::SeqCst), 4);
    for (email, mailbox) in [
        ("noreply@analytical.org", "inbox"),
        ("ada@analytical.org", "sent"),
    ] {
        let outgoing = seed_message(&fixture.state, auth, *account, email, mailbox).await;
        assert_eq!(
            call(
                &fixture.app,
                "POST",
                &path(outgoing),
                Some(token),
                json!({})
            )
            .await
            .1["status"],
            "not_found"
        );
    }
    assert_eq!(transport.calls.load(Ordering::SeqCst), 4);
    let mut tx = auth.begin(&fixture.state.pool).await.unwrap();
    sqlx::query("UPDATE ai_preferences SET enabled=false WHERE workspace_id=$1 AND user_id=$2")
        .bind(auth.workspace_id)
        .bind(auth.user_id)
        .execute(&mut *tx)
        .await
        .unwrap();
    tx.commit().await.unwrap();
    assert_eq!(
        call(
            &fixture.app,
            "POST",
            &path(*message),
            Some(token),
            json!({})
        )
        .await
        .1["status"],
        "disabled"
    );
    assert_eq!(transport.calls.load(Ordering::SeqCst), 4);
}

#[tokio::test]
async fn concurrent_sender_lookups_coalesce_and_no_match_is_cached() {
    let transport = FixtureSearch::new(true, true);
    let fixture = Fixture::new(transport.clone(), 1).await;
    let (_, token, _, message) = &fixture.users[0];
    let a = fixture.app.clone();
    let t = token.clone();
    let p = path(*message);
    let first = tokio::spawn(async move { call(&a, "POST", &p, Some(&t), json!({})).await });
    tokio::time::timeout(
        std::time::Duration::from_secs(5),
        transport.started.acquire(),
    )
    .await
    .unwrap()
    .unwrap()
    .forget();
    let a = fixture.app.clone();
    let t = token.clone();
    let p = path(*message);
    let second =
        tokio::spawn(async move { call(&a, "POST", &p, Some(&t), json!({"refresh":true})).await });
    tokio::task::yield_now().await;
    transport.resume.as_ref().unwrap().add_permits(2);
    for result in [first.await.unwrap(), second.await.unwrap()] {
        assert_eq!(result.0, StatusCode::OK, "{}", result.1);
        assert_eq!(result.1["status"], "not_found");
        assert!(result.1.get("profile").is_none());
    }
    assert_eq!(transport.calls.load(Ordering::SeqCst), 1);
    assert_eq!(
        call(
            &fixture.app,
            "POST",
            &path(*message),
            Some(token),
            json!({})
        )
        .await
        .1["status"],
        "not_found"
    );
    assert_eq!(transport.calls.load(Ordering::SeqCst), 1);
}

#[tokio::test]
async fn sender_profile_rechecks_authorization_after_provider_waits() {
    for revoke in [
        "logout",
        "membership",
        "disconnect",
        "reconnect",
        "consent",
        "message",
    ] {
        let transport = FixtureSearch::new(true, false);
        let fixture = Fixture::new(transport.clone(), 1).await;
        let (auth, token, account, message) = &fixture.users[0];
        let a = fixture.app.clone();
        let t = token.clone();
        let p = path(*message);
        let pending = tokio::spawn(async move { call(&a, "POST", &p, Some(&t), json!({})).await });
        tokio::time::timeout(
            std::time::Duration::from_secs(5),
            transport.started.acquire(),
        )
        .await
        .unwrap()
        .unwrap()
        .forget();
        let mut tx = auth.begin(&fixture.state.pool).await.unwrap();
        match revoke {
            "logout" => {
                sqlx::query("UPDATE sessions SET revoked_at=now() WHERE id=$1")
                    .bind(auth.session_id)
                    .execute(&mut *tx)
                    .await
                    .unwrap();
            }
            "membership" => {
                sqlx::query(
                    "UPDATE memberships SET revoked_at=now() WHERE workspace_id=$1 AND user_id=$2",
                )
                .bind(auth.workspace_id)
                .bind(auth.user_id)
                .execute(&mut *tx)
                .await
                .unwrap();
            }
            "disconnect" => {
                sqlx::query("UPDATE provider_accounts SET disabled_at=now() WHERE id=$1")
                    .bind(account)
                    .execute(&mut *tx)
                    .await
                    .unwrap();
            }
            "reconnect" => {
                sqlx::query("UPDATE provider_accounts SET status='reconnect_required' WHERE id=$1")
                    .bind(account)
                    .execute(&mut *tx)
                    .await
                    .unwrap();
            }
            "consent" => {
                sqlx::query(
                    "UPDATE ai_preferences SET enabled=false WHERE workspace_id=$1 AND user_id=$2",
                )
                .bind(auth.workspace_id)
                .bind(auth.user_id)
                .execute(&mut *tx)
                .await
                .unwrap();
            }
            "message" => {
                sqlx::query("UPDATE mail_messages SET deleted_at=now() WHERE id=$1")
                    .bind(message)
                    .execute(&mut *tx)
                    .await
                    .unwrap();
            }
            _ => unreachable!(),
        }
        tx.commit().await.unwrap();
        transport.resume.as_ref().unwrap().add_permits(1);
        let result = tokio::time::timeout(std::time::Duration::from_secs(5), pending)
            .await
            .unwrap()
            .unwrap();
        let expected = match revoke {
            "logout" | "membership" => StatusCode::UNAUTHORIZED,
            "consent" => StatusCode::OK,
            _ => StatusCode::NOT_FOUND,
        };
        assert_eq!(result.0, expected, "{revoke}: {}", result.1);
        assert!(result.1.get("profile").is_none(), "{revoke}");
        if revoke == "consent" {
            assert_eq!(result.1["status"], "disabled");
        }
    }
}

#[tokio::test]
async fn unconfigured_sender_profile_never_calls_transport() {
    let transport = FixtureSearch::new(false, false);
    let fixture = Fixture::new(transport.clone(), 1).await;
    let mut config = (*fixture.state.config).clone();
    config.ai_api_key = None;
    let state = AppState::new(fixture.state.pool.clone(), config)
        .await
        .unwrap();
    let app = application(state, sender_profile::router(transport.clone()));
    let (_, token, _, message) = &fixture.users[0];
    let result = call(&app, "POST", &path(*message), Some(token), json!({})).await;
    assert_eq!(result.0, StatusCode::OK);
    assert_eq!(result.1["status"], "unconfigured");
    assert_eq!(transport.calls.load(Ordering::SeqCst), 0);
}
