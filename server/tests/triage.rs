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
                .body(Body::from(body.to_string()))
                .unwrap(),
        )
        .await
        .unwrap();
    let status = response.status();
    let body = response.into_body().collect().await.unwrap().to_bytes();
    (status, serde_json::from_slice(&body).unwrap_or(Value::Null))
}

fn normalized(
    id: Uuid,
    account: Uuid,
    from: &str,
    subject: &str,
    text: &str,
    unsubscribe: bool,
) -> Value {
    json!({
        "id": id, "account_id": account, "provider_message_id": format!("p-{id}"),
        "provider_thread_id": format!("t-{id}"), "subject": subject,
        "from": {"name": "Sender", "email": from},
        "to": [], "cc": [], "bcc": [], "text_body": text, "html_body": null, "preview": "",
        "sent_at": "2026-11-20T10:00:00Z", "is_read": false, "is_starred": false,
        "mailbox": "inbox", "provider_labels": [], "attachments": [],
        "list_unsubscribe": if unsubscribe { json!(["https://news.example.org/u"]) } else { json!([]) },
        "list_unsubscribe_post": []
    })
}

#[tokio::test]
async fn triage_suggestions_follow_rules_then_learned_habits_per_user() {
    let url = std::env::var("POSTMERE_TEST_DATABASE_URL")
        .expect("Use the isolated non-superuser test database");
    let pool = db::connect(&url).await.unwrap();
    db::migrate(&pool).await.unwrap();
    let state = AppState::new(pool.clone(), common::config(url))
        .await
        .unwrap();
    let app = application(state.clone(), postmere_ai::router());
    let workspace = Uuid::new_v4();
    let hash = hash_password(Zeroizing::new("triage fixture secure password".into()))
        .await
        .unwrap();
    sqlx::query("INSERT INTO workspaces(id,name) VALUES($1,'Triage')")
        .bind(workspace)
        .execute(&pool)
        .await
        .unwrap();
    let mut users = Vec::new();
    let mut tokens = Vec::new();
    for _ in 0..2 {
        let user = Uuid::new_v4();
        let email = format!("triage-{user}@example.test");
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
            json!({"email":email,"password":"triage fixture secure password","workspace_id":workspace})).await;
        assert_eq!(status, StatusCode::OK);
        users.push(user);
        tokens.push(
            serde_json::from_value::<SessionResponse>(value)
                .unwrap()
                .token,
        );
    }
    let account = Uuid::new_v4();
    let mut tx = db::scoped_transaction(&pool, workspace, users[0])
        .await
        .unwrap();
    sqlx::query("INSERT INTO provider_accounts(id,workspace_id,user_id,provider,email,encrypted_credentials) VALUES($1,$2,$3,'gmail','me@example.test',$4)")
        .bind(account).bind(workspace).bind(users[0]).bind(state.crypto.seal(workspace, account, b"fake").unwrap())
        .execute(&mut *tx).await.unwrap();
    let fixtures = [
        (
            "ada@analytical.org",
            "Draft",
            "Could you send the draft by Friday?",
            false,
        ),
        (
            "news@digest.org",
            "Weekly digest",
            "This week in engines.",
            true,
        ),
        ("ada@analytical.org", "Hello", "Lovely to see you.", false),
        ("ada@analytical.org", "Later", "Another note.", false),
    ];
    let mut ids = Vec::new();
    for (from, subject, text, unsubscribe) in fixtures {
        let id = Uuid::new_v4();
        sqlx::query("INSERT INTO mail_messages(id,workspace_id,user_id,account_id,provider_message_id,provider_thread_id,sent_at,normalized,search_text) VALUES($1,$2,$3,$4,$5,$6,now(),$7,'x')")
            .bind(id).bind(workspace).bind(users[0]).bind(account).bind(format!("p-{id}")).bind(format!("t-{id}"))
            .bind(normalized(id, account, from, subject, text, unsubscribe))
            .execute(&mut *tx).await.unwrap();
        ids.push(id);
    }
    tx.commit().await.unwrap();

    // AI is off for this user: rules answer, and answers are stored.
    let (status, first) = request(
        &app,
        "POST",
        "/v1/decisions/triage",
        &tokens[0],
        json!({"message_ids": [ids[0], ids[1]], "today": "2026-11-22"}),
    )
    .await;
    assert_eq!(status, StatusCode::OK, "{first}");
    let find = |value: &Value, id: Uuid| {
        value["suggestions"]
            .as_array()
            .unwrap()
            .iter()
            .find(|s| s["message_id"] == id.to_string())
            .cloned()
            .unwrap()
    };
    assert_eq!(find(&first, ids[0])["action"], "needs_reply");
    assert_eq!(find(&first, ids[0])["source"], "rules");
    assert_eq!(find(&first, ids[1])["action"], "archive");
    let (_, again) = request(
        &app,
        "POST",
        "/v1/decisions/triage",
        &tokens[0],
        json!({"message_ids": [ids[0], ids[1]]}),
    )
    .await;
    assert_eq!(again, first, "stored suggestions come back unchanged");

    // Another member cannot see or create suggestions for this mail.
    let (_, other) = request(
        &app,
        "POST",
        "/v1/decisions/triage",
        &tokens[1],
        json!({"message_ids": [ids[0]]}),
    )
    .await;
    assert_eq!(other["suggestions"], json!([]));
    let (status, _) = request(
        &app,
        "POST",
        "/v1/decisions/triage/feedback",
        &tokens[1],
        json!({"message_id": ids[0], "action": "archive"}),
    )
    .await;
    assert_eq!(status, StatusCode::NOT_FOUND);

    // Four archives of Ada's mail become a habit for her next message.
    for _ in 0..4 {
        let (status, _) = request(
            &app,
            "POST",
            "/v1/decisions/triage/feedback",
            &tokens[0],
            json!({"message_id": ids[2], "action": "archive"}),
        )
        .await;
        assert_eq!(status, StatusCode::OK);
    }
    let (_, learned) = request(
        &app,
        "POST",
        "/v1/decisions/triage",
        &tokens[0],
        json!({"message_ids": [ids[3]]}),
    )
    .await;
    let habit = find(&learned, ids[3]);
    assert_eq!(
        (habit["action"].as_str(), habit["source"].as_str()),
        (Some("archive"), Some("history"))
    );
    assert_eq!(
        habit["reason"],
        "You archived 4 of the last 4 from this sender"
    );

    // Bounds and closed decisions.
    let (status, _) = request(
        &app,
        "POST",
        "/v1/decisions/triage",
        &tokens[0],
        json!({"message_ids": []}),
    )
    .await;
    assert_eq!(status, StatusCode::BAD_REQUEST);
    let many: Vec<Uuid> = (0..51).map(|_| Uuid::new_v4()).collect();
    let (status, _) = request(
        &app,
        "POST",
        "/v1/decisions/triage",
        &tokens[0],
        json!({"message_ids": many}),
    )
    .await;
    assert_eq!(status, StatusCode::BAD_REQUEST);
    let (status, _) = request(
        &app,
        "POST",
        "/v1/decisions/triage/feedback",
        &tokens[0],
        json!({"message_id": ids[0], "action": "forward"}),
    )
    .await;
    assert_eq!(status, StatusCode::BAD_REQUEST);

    // New inbox mail is queued on arrival and answered by the worker, before
    // the app asks. Old history and the account's own mail are not queued.
    let mut tx = db::scoped_transaction(&pool, workspace, users[0])
        .await
        .unwrap();
    let arrived = Uuid::new_v4();
    let old = Uuid::new_v4();
    let own = Uuid::new_v4();
    let now = chrono::Utc::now();
    for (id, from, sent) in [
        (arrived, "grace@navy.org", now),
        (old, "grace@navy.org", now - chrono::Duration::days(10)),
        (own, "me@example.test", now),
    ] {
        sqlx::query("INSERT INTO mail_messages(id,workspace_id,user_id,account_id,provider_message_id,provider_thread_id,sent_at,normalized,search_text) VALUES($1,$2,$3,$4,$5,$6,$8,$7,'x')")
            .bind(id).bind(workspace).bind(users[0]).bind(account).bind(format!("p-{id}")).bind(format!("t-{id}"))
            .bind(normalized(id, account, from, "Coffee?", "Free for coffee next week?", false))
            .bind(sent)
            .execute(&mut *tx).await.unwrap();
    }
    tx.commit().await.unwrap();
    let queued: Vec<Uuid> =
        sqlx::query_scalar("SELECT message_id FROM mail_triage_wakeups WHERE message_id = ANY($1)")
            .bind(vec![arrived, old, own])
            .fetch_all(&pool)
            .await
            .unwrap();
    assert_eq!(queued, vec![arrived]);
    sqlx::query("UPDATE mail_triage_wakeups SET due_at = now() WHERE message_id = $1")
        .bind(arrived)
        .execute(&pool)
        .await
        .unwrap();
    while postmere_ai::process_triage_batch(&state).await.unwrap() {}
    let (_, ready) = request(
        &app,
        "POST",
        "/v1/decisions/triage",
        &tokens[0],
        json!({"message_ids": [arrived]}),
    )
    .await;
    assert_eq!(find(&ready, arrived)["action"], "needs_reply");
    let left: i64 =
        sqlx::query_scalar("SELECT count(*) FROM mail_triage_wakeups WHERE message_id = $1")
            .bind(arrived)
            .fetch_one(&pool)
            .await
            .unwrap();
    assert_eq!(left, 0, "the queue empties once answered");
}
