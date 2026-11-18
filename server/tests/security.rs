mod common;
use axum::{
    Json, Router,
    body::Body,
    extract::{Path, State},
    http::{Request, StatusCode},
    routing::get,
};
use http_body_util::BodyExt;
use postmere_core::AppState;
use postmere_core::auth::{AuthContext, SessionResponse, hash_password};
use postmere_core::db;
use postmere_core::error::AppError;
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
    token: Option<&str>,
    body: Value,
) -> (StatusCode, Value) {
    let mut builder = Request::builder()
        .method(method)
        .uri(path)
        .header("content-type", "application/json");
    if let Some(token) = token {
        builder = builder.header("authorization", format!("Bearer {token}"));
    }
    let response = app
        .clone()
        .oneshot(builder.body(Body::from(body.to_string())).unwrap())
        .await
        .unwrap();
    assert_eq!(response.headers().get("cache-control").unwrap(), "no-store");
    assert_eq!(
        response.headers().get("x-content-type-options").unwrap(),
        "nosniff"
    );
    let status = response.status();
    let bytes = response.into_body().collect().await.unwrap().to_bytes();
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
    sqlx::query(
        "INSERT INTO workspaces(id,name) VALUES($1,'Security fixture') ON CONFLICT DO NOTHING",
    )
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
    let (status, body) = request(
        app,
        "POST",
        "/v1/auth/login",
        None,
        json!({"email":email,"password":"correct horse test password","workspace_id":workspace}),
    )
    .await;
    assert_eq!(status, StatusCode::OK, "{body}");
    serde_json::from_value(body).unwrap()
}
async fn scoped_account(
    auth: AuthContext,
    State(state): State<AppState>,
    Path(id): Path<Uuid>,
) -> Result<Json<Value>, AppError> {
    let mut tx = auth.begin(&state.pool).await?;
    let email: Option<String> =
        sqlx::query_scalar("SELECT email FROM provider_accounts WHERE id=$1")
            .bind(id)
            .fetch_optional(&mut *tx)
            .await?;
    Ok(Json(
        json!({"email":email.ok_or_else(AppError::not_found)?}),
    ))
}

#[tokio::test]
async fn real_database_authentication_rls_revocation_rotation_and_rate_limits() {
    let url=std::env::var("POSTMERE_TEST_DATABASE_URL").expect("Set POSTMERE_TEST_DATABASE_URL to an isolated non-superuser, NOBYPASSRLS PostgreSQL database");
    let pool = db::connect(&url).await.unwrap();
    db::migrate(&pool).await.unwrap();
    let state = AppState::new(pool.clone(), common::config(url))
        .await
        .unwrap();
    let app = application(
        state.clone(),
        Router::new().route("/test/account/{id}", get(scoped_account)),
    );
    let ws = Uuid::new_v4();
    let other_ws = Uuid::new_v4();
    let email = format!("test-{}@example.test", Uuid::new_v4());
    let email2 = format!("test-{}@example.test", Uuid::new_v4());
    let hash = hash_password(Zeroizing::new("correct horse test password".into()))
        .await
        .unwrap();
    assert!(hash.starts_with("$argon2id$"));
    let user = seed(&pool, ws, &email, &hash).await;
    let user2 = seed(&pool, ws, &email2, &hash).await;
    sqlx::query("INSERT INTO workspaces(id,name) VALUES($1,'Foreign fixture')")
        .bind(other_ws)
        .execute(&pool)
        .await
        .unwrap();
    let session = login(&app, &email, ws).await;
    let session2 = login(&app, &email2, ws).await;
    assert_ne!(session.token, session2.token);
    assert_eq!(session.token.len(), 43);
    assert_eq!(
        request(&app, "GET", "/v1/auth/me", None, Value::Null)
            .await
            .0,
        StatusCode::UNAUTHORIZED
    );
    assert_eq!(
        request(&app, "GET", "/v1/auth/me", Some("forged"), Value::Null)
            .await
            .0,
        StatusCode::UNAUTHORIZED
    );
    assert_eq!(
        request(
            &app,
            "GET",
            "/v1/auth/me",
            Some(&session.token),
            Value::Null
        )
        .await
        .0,
        StatusCode::OK
    );
    let wrong = request(
        &app,
        "POST",
        "/v1/auth/login",
        None,
        json!({"email":email,"password":"incorrect","workspace_id":ws}),
    )
    .await;
    let foreign = request(
        &app,
        "POST",
        "/v1/auth/login",
        None,
        json!({"email":email,"password":"correct horse test password","workspace_id":other_ws}),
    )
    .await;
    assert_eq!(wrong, foreign);
    assert_eq!(wrong.0, StatusCode::UNAUTHORIZED);
    let account = Uuid::new_v4();
    let auth = state.auth.authenticate(&session.token).await.unwrap();
    let encrypted = state
        .crypto
        .seal(ws, account, b"credential fixture")
        .unwrap();
    let mut tx = auth.begin(&pool).await.unwrap();
    sqlx::query("INSERT INTO provider_accounts(id,workspace_id,user_id,provider,email,encrypted_credentials) VALUES($1,$2,$3,'gmail',$4,$5)").bind(account).bind(ws).bind(user).bind(&email).bind(encrypted).execute(&mut *tx).await.unwrap();
    tx.commit().await.unwrap();
    let path = format!("/test/account/{account}");
    assert_eq!(
        request(&app, "GET", &path, Some(&session.token), Value::Null)
            .await
            .0,
        StatusCode::OK
    );
    assert_eq!(
        request(&app, "GET", &path, Some(&session2.token), Value::Null)
            .await
            .0,
        StatusCode::NOT_FOUND,
        "same-workspace peer must not see credentials"
    );
    let no_scope: i64 = sqlx::query_scalar("SELECT count(*) FROM provider_accounts WHERE id=$1")
        .bind(account)
        .fetch_one(&pool)
        .await
        .unwrap();
    assert_eq!(
        no_scope, 0,
        "unset transaction scope must deny access, even for table owner"
    );
    let mut peer_tx = db::scoped_transaction(&pool, ws, user2).await.unwrap();
    let cross_insert=sqlx::query("INSERT INTO provider_accounts(id,workspace_id,user_id,provider,email,encrypted_credentials) VALUES($1,$2,$3,'gmail',$4,$5)").bind(Uuid::new_v4()).bind(ws).bind(user).bind(&email).bind(vec![0u8;40]).execute(&mut *peer_tx).await;
    assert!(
        cross_insert.is_err(),
        "WITH CHECK must reject cross-user writes"
    );
    peer_tx.rollback().await.unwrap();
    let hash_row = sqlx::query("SELECT token_hash FROM sessions WHERE id=$1")
        .bind(session.session_id)
        .fetch_one(&pool)
        .await
        .unwrap();
    let stored: Vec<u8> = hash_row.get("token_hash");
    assert_eq!(stored.len(), 32);
    assert_ne!(stored, session.token.as_bytes());
    let (rotate1, rotate2) = tokio::join!(
        request(
            &app,
            "POST",
            "/v1/auth/rotate",
            Some(&session.token),
            Value::Null
        ),
        request(
            &app,
            "POST",
            "/v1/auth/rotate",
            Some(&session.token),
            Value::Null
        )
    );
    assert!(matches!(
        (rotate1.0, rotate2.0),
        (StatusCode::OK, StatusCode::UNAUTHORIZED) | (StatusCode::UNAUTHORIZED, StatusCode::OK)
    ));
    let rotated: SessionResponse = serde_json::from_value(if rotate1.0 == StatusCode::OK {
        rotate1.1
    } else {
        rotate2.1
    })
    .unwrap();
    assert_eq!(rotated.absolute_expires_at, session.absolute_expires_at);
    assert_eq!(
        request(
            &app,
            "GET",
            "/v1/auth/me",
            Some(&session.token),
            Value::Null
        )
        .await
        .0,
        StatusCode::UNAUTHORIZED
    );
    assert_eq!(
        request(
            &app,
            "POST",
            "/v1/auth/logout",
            Some(&rotated.token),
            Value::Null
        )
        .await
        .0,
        StatusCode::NO_CONTENT
    );
    assert_eq!(
        request(
            &app,
            "GET",
            "/v1/auth/me",
            Some(&rotated.token),
            Value::Null
        )
        .await
        .0,
        StatusCode::UNAUTHORIZED
    );
    sqlx::query("UPDATE memberships SET revoked_at=now() WHERE workspace_id=$1 AND user_id=$2")
        .bind(ws)
        .bind(user2)
        .execute(&pool)
        .await
        .unwrap();
    assert_eq!(
        request(
            &app,
            "GET",
            "/v1/auth/me",
            Some(&session2.token),
            Value::Null
        )
        .await
        .0,
        StatusCode::UNAUTHORIZED
    );
    let session3 = login(&app, &email, ws).await;
    sqlx::query("UPDATE sessions SET created_at=now()-interval '2 days',expires_at=now()-interval '1 second',absolute_expires_at=now()+interval '1 day' WHERE id=$1").bind(session3.session_id).execute(&pool).await.unwrap();
    assert_eq!(
        request(
            &app,
            "GET",
            "/v1/auth/me",
            Some(&session3.token),
            Value::Null
        )
        .await
        .0,
        StatusCode::UNAUTHORIZED
    );
    let session4 = login(&app, &email, ws).await;
    let session5 = login(&app, &email, ws).await;
    assert_eq!(
        request(
            &app,
            "POST",
            "/v1/auth/logout-all",
            Some(&session4.token),
            Value::Null
        )
        .await
        .0,
        StatusCode::NO_CONTENT
    );
    assert!(state.auth.authenticate(&session5.token).await.is_err());
    let bucket = Uuid::new_v4().to_string();
    state.auth.rate_limit("test", &bucket, 2).await.unwrap();
    state.auth.rate_limit("test", &bucket, 2).await.unwrap();
    assert_eq!(
        state
            .auth
            .rate_limit("test", &bucket, 2)
            .await
            .unwrap_err()
            .status,
        StatusCode::TOO_MANY_REQUESTS
    );
    let state2 = AppState::new(pool.clone(), (*state.config).clone())
        .await
        .unwrap();
    assert_eq!(
        state2
            .auth
            .rate_limit("test", &bucket, 2)
            .await
            .unwrap_err()
            .status,
        StatusCode::TOO_MANY_REQUESTS,
        "rate limits must survive process/service recreation"
    );
    sqlx::query("DELETE FROM workspaces WHERE id=ANY($1)")
        .bind(vec![ws, other_ws])
        .execute(&pool)
        .await
        .unwrap();
    sqlx::query("DELETE FROM users WHERE id=ANY($1)")
        .bind(vec![user, user2])
        .execute(&pool)
        .await
        .unwrap();
}
