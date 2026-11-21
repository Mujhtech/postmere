mod common;
use axum::{
    body::Body,
    http::{Request, StatusCode},
};
use base64::{Engine, engine::general_purpose::URL_SAFE_NO_PAD};
use http_body_util::BodyExt;
use postmere_core::AppState;
use postmere_core::auth::AuthContext;
use postmere_core::db;
use postmere_server::application;
use postmere_unsubscribe as unsubscribe;
use serde_json::{Value, json};
use sha2::{Digest, Sha256};
use tower::ServiceExt;
use uuid::Uuid;

#[tokio::test]
async fn unsubscribe_preview_and_preflight_are_authenticated_scoped_and_make_no_sender_request() {
    let url = std::env::var("POSTMERE_TEST_DATABASE_URL")
        .expect("Set POSTMERE_TEST_DATABASE_URL to an isolated NOBYPASSRLS database");
    let pool = db::connect(&url).await.unwrap();
    db::migrate(&pool).await.unwrap();
    let state = AppState::new(pool.clone(), common::config(url))
        .await
        .unwrap();
    let app = application(state.clone(), unsubscribe::router());
    let ws = Uuid::new_v4();
    let user = Uuid::new_v4();
    let session = Uuid::new_v4();
    let other = Uuid::new_v4();
    let other_session = Uuid::new_v4();
    let account = Uuid::new_v4();
    let message = Uuid::new_v4();
    let email = format!("unsubscribe-{user}@example.test");
    sqlx::query("INSERT INTO workspaces(id,name)VALUES($1,'Unsubscribe fixture')")
        .bind(ws)
        .execute(&pool)
        .await
        .unwrap();
    let token = URL_SAFE_NO_PAD
        .encode([user.as_bytes().as_slice(), session.as_bytes().as_slice()].concat());
    let other_token = URL_SAFE_NO_PAD.encode(
        [
            other.as_bytes().as_slice(),
            other_session.as_bytes().as_slice(),
        ]
        .concat(),
    );
    for (id, session, email, token) in [
        (user, session, email.clone(), token.clone()),
        (
            other,
            other_session,
            format!("unsubscribe-{other}@example.test"),
            other_token.clone(),
        ),
    ] {
        sqlx::query("INSERT INTO users(id,email,password_hash)VALUES($1,$2,'unused')")
            .bind(id)
            .bind(email)
            .execute(&pool)
            .await
            .unwrap();
        sqlx::query("INSERT INTO memberships(workspace_id,user_id,role)VALUES($1,$2,'member')")
            .bind(ws)
            .bind(id)
            .execute(&pool)
            .await
            .unwrap();
        sqlx::query("INSERT INTO sessions(id,workspace_id,user_id,token_hash,expires_at,absolute_expires_at)VALUES($1,$2,$3,$4,now()+interval '1 day',now()+interval '30 days')").bind(session).bind(ws).bind(id).bind(Sha256::digest(token.as_bytes()).as_slice()).execute(&pool).await.unwrap();
    }
    let auth = AuthContext {
        assistant: false,
        user_id: user,
        workspace_id: ws,
        session_id: session,
        role: "member".into(),
    };
    let mut tx = auth.begin(&pool).await.unwrap();
    sqlx::query("INSERT INTO provider_accounts(id,workspace_id,user_id,provider,email,encrypted_credentials)VALUES($1,$2,$3,'gmail',$4,$5)").bind(account).bind(ws).bind(user).bind(email).bind(state.crypto.seal(ws,account,b"not used by preview").unwrap()).execute(&mut *tx).await.unwrap();
    let mut mail = json!({"id":message,"account_id":account,"provider_message_id":"fixture","provider_thread_id":"fixture","subject":"Newsletter","from":{"name":null,"email":"news@example.com"},"to":[],"cc":[],"bcc":[],"text_body":"","html_body":null,"preview":"","sent_at":"2026-11-17T00:00:00Z","is_read":true,"is_starred":false,"mailbox":"inbox","provider_labels":["INBOX"],"attachments":[],"list_unsubscribe":["<https://lists.example.com/unsubscribe?opaque=fixture>"],"list_unsubscribe_post":["List-Unsubscribe=One-Click"],"authentication_results":["mx.google.com; dkim=pass header.i=@example.com header.s=mail header.b=abcdefgh"],"dkim_signatures":["v=1; a=rsa-sha256; d=example.com; s=mail; h=from:subject:list-unsubscribe:list-unsubscribe-post; b=abcdefgh0123456789; bh=fixture"]});
    sqlx::query("INSERT INTO mail_messages(id,workspace_id,user_id,account_id,provider_message_id,provider_thread_id,sent_at,normalized,search_text)VALUES($1,$2,$3,$4,'fixture','fixture',now(),$5,'newsletter')").bind(message).bind(ws).bind(user).bind(account).bind(&mail).execute(&mut *tx).await.unwrap();
    tx.commit().await.unwrap();
    let path = format!("/v1/mail/messages/{message}/unsubscribe");
    for (method, token, body, expected) in [
        ("GET", None, Value::Null, StatusCode::UNAUTHORIZED),
        (
            "GET",
            Some(other_token.as_str()),
            Value::Null,
            StatusCode::NOT_FOUND,
        ),
        (
            "POST",
            Some(other_token.as_str()),
            json!({"expected_url":"https://lists.example.com/unsubscribe?opaque=fixture"}),
            StatusCode::NOT_FOUND,
        ),
        (
            "POST",
            Some(token.as_str()),
            json!({"expected_url":"https://attacker.example.com/"}),
            StatusCode::BAD_REQUEST,
        ),
    ] {
        let mut request = Request::builder()
            .method(method)
            .uri(&path)
            .header("content-type", "application/json");
        if let Some(token) = token {
            request = request.header("authorization", format!("Bearer {token}"));
        }
        let result = app
            .clone()
            .oneshot(request.body(Body::from(body.to_string())).unwrap())
            .await
            .unwrap();
        assert_eq!(result.status(), expected);
    }
    let result = app
        .clone()
        .oneshot(
            Request::builder()
                .uri(&path)
                .header("authorization", format!("Bearer {token}"))
                .body(Body::empty())
                .unwrap(),
        )
        .await
        .unwrap();
    assert_eq!(result.status(), StatusCode::OK);
    let body: Value =
        serde_json::from_slice(&result.into_body().collect().await.unwrap().to_bytes()).unwrap();
    assert!(
        body["one_click_url"].is_null(),
        "Forged Authentication-Results must not offer one-click"
    );
    assert!(body["reason"].as_str().unwrap().contains("signature"));
    mail["dkim_signatures"] = json!([]);
    let mut tx = auth.begin(&pool).await.unwrap();
    sqlx::query("UPDATE mail_messages SET normalized=$1 WHERE id=$2")
        .bind(mail)
        .bind(message)
        .execute(&mut *tx)
        .await
        .unwrap();
    tx.commit().await.unwrap();
    let result = app
        .clone()
        .oneshot(
            Request::builder()
                .method("POST")
                .uri(&path)
                .header("authorization", format!("Bearer {token}"))
                .header("content-type", "application/json")
                .body(Body::from(
                    json!({"expected_url":"https://lists.example.com/unsubscribe?opaque=fixture"})
                        .to_string(),
                ))
                .unwrap(),
        )
        .await
        .unwrap();
    assert_eq!(
        result.status(),
        StatusCode::BAD_REQUEST,
        "unsigned mail must fail before decrypting invalid fixture credentials or sending requests"
    );
    let mut tx = auth.begin(&pool).await.unwrap();
    sqlx::query("UPDATE provider_accounts SET provider='microsoft' WHERE id=$1")
        .bind(account)
        .execute(&mut *tx)
        .await
        .unwrap();
    tx.commit().await.unwrap();
    let result = app
        .clone()
        .oneshot(
            Request::builder()
                .uri(&path)
                .header("authorization", format!("Bearer {token}"))
                .body(Body::empty())
                .unwrap(),
        )
        .await
        .unwrap();
    let body: Value =
        serde_json::from_slice(&result.into_body().collect().await.unwrap().to_bytes()).unwrap();
    assert!(body["one_click_url"].is_null());
    assert!(body["reason"].as_str().unwrap().contains("signature"));
    sqlx::query("DELETE FROM workspaces WHERE id=$1")
        .bind(ws)
        .execute(&pool)
        .await
        .unwrap();
    sqlx::query("DELETE FROM users WHERE id=ANY($1)")
        .bind(vec![user, other])
        .execute(&pool)
        .await
        .unwrap();
}
