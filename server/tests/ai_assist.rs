mod common;
use std::sync::{Arc, Mutex};

use axum::{
    Json, Router,
    body::Body,
    http::{Request, StatusCode},
    routing::post,
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

async fn request(app: &Router, method: &str, path: &str, token: &str, body: Value) -> (StatusCode, Value) {
    let response = app
        .clone()
        .oneshot(
            Request::builder()
                .method(method)
                .uri(path)
                .header("content-type", "application/json")
                .header("authorization", format!("Bearer {token}"))
                .body(Body::from(body.to_string()))
                .unwrap(),
        )
        .await
        .unwrap();
    let status = response.status();
    let body = response.into_body().collect().await.unwrap().to_bytes();
    (status, serde_json::from_slice(&body).unwrap_or(Value::Null))
}

/// A stand-in model: answers each structured call by its schema name, and
/// records every request so the test can see what was sent.
async fn fake_model(seen: Arc<Mutex<Vec<Value>>>, message: Uuid, other: Uuid) -> String {
    let app = Router::new().route(
        "/responses",
        post(move |Json(input): Json<Value>| {
            let seen = seen.clone();
            async move {
                let name = input["text"]["format"]["name"].as_str().unwrap_or("").to_string();
                seen.lock().unwrap().push(input);
                let output = match name.as_str() {
                    "quick_replies" => json!({"replies":[
                        {"label":"Agree","text":"Thursday works for me."},
                        {"label":"Ask","text":"What time on Thursday?"},
                        {"label":"Decline","text":"I can't make Thursday, sorry."},
                        {"label":"Extra","text":"A fourth reply the server must drop."}]}),
                    // The second issue quotes text that isn't in the draft and must be dropped.
                    "proofread" => json!({"issues":[
                        {"kind":"spelling","excerpt":"recieve","suggestion":"receive","explanation":"Misspelled."},
                        {"kind":"name","excerpt":"Not in the draft","suggestion":"x","explanation":"Invented."}]}),
                    "writing_style" => json!({"style_guide":"Open with 'Hi' and keep it to two lines."}),
                    "search_query" => json!({"query":"from:stripe has:attachment filetype:pdf after:2026-10-01","explanation":"PDFs from Stripe since October."}),
                    "document_summary" => json!({"summary":"A lease for flat 4.","points":[{"kind":"amount","text":"Rent is 500 a month."},{"kind":"bogus","text":"dropped"}]}),
                    "classify" => json!({"matches":[{"message_id":message,"label_ids":["receipts","unknown"]}]}),
                    "action_items" => json!({"tasks":[
                        {"title":"Send the signed lease","due_at":"2026-12-01T17:00:00Z","source_id":message},
                        {"title":"From a message nobody asked about","due_at":null,"source_id":other}]}),
                    _ => json!({}),
                };
                Json(json!({"status":"completed","output":[{"type":"message","content":[
                    {"type":"output_text","text":output.to_string()}]}]}))
            }
        }),
    );
    let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
    let address = listener.local_addr().unwrap();
    tokio::spawn(async move { axum::serve(listener, app).await.unwrap() });
    format!("http://{address}/responses")
}

#[tokio::test]
async fn assistance_endpoints_are_scoped_and_validate_model_output() {
    let url = std::env::var("POSTMERE_TEST_DATABASE_URL").expect("Use the isolated non-superuser test database");
    let pool = db::connect(&url).await.unwrap();
    db::migrate(&pool).await.unwrap();
    let message = Uuid::new_v4();
    let sent = Uuid::new_v4();
    let other = Uuid::new_v4();
    let seen = Arc::new(Mutex::new(Vec::new()));
    let model = fake_model(seen.clone(), message, other).await;
    let mut config = common::config(url);
    let mut provider = postmere_core::config::AiProvider::openai("fixture-key");
    provider.url = model.parse().unwrap();
    config.ai = Some(provider);
    let state = AppState::new(pool.clone(), config).await.unwrap();
    let app = application(state.clone(), ai::router());

    let workspace = Uuid::new_v4();
    let user = Uuid::new_v4();
    let email = format!("assist-{user}@example.test");
    let hash = hash_password(Zeroizing::new("assist fixture password".into())).await.unwrap();
    sqlx::query("INSERT INTO workspaces(id,name) VALUES($1,'Assist')").bind(workspace).execute(&pool).await.unwrap();
    sqlx::query("INSERT INTO users(id,email,password_hash) VALUES($1,$2,$3)").bind(user).bind(&email).bind(&hash).execute(&pool).await.unwrap();
    sqlx::query("INSERT INTO memberships(workspace_id,user_id,role) VALUES($1,$2,'member')").bind(workspace).bind(user).execute(&pool).await.unwrap();
    let (status, value) = request(&app, "POST", "/v1/auth/login", "",
        json!({"email":email,"password":"assist fixture password","workspace_id":workspace})).await;
    assert_eq!(status, StatusCode::OK);
    let token = serde_json::from_value::<SessionResponse>(value).unwrap().token;

    // AI stays off until the user turns it on.
    assert_eq!(request(&app, "POST", "/v1/ai/quick-replies", &token, json!({"message_ids":[message]})).await.0, StatusCode::FORBIDDEN);
    assert_eq!(request(&app, "PUT", "/v1/ai/settings", &token, json!({"enabled":true})).await.0, StatusCode::OK);

    let account = Uuid::new_v4();
    let mut tx = db::scoped_transaction(&pool, workspace, user).await.unwrap();
    sqlx::query("INSERT INTO provider_accounts(id,workspace_id,user_id,provider,email,encrypted_credentials) VALUES($1,$2,$3,'gmail','me@example.test',$4)")
        .bind(account).bind(workspace).bind(user).bind(state.crypto.seal(workspace, account, b"fake").unwrap()).execute(&mut *tx).await.unwrap();
    sqlx::query("INSERT INTO mail_messages(id,workspace_id,user_id,account_id,provider_message_id,provider_thread_id,sent_at,normalized,search_text) VALUES($1,$2,$3,$4,'in','t',now(),$5,'lease')")
        .bind(message).bind(workspace).bind(user).bind(account)
        .bind(json!({"subject":"Lease","from":{"email":"ada@example.test","name":"Ada"},"text_body":"Can you send the signed lease by Monday?"}))
        .execute(&mut *tx).await.unwrap();
    for (index, id) in [sent, Uuid::new_v4(), Uuid::new_v4()].into_iter().enumerate() {
        sqlx::query("INSERT INTO mail_messages(id,workspace_id,user_id,account_id,provider_message_id,provider_thread_id,sent_at,normalized,search_text) VALUES($1,$2,$3,$4,$5,'t',now(),$6,'reply')")
            .bind(id).bind(workspace).bind(user).bind(account).bind(format!("out-{index}"))
            .bind(json!({"subject":"Re: Lease","from":{"email":"ME@example.test"},
                "text_body":"Hi Ada,\nThursday works for me, see you then.\nThanks\n\nOn Mon, Ada wrote:\n> SECRET QUOTED TEXT"}))
            .execute(&mut *tx).await.unwrap();
    }
    tx.commit().await.unwrap();

    let replies = request(&app, "POST", "/v1/ai/quick-replies", &token, json!({"message_ids":[message]})).await;
    assert_eq!(replies.0, StatusCode::OK);
    assert_eq!(replies.1["replies"].as_array().unwrap().len(), 3, "at most three replies");

    // Another user's or a missing message can't be used.
    assert_eq!(request(&app, "POST", "/v1/ai/quick-replies", &token, json!({"message_ids":[other]})).await.0, StatusCode::NOT_FOUND);

    let proofread = request(&app, "POST", "/v1/ai/proofread", &token,
        json!({"draft_text":"I will recieve it Monday.","recipients":["ada@example.test"],"message_ids":[message]})).await;
    assert_eq!(proofread.0, StatusCode::OK);
    let issues = proofread.1["issues"].as_array().unwrap();
    assert_eq!(issues.len(), 1, "issues must quote the draft");
    assert_eq!(issues[0]["suggestion"], "receive");

    let learned = request(&app, "POST", "/v1/ai/style/learn", &token, Value::Null).await;
    assert_eq!(learned.0, StatusCode::OK);
    assert_eq!(learned.1["messages_read"], 3);
    let style_request = seen.lock().unwrap().iter()
        .find(|input| input["text"]["format"]["name"] == "writing_style").unwrap().to_string();
    assert!(style_request.contains("Thursday works"), "reads what the user wrote");
    assert!(!style_request.contains("SECRET QUOTED TEXT"), "skips quoted history");
    assert!(!style_request.contains("Can you send the signed lease"), "skips mail from others");
    let settings = request(&app, "GET", "/v1/ai/settings", &token, Value::Null).await.1;
    assert_eq!(settings["learned_style"], "Open with 'Hi' and keep it to two lines.");
    assert!(settings["learned_at"].is_string());
    request(&app, "POST", "/v1/ai/quick-replies", &token, json!({"message_ids":[message]})).await;
    assert!(seen.lock().unwrap().last().unwrap().to_string().contains("keep it to two lines"), "drafting uses the learned style");
    let cleared = request(&app, "PUT", "/v1/ai/settings", &token, json!({"enabled":true,"learned_style":""})).await.1;
    assert_eq!(cleared["learned_style"], "");
    assert!(cleared["learned_at"].is_null());

    let search = request(&app, "POST", "/v1/ai/search", &token, json!({"request":"stripe invoices since october with pdfs"})).await;
    assert_eq!(search.0, StatusCode::OK);
    assert!(search.1["query"].as_str().unwrap().contains("from:stripe"));
    assert_eq!(request(&app, "POST", "/v1/ai/search", &token, json!({"request":"  "})).await.0, StatusCode::BAD_REQUEST);

    let document = request(&app, "POST", "/v1/ai/document", &token,
        json!({"message_id":message,"filename":"lease.pdf","text":"Rent is 500 a month."})).await;
    assert_eq!(document.0, StatusCode::OK);
    assert_eq!(document.1["points"].as_array().unwrap().len(), 1, "unknown kinds are dropped");
    assert_eq!(request(&app, "POST", "/v1/ai/document", &token,
        json!({"message_id":other,"filename":"x.pdf","text":"text"})).await.0, StatusCode::NOT_FOUND);

    let classified = request(&app, "POST", "/v1/ai/classify", &token, json!({
        "labels":[{"id":"receipts","name":"Receipts","description":"Receipts and invoices"}],
        "message_ids":[message]})).await;
    assert_eq!(classified.0, StatusCode::OK);
    assert_eq!(classified.1["matches"][0]["label_ids"], json!(["receipts"]), "only labels the user described");

    let tasks = request(&app, "POST", "/v1/ai/tasks", &token, json!({"message_ids":[message]})).await;
    assert_eq!(tasks.0, StatusCode::OK);
    let tasks = tasks.1["tasks"].as_array().unwrap().clone();
    assert_eq!(tasks.len(), 1, "tasks must come from the supplied messages");
    assert_eq!(tasks[0]["title"], "Send the signed lease");
}
