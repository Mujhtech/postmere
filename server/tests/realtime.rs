mod common;
use axum::{
    Router,
    body::Body,
    http::{Request, StatusCode},
    response::Response,
};
use base64::{Engine, engine::general_purpose::URL_SAFE_NO_PAD};
use chrono::{Duration, Utc};
use http_body_util::BodyExt;
use postmere_core::{AppState, auth::AuthContext, db};
use postmere_providers::{Address, Credentials, Message};
use postmere_server::application;
use serde_json::{Value, json};
use sha2::{Digest, Sha256};
use sqlx::PgPool;
use tower::ServiceExt;
use uuid::Uuid;

async fn identity(pool: &PgPool, workspace: Uuid) -> (AuthContext, String) {
    let user = Uuid::new_v4();
    let session = Uuid::new_v4();
    let token = URL_SAFE_NO_PAD.encode(Sha256::digest(session.as_bytes()));
    sqlx::query(
        "INSERT INTO users(id,email,password_hash) VALUES($1,$2,'unused-realtime-fixture')",
    )
    .bind(user)
    .bind(format!("events-{user}@example.test"))
    .execute(pool)
    .await
    .unwrap();
    sqlx::query(
        "INSERT INTO workspaces(id,name) VALUES($1,'Realtime fixture') ON CONFLICT DO NOTHING",
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
    sqlx::query("INSERT INTO sessions(id,workspace_id,user_id,token_hash,expires_at,absolute_expires_at) VALUES($1,$2,$3,$4,now()+interval '1 day',now()+interval '2 days')")
        .bind(session).bind(workspace).bind(user).bind(Sha256::digest(token.as_bytes()).to_vec()).execute(pool).await.unwrap();
    (
        AuthContext {
            user_id: user,
            workspace_id: workspace,
            session_id: session,
            role: "owner".into(),
        },
        token,
    )
}
async fn account(state: &AppState, auth: &AuthContext) -> Uuid {
    let id = Uuid::new_v4();
    let credentials = Credentials {
        access_token: "fixture-no-provider-traffic".into(),
        refresh_token: None,
        expires_at: Utc::now() + Duration::days(1),
        scopes: vec![],
    };
    let encrypted = state
        .crypto
        .seal(
            auth.workspace_id,
            id,
            &serde_json::to_vec(&credentials).unwrap(),
        )
        .unwrap();
    let mut tx = auth.begin(&state.pool).await.unwrap();
    sqlx::query("INSERT INTO provider_accounts(id,workspace_id,user_id,provider,email,encrypted_credentials) VALUES($1,$2,$3,'gmail',$4,$5)")
        .bind(id).bind(auth.workspace_id).bind(auth.user_id).bind(format!("mailbox-{id}@example.test")).bind(encrypted).execute(&mut *tx).await.unwrap();
    tx.commit().await.unwrap();
    id
}
async fn message(state: &AppState, auth: &AuthContext, account: Uuid) -> Uuid {
    let id = Uuid::new_v4();
    let message = Message {
        id,
        account_id: account,
        provider_message_id: id.to_string(),
        provider_thread_id: "fixture".into(),
        subject: "Secret realtime subject".into(),
        from: Address {
            name: None,
            email: "secret@example.test".into(),
        },
        to: vec![],
        cc: vec![],
        bcc: vec![],
        text_body: "Secret realtime body".into(),
        html_body: None,
        preview: "Secret preview".into(),
        sent_at: Utc::now(),
        is_read: false,
        is_starred: false,
        mailbox: "inbox".into(),
        provider_labels: vec![],
        categories: vec![],
        delivery_headers: None,
        attachments: vec![],
        list_unsubscribe: vec![],
        list_unsubscribe_post: vec![],
        authentication_results: vec![],
        dkim_signatures: vec![],
        rfc_message_id: None,
        in_reply_to: None,
        references: vec![],
    };
    let mut tx = auth.begin(&state.pool).await.unwrap();
    sqlx::query("INSERT INTO mail_messages(id,workspace_id,user_id,account_id,provider_message_id,provider_thread_id,sent_at,normalized,search_text) VALUES($1,$2,$3,$4,$5,'fixture',now(),$6,'Secret')")
        .bind(id).bind(auth.workspace_id).bind(auth.user_id).bind(account).bind(id.to_string()).bind(serde_json::to_value(message).unwrap()).execute(&mut *tx).await.unwrap();
    tx.commit().await.unwrap();
    id
}
async fn open(app: &Router, token: Option<&str>, cursor: Option<&str>) -> Response {
    let mut request = Request::builder().uri("/v1/events");
    if let Some(token) = token {
        request = request.header("authorization", format!("Bearer {token}"));
    }
    if let Some(cursor) = cursor {
        request = request.header("last-event-id", cursor);
    }
    app.clone()
        .oneshot(request.body(Body::empty()).unwrap())
        .await
        .unwrap()
}
async fn frame(response: &mut Response) -> Option<String> {
    tokio::time::timeout(std::time::Duration::from_secs(5), async {
        loop {
            let frame = response.body_mut().frame().await?.unwrap();
            if let Ok(data) = frame.into_data() {
                return Some(String::from_utf8(data.to_vec()).unwrap());
            }
        }
    })
    .await
    .expect("SSE response should make progress")
}
async fn quiet(response: &mut Response) {
    assert!(
        tokio::time::timeout(
            std::time::Duration::from_millis(150),
            response.body_mut().frame()
        )
        .await
        .is_err(),
        "no unrelated or uncommitted invalidation should be published"
    );
}
fn payload(frame: &str) -> Value {
    serde_json::from_str(
        frame
            .lines()
            .find_map(|line| {
                line.strip_prefix("data: ")
                    .or_else(|| line.strip_prefix("data:"))
            })
            .unwrap(),
    )
    .unwrap()
}

#[tokio::test]
async fn realtime_is_commit_scoped_content_free_and_revocation_safe() {
    let url = std::env::var("POSTMERE_TEST_DATABASE_URL")
        .expect("Set isolated non-bypass PostgreSQL test database URL");
    let pool = db::connect(&url).await.unwrap();
    db::migrate(&pool).await.unwrap();
    let state = AppState::new(pool.clone(), common::config(url))
        .await
        .unwrap();
    let (shutdown_sender, shutdown_signal) = postmere_realtime::shutdown_channel();
    let app = application(
        state.clone(),
        postmere_realtime::router().merge(postmere_mail::mail::router()),
    )
    .layer(axum::Extension(shutdown_signal));
    let workspace = Uuid::new_v4();
    let foreign = Uuid::new_v4();
    let (owner, token) = identity(&pool, workspace).await;
    let (peer, peer_token) = identity(&pool, workspace).await;
    let (outsider, outside_token) = identity(&pool, foreign).await;
    let owner_account = account(&state, &owner).await;
    let peer_account = account(&state, &peer).await;
    let outside_account = account(&state, &outsider).await;
    let message_id = message(&state, &owner, owner_account).await;
    assert_eq!(
        open(&app, None, None).await.status(),
        StatusCode::UNAUTHORIZED
    );
    assert_eq!(
        open(&app, Some(&token), Some(&"x".repeat(257)))
            .await
            .status(),
        StatusCode::BAD_REQUEST
    );
    let mut stream = open(&app, Some(&token), None).await;
    assert_eq!(stream.status(), StatusCode::OK);
    assert_eq!(stream.headers()["content-type"], "text/event-stream");
    assert_eq!(stream.headers()["x-accel-buffering"], "no");
    let ready = frame(&mut stream).await.unwrap();
    assert!(ready.contains("event: ready"));
    assert_eq!(payload(&ready)["version"], 1);
    let cursor = ready
        .lines()
        .find_map(|line| line.strip_prefix("id: "))
        .unwrap()
        .to_owned();
    assert!(cursor.len() <= 256);
    let mut peer_stream = open(&app, Some(&peer_token), None).await;
    frame(&mut peer_stream).await.unwrap();
    message(&state, &peer, peer_account).await;
    assert_eq!(
        payload(&frame(&mut peer_stream).await.unwrap())["kinds"],
        json!(["mail"])
    );
    quiet(&mut stream).await;
    message(&state, &outsider, outside_account).await;
    quiet(&mut stream).await;
    quiet(&mut peer_stream).await;

    let mut tx = owner.begin(&pool).await.unwrap();
    sqlx::query("UPDATE mail_messages SET normalized=jsonb_set(normalized,'{is_read}','true'::jsonb),updated_at=clock_timestamp() WHERE id=$1").bind(message_id).execute(&mut *tx).await.unwrap();
    quiet(&mut stream).await;
    tx.commit().await.unwrap();
    let changed = frame(&mut stream).await.unwrap();
    assert!(changed.contains("event: change"));
    assert_eq!(payload(&changed)["kinds"], json!(["mail"]));
    for secret in [
        "Secret",
        "secret@example.test",
        &owner.user_id.to_string(),
        &workspace.to_string(),
        &message_id.to_string(),
    ] {
        assert!(!changed.contains(secret));
    }
    let mut tx = owner.begin(&pool).await.unwrap();
    sqlx::query("UPDATE mail_messages SET normalized=jsonb_set(normalized,'{is_read}','false'::jsonb) WHERE id=$1").bind(message_id).execute(&mut *tx).await.unwrap();
    tx.rollback().await.unwrap();
    quiet(&mut stream).await;
    // Verification and provider cursor updates do not feed back into refresh.
    let mut tx = owner.begin(&pool).await.unwrap();
    sqlx::query("UPDATE mail_messages SET last_verified_at=now() WHERE id=$1")
        .bind(message_id)
        .execute(&mut *tx)
        .await
        .unwrap();
    sqlx::query("UPDATE provider_accounts SET last_synced_at=now(),sync_cursor='fixture-checkpoint',updated_at=now() WHERE id=$1").bind(owner_account).execute(&mut *tx).await.unwrap();
    tx.commit().await.unwrap();
    quiet(&mut stream).await;
    let response = app
        .clone()
        .oneshot(
            Request::builder()
                .method("POST")
                .uri(format!("/v1/mail/accounts/{owner_account}/sync"))
                .header("authorization", format!("Bearer {token}"))
                .header("content-type", "application/json")
                .body(Body::from(json!({"refresh_provider":false}).to_string()))
                .unwrap(),
        )
        .await
        .unwrap();
    assert_eq!(
        response.status(),
        StatusCode::OK,
        "cache-only refresh does not contact fixture provider credentials"
    );
    let cached: Value =
        serde_json::from_slice(&response.into_body().collect().await.unwrap().to_bytes()).unwrap();
    assert_eq!(cached["messages"].as_array().unwrap().len(), 1);
    quiet(&mut stream).await;
    let mut tx = owner.begin(&pool).await.unwrap();
    sqlx::query("UPDATE provider_accounts SET display_name='Updated account' WHERE id=$1")
        .bind(owner_account)
        .execute(&mut *tx)
        .await
        .unwrap();
    tx.commit().await.unwrap();
    assert_eq!(
        payload(&frame(&mut stream).await.unwrap())["kinds"],
        json!(["accounts"])
    );
    for index in 0..140 {
        let mut tx = owner.begin(&pool).await.unwrap();
        sqlx::query("UPDATE provider_accounts SET display_name=$2 WHERE id=$1")
            .bind(owner_account)
            .bind(format!("Account {index}"))
            .execute(&mut *tx)
            .await
            .unwrap();
        tx.commit().await.unwrap();
    }
    tokio::time::sleep(std::time::Duration::from_millis(100)).await;
    assert!(
        frame(&mut stream).await.unwrap().contains("event: reset"),
        "a lagged client recovers through a full cache invalidation"
    );
    let outbox = Uuid::new_v4();
    let mut tx = owner.begin(&pool).await.unwrap();
    sqlx::query("INSERT INTO mail_outbox(id,client_id,workspace_id,user_id,account_id,encrypted_payload,payload_hash,scheduled_at,undo_until) VALUES($1,$1,$2,$3,$4,$5,$6,now()+interval '1 day',now()+interval '1 minute')")
        .bind(outbox).bind(workspace).bind(owner.user_id).bind(owner_account).bind(vec![1u8;64]).bind(vec![2u8;32]).execute(&mut *tx).await.unwrap();
    tx.commit().await.unwrap();
    assert_eq!(
        payload(&frame(&mut stream).await.unwrap())["kinds"],
        json!(["outbox"])
    );

    drop(stream);
    let mut reconnect = open(&app, Some(&token), Some(&cursor)).await;
    assert!(
        frame(&mut reconnect)
            .await
            .unwrap()
            .contains("event: reset")
    );
    let mut extra = Vec::new();
    for _ in 0..3 {
        let mut stream = open(&app, Some(&token), None).await;
        assert_eq!(stream.status(), StatusCode::OK);
        frame(&mut stream).await.unwrap();
        extra.push(stream);
    }
    assert_eq!(
        open(&app, Some(&token), None).await.status(),
        StatusCode::TOO_MANY_REQUESTS
    );
    extra.clear();
    let mut released = open(&app, Some(&token), None).await;
    assert_eq!(released.status(), StatusCode::OK);
    frame(&mut released).await.unwrap();
    drop(released);
    sqlx::query("UPDATE memberships SET revoked_at=now() WHERE workspace_id=$1 AND user_id=$2")
        .bind(workspace)
        .bind(owner.user_id)
        .execute(&pool)
        .await
        .unwrap();
    assert!(
        frame(&mut reconnect).await.is_none(),
        "membership revocation closes even an idle stream"
    );
    assert_eq!(
        open(&app, Some(&token), None).await.status(),
        StatusCode::UNAUTHORIZED
    );
    sqlx::query("UPDATE sessions SET created_at=now()-interval '2 days',expires_at=now()-interval '1 day' WHERE id=$1").bind(peer.session_id).execute(&pool).await.unwrap();
    assert!(
        frame(&mut peer_stream).await.is_none(),
        "expiry closes an idle stream"
    );
    let mut closing = open(&app, Some(&outside_token), None).await;
    frame(&mut closing).await.unwrap();
    shutdown_sender.send(true).unwrap();
    assert!(
        frame(&mut closing).await.is_none(),
        "graceful shutdown closes active SSE bodies"
    );
    drop(closing);
    drop(reconnect);
    drop(peer_stream);
    drop(app);
    sqlx::query("DELETE FROM workspaces WHERE id=ANY($1)")
        .bind(vec![workspace, foreign])
        .execute(&pool)
        .await
        .unwrap();
    sqlx::query("DELETE FROM users WHERE id=ANY($1)")
        .bind(vec![owner.user_id, peer.user_id, outsider.user_id])
        .execute(&pool)
        .await
        .unwrap();
}
