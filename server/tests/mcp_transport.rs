mod common;

use axum::{
    Router,
    body::Body,
    http::{HeaderMap, Request, StatusCode},
};
use base64::{Engine, engine::general_purpose::URL_SAFE_NO_PAD};
use http_body_util::BodyExt;
use postmere_core::{
    AppState,
    auth::{LoginRequest, SessionResponse, hash_password},
    db,
};
use postmere_server::application;
use serde_json::{Value, json};
use sha2::{Digest, Sha256};
use tower::ServiceExt;
use uuid::Uuid;
use zeroize::Zeroizing;

async fn request(
    app: &Router,
    method: &str,
    token: Option<&str>,
    host: &str,
    origin: Option<&str>,
    payload: &str,
) -> (StatusCode, HeaderMap, Value) {
    let mut request = Request::builder()
        .method(method)
        .uri("/mcp")
        .header("host", host)
        .header("accept", "application/json, text/event-stream")
        .header("content-type", "application/json")
        .header("mcp-protocol-version", "2025-06-18");
    if let Some(token) = token {
        request = request.header("authorization", format!("Bearer {token}"));
    }
    if let Some(origin) = origin {
        request = request.header("origin", origin);
    }
    let response = app
        .clone()
        .oneshot(request.body(Body::from(payload.to_string())).unwrap())
        .await
        .unwrap();
    let status = response.status();
    let headers = response.headers().clone();
    let bytes = response.into_body().collect().await.unwrap().to_bytes();
    let body = serde_json::from_slice(&bytes)
        .unwrap_or_else(|_| json!({"text":String::from_utf8_lossy(&bytes)}));
    (status, headers, body)
}
async fn rpc(
    app: &Router,
    token: &str,
    method: &str,
    params: Value,
) -> (StatusCode, HeaderMap, Value) {
    request(
        app,
        "POST",
        Some(token),
        "127.0.0.1:8080",
        None,
        &json!({"jsonrpc":"2.0","id":1,"method":method,"params":params}).to_string(),
    )
    .await
}
async fn user(state: &AppState, ws: Uuid, hash: &str) -> SessionResponse {
    let id = Uuid::new_v4();
    let email = format!("mcp-transport-{id}@example.test");
    sqlx::query("INSERT INTO users(id,email,password_hash) VALUES($1,$2,$3)")
        .bind(id)
        .bind(&email)
        .bind(hash)
        .execute(&state.pool)
        .await
        .unwrap();
    sqlx::query("INSERT INTO memberships(workspace_id,user_id,role) VALUES($1,$2,'owner')")
        .bind(ws)
        .bind(id)
        .execute(&state.pool)
        .await
        .unwrap();
    state
        .auth
        .login_browser(
            LoginRequest {
                email,
                password: "MCP transport test password".into(),
                workspace_id: ws,
            },
            "mcp-transport-fixture",
        )
        .await
        .unwrap()
}
async fn grant(
    state: &AppState,
    session: &SessionResponse,
    scopes: &[&str],
) -> (String, Uuid, String) {
    let client = Uuid::new_v4().to_string();
    let grant = Uuid::new_v4();
    let mut random = [0u8; 32];
    getrandom::fill(&mut random).unwrap();
    let token = format!("pm_mcp_{}", URL_SAFE_NO_PAD.encode(random));
    sqlx::query("INSERT INTO mcp_oauth_clients(id,name,redirect_uris,auth_method) VALUES($1,'Transport fixture',$2,'none')").bind(&client).bind(vec!["https://client.example/callback"]).execute(&state.pool).await.unwrap();
    sqlx::query("INSERT INTO mcp_oauth_grants(id,session_id,client_id,resource,scopes,expires_at) VALUES($1,$2,$3,'http://127.0.0.1:8080/mcp',$4,$5)").bind(grant).bind(session.session_id).bind(&client).bind(scopes).bind(session.expires_at).execute(&state.pool).await.unwrap();
    sqlx::query("INSERT INTO mcp_access_tokens(token_hash,grant_id,expires_at) VALUES($1,$2,$3)")
        .bind(Sha256::digest(token.as_bytes()).to_vec())
        .bind(grant)
        .bind(session.expires_at)
        .execute(&state.pool)
        .await
        .unwrap();
    (token, grant, client)
}

#[tokio::test]
async fn remote_protocol_scopes_isolation_and_revocation() {
    let url = std::env::var("POSTMERE_TEST_DATABASE_URL")
        .expect("Use an isolated NOBYPASSRLS test database");
    let pool = db::connect(&url).await.unwrap();
    db::migrate(&pool).await.unwrap();
    let state = AppState::new(pool.clone(), common::config(url))
        .await
        .unwrap();
    let app = application(state.clone(), postmere_mcp::router());
    let ws = Uuid::new_v4();
    sqlx::query("INSERT INTO workspaces(id,name) VALUES($1,'Transport fixture')")
        .bind(ws)
        .execute(&pool)
        .await
        .unwrap();
    let hash = hash_password(Zeroizing::new("MCP transport test password".into()))
        .await
        .unwrap();
    let session = user(&state, ws, &hash).await;
    let other = user(&state, ws, &hash).await;
    let (token, grant_id, client) = grant(
        &state,
        &session,
        &["mail:read", "mail:draft", "mail:manage", "mail:send"],
    )
    .await;
    let (read_token, _, read_client) = grant(&state, &session, &["mail:read"]).await;
    let (other_token, _, other_client) = grant(&state, &other, &["mail:read", "mail:draft"]).await;

    let (status, headers, _) = request(&app, "POST", None, "127.0.0.1:8080", None, "{}").await;
    assert_eq!(status, StatusCode::UNAUTHORIZED);
    assert!(
        headers["www-authenticate"]
            .to_str()
            .unwrap()
            .contains("/.well-known/oauth-protected-resource/mcp")
    );
    assert_eq!(
        request(
            &app,
            "POST",
            Some(&session.token),
            "127.0.0.1:8080",
            None,
            "{}"
        )
        .await
        .0,
        StatusCode::UNAUTHORIZED
    );
    assert_eq!(
        request(&app, "POST", Some(&token), "evil.example", None, "{}")
            .await
            .0,
        StatusCode::FORBIDDEN
    );
    assert_eq!(
        request(
            &app,
            "POST",
            Some(&token),
            "127.0.0.1:8080",
            Some("https://evil.example"),
            "{}"
        )
        .await
        .0,
        StatusCode::FORBIDDEN
    );
    assert_eq!(
        request(
            &app,
            "POST",
            Some(&token),
            "127.0.0.1:8080",
            None,
            &" ".repeat(1024 * 1024 + 1)
        )
        .await
        .0,
        StatusCode::PAYLOAD_TOO_LARGE
    );

    let (status,headers,body)=rpc(&app,&token,"initialize",json!({"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"test","version":"1"}})).await;
    assert_eq!(status, StatusCode::OK, "{body}");
    assert_eq!(body["result"]["serverInfo"]["name"], "postmere");
    assert!(!headers.contains_key("mcp-session-id"));
    let (status, _, body) = rpc(&app, &token, "tools/list", json!({})).await;
    assert_eq!(status, StatusCode::OK, "{body}");
    let tools = body["result"]["tools"].as_array().unwrap();
    assert_eq!(tools.len(), 16);
    assert!(
        !tools
            .iter()
            .any(|tool| tool["name"] == "approve_action" || tool["name"] == "send")
    );
    let (_, _, body) = rpc(&app, &read_token, "tools/list", json!({})).await;
    assert_eq!(body["result"]["tools"].as_array().unwrap().len(), 16);
    assert!(
        body["result"]["tools"]
            .as_array()
            .unwrap()
            .iter()
            .all(|t| t["_meta"]["securitySchemes"][0]["type"] == "oauth2")
    );
    let (status, headers, _) = rpc(
        &app,
        &read_token,
        "tools/call",
        json!({"name":"create_draft","arguments":{"request_id":Uuid::new_v4(),"content":{}}}),
    )
    .await;
    assert_eq!(status, StatusCode::FORBIDDEN);
    assert!(
        headers["www-authenticate"]
            .to_str()
            .unwrap()
            .contains("mail:draft")
    );

    let account = Uuid::new_v4();
    let mut tx = db::scoped_transaction(&pool, ws, session.user_id)
        .await
        .unwrap();
    sqlx::query("INSERT INTO provider_accounts(id,workspace_id,user_id,provider,email,encrypted_credentials) VALUES($1,$2,$3,'gmail','fixture@example.test',$4)")
        .bind(account).bind(ws).bind(session.user_id).bind(vec![0u8;32]).execute(&mut *tx).await.unwrap();
    tx.commit().await.unwrap();
    let request_id = Uuid::new_v4();
    let arguments = json!({"request_id":request_id,"content":{"account_id":account,"to":[{"email":"recipient@example.test"}],"subject":"untrusted <instructions>","text_body":"fixture only"}});
    let (status, _, body) = rpc(
        &app,
        &token,
        "tools/call",
        json!({"name":"create_draft","arguments":arguments}),
    )
    .await;
    assert_eq!(status, StatusCode::OK, "{body}");
    assert_eq!(body["result"]["isError"], false, "{body}");
    let draft = body["result"]["structuredContent"].clone();
    assert_eq!(draft["version"], 1);
    let (send_token, _, send_client) = grant(&state, &session, &["mail:send"]).await;
    let (_,_,response)=rpc(&app,&send_token,"tools/call",json!({"name":"request_send","arguments":{"request_id":Uuid::new_v4(),"draft_id":draft["id"],"expected_version":1}})).await;
    assert_eq!(response["result"]["isError"], false, "{response}");
    let approval = &response["result"]["structuredContent"];
    assert_eq!(approval["status"], "pending");
    assert!(approval.get("review").is_none());
    assert!(!response.to_string().contains("fixture only"));
    assert_eq!(
        rpc(
            &app,
            &send_token,
            "tools/call",
            json!({"name":"get_draft","arguments":{"draft_id":draft["id"]}})
        )
        .await
        .0,
        StatusCode::FORBIDDEN
    );
    let (_, _, response) = rpc(
        &app,
        &read_token,
        "tools/call",
        json!({"name":"get_approval","arguments":{"approval_id":approval["id"]}}),
    )
    .await;
    assert_eq!(response["result"]["isError"], false);
    assert!(
        response["result"]["structuredContent"]
            .get("review")
            .is_none()
    );
    let (_, _, body) = rpc(
        &app,
        &token,
        "tools/call",
        json!({"name":"create_draft","arguments":arguments}),
    )
    .await;
    assert_eq!(body["result"]["structuredContent"]["id"], draft["id"]);
    let (_, _, body) = rpc(
        &app,
        &other_token,
        "tools/call",
        json!({"name":"get_draft","arguments":{"draft_id":draft["id"]}}),
    )
    .await;
    assert_eq!(body["result"]["isError"], true);
    assert_eq!(
        body["result"]["structuredContent"]["error"]["code"],
        "not_found"
    );
    let (_,_,body)=rpc(&app,&token,"tools/call",json!({"name":"update_draft","arguments":{"draft_id":draft["id"],"expected_version":42,"content":{}}})).await;
    assert_eq!(body["result"]["isError"], true);
    assert_eq!(
        body["result"]["structuredContent"]["error"]["code"],
        "conflict"
    );
    let (_, _, body) = rpc(
        &app,
        &token,
        "tools/call",
        json!({"name":"approve_action","arguments":{"approval_id":Uuid::new_v4()}}),
    )
    .await;
    assert!(body.get("error").is_some(), "{body}");
    let (_,_,body)=rpc(&app,&token,"tools/call",json!({"name":"manage_message","arguments":{"message_id":Uuid::new_v4(),"mailbox":"trash"}})).await;
    assert!(
        body.get("error").is_some() || body["result"]["isError"] == true,
        "{body}"
    );
    assert_eq!(
        request(&app, "GET", Some(&token), "127.0.0.1:8080", None, "")
            .await
            .0,
        StatusCode::METHOD_NOT_ALLOWED
    );

    sqlx::query("UPDATE mcp_oauth_grants SET revoked_at=clock_timestamp() WHERE id=$1")
        .bind(grant_id)
        .execute(&pool)
        .await
        .unwrap();
    assert_eq!(
        rpc(&app, &token, "tools/list", json!({})).await.0,
        StatusCode::UNAUTHORIZED
    );
    sqlx::query(
        "UPDATE memberships SET revoked_at=clock_timestamp() WHERE user_id=$1 AND workspace_id=$2",
    )
    .bind(other.user_id)
    .bind(ws)
    .execute(&pool)
    .await
    .unwrap();
    assert_eq!(
        rpc(&app, &other_token, "tools/list", json!({})).await.0,
        StatusCode::UNAUTHORIZED
    );
    sqlx::query("DELETE FROM workspaces WHERE id=$1")
        .bind(ws)
        .execute(&pool)
        .await
        .unwrap();
    sqlx::query("DELETE FROM users WHERE id=ANY($1)")
        .bind(vec![session.user_id, other.user_id])
        .execute(&pool)
        .await
        .unwrap();
    sqlx::query("DELETE FROM mcp_oauth_clients WHERE id=ANY($1)")
        .bind(vec![client, read_client, other_client, send_client])
        .execute(&pool)
        .await
        .unwrap();
}
