mod common;
use axum::{
    Router,
    body::Body,
    http::{Request, StatusCode},
};
use http_body_util::BodyExt;
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
    token: &str,
    body: Value,
) -> (StatusCode, Value) {
    let response = app
        .clone()
        .oneshot(
            Request::builder()
                .method(method)
                .uri(path)
                .header("content-type", "application/json")
                .header("authorization", format!("Bearer {token}"))
                .body(Body::from(if body.is_null() {
                    String::new()
                } else {
                    body.to_string()
                }))
                .unwrap(),
        )
        .await
        .unwrap();
    let status = response.status();
    let body = response.into_body().collect().await.unwrap().to_bytes();
    (status, serde_json::from_slice(&body).unwrap_or(Value::Null))
}

fn normalized(id: Uuid, account: Uuid, subject: &str, text: &str) -> Value {
    json!({
        "id": id, "account_id": account, "provider_message_id": format!("p-{id}"),
        "provider_thread_id": "t", "subject": subject,
        "from": {"name": "Acme Billing", "email": "billing@acme.test"},
        "to": [], "cc": [], "bcc": [], "text_body": text, "html_body": null, "preview": "",
        "sent_at": "2026-11-20T10:00:00Z", "is_read": false, "is_starred": false,
        "mailbox": "inbox", "provider_labels": [], "attachments": [],
        "list_unsubscribe": [], "list_unsubscribe_post": []
    })
}

#[tokio::test]
async fn plugins_are_per_user_off_by_default_and_respect_hidden_accounts() {
    let url = std::env::var("POSTMERE_TEST_DATABASE_URL")
        .expect("Use the isolated non-superuser test database");
    let pool = db::connect(&url).await.unwrap();
    db::migrate(&pool).await.unwrap();
    let state = AppState::new(pool.clone(), common::config(url))
        .await
        .unwrap();
    let app = application(state.clone(), postmere_plugins::router());
    let workspace = Uuid::new_v4();
    let hash = hash_password(Zeroizing::new("plugin fixture secure password".into()))
        .await
        .unwrap();
    let mut users = Vec::new();
    let mut tokens = Vec::new();
    for _ in 0..2 {
        let user = Uuid::new_v4();
        let email = format!("plugins-{user}@example.test");
        sqlx::query("INSERT INTO workspaces(id,name) VALUES($1,'Plugins') ON CONFLICT DO NOTHING")
            .bind(workspace)
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
            .bind(workspace)
            .bind(user)
            .execute(&pool)
            .await
            .unwrap();
        let (status, value) = request(&app, "POST", "/v1/auth/login", "unused",
            json!({"email":email,"password":"plugin fixture secure password","workspace_id":workspace})).await;
        assert_eq!(status, StatusCode::OK);
        users.push(user);
        tokens.push(
            serde_json::from_value::<SessionResponse>(value)
                .unwrap()
                .token,
        );
    }

    let account = Uuid::new_v4();
    let bill = Uuid::new_v4();
    let mut tx = db::scoped_transaction(&pool, workspace, users[0])
        .await
        .unwrap();
    sqlx::query("INSERT INTO provider_accounts(id,workspace_id,user_id,provider,email,encrypted_credentials) VALUES($1,$2,$3,'gmail','me@example.test',$4)")
        .bind(account).bind(workspace).bind(users[0]).bind(state.crypto.seal(workspace, account, b"fake").unwrap())
        .execute(&mut *tx).await.unwrap();
    sqlx::query("INSERT INTO mail_messages(id,workspace_id,user_id,account_id,provider_message_id,provider_thread_id,sent_at,normalized,search_text) VALUES($1,$2,$3,$4,$5,'t',now(),$6,'invoice')")
        .bind(bill).bind(workspace).bind(users[0]).bind(account).bind(format!("p-{bill}"))
        .bind(normalized(bill, account, "Your Acme invoice", "Amount due: $120.00. Due date: December 5, 2026."))
        .execute(&mut *tx).await.unwrap();
    tx.commit().await.unwrap();

    // Everything ships off.
    let (status, list) = request(&app, "GET", "/v1/plugins", &tokens[0], Value::Null).await;
    assert_eq!(status, StatusCode::OK);
    assert_eq!(list["plugins"].as_array().unwrap().len(), 7);
    assert!(
        list["plugins"]
            .as_array()
            .unwrap()
            .iter()
            .all(|p| p["enabled"] == false)
    );
    assert_eq!(
        list["plugins"][6]["settings"][0]["key"],
        "remind_days_before"
    );
    assert_eq!(list["plugins"][6]["settings"][0]["value"], "3");
    assert_eq!(
        list["plugins"][6]["settings"][0]["options"][2],
        json!(["7", "A week before"])
    );
    let cards_path = format!("/v1/mail/messages/{bill}/plugins?today=2026-11-21");
    let (_, empty) = request(&app, "GET", &cards_path, &tokens[0], Value::Null).await;
    assert_eq!(empty["cards"], json!([]));
    let tool_path = "/v1/plugins/postmere.bills/tools/remind_bill";
    let call = json!({"message_id": bill, "args": {"date": "2026-12-02"}, "today": "2026-11-21"});
    assert_eq!(
        request(&app, "POST", tool_path, &tokens[0], call.clone())
            .await
            .0,
        StatusCode::CONFLICT
    );

    // Invalid settings are rejected; valid ones persist per user.
    assert_eq!(
        request(
            &app,
            "PUT",
            "/v1/plugins/postmere.bills",
            &tokens[0],
            json!({"enabled": true, "values": {"remind_days_before": "99"}})
        )
        .await
        .0,
        StatusCode::BAD_REQUEST
    );
    let (status, updated) = request(
        &app,
        "PUT",
        "/v1/plugins/postmere.bills",
        &tokens[0],
        json!({"enabled": true, "values": {"remind_days_before": "7"}}),
    )
    .await;
    assert_eq!(status, StatusCode::OK, "{updated}");
    assert_eq!(updated["enabled"], true);
    assert_eq!(updated["settings"][0]["value"], "7");
    let (_, other) = request(&app, "GET", "/v1/plugins", &tokens[1], Value::Null).await;
    assert_eq!(other["plugins"][6]["enabled"], false);

    let (status, cards) = request(&app, "GET", &cards_path, &tokens[0], Value::Null).await;
    assert_eq!(status, StatusCode::OK, "{cards}");
    assert_eq!(cards["cards"][0]["plugin_id"], "postmere.bills");
    assert_eq!(cards["cards"][0]["card"]["title"], "$120.00 due Dec 5");
    assert_eq!(cards["actions"][0]["tool"], "remind_bill");
    assert_eq!(cards["actions"][0]["args"]["date"], "2026-11-28");

    let (status, result) = request(&app, "POST", tool_path, &tokens[0], call.clone()).await;
    assert_eq!(status, StatusCode::OK, "{result}");
    assert_eq!(
        result["effects"],
        json!([{"type": "remind", "date": "2026-12-02"}])
    );
    let (_, list) = request(&app, "GET", "/v1/plugins", &tokens[0], Value::Null).await;
    assert_eq!(list["plugins"][6]["activity"][0]["tool"], "remind_bill");
    assert_eq!(list["plugins"][6]["activity"][0]["succeeded"], true);

    // Another user can't reach this message even with the plugin on.
    request(
        &app,
        "PUT",
        "/v1/plugins/postmere.bills",
        &tokens[1],
        json!({"enabled": true}),
    )
    .await;
    let (_, peer) = request(&app, "GET", &cards_path, &tokens[1], Value::Null).await;
    assert_eq!(peer["cards"], json!([]));
    assert_eq!(
        request(&app, "POST", tool_path, &tokens[1], call.clone())
            .await
            .0,
        StatusCode::NOT_FOUND
    );

    // Hiding the account from assistants hides it from plugins too.
    let mut tx = db::scoped_transaction(&pool, workspace, users[0])
        .await
        .unwrap();
    sqlx::query("UPDATE provider_accounts SET hidden_from_assistants=true WHERE id=$1")
        .bind(account)
        .execute(&mut *tx)
        .await
        .unwrap();
    tx.commit().await.unwrap();
    let (_, hidden) = request(&app, "GET", &cards_path, &tokens[0], Value::Null).await;
    assert_eq!(hidden["cards"], json!([]));
    assert_eq!(
        request(&app, "POST", tool_path, &tokens[0], call).await.0,
        StatusCode::NOT_FOUND
    );
    assert_eq!(
        request(&app, "GET", "/v1/plugins/nope", &tokens[0], Value::Null)
            .await
            .0,
        StatusCode::METHOD_NOT_ALLOWED
    );
}
