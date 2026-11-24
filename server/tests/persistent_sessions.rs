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
    auth::{LoginRequest, SessionResponse, hash_password},
    db,
};
use postmere_server::application;
use serde_json::{Value, json};
use sqlx::{PgPool, Row};
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
    let body = response.into_body().collect().await.unwrap().to_bytes();
    (status, serde_json::from_slice(&body).unwrap_or(Value::Null))
}

async fn seed(pool: &PgPool, password_hash: &str) -> (Uuid, Uuid, String) {
    let workspace = Uuid::new_v4();
    let user = Uuid::new_v4();
    let email = format!("persistent-{user}@example.test");
    sqlx::query("INSERT INTO users(id,email,password_hash) VALUES($1,$2,$3)")
        .bind(user)
        .bind(&email)
        .bind(password_hash)
        .execute(pool)
        .await
        .unwrap();
    sqlx::query("INSERT INTO workspaces(id,name) VALUES($1,'Persistent session fixture')")
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
    (workspace, user, email)
}

#[tokio::test]
async fn native_sign_in_survives_age_restart_and_rotation_until_revoked() {
    let url = std::env::var("POSTMERE_TEST_DATABASE_URL")
        .expect("Set the isolated non-bypass PostgreSQL test database URL");
    let pool = db::connect(&url).await.unwrap();
    db::migrate(&pool).await.unwrap();
    let config = common::config(url);
    let state = AppState::new(pool.clone(), config.clone()).await.unwrap();
    let app = application(state.clone(), Router::new());
    let hash = hash_password(Zeroizing::new("persistent session fixture password".into()))
        .await
        .unwrap();
    let (workspace, user, email) = seed(&pool, &hash).await;
    let (status, body) = request(
        &app,
        "POST",
        "/v1/auth/login",
        "",
        json!({
            "email":email,"password":"persistent session fixture password","workspace_id":workspace
        }),
    )
    .await;
    assert_eq!(status, StatusCode::OK, "{body}");
    assert!(body["expires_at"].is_null() && body["absolute_expires_at"].is_null());
    assert_eq!(body["persistent"], true);
    let session: SessionResponse = serde_json::from_value(body).unwrap();

    for days in [2_i64, 45, 400] {
        sqlx::query("UPDATE sessions SET created_at=$1 WHERE id=$2")
            .bind(Utc::now() - Duration::days(days))
            .bind(session.session_id)
            .execute(&pool)
            .await
            .unwrap();
        let restarted = AppState::new(pool.clone(), config.clone()).await.unwrap();
        let auth = restarted.auth.authenticate(&session.token).await.unwrap();
        auth.begin_authorized(&pool)
            .await
            .unwrap()
            .commit()
            .await
            .unwrap();
        let app = application(restarted, Router::new());
        let (status, identity) =
            request(&app, "GET", "/v1/auth/me", &session.token, Value::Null).await;
        assert_eq!(status, StatusCode::OK, "{days}-day session: {identity}");
        assert_eq!(identity["session_id"], session.session_id.to_string());
        assert_eq!(identity["persistent"], true);
        assert!(identity["expires_at"].is_null() && identity["absolute_expires_at"].is_null());
    }

    let (status, body) =
        request(&app, "POST", "/v1/auth/rotate", &session.token, Value::Null).await;
    assert_eq!(status, StatusCode::OK, "{body}");
    let rotated: SessionResponse = serde_json::from_value(body).unwrap();
    assert!(
        rotated.persistent && rotated.expires_at.is_none() && rotated.absolute_expires_at.is_none()
    );
    assert!(state.auth.authenticate(&session.token).await.is_err());
    assert!(state.auth.authenticate(&rotated.token).await.is_ok());

    // Persistent credentials still obey every live identity revocation check.
    for statement in [
        "UPDATE users SET disabled_at=clock_timestamp() WHERE id=$1",
        "UPDATE memberships SET revoked_at=clock_timestamp() WHERE user_id=$1",
    ] {
        sqlx::query(statement)
            .bind(user)
            .execute(&pool)
            .await
            .unwrap();
        assert!(state.auth.authenticate(&rotated.token).await.is_err());
        sqlx::query("UPDATE users SET disabled_at=NULL WHERE id=$1")
            .bind(user)
            .execute(&pool)
            .await
            .unwrap();
        sqlx::query("UPDATE memberships SET revoked_at=NULL WHERE user_id=$1")
            .bind(user)
            .execute(&pool)
            .await
            .unwrap();
    }
    sqlx::query("UPDATE workspaces SET disabled_at=clock_timestamp() WHERE id=$1")
        .bind(workspace)
        .execute(&pool)
        .await
        .unwrap();
    assert!(state.auth.authenticate(&rotated.token).await.is_err());
    sqlx::query("UPDATE workspaces SET disabled_at=NULL WHERE id=$1")
        .bind(workspace)
        .execute(&pool)
        .await
        .unwrap();
    assert_eq!(
        request(&app, "POST", "/v1/auth/logout", &rotated.token, Value::Null)
            .await
            .0,
        StatusCode::NO_CONTENT
    );
    assert!(state.auth.authenticate(&rotated.token).await.is_err());

    // Browser/OAuth sign-in and rotation retain their bounded lifetime.
    let browser = state
        .auth
        .login_browser(
            LoginRequest {
                email: email.clone(),
                password: "persistent session fixture password".into(),
                workspace_id: Some(workspace),
            },
            &Uuid::new_v4().to_string(),
        )
        .await
        .unwrap();
    assert!(!browser.persistent);
    assert!(browser.expires_at.is_some() && browser.absolute_expires_at.is_some());
    let (status, body) =
        request(&app, "POST", "/v1/auth/rotate", &browser.token, Value::Null).await;
    assert_eq!(status, StatusCode::OK, "{body}");
    let browser_rotated: SessionResponse = serde_json::from_value(body).unwrap();
    assert!(!browser_rotated.persistent);
    assert_eq!(
        browser_rotated.absolute_expires_at,
        browser.absolute_expires_at
    );
    sqlx::query("UPDATE sessions SET created_at=clock_timestamp()-interval '2 days',expires_at=clock_timestamp()-interval '1 second' WHERE id=$1")
        .bind(browser_rotated.session_id).execute(&pool).await.unwrap();
    assert!(
        state
            .auth
            .authenticate(&browser_rotated.token)
            .await
            .is_err()
    );
    assert_eq!(
        request(
            &app,
            "POST",
            "/v1/auth/rotate",
            &browser_rotated.token,
            Value::Null
        )
        .await
        .0,
        StatusCode::UNAUTHORIZED
    );

    sqlx::query("DELETE FROM workspaces WHERE id=$1")
        .bind(workspace)
        .execute(&pool)
        .await
        .unwrap();
    sqlx::query("DELETE FROM users WHERE id=$1")
        .bind(user)
        .execute(&pool)
        .await
        .unwrap();
}

#[tokio::test]
async fn migration_upgrades_only_active_native_sessions_without_reviving_access() {
    let url = std::env::var("POSTMERE_TEST_DATABASE_URL")
        .expect("Set the isolated non-bypass PostgreSQL test database URL");
    let pool = db::connect(&url).await.unwrap();
    let mut tx = pool.begin().await.unwrap();
    // Execute the real pre-upgrade schema and migration in a private schema,
    // so this regression also runs after the shared test DB has been migrated.
    let schema = format!("persistent_fixture_{}", Uuid::new_v4().simple());
    // The identifier contains only a fixed prefix and hex UUID generated here.
    sqlx::query(sqlx::AssertSqlSafe(format!("CREATE SCHEMA {schema}")))
        .execute(&mut *tx)
        .await
        .unwrap();
    sqlx::query("SELECT set_config('search_path',$1,true)")
        .bind(&schema)
        .execute(&mut *tx)
        .await
        .unwrap();
    sqlx::raw_sql(include_str!("../migrations/0001_foundation.sql"))
        .execute(&mut *tx)
        .await
        .unwrap();
    sqlx::raw_sql(include_str!("../migrations/0007_mcp_auth.sql"))
        .execute(&mut *tx)
        .await
        .unwrap();
    sqlx::query("INSERT INTO mcp_oauth_clients(id,name,redirect_uris,auth_method) VALUES('fixture','Fixture',ARRAY['https://example.test/callback'],'none')")
        .execute(&mut *tx).await.unwrap();
    let mut fixtures = vec![];
    for (index, kind) in [
        "native",
        "expired",
        "revoked",
        "replaced",
        "browser",
        "grant",
        "disabled_user",
        "revoked_member",
        "disabled_workspace",
    ]
    .into_iter()
    .enumerate()
    {
        let workspace = Uuid::new_v4();
        let user = Uuid::new_v4();
        let session = Uuid::new_v4();
        sqlx::query("INSERT INTO users(id,email,password_hash) VALUES($1,$2,'fixture-hash')")
            .bind(user)
            .bind(format!("{user}@example.test"))
            .execute(&mut *tx)
            .await
            .unwrap();
        sqlx::query("INSERT INTO workspaces(id,name) VALUES($1,'Migration fixture')")
            .bind(workspace)
            .execute(&mut *tx)
            .await
            .unwrap();
        sqlx::query("INSERT INTO memberships(workspace_id,user_id,role) VALUES($1,$2,'owner')")
            .bind(workspace)
            .bind(user)
            .execute(&mut *tx)
            .await
            .unwrap();
        sqlx::query("INSERT INTO sessions(id,workspace_id,user_id,token_hash,created_at,expires_at,absolute_expires_at) VALUES($1,$2,$3,$4,clock_timestamp()-interval '2 days',clock_timestamp()+interval '1 day',clock_timestamp()+interval '30 days')")
            .bind(session).bind(workspace).bind(user).bind(vec![index as u8;32]).execute(&mut *tx).await.unwrap();
        match kind {
            "expired" => {
                sqlx::query("UPDATE sessions SET expires_at=clock_timestamp()-interval '1 second' WHERE id=$1").bind(session).execute(&mut *tx).await.unwrap();
            }
            "revoked" => {
                sqlx::query("UPDATE sessions SET revoked_at=clock_timestamp() WHERE id=$1")
                    .bind(session)
                    .execute(&mut *tx)
                    .await
                    .unwrap();
            }
            "replaced" => {
                sqlx::query("UPDATE sessions SET replaced_by=id WHERE id=$1")
                    .bind(session)
                    .execute(&mut *tx)
                    .await
                    .unwrap();
            }
            "browser" => {
                sqlx::query("INSERT INTO mcp_browser_sessions(token_hash,session_id,csrf_token,expires_at) VALUES($1,$2,$3,clock_timestamp()+interval '1 day')").bind(vec![index as u8;32]).bind(session).bind("x".repeat(43)).execute(&mut *tx).await.unwrap();
            }
            "grant" => {
                sqlx::query("INSERT INTO mcp_oauth_grants(id,session_id,client_id,resource,scopes,expires_at) VALUES($1,$2,'fixture','https://example.test/mcp',ARRAY['mail.read'],clock_timestamp()+interval '1 day')").bind(Uuid::new_v4()).bind(session).execute(&mut *tx).await.unwrap();
            }
            "disabled_user" => {
                sqlx::query("UPDATE users SET disabled_at=clock_timestamp() WHERE id=$1")
                    .bind(user)
                    .execute(&mut *tx)
                    .await
                    .unwrap();
            }
            "revoked_member" => {
                sqlx::query("UPDATE memberships SET revoked_at=clock_timestamp() WHERE user_id=$1")
                    .bind(user)
                    .execute(&mut *tx)
                    .await
                    .unwrap();
            }
            "disabled_workspace" => {
                sqlx::query("UPDATE workspaces SET disabled_at=clock_timestamp() WHERE id=$1")
                    .bind(workspace)
                    .execute(&mut *tx)
                    .await
                    .unwrap();
            }
            _ => {}
        }
        fixtures.push((kind, session));
    }
    sqlx::raw_sql(include_str!(
        "../migrations/0011_persistent_native_sessions.sql"
    ))
    .execute(&mut *tx)
    .await
    .unwrap();
    for (kind, session) in &fixtures {
        let row = sqlx::query("SELECT expires_at IS NULL AS persistent,absolute_expires_at IS NULL AS absolute_persistent FROM sessions WHERE id=$1")
            .bind(session).fetch_one(&mut *tx).await.unwrap();
        assert_eq!(
            row.get::<bool, _>("persistent"),
            *kind == "native",
            "{kind}"
        );
        assert_eq!(
            row.get::<bool, _>("absolute_persistent"),
            *kind == "native",
            "{kind}"
        );
    }
    // Both dates must be absent together; finite dates must remain valid.
    for statement in [
        "UPDATE sessions SET expires_at=clock_timestamp()+interval '1 day' WHERE id=$1",
        "UPDATE sessions SET absolute_expires_at=clock_timestamp()+interval '1 day' WHERE id=$1",
        "UPDATE sessions SET expires_at='infinity',absolute_expires_at='infinity' WHERE id=$1",
        "UPDATE sessions SET expires_at=created_at,absolute_expires_at=clock_timestamp()+interval '1 day' WHERE id=$1",
    ] {
        sqlx::query("SAVEPOINT invalid_lifetime")
            .execute(&mut *tx)
            .await
            .unwrap();
        assert!(
            sqlx::query(statement)
                .bind(fixtures[0].1)
                .execute(&mut *tx)
                .await
                .is_err()
        );
        sqlx::query("ROLLBACK TO SAVEPOINT invalid_lifetime")
            .execute(&mut *tx)
            .await
            .unwrap();
    }
    tx.rollback().await.unwrap();
}

#[tokio::test]
async fn bounded_rotation_that_expires_while_transferring_push_registration_rolls_back() {
    let url = std::env::var("POSTMERE_TEST_DATABASE_URL")
        .expect("Set the isolated non-bypass PostgreSQL test database URL");
    let pool = db::connect(&url).await.unwrap();
    db::migrate(&pool).await.unwrap();
    let state = AppState::new(pool.clone(), common::config(url))
        .await
        .unwrap();
    let app = application(state.clone(), Router::new());
    let hash = hash_password(Zeroizing::new("persistent session fixture password".into()))
        .await
        .unwrap();
    let (workspace, user, email) = seed(&pool, &hash).await;
    let session = state
        .auth
        .login_browser(
            LoginRequest {
                email,
                password: "persistent session fixture password".into(),
                workspace_id: Some(workspace),
            },
            &Uuid::new_v4().to_string(),
        )
        .await
        .unwrap();
    let device = Uuid::new_v4();
    let mut setup = db::scoped_transaction(&pool, workspace, user)
        .await
        .unwrap();
    sqlx::query("INSERT INTO push_devices(id,installation_id,workspace_id,user_id,session_id,encrypted_token,token_hash,environment,enabled) VALUES($1,$2,$3,$4,$5,$6,$7,'sandbox',true)")
        .bind(device).bind(Uuid::new_v4()).bind(workspace).bind(user).bind(session.session_id)
        .bind(vec![0_u8;32]).bind(vec![1_u8;32]).execute(&mut *setup).await.unwrap();
    setup.commit().await.unwrap();
    let mut blocker = db::scoped_transaction(&pool, workspace, user)
        .await
        .unwrap();
    sqlx::query("SELECT id FROM push_devices WHERE id=$1 FOR UPDATE")
        .bind(device)
        .fetch_one(&mut *blocker)
        .await
        .unwrap();
    let blocker_pid: i32 = sqlx::query_scalar("SELECT pg_backend_pid()")
        .fetch_one(&mut *blocker)
        .await
        .unwrap();
    sqlx::query(
        "UPDATE sessions SET expires_at=clock_timestamp()+interval '2 seconds' WHERE id=$1",
    )
    .bind(session.session_id)
    .execute(&pool)
    .await
    .unwrap();
    let rotate_token = session.token.clone();
    let rotation = tokio::spawn(async move {
        request(&app, "POST", "/v1/auth/rotate", &rotate_token, Value::Null).await
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
    .expect("rotation must reach the held push device row");
    tokio::time::sleep(std::time::Duration::from_secs(2)).await;
    blocker.commit().await.unwrap();
    assert_eq!(rotation.await.unwrap().0, StatusCode::UNAUTHORIZED);
    let mut verify = db::scoped_transaction(&pool, workspace, user)
        .await
        .unwrap();
    let binding: Uuid = sqlx::query_scalar("SELECT session_id FROM push_devices WHERE id=$1")
        .bind(device)
        .fetch_one(&mut *verify)
        .await
        .unwrap();
    assert_eq!(
        binding, session.session_id,
        "failed rotation must roll back device transfer"
    );
    let count: i64 = sqlx::query_scalar("SELECT count(*) FROM sessions WHERE user_id=$1")
        .bind(user)
        .fetch_one(&mut *verify)
        .await
        .unwrap();
    assert_eq!(
        count, 1,
        "failed rotation must not leave a replacement credential"
    );
    let untouched: bool = sqlx::query_scalar(
        "SELECT revoked_at IS NULL AND replaced_by IS NULL FROM sessions WHERE id=$1",
    )
    .bind(session.session_id)
    .fetch_one(&mut *verify)
    .await
    .unwrap();
    assert!(untouched);
    verify.commit().await.unwrap();
    sqlx::query("DELETE FROM workspaces WHERE id=$1")
        .bind(workspace)
        .execute(&pool)
        .await
        .unwrap();
    sqlx::query("DELETE FROM users WHERE id=$1")
        .bind(user)
        .execute(&pool)
        .await
        .unwrap();
}

#[tokio::test]
async fn mcp_migration_preserves_active_refresh_without_reviving_invalid_credentials() {
    let url = std::env::var("POSTMERE_TEST_DATABASE_URL").unwrap();
    let pool = db::connect(&url).await.unwrap();
    let mut tx = pool.begin().await.unwrap();
    let schema = format!("mcp_migration_{}", Uuid::new_v4().simple());
    sqlx::query(sqlx::AssertSqlSafe(format!("CREATE SCHEMA {schema}")))
        .execute(&mut *tx)
        .await
        .unwrap();
    sqlx::query("SELECT set_config('search_path',$1,true)")
        .bind(&schema)
        .execute(&mut *tx)
        .await
        .unwrap();
    for schema in [
        include_str!("../migrations/0001_foundation.sql"),
        include_str!("../migrations/0007_mcp_auth.sql"),
        include_str!("../migrations/0011_persistent_native_sessions.sql"),
    ] {
        sqlx::raw_sql(schema).execute(&mut *tx).await.unwrap();
    }
    sqlx::query("INSERT INTO mcp_oauth_clients(id,name,redirect_uris,auth_method) VALUES('fixture','Fixture',ARRAY['https://example.test/callback'],'none')").execute(&mut *tx).await.unwrap();
    let mut fixtures = vec![];
    for (index, kind) in [
        "active",
        "expired_grant",
        "revoked_grant",
        "expired_session",
        "revoked_session",
        "disabled_user",
        "revoked_member",
        "disabled_workspace",
        "replaced_session",
    ]
    .into_iter()
    .enumerate()
    {
        let user = Uuid::new_v4();
        let workspace = Uuid::new_v4();
        let session = Uuid::new_v4();
        let grant = Uuid::new_v4();
        sqlx::query("INSERT INTO users(id,email,password_hash) VALUES($1,$2,'unused')")
            .bind(user)
            .bind(format!("{user}@example.test"))
            .execute(&mut *tx)
            .await
            .unwrap();
        sqlx::query("INSERT INTO workspaces(id,name) VALUES($1,'MCP migration')")
            .bind(workspace)
            .execute(&mut *tx)
            .await
            .unwrap();
        sqlx::query("INSERT INTO memberships(user_id,workspace_id,role) VALUES($1,$2,'owner')")
            .bind(user)
            .bind(workspace)
            .execute(&mut *tx)
            .await
            .unwrap();
        sqlx::query("INSERT INTO sessions(id,user_id,workspace_id,token_hash,created_at,expires_at,absolute_expires_at) VALUES($1,$2,$3,$4,now()-interval '2 days',now()+interval '1 day',now()+interval '30 days')").bind(session).bind(user).bind(workspace).bind(vec![index as u8;32]).execute(&mut *tx).await.unwrap();
        sqlx::query("INSERT INTO mcp_browser_sessions(token_hash,session_id,csrf_token,expires_at) VALUES($1,$2,$3,now()+interval '1 day')").bind(vec![index as u8;32]).bind(session).bind("x".repeat(43)).execute(&mut *tx).await.unwrap();
        sqlx::query("INSERT INTO mcp_oauth_grants(id,session_id,client_id,resource,scopes,expires_at) VALUES($1,$2,'fixture','https://example.test/mcp',ARRAY['mail:read'],now()+interval '1 day')").bind(grant).bind(session).execute(&mut *tx).await.unwrap();
        for token in 0..3_u8 {
            let hash = vec![(index * 3) as u8 + token; 32];
            sqlx::query("INSERT INTO mcp_refresh_tokens(token_hash,grant_id,expires_at,used_at) VALUES($1,$2,CASE WHEN $3=1 THEN now()-interval '1 second' ELSE now()+interval '1 day' END, CASE WHEN $3=2 THEN now() ELSE NULL END)").bind(hash).bind(grant).bind(i32::from(token)).execute(&mut *tx).await.unwrap();
        }
        let sql = match kind {
            "expired_grant" => {
                "UPDATE mcp_oauth_grants SET expires_at=now()-interval '1 second' WHERE id=$1"
            }
            "revoked_grant" => "UPDATE mcp_oauth_grants SET revoked_at=now() WHERE id=$1",
            "expired_session" => {
                "UPDATE sessions SET expires_at=now()-interval '1 second' WHERE id=$1"
            }
            "revoked_session" => "UPDATE sessions SET revoked_at=now() WHERE id=$1",
            "replaced_session" => "UPDATE sessions SET replaced_by=id WHERE id=$1",
            "disabled_user" => "UPDATE users SET disabled_at=now() WHERE id=$1",
            "revoked_member" => "UPDATE memberships SET revoked_at=now() WHERE user_id=$1",
            "disabled_workspace" => "UPDATE workspaces SET disabled_at=now() WHERE id=$1",
            _ => "SELECT $1::uuid",
        };
        let id = if kind.ends_with("grant") {
            grant
        } else if ["disabled_user", "revoked_member"].contains(&kind) {
            user
        } else if kind == "disabled_workspace" {
            workspace
        } else {
            session
        };
        sqlx::query(sql).bind(id).execute(&mut *tx).await.unwrap();
        fixtures.push((kind, session, grant, index));
    }
    sqlx::raw_sql(include_str!("../migrations/0013_persistent_mcp.sql"))
        .execute(&mut *tx)
        .await
        .unwrap();
    for (kind, session, grant, index) in fixtures {
        let row=sqlx::query("SELECT g.session_id,g.expires_at IS NULL AS persistent,s.kind,s.expires_at IS NULL AS session_persistent FROM mcp_oauth_grants g JOIN sessions s ON s.id=g.session_id WHERE g.id=$1").bind(grant).fetch_one(&mut *tx).await.unwrap();
        assert_eq!(row.get::<bool, _>("persistent"), kind == "active", "{kind}");
        assert_eq!(
            row.get::<bool, _>("session_persistent"),
            kind == "active",
            "{kind}"
        );
        assert_eq!(
            row.get::<Uuid, _>("session_id") == session,
            kind != "active",
            "{kind}"
        );
        for token in 0..3_u8 {
            let persistent: bool = sqlx::query_scalar(
                "SELECT expires_at IS NULL FROM mcp_refresh_tokens WHERE token_hash=$1",
            )
            .bind(vec![(index * 3) as u8 + token; 32])
            .fetch_one(&mut *tx)
            .await
            .unwrap();
            assert_eq!(
                persistent,
                kind == "active" && token == 0,
                "{kind}, token {token}"
            );
        }
        let browser_persistent: bool =
            sqlx::query_scalar("SELECT expires_at IS NULL FROM sessions WHERE id=$1")
                .bind(session)
                .fetch_one(&mut *tx)
                .await
                .unwrap();
        assert!(
            !browser_persistent,
            "Browser approval lifetime stays bounded"
        );
    }
    tx.rollback().await.unwrap();
}
