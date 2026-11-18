mod common;

use axum::{
    Router,
    body::Body,
    http::{HeaderMap, Request, StatusCode, header},
};
use base64::{
    Engine,
    engine::general_purpose::{STANDARD, URL_SAFE_NO_PAD},
};
use chrono::{Duration, Utc};
use http_body_util::BodyExt;
use postmere_core::{
    AppState,
    auth::{AuthContext, SessionResponse, hash_password},
    db,
};
use postmere_mcp_operations::{
    Approval, ApprovalInput, CreateDraft, DraftContent, UpdateDraft, create_draft, get_approval,
    request_approval, update_draft,
};
use postmere_providers::{Address, Credentials, SendAttachment};
use postmere_server::application;
use serde_json::json;
use sha2::{Digest, Sha256};
use sqlx::PgPool;
use tower::ServiceExt;
use uuid::Uuid;
use zeroize::Zeroizing;

const ORIGIN: &str = "http://127.0.0.1:8080";
const PASSWORD: &str = "browser approval fixture password";
const SUBJECT: &str = "Private approval <img src=x onerror=alert(1)>";

struct Browser {
    cookie: String,
    csrf: String,
}

fn token() -> String {
    let mut bytes = [0u8; 32];
    getrandom::fill(&mut bytes).unwrap();
    URL_SAFE_NO_PAD.encode(bytes)
}

async fn browser(pool: &PgPool, session: &SessionResponse) -> Browser {
    let cookie = token();
    let csrf = token();
    sqlx::query("INSERT INTO mcp_browser_sessions(token_hash,session_id,csrf_token,expires_at) VALUES($1,$2,$3,$4)")
        .bind(Sha256::digest(cookie.as_bytes()).to_vec())
        .bind(session.session_id)
        .bind(&csrf)
        .bind(session.expires_at.unwrap_or_else(|| Utc::now() + Duration::hours(24)))
        .execute(pool).await.unwrap();
    Browser { cookie, csrf }
}

async fn mcp_bearer(state: &AppState, session: &SessionResponse) -> (String, String) {
    let client = Uuid::new_v4().to_string();
    let grant = Uuid::new_v4();
    let bearer = format!("pm_mcp_{}", token());
    sqlx::query("INSERT INTO mcp_oauth_clients(id,name,redirect_uris,auth_method) VALUES($1,'Approval fixture assistant',$2,'none')")
        .bind(&client).bind(vec!["https://client.example/callback"])
        .execute(&state.pool).await.unwrap();
    sqlx::query("INSERT INTO mcp_oauth_grants(id,session_id,client_id,resource,scopes,expires_at) VALUES($1,$2,$3,$4,$5,$6)")
        .bind(grant).bind(session.session_id).bind(&client).bind(format!("{ORIGIN}/mcp"))
        .bind(vec!["mail:read", "mail:draft", "mail:manage", "mail:send"]).bind(session.expires_at.unwrap_or_else(|| Utc::now() + Duration::hours(24)))
        .execute(&state.pool).await.unwrap();
    sqlx::query("INSERT INTO mcp_access_tokens(token_hash,grant_id,expires_at) VALUES($1,$2,$3)")
        .bind(Sha256::digest(bearer.as_bytes()).to_vec())
        .bind(grant)
        .bind(
            session
                .expires_at
                .unwrap_or_else(|| Utc::now() + Duration::hours(24)),
        )
        .execute(&state.pool)
        .await
        .unwrap();
    let mut headers = HeaderMap::new();
    headers.insert(
        header::AUTHORIZATION,
        format!("Bearer {bearer}").parse().unwrap(),
    );
    let verified = postmere_mcp_auth::authenticate(state, &headers)
        .await
        .unwrap();
    assert_eq!(verified.auth.user_id, session.user_id);
    (bearer, client)
}

async fn raw(
    app: &Router,
    method: &str,
    path: &str,
    browser: Option<&Browser>,
    bearer: Option<&str>,
    origin: Option<&str>,
    form: &str,
) -> (StatusCode, HeaderMap, String) {
    let mut request = Request::builder().method(method).uri(path);
    if let Some(browser) = browser {
        request = request.header(
            header::COOKIE,
            format!("postmere_mcp_browser={}", browser.cookie),
        );
    }
    if let Some(bearer) = bearer {
        request = request.header(header::AUTHORIZATION, format!("Bearer {bearer}"));
    }
    if let Some(origin) = origin {
        request = request.header(header::ORIGIN, origin);
    }
    if method == "POST" {
        request = request.header(header::CONTENT_TYPE, "application/x-www-form-urlencoded");
    }
    let response = app
        .clone()
        .oneshot(request.body(Body::from(form.to_owned())).unwrap())
        .await
        .unwrap();
    let status = response.status();
    let headers = response.headers().clone();
    let bytes = response.into_body().collect().await.unwrap().to_bytes();
    (status, headers, String::from_utf8(bytes.to_vec()).unwrap())
}

fn decision(browser: &Browser, action: &str) -> String {
    url::form_urlencoded::Serializer::new(String::new())
        .append_pair("csrf", &browser.csrf)
        .append_pair("action", action)
        .finish()
}

async fn seed_member(pool: &PgPool, workspace: Uuid, hash: &str) -> (Uuid, String) {
    let user = Uuid::new_v4();
    let email = format!("approval-{user}@example.test");
    sqlx::query("INSERT INTO users(id,email,password_hash) VALUES($1,$2,$3)")
        .bind(user)
        .bind(&email)
        .bind(hash)
        .execute(pool)
        .await
        .unwrap();
    sqlx::query("INSERT INTO workspaces(id,name) VALUES($1,'Approval browser fixture') ON CONFLICT DO NOTHING")
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
    let response = app
        .clone()
        .oneshot(
            Request::builder()
                .method("POST")
                .uri("/v1/auth/login")
                .header(header::CONTENT_TYPE, "application/json")
                .body(Body::from(
                    json!({"email":email,"password":PASSWORD,"workspace_id":workspace}).to_string(),
                ))
                .unwrap(),
        )
        .await
        .unwrap();
    assert_eq!(response.status(), StatusCode::OK);
    serde_json::from_slice(&response.into_body().collect().await.unwrap().to_bytes()).unwrap()
}

async fn seed_account(state: &AppState, auth: &AuthContext) -> Uuid {
    let id = Uuid::new_v4();
    let credentials = Credentials {
        access_token: "fixture-never-sent-to-provider".into(),
        refresh_token: None,
        expires_at: Utc::now() + Duration::days(1),
        scopes: vec![],
    };
    let sealed = state
        .crypto
        .seal(
            auth.workspace_id,
            id,
            &serde_json::to_vec(&credentials).unwrap(),
        )
        .unwrap();
    let mut tx = auth.begin(&state.pool).await.unwrap();
    sqlx::query("INSERT INTO provider_accounts(id,workspace_id,user_id,provider,email,display_name,encrypted_credentials) VALUES($1,$2,$3,'gmail','sender@example.test',$4,$5)")
        .bind(id).bind(auth.workspace_id).bind(auth.user_id).bind("Sender <script>alert('name')</script>").bind(sealed)
        .execute(&mut *tx).await.unwrap();
    tx.commit().await.unwrap();
    id
}

async fn seed_message(state: &AppState, auth: &AuthContext, account: Uuid) -> Uuid {
    let fixture = json!({
        "id":"approval-trash-fixture", "threadId":"immutable-thread-fixture", "internalDate":"1730610000000",
        "snippet":"Trash preview <img src=x onerror=alert(1)>", "labelIds":["INBOX"],
        "payload":{"mimeType":"text/plain","headers":[
            {"name":"Subject","value":"Message to trash <script>alert('subject')</script>"},
            {"name":"From","value":"Sender <sender@example.test>"}
        ],"body":{"data":URL_SAFE_NO_PAD.encode("Fixture body")}}
    });
    let message = postmere_providers::normalize_gmail(account, &fixture).unwrap();
    let mut tx = auth.begin(&state.pool).await.unwrap();
    sqlx::query("INSERT INTO mail_messages(id,workspace_id,user_id,account_id,provider_message_id,provider_thread_id,sent_at,normalized,search_text) VALUES($1,$2,$3,$4,$5,$6,$7,$8,'Approval fixture')")
        .bind(message.id).bind(auth.workspace_id).bind(auth.user_id).bind(account)
        .bind(&message.provider_message_id).bind(&message.provider_thread_id).bind(message.sent_at)
        .bind(serde_json::to_value(&message).unwrap()).execute(&mut *tx).await.unwrap();
    tx.commit().await.unwrap();
    message.id
}

fn content(account: Uuid) -> DraftContent {
    DraftContent {
        account_id: Some(account),
        to: vec![Address { name: Some("Pat <svg onload=alert(1)>".into()), email: "to@example.test".into() }],
        cc: vec![Address { name: None, email: "cc@example.test".into() }],
        bcc: vec![Address { name: None, email: "private-bcc@example.test".into() }],
        subject: SUBJECT.into(),
        text_body: format!("Untrusted <script>alert('body')</script> & message.\n{}\nEnd of full immutable body.", "A full paragraph.\n".repeat(1000)),
        html_body: Some("<p>HTML version</p><img src=\"https://outside.example/track\"><script>alert('html')</script>".into()),
        attachments: vec![SendAttachment { filename: "notes <img onerror=alert(1)>.txt".into(), mime_type: "text/plain".into(), data_base64: STANDARD.encode("fixture file") }],
        scheduled_at: Some(Utc::now() + Duration::hours(1)),
        undo_seconds: Some(15), track_opens: true, track_links: false,
        in_reply_to: Some("<prior@example.test>".into()),
        references: vec!["<older@example.test>".into()],
        provider_thread_id: Some("immutable-thread-fixture".into()),
        ..Default::default()
    }
}

async fn send_request(state: &AppState, auth: &AuthContext, account: Uuid) -> Approval {
    let draft = create_draft(
        state,
        auth,
        CreateDraft {
            request_id: Uuid::new_v4(),
            content: content(account),
        },
    )
    .await
    .unwrap();
    request_approval(
        state,
        auth,
        ApprovalInput::SendDraft {
            request_id: Uuid::new_v4(),
            draft_id: draft.id,
            expected_version: draft.version,
        },
    )
    .await
    .unwrap()
}

async fn outbox_count(state: &AppState, auth: &AuthContext) -> i64 {
    let mut tx = auth.begin(&state.pool).await.unwrap();
    sqlx::query_scalar("SELECT count(*) FROM mail_outbox")
        .fetch_one(&mut *tx)
        .await
        .unwrap()
}

fn assert_boundary(headers: &HeaderMap) {
    assert_eq!(headers[header::CACHE_CONTROL], "no-store");
    assert_eq!(headers[header::X_CONTENT_TYPE_OPTIONS], "nosniff");
    assert_eq!(headers[header::REFERRER_POLICY], "no-referrer");
    let csp = headers[header::CONTENT_SECURITY_POLICY].to_str().unwrap();
    for required in [
        "default-src 'none'",
        "style-src 'self'",
        "form-action 'self'",
        "frame-ancestors 'none'",
        "base-uri 'none'",
    ] {
        assert!(csp.contains(required), "{csp}");
    }
    assert!(!csp.contains("unsafe-inline") && !csp.contains("unsafe-eval"));
}

fn assert_login_redirect(response: &(StatusCode, HeaderMap, String), path: &str) {
    assert_eq!(response.0, StatusCode::SEE_OTHER);
    let location = response.1[header::LOCATION].to_str().unwrap();
    let url = url::Url::parse(&format!("{ORIGIN}{location}")).unwrap();
    assert_eq!(url.path(), "/mcp/login");
    assert_eq!(
        url.query_pairs().find(|(key, _)| key == "next").unwrap().1,
        path
    );
    assert!(!response.2.contains("Private approval"));
}

#[tokio::test]
async fn browser_approvals_require_owner_origin_csrf_and_explicit_post() {
    let url = std::env::var("POSTMERE_TEST_DATABASE_URL")
        .expect("Set the isolated non-bypass PostgreSQL test database URL");
    let pool = db::connect(&url).await.unwrap();
    db::migrate(&pool).await.unwrap();
    let state = AppState::new(pool.clone(), common::config(url))
        .await
        .unwrap();
    // This router has no background workers. Fake credentials and future
    // scheduling ensure fixture approvals cannot contact or deliver to a provider.
    let app = application(state.clone(), postmere_mcp::router());
    let workspace = Uuid::new_v4();
    let foreign_workspace = Uuid::new_v4();
    let hash = hash_password(Zeroizing::new(PASSWORD.into()))
        .await
        .unwrap();
    let (user, email) = seed_member(&pool, workspace, &hash).await;
    let (peer, peer_email) = seed_member(&pool, workspace, &hash).await;
    let (outsider, outsider_email) = seed_member(&pool, foreign_workspace, &hash).await;
    let session = login(&app, workspace, &email).await;
    let peer_session = login(&app, workspace, &peer_email).await;
    let outside_session = login(&app, foreign_workspace, &outsider_email).await;
    let auth = state.auth.authenticate(&session.token).await.unwrap();
    let (assistant_token, assistant_client) = mcp_bearer(&state, &session).await;
    let owner = browser(&pool, &session).await;
    let owner_second_browser = browser(&pool, &session).await;
    let peer_browser = browser(&pool, &peer_session).await;
    let outside_browser = browser(&pool, &outside_session).await;
    let account = seed_account(&state, &auth).await;
    let message = seed_message(&state, &auth, account).await;
    let draft = create_draft(
        &state,
        &auth,
        CreateDraft {
            request_id: Uuid::new_v4(),
            content: content(account),
        },
    )
    .await
    .unwrap();
    let approval = request_approval(
        &state,
        &auth,
        ApprovalInput::SendDraft {
            request_id: Uuid::new_v4(),
            draft_id: draft.id,
            expected_version: draft.version,
        },
    )
    .await
    .unwrap();
    let path = format!("/mcp/approvals/{}", approval.id);

    for bearer in [
        None,
        Some(session.token.as_str()),
        Some(assistant_token.as_str()),
    ] {
        assert_login_redirect(
            &raw(&app, "GET", &path, None, bearer, None, "").await,
            &path,
        );
        assert_login_redirect(
            &raw(
                &app,
                "POST",
                &path,
                None,
                bearer,
                Some(ORIGIN),
                &decision(&owner, "approve"),
            )
            .await,
            &path,
        );
    }

    let (status, headers, html) = raw(&app, "GET", &path, Some(&owner), None, None, "").await;
    assert_eq!(status, StatusCode::OK);
    assert_boundary(&headers);
    if let Some(directory) = std::env::var_os("POSTMERE_APPROVAL_PREVIEW_DIR") {
        let directory = std::path::PathBuf::from(directory);
        std::fs::create_dir_all(directory.join("mcp")).unwrap();
        std::fs::write(directory.join("index.html"), &html).unwrap();
        std::fs::write(
            directory.join("mcp/approvals.css"),
            include_str!("../crates/postmere-mcp/static/approvals.css"),
        )
        .unwrap();
    }
    for value in [
        "sender@example.test",
        "to@example.test",
        "cc@example.test",
        "private-bcc@example.test",
        "End of full immutable body.",
        "notes &lt;img onerror=alert(1)&gt;.txt",
        "Review HTML source",
        "15 seconds",
        "Open tracking",
        "Link tracking",
        "Awaiting your approval",
        "&lt;prior@example.test&gt;",
        "&lt;older@example.test&gt;",
        "immutable-thread-fixture",
    ] {
        assert!(html.contains(value), "Missing review detail {value}");
    }
    assert!(html.contains("Private approval &lt;img src=x onerror=alert(1)&gt;"));
    assert!(html.contains("&lt;script&gt;alert(&#39;body&#39;)&lt;/script&gt;"));
    assert!(!html.contains("<script") && !html.contains("<img") && !html.contains("<iframe"));
    assert!(!html.contains("fixture-never-sent-to-provider") && !html.contains(&session.token));
    assert!(
        html.contains(&format!("action=\"{path}\""))
            && html.contains(&format!("value=\"{}\"", owner.csrf))
    );
    assert_eq!(
        get_approval(&state, &auth, approval.id)
            .await
            .unwrap()
            .status,
        "pending"
    );
    assert_eq!(
        outbox_count(&state, &auth).await,
        0,
        "GET must not queue mail"
    );
    let css = raw(&app, "GET", "/mcp/approvals.css", None, None, None, "").await;
    assert_eq!(css.0, StatusCode::OK);
    assert_eq!(css.1[header::CONTENT_TYPE], "text/css; charset=utf-8");
    assert!(!css.2.contains("url(") && !css.2.contains("@import"));

    // A later draft edit cannot silently change the browser review.
    let mut edited = draft.content.clone();
    edited.subject = "Changed after approval request".into();
    edited.to = vec![Address {
        name: None,
        email: "changed@example.test".into(),
    }];
    update_draft(
        &state,
        &auth,
        UpdateDraft {
            draft_id: draft.id,
            expected_version: draft.version,
            content: edited,
        },
    )
    .await
    .unwrap();
    let html = raw(&app, "GET", &path, Some(&owner), None, None, "")
        .await
        .2;
    assert!(
        html.contains("Private approval &lt;img")
            && !html.contains("Changed after approval request")
            && !html.contains("changed@example.test")
    );

    for other in [&peer_browser, &outside_browser] {
        let response = raw(&app, "GET", &path, Some(other), None, None, "").await;
        assert_eq!(response.0, StatusCode::NOT_FOUND);
        assert!(
            !response.2.contains("Private approval")
                && !response.2.contains("private-bcc@example.test")
        );
        let response = raw(
            &app,
            "POST",
            &path,
            Some(other),
            None,
            Some(ORIGIN),
            &decision(other, "approve"),
        )
        .await;
        assert_eq!(response.0, StatusCode::NOT_FOUND);
        assert!(!response.2.contains("Private approval"));
    }
    for origin in [None, Some("https://outside.example"), Some("null")] {
        assert_eq!(
            raw(
                &app,
                "POST",
                &path,
                Some(&owner),
                None,
                origin,
                &decision(&owner, "approve")
            )
            .await
            .0,
            StatusCode::FORBIDDEN
        );
    }
    let wrong_csrf = decision(&owner_second_browser, "approve");
    assert_eq!(
        raw(
            &app,
            "POST",
            &path,
            Some(&owner),
            None,
            Some(ORIGIN),
            &wrong_csrf
        )
        .await
        .0,
        StatusCode::FORBIDDEN
    );
    assert_eq!(
        raw(
            &app,
            "POST",
            &path,
            Some(&owner),
            None,
            Some(ORIGIN),
            "action=approve"
        )
        .await
        .0,
        StatusCode::BAD_REQUEST
    );
    assert_eq!(
        raw(
            &app,
            "POST",
            &path,
            Some(&owner),
            None,
            Some(ORIGIN),
            &format!("csrf={}&action=approve&action=cancel", owner.csrf)
        )
        .await
        .0,
        StatusCode::BAD_REQUEST
    );
    assert_eq!(
        get_approval(&state, &auth, approval.id)
            .await
            .unwrap()
            .status,
        "pending"
    );
    assert_eq!(
        outbox_count(&state, &auth).await,
        0,
        "rejected requests must not queue mail"
    );

    let cancelled = raw(
        &app,
        "POST",
        &path,
        Some(&owner),
        None,
        Some(ORIGIN),
        &decision(&owner, "cancel"),
    )
    .await;
    assert_eq!(cancelled.0, StatusCode::SEE_OTHER);
    assert_eq!(cancelled.1[header::LOCATION], path);
    assert_eq!(
        get_approval(&state, &auth, approval.id)
            .await
            .unwrap()
            .status,
        "cancelled"
    );
    let cancelled_html = raw(&app, "GET", &path, Some(&owner), None, None, "")
        .await
        .2;
    assert!(
        cancelled_html.contains("Request cancelled")
            && !cancelled_html.contains("value=\"approve\"")
    );
    let _ = raw(
        &app,
        "POST",
        &path,
        Some(&owner),
        None,
        Some(ORIGIN),
        &decision(&owner, "approve"),
    )
    .await;
    assert_eq!(
        get_approval(&state, &auth, approval.id)
            .await
            .unwrap()
            .status,
        "cancelled"
    );
    assert_eq!(outbox_count(&state, &auth).await, 0);

    let expired = send_request(&state, &auth, account).await;
    let expired_path = format!("/mcp/approvals/{}", expired.id);
    let mut tx = auth.begin(&pool).await.unwrap();
    sqlx::query("UPDATE mcp_mail_approvals SET created_at=now()-interval '2 hours',expires_at=now()-interval '1 hour' WHERE id=$1")
        .bind(expired.id).execute(&mut *tx).await.unwrap();
    tx.commit().await.unwrap();
    let expired_response = raw(&app, "GET", &expired_path, Some(&owner), None, None, "").await;
    assert_eq!(expired_response.0, StatusCode::OK);
    assert!(
        expired_response.2.contains("Request expired")
            && !expired_response.2.contains("value=\"approve\"")
    );
    let mut tx = auth.begin(&pool).await.unwrap();
    let stored_status: String =
        sqlx::query_scalar("SELECT status FROM mcp_mail_approvals WHERE id=$1")
            .bind(expired.id)
            .fetch_one(&mut *tx)
            .await
            .unwrap();
    tx.commit().await.unwrap();
    assert_eq!(
        stored_status, "pending",
        "opening an expired request is still read-only"
    );
    let _ = raw(
        &app,
        "POST",
        &expired_path,
        Some(&owner),
        None,
        Some(ORIGIN),
        &decision(&owner, "approve"),
    )
    .await;
    assert_eq!(
        outbox_count(&state, &auth).await,
        0,
        "expired approval cannot send"
    );

    // Explicit approval queues one isolated fixture send. No delivery worker is
    // started; all fixture rows are deleted at the end of this test.
    let accepted = send_request(&state, &auth, account).await;
    let accepted_path = format!("/mcp/approvals/{}", accepted.id);
    for _ in 0..2 {
        let response = raw(
            &app,
            "POST",
            &accepted_path,
            Some(&owner),
            None,
            Some(ORIGIN),
            &decision(&owner, "approve"),
        )
        .await;
        assert_eq!(response.0, StatusCode::SEE_OTHER, "{}", response.2);
        assert_eq!(response.1[header::LOCATION], accepted_path);
    }
    assert_eq!(
        get_approval(&state, &auth, accepted.id)
            .await
            .unwrap()
            .status,
        "completed"
    );
    assert_eq!(
        outbox_count(&state, &auth).await,
        1,
        "approval resubmission must not create duplicate sends"
    );
    let completed_html = raw(&app, "GET", &accepted_path, Some(&owner), None, None, "")
        .await
        .2;
    assert!(
        completed_html.contains("Action approved") && !completed_html.contains("value=\"approve\"")
    );

    let disconnect = request_approval(
        &state,
        &auth,
        ApprovalInput::DisconnectAccount {
            request_id: Uuid::new_v4(),
            account_id: account,
        },
    )
    .await
    .unwrap();
    let disconnect_path = format!("/mcp/approvals/{}", disconnect.id);
    let disconnect_html = raw(&app, "GET", &disconnect_path, Some(&owner), None, None, "")
        .await
        .2;
    assert!(
        disconnect_html.contains("Disconnect this account?")
            && disconnect_html.contains("sender@example.test")
    );
    assert!(
        disconnect_html.contains("Sender &lt;script&gt;") && !disconnect_html.contains("<script")
    );
    assert_eq!(
        get_approval(&state, &auth, disconnect.id)
            .await
            .unwrap()
            .status,
        "pending"
    );
    let mut tx = auth.begin(&pool).await.unwrap();
    let disabled: bool =
        sqlx::query_scalar("SELECT disabled_at IS NOT NULL FROM provider_accounts WHERE id=$1")
            .bind(account)
            .fetch_one(&mut *tx)
            .await
            .unwrap();
    tx.commit().await.unwrap();
    assert!(!disabled, "GET must not disconnect an account");

    let trash = request_approval(
        &state,
        &auth,
        ApprovalInput::TrashMessage {
            request_id: Uuid::new_v4(),
            message_id: message,
        },
    )
    .await
    .unwrap();
    let trash_path = format!("/mcp/approvals/{}", trash.id);
    let trash_html = raw(&app, "GET", &trash_path, Some(&owner), None, None, "")
        .await
        .2;
    assert!(
        trash_html.contains("Move this message to Trash?")
            && trash_html.contains("sender@example.test")
    );
    assert!(
        trash_html.contains("Message to trash &lt;script&gt;") && !trash_html.contains("<script")
    );
    assert_eq!(
        get_approval(&state, &auth, trash.id).await.unwrap().status,
        "pending"
    );
    let mut tx = auth.begin(&pool).await.unwrap();
    let mailbox: String =
        sqlx::query_scalar("SELECT normalized->>'mailbox' FROM mail_messages WHERE id=$1")
            .bind(message)
            .fetch_one(&mut *tx)
            .await
            .unwrap();
    tx.commit().await.unwrap();
    assert_eq!(mailbox, "inbox", "GET must not move a message");

    // Browser sessions are revalidated independently of a still-valid bearer.
    sqlx::query(
        "UPDATE mcp_browser_sessions SET expires_at=now()-interval '1 minute' WHERE token_hash=$1",
    )
    .bind(Sha256::digest(owner.cookie.as_bytes()).to_vec())
    .execute(&pool)
    .await
    .unwrap();
    assert_login_redirect(
        &raw(
            &app,
            "GET",
            &disconnect_path,
            Some(&owner),
            Some(&session.token),
            None,
            "",
        )
        .await,
        &disconnect_path,
    );
    sqlx::query("UPDATE memberships SET revoked_at=now() WHERE workspace_id=$1 AND user_id=$2")
        .bind(workspace)
        .bind(user)
        .execute(&pool)
        .await
        .unwrap();
    assert_login_redirect(
        &raw(
            &app,
            "GET",
            &disconnect_path,
            Some(&owner_second_browser),
            None,
            None,
            "",
        )
        .await,
        &disconnect_path,
    );

    sqlx::query("DELETE FROM workspaces WHERE id=ANY($1)")
        .bind(vec![workspace, foreign_workspace])
        .execute(&pool)
        .await
        .unwrap();
    sqlx::query("DELETE FROM users WHERE id=ANY($1)")
        .bind(vec![user, peer, outsider])
        .execute(&pool)
        .await
        .unwrap();
    sqlx::query("DELETE FROM mcp_oauth_clients WHERE id=$1")
        .bind(assistant_client)
        .execute(&pool)
        .await
        .unwrap();
}
