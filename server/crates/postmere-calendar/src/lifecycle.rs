//! Recover lost provider responses without replaying event creation. Cancellation
//! is durable before I/O and retries address the same provider event only.
use super::*;
use calendar_provider::EventLookup;

pub(super) async fn cancel_booking(
    State(state): State<AppState>,
    auth: AuthContext,
    Path(id): Path<Uuid>,
) -> Result<Json<BookingResult>, AppError> {
    cancel_with(&state, &auth, id, &LiveCalendar)
        .await
        .map(Json)
}
pub(super) async fn reconcile_booking(
    State(state): State<AppState>,
    auth: AuthContext,
    Path(id): Path<Uuid>,
) -> Result<Json<BookingResult>, AppError> {
    reconcile_with(&state, &auth, id, &LiveCalendar)
        .await
        .map(Json)
}
async fn booking_row(state: &AppState, auth: &AuthContext, id: Uuid) -> Result<PgRow, AppError> {
    let mut tx = auth.begin_authorized(&state.pool).await?;
    let account: Uuid = sqlx::query_scalar("SELECT account_id FROM calendar_bookings WHERE id=$1")
        .bind(id)
        .fetch_optional(&mut *tx)
        .await?
        .ok_or_else(AppError::not_found)?;
    reservation_lock(&mut tx, account).await?;
    let row = sqlx::query("SELECT b.*,l.calendar_id FROM calendar_bookings b JOIN calendar_booking_links l ON l.id=b.link_id WHERE b.id=$1").bind(id).fetch_one(&mut *tx).await?;
    tx.commit().await?;
    Ok(row)
}
pub async fn reconcile_with(
    state: &AppState,
    auth: &AuthContext,
    id: Uuid,
    transport: &dyn CalendarTransport,
) -> Result<BookingResult, AppError> {
    state
        .auth
        .rate_limit("calendar_reconcile", &auth.user_id.to_string(), 60)
        .await?;
    let row = booking_row(state, auth, id).await?;
    let old_status: String = row.try_get("status")?;
    if !matches!(
        old_status.as_str(),
        "uncertain" | "cancel_uncertain" | "confirmed"
    ) {
        return result(&row);
    }
    let updated: DateTime<Utc> = row.try_get("updated_at")?;
    let event: Option<String> = row.try_get("provider_event_id")?;
    let calendar: String = row.try_get("calendar_id")?;
    let session = mail::account_session(state, auth, row.try_get("account_id")?).await?;
    let found = transport
        .lookup(state, &session, &calendar, id, event.as_deref())
        .await?;
    let (status, event) = match found {
        EventLookup::Present(found) => (
            if old_status == "cancel_uncertain" {
                "cancel_uncertain"
            } else {
                "confirmed"
            },
            Some(found),
        ),
        EventLookup::Absent if old_status == "cancel_uncertain" && event.is_some() => {
            ("cancelled", event)
        }
        // An empty lookup is not proof that an uncertain create never happened.
        EventLookup::Absent => {
            let mut tx = auth.begin_authorized(&state.pool).await?;
            lock_active_account(&mut tx, row.try_get("account_id")?).await?;
            auth.authorize_in_transaction(&mut tx).await?;
            let current = sqlx::query("SELECT * FROM calendar_bookings WHERE id=$1")
                .bind(id)
                .fetch_one(&mut *tx)
                .await?;
            let output = result(&current)?;
            tx.commit().await?;
            return Ok(output);
        }
    };
    let mut tx = auth.begin_authorized(&state.pool).await?;
    lock_active_account(&mut tx, row.try_get("account_id")?).await?;
    auth.authorize_in_transaction(&mut tx).await?;
    let changed = sqlx::query("UPDATE calendar_bookings SET status=$2,provider_event_id=$3,error_code=NULL,updated_at=now() WHERE id=$1 AND status=$4 AND updated_at=$5 RETURNING *")
        .bind(id).bind(status).bind(event).bind(old_status).bind(updated).fetch_optional(&mut *tx).await?;
    let current = if let Some(row) = changed {
        row
    } else {
        sqlx::query("SELECT * FROM calendar_bookings WHERE id=$1")
            .bind(id)
            .fetch_one(&mut *tx)
            .await?
    };
    let output = result(&current)?;
    tx.commit().await?;
    Ok(output)
}
pub async fn cancel_with(
    state: &AppState,
    auth: &AuthContext,
    id: Uuid,
    transport: &dyn CalendarTransport,
) -> Result<BookingResult, AppError> {
    state
        .auth
        .rate_limit("calendar_cancel", &auth.user_id.to_string(), 30)
        .await?;
    let mut row = booking_row(state, auth, id).await?;
    if row.try_get::<String, _>("status")? == "uncertain" {
        reconcile_with(state, auth, id, transport).await?;
        row = booking_row(state, auth, id).await?;
    }
    let status: String = row.try_get("status")?;
    if status == "cancelled" || status == "failed" {
        return result(&row);
    }
    if !matches!(status.as_str(), "confirmed" | "cancel_uncertain") {
        return Err(AppError::conflict(
            "The booking outcome is still being checked. Reconcile it before cancelling; its time remains reserved.",
        ));
    }
    let event: String = row
        .try_get::<Option<String>, _>("provider_event_id")?
        .ok_or_else(|| {
            AppError::conflict(
                "No provider event has been identified yet. Check the booking status again.",
            )
        })?;
    let account: Uuid = row.try_get("account_id")?;
    let calendar: String = row.try_get("calendar_id")?;
    let session = mail::account_session(state, auth, account).await?;
    calendar_provider::require_calendar(&session)?;
    let mut tx = auth.begin_authorized(&state.pool).await?;
    reservation_lock(&mut tx, account).await?;
    let changed = sqlx::query("UPDATE calendar_bookings SET status='cancelling',updated_at=now() WHERE id=$1 AND status IN ('confirmed','cancel_uncertain') AND provider_event_id=$2 RETURNING updated_at")
        .bind(id).bind(&event).fetch_optional(&mut *tx).await?.ok_or_else(|| AppError::conflict("This booking is already changing. Refresh its status."))?;
    let fence: DateTime<Utc> = changed.try_get("updated_at")?;
    tx.commit().await?;
    // The durable claim is committed. Recheck after every wait and retain the
    // session/account authorization locks while making the external mutation.
    let mut tx = auth.begin_authorized(&state.pool).await?;
    postmere_mail::mail_sync::account_operation_lock(
        &mut tx,
        auth.workspace_id,
        auth.user_id,
        account,
    )
    .await?;
    lock_active_account(&mut tx, account).await?;
    auth.authorize_in_transaction(&mut tx).await?;
    let status = match transport.cancel(state, &session, &calendar, &event).await {
        Ok(()) | Err(CalendarError::NotFound) => "cancelled",
        Err(_) => "cancel_uncertain",
    };
    auth.authorize_in_transaction(&mut tx).await?;
    sqlx::query("UPDATE calendar_bookings SET status=$2,error_code=$3,updated_at=now() WHERE id=$1 AND status='cancelling' AND updated_at=$4")
        .bind(id).bind(status).bind(if status == "cancelled" { None } else { Some("cancellation_result_unknown") }).bind(fence).execute(&mut *tx).await?;
    let row = sqlx::query("SELECT * FROM calendar_bookings WHERE id=$1")
        .bind(id)
        .fetch_one(&mut *tx)
        .await?;
    let output = result(&row)?;
    tx.commit().await?;
    Ok(output)
}
