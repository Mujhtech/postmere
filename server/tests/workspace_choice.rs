//! Signing in without a workspace ID, choosing among several, and switching.
mod common;
use axum::{
    Router,
    body::Body,
    http::{Request, StatusCode},
};
use base64::{Engine, engine::general_purpose::URL_SAFE_NO_PAD};
use http_body_util::BodyExt;
use postmere_core::AppState;
use postmere_core::auth::hash_password;
use postmere_core::db;
use postmere_server::application;
use serde_json::{Value, json};
use sha2::{Digest, Sha256};
use sqlx::PgPool;
use tower::ServiceExt;
use uuid::Uuid;
use zeroize::Zeroizing;

const PASSWORD: &str = "correct horse test password";

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
    let body = if body.is_null() {
        Body::empty()
    } else {
        Body::from(body.to_string())
    };
    let response = app
        .clone()
        .oneshot(builder.body(body).unwrap())
        .await
        .unwrap();
    let status = response.status();
    let bytes = response.into_body().collect().await.unwrap().to_bytes();
    (
        status,
        serde_json::from_slice(&bytes).unwrap_or(Value::Null),
    )
}

async fn workspace(pool: &PgPool, name: &str) -> Uuid {
    let id = Uuid::new_v4();
    sqlx::query("INSERT INTO workspaces(id,name) VALUES($1,$2)")
        .bind(id)
        .bind(name)
        .execute(pool)
        .await
        .unwrap();
    id
}

async fn member(pool: &PgPool, workspace: Uuid, user: Uuid, role: &str) {
    sqlx::query("INSERT INTO memberships(workspace_id,user_id,role) VALUES($1,$2,$3)")
        .bind(workspace)
        .bind(user)
        .bind(role)
        .execute(pool)
        .await
        .unwrap();
}

async fn user(pool: &PgPool, email: &str, hash: &str) -> Uuid {
    let id = Uuid::new_v4();
    sqlx::query("INSERT INTO users(id,email,password_hash) VALUES($1,$2,$3)")
        .bind(id)
        .bind(email)
        .bind(hash)
        .execute(pool)
        .await
        .unwrap();
    id
}

async fn sessions(pool: &PgPool, user: Uuid) -> i64 {
    sqlx::query_scalar("SELECT count(*) FROM sessions WHERE user_id=$1")
        .bind(user)
        .fetch_one(pool)
        .await
        .unwrap()
}

fn login_body(email: &str, password: &str, workspace: Option<Uuid>) -> Value {
    match workspace {
        Some(id) => json!({"email": email, "password": password, "workspace_id": id}),
        None => json!({"email": email, "password": password}),
    }
}

#[tokio::test]
async fn sign_in_without_workspace_id_choose_list_and_switch() {
    let url = std::env::var("POSTMERE_TEST_DATABASE_URL").expect("Set POSTMERE_TEST_DATABASE_URL to an isolated non-superuser, NOBYPASSRLS PostgreSQL database");
    let pool = db::connect(&url).await.unwrap();
    db::migrate(&pool).await.unwrap();
    let state = AppState::new(pool.clone(), common::config(url))
        .await
        .unwrap();
    let app = application(state, Router::new());
    let hash = hash_password(Zeroizing::new(PASSWORD.into()))
        .await
        .unwrap();

    let beta = workspace(&pool, "Beta fixture").await;
    let alpha = workspace(&pool, "alpha fixture").await;
    let foreign = workspace(&pool, "Foreign fixture").await;
    let email = format!("choose-{}@example.test", Uuid::new_v4());
    let person = user(&pool, &email, &hash).await;
    member(&pool, beta, person, "member").await;

    // One workspace: signed straight in, no ID needed.
    let (status, body) = request(
        &app,
        "POST",
        "/v1/auth/login",
        None,
        login_body(&email, PASSWORD, None),
    )
    .await;
    assert_eq!(status, StatusCode::OK, "{body}");
    assert_eq!(body["workspace_id"], json!(beta));
    assert_eq!(body["role"], "member");
    let beta_token = body["token"].as_str().unwrap().to_owned();

    // Several: the password is checked, then the names come back with no session issued.
    member(&pool, alpha, person, "admin").await;
    let before = sessions(&pool, person).await;
    let (status, body) = request(
        &app,
        "POST",
        "/v1/auth/login",
        None,
        login_body(&email, PASSWORD, None),
    )
    .await;
    assert_eq!(status, StatusCode::OK, "{body}");
    assert_eq!(body["workspace_required"], true);
    assert!(body.get("token").is_none());
    let names: Vec<&str> = body["workspaces"]
        .as_array()
        .unwrap()
        .iter()
        .map(|w| w["name"].as_str().unwrap())
        .collect();
    assert_eq!(
        names,
        ["alpha fixture", "Beta fixture"],
        "sorted by name, case-insensitively"
    );
    assert_eq!(body["workspaces"][0]["role"], "admin");
    assert_eq!(sessions(&pool, person).await, before);

    // A wrong password or unknown address never lists anything.
    let (status, body) = request(
        &app,
        "POST",
        "/v1/auth/login",
        None,
        login_body(&email, "wrong password entirely", None),
    )
    .await;
    assert_eq!(status, StatusCode::UNAUTHORIZED);
    assert!(body.get("workspaces").is_none());
    let (status, _) = request(
        &app,
        "POST",
        "/v1/auth/login",
        None,
        login_body(
            &format!("nobody-{}@example.test", Uuid::new_v4()),
            PASSWORD,
            None,
        ),
    )
    .await;
    assert_eq!(status, StatusCode::UNAUTHORIZED);

    // Naming one still works, and naming one you don't belong to doesn't.
    let (status, body) = request(
        &app,
        "POST",
        "/v1/auth/login",
        None,
        login_body(&email, PASSWORD, Some(alpha)),
    )
    .await;
    assert_eq!(status, StatusCode::OK, "{body}");
    assert_eq!(body["workspace_id"], json!(alpha));
    let (status, _) = request(
        &app,
        "POST",
        "/v1/auth/login",
        None,
        login_body(&email, PASSWORD, Some(foreign)),
    )
    .await;
    assert_eq!(status, StatusCode::UNAUTHORIZED);

    // Listing from a signed-in session.
    let (status, body) = request(
        &app,
        "GET",
        "/v1/auth/workspaces",
        Some(&beta_token),
        Value::Null,
    )
    .await;
    assert_eq!(status, StatusCode::OK, "{body}");
    assert_eq!(body["current"], json!(beta));
    assert_eq!(body["workspaces"].as_array().unwrap().len(), 2);
    let (status, _) = request(&app, "GET", "/v1/auth/workspaces", None, Value::Null).await;
    assert_eq!(status, StatusCode::UNAUTHORIZED);

    // Switching issues a new session there and keeps the current one.
    let (status, body) = request(
        &app,
        "POST",
        "/v1/auth/switch",
        Some(&beta_token),
        json!({"workspace_id": alpha}),
    )
    .await;
    assert_eq!(status, StatusCode::OK, "{body}");
    assert_eq!(body["workspace_id"], json!(alpha));
    assert_eq!(body["role"], "admin");
    assert_eq!(body["persistent"], true);
    let alpha_token = body["token"].as_str().unwrap().to_owned();
    let (status, me) = request(&app, "GET", "/v1/auth/me", Some(&alpha_token), Value::Null).await;
    assert_eq!(status, StatusCode::OK);
    assert_eq!(me["workspace_id"], json!(alpha));
    let (status, me) = request(&app, "GET", "/v1/auth/me", Some(&beta_token), Value::Null).await;
    assert_eq!(status, StatusCode::OK);
    assert_eq!(me["workspace_id"], json!(beta));

    // Not into a workspace you aren't in.
    let (status, _) = request(
        &app,
        "POST",
        "/v1/auth/switch",
        Some(&beta_token),
        json!({"workspace_id": foreign}),
    )
    .await;
    assert_eq!(status, StatusCode::NOT_FOUND);
    let (status, _) = request(
        &app,
        "POST",
        "/v1/auth/switch",
        Some(&beta_token),
        json!({"workspace_id": Uuid::new_v4()}),
    )
    .await;
    assert_eq!(status, StatusCode::NOT_FOUND);

    // An assistant's browser sign-in can't hop workspaces.
    let mut random = [0u8; 32];
    getrandom::fill(&mut random).unwrap();
    let token = URL_SAFE_NO_PAD.encode(random);
    sqlx::query("INSERT INTO sessions(id,workspace_id,user_id,token_hash,expires_at,absolute_expires_at,kind) VALUES($1,$2,$3,$4,now()+interval '1 hour',now()+interval '1 day','mcp_browser')")
        .bind(Uuid::new_v4()).bind(beta).bind(person).bind(Sha256::digest(token.as_bytes()).as_slice())
        .execute(&pool).await.unwrap();
    let (status, _) = request(
        &app,
        "POST",
        "/v1/auth/switch",
        Some(&token),
        json!({"workspace_id": alpha}),
    )
    .await;
    assert_eq!(status, StatusCode::FORBIDDEN);

    // Revoked memberships and disabled workspaces drop out of every path.
    sqlx::query("UPDATE memberships SET revoked_at=now() WHERE workspace_id=$1 AND user_id=$2")
        .bind(alpha)
        .bind(person)
        .execute(&pool)
        .await
        .unwrap();
    let (status, _) = request(
        &app,
        "POST",
        "/v1/auth/switch",
        Some(&beta_token),
        json!({"workspace_id": alpha}),
    )
    .await;
    assert_eq!(status, StatusCode::NOT_FOUND);
    let (status, _) = request(&app, "GET", "/v1/auth/me", Some(&alpha_token), Value::Null).await;
    assert_eq!(status, StatusCode::UNAUTHORIZED);
    let (status, body) = request(
        &app,
        "POST",
        "/v1/auth/login",
        None,
        login_body(&email, PASSWORD, None),
    )
    .await;
    assert_eq!(status, StatusCode::OK, "{body}");
    assert_eq!(
        body["workspace_id"],
        json!(beta),
        "back to one workspace: signed straight in"
    );
    let (_, body) = request(
        &app,
        "GET",
        "/v1/auth/workspaces",
        Some(&beta_token),
        Value::Null,
    )
    .await;
    assert_eq!(body["workspaces"].as_array().unwrap().len(), 1);

    sqlx::query("UPDATE workspaces SET disabled_at=now() WHERE id=$1")
        .bind(beta)
        .execute(&pool)
        .await
        .unwrap();
    let (status, body) = request(
        &app,
        "POST",
        "/v1/auth/login",
        None,
        login_body(&email, PASSWORD, None),
    )
    .await;
    assert_eq!(
        status,
        StatusCode::UNAUTHORIZED,
        "no workspace left looks like bad credentials: {body}"
    );
    assert!(body.get("workspaces").is_none());
}
