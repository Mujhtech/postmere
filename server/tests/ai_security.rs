mod common;
use axum::{
    Router,
    body::Body,
    http::{Request, StatusCode},
};
use http_body_util::BodyExt;
use postmere_ai as ai;
use postmere_core::AppState;
use postmere_core::auth::{SessionResponse, hash_password};
use postmere_core::db;
use postmere_server::application;
use serde_json::{Value, json};
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
    let status = response.status();
    let body = response.into_body().collect().await.unwrap().to_bytes();
    (status, serde_json::from_slice(&body).unwrap_or(Value::Null))
}

#[tokio::test]
async fn ai_opt_in_and_retrieval_stay_user_and_workspace_scoped() {
    let url = std::env::var("POSTMERE_TEST_DATABASE_URL")
        .expect("Use the isolated non-superuser test database");
    let pool = db::connect(&url).await.unwrap();
    db::migrate(&pool).await.unwrap();
    let mut config = common::config(url);
    config.ai_api_key = Some("fixture-never-transmitted".into());
    let mut state = AppState::new(pool.clone(), config).await.unwrap();
    // Even an accidental model call is forced onto a closed loopback port.
    state.http = reqwest::Client::builder()
        .no_proxy()
        .resolve("api.openai.com", "127.0.0.1:9".parse().unwrap())
        .timeout(std::time::Duration::from_millis(100))
        .build()
        .unwrap();
    let app = application(state.clone(), ai::router());
    let workspace = Uuid::new_v4();
    let other_workspace = Uuid::new_v4();
    let hash = hash_password(Zeroizing::new("ai fixture secure password".into()))
        .await
        .unwrap();
    let mut sessions = Vec::new();
    let mut users = Vec::new();
    for ws in [workspace, workspace, other_workspace] {
        let user = Uuid::new_v4();
        let email = format!("ai-{user}@example.test");
        users.push(user);
        sqlx::query(
            "INSERT INTO workspaces(id,name) VALUES($1,'AI fixture') ON CONFLICT DO NOTHING",
        )
        .bind(ws)
        .execute(&pool)
        .await
        .unwrap();
        sqlx::query("INSERT INTO users(id,email,password_hash) VALUES($1,$2,$3)")
            .bind(user)
            .bind(&email)
            .bind(&hash)
            .execute(&pool)
            .await
            .unwrap();
        sqlx::query("INSERT INTO memberships(workspace_id,user_id,role) VALUES($1,$2,'member')")
            .bind(ws)
            .bind(user)
            .execute(&pool)
            .await
            .unwrap();
        let (status, value) = request(
            &app,
            "POST",
            "/v1/auth/login",
            None,
            json!({"email":email,"password":"ai fixture secure password","workspace_id":ws}),
        )
        .await;
        assert_eq!(status, StatusCode::OK);
        sessions.push(serde_json::from_value::<SessionResponse>(value).unwrap());
    }
    assert_eq!(
        request(&app, "GET", "/v1/ai/settings", None, Value::Null)
            .await
            .0,
        StatusCode::UNAUTHORIZED
    );
    let before = request(
        &app,
        "GET",
        "/v1/ai/settings",
        Some(&sessions[0].token),
        Value::Null,
    )
    .await;
    assert_eq!(before.1["enabled"], false);
    assert_eq!(
        request(
            &app,
            "POST",
            "/v1/ai/summary",
            Some(&sessions[0].token),
            json!({"message_ids":[Uuid::new_v4()]})
        )
        .await
        .0,
        StatusCode::FORBIDDEN
    );
    let enabled = request(
        &app,
        "PUT",
        "/v1/ai/settings",
        Some(&sessions[0].token),
        json!({"enabled":true,"style_guide":"Brief and friendly"}),
    )
    .await;
    assert_eq!(enabled.0, StatusCode::OK);
    assert_eq!(enabled.1["enabled"], true);
    assert_eq!(
        request(
            &app,
            "GET",
            "/v1/ai/settings",
            Some(&sessions[1].token),
            Value::Null
        )
        .await
        .1["enabled"],
        false
    );
    assert_eq!(
        request(
            &app,
            "GET",
            "/v1/ai/settings",
            Some(&sessions[2].token),
            Value::Null
        )
        .await
        .1["style_guide"],
        ""
    );
    let peer_account = Uuid::new_v4();
    let peer_message = Uuid::new_v4();
    let mut tx = db::scoped_transaction(&pool, workspace, users[1])
        .await
        .unwrap();
    sqlx::query("INSERT INTO provider_accounts(id,workspace_id,user_id,provider,email,encrypted_credentials) VALUES($1,$2,$3,'gmail','fixture@example.test',$4)")
        .bind(peer_account).bind(workspace).bind(users[1]).bind(state.crypto.seal(workspace,peer_account,b"fake").unwrap()).execute(&mut *tx).await.unwrap();
    sqlx::query("INSERT INTO mail_messages(id,workspace_id,user_id,account_id,provider_message_id,provider_thread_id,sent_at,normalized,search_text) VALUES($1,$2,$3,$4,'fixture','fixture',now(),$5,'private project deadline')")
        .bind(peer_message).bind(workspace).bind(users[1]).bind(peer_account).bind(json!({"subject":"Private project","from":{"email":"private@example.test"},"text_body":"Confidential peer data"})).execute(&mut *tx).await.unwrap();
    tx.commit().await.unwrap();
    assert_eq!(
        request(
            &app,
            "POST",
            "/v1/ai/summary",
            Some(&sessions[0].token),
            json!({"message_ids":[peer_message]})
        )
        .await
        .0,
        StatusCode::NOT_FOUND
    );
    assert_eq!(
        request(
            &app,
            "POST",
            "/v1/ai/ask",
            Some(&sessions[0].token),
            json!({"question":"private project deadline","account_ids":[peer_account]})
        )
        .await
        .0,
        StatusCode::NOT_FOUND
    );
    let empty = request(
        &app,
        "POST",
        "/v1/ai/ask",
        Some(&sessions[0].token),
        json!({"question":"private project deadline","account_ids":[]}),
    )
    .await;
    assert_eq!(empty.0, StatusCode::OK);
    assert!(empty.1["sources"].as_array().unwrap().is_empty());
    assert!(!empty.1.to_string().contains("Confidential peer data"));
    // Cached mail remains after disconnect, but it must not silently become AI
    // context when the UI promises to search connected accounts only.
    let inactive_account = Uuid::new_v4();
    let inactive_message = Uuid::new_v4();
    let mut tx = db::scoped_transaction(&pool, workspace, users[0])
        .await
        .unwrap();
    sqlx::query("INSERT INTO provider_accounts(id,workspace_id,user_id,provider,email,encrypted_credentials,disabled_at) VALUES($1,$2,$3,'gmail','inactive@example.test',$4,now())")
        .bind(inactive_account).bind(workspace).bind(users[0]).bind(state.crypto.seal(workspace,inactive_account,b"fake").unwrap()).execute(&mut *tx).await.unwrap();
    sqlx::query("INSERT INTO mail_messages(id,workspace_id,user_id,account_id,provider_message_id,provider_thread_id,sent_at,normalized,search_text) VALUES($1,$2,$3,$4,'inactive','inactive',now(),$5,'private project deadline')")
        .bind(inactive_message).bind(workspace).bind(users[0]).bind(inactive_account).bind(json!({"subject":"Private project","from":{"email":"inactive@example.test"},"text_body":"Disconnected account must not reach AI"})).execute(&mut *tx).await.unwrap();
    tx.commit().await.unwrap();
    for reconnect_required in [false, true] {
        if reconnect_required {
            let mut tx = db::scoped_transaction(&pool, workspace, users[0])
                .await
                .unwrap();
            sqlx::query("UPDATE provider_accounts SET disabled_at=NULL,status='reconnect_required' WHERE id=$1")
                .bind(inactive_account).execute(&mut *tx).await.unwrap();
            tx.commit().await.unwrap();
        }
        let response = request(
            &app,
            "POST",
            "/v1/ai/ask",
            Some(&sessions[0].token),
            json!({"question":"private project deadline","account_ids":[]}),
        )
        .await;
        assert_eq!(
            response.0,
            StatusCode::OK,
            "inactive mail must not cause a model request"
        );
        assert!(response.1["sources"].as_array().unwrap().is_empty());
        assert_eq!(
            request(
                &app,
                "POST",
                "/v1/ai/ask",
                Some(&sessions[0].token),
                json!({"question":"deadline","account_ids":[inactive_account]})
            )
            .await
            .0,
            StatusCode::NOT_FOUND
        );
        assert_eq!(
            request(
                &app,
                "POST",
                "/v1/ai/summary",
                Some(&sessions[0].token),
                json!({"message_ids":[inactive_message]})
            )
            .await
            .0,
            StatusCode::NOT_FOUND
        );
    }
    let no_scope: i64 =
        sqlx::query_scalar("SELECT count(*) FROM ai_preferences WHERE workspace_id=$1")
            .bind(workspace)
            .fetch_one(&pool)
            .await
            .unwrap();
    assert_eq!(no_scope, 0);
    request(
        &app,
        "PUT",
        "/v1/ai/settings",
        Some(&sessions[0].token),
        json!({"enabled":false,"style_guide":""}),
    )
    .await;
    assert_eq!(
        request(
            &app,
            "POST",
            "/v1/ai/ask",
            Some(&sessions[0].token),
            json!({"question":"deadline","account_ids":[]})
        )
        .await
        .0,
        StatusCode::FORBIDDEN
    );
    sqlx::query("DELETE FROM workspaces WHERE id=ANY($1)")
        .bind(vec![workspace, other_workspace])
        .execute(&pool)
        .await
        .unwrap();
    sqlx::query("DELETE FROM users WHERE id=ANY($1)")
        .bind(users)
        .execute(&pool)
        .await
        .unwrap();
}
