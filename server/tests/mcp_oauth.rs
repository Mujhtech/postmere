mod common;

use axum::{
    Json, Router,
    body::Body,
    extract::State,
    http::{HeaderMap, Request, StatusCode},
    routing::get,
};
use base64::{
    Engine,
    engine::general_purpose::{STANDARD, URL_SAFE_NO_PAD},
};
use http_body_util::BodyExt;
use postmere_core::{
    AppState,
    auth::{SessionResponse, hash_password},
    db,
    error::AppError,
};
use postmere_server::application;
use serde_json::{Value, json};
use sha2::{Digest, Sha256};
use sqlx::Row;
use std::{collections::HashMap, time::Duration};
use tower::ServiceExt;
use uuid::Uuid;
use zeroize::Zeroizing;

const ORIGIN: &str = "https://postmere.example.test";
const RESOURCE: &str = "https://postmere.example.test/mcp";
const REDIRECT: &str = "https://client.example.test/callback";
const VERIFIER: &str = "test-pkce-verifier-abcdefghijklmnopqrstuvwxyz0123456789";
const PASSWORD: &str = "remote MCP integration fixture password";

struct Reply {
    status: StatusCode,
    headers: HeaderMap,
    body: String,
}
impl Reply {
    fn json(&self) -> Value {
        serde_json::from_str(&self.body).unwrap()
    }
    fn location(&self) -> &str {
        self.headers["location"].to_str().unwrap()
    }
    fn cookie(&self, name: &str) -> String {
        self.headers
            .get_all("set-cookie")
            .iter()
            .map(|v| v.to_str().unwrap())
            .find(|v| v.starts_with(&format!("{name}=")))
            .unwrap()
            .split(';')
            .next()
            .unwrap()
            .to_string()
    }
}
async fn request(
    app: &Router,
    method: &str,
    path: &str,
    headers: &[(&str, &str)],
    body: String,
) -> Reply {
    let mut builder = Request::builder().method(method).uri(path);
    for (name, value) in headers {
        builder = builder.header(*name, *value);
    }
    let response = app
        .clone()
        .oneshot(builder.body(Body::from(body)).unwrap())
        .await
        .unwrap();
    assert_eq!(response.headers()["cache-control"], "no-store");
    let status = response.status();
    let headers = response.headers().clone();
    let body = String::from_utf8(
        response
            .into_body()
            .collect()
            .await
            .unwrap()
            .to_bytes()
            .to_vec(),
    )
    .unwrap();
    Reply {
        status,
        headers,
        body,
    }
}
fn encoded(parameters: &[(&str, &str)]) -> String {
    url::form_urlencoded::Serializer::new(String::new())
        .extend_pairs(parameters.iter().copied())
        .finish()
}
async fn form(
    app: &Router,
    path: &str,
    headers: &[(&str, &str)],
    parameters: &[(&str, &str)],
) -> Reply {
    let mut headers = headers.to_vec();
    headers.push(("content-type", "application/x-www-form-urlencoded"));
    request(app, "POST", path, &headers, encoded(parameters)).await
}
fn hidden(body: &str, name: &str) -> String {
    body.split(&format!("name=\"{name}\" value=\""))
        .nth(1)
        .unwrap()
        .split('"')
        .next()
        .unwrap()
        .to_string()
}
fn bearer(token: &str) -> HeaderMap {
    let mut headers = HeaderMap::new();
    headers.insert("authorization", format!("Bearer {token}").parse().unwrap());
    headers
}
async fn authenticated(
    State(state): State<AppState>,
    headers: HeaderMap,
) -> Result<Json<Value>, AppError> {
    let principal = postmere_mcp_auth::authenticate(&state, &headers).await?;
    let grant = principal.begin_authorized(&state.pool).await?;
    let tx = principal.auth.begin_authorized(&state.pool).await?;
    tx.commit().await?;
    grant.commit().await?;
    Ok(Json(
        json!({"user":principal.auth.user_id,"workspace":principal.auth.workspace_id,"scopes":principal.scopes}),
    ))
}
struct Fixture {
    state: AppState,
    app: Router,
    workspace: Uuid,
    user: Uuid,
    email: String,
}
impl Fixture {
    async fn new() -> Self {
        let database = std::env::var("POSTMERE_TEST_DATABASE_URL").expect(
            "Set POSTMERE_TEST_DATABASE_URL to an isolated non-superuser NOBYPASSRLS database",
        );
        let pool = db::connect(&database).await.unwrap();
        db::migrate(&pool).await.unwrap();
        let mut config = common::config(database);
        config.public_base_url = ORIGIN.parse().unwrap();
        config.mcp_redirect_uris = vec![REDIRECT.into()];
        let state = AppState::new(pool, config).await.unwrap();
        let app = application(
            state.clone(),
            postmere_mcp_auth::router().route("/test/mcp", get(authenticated)),
        );
        let workspace = Uuid::new_v4();
        let user = Uuid::new_v4();
        let email = format!("mcp-{user}@example.test");
        let hash = hash_password(Zeroizing::new(PASSWORD.into()))
            .await
            .unwrap();
        sqlx::query("INSERT INTO users(id,email,password_hash) VALUES($1,$2,$3)")
            .bind(user)
            .bind(&email)
            .bind(hash)
            .execute(&state.pool)
            .await
            .unwrap();
        sqlx::query("INSERT INTO workspaces(id,name) VALUES($1,'MCP OAuth fixture')")
            .bind(workspace)
            .execute(&state.pool)
            .await
            .unwrap();
        sqlx::query("INSERT INTO memberships(workspace_id,user_id,role) VALUES($1,$2,'owner')")
            .bind(workspace)
            .bind(user)
            .execute(&state.pool)
            .await
            .unwrap();
        Self {
            state,
            app,
            workspace,
            user,
            email,
        }
    }
    async fn browser(&self) -> String {
        let page = request(&self.app, "GET", "/mcp/login", &[], String::new()).await;
        let csrf = hidden(&page.body, "csrf_token");
        let cookie = page.cookie("postmere_mcp_login");
        let reply = form(
            &self.app,
            "/mcp/login",
            &[("origin", ORIGIN), ("cookie", &cookie)],
            &[
                ("csrf_token", &csrf),
                ("next", "/mcp/connected"),
                ("email", &self.email),
                ("password", PASSWORD),
                ("workspace_id", &self.workspace.to_string()),
            ],
        )
        .await;
        assert_eq!(reply.status, StatusCode::SEE_OTHER);
        reply.cookie("postmere_mcp_browser")
    }
    async fn register(&self, method: &str) -> Value {
        let reply = request(&self.app,"POST","/mcp/register",&[("content-type","application/json")],
            json!({"client_name":"Assistant <img src=x>","redirect_uris":[REDIRECT],"token_endpoint_auth_method":method}).to_string()).await;
        assert_eq!(reply.status, StatusCode::CREATED);
        reply.json()
    }
    async fn authorize(&self, client: &str, browser: Option<&str>, scopes: &str) -> Reply {
        let challenge = URL_SAFE_NO_PAD.encode(Sha256::digest(VERIFIER.as_bytes()));
        let query = encoded(&[
            ("response_type", "code"),
            ("client_id", client),
            ("redirect_uri", REDIRECT),
            ("resource", RESOURCE),
            ("scope", scopes),
            ("state", "fixture-state + &"),
            ("code_challenge", &challenge),
            ("code_challenge_method", "S256"),
        ]);
        let headers = browser
            .map(|cookie| vec![("cookie", cookie)])
            .unwrap_or_default();
        request(
            &self.app,
            "GET",
            &format!("/mcp/authorize?{query}"),
            &headers,
            String::new(),
        )
        .await
    }
    async fn code(&self, client: &str, browser: &str, scopes: &str) -> String {
        let pending = self.authorize(client, Some(browser), scopes).await;
        assert_eq!(pending.status, StatusCode::SEE_OTHER);
        let consent = request(
            &self.app,
            "GET",
            pending.location(),
            &[("cookie", browser)],
            String::new(),
        )
        .await;
        assert_eq!(consent.status, StatusCode::OK);
        assert!(consent.body.contains("Assistant &lt;img src=x&gt;"));
        assert!(!consent.body.contains("Assistant <img"));
        let reply = form(
            &self.app,
            pending.location(),
            &[("origin", ORIGIN), ("cookie", browser)],
            &[
                ("csrf_token", &hidden(&consent.body, "csrf_token")),
                ("decision", "approve"),
            ],
        )
        .await;
        assert_eq!(reply.status, StatusCode::SEE_OTHER);
        let target = url::Url::parse(reply.location()).unwrap();
        let fields: HashMap<_, _> = target.query_pairs().into_owned().collect();
        assert_eq!(fields["state"], "fixture-state + &");
        assert_eq!(fields["iss"], ORIGIN);
        fields["code"].clone()
    }
    async fn exchange(&self, client: &str, code: &str, basic: Option<&str>) -> Reply {
        let headers = basic
            .map(|value| vec![("authorization", value)])
            .unwrap_or_default();
        form(
            &self.app,
            "/mcp/token",
            &headers,
            &[
                ("grant_type", "authorization_code"),
                ("client_id", client),
                ("code", code),
                ("redirect_uri", REDIRECT),
                ("resource", RESOURCE),
                ("code_verifier", VERIFIER),
            ],
        )
        .await
    }
    async fn access(&self, token: &str) -> StatusCode {
        request(
            &self.app,
            "GET",
            "/test/mcp",
            &[("authorization", &format!("Bearer {token}"))],
            String::new(),
        )
        .await
        .status
    }
}

#[tokio::test]
async fn browser_oauth_pkce_token_boundaries_rotation_and_revocation() {
    let fixture = Fixture::new().await;
    let f = &fixture;
    let metadata = request(
        &f.app,
        "GET",
        "/.well-known/oauth-protected-resource/mcp",
        &[],
        String::new(),
    )
    .await
    .json();
    assert_eq!(metadata["resource"], RESOURCE);
    assert_eq!(metadata["authorization_servers"], json!([ORIGIN]));
    let metadata = request(
        &f.app,
        "GET",
        "/.well-known/oauth-authorization-server",
        &[],
        String::new(),
    )
    .await
    .json();
    assert_eq!(
        metadata["code_challenge_methods_supported"],
        json!(["S256"])
    );
    for redirect in [
        "https://attacker.example.test/callback",
        "https://client.example.test/callback?extra=1",
    ] {
        let rejected = request(
            &f.app,
            "POST",
            "/mcp/register",
            &[("content-type", "application/json")],
            json!({"client_name":"bad redirect","redirect_uris":[redirect]}).to_string(),
        )
        .await;
        assert_eq!(rejected.status, StatusCode::BAD_REQUEST);
    }
    let public = f.register("none").await;
    let client = public["client_id"].as_str().unwrap();
    assert!(public.get("client_secret").is_none());
    let pending = f
        .authorize(client, None, "mail:read mail:draft mail:send mail:manage")
        .await;
    assert_eq!(pending.status, StatusCode::SEE_OTHER);
    let unauthenticated = request(&f.app, "GET", pending.location(), &[], String::new()).await;
    assert!(unauthenticated.location().starts_with("/mcp/login?next="));

    let page = request(
        &f.app,
        "GET",
        "/mcp/login?next=https://attacker.example.test",
        &[],
        String::new(),
    )
    .await;
    assert_eq!(hidden(&page.body, "next"), "/mcp/connected");
    assert!(
        page.headers["set-cookie"]
            .to_str()
            .unwrap()
            .contains("; Secure")
    );
    assert!(
        page.headers["set-cookie"]
            .to_str()
            .unwrap()
            .contains("HttpOnly; SameSite=Lax")
    );
    assert!(
        page.headers["content-security-policy"]
            .to_str()
            .unwrap()
            .contains("frame-ancestors 'none'")
    );
    let login_cookie = page.cookie("postmere_mcp_login");
    let csrf = hidden(&page.body, "csrf_token");
    let workspace = f.workspace.to_string();
    let login_fields = [
        ("csrf_token", csrf.as_str()),
        ("next", "/mcp/connected"),
        ("email", f.email.as_str()),
        ("password", PASSWORD),
        ("workspace_id", workspace.as_str()),
    ];
    assert_eq!(
        form(
            &f.app,
            "/mcp/login",
            &[("cookie", &login_cookie)],
            &login_fields
        )
        .await
        .status,
        StatusCode::FORBIDDEN
    );
    assert_eq!(
        form(
            &f.app,
            "/mcp/login",
            &[
                ("cookie", &login_cookie),
                ("origin", "https://attacker.example.test")
            ],
            &login_fields
        )
        .await
        .status,
        StatusCode::FORBIDDEN
    );
    let duplicate = format!("{login_cookie}; {login_cookie}");
    assert_eq!(
        form(
            &f.app,
            "/mcp/login",
            &[("cookie", &duplicate), ("origin", ORIGIN)],
            &login_fields
        )
        .await
        .status,
        StatusCode::FORBIDDEN
    );
    let browser = f.browser().await;
    let other_browser = f.browser().await;
    let consent = request(
        &f.app,
        "GET",
        pending.location(),
        &[("cookie", &browser)],
        String::new(),
    )
    .await;
    assert_eq!(consent.status, StatusCode::OK);
    assert_eq!(
        request(
            &f.app,
            "GET",
            pending.location(),
            &[("cookie", &other_browser)],
            String::new()
        )
        .await
        .status,
        StatusCode::FORBIDDEN
    );
    assert_eq!(
        form(
            &f.app,
            pending.location(),
            &[("cookie", &browser), ("origin", ORIGIN)],
            &[("csrf_token", "incorrect"), ("decision", "approve")]
        )
        .await
        .status,
        StatusCode::FORBIDDEN
    );
    let decision_fields = [
        ("csrf_token", hidden(&consent.body, "csrf_token")),
        ("decision", "deny".to_string()),
    ];
    let decision_refs: Vec<_> = decision_fields
        .iter()
        .map(|(k, v)| (*k, v.as_str()))
        .collect();
    assert_eq!(
        form(
            &f.app,
            pending.location(),
            &[("cookie", &browser)],
            &decision_refs
        )
        .await
        .status,
        StatusCode::FORBIDDEN
    );
    let denied = form(
        &f.app,
        pending.location(),
        &[("cookie", &browser), ("origin", ORIGIN)],
        &decision_refs,
    )
    .await;
    assert!(denied.location().contains("error=access_denied"));
    assert_eq!(
        form(
            &f.app,
            pending.location(),
            &[("cookie", &browser), ("origin", ORIGIN)],
            &decision_refs
        )
        .await
        .status,
        StatusCode::BAD_REQUEST
    );

    let code = f
        .code(
            client,
            &browser,
            "mail:read mail:draft mail:send mail:manage",
        )
        .await;
    let bad_fields = [
        ("grant_type", "authorization_code"),
        ("client_id", client),
        ("code", code.as_str()),
        ("redirect_uri", REDIRECT),
        ("resource", RESOURCE),
        ("code_verifier", "bad"),
    ];
    assert_eq!(
        form(&f.app, "/mcp/token", &[], &bad_fields).await.json()["error"],
        "invalid_grant"
    );
    let mut wrong_resource = bad_fields;
    wrong_resource[4].1 = "https://attacker.example.test/mcp";
    wrong_resource[5].1 = VERIFIER;
    assert_eq!(
        form(&f.app, "/mcp/token", &[], &wrong_resource)
            .await
            .json()["error"],
        "invalid_target"
    );
    let mut wrong_redirect = bad_fields;
    wrong_redirect[3].1 = "https://client.example.test/callback?extra=1";
    wrong_redirect[5].1 = VERIFIER;
    assert_eq!(
        form(&f.app, "/mcp/token", &[], &wrong_redirect)
            .await
            .json()["error"],
        "invalid_grant"
    );
    let tokens = f.exchange(client, &code, None).await;
    assert_eq!(tokens.status, StatusCode::OK);
    let tokens = tokens.json();
    let access = tokens["access_token"].as_str().unwrap();
    let refresh = tokens["refresh_token"].as_str().unwrap();
    assert_eq!(f.access(access).await, StatusCode::OK);
    assert_eq!(f.access(refresh).await, StatusCode::UNAUTHORIZED);
    assert_eq!(f.access(&code).await, StatusCode::UNAUTHORIZED);
    assert!(
        f.state.auth.authenticate(access).await.is_err(),
        "MCP token must not unlock workspace REST APIs"
    );
    let row = sqlx::query("SELECT t.token_hash,g.id FROM mcp_access_tokens t JOIN mcp_oauth_grants g ON g.id=t.grant_id WHERE t.token_hash=$1")
        .bind(Sha256::digest(access.as_bytes()).to_vec()).fetch_one(&f.state.pool).await.unwrap();
    assert_eq!(row.get::<Vec<u8>, _>("token_hash").len(), 32);
    assert_ne!(row.get::<Vec<u8>, _>("token_hash"), access.as_bytes());
    let reduced = form(
        &f.app,
        "/mcp/token",
        &[],
        &[
            ("grant_type", "refresh_token"),
            ("client_id", client),
            ("refresh_token", refresh),
            ("resource", RESOURCE),
            ("scope", "mail:read"),
        ],
    )
    .await;
    assert_eq!(reduced.status, StatusCode::OK);
    let reduced = reduced.json();
    assert_eq!(reduced["scope"], "mail:read");
    let principal = postmere_mcp_auth::authenticate(&f.state, &bearer(access))
        .await
        .unwrap();
    assert!(
        principal.require_scope("mail:send").is_err(),
        "old access tokens also lose removed scopes"
    );
    let next_refresh = reduced["refresh_token"].as_str().unwrap();
    assert_eq!(
        form(
            &f.app,
            "/mcp/token",
            &[],
            &[
                ("grant_type", "refresh_token"),
                ("client_id", client),
                ("refresh_token", next_refresh),
                ("resource", RESOURCE),
                ("scope", "mail:send")
            ]
        )
        .await
        .json()["error"],
        "invalid_scope"
    );
    assert_eq!(
        form(
            &f.app,
            "/mcp/token",
            &[],
            &[
                ("grant_type", "refresh_token"),
                ("client_id", client),
                ("refresh_token", refresh),
                ("resource", RESOURCE)
            ]
        )
        .await
        .json()["error"],
        "invalid_grant"
    );
    assert_eq!(f.access(access).await, StatusCode::UNAUTHORIZED);
    assert_eq!(
        f.access(reduced["access_token"].as_str().unwrap()).await,
        StatusCode::UNAUTHORIZED,
        "refresh replay revokes descendants"
    );

    let confidential = f.register("client_secret_basic").await;
    let confidential_id = confidential["client_id"].as_str().unwrap();
    let basic = format!(
        "Basic {}",
        STANDARD.encode(format!(
            "{confidential_id}:{}",
            confidential["client_secret"].as_str().unwrap()
        ))
    );
    let expired_code = f.code(confidential_id, &browser, "mail:read").await;
    sqlx::query(
        "UPDATE mcp_oauth_codes SET expires_at=now()-interval '1 second' WHERE token_hash=$1",
    )
    .bind(Sha256::digest(expired_code.as_bytes()).to_vec())
    .execute(&f.state.pool)
    .await
    .unwrap();
    assert_eq!(
        f.exchange(confidential_id, &expired_code, Some(&basic))
            .await
            .json()["error"],
        "invalid_grant"
    );
    let code = f.code(confidential_id, &browser, "mail:read").await;
    assert_eq!(
        f.exchange(confidential_id, &code, None).await.json()["error"],
        "invalid_client"
    );
    assert_eq!(
        f.exchange(client, &code, None).await.json()["error"],
        "invalid_grant"
    );
    let tokens = f.exchange(confidential_id, &code, Some(&basic)).await;
    assert_eq!(tokens.status, StatusCode::OK);
    let tokens = tokens.json();
    let access = tokens["access_token"].as_str().unwrap();
    assert_eq!(f.access(access).await, StatusCode::OK);
    assert_eq!(
        form(
            &f.app,
            "/mcp/revoke",
            &[],
            &[("client_id", client), ("token", access)]
        )
        .await
        .status,
        StatusCode::OK
    );
    assert_eq!(
        f.access(access).await,
        StatusCode::OK,
        "another client cannot revoke this grant"
    );
    sqlx::query(
        "UPDATE mcp_oauth_codes SET expires_at=now()-interval '1 second' WHERE token_hash=$1",
    )
    .bind(Sha256::digest(code.as_bytes()).to_vec())
    .execute(&f.state.pool)
    .await
    .unwrap();
    assert_eq!(
        f.exchange(confidential_id, &code, Some(&basic))
            .await
            .json()["error"],
        "invalid_grant"
    );
    assert_eq!(
        f.access(access).await,
        StatusCode::UNAUTHORIZED,
        "spent authorization codes detect replay even after code expiry"
    );

    // A workspace token and browser cookie never pass the MCP bearer boundary.
    let session = request(
        &f.app,
        "POST",
        "/v1/auth/login",
        &[("content-type", "application/json")],
        json!({"email":f.email,"password":PASSWORD,"workspace_id":f.workspace}).to_string(),
    )
    .await;
    let session: SessionResponse = serde_json::from_value(session.json()).unwrap();
    assert_eq!(f.access(&session.token).await, StatusCode::UNAUTHORIZED);
    assert_eq!(
        f.access(browser.split('=').nth(1).unwrap()).await,
        StatusCode::UNAUTHORIZED
    );
    let code = f.code(client, &browser, "mail:read").await;
    let tokens = f.exchange(client, &code, None).await.json();
    let access = tokens["access_token"].as_str().unwrap();
    for revoke_membership in [true, false] {
        let old = postmere_mcp_auth::authenticate(&f.state, &bearer(access))
            .await
            .unwrap();
        if revoke_membership {
            sqlx::query(
                "UPDATE memberships SET revoked_at=now() WHERE workspace_id=$1 AND user_id=$2",
            )
            .bind(f.workspace)
            .bind(f.user)
            .execute(&f.state.pool)
            .await
            .unwrap();
            assert_eq!(f.access(access).await, StatusCode::UNAUTHORIZED);
        } else {
            sqlx::query(
                "UPDATE memberships SET role='member' WHERE workspace_id=$1 AND user_id=$2",
            )
            .bind(f.workspace)
            .bind(f.user)
            .execute(&f.state.pool)
            .await
            .unwrap();
            assert!(
                old.auth.begin_authorized(&f.state.pool).await.is_err(),
                "stale roles cannot survive final authorization"
            );
        }
        sqlx::query("UPDATE memberships SET revoked_at=NULL,role='owner' WHERE workspace_id=$1 AND user_id=$2").bind(f.workspace).bind(f.user).execute(&f.state.pool).await.unwrap();
    }
    let principal = postmere_mcp_auth::authenticate(&f.state, &bearer(access))
        .await
        .unwrap();
    sqlx::query("UPDATE sessions SET revoked_at=now() WHERE id=$1")
        .bind(principal.auth.session_id)
        .execute(&f.state.pool)
        .await
        .unwrap();
    assert_eq!(f.access(access).await, StatusCode::UNAUTHORIZED);
    assert_eq!(
        form(
            &f.app,
            "/mcp/token",
            &[],
            &[
                ("grant_type", "refresh_token"),
                ("client_id", client),
                ("refresh_token", tokens["refresh_token"].as_str().unwrap()),
                ("resource", RESOURCE)
            ]
        )
        .await
        .json()["error"],
        "invalid_grant"
    );
    assert!(
        postmere_mcp_auth::browser_session(&f.state, &{
            let mut h = HeaderMap::new();
            h.insert("cookie", browser.parse().unwrap());
            h
        })
        .await
        .is_ok(),
        "Revoking a grant's session does not revoke its independent browser session"
    );
}

#[tokio::test]
async fn concurrent_refresh_and_authorization_guards_close_revocation_expiry_races() {
    let fixture = Fixture::new().await;
    let f = &fixture;
    let browser = f.browser().await;
    let client = f.register("none").await["client_id"]
        .as_str()
        .unwrap()
        .to_string();
    let code = f.code(&client, &browser, "mail:read mail:send").await;
    let tokens = f.exchange(&client, &code, None).await.json();
    let fields = [
        ("grant_type", "refresh_token"),
        ("client_id", client.as_str()),
        ("refresh_token", tokens["refresh_token"].as_str().unwrap()),
        ("resource", RESOURCE),
    ];
    let (a, b) = tokio::join!(
        form(&f.app, "/mcp/token", &[], &fields),
        form(&f.app, "/mcp/token", &[], &fields)
    );
    assert!(matches!(
        (a.status, b.status),
        (StatusCode::OK, StatusCode::BAD_REQUEST) | (StatusCode::BAD_REQUEST, StatusCode::OK)
    ));
    let winner = if a.status == StatusCode::OK {
        a.json()
    } else {
        b.json()
    };
    assert_eq!(
        f.access(winner["access_token"].as_str().unwrap()).await,
        StatusCode::UNAUTHORIZED,
        "concurrent replay revokes the rotated token family"
    );

    let code = f.code(&client, &browser, "mail:read mail:send").await;
    let tokens = f.exchange(&client, &code, None).await.json();
    let access = tokens["access_token"].as_str().unwrap().to_string();
    let principal = postmere_mcp_auth::authenticate(&f.state, &bearer(&access))
        .await
        .unwrap();
    let guard = principal.begin_authorized(&f.state.pool).await.unwrap();
    let app = f.app.clone();
    let client_copy = client.clone();
    let token_copy = access.clone();
    let mut revoke = tokio::spawn(async move {
        form(
            &app,
            "/mcp/revoke",
            &[],
            &[("client_id", &client_copy), ("token", &token_copy)],
        )
        .await
        .status
    });
    assert!(
        tokio::time::timeout(Duration::from_millis(80), &mut revoke)
            .await
            .is_err(),
        "revocation waits for already authorized tool operations"
    );
    guard.commit().await.unwrap();
    assert_eq!(revoke.await.unwrap(), StatusCode::OK);
    assert!(
        principal.begin_authorized(&f.state.pool).await.is_err(),
        "stale in-memory context cannot bypass completed revocation"
    );

    let code = f.code(&client, &browser, "mail:read mail:send").await;
    let tokens = f.exchange(&client, &code, None).await.json();
    let access = tokens["access_token"].as_str().unwrap();
    let principal = postmere_mcp_auth::authenticate(&f.state, &bearer(access))
        .await
        .unwrap();
    let reduced = form(
        &f.app,
        "/mcp/token",
        &[],
        &[
            ("grant_type", "refresh_token"),
            ("client_id", &client),
            ("refresh_token", tokens["refresh_token"].as_str().unwrap()),
            ("resource", RESOURCE),
            ("scope", "mail:read"),
        ],
    )
    .await;
    assert_eq!(reduced.status, StatusCode::OK);
    assert!(
        principal.begin_authorized(&f.state.pool).await.is_err(),
        "scope reduction invalidates stale operation authority"
    );
    let principal = postmere_mcp_auth::authenticate(&f.state, &bearer(access))
        .await
        .unwrap();
    sqlx::query("UPDATE mcp_access_tokens SET expires_at=clock_timestamp()+interval '150 milliseconds' WHERE token_hash=$1")
        .bind(Sha256::digest(access.as_bytes()).to_vec()).execute(&f.state.pool).await.unwrap();
    let mut locked = f.state.pool.begin().await.unwrap();
    sqlx::query("SELECT id FROM mcp_oauth_grants WHERE id=$1 FOR UPDATE")
        .bind(principal.grant_id)
        .fetch_one(&mut *locked)
        .await
        .unwrap();
    let pool = f.state.pool.clone();
    let mut waiting = tokio::spawn(async move { principal.begin_authorized(&pool).await.is_err() });
    assert!(
        tokio::time::timeout(Duration::from_millis(200), &mut waiting)
            .await
            .is_err()
    );
    locked.commit().await.unwrap();
    assert!(
        waiting.await.unwrap(),
        "grant lock waits must recheck wall-clock token expiry"
    );

    // A refresh blocked on identity must already hold the grant lock. This
    // prevents tools and queued identity revocations forming a lock-order cycle.
    let code = f.code(&client, &browser, "mail:read").await;
    let tokens = f.exchange(&client, &code, None).await.json();
    let principal = postmere_mcp_auth::authenticate(
        &f.state,
        &bearer(tokens["access_token"].as_str().unwrap()),
    )
    .await
    .unwrap();
    let mut identity_lock = f.state.pool.begin().await.unwrap();
    let blocker: i32 = sqlx::query_scalar("SELECT pg_backend_pid()")
        .fetch_one(&mut *identity_lock)
        .await
        .unwrap();
    sqlx::query("SELECT id FROM users WHERE id=$1 FOR UPDATE")
        .bind(f.user)
        .fetch_one(&mut *identity_lock)
        .await
        .unwrap();
    let app = f.app.clone();
    let client_copy = client.clone();
    let refresh_token = tokens["refresh_token"].as_str().unwrap().to_string();
    let refresh = tokio::spawn(async move {
        form(
            &app,
            "/mcp/token",
            &[],
            &[
                ("grant_type", "refresh_token"),
                ("client_id", &client_copy),
                ("refresh_token", &refresh_token),
                ("resource", RESOURCE),
            ],
        )
        .await
        .status
    });
    tokio::time::timeout(Duration::from_secs(3),async {
        loop {
            let blocked:bool=sqlx::query_scalar("SELECT EXISTS(SELECT 1 FROM pg_stat_activity WHERE $1 = ANY(pg_blocking_pids(pid)))")
                .bind(blocker).fetch_one(&f.state.pool).await.unwrap();
            if blocked { break; }
            tokio::time::sleep(Duration::from_millis(5)).await;
        }
    }).await.expect("refresh must reach its identity lock");
    let pool = f.state.pool.clone();
    let mut tool = tokio::spawn(async move {
        let tx = principal.begin_authorized(&pool).await?;
        tx.rollback().await.map_err(AppError::from)
    });
    assert!(
        tokio::time::timeout(Duration::from_millis(80), &mut tool)
            .await
            .is_err(),
        "refresh must lock grant before identity"
    );
    identity_lock.commit().await.unwrap();
    assert_eq!(refresh.await.unwrap(), StatusCode::OK);
    assert!(tool.await.unwrap().is_ok());
}

impl Fixture {
    async fn native(&self) -> SessionResponse {
        let response = request(
            &self.app,
            "POST",
            "/v1/auth/login",
            &[("content-type", "application/json")],
            json!({"email":self.email,"password":PASSWORD,"workspace_id":self.workspace})
                .to_string(),
        )
        .await;
        assert_eq!(response.status, StatusCode::OK);
        serde_json::from_value(response.json()).unwrap()
    }
    async fn refresh(&self, client: &str, token: &str) -> Reply {
        form(
            &self.app,
            "/mcp/token",
            &[],
            &[
                ("grant_type", "refresh_token"),
                ("client_id", client),
                ("refresh_token", token),
                ("resource", RESOURCE),
            ],
        )
        .await
    }
    async fn tokens(&self, client: &str, browser: &str) -> Value {
        let code = self.code(client, browser, "mail:read").await;
        let response = self.exchange(client, &code, None).await;
        assert_eq!(response.status, StatusCode::OK);
        response.json()
    }
}

#[tokio::test]
async fn persistent_mcp_survives_browser_expiration_and_aged_grants_until_signout() {
    let f = Fixture::new().await;
    let browser = f.browser().await;
    let client = f.register("none").await["client_id"]
        .as_str()
        .unwrap()
        .to_string();
    let tokens = f.tokens(&client, &browser).await;
    let access = tokens["access_token"].as_str().unwrap();
    let principal = postmere_mcp_auth::authenticate(&f.state, &bearer(access))
        .await
        .unwrap();
    let lifetimes = sqlx::query("SELECT g.expires_at AS grant_expiry,s.expires_at,s.absolute_expires_at,s.kind FROM mcp_oauth_grants g JOIN sessions s ON s.id=g.session_id WHERE g.id=$1")
        .bind(principal.grant_id).fetch_one(&f.state.pool).await.unwrap();
    assert!(
        lifetimes
            .get::<Option<chrono::DateTime<chrono::Utc>>, _>("grant_expiry")
            .is_none()
    );
    assert!(
        lifetimes
            .get::<Option<chrono::DateTime<chrono::Utc>>, _>("expires_at")
            .is_none()
    );
    assert!(
        lifetimes
            .get::<Option<chrono::DateTime<chrono::Utc>>, _>("absolute_expires_at")
            .is_none()
    );
    assert_eq!(lifetimes.get::<String, _>("kind"), "mcp_grant");
    sqlx::query("UPDATE sessions SET created_at=now()-interval '400 days' WHERE id=$1")
        .bind(principal.auth.session_id)
        .execute(&f.state.pool)
        .await
        .unwrap();
    sqlx::query("UPDATE mcp_oauth_grants SET created_at=now()-interval '400 days' WHERE id=$1")
        .bind(principal.grant_id)
        .execute(&f.state.pool)
        .await
        .unwrap();
    sqlx::query("UPDATE mcp_browser_sessions SET expires_at=now()-interval '1 second' WHERE session_id IN (SELECT id FROM sessions WHERE user_id=$1)").bind(f.user).execute(&f.state.pool).await.unwrap();
    sqlx::query(
        "UPDATE mcp_access_tokens SET expires_at=now()-interval '1 second' WHERE grant_id=$1",
    )
    .bind(principal.grant_id)
    .execute(&f.state.pool)
    .await
    .unwrap();
    assert_eq!(f.access(access).await, StatusCode::UNAUTHORIZED);
    let response = f
        .refresh(&client, tokens["refresh_token"].as_str().unwrap())
        .await;
    assert_eq!(response.status, StatusCode::OK);
    let renewed = response.json();
    assert!(renewed["expires_in"].as_i64().unwrap() <= 900);
    assert_eq!(
        f.access(renewed["access_token"].as_str().unwrap()).await,
        StatusCode::OK
    );
    let native = f.native().await;
    let other_native = f.native().await;
    let logout = request(
        &f.app,
        "POST",
        "/v1/auth/logout",
        &[("authorization", &format!("Bearer {}", native.token))],
        String::new(),
    )
    .await;
    assert_eq!(logout.status, StatusCode::NO_CONTENT);
    assert_eq!(
        f.access(renewed["access_token"].as_str().unwrap()).await,
        StatusCode::UNAUTHORIZED
    );
    assert_eq!(
        f.refresh(&client, renewed["refresh_token"].as_str().unwrap())
            .await
            .json()["error"],
        "invalid_grant"
    );
    assert!(
        f.state.auth.authenticate(&other_native.token).await.is_ok(),
        "Workspace MCP signout must preserve other native sessions"
    );
}

#[tokio::test]
async fn delayed_signout_preserves_later_grants_and_login_cleanup_preserves_all_mcp() {
    let f = Fixture::new().await;
    let native = f.native().await;
    let browser = f.browser().await;
    let client = f.register("none").await["client_id"]
        .as_str()
        .unwrap()
        .to_string();
    let old = f.tokens(&client, &browser).await;
    let cutoff = chrono::Utc::now();
    let later = f.tokens(&client, &browser).await;
    // Failed/cancelled native login cleanup is not an intentional workspace signout.
    let cleanup = f.native().await;
    assert_eq!(
        request(
            &f.app,
            "POST",
            "/v1/auth/logout",
            &[
                ("authorization", &format!("Bearer {}", cleanup.token)),
                ("content-type", "application/json")
            ],
            json!({"revoke_mcp":false}).to_string()
        )
        .await
        .status,
        StatusCode::NO_CONTENT
    );
    assert_eq!(
        f.access(old["access_token"].as_str().unwrap()).await,
        StatusCode::OK
    );
    assert_eq!(
        request(
            &f.app,
            "POST",
            "/v1/auth/logout",
            &[
                ("authorization", &format!("Bearer {}", native.token)),
                ("content-type", "application/json")
            ],
            json!({"signed_out_at":cutoff}).to_string()
        )
        .await
        .status,
        StatusCode::NO_CONTENT
    );
    assert_eq!(
        f.access(old["access_token"].as_str().unwrap()).await,
        StatusCode::UNAUTHORIZED
    );
    assert_eq!(
        f.access(later["access_token"].as_str().unwrap()).await,
        StatusCode::OK
    );
    assert_eq!(
        f.refresh(&client, later["refresh_token"].as_str().unwrap())
            .await
            .status,
        StatusCode::OK
    );
    let page = request(
        &f.app,
        "GET",
        "/mcp/connected",
        &[("cookie", &browser)],
        String::new(),
    )
    .await;
    assert_eq!(
        page.status,
        StatusCode::SEE_OTHER,
        "Signout invalidates the old browser cookie too"
    );
}

#[tokio::test]
async fn connected_clients_are_scoped_and_browser_revoke_and_signout_require_csrf() {
    let f = Fixture::new().await;
    let native = f.native().await;
    let browser = f.browser().await;
    let client = f.register("none").await["client_id"]
        .as_str()
        .unwrap()
        .to_string();
    let first = f.tokens(&client, &browser).await;
    let second = f.tokens(&client, &browser).await;
    let principal =
        postmere_mcp_auth::authenticate(&f.state, &bearer(first["access_token"].as_str().unwrap()))
            .await
            .unwrap();
    let other = Fixture::new().await;
    let other_native = other.native().await;
    let path = format!("/v1/mcp/connections/{}", principal.grant_id);
    assert_eq!(
        request(
            &f.app,
            "DELETE",
            &path,
            &[("authorization", &format!("Bearer {}", other_native.token))],
            String::new()
        )
        .await
        .status,
        StatusCode::NOT_FOUND
    );
    let listing = request(
        &f.app,
        "GET",
        "/v1/mcp/connections",
        &[("authorization", &format!("Bearer {}", native.token))],
        String::new(),
    )
    .await;
    assert_eq!(listing.json().as_array().unwrap().len(), 2);
    let page = request(
        &f.app,
        "GET",
        "/mcp/connected",
        &[("cookie", &browser)],
        String::new(),
    )
    .await;
    assert!(page.body.contains("Assistant &lt;img src=x&gt;"));
    if let Some(directory) = std::env::var_os("POSTMERE_CONNECTIONS_PREVIEW_DIR") {
        let directory = std::path::PathBuf::from(directory);
        std::fs::create_dir_all(&directory).unwrap();
        std::fs::write(directory.join("index.html"), &page.body).unwrap();
    }
    let csrf = hidden(&page.body, "csrf_token");
    let path = format!("/mcp/connections/{}/revoke", principal.grant_id);
    assert_eq!(
        form(
            &f.app,
            &path,
            &[("cookie", &browser)],
            &[("csrf_token", &csrf)]
        )
        .await
        .status,
        StatusCode::FORBIDDEN
    );
    assert_eq!(
        form(
            &f.app,
            &path,
            &[("cookie", &browser), ("origin", ORIGIN)],
            &[("csrf_token", &csrf)]
        )
        .await
        .status,
        StatusCode::SEE_OTHER
    );
    assert_eq!(
        f.access(first["access_token"].as_str().unwrap()).await,
        StatusCode::UNAUTHORIZED
    );
    assert_eq!(
        f.access(second["access_token"].as_str().unwrap()).await,
        StatusCode::OK
    );
    assert_eq!(
        form(
            &f.app,
            "/mcp/logout",
            &[("cookie", &browser), ("origin", ORIGIN)],
            &[("csrf_token", "bad")]
        )
        .await
        .status,
        StatusCode::FORBIDDEN
    );
    let logout = form(
        &f.app,
        "/mcp/logout",
        &[("cookie", &browser), ("origin", ORIGIN)],
        &[("csrf_token", &csrf)],
    )
    .await;
    assert_eq!(logout.status, StatusCode::OK);
    assert!(
        logout.headers["set-cookie"]
            .to_str()
            .unwrap()
            .contains("Max-Age=0")
    );
    assert_eq!(
        f.access(second["access_token"].as_str().unwrap()).await,
        StatusCode::UNAUTHORIZED
    );
}
