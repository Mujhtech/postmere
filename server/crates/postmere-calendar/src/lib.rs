//! Explicit calendar sharing and nonce-authorized bookings. Guest details and
//! reusable link secrets are encrypted. Reservations are durable before network
//! writes, and uncertain writes are never retried or released automatically.
pub mod calendar_provider;

use axum::{
    Extension, Json, Router,
    extract::{ConnectInfo, DefaultBodyLimit, Path, State},
    http::{HeaderMap, header},
    response::{Html, IntoResponse, Response},
    routing::{get, post},
};
use calendar_provider::{
    BookingEvent, CalendarError, CalendarTransport, Interval, InvitationRequest, LiveCalendar,
};
use chrono::{DateTime, Duration, Utc};
use chrono_tz::Tz;
use postmere_core::{AppState, auth::AuthContext, db, error::AppError, tokens};
use postmere_mail::mail;
use postmere_providers as provider;
use serde::{Deserialize, Serialize};
use serde_json::{Value, json};
use sqlx::{Postgres, Row, Transaction, postgres::PgRow};
use std::{
    collections::{HashMap, HashSet},
    net::SocketAddr,
    sync::Arc,
};
use uuid::Uuid;
use zeroize::Zeroizing;

pub fn router() -> Router<AppState> {
    Router::new()
        .route(
            "/v1/calendar/booking-links",
            get(list_links).post(create_link),
        )
        .route(
            "/v1/calendar/booking-links/{id}",
            axum::routing::delete(revoke_link),
        )
        .route("/v1/calendar/bookings", get(list_bookings))
        .route("/v1/calendar/sharing", get(list_sharing))
        .route("/v1/calendar/sharing/{id}", axum::routing::put(set_sharing))
        .route("/v1/calendar/free-busy", post(free_busy))
        .route("/v1/calendar/invitations/respond", post(respond))
        .route(
            "/v1/calendar/public/{token}",
            get(public_availability).post(public_book),
        )
        .route("/book/{token}", get(booking_page))
        .route("/calendar-booking.css", get(booking_css))
        .route("/calendar-booking.js", get(booking_js))
        .layer(DefaultBodyLimit::max(64 * 1024))
}

#[derive(Clone, Serialize)]
pub struct Slot {
    pub id: Uuid,
    pub start: DateTime<Utc>,
    pub end: DateTime<Utc>,
}
impl Slot {
    fn interval(&self) -> Interval {
        Interval {
            start: self.start,
            end: self.end,
        }
    }
}
#[derive(Serialize)]
struct Link {
    id: Uuid,
    account_id: Uuid,
    title: String,
    description: String,
    time_zone: String,
    duration_minutes: i32,
    url: String,
    expires_at: DateTime<Utc>,
    disabled_at: Option<DateTime<Utc>>,
    created_at: DateTime<Utc>,
    slots: Vec<Slot>,
}
#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct NewLink {
    account_id: Uuid,
    title: String,
    #[serde(default)]
    description: String,
    time_zone: String,
    duration_minutes: i32,
    expires_at: DateTime<Utc>,
    slots: Vec<Interval>,
}
#[derive(Clone)]
struct PublicLink {
    id: Uuid,
    workspace: Uuid,
    user: Uuid,
    account: Uuid,
    title: String,
    description: String,
    time_zone: String,
    duration_minutes: i32,
}

fn slot_row(row: &PgRow) -> Result<Slot, AppError> {
    Ok(Slot {
        id: row.try_get("id")?,
        start: row.try_get("starts_at")?,
        end: row.try_get("ends_at")?,
    })
}
async fn link_output(
    state: &AppState,
    tx: &mut Transaction<'_, Postgres>,
    row: &PgRow,
    workspace: Uuid,
) -> Result<Link, AppError> {
    let id: Uuid = row.try_get("id")?;
    let secret = state.crypto.open(
        workspace,
        id,
        &row.try_get::<Vec<u8>, _>("encrypted_token")?,
    )?;
    let secret =
        std::str::from_utf8(&secret).map_err(|_| AppError::internal("booking_link_decode"))?;
    let url = state
        .config
        .public_base_url
        .join(&format!("/book/{secret}"))
        .map_err(|_| AppError::internal("booking_link_url"))?
        .to_string();
    let slots=sqlx::query("SELECT id,starts_at,ends_at FROM calendar_booking_slots WHERE link_id=$1 ORDER BY starts_at,id").bind(id).fetch_all(&mut **tx).await?.iter().map(slot_row).collect::<Result<_,_>>()?;
    Ok(Link {
        id,
        account_id: row.try_get("account_id")?,
        title: row.try_get("title")?,
        description: row.try_get("description")?,
        time_zone: row.try_get("time_zone")?,
        duration_minutes: row.try_get("duration_minutes")?,
        url,
        expires_at: row.try_get("expires_at")?,
        disabled_at: row.try_get("disabled_at")?,
        created_at: row.try_get("created_at")?,
        slots,
    })
}
fn valid_text(text: &str, max: usize, multiline: bool) -> bool {
    !text.trim().is_empty()
        && text.chars().count() <= max
        && !text
            .chars()
            .any(|c| c.is_control() && !(multiline && matches!(c, '\n' | '\t')))
}
fn validate_link(input: &NewLink) -> Result<(), AppError> {
    let now = Utc::now();
    if !valid_text(&input.title, 160, false)
        || input.description.chars().count() > 2000
        || input
            .description
            .chars()
            .any(|c| c.is_control() && !matches!(c, '\n' | '\t'))
        || input.time_zone.len() > 100
        || input.time_zone.parse::<Tz>().is_err()
        || !(15..=240).contains(&input.duration_minutes)
        || input.slots.is_empty()
        || input.slots.len() > 100
        || input.expires_at <= now
        || input.expires_at > now + Duration::days(90)
    {
        return Err(AppError::bad_request(
            "Use a title, a valid time zone, 15–240 minute meetings and up to 100 times within the next 90 days.",
        ));
    }
    let mut starts = HashSet::new();
    for slot in &input.slots {
        if slot.start <= now + Duration::minutes(5)
            || slot.end > now + Duration::days(90)
            || slot.end - slot.start != Duration::minutes(i64::from(input.duration_minutes))
            || !starts.insert(slot.start)
        {
            return Err(AppError::bad_request(
                "Each offered time must be distinct, at least five minutes ahead and match the meeting duration.",
            ));
        }
    }
    if !input.slots.iter().any(|s| s.start < input.expires_at) {
        return Err(AppError::bad_request(
            "The link expires before its first offered time.",
        ));
    }
    Ok(())
}
async fn create_link(
    State(state): State<AppState>,
    auth: AuthContext,
    Json(mut input): Json<NewLink>,
) -> Result<Json<Link>, AppError> {
    input.title = input.title.trim().into();
    input.description = input.description.trim().into();
    // Both providers store whole-second meeting times; normalize once before
    // offering or reserving them so the database and provider cannot diverge.
    for slot in &mut input.slots {
        slot.start = DateTime::from_timestamp(slot.start.timestamp(), 0)
            .ok_or_else(|| AppError::bad_request("Invalid meeting start."))?;
        slot.end = DateTime::from_timestamp(slot.end.timestamp(), 0)
            .ok_or_else(|| AppError::bad_request("Invalid meeting end."))?;
    }
    validate_link(&input)?;
    state
        .auth
        .rate_limit("calendar_link_create", &auth.user_id.to_string(), 30)
        .await?;
    let session = mail::account_session(&state, &auth, input.account_id).await?;
    calendar_provider::require_calendar(&session)?;
    let id = Uuid::new_v4();
    let token = tokens::scoped_token(auth.workspace_id, auth.user_id, id)?;
    let sealed = state.crypto.seal(auth.workspace_id, id, token.as_bytes())?;
    let mut tx = auth.begin(&state.pool).await?;
    let active:i64=sqlx::query_scalar("SELECT count(*) FROM calendar_booking_links WHERE disabled_at IS NULL AND expires_at>now()").fetch_one(&mut *tx).await?;
    if active >= 30 {
        return Err(AppError::conflict(
            "Revoke an existing booking link before creating another.",
        ));
    }
    let row=sqlx::query("INSERT INTO calendar_booking_links(id,workspace_id,user_id,account_id,token_hash,encrypted_token,title,description,time_zone,duration_minutes,expires_at) VALUES($1,$2,$3,$4,$5,$6,$7,$8,$9,$10,$11) RETURNING *")
        .bind(id).bind(auth.workspace_id).bind(auth.user_id).bind(input.account_id).bind(tokens::token_hash(&token)).bind(sealed).bind(input.title).bind(input.description).bind(input.time_zone).bind(input.duration_minutes).bind(input.expires_at).fetch_one(&mut *tx).await?;
    for slot in input.slots {
        sqlx::query("INSERT INTO calendar_booking_slots(id,workspace_id,user_id,account_id,link_id,starts_at,ends_at) VALUES($1,$2,$3,$4,$5,$6,$7)").bind(Uuid::new_v4()).bind(auth.workspace_id).bind(auth.user_id).bind(input.account_id).bind(id).bind(slot.start).bind(slot.end).execute(&mut *tx).await?;
    }
    let link = link_output(&state, &mut tx, &row, auth.workspace_id).await?;
    tx.commit().await?;
    Ok(Json(link))
}
async fn list_links(
    State(state): State<AppState>,
    auth: AuthContext,
) -> Result<Json<Value>, AppError> {
    let mut tx = auth.begin(&state.pool).await?;
    let rows =
        sqlx::query("SELECT * FROM calendar_booking_links ORDER BY created_at DESC LIMIT 100")
            .fetch_all(&mut *tx)
            .await?;
    let mut result = vec![];
    for row in rows {
        result.push(link_output(&state, &mut tx, &row, auth.workspace_id).await?)
    }
    tx.commit().await?;
    Ok(Json(json!({"items":result})))
}
async fn revoke_link(
    State(state): State<AppState>,
    auth: AuthContext,
    Path(id): Path<Uuid>,
) -> Result<Json<Value>, AppError> {
    let mut tx = auth.begin(&state.pool).await?;
    if sqlx::query(
        "UPDATE calendar_booking_links SET disabled_at=coalesce(disabled_at,now()) WHERE id=$1",
    )
    .bind(id)
    .execute(&mut *tx)
    .await?
    .rows_affected()
        == 0
    {
        return Err(AppError::not_found());
    }
    tx.commit().await?;
    Ok(Json(json!({})))
}

async fn verified_link(
    tx: &mut Transaction<'_, Postgres>,
    workspace: Uuid,
    user: Uuid,
    id: Uuid,
    token: &str,
) -> Result<PublicLink, AppError> {
    let row=sqlx::query("SELECT l.id,l.account_id,l.title,l.description,l.time_zone,l.duration_minutes FROM calendar_booking_links l JOIN provider_accounts a ON a.id=l.account_id JOIN memberships m ON m.workspace_id=l.workspace_id AND m.user_id=l.user_id JOIN users u ON u.id=l.user_id JOIN workspaces w ON w.id=l.workspace_id WHERE l.id=$1 AND l.token_hash=$2 AND l.disabled_at IS NULL AND l.expires_at>now() AND a.disabled_at IS NULL AND 'calendar'=ANY(a.capabilities) AND m.revoked_at IS NULL AND u.disabled_at IS NULL AND w.disabled_at IS NULL FOR SHARE OF l,a,m,u,w")
        .bind(id).bind(tokens::token_hash(token)).fetch_optional(&mut **tx).await?.ok_or_else(AppError::not_found)?;
    Ok(PublicLink {
        id,
        workspace,
        user,
        account: row.try_get("account_id")?,
        title: row.try_get("title")?,
        description: row.try_get("description")?,
        time_zone: row.try_get("time_zone")?,
        duration_minutes: row.try_get("duration_minutes")?,
    })
}
async fn public_link(state: &AppState, token: &str) -> Result<PublicLink, AppError> {
    let (workspace, user, id) = tokens::parse_scoped_token(token)?;
    let mut tx = db::scoped_transaction(&state.pool, workspace, user).await?;
    let result = verified_link(&mut tx, workspace, user, id, token).await?;
    tx.commit().await?;
    Ok(result)
}
async fn reservation_lock(
    tx: &mut Transaction<'_, Postgres>,
    account: Uuid,
) -> Result<(), AppError> {
    // A database lock covers ALL links for an account, including overlapping
    // alternatives. It works across server instances, unlike a process mutex.
    sqlx::query("SELECT pg_advisory_xact_lock(hashtextextended($1,711947))")
        .bind(account.to_string())
        .execute(&mut **tx)
        .await?;
    sqlx::query("UPDATE calendar_bookings SET status='failed',error_code='check_interrupted',updated_at=now() WHERE account_id=$1 AND status='checking' AND updated_at<now()-interval '5 minutes'").bind(account).execute(&mut **tx).await?;
    sqlx::query("UPDATE calendar_bookings SET status='uncertain',error_code='creation_interrupted',updated_at=now() WHERE account_id=$1 AND status='creating' AND updated_at<now()-interval '5 minutes'").bind(account).execute(&mut **tx).await?;
    Ok(())
}
async fn available_slots(
    state: &AppState,
    link: &PublicLink,
    transport: &dyn CalendarTransport,
) -> Result<Vec<Slot>, AppError> {
    let session =
        mail::service_account_session(state, link.workspace, link.user, link.account).await?;
    calendar_provider::require_calendar(&session)?;
    let mut tx = db::scoped_transaction(&state.pool, link.workspace, link.user).await?;
    reservation_lock(&mut tx, link.account).await?;
    let rows=sqlx::query("SELECT s.id,s.starts_at,s.ends_at FROM calendar_booking_slots s JOIN calendar_booking_links l ON l.id=s.link_id WHERE s.link_id=$1 AND s.starts_at>now()+interval '2 minutes' AND s.starts_at<l.expires_at AND NOT EXISTS(SELECT 1 FROM calendar_bookings b WHERE b.account_id=s.account_id AND b.status<>'failed' AND b.starts_at<s.ends_at AND s.starts_at<b.ends_at) ORDER BY s.starts_at")
        .bind(link.id).fetch_all(&mut *tx).await?;
    let slots = rows.iter().map(slot_row).collect::<Result<Vec<_>, _>>()?;
    tx.commit().await?;
    let Some(first) = slots.first() else {
        return Ok(vec![]);
    };
    let range = Interval {
        start: first.start,
        end: slots.iter().map(|s| s.end).max().unwrap_or(first.end),
    };
    let busy = transport.busy(state, &session, &range).await?;
    Ok(slots
        .into_iter()
        .filter(|slot| !busy.iter().any(|b| slot.interval().overlaps(b)))
        .collect())
}
fn client_identity(client: Option<Extension<ConnectInfo<SocketAddr>>>) -> String {
    client
        .map(|Extension(ConnectInfo(addr))| addr.ip().to_string())
        .unwrap_or_else(|| "unknown-peer".into())
}
async fn public_availability(
    State(state): State<AppState>,
    Path(token): Path<String>,
    client: Option<Extension<ConnectInfo<SocketAddr>>>,
) -> Result<Json<Value>, AppError> {
    state
        .auth
        .rate_limit("booking_read_ip", &client_identity(client), 180)
        .await?;
    public_availability_with(&state, &token, &LiveCalendar)
        .await
        .map(Json)
}

/// Provider I/O is injectable; token authorization is identical for fixtures
/// and public requests, including revocation while availability is loading.
pub async fn public_availability_with(
    state: &AppState,
    token: &str,
    transport: &dyn CalendarTransport,
) -> Result<Value, AppError> {
    let link = public_link(state, token).await?;
    state
        .auth
        .rate_limit("booking_read_link", &link.id.to_string(), 300)
        .await?;
    let slots = available_slots(state, &link, transport).await?;
    // Revocation or expiry during the provider read must prevent disclosure of
    // the host's remaining offered times, just as it prevents a new booking.
    public_link(state, token).await?;
    Ok(
        json!({"title":link.title,"description":link.description,"time_zone":link.time_zone,"duration_minutes":link.duration_minutes,"slots":slots,"calendar_scope":"primary"}),
    )
}

#[derive(Clone, Deserialize, Serialize)]
#[serde(deny_unknown_fields)]
pub struct BookingRequest {
    pub client_id: Uuid,
    pub slot_id: Uuid,
    pub name: String,
    pub email: String,
}
#[derive(Serialize, Deserialize)]
struct Guest {
    name: String,
    email: String,
}
#[derive(Serialize, Deserialize, Debug)]
pub struct BookingResult {
    pub id: Uuid,
    pub status: String,
    pub start: DateTime<Utc>,
    pub end: DateTime<Utc>,
    pub message: String,
}
fn result(row: &PgRow) -> Result<BookingResult, AppError> {
    let mut status: String = row.try_get("status")?;
    let updated: DateTime<Utc> = row.try_get("updated_at")?;
    if status == "creating" && updated < Utc::now() - Duration::minutes(5) {
        status = "uncertain".into()
    }
    let message=match status.as_str(){
        "confirmed"=>"Your meeting is confirmed. The calendar provider has sent an invitation.",
        "uncertain"=>"The calendar provider did not confirm the result. This time remains reserved. Contact the host before booking again.",
        "failed"=>"This meeting was not booked. Refresh the available times before choosing another.",
        _=>"Your booking is being checked. Keep this page open; do not submit another booking.",
    }.into();
    Ok(BookingResult {
        id: row.try_get("id")?,
        status,
        start: row.try_get("starts_at")?,
        end: row.try_get("ends_at")?,
        message,
    })
}
enum Reservation {
    Existing(BookingResult),
    New(PublicLink, Uuid, Interval),
}
async fn reserve(
    state: &AppState,
    token: &str,
    input: &BookingRequest,
) -> Result<Reservation, AppError> {
    let (workspace, user, id) = tokens::parse_scoped_token(token)?;
    let mut tx = db::scoped_transaction(&state.pool, workspace, user).await?;
    let link = verified_link(&mut tx, workspace, user, id, token).await?;
    reservation_lock(&mut tx, link.account).await?;
    let hash = tokens::token_hash(
        &serde_json::to_string(input).map_err(|_| AppError::internal("booking_encode"))?,
    );
    if let Some(row) =
        sqlx::query("SELECT * FROM calendar_bookings WHERE link_id=$1 AND client_id=$2")
            .bind(id)
            .bind(input.client_id)
            .fetch_optional(&mut *tx)
            .await?
    {
        if row.try_get::<Vec<u8>, _>("payload_hash")? != hash {
            return Err(AppError::conflict(
                "This booking request was already used with different details.",
            ));
        }
        let result = result(&row)?;
        tx.commit().await?;
        return Ok(Reservation::Existing(result));
    }
    let slot=sqlx::query("SELECT s.starts_at,s.ends_at FROM calendar_booking_slots s JOIN calendar_booking_links l ON l.id=s.link_id WHERE s.id=$1 AND s.link_id=$2 AND s.starts_at>now()+interval '2 minutes' AND s.starts_at<l.expires_at AND l.disabled_at IS NULL AND l.expires_at>now()")
        .bind(input.slot_id).bind(id).fetch_optional(&mut *tx).await?.ok_or_else(AppError::not_found)?;
    let interval = Interval {
        start: slot.try_get("starts_at")?,
        end: slot.try_get("ends_at")?,
    };
    let occupied:bool=sqlx::query_scalar("SELECT EXISTS(SELECT 1 FROM calendar_bookings WHERE account_id=$1 AND status<>'failed' AND starts_at<$3 AND $2<ends_at)").bind(link.account).bind(interval.start).bind(interval.end).fetch_one(&mut *tx).await?;
    if occupied {
        return Err(AppError::conflict(
            "That time is no longer available. Choose another time.",
        ));
    }
    let booking = Uuid::new_v4();
    let guest = Zeroizing::new(
        serde_json::to_vec(&Guest {
            name: input.name.clone(),
            email: input.email.clone(),
        })
        .map_err(|_| AppError::internal("booking_guest_encode"))?,
    );
    let encrypted = state.crypto.seal(workspace, booking, &guest)?;
    sqlx::query("INSERT INTO calendar_bookings(id,workspace_id,user_id,account_id,link_id,slot_id,client_id,payload_hash,encrypted_guest,starts_at,ends_at,status) VALUES($1,$2,$3,$4,$5,$6,$7,$8,$9,$10,$11,'checking')")
        .bind(booking).bind(workspace).bind(user).bind(link.account).bind(id).bind(input.slot_id).bind(input.client_id).bind(hash).bind(encrypted).bind(interval.start).bind(interval.end).execute(&mut *tx).await?;
    tx.commit().await?;
    Ok(Reservation::New(link, booking, interval))
}
async fn finish(
    state: &AppState,
    link: &PublicLink,
    id: Uuid,
    status: &str,
    event_id: Option<String>,
    code: Option<&str>,
) -> Result<BookingResult, AppError> {
    let mut tx = db::scoped_transaction(&state.pool, link.workspace, link.user).await?;
    let row=sqlx::query("UPDATE calendar_bookings SET status=$2,provider_event_id=$3,error_code=$4,updated_at=now() WHERE id=$1 AND status IN ('checking','creating') RETURNING *").bind(id).bind(status).bind(event_id).bind(code).fetch_optional(&mut *tx).await?.ok_or_else(||AppError::conflict("This reservation is no longer active."))?;
    let result = result(&row)?;
    tx.commit().await?;
    Ok(result)
}

/// All production and fixture bookings use the same authorization, reservation,
/// conflict check and durable state transitions. Only provider I/O is injected.
pub async fn book_with(
    state: &AppState,
    token: &str,
    mut input: BookingRequest,
    transport: &dyn CalendarTransport,
) -> Result<BookingResult, AppError> {
    input.name = input.name.trim().into();
    input.email = input.email.trim().to_lowercase();
    if input.client_id.is_nil()
        || !valid_text(&input.name, 120, false)
        || !provider::valid_email(&input.email)
    {
        return Err(AppError::bad_request(
            "Enter your name and a valid email address.",
        ));
    }
    let (link, id, interval) = match reserve(state, token, &input).await? {
        Reservation::Existing(result) => return Ok(result),
        Reservation::New(link, id, range) => (link, id, range),
    };
    let session =
        match mail::service_account_session(state, link.workspace, link.user, link.account).await {
            Ok(session) => session,
            Err(error) => {
                finish(
                    state,
                    &link,
                    id,
                    "failed",
                    None,
                    Some("account_unavailable"),
                )
                .await?;
                return Err(error);
            }
        };
    if let Err(error) = calendar_provider::require_calendar(&session) {
        finish(
            state,
            &link,
            id,
            "failed",
            None,
            Some("calendar_not_connected"),
        )
        .await?;
        return Err(error);
    }
    let busy = match transport.busy(state, &session, &interval).await {
        Ok(busy) => busy,
        Err(error) => {
            finish(
                state,
                &link,
                id,
                "failed",
                None,
                Some("availability_unavailable"),
            )
            .await?;
            return Err(error.into());
        }
    };
    if busy.iter().any(|b| b.overlaps(&interval)) {
        finish(state, &link, id, "failed", None, Some("calendar_busy")).await?;
        return Err(AppError::conflict(
            "That time is now busy on the host's calendar. Choose another time.",
        ));
    }
    // Recheck link, account and membership after availability I/O. Committing
    // creating before the external write is what makes cancellation safe.
    let mut tx = db::scoped_transaction(&state.pool, link.workspace, link.user).await?;
    reservation_lock(&mut tx, link.account).await?;
    if let Err(error) = verified_link(&mut tx, link.workspace, link.user, link.id, token).await {
        tx.rollback().await?;
        finish(state, &link, id, "failed", None, Some("link_revoked")).await?;
        return Err(error);
    }
    let changed=sqlx::query("UPDATE calendar_bookings SET status='creating',updated_at=now() WHERE id=$1 AND status='checking'").bind(id).execute(&mut *tx).await?;
    if changed.rows_affected() != 1 {
        return Err(AppError::conflict(
            "This reservation expired before calendar creation.",
        ));
    }
    tx.commit().await?;
    let event = BookingEvent {
        id,
        title: link.title.clone(),
        description: link.description.clone(),
        guest_name: input.name,
        guest_email: input.email,
        interval,
    };
    match transport.create(state, &session, &event).await {
        Ok(event_id) => finish(state, &link, id, "confirmed", Some(event_id), None).await,
        Err(CalendarError::Rejected | CalendarError::NotFound) => {
            finish(state, &link, id, "failed", None, Some("provider_rejected")).await
        }
        Err(_) => {
            finish(
                state,
                &link,
                id,
                "uncertain",
                None,
                Some("provider_result_unknown"),
            )
            .await
        }
    }
}

fn same_origin(state: &AppState, headers: &HeaderMap) -> Result<(), AppError> {
    if let Some(origin) = headers.get(header::ORIGIN) {
        let raw = origin.to_str().map_err(|_| AppError::forbidden())?;
        let parsed = url::Url::parse(raw).map_err(|_| AppError::forbidden())?;
        if parsed.origin() != state.config.public_base_url.origin() {
            return Err(AppError::forbidden());
        }
    }
    Ok(())
}
async fn public_book(
    State(state): State<AppState>,
    Path(token): Path<String>,
    headers: HeaderMap,
    client: Option<Extension<ConnectInfo<SocketAddr>>>,
    Json(input): Json<BookingRequest>,
) -> Result<Json<BookingResult>, AppError> {
    same_origin(&state, &headers)?;
    state
        .auth
        .rate_limit("booking_write_ip", &client_identity(client), 20)
        .await?;
    let link = public_link(&state, &token).await?;
    state
        .auth
        .rate_limit("booking_write_link", &link.id.to_string(), 40)
        .await?;
    book_with(&state, &token, input, &LiveCalendar)
        .await
        .map(Json)
}
async fn list_bookings(
    State(state): State<AppState>,
    auth: AuthContext,
) -> Result<Json<Value>, AppError> {
    let mut tx = auth.begin(&state.pool).await?;
    let rows = sqlx::query("SELECT * FROM calendar_bookings ORDER BY created_at DESC LIMIT 200")
        .fetch_all(&mut *tx)
        .await?;
    let mut items = vec![];
    for row in rows {
        let id: Uuid = row.try_get("id")?;
        let plain = state.crypto.open(
            auth.workspace_id,
            id,
            &row.try_get::<Vec<u8>, _>("encrypted_guest")?,
        )?;
        let guest: Guest = serde_json::from_slice(&plain)
            .map_err(|_| AppError::internal("booking_guest_decode"))?;
        let result = result(&row)?;
        items.push(json!({"id":id,"link_id":row.try_get::<Uuid,_>("link_id")?,"start":result.start,"end":result.end,"guest_name":guest.name,"guest_email":guest.email,"status":result.status,"created_at":row.try_get::<DateTime<Utc>,_>("created_at")?}));
    }
    tx.commit().await?;
    Ok(Json(json!({"items":items})))
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct SharingRequest {
    enabled: bool,
}
async fn set_sharing(
    State(state): State<AppState>,
    auth: AuthContext,
    Path(id): Path<Uuid>,
    Json(input): Json<SharingRequest>,
) -> Result<Json<Value>, AppError> {
    if !input.enabled {
        // Revocation must work even if OAuth expired or the provider is down.
        let mut tx = auth.begin(&state.pool).await?;
        let owned: bool =
            sqlx::query_scalar("SELECT EXISTS(SELECT 1 FROM provider_accounts WHERE id=$1)")
                .bind(id)
                .fetch_one(&mut *tx)
                .await?;
        if !owned {
            return Err(AppError::not_found());
        }
        sqlx::query(
            "UPDATE calendar_sharing SET enabled=false,updated_at=now() WHERE account_id=$1",
        )
        .bind(id)
        .execute(&mut *tx)
        .await?;
        tx.commit().await?;
        return Ok(Json(json!({})));
    }
    let session = mail::account_session(&state, &auth, id).await?;
    calendar_provider::require_calendar(&session)?;
    let mut tx = auth.begin(&state.pool).await?;
    sqlx::query("INSERT INTO calendar_sharing(account_id,workspace_id,user_id,email,enabled) VALUES($1,$2,$3,$4,$5) ON CONFLICT(account_id) DO UPDATE SET enabled=excluded.enabled,email=excluded.email,updated_at=now()")
        .bind(id).bind(auth.workspace_id).bind(auth.user_id).bind(session.account.email).bind(input.enabled).execute(&mut *tx).await?;
    tx.commit().await?;
    Ok(Json(json!({})))
}
async fn list_sharing(
    State(state): State<AppState>,
    auth: AuthContext,
) -> Result<Json<Value>, AppError> {
    let mut tx = auth.begin(&state.pool).await?;
    let rows=sqlx::query("SELECT a.id AS account_id,a.email,a.user_id,coalesce(s.enabled,false) AS enabled FROM provider_accounts a LEFT JOIN calendar_sharing s ON s.account_id=a.id WHERE a.disabled_at IS NULL AND 'calendar'=ANY(a.capabilities) UNION ALL SELECT s.account_id,s.email,s.user_id,s.enabled FROM calendar_sharing s JOIN memberships m ON m.workspace_id=s.workspace_id AND m.user_id=s.user_id JOIN users u ON u.id=s.user_id WHERE s.user_id<>$1 AND s.enabled AND m.revoked_at IS NULL AND u.disabled_at IS NULL ORDER BY email")
        .bind(auth.user_id).fetch_all(&mut *tx).await?;
    let items=rows.into_iter().map(|r|Ok::<_,AppError>(json!({"account_id":r.try_get::<Uuid,_>("account_id")?,"email":r.try_get::<String,_>("email")?,"user_id":r.try_get::<Uuid,_>("user_id")?,"enabled":r.try_get::<bool,_>("enabled")?,"is_mine":r.try_get::<Uuid,_>("user_id")?==auth.user_id}))).collect::<Result<Vec<_>,_>>()?;
    tx.commit().await?;
    Ok(Json(json!({"items":items})))
}
#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
pub struct FreeBusyRequest {
    pub account_ids: Vec<Uuid>,
    pub start: DateTime<Utc>,
    pub end: DateTime<Utc>,
}
async fn shared_owners(
    state: &AppState,
    auth: &AuthContext,
    accounts: &[Uuid],
) -> Result<HashMap<Uuid, Uuid>, AppError> {
    let mut tx = auth.begin(&state.pool).await?;
    // One statement gives all returned calendars the same authorization
    // snapshot. Provider accounts are owner-only under RLS; peer calendars
    // require a live, explicit share from an active workspace member.
    let rows=sqlx::query("SELECT id AS account_id,user_id FROM provider_accounts WHERE id=ANY($1) AND disabled_at IS NULL UNION ALL SELECT s.account_id,s.user_id FROM calendar_sharing s JOIN memberships m ON m.workspace_id=s.workspace_id AND m.user_id=s.user_id JOIN users u ON u.id=s.user_id WHERE s.account_id=ANY($1) AND s.user_id<>$2 AND s.enabled AND m.revoked_at IS NULL AND u.disabled_at IS NULL")
        .bind(accounts).bind(auth.user_id).fetch_all(&mut *tx).await?;
    let owners = rows
        .into_iter()
        .map(|row| Ok((row.try_get("account_id")?, row.try_get("user_id")?)))
        .collect::<Result<HashMap<Uuid, Uuid>, sqlx::Error>>()?;
    tx.commit().await?;
    Ok(owners)
}
async fn free_busy(
    State(state): State<AppState>,
    auth: AuthContext,
    Json(input): Json<FreeBusyRequest>,
) -> Result<Json<Value>, AppError> {
    free_busy_with(&state, &auth, input, Arc::new(LiveCalendar))
        .await
        .map(Json)
}

/// All provider reads finish before one final authorization check. A fast
/// calendar cannot outlive a revoked share while another calendar is loading.
pub async fn free_busy_with(
    state: &AppState,
    auth: &AuthContext,
    input: FreeBusyRequest,
    transport: Arc<dyn CalendarTransport>,
) -> Result<Value, AppError> {
    if input.account_ids.is_empty()
        || input.account_ids.len() > 8
        || input.end <= input.start
        || input.end - input.start > Duration::days(31)
        || input.start < Utc::now() - Duration::days(1)
        || input.end > Utc::now() + Duration::days(366)
    {
        return Err(AppError::bad_request(
            "Choose up to eight calendars and a time range of up to 31 days.",
        ));
    }
    state
        .auth
        .rate_limit("calendar_free_busy", &auth.user_id.to_string(), 60)
        .await?;
    let mut accounts = HashSet::new();
    let mut tasks = tokio::task::JoinSet::new();
    let owners = shared_owners(state, auth, &input.account_ids).await?;
    for id in input.account_ids {
        if !accounts.insert(id) {
            continue;
        }
        let owner = *owners.get(&id).ok_or_else(AppError::not_found)?;
        let session = mail::service_account_session(state, auth.workspace_id, owner, id).await?;
        calendar_provider::require_calendar(&session)?;
        let state = state.clone();
        let transport = transport.clone();
        let range = Interval {
            start: input.start,
            end: input.end,
        };
        tasks.spawn(async move {
            let busy = transport.busy(&state, &session, &range).await?;
            Ok::<_, CalendarError>((id, owner, busy))
        });
    }
    let mut results = vec![];
    while let Some(result) = tasks.join_next().await {
        results.push(result.map_err(|_| AppError::unavailable())??);
    }
    let ids = results.iter().map(|(id, _, _)| *id).collect::<Vec<_>>();
    let authorized = shared_owners(state, auth, &ids).await?;
    let mut calendars = vec![];
    for (id, owner, busy) in results {
        if authorized.get(&id) != Some(&owner) {
            return Err(AppError::not_found());
        }
        calendars.push(json!({"account_id":id,"busy":busy}));
    }
    Ok(json!({"calendars":calendars,"start":input.start,"end":input.end}))
}
async fn respond(
    State(state): State<AppState>,
    auth: AuthContext,
    Json(input): Json<InvitationRequest>,
) -> Result<Json<Value>, AppError> {
    state
        .auth
        .rate_limit("calendar_rsvp", &auth.user_id.to_string(), 30)
        .await?;
    let session = mail::account_session(&state, &auth, input.account_id).await?;
    calendar_provider::respond(&state, &session, &input).await?;
    Ok(Json(
        json!({"status":"responded","response":input.response}),
    ))
}

async fn booking_page(
    State(state): State<AppState>,
    Path(token): Path<String>,
) -> Result<Response, AppError> {
    public_link(&state, &token).await?;
    let mut response = Html(include_str!("../static/booking.html")).into_response();
    response.headers_mut().insert(header::CONTENT_SECURITY_POLICY,"default-src 'none'; style-src 'self'; script-src 'self'; connect-src 'self'; form-action 'self'; base-uri 'none'; frame-ancestors 'none'".parse().unwrap());
    Ok(response)
}
async fn booking_css() -> impl IntoResponse {
    (
        [(header::CONTENT_TYPE, "text/css; charset=utf-8")],
        include_str!("../static/booking.css"),
    )
}
async fn booking_js() -> impl IntoResponse {
    (
        [(header::CONTENT_TYPE, "text/javascript; charset=utf-8")],
        include_str!("../static/booking.js"),
    )
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn link_validation_rejects_inconsistent_duration_and_bad_zone() {
        let start = Utc::now() + Duration::days(1);
        let mut input = NewLink {
            account_id: Uuid::new_v4(),
            title: "Meeting".into(),
            description: String::new(),
            time_zone: "Africa/Lagos".into(),
            duration_minutes: 30,
            expires_at: start + Duration::days(1),
            slots: vec![Interval {
                start,
                end: start + Duration::minutes(30),
            }],
        };
        assert!(validate_link(&input).is_ok());
        input.slots[0].end += Duration::minutes(1);
        assert!(validate_link(&input).is_err());
        input.slots[0].end -= Duration::minutes(1);
        input.time_zone = "../../etc/passwd".into();
        assert!(validate_link(&input).is_err());
    }
}
