mod common;
use axum::{
    Router,
    body::Body,
    http::{Request, StatusCode},
};
use chrono::{Duration, Utc};
use http_body_util::BodyExt;
use postmere_calendar::calendar_provider::{
    BookingEvent, CalendarError, CalendarFuture, CalendarTransport, Interval,
};
use postmere_calendar::{self as calendar, BookingRequest, FreeBusyRequest};
use postmere_core::AppState;
use postmere_core::auth::{AuthContext, SessionResponse, hash_password};
use postmere_core::db;
use postmere_mail::mail::{self, AccountSession};
use postmere_providers::Credentials;
use postmere_server::application;
use serde_json::{Value, json};
use sqlx::{PgPool, Row};
use std::sync::{
    Arc,
    atomic::{AtomicUsize, Ordering},
};
use tokio::sync::Notify;
use tower::ServiceExt;
use uuid::Uuid;
use zeroize::Zeroizing;

async fn raw(
    app: &Router,
    method: &str,
    path: &str,
    token: Option<&str>,
    body: Value,
) -> (StatusCode, axum::http::HeaderMap, Vec<u8>) {
    let mut request = Request::builder()
        .method(method)
        .uri(path)
        .header("content-type", "application/json");
    if let Some(token) = token {
        request = request.header("authorization", format!("Bearer {token}"))
    }
    let response = app
        .clone()
        .oneshot(request.body(Body::from(body.to_string())).unwrap())
        .await
        .unwrap();
    let status = response.status();
    let headers = response.headers().clone();
    let bytes = response
        .into_body()
        .collect()
        .await
        .unwrap()
        .to_bytes()
        .to_vec();
    (status, headers, bytes)
}
async fn request(
    app: &Router,
    method: &str,
    path: &str,
    token: Option<&str>,
    body: Value,
) -> (StatusCode, Value) {
    let (status, _, bytes) = raw(app, method, path, token, body).await;
    (
        status,
        serde_json::from_slice(&bytes).unwrap_or(Value::Null),
    )
}
async fn seed(pool: &PgPool, workspace: Uuid, email: &str, hash: &str) -> Uuid {
    let user = Uuid::new_v4();
    sqlx::query("INSERT INTO users(id,email,password_hash) VALUES($1,$2,$3)")
        .bind(user)
        .bind(email)
        .bind(hash)
        .execute(pool)
        .await
        .unwrap();
    sqlx::query(
        "INSERT INTO workspaces(id,name) VALUES($1,'Calendar fixture') ON CONFLICT DO NOTHING",
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
    user
}
async fn login(app: &Router, email: &str, workspace: Uuid) -> SessionResponse {
    let(status,body)=request(app,"POST","/v1/auth/login",None,json!({"email":email,"password":"calendar fixture password long enough","workspace_id":workspace})).await;
    assert_eq!(status, StatusCode::OK, "{body}");
    serde_json::from_value(body).unwrap()
}
async fn account(state: &AppState, auth: &AuthContext, capability: bool) -> Uuid {
    let id = Uuid::new_v4();
    let credentials = Credentials {
        access_token: "fixture-never-sent-to-provider".into(),
        refresh_token: None,
        expires_at: Utc::now() + Duration::days(1),
        scopes: if capability {
            vec!["https://www.googleapis.com/auth/calendar.events".into()]
        } else {
            vec![]
        },
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
    sqlx::query("INSERT INTO provider_accounts(id,workspace_id,user_id,provider,email,encrypted_credentials,capabilities) VALUES($1,$2,$3,'gmail',$4,$5,$6)").bind(id).bind(auth.workspace_id).bind(auth.user_id).bind(format!("{id}@example.test")).bind(sealed).bind(if capability{vec!["calendar"]}else{vec![]}).execute(&mut *tx).await.unwrap();
    tx.commit().await.unwrap();
    id
}
fn link_body(account: Uuid, start: chrono::DateTime<Utc>) -> Value {
    json!({"account_id":account,"title":"Product conversation","description":"A fixture booking. No live provider calls.","time_zone":"Africa/Lagos","duration_minutes":30,"expires_at":start+Duration::days(2),"slots":[{"start":start,"end":start+Duration::minutes(30)},{"start":start+Duration::hours(1),"end":start+Duration::minutes(90)},{"start":start+Duration::hours(2),"end":start+Duration::minutes(150)},{"start":start+Duration::hours(3),"end":start+Duration::minutes(210)},{"start":start+Duration::hours(4),"end":start+Duration::minutes(270)}]})
}
fn secret(link: &Value) -> String {
    url::Url::parse(link["url"].as_str().unwrap())
        .unwrap()
        .path_segments()
        .unwrap()
        .next_back()
        .unwrap()
        .to_owned()
}
fn booking(link: &Value, index: usize) -> BookingRequest {
    BookingRequest {
        client_id: Uuid::new_v4(),
        slot_id: serde_json::from_value(link["slots"][index]["id"].clone()).unwrap(),
        name: "Private Guest".into(),
        email: "private-guest@example.test".into(),
    }
}
struct FixtureCalendar {
    busy: bool,
    outcome: Result<String, CalendarError>,
    creates: AtomicUsize,
    checks: AtomicUsize,
    revoke_during_check: Option<(Uuid, Uuid, Uuid)>,
}
impl FixtureCalendar {
    fn new(busy: bool, outcome: Result<String, CalendarError>) -> Self {
        Self {
            busy,
            outcome,
            creates: AtomicUsize::new(0),
            checks: AtomicUsize::new(0),
            revoke_during_check: None,
        }
    }
}
impl CalendarTransport for FixtureCalendar {
    fn busy<'a>(
        &'a self,
        state: &'a AppState,
        _: &'a AccountSession,
        range: &'a Interval,
    ) -> CalendarFuture<'a, Vec<Interval>> {
        Box::pin(async move {
            self.checks.fetch_add(1, Ordering::SeqCst);
            if let Some((workspace, user, link)) = self.revoke_during_check {
                let mut tx = db::scoped_transaction(&state.pool, workspace, user)
                    .await
                    .unwrap();
                sqlx::query("UPDATE calendar_booking_links SET disabled_at=now() WHERE id=$1")
                    .bind(link)
                    .execute(&mut *tx)
                    .await
                    .unwrap();
                tx.commit().await.unwrap();
            }
            tokio::time::sleep(std::time::Duration::from_millis(120)).await;
            Ok(if self.busy {
                vec![range.clone()]
            } else {
                vec![]
            })
        })
    }
    fn create<'a>(
        &'a self,
        _: &'a AppState,
        _: &'a AccountSession,
        event: &'a BookingEvent,
    ) -> CalendarFuture<'a, String> {
        Box::pin(async move {
            assert_eq!(event.guest_email, "private-guest@example.test");
            self.creates.fetch_add(1, Ordering::SeqCst);
            self.outcome.clone()
        })
    }
}

struct SplitCompletionCalendar {
    fast_account: Uuid,
    fast_finished: Notify,
    slow_started: Notify,
    release_slow: Notify,
}
impl CalendarTransport for SplitCompletionCalendar {
    fn busy<'a>(
        &'a self,
        _: &'a AppState,
        session: &'a AccountSession,
        range: &'a Interval,
    ) -> CalendarFuture<'a, Vec<Interval>> {
        Box::pin(async move {
            if session.account.id == self.fast_account {
                self.fast_finished.notify_one();
            } else {
                self.slow_started.notify_one();
                self.release_slow.notified().await;
            }
            Ok(vec![range.clone()])
        })
    }
    fn create<'a>(
        &'a self,
        _: &'a AppState,
        _: &'a AccountSession,
        _: &'a BookingEvent,
    ) -> CalendarFuture<'a, String> {
        Box::pin(async { panic!("availability must never create a calendar event") })
    }
}

#[tokio::test]
async fn bookings_scope_race_idempotency_encryption_revocation_and_ambiguous_provider() {
    let url = std::env::var("POSTMERE_TEST_DATABASE_URL")
        .expect("Set the isolated non-bypass PostgreSQL test database URL");
    let pool = db::connect(&url).await.unwrap();
    db::migrate(&pool).await.unwrap();
    let state = AppState::new(pool.clone(), common::config(url))
        .await
        .unwrap();
    let app = application(state.clone(), calendar::router().merge(mail::router()));
    let workspace = Uuid::new_v4();
    let foreign = Uuid::new_v4();
    let email = format!("calendar-{}@example.test", Uuid::new_v4());
    let peer_email = format!("calendar-{}@example.test", Uuid::new_v4());
    let other_email = format!("calendar-{}@example.test", Uuid::new_v4());
    let hash = hash_password(Zeroizing::new(
        "calendar fixture password long enough".into(),
    ))
    .await
    .unwrap();
    let user = seed(&pool, workspace, &email, &hash).await;
    let peer = seed(&pool, workspace, &peer_email, &hash).await;
    let other = seed(&pool, foreign, &other_email, &hash).await;
    let owner_session = login(&app, &email, workspace).await;
    let peer_session = login(&app, &peer_email, workspace).await;
    let other_session = login(&app, &other_email, foreign).await;
    let auth = state.auth.authenticate(&owner_session.token).await.unwrap();
    let peer_auth = state.auth.authenticate(&peer_session.token).await.unwrap();
    let host = account(&state, &auth, true).await;
    let mail_only = account(&state, &auth, false).await;
    let peer_calendar = account(&state, &peer_auth, true).await;
    let start = Utc::now() + Duration::days(1);
    assert_eq!(
        request(
            &app,
            "POST",
            "/v1/calendar/booking-links",
            None,
            link_body(host, start)
        )
        .await
        .0,
        StatusCode::UNAUTHORIZED
    );
    assert_eq!(
        request(
            &app,
            "POST",
            "/v1/calendar/booking-links",
            Some(&peer_session.token),
            link_body(host, start)
        )
        .await
        .0,
        StatusCode::NOT_FOUND
    );
    assert_eq!(
        request(
            &app,
            "POST",
            "/v1/calendar/booking-links",
            Some(&owner_session.token),
            link_body(mail_only, start)
        )
        .await
        .0,
        StatusCode::CONFLICT,
        "mail OAuth is not calendar consent"
    );
    let created = request(
        &app,
        "POST",
        "/v1/calendar/booking-links",
        Some(&owner_session.token),
        link_body(host, start),
    )
    .await;
    assert_eq!(created.0, StatusCode::OK, "{}", created.1);
    let link = created.1;
    let token = secret(&link);
    let duplicate_link = request(
        &app,
        "POST",
        "/v1/calendar/booking-links",
        Some(&owner_session.token),
        link_body(host, start + Duration::minutes(15)),
    )
    .await;
    assert_eq!(duplicate_link.0, StatusCode::OK);
    let overlap = duplicate_link.1;
    let list = request(
        &app,
        "GET",
        "/v1/calendar/booking-links",
        Some(&owner_session.token),
        Value::Null,
    )
    .await;
    assert_eq!(list.1["items"].as_array().unwrap().len(), 2);
    for session in [&peer_session, &other_session] {
        assert!(
            request(
                &app,
                "GET",
                "/v1/calendar/booking-links",
                Some(&session.token),
                Value::Null
            )
            .await
            .1["items"]
                .as_array()
                .unwrap()
                .is_empty()
        );
    }
    let page = raw(&app, "GET", &format!("/book/{token}"), None, Value::Null).await;
    assert_eq!(page.0, StatusCode::OK);
    assert!(
        page.1["content-security-policy"]
            .to_str()
            .unwrap()
            .contains("script-src 'self'")
    );
    assert!(!String::from_utf8(page.2).unwrap().contains(&token));
    let link_id: Uuid = serde_json::from_value(link["id"].clone()).unwrap();
    let forged = postmere_core::tokens::scoped_token(workspace, user, link_id).unwrap();
    assert_eq!(
        raw(&app, "GET", &format!("/book/{forged}"), None, Value::Null)
            .await
            .0,
        StatusCode::NOT_FOUND
    );
    assert_eq!(
        request(
            &app,
            "DELETE",
            &format!("/v1/calendar/booking-links/{link_id}"),
            Some(&peer_session.token),
            Value::Null
        )
        .await
        .0,
        StatusCode::NOT_FOUND
    );
    let mut tx = auth.begin(&pool).await.unwrap();
    let row =
        sqlx::query("SELECT encrypted_token,token_hash FROM calendar_booking_links WHERE id=$1")
            .bind(link_id)
            .fetch_one(&mut *tx)
            .await
            .unwrap();
    assert_ne!(row.get::<Vec<u8>, _>("encrypted_token"), token.as_bytes());
    assert_eq!(
        row.get::<Vec<u8>, _>("token_hash"),
        postmere_core::tokens::token_hash(&token)
    );
    tx.commit().await.unwrap();

    // Different links with partially overlapping times compete on the host
    // account, not merely on a slot id. Exactly one reaches the provider write.
    let transport = FixtureCalendar::new(false, Ok("fixture-event".into()));
    let first = booking(&link, 0);
    let rival = booking(&overlap, 0);
    let overlap_token = secret(&overlap);
    let (a, b) = tokio::join!(
        calendar::book_with(&state, &token, first.clone(), &transport),
        calendar::book_with(&state, &overlap_token, rival.clone(), &transport)
    );
    assert_eq!(
        usize::from(a.is_ok()) + usize::from(b.is_ok()),
        1,
        "only one overlapping request may reserve the account"
    );
    let (winning_token, winning_input, confirmed) = match (a, b) {
        (Ok(a), Err(b)) => {
            assert_eq!(b.status, StatusCode::CONFLICT);
            (&token, &first, a)
        }
        (Err(a), Ok(b)) => {
            assert_eq!(a.status, StatusCode::CONFLICT);
            (&overlap_token, &rival, b)
        }
        _ => panic!("unexpected booking race results"),
    };
    assert_eq!(confirmed.status, "confirmed");
    assert_eq!(transport.creates.load(Ordering::SeqCst), 1);
    let repeat = calendar::book_with(&state, winning_token, winning_input.clone(), &transport)
        .await
        .unwrap();
    assert_eq!(repeat.id, confirmed.id);
    assert_eq!(transport.creates.load(Ordering::SeqCst), 1);
    let mut changed = winning_input.clone();
    changed.name = "Different Guest".into();
    assert_eq!(
        calendar::book_with(&state, winning_token, changed, &transport)
            .await
            .unwrap_err()
            .status,
        StatusCode::CONFLICT
    );
    let mut tx = auth.begin(&pool).await.unwrap();
    let encrypted: Vec<u8> =
        sqlx::query_scalar("SELECT encrypted_guest FROM calendar_bookings WHERE id=$1")
            .bind(confirmed.id)
            .fetch_one(&mut *tx)
            .await
            .unwrap();
    assert!(!String::from_utf8_lossy(&encrypted).contains("private-guest"));
    tx.commit().await.unwrap();
    let listed = request(
        &app,
        "GET",
        "/v1/calendar/bookings",
        Some(&owner_session.token),
        Value::Null,
    )
    .await
    .1;
    assert_eq!(
        listed["items"][0]["guest_email"],
        "private-guest@example.test"
    );
    assert!(
        request(
            &app,
            "GET",
            "/v1/calendar/bookings",
            Some(&peer_session.token),
            Value::Null
        )
        .await
        .1["items"]
            .as_array()
            .unwrap()
            .is_empty()
    );
    let mut peer_tx = peer_auth.begin(&pool).await.unwrap();
    let count: i64 = sqlx::query_scalar("SELECT count(*) FROM calendar_bookings")
        .fetch_one(&mut *peer_tx)
        .await
        .unwrap();
    assert_eq!(
        count, 0,
        "forced row-level security applies even to SQL without app predicates"
    );
    peer_tx.rollback().await.unwrap();

    let busy = FixtureCalendar::new(true, Ok("must-not-create".into()));
    assert_eq!(
        calendar::book_with(&state, &token, booking(&link, 1), &busy)
            .await
            .unwrap_err()
            .status,
        StatusCode::CONFLICT
    );
    assert_eq!(busy.creates.load(Ordering::SeqCst), 0);
    let ambiguous = FixtureCalendar::new(false, Err(CalendarError::Ambiguous));
    let uncertain_request = booking(&link, 2);
    let uncertain = calendar::book_with(&state, &token, uncertain_request.clone(), &ambiguous)
        .await
        .unwrap();
    assert_eq!(uncertain.status, "uncertain");
    assert_eq!(
        calendar::book_with(&state, &token, uncertain_request, &ambiguous)
            .await
            .unwrap()
            .status,
        "uncertain"
    );
    assert_eq!(
        ambiguous.creates.load(Ordering::SeqCst),
        1,
        "an ambiguous event creation is never retried"
    );
    assert_eq!(
        calendar::book_with(&state, &token, booking(&link, 2), &transport)
            .await
            .unwrap_err()
            .status,
        StatusCode::CONFLICT,
        "unknown outcome keeps reservation occupied"
    );
    let interrupted_request = booking(&link, 3);
    let interrupted = calendar::book_with(&state, &token, interrupted_request.clone(), &transport)
        .await
        .unwrap();
    let mut tx = auth.begin(&pool).await.unwrap();
    sqlx::query("UPDATE calendar_bookings SET status='creating',provider_event_id=NULL,updated_at=now()-interval '10 minutes' WHERE id=$1").bind(interrupted.id).execute(&mut *tx).await.unwrap();
    tx.commit().await.unwrap();
    let calls = transport.creates.load(Ordering::SeqCst);
    assert_eq!(
        calendar::book_with(&state, &token, interrupted_request, &transport)
            .await
            .unwrap()
            .status,
        "uncertain"
    );
    assert_eq!(
        transport.creates.load(Ordering::SeqCst),
        calls,
        "a process interruption after committing creating cannot resend"
    );

    // Workspace membership is insufficient to inspect somebody's calendar;
    // only an explicit per-account share exposes its busy intervals.
    let range = json!({"account_ids":[peer_calendar],"start":start,"end":start+Duration::hours(1)});
    assert_eq!(
        request(
            &app,
            "POST",
            "/v1/calendar/free-busy",
            Some(&owner_session.token),
            range.clone()
        )
        .await
        .0,
        StatusCode::NOT_FOUND
    );
    let sharing = request(
        &app,
        "GET",
        "/v1/calendar/sharing",
        Some(&owner_session.token),
        Value::Null,
    )
    .await
    .1;
    assert_eq!(sharing["items"].as_array().unwrap().len(), 1);
    assert_eq!(sharing["items"][0]["enabled"], false);
    assert_eq!(
        request(
            &app,
            "PUT",
            &format!("/v1/calendar/sharing/{peer_calendar}"),
            Some(&owner_session.token),
            json!({"enabled":true})
        )
        .await
        .0,
        StatusCode::NOT_FOUND
    );
    assert_eq!(
        request(
            &app,
            "PUT",
            &format!("/v1/calendar/sharing/{peer_calendar}"),
            Some(&peer_session.token),
            json!({"enabled":true})
        )
        .await
        .0,
        StatusCode::OK
    );
    assert_eq!(
        request(
            &app,
            "GET",
            "/v1/calendar/sharing",
            Some(&owner_session.token),
            Value::Null
        )
        .await
        .1["items"]
            .as_array()
            .unwrap()
            .len(),
        2
    );
    assert!(
        request(
            &app,
            "GET",
            "/v1/calendar/sharing",
            Some(&other_session.token),
            Value::Null
        )
        .await
        .1["items"]
            .as_array()
            .unwrap()
            .is_empty(),
        "shares never cross workspaces"
    );
    let shared = calendar::free_busy_with(
        &state,
        &auth,
        FreeBusyRequest {
            account_ids: vec![peer_calendar, host],
            start,
            end: start + Duration::hours(1),
        },
        Arc::new(FixtureCalendar::new(true, Ok("unused".into()))),
    )
    .await
    .unwrap();
    assert_eq!(shared["calendars"].as_array().unwrap().len(), 2);
    assert!(
        shared["calendars"]
            .as_array()
            .unwrap()
            .iter()
            .all(|c| c["busy"].as_array().unwrap().len() == 1)
    );

    // Calendar A finishes first, but its share must still be checked after the
    // blocked calendar B returns. Checking A only when it finishes leaks data
    // if its owner revokes sharing while the response is waiting for B.
    let split = Arc::new(SplitCompletionCalendar {
        fast_account: peer_calendar,
        fast_finished: Notify::new(),
        slow_started: Notify::new(),
        release_slow: Notify::new(),
    });
    let waiting = {
        let state = state.clone();
        let auth = auth.clone();
        let split = split.clone();
        tokio::spawn(async move {
            calendar::free_busy_with(
                &state,
                &auth,
                FreeBusyRequest {
                    account_ids: vec![peer_calendar, host],
                    start,
                    end: start + Duration::hours(1),
                },
                split,
            )
            .await
        })
    };
    tokio::time::timeout(std::time::Duration::from_secs(5), async {
        split.fast_finished.notified().await;
        split.slow_started.notified().await;
    })
    .await
    .unwrap();
    // Give the completed A result time to pass the old per-result check while
    // B remains explicitly blocked; no provider response relies on this delay.
    tokio::time::sleep(std::time::Duration::from_millis(150)).await;
    assert_eq!(
        request(
            &app,
            "PUT",
            &format!("/v1/calendar/sharing/{peer_calendar}"),
            Some(&peer_session.token),
            json!({"enabled":false})
        )
        .await
        .0,
        StatusCode::OK
    );
    split.release_slow.notify_one();
    assert_eq!(
        waiting.await.unwrap().unwrap_err().status,
        StatusCode::NOT_FOUND,
        "a revoked fast calendar must not escape with a later slow result"
    );
    assert_eq!(
        request(
            &app,
            "PUT",
            &format!("/v1/calendar/sharing/{peer_calendar}"),
            Some(&peer_session.token),
            json!({"enabled":true})
        )
        .await
        .0,
        StatusCode::OK
    );

    let expired = Credentials {
        access_token: "expired-fixture".into(),
        refresh_token: None,
        expires_at: Utc::now() - Duration::days(1),
        scopes: vec![],
    };
    let expired = state
        .crypto
        .seal(
            workspace,
            peer_calendar,
            &serde_json::to_vec(&expired).unwrap(),
        )
        .unwrap();
    let mut tx = peer_auth.begin(&pool).await.unwrap();
    sqlx::query("UPDATE provider_accounts SET encrypted_credentials=$2 WHERE id=$1")
        .bind(peer_calendar)
        .bind(expired)
        .execute(&mut *tx)
        .await
        .unwrap();
    tx.commit().await.unwrap();
    assert_eq!(
        request(
            &app,
            "PUT",
            &format!("/v1/calendar/sharing/{peer_calendar}"),
            Some(&peer_session.token),
            json!({"enabled":false})
        )
        .await
        .0,
        StatusCode::OK
    );
    assert_eq!(
        request(
            &app,
            "POST",
            "/v1/calendar/free-busy",
            Some(&owner_session.token),
            range
        )
        .await
        .0,
        StatusCode::NOT_FOUND
    );
    let rsvp = json!({"account_id":host,"ical_uid":"fixture@example.test","organizer":"host@example.test","start":start,"end":start+Duration::hours(1),"response":"accepted"});
    assert_eq!(
        request(
            &app,
            "POST",
            "/v1/calendar/invitations/respond",
            Some(&peer_session.token),
            rsvp
        )
        .await
        .0,
        StatusCode::NOT_FOUND
    );

    let revoked_during_check = request(
        &app,
        "POST",
        "/v1/calendar/booking-links",
        Some(&owner_session.token),
        link_body(host, start + Duration::hours(8)),
    )
    .await;
    assert_eq!(revoked_during_check.0, StatusCode::OK);
    let revoked_during_check = revoked_during_check.1;
    let mut revoking = FixtureCalendar::new(false, Ok("must-not-send-after-revocation".into()));
    revoking.revoke_during_check = Some((
        workspace,
        user,
        serde_json::from_value(revoked_during_check["id"].clone()).unwrap(),
    ));
    assert_eq!(
        calendar::book_with(
            &state,
            &secret(&revoked_during_check),
            booking(&revoked_during_check, 0),
            &revoking
        )
        .await
        .unwrap_err()
        .status,
        StatusCode::NOT_FOUND
    );
    assert_eq!(
        revoking.creates.load(Ordering::SeqCst),
        0,
        "revocation during availability I/O is rechecked before creating an event"
    );

    let availability_link = request(
        &app,
        "POST",
        "/v1/calendar/booking-links",
        Some(&owner_session.token),
        link_body(host, start + Duration::hours(10)),
    )
    .await;
    assert_eq!(availability_link.0, StatusCode::OK);
    let availability_link = availability_link.1;
    let available = calendar::public_availability_with(
        &state,
        &secret(&availability_link),
        &FixtureCalendar::new(false, Ok("unused".into())),
    )
    .await
    .unwrap();
    assert_eq!(available["slots"].as_array().unwrap().len(), 5);
    let mut revoke_availability = FixtureCalendar::new(false, Ok("must-not-create".into()));
    revoke_availability.revoke_during_check = Some((
        workspace,
        user,
        serde_json::from_value(availability_link["id"].clone()).unwrap(),
    ));
    assert_eq!(
        calendar::public_availability_with(
            &state,
            &secret(&availability_link),
            &revoke_availability
        )
        .await
        .unwrap_err()
        .status,
        StatusCode::NOT_FOUND,
        "public availability cannot return offered times after its token was revoked during provider I/O"
    );
    assert_eq!(revoke_availability.creates.load(Ordering::SeqCst), 0);

    assert_eq!(
        request(
            &app,
            "DELETE",
            &format!("/v1/calendar/booking-links/{link_id}"),
            Some(&owner_session.token),
            Value::Null
        )
        .await
        .0,
        StatusCode::OK
    );
    assert_eq!(
        calendar::book_with(&state, &token, booking(&link, 4), &transport)
            .await
            .unwrap_err()
            .status,
        StatusCode::NOT_FOUND
    );
    sqlx::query("UPDATE memberships SET revoked_at=now() WHERE workspace_id=$1 AND user_id=$2")
        .bind(workspace)
        .bind(user)
        .execute(&pool)
        .await
        .unwrap();
    assert_eq!(
        calendar::book_with(&state, &overlap_token, booking(&overlap, 4), &transport)
            .await
            .unwrap_err()
            .status,
        StatusCode::NOT_FOUND,
        "revoking membership also disables public booking secrets"
    );
    assert_eq!(
        raw(
            &app,
            "GET",
            &format!("/book/{overlap_token}"),
            None,
            Value::Null
        )
        .await
        .0,
        StatusCode::NOT_FOUND
    );
    sqlx::query("DELETE FROM workspaces WHERE id=ANY($1)")
        .bind(vec![workspace, foreign])
        .execute(&pool)
        .await
        .unwrap();
    sqlx::query("DELETE FROM users WHERE id=ANY($1)")
        .bind(vec![user, peer, other])
        .execute(&pool)
        .await
        .unwrap();
}

struct SelectedCalendarFixture {
    busy_id: Option<String>,
    gate_busy: std::sync::atomic::AtomicBool,
    gate_lookup: std::sync::atomic::AtomicBool,
    gate_calendars: std::sync::atomic::AtomicBool,
    started: Notify,
    release: Notify,
    creates: AtomicUsize,
    cancels: AtomicUsize,
    absent: std::sync::atomic::AtomicBool,
    ambiguous_cancel: std::sync::atomic::AtomicBool,
    target: std::sync::Mutex<Option<String>>,
    checked: std::sync::Mutex<Vec<String>>,
}
impl SelectedCalendarFixture {
    fn new(busy_id: Option<&str>) -> Self {
        Self {
            busy_id: busy_id.map(str::to_owned),
            gate_busy: false.into(),
            gate_lookup: false.into(),
            gate_calendars: false.into(),
            started: Notify::new(),
            release: Notify::new(),
            creates: AtomicUsize::new(0),
            cancels: AtomicUsize::new(0),
            absent: true.into(),
            ambiguous_cancel: true.into(),
            target: Default::default(),
            checked: Default::default(),
        }
    }
}
impl CalendarTransport for SelectedCalendarFixture {
    fn busy<'a>(
        &'a self,
        state: &'a AppState,
        session: &'a AccountSession,
        range: &'a Interval,
    ) -> CalendarFuture<'a, Vec<Interval>> {
        self.busy_selected(state, session, "primary", range)
    }
    fn create<'a>(
        &'a self,
        state: &'a AppState,
        session: &'a AccountSession,
        event: &'a BookingEvent,
    ) -> CalendarFuture<'a, String> {
        self.create_selected(state, session, "primary", event)
    }
    fn calendars<'a>(
        &'a self,
        _: &'a AppState,
        _: &'a AccountSession,
    ) -> CalendarFuture<'a, Vec<postmere_calendar::calendar_provider::ProviderCalendar>> {
        Box::pin(async move {
            if self.gate_calendars.swap(false, Ordering::SeqCst) {
                self.started.notify_one();
                self.release.notified().await;
            }
            Ok([
                ("primary", true),
                ("work@example.test", true),
                ("holidays", false),
            ]
            .into_iter()
            .map(
                |(id, can_write)| postmere_calendar::calendar_provider::ProviderCalendar {
                    id: id.into(),
                    name: id.into(),
                    is_primary: id == "primary",
                    can_write,
                },
            )
            .collect())
        })
    }
    fn busy_selected<'a>(
        &'a self,
        _: &'a AppState,
        _: &'a AccountSession,
        id: &'a str,
        range: &'a Interval,
    ) -> CalendarFuture<'a, Vec<Interval>> {
        Box::pin(async move {
            if self.gate_busy.swap(false, Ordering::SeqCst) {
                self.started.notify_one();
                self.release.notified().await;
            }
            self.checked.lock().unwrap().push(id.into());
            Ok(if self.busy_id.as_deref() == Some(id) {
                vec![range.clone()]
            } else {
                vec![]
            })
        })
    }
    fn create_selected<'a>(
        &'a self,
        _: &'a AppState,
        _: &'a AccountSession,
        id: &'a str,
        _: &'a BookingEvent,
    ) -> CalendarFuture<'a, String> {
        Box::pin(async move {
            *self.target.lock().unwrap() = Some(id.into());
            self.creates.fetch_add(1, Ordering::SeqCst);
            Err(CalendarError::Ambiguous)
        })
    }
    fn lookup<'a>(
        &'a self,
        _: &'a AppState,
        _: &'a AccountSession,
        calendar: &'a str,
        _: Uuid,
        _: Option<&'a str>,
    ) -> CalendarFuture<'a, postmere_calendar::calendar_provider::EventLookup> {
        Box::pin(async move {
            assert_eq!(calendar, "work@example.test");
            if self.gate_lookup.swap(false, Ordering::SeqCst) {
                self.started.notify_one();
                self.release.notified().await;
            }
            Ok(if self.absent.load(Ordering::SeqCst) {
                postmere_calendar::calendar_provider::EventLookup::Absent
            } else {
                postmere_calendar::calendar_provider::EventLookup::Present(
                    "stable-provider-event".into(),
                )
            })
        })
    }
    fn cancel<'a>(
        &'a self,
        _: &'a AppState,
        _: &'a AccountSession,
        calendar: &'a str,
        event: &'a str,
    ) -> CalendarFuture<'a, ()> {
        Box::pin(async move {
            assert_eq!(calendar, "work@example.test");
            assert_eq!(event, "stable-provider-event");
            self.cancels.fetch_add(1, Ordering::SeqCst);
            if self.ambiguous_cancel.load(Ordering::SeqCst) {
                Err(CalendarError::Ambiguous)
            } else {
                Ok(())
            }
        })
    }
}

#[tokio::test]
async fn booking_final_authorization_precedes_reservation_lock_and_rechecks_expiry() {
    let url = std::env::var("POSTMERE_TEST_DATABASE_URL").expect("isolated test database");
    let pool = db::connect(&url).await.unwrap();
    db::migrate(&pool).await.unwrap();
    let state = AppState::new(pool.clone(), common::config(url))
        .await
        .unwrap();
    let app = application(state.clone(), calendar::router());
    let workspace = Uuid::new_v4();
    let email = format!("calendar-lock-order-{}@example.test", Uuid::new_v4());
    let hash = hash_password(Zeroizing::new(
        "calendar fixture password long enough".into(),
    ))
    .await
    .unwrap();
    seed(&pool, workspace, &email, &hash).await;
    let session = login(&app, &email, workspace).await;
    let auth = state.auth.authenticate(&session.token).await.unwrap();

    for expire_while_waiting in [false, true] {
        let account_id = account(&state, &auth, true).await;
        let fixture = Arc::new(SelectedCalendarFixture::new(None));
        let link = serde_json::to_value(
            calendar::create_link_with(
                &state,
                &auth,
                serde_json::from_value(link_body(account_id, Utc::now() + Duration::days(2)))
                    .unwrap(),
                fixture.as_ref(),
            )
            .await
            .unwrap(),
        )
        .unwrap();
        let link_id: Uuid = serde_json::from_value(link["id"].clone()).unwrap();
        fixture.gate_busy.store(true, Ordering::SeqCst);
        let task = {
            let state = state.clone();
            let fixture = fixture.clone();
            tokio::spawn(async move {
                calendar::book_with(&state, &secret(&link), booking(&link, 0), fixture.as_ref())
                    .await
            })
        };
        tokio::time::timeout(
            std::time::Duration::from_secs(3),
            fixture.started.notified(),
        )
        .await
        .expect("booking must reach provider availability before the final transaction");

        let mut blocker = auth.begin(&pool).await.unwrap();
        sqlx::query("SELECT pg_advisory_xact_lock(hashtextextended($1,711947))")
            .bind(account_id.to_string())
            .execute(&mut *blocker)
            .await
            .unwrap();
        let blocker_pid: i32 = sqlx::query_scalar("SELECT pg_backend_pid()")
            .fetch_one(&mut *blocker)
            .await
            .unwrap();
        if expire_while_waiting {
            let mut tx = auth.begin(&pool).await.unwrap();
            sqlx::query("UPDATE calendar_booking_links SET expires_at=clock_timestamp()+interval '2 seconds' WHERE id=$1")
                .bind(link_id).execute(&mut *tx).await.unwrap();
            tx.commit().await.unwrap();
        }
        fixture.release.notify_one();
        tokio::time::timeout(std::time::Duration::from_secs(3), async {
            loop {
                let waiting: bool = sqlx::query_scalar("SELECT EXISTS(SELECT 1 FROM pg_stat_activity WHERE $1=ANY(pg_blocking_pids(pid)))")
                    .bind(blocker_pid).fetch_one(&pool).await.unwrap();
                if waiting {
                    break;
                }
                tokio::time::sleep(std::time::Duration::from_millis(10)).await;
            }
        })
        .await
        .expect("booking must wait at the final reservation lock");

        let mut probe = pool.begin().await.unwrap();
        let identity_lock = sqlx::query("SELECT id FROM users WHERE id=$1 FOR UPDATE NOWAIT")
            .bind(auth.user_id)
            .fetch_one(&mut *probe)
            .await;
        probe.rollback().await.unwrap();
        assert_eq!(
            identity_lock
                .unwrap_err()
                .as_database_error()
                .unwrap()
                .code()
                .as_deref(),
            Some("55P03"),
            "booking must hold identity authorization before waiting for reservations"
        );
        if expire_while_waiting {
            tokio::time::sleep(std::time::Duration::from_secs(2)).await;
        }
        blocker.commit().await.unwrap();
        let outcome = tokio::time::timeout(std::time::Duration::from_secs(3), task)
            .await
            .expect("booking must finish after releasing the reservation lock")
            .unwrap();
        if expire_while_waiting {
            assert_eq!(outcome.unwrap_err().status, StatusCode::NOT_FOUND);
            assert_eq!(fixture.creates.load(Ordering::SeqCst), 0);
        } else {
            assert_eq!(outcome.unwrap().status, "uncertain");
            assert_eq!(fixture.creates.load(Ordering::SeqCst), 1);
        }
        let mut tx = auth.begin(&pool).await.unwrap();
        let status: String =
            sqlx::query_scalar("SELECT status FROM calendar_bookings WHERE link_id=$1")
                .bind(link_id)
                .fetch_one(&mut *tx)
                .await
                .unwrap();
        assert_eq!(
            status,
            if expire_while_waiting {
                "failed"
            } else {
                "uncertain"
            }
        );
        tx.commit().await.unwrap();
    }
}

#[tokio::test]
async fn selected_calendars_weekly_rules_and_booking_recovery_never_replay_creation() {
    let url = std::env::var("POSTMERE_TEST_DATABASE_URL").expect("isolated test database");
    let pool = db::connect(&url).await.unwrap();
    db::migrate(&pool).await.unwrap();
    let state = AppState::new(pool.clone(), common::config(url))
        .await
        .unwrap();
    let app = application(state.clone(), calendar::router());
    let workspace = Uuid::new_v4();
    let email = format!("lifecycle-{}@example.test", Uuid::new_v4());
    let hash = hash_password(Zeroizing::new(
        "calendar fixture password long enough".into(),
    ))
    .await
    .unwrap();
    seed(&pool, workspace, &email, &hash).await;
    let session = login(&app, &email, workspace).await;
    let auth = state.auth.authenticate(&session.token).await.unwrap();
    let account_id = account(&state, &auth, true).await;
    let start = Utc::now() + Duration::days(2);
    let mut body = link_body(account_id, start);
    body["calendar_id"] = json!("work@example.test");
    body["conflict_calendar_ids"] = json!(["primary", "work@example.test", "holidays"]);
    let fixture = SelectedCalendarFixture::new(None);
    // Old grants keep primary available and explicitly request reconnection for discovery.
    let (status, old_list) = request(
        &app,
        "GET",
        &format!("/v1/calendar/accounts/{account_id}/calendars"),
        Some(&session.token),
        Value::Null,
    )
    .await;
    assert_eq!(status, StatusCode::OK);
    assert_eq!(old_list["requires_reconnect"], true);
    let denied = calendar::create_link_with(
        &state,
        &auth,
        serde_json::from_value(body.clone()).unwrap(),
        &fixture,
    )
    .await;
    assert!(denied.is_err());
    // Upgrade only the fixture credential; no OAuth or provider traffic occurs.
    let mut credentials = mail::account_session(&state, &auth, account_id)
        .await
        .unwrap()
        .credentials;
    credentials
        .scopes
        .push("https://www.googleapis.com/auth/calendar.calendarlist.readonly".into());
    let sealed = state
        .crypto
        .seal(
            workspace,
            account_id,
            &serde_json::to_vec(&credentials).unwrap(),
        )
        .unwrap();
    let mut tx = auth.begin(&pool).await.unwrap();
    sqlx::query("UPDATE provider_accounts SET encrypted_credentials=$2 WHERE id=$1")
        .bind(account_id)
        .bind(sealed)
        .execute(&mut *tx)
        .await
        .unwrap();
    tx.commit().await.unwrap();
    let mut read_only = body.clone();
    read_only["calendar_id"] = json!("holidays");
    assert!(
        calendar::create_link_with(
            &state,
            &auth,
            serde_json::from_value(read_only).unwrap(),
            &fixture
        )
        .await
        .is_err()
    );
    let mut excluded = body.clone();
    excluded["conflict_calendar_ids"] = json!(["primary"]);
    assert!(
        calendar::create_link_with(
            &state,
            &auth,
            serde_json::from_value(excluded).unwrap(),
            &fixture
        )
        .await
        .is_err()
    );
    let link = serde_json::to_value(
        calendar::create_link_with(
            &state,
            &auth,
            serde_json::from_value(body.clone()).unwrap(),
            &fixture,
        )
        .await
        .unwrap(),
    )
    .unwrap();
    assert_eq!(link["calendar_id"], "work@example.test");
    assert_eq!(link["conflict_calendar_ids"].as_array().unwrap().len(), 3);
    let token = secret(&link);
    let blocked = SelectedCalendarFixture::new(Some("holidays"));
    assert!(
        calendar::public_availability_with(&state, &token, &blocked)
            .await
            .unwrap()["slots"]
            .as_array()
            .unwrap()
            .is_empty()
    );
    assert!(
        calendar::book_with(&state, &token, booking(&link, 0), &blocked)
            .await
            .is_err()
    );
    assert_eq!(blocked.creates.load(Ordering::SeqCst), 0);
    let request = booking(&link, 0);
    let booked = calendar::book_with(&state, &token, request.clone(), &fixture)
        .await
        .unwrap();
    assert_eq!(booked.status, "uncertain");
    assert_eq!(fixture.creates.load(Ordering::SeqCst), 1);
    assert_eq!(
        fixture.target.lock().unwrap().as_deref(),
        Some("work@example.test")
    );
    assert_eq!(
        *fixture.checked.lock().unwrap(),
        vec!["primary", "work@example.test", "holidays"]
    );
    assert_eq!(
        calendar::reconcile_with(&state, &auth, booked.id, &fixture)
            .await
            .unwrap()
            .status,
        "uncertain"
    );
    assert!(
        calendar::cancel_with(&state, &auth, booked.id, &fixture)
            .await
            .is_err()
    );
    fixture.absent.store(false, Ordering::SeqCst);
    assert_eq!(
        calendar::reconcile_with(&state, &auth, booked.id, &fixture)
            .await
            .unwrap()
            .status,
        "confirmed"
    );
    assert_eq!(
        calendar::book_with(&state, &token, request.clone(), &fixture)
            .await
            .unwrap()
            .status,
        "confirmed"
    );
    assert_eq!(
        calendar::cancel_with(&state, &auth, booked.id, &fixture)
            .await
            .unwrap()
            .status,
        "cancel_uncertain"
    );
    assert_eq!(
        calendar::reconcile_with(&state, &auth, booked.id, &fixture)
            .await
            .unwrap()
            .status,
        "cancel_uncertain"
    );
    let availability = calendar::public_availability_with(&state, &token, &fixture)
        .await
        .unwrap();
    assert_eq!(availability["slots"].as_array().unwrap().len(), 4);
    fixture.ambiguous_cancel.store(false, Ordering::SeqCst);
    assert_eq!(
        calendar::cancel_with(&state, &auth, booked.id, &fixture)
            .await
            .unwrap()
            .status,
        "cancelled"
    );
    assert_eq!(
        calendar::cancel_with(&state, &auth, booked.id, &fixture)
            .await
            .unwrap()
            .status,
        "cancelled"
    );
    assert_eq!(fixture.cancels.load(Ordering::SeqCst), 2);
    assert_eq!(fixture.creates.load(Ordering::SeqCst), 1);
    assert_eq!(
        calendar::public_availability_with(&state, &token, &fixture)
            .await
            .unwrap()["slots"]
            .as_array()
            .unwrap()
            .len(),
        5
    );
    assert_eq!(
        calendar::book_with(&state, &token, request, &fixture)
            .await
            .unwrap()
            .status,
        "cancelled"
    );
    // Persist a bounded weekly definition and materialized slots through the same create path.
    body["slots"] = json!([]);
    body["availability"] = json!({"start_date":start.date_naive(),"end_date":(start + Duration::days(1)).date_naive(),"weekdays":[1,2,3,4,5,6,7],"start_minute":540,"end_minute":600});
    let recurring = serde_json::to_value(
        calendar::create_link_with(
            &state,
            &auth,
            serde_json::from_value(body).unwrap(),
            &fixture,
        )
        .await
        .unwrap(),
    )
    .unwrap();
    assert!(recurring["availability"].is_object());
    assert_eq!(recurring["slots"].as_array().unwrap().len(), 4);
    let (_, listed) = crate::request(
        &app,
        "GET",
        "/v1/calendar/booking-links",
        Some(&session.token),
        Value::Null,
    )
    .await;
    assert!(
        listed["items"]
            .as_array()
            .unwrap()
            .iter()
            .any(|item| item["id"] == recurring["id"] && item["availability"].is_object())
    );
    assert_eq!(fixture.creates.load(Ordering::SeqCst), 1);
}

#[tokio::test]
async fn revoked_access_during_calendar_io_prevents_later_mutations() {
    let url = std::env::var("POSTMERE_TEST_DATABASE_URL").expect("isolated test database");
    let pool = db::connect(&url).await.unwrap();
    db::migrate(&pool).await.unwrap();
    let state = AppState::new(pool.clone(), common::config(url))
        .await
        .unwrap();
    let app = application(state.clone(), calendar::router());
    let workspace = Uuid::new_v4();
    let email = format!("calendar-revocation-{}@example.test", Uuid::new_v4());
    let hash = hash_password(Zeroizing::new(
        "calendar fixture password long enough".into(),
    ))
    .await
    .unwrap();
    seed(&pool, workspace, &email, &hash).await;
    for (cancel, change) in [
        (true, "logout"),
        (true, "disconnect"),
        (true, "reconnect"),
        (false, "logout"),
        (false, "disconnect"),
        (false, "reconnect"),
        (true, "membership"),
        (false, "membership"),
    ] {
        let session = login(&app, &email, workspace).await;
        let auth = state.auth.authenticate(&session.token).await.unwrap();
        let account_id = account(&state, &auth, true).await;
        let mut credentials = mail::account_session(&state, &auth, account_id)
            .await
            .unwrap()
            .credentials;
        credentials
            .scopes
            .push("https://www.googleapis.com/auth/calendar.calendarlist.readonly".into());
        let encrypted = state
            .crypto
            .seal(
                workspace,
                account_id,
                &serde_json::to_vec(&credentials).unwrap(),
            )
            .unwrap();
        let mut tx = auth.begin(&pool).await.unwrap();
        sqlx::query("UPDATE provider_accounts SET encrypted_credentials=$2 WHERE id=$1")
            .bind(account_id)
            .bind(encrypted)
            .execute(&mut *tx)
            .await
            .unwrap();
        tx.commit().await.unwrap();
        let fixture = Arc::new(SelectedCalendarFixture::new(None));
        let mut body = link_body(account_id, Utc::now() + Duration::days(2));
        body["calendar_id"] = json!("work@example.test");
        body["conflict_calendar_ids"] = json!(["primary", "work@example.test"]);
        let booking_id = if cancel {
            let link = serde_json::to_value(
                calendar::create_link_with(
                    &state,
                    &auth,
                    serde_json::from_value(body.clone()).unwrap(),
                    fixture.as_ref(),
                )
                .await
                .unwrap(),
            )
            .unwrap();
            let booked =
                calendar::book_with(&state, &secret(&link), booking(&link, 0), fixture.as_ref())
                    .await
                    .unwrap();
            fixture.absent.store(false, Ordering::SeqCst);
            fixture.gate_lookup.store(true, Ordering::SeqCst);
            Some(booked.id)
        } else {
            fixture.gate_calendars.store(true, Ordering::SeqCst);
            None
        };
        let task_state = state.clone();
        let task_auth = auth.clone();
        let task_fixture = fixture.clone();
        let task = tokio::spawn(async move {
            if let Some(id) = booking_id {
                calendar::cancel_with(&task_state, &task_auth, id, task_fixture.as_ref())
                    .await
                    .map(|_| ())
            } else {
                calendar::create_link_with(
                    &task_state,
                    &task_auth,
                    serde_json::from_value(body).unwrap(),
                    task_fixture.as_ref(),
                )
                .await
                .map(|_| ())
            }
        });
        tokio::time::timeout(
            std::time::Duration::from_secs(3),
            fixture.started.notified(),
        )
        .await
        .unwrap();
        match change {
            "logout" => {
                sqlx::query("UPDATE sessions SET revoked_at=now() WHERE id=$1")
                    .bind(session.session_id)
                    .execute(&pool)
                    .await
                    .unwrap();
            }
            "membership" => {
                sqlx::query(
                    "UPDATE memberships SET revoked_at=now() WHERE workspace_id=$1 AND user_id=$2",
                )
                .bind(workspace)
                .bind(auth.user_id)
                .execute(&pool)
                .await
                .unwrap();
            }
            _ => {
                let mut tx = auth.begin(&pool).await.unwrap();
                let query = if change == "reconnect" {
                    "UPDATE provider_accounts SET status='reconnect_required' WHERE id=$1"
                } else {
                    "UPDATE provider_accounts SET disabled_at=now() WHERE id=$1"
                };
                sqlx::query(query)
                    .bind(account_id)
                    .execute(&mut *tx)
                    .await
                    .unwrap();
                tx.commit().await.unwrap();
            }
        }
        fixture.release.notify_one();
        assert!(
            task.await.unwrap().is_err(),
            "revoked access must reject the final mutation"
        );
        assert_eq!(fixture.cancels.load(Ordering::SeqCst), 0);
        let mut tx = auth.begin(&pool).await.unwrap();
        if let Some(id) = booking_id {
            let status: String =
                sqlx::query_scalar("SELECT status FROM calendar_bookings WHERE id=$1")
                    .bind(id)
                    .fetch_one(&mut *tx)
                    .await
                    .unwrap();
            assert_eq!(status, "uncertain");
            assert_eq!(fixture.creates.load(Ordering::SeqCst), 1);
        } else {
            let count: i64 = sqlx::query_scalar(
                "SELECT count(*) FROM calendar_booking_links WHERE account_id=$1",
            )
            .bind(account_id)
            .fetch_one(&mut *tx)
            .await
            .unwrap();
            assert_eq!(count, 0);
            assert_eq!(fixture.creates.load(Ordering::SeqCst), 0);
        }
        tx.commit().await.unwrap();
        if change == "membership" {
            sqlx::query(
                "UPDATE memberships SET revoked_at=NULL WHERE workspace_id=$1 AND user_id=$2",
            )
            .bind(workspace)
            .bind(auth.user_id)
            .execute(&pool)
            .await
            .unwrap();
        }
    }
}
