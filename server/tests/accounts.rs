mod common;

use axum::{
    Router,
    body::Body,
    http::{Request, StatusCode},
};
use chrono::{Duration, Utc};
use http_body_util::BodyExt;
use postmere_core::{
    AppState,
    auth::{AuthContext, SessionResponse, hash_password},
    db,
    error::AppError,
};
use postmere_mail::{
    mail::{self, AccountSession, OAuthFuture, OAuthTransport},
    mail_sync::{self, SyncTransport},
};
use postmere_providers::{Credentials, Identity, Provider, SyncBatch, SyncCheckpoint};
use postmere_server::application;
use serde_json::{Value, json};
use sqlx::{PgPool, Row};
use std::{
    collections::HashSet,
    sync::{
        Arc, Mutex,
        atomic::{AtomicBool, Ordering},
    },
};
use tokio::sync::{Barrier, Notify};
use tower::ServiceExt;
use uuid::Uuid;
use zeroize::Zeroizing;

async fn request(
    app: &Router,
    method: &str,
    path: &str,
    token: &str,
    body: Value,
) -> (StatusCode, Value) {
    let response = app
        .clone()
        .oneshot(
            Request::builder()
                .method(method)
                .uri(path)
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

async fn member(pool: &PgPool, workspace: Uuid, hash: &str) -> (Uuid, String) {
    let user = Uuid::new_v4();
    let email = format!("accounts-{user}@example.test");
    sqlx::query("INSERT INTO users(id,email,password_hash) VALUES($1,$2,$3)")
        .bind(user)
        .bind(&email)
        .bind(hash)
        .execute(pool)
        .await
        .unwrap();
    sqlx::query("INSERT INTO workspaces(id,name) VALUES($1,'Multiple accounts fixture') ON CONFLICT DO NOTHING")
        .bind(workspace).execute(pool).await.unwrap();
    sqlx::query("INSERT INTO memberships(workspace_id,user_id,role) VALUES($1,$2,'owner')")
        .bind(workspace)
        .bind(user)
        .execute(pool)
        .await
        .unwrap();
    (user, email)
}

async fn login(app: &Router, workspace: Uuid, email: &str) -> SessionResponse {
    let (status, response) = request(app, "POST", "/v1/auth/login", "unused",
        json!({"workspace_id":workspace,"email":email,"password":"multiple accounts fixture password"})).await;
    assert_eq!(status, StatusCode::OK, "{response}");
    serde_json::from_value(response).unwrap()
}

struct FixtureOAuth {
    barrier: Option<Barrier>,
}
impl OAuthTransport for FixtureOAuth {
    fn connect<'a>(
        &'a self,
        _: &'a AppState,
        provider: Provider,
        code: &'a str,
        verifier: &'a str,
    ) -> OAuthFuture<'a> {
        Box::pin(async move {
            assert!(!verifier.is_empty());
            if let Some(barrier) = &self.barrier {
                barrier.wait().await;
            }
            let (email, version) = code.split_once('|').unwrap();
            Ok((
                Credentials {
                    access_token: format!("fixture-{}-{version}", provider.as_str()),
                    refresh_token: Some(format!("fixture-refresh-{version}")),
                    expires_at: Utc::now() + Duration::days(1),
                    scopes: vec![],
                },
                Identity {
                    email: email.into(),
                    display_name: Some(version.into()),
                },
            ))
        })
    }
}

async fn begin(app: &Router, session: &SessionResponse, provider: Provider) -> (Uuid, String) {
    let (status, response) = request(
        app,
        "POST",
        &format!("/v1/mail/oauth/{}/start", provider.as_str()),
        &session.token,
        json!({}),
    )
    .await;
    assert_eq!(status, StatusCode::OK, "{response}");
    let url = url::Url::parse(response["authorization_url"].as_str().unwrap()).unwrap();
    let parameters = url
        .query_pairs()
        .into_owned()
        .collect::<std::collections::HashMap<_, _>>();
    assert!(
        parameters["prompt"]
            .split_whitespace()
            .any(|p| p == "select_account"),
        "each additional connection offers account selection"
    );
    if provider == Provider::Gmail {
        assert!(
            parameters["prompt"]
                .split_whitespace()
                .any(|p| p == "consent")
        );
        assert_eq!(parameters["access_type"], "offline");
    }
    (
        serde_json::from_value(response["connection_id"].clone()).unwrap(),
        parameters["state"].clone(),
    )
}

async fn connected_id(app: &Router, session: &SessionResponse, connection: Uuid) -> Uuid {
    let (status, response) = request(
        app,
        "GET",
        &format!("/v1/mail/oauth/connections/{connection}"),
        &session.token,
        Value::Null,
    )
    .await;
    assert_eq!(status, StatusCode::OK);
    assert_eq!(response["status"], "connected", "{response}");
    serde_json::from_value(response["account_id"].clone()).unwrap()
}

async fn connect(
    state: &AppState,
    app: &Router,
    session: &SessionResponse,
    provider: Provider,
    email: &str,
    version: &str,
) -> Uuid {
    let (connection, token) = begin(app, session, provider).await;
    let _ = mail::complete_oauth_with(
        state,
        provider,
        &token,
        Some(&format!("{email}|{version}")),
        false,
        &FixtureOAuth { barrier: None },
    )
    .await
    .unwrap();
    connected_id(app, session, connection).await
}

async fn credential_bytes(state: &AppState, auth: &AuthContext, account: Uuid) -> Vec<u8> {
    let mut tx = auth.begin(&state.pool).await.unwrap();
    sqlx::query_scalar("SELECT encrypted_credentials FROM provider_accounts WHERE id=$1")
        .bind(account)
        .fetch_one(&mut *tx)
        .await
        .unwrap()
}

#[derive(Default)]
struct RecordingSync {
    seen: Mutex<Vec<Uuid>>,
}
impl SyncTransport for RecordingSync {
    fn fetch<'a>(
        &'a self,
        _: &'a AppState,
        session: &'a AccountSession,
        _: SyncCheckpoint,
        _: &'a [String],
    ) -> std::pin::Pin<Box<dyn std::future::Future<Output = Result<SyncBatch, AppError>> + Send + 'a>>
    {
        Box::pin(async move {
            self.seen.lock().unwrap().push(session.account.id);
            Ok(SyncBatch {
                messages: vec![],
                deleted_ids: vec![],
                checkpoint: SyncCheckpoint {
                    phase: "history".into(),
                    cursor: Some(session.account.id.to_string()),
                    ..Default::default()
                },
                has_more: true,
            })
        })
    }
}

struct SlowSync {
    slow_account: Uuid,
    slow_entered: Notify,
    fast_finished: Notify,
    release_slow: Notify,
    slow_finished: AtomicBool,
    slow_dropped: Notify,
}

struct NotifyOnDrop<'a>(&'a Notify);
impl Drop for NotifyOnDrop<'_> {
    fn drop(&mut self) {
        self.0.notify_one();
    }
}
impl SyncTransport for SlowSync {
    fn fetch<'a>(
        &'a self,
        _: &'a AppState,
        session: &'a AccountSession,
        _: SyncCheckpoint,
        _: &'a [String],
    ) -> std::pin::Pin<Box<dyn std::future::Future<Output = Result<SyncBatch, AppError>> + Send + 'a>>
    {
        Box::pin(async move {
            if session.account.id == self.slow_account {
                let _drop_notice = NotifyOnDrop(&self.slow_dropped);
                self.slow_entered.notify_one();
                self.release_slow.notified().await;
                self.slow_finished.store(true, Ordering::SeqCst);
            } else {
                self.fast_finished.notify_one();
            }
            Ok(SyncBatch {
                messages: vec![],
                deleted_ids: vec![],
                checkpoint: SyncCheckpoint::default(),
                has_more: false,
            })
        })
    }
}

#[tokio::test]
async fn disconnect_waits_for_sync_before_account_rows_and_rechecks_session_expiry() {
    let url = std::env::var("POSTMERE_TEST_DATABASE_URL")
        .expect("Set the isolated non-bypass PostgreSQL test database URL");
    let base = db::connect(&url).await.unwrap();
    let schema = format!("disconnect_fixture_{}", Uuid::new_v4().simple());
    sqlx::query(sqlx::AssertSqlSafe(format!("CREATE SCHEMA {schema}")))
        .execute(&base)
        .await
        .unwrap();
    let connection_schema = schema.clone();
    let pool = sqlx::postgres::PgPoolOptions::new()
        .max_connections(10)
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
    config.google_client_id = Some("fixture-google".into());
    config.google_client_secret = Some("fixture-secret".into());
    let state = AppState::new(pool.clone(), config).await.unwrap();
    let app = application(state.clone(), mail::router());
    let workspace = Uuid::new_v4();
    let hash = hash_password(Zeroizing::new("multiple accounts fixture password".into()))
        .await
        .unwrap();
    let (user, email) = member(&pool, workspace, &hash).await;
    let mut retained = None;
    for expire_while_waiting in [false, true] {
        let session = login(&app, workspace, &email).await;
        let auth = state.auth.authenticate(&session.token).await.unwrap();
        let account = connect(
            &state,
            &app,
            &session,
            Provider::Gmail,
            &format!("race-{}@example.test", Uuid::new_v4()),
            "v1",
        )
        .await;
        let paused = Arc::new(SlowSync {
            slow_account: account,
            slow_entered: Notify::new(),
            fast_finished: Notify::new(),
            release_slow: Notify::new(),
            slow_finished: AtomicBool::new(false),
            slow_dropped: Notify::new(),
        });
        let sync = {
            let state = state.clone();
            let paused = paused.clone();
            tokio::spawn(async move {
                mail_sync::sync_account_with(&state, workspace, user, account, paused.as_ref())
                    .await
            })
        };
        tokio::time::timeout(
            std::time::Duration::from_secs(3),
            paused.slow_entered.notified(),
        )
        .await
        .unwrap();
        // Sync now owns its advisory and wakeup row while awaiting the provider.
        if expire_while_waiting {
            sqlx::query("UPDATE sessions SET expires_at=clock_timestamp()+interval '1 second',absolute_expires_at=clock_timestamp()+interval '1 hour' WHERE id=$1")
                .bind(auth.session_id).execute(&pool).await.unwrap();
        }
        let disconnect = {
            let app = app.clone();
            let token = session.token.clone();
            tokio::spawn(async move {
                request(
                    &app,
                    "DELETE",
                    &format!("/v1/mail/accounts/{account}"),
                    &token,
                    Value::Null,
                )
                .await
            })
        };
        let key: i64 = sqlx::query_scalar("SELECT hashtextextended($1,0)")
            .bind(format!("mail-sync:{workspace}:{user}:{account}"))
            .fetch_one(&pool)
            .await
            .unwrap();
        tokio::time::timeout(std::time::Duration::from_secs(3), async {
            loop {
                let waiting: bool = sqlx::query_scalar("SELECT EXISTS(SELECT 1 FROM pg_locks WHERE locktype='advisory' AND NOT granted AND classid::bigint=$1 AND objid::bigint=$2 AND objsubid=1)")
                    .bind(((key as u64) >> 32) as i64).bind((key as u64 & 0xffff_ffff) as i64)
                    .fetch_one(&pool).await.unwrap();
                if waiting { break; }
                tokio::time::sleep(std::time::Duration::from_millis(10)).await;
            }
        }).await.expect("disconnect must wait for sync before locking its account row");
        let mut probe = auth.begin(&pool).await.unwrap();
        sqlx::query("SELECT id FROM provider_accounts WHERE id=$1 FOR UPDATE NOWAIT")
            .bind(account)
            .fetch_one(&mut *probe)
            .await
            .expect("waiting disconnect must not hold the account row needed by sync");
        probe.rollback().await.unwrap();
        if expire_while_waiting {
            tokio::time::sleep(std::time::Duration::from_millis(1100)).await;
        }
        paused.release_slow.notify_one();
        tokio::time::timeout(std::time::Duration::from_secs(3), sync)
            .await
            .unwrap()
            .unwrap()
            .unwrap();
        let (status, _) = tokio::time::timeout(std::time::Duration::from_secs(3), disconnect)
            .await
            .unwrap()
            .unwrap();
        assert_eq!(
            status,
            if expire_while_waiting {
                StatusCode::UNAUTHORIZED
            } else {
                StatusCode::OK
            }
        );
        let mut tx = auth.begin(&pool).await.unwrap();
        let disabled: bool =
            sqlx::query_scalar("SELECT disabled_at IS NOT NULL FROM provider_accounts WHERE id=$1")
                .bind(account)
                .fetch_one(&mut *tx)
                .await
                .unwrap();
        let scheduled: bool = sqlx::query_scalar(
            "SELECT EXISTS(SELECT 1 FROM mail_sync_wakeups WHERE account_id=$1)",
        )
        .bind(account)
        .fetch_one(&mut *tx)
        .await
        .unwrap();
        assert_eq!(disabled, !expire_while_waiting);
        assert_eq!(
            scheduled, expire_while_waiting,
            "expired disconnect must not remove sync work"
        );
        tx.commit().await.unwrap();
        if expire_while_waiting {
            retained = Some(account);
        }
    }
    let session = login(&app, workspace, &email).await;
    let revoked_auth = state.auth.authenticate(&session.token).await.unwrap();
    sqlx::query("UPDATE sessions SET revoked_at=clock_timestamp() WHERE id=$1")
        .bind(revoked_auth.session_id)
        .execute(&pool)
        .await
        .unwrap();
    let mut tx = revoked_auth.begin(&pool).await.unwrap();
    assert_eq!(
        mail::disconnect_in_transaction(&mut tx, &revoked_auth, retained.unwrap())
            .await
            .unwrap_err()
            .status,
        StatusCode::UNAUTHORIZED,
        "scoped stale callers must not bypass disconnect authorization"
    );
    tx.rollback().await.unwrap();
    pool.close().await;
    sqlx::query(sqlx::AssertSqlSafe(format!("DROP SCHEMA {schema} CASCADE")))
        .execute(&base)
        .await
        .unwrap();
    base.close().await;
}

#[tokio::test]
async fn many_provider_accounts_remain_independent_through_reconnect_disconnect_and_sync() {
    let url = std::env::var("POSTMERE_TEST_DATABASE_URL")
        .expect("Set the isolated non-bypass PostgreSQL test database URL");
    let pool = db::connect(&url).await.unwrap();
    db::migrate(&pool).await.unwrap();
    let mut config = common::config(url);
    config.google_client_id = Some("fixture-google".into());
    config.google_client_secret = Some("fixture-secret".into());
    config.microsoft_client_id = Some("fixture-microsoft".into());
    config.microsoft_client_secret = Some("fixture-secret".into());
    let state = AppState::new(pool.clone(), config).await.unwrap();
    let app = application(state.clone(), mail::router());
    let workspace = Uuid::new_v4();
    let foreign = Uuid::new_v4();
    let hash = hash_password(Zeroizing::new("multiple accounts fixture password".into()))
        .await
        .unwrap();
    let (user, email) = member(&pool, workspace, &hash).await;
    let (peer, peer_email) = member(&pool, workspace, &hash).await;
    let (outsider, outsider_email) = member(&pool, foreign, &hash).await;
    let session = login(&app, workspace, &email).await;
    let peer_session = login(&app, workspace, &peer_email).await;
    let outside_session = login(&app, foreign, &outsider_email).await;
    let auth = state.auth.authenticate(&session.token).await.unwrap();
    let mut account_ids = vec![];
    for provider in [Provider::Gmail, Provider::Microsoft] {
        for index in 0..12 {
            account_ids.push(
                connect(
                    &state,
                    &app,
                    &session,
                    provider,
                    &format!("mailbox-{index}@example.test"),
                    &format!("initial-{index}"),
                )
                .await,
            );
        }
    }
    assert_eq!(
        account_ids.iter().copied().collect::<HashSet<_>>().len(),
        24
    );
    let (status, listed) = request(
        &app,
        "GET",
        "/v1/mail/accounts",
        &session.token,
        Value::Null,
    )
    .await;
    assert_eq!(status, StatusCode::OK);
    let listed = listed.as_array().unwrap();
    assert_eq!(
        listed.len(),
        24,
        "connected accounts are not truncated at ten"
    );
    for provider in ["gmail", "microsoft"] {
        assert_eq!(
            listed.iter().filter(|a| a["provider"] == provider).count(),
            12
        );
    }

    let peer_account = connect(
        &state,
        &app,
        &peer_session,
        Provider::Gmail,
        "mailbox-0@example.test",
        "peer",
    )
    .await;
    let outside_account = connect(
        &state,
        &app,
        &outside_session,
        Provider::Gmail,
        "mailbox-0@example.test",
        "outside",
    )
    .await;
    assert_ne!(peer_account, account_ids[0]);
    assert_ne!(outside_account, account_ids[0]);
    for (other_session, expected) in [
        (&peer_session, peer_account),
        (&outside_session, outside_account),
    ] {
        let (_, listed) = request(
            &app,
            "GET",
            "/v1/mail/accounts",
            &other_session.token,
            Value::Null,
        )
        .await;
        assert_eq!(listed.as_array().unwrap().len(), 1);
        assert_eq!(listed[0]["id"], expected.to_string());
        assert_eq!(
            request(
                &app,
                "DELETE",
                &format!("/v1/mail/accounts/{}", account_ids[0]),
                &other_session.token,
                Value::Null
            )
            .await
            .0,
            StatusCode::NOT_FOUND
        );
    }

    let selected = account_ids[5];
    let neighbor = account_ids[6];
    // A name the person gives an account: set, private to its owner, bounded,
    // and kept when the account is reconnected.
    let selected_path = format!("/v1/mail/accounts/{selected}");
    let (status, _) = request(
        &app,
        "PATCH",
        &selected_path,
        &session.token,
        json!({"name": "  Work  "}),
    )
    .await;
    assert_eq!(status, StatusCode::OK);
    let (status, _) = request(
        &app,
        "PATCH",
        &selected_path,
        &peer_session.token,
        json!({"name": "Mine"}),
    )
    .await;
    assert_eq!(status, StatusCode::NOT_FOUND);
    let (status, _) = request(
        &app,
        "PATCH",
        &selected_path,
        &session.token,
        json!({"name": "x".repeat(65)}),
    )
    .await;
    assert_eq!(status, StatusCode::BAD_REQUEST);
    let before_selected = credential_bytes(&state, &auth, selected).await;
    let before_neighbor = credential_bytes(&state, &auth, neighbor).await;
    assert_eq!(
        connect(
            &state,
            &app,
            &session,
            Provider::Gmail,
            "MAILBOX-5@example.test",
            "reconnected"
        )
        .await,
        selected
    );
    assert_ne!(
        credential_bytes(&state, &auth, selected).await,
        before_selected
    );
    assert_eq!(
        credential_bytes(&state, &auth, neighbor).await,
        before_neighbor,
        "reconnect changes only the selected identity"
    );
    let name_of = |listed: &Value, id: Uuid| {
        listed
            .as_array()
            .unwrap()
            .iter()
            .find(|a| a["id"] == id.to_string())
            .unwrap()["name"]
            .clone()
    };
    let (_, listed) = request(
        &app,
        "GET",
        "/v1/mail/accounts",
        &session.token,
        Value::Null,
    )
    .await;
    assert_eq!(
        name_of(&listed, selected),
        "Work",
        "reconnecting keeps the account's name"
    );
    assert!(name_of(&listed, neighbor).is_null());
    let (status, _) = request(
        &app,
        "PATCH",
        &selected_path,
        &session.token,
        json!({"name": ""}),
    )
    .await;
    assert_eq!(status, StatusCode::OK);
    let (_, listed) = request(
        &app,
        "GET",
        "/v1/mail/accounts",
        &session.token,
        Value::Null,
    )
    .await;
    assert!(
        name_of(&listed, selected).is_null(),
        "an empty name clears it"
    );

    let (first_connection, first_token) = begin(&app, &session, Provider::Microsoft).await;
    let (second_connection, second_token) = begin(&app, &session, Provider::Microsoft).await;
    let simultaneous = FixtureOAuth {
        barrier: Some(Barrier::new(2)),
    };
    let (one, two) = tokio::join!(
        mail::complete_oauth_with(
            &state,
            Provider::Microsoft,
            &first_token,
            Some("parallel@example.test|first"),
            false,
            &simultaneous
        ),
        mail::complete_oauth_with(
            &state,
            Provider::Microsoft,
            &second_token,
            Some("parallel@example.test|second"),
            false,
            &simultaneous
        ),
    );
    let _ = one.unwrap();
    let _ = two.unwrap();
    let parallel = connected_id(&app, &session, first_connection).await;
    assert_eq!(
        parallel,
        connected_id(&app, &session, second_connection).await,
        "simultaneous first connections share a stable account ID"
    );
    account_ids.push(parallel);

    assert_eq!(
        request(
            &app,
            "DELETE",
            &format!("/v1/mail/accounts/{selected}"),
            &session.token,
            Value::Null
        )
        .await
        .0,
        StatusCode::OK
    );
    let (_, remaining) = request(
        &app,
        "GET",
        "/v1/mail/accounts",
        &session.token,
        Value::Null,
    )
    .await;
    assert_eq!(remaining.as_array().unwrap().len(), 24);
    assert!(
        !remaining
            .as_array()
            .unwrap()
            .iter()
            .any(|a| a["id"] == selected.to_string())
    );
    assert_eq!(
        credential_bytes(&state, &auth, neighbor).await,
        before_neighbor
    );
    assert_eq!(
        connect(
            &state,
            &app,
            &session,
            Provider::Gmail,
            "mailbox-5@example.test",
            "restored"
        )
        .await,
        selected,
        "reconnecting a disconnected identity restores its original account ID"
    );

    // A bound on unfinished OAuth handshakes remains independent of the number
    // of connected accounts; completed/declined attempts release that capacity.
    let mut attempts = tokio::task::JoinSet::new();
    for _ in 0..11 {
        let app = app.clone();
        let token = session.token.clone();
        attempts.spawn(async move {
            request(
                &app,
                "POST",
                "/v1/mail/oauth/gmail/start",
                &token,
                json!({}),
            )
            .await
        });
    }
    let mut pending = vec![];
    let mut rejected = 0;
    while let Some(result) = attempts.join_next().await {
        let (status, body) = result.unwrap();
        if status == StatusCode::TOO_MANY_REQUESTS {
            rejected += 1;
            continue;
        }
        assert_eq!(status, StatusCode::OK, "{body}");
        let connection: Uuid = serde_json::from_value(body["connection_id"].clone()).unwrap();
        let url = url::Url::parse(body["authorization_url"].as_str().unwrap()).unwrap();
        let token = url
            .query_pairs()
            .find(|(key, _)| key == "state")
            .unwrap()
            .1
            .into_owned();
        pending.push((connection, token));
    }
    assert_eq!(
        pending.len(),
        10,
        "concurrent handshakes obey the unfinished-work bound"
    );
    assert_eq!(rejected, 1);
    for (_, token) in pending {
        let _ = mail::complete_oauth_with(
            &state,
            Provider::Gmail,
            &token,
            None,
            true,
            &FixtureOAuth { barrier: None },
        )
        .await
        .unwrap();
    }

    sqlx::query("UPDATE mail_sync_wakeups SET due_at=now()+interval '1 day',lease_until=NULL WHERE workspace_id=ANY($1)")
        .bind(vec![workspace, foreign]).execute(&pool).await.unwrap();
    sqlx::query("UPDATE mail_sync_wakeups SET due_at=now()-interval '1 day',lease_until=NULL WHERE account_id=ANY($1)")
        .bind(&account_ids).execute(&pool).await.unwrap();
    let sync = RecordingSync::default();
    for _ in 0..account_ids.len() {
        assert!(
            mail_sync::process_one_sync_with(&state, &sync)
                .await
                .unwrap()
        );
    }
    let seen = sync.seen.lock().unwrap().clone();
    assert_eq!(seen.len(), account_ids.len());
    assert_eq!(
        seen.iter().copied().collect::<HashSet<_>>(),
        account_ids.iter().copied().collect(),
        "every due account gets a page before a busy account is repeated"
    );
    let mut tx = auth.begin(&pool).await.unwrap();
    let checkpoints = sqlx::query("SELECT account_id,checkpoint FROM mail_sync_state")
        .fetch_all(&mut *tx)
        .await
        .unwrap();
    for row in checkpoints {
        let id: Uuid = row.get("account_id");
        assert_eq!(row.get::<Value, _>("checkpoint")["cursor"], id.to_string());
    }
    tx.commit().await.unwrap();

    sqlx::query("UPDATE mail_sync_wakeups SET due_at=now()+interval '1 day',lease_until=NULL WHERE workspace_id=ANY($1)")
        .bind(vec![workspace, foreign]).execute(&pool).await.unwrap();
    sqlx::query("UPDATE mail_sync_wakeups SET due_at=now()-interval '1 day',lease_until=NULL WHERE account_id=ANY($1)")
        .bind(vec![selected, neighbor]).execute(&pool).await.unwrap();
    let slow = Arc::new(SlowSync {
        slow_account: selected,
        slow_entered: Notify::new(),
        fast_finished: Notify::new(),
        release_slow: Notify::new(),
        slow_finished: AtomicBool::new(false),
        slow_dropped: Notify::new(),
    });
    let worker = mail_sync::spawn_sync_worker_with(state.clone(), slow.clone());
    let progress = tokio::time::timeout(std::time::Duration::from_secs(5), async {
        slow.slow_entered.notified().await;
        slow.fast_finished.notified().await;
    })
    .await;
    let completed_while_slow = !slow.slow_finished.load(Ordering::SeqCst);
    worker.abort();
    let _ = worker.await;
    tokio::time::timeout(
        std::time::Duration::from_secs(5),
        slow.slow_dropped.notified(),
    )
    .await
    .expect("aborting the parent worker must cancel in-flight child provider requests");
    assert!(
        !slow.slow_finished.load(Ordering::SeqCst),
        "cancelled provider work must not complete after shutdown"
    );
    assert!(
        progress.is_ok() && completed_while_slow,
        "a slow mailbox does not block synchronization of another account"
    );

    // Wait on the same identity lock used by concurrent reconnects, then revoke
    // access after the callback has already completed provider authentication.
    let (revoked_connection, revoked_token) = begin(&app, &peer_session, Provider::Gmail).await;
    let mut blocker = pool.begin().await.unwrap();
    sqlx::query("SELECT pg_advisory_xact_lock(hashtextextended($1,0))")
        .bind(format!(
            "mail-account:{workspace}:{peer}:gmail:revoked@example.test"
        ))
        .execute(&mut *blocker)
        .await
        .unwrap();
    let blocker_pid: i32 = sqlx::query_scalar("SELECT pg_backend_pid()")
        .fetch_one(&mut *blocker)
        .await
        .unwrap();
    let callback_state = state.clone();
    let callback = tokio::spawn(async move {
        mail::complete_oauth_with(
            &callback_state,
            Provider::Gmail,
            &revoked_token,
            Some("revoked@example.test|revoked"),
            false,
            &FixtureOAuth { barrier: None },
        )
        .await
    });
    tokio::time::timeout(std::time::Duration::from_secs(5), async {
        loop {
            let blocked: bool = sqlx::query_scalar(
                "SELECT EXISTS(SELECT 1 FROM pg_stat_activity WHERE $1=ANY(pg_blocking_pids(pid)))",
            )
            .bind(blocker_pid)
            .fetch_one(&pool)
            .await
            .unwrap();
            if blocked {
                break;
            }
            tokio::time::sleep(std::time::Duration::from_millis(10)).await;
        }
    })
    .await
    .expect("callback must reach the held identity lock");
    sqlx::query("UPDATE memberships SET revoked_at=now() WHERE workspace_id=$1 AND user_id=$2")
        .bind(workspace)
        .bind(peer)
        .execute(&pool)
        .await
        .unwrap();
    blocker.commit().await.unwrap();
    let _ = callback.await.unwrap().unwrap();
    let mut revoked_scope = db::scoped_transaction(&pool, workspace, peer)
        .await
        .unwrap();
    let outcome: String =
        sqlx::query_scalar("SELECT status FROM mail_oauth_connections WHERE id=$1")
            .bind(revoked_connection)
            .fetch_one(&mut *revoked_scope)
            .await
            .unwrap();
    assert_eq!(
        outcome, "failed",
        "revocation while waiting prevents credential installation"
    );
    let absent: bool = sqlx::query_scalar(
        "SELECT NOT EXISTS(SELECT 1 FROM provider_accounts WHERE email='revoked@example.test')",
    )
    .fetch_one(&mut *revoked_scope)
    .await
    .unwrap();
    assert!(absent, "revoked callback cannot add an account");
    revoked_scope.commit().await.unwrap();

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
