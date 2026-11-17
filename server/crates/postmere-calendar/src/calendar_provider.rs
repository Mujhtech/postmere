//! Fixed-origin adapters for the account's primary calendar. Incomplete pages,
//! unknown time zones and provider failures never turn into empty availability.
use chrono::{DateTime, Duration, NaiveDate, NaiveDateTime, TimeZone, Utc};
use chrono_tz::Tz;
use postmere_core::{AppState, error::AppError};
use postmere_mail::mail::AccountSession;
use postmere_providers::{self as provider, Provider};
use serde::{Deserialize, Serialize};
use serde_json::{Value, json};
use std::{future::Future, pin::Pin, time::Duration as StdDuration};
use url::Url;
use uuid::Uuid;

const GOOGLE: &str = "https://www.googleapis.com/calendar/v3/calendars/primary/events";
const GRAPH: &str = "https://graph.microsoft.com/v1.0/me/calendar/calendarView";
const MAX_BODY: usize = 8 * 1024 * 1024;

#[derive(Clone, Debug, Serialize, Deserialize, PartialEq, Eq)]
pub struct Interval {
    pub start: DateTime<Utc>,
    pub end: DateTime<Utc>,
}
impl Interval {
    pub fn overlaps(&self, other: &Self) -> bool {
        self.start < other.end && other.start < self.end
    }
}
#[derive(Clone, Debug)]
pub struct BookingEvent {
    pub id: Uuid,
    pub title: String,
    pub description: String,
    pub guest_name: String,
    pub guest_email: String,
    pub interval: Interval,
}
#[derive(Clone, Copy, Debug, Deserialize, Serialize, PartialEq, Eq)]
#[serde(rename_all = "lowercase")]
pub enum InvitationResponse {
    Accepted,
    Tentative,
    Declined,
}
impl InvitationResponse {
    fn google(self) -> &'static str {
        match self {
            Self::Accepted => "accepted",
            Self::Tentative => "tentative",
            Self::Declined => "declined",
        }
    }
    fn graph(self) -> &'static str {
        match self {
            Self::Accepted => "accept",
            Self::Tentative => "tentativelyAccept",
            Self::Declined => "decline",
        }
    }
}
#[derive(Clone, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct InvitationRequest {
    pub account_id: Uuid,
    pub ical_uid: String,
    pub organizer: String,
    pub start: DateTime<Utc>,
    pub end: DateTime<Utc>,
    pub response: InvitationResponse,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum CalendarError {
    Unavailable,
    InvalidResponse,
    Rejected,
    Ambiguous,
    NotFound,
}
impl From<CalendarError> for AppError {
    fn from(error: CalendarError) -> Self {
        match error {
            CalendarError::Rejected => AppError::conflict(
                "The calendar provider declined this action. Check your account connection and calendar.",
            ),
            CalendarError::NotFound => AppError::not_found(),
            CalendarError::Ambiguous => AppError::conflict(
                "The calendar provider did not confirm the result. Check your calendar before trying again.",
            ),
            _ => AppError::unavailable(),
        }
    }
}
pub fn require_calendar(session: &AccountSession) -> Result<Provider, AppError> {
    let provider = Provider::parse(&session.account.provider)?;
    if !session.account.capabilities.iter().any(|c| c == "calendar")
        || !provider::has_calendar_scope(provider, &session.credentials)
    {
        return Err(AppError::conflict(
            "Connect calendar access for this account before continuing.",
        ));
    }
    Ok(provider)
}

pub type CalendarFuture<'a, T> =
    Pin<Box<dyn Future<Output = Result<T, CalendarError>> + Send + 'a>>;
/// The injected transport lets integration tests exercise durable reservations
/// and failures without sending calendar invitations to real people.
pub trait CalendarTransport: Send + Sync {
    fn busy<'a>(
        &'a self,
        state: &'a AppState,
        session: &'a AccountSession,
        range: &'a Interval,
    ) -> CalendarFuture<'a, Vec<Interval>>;
    fn create<'a>(
        &'a self,
        state: &'a AppState,
        session: &'a AccountSession,
        event: &'a BookingEvent,
    ) -> CalendarFuture<'a, String>;
}
pub struct LiveCalendar;
impl CalendarTransport for LiveCalendar {
    fn busy<'a>(
        &'a self,
        state: &'a AppState,
        session: &'a AccountSession,
        range: &'a Interval,
    ) -> CalendarFuture<'a, Vec<Interval>> {
        Box::pin(async move {
            tokio::time::timeout(StdDuration::from_secs(12), busy(state, session, range))
                .await
                .map_err(|_| CalendarError::Unavailable)?
        })
    }
    fn create<'a>(
        &'a self,
        state: &'a AppState,
        session: &'a AccountSession,
        event: &'a BookingEvent,
    ) -> CalendarFuture<'a, String> {
        Box::pin(create(state, session, event))
    }
}

async fn request(builder: reqwest::RequestBuilder, mutation: bool) -> Result<Value, CalendarError> {
    let mut response = builder
        .timeout(StdDuration::from_secs(8))
        .send()
        .await
        .map_err(|_| {
            if mutation {
                CalendarError::Ambiguous
            } else {
                CalendarError::Unavailable
            }
        })?;
    let status = response.status();
    if !status.is_success() {
        return Err(if status.is_server_error() || status.as_u16() == 408 {
            if mutation {
                CalendarError::Ambiguous
            } else {
                CalendarError::Unavailable
            }
        } else if status.as_u16() == 404 {
            CalendarError::NotFound
        } else {
            CalendarError::Rejected
        });
    }
    if status.as_u16() == 204 || status.as_u16() == 202 {
        return Ok(Value::Null);
    }
    if response
        .content_length()
        .is_some_and(|n| n > MAX_BODY as u64)
    {
        return Err(if mutation {
            CalendarError::Ambiguous
        } else {
            CalendarError::InvalidResponse
        });
    }
    let mut bytes = Vec::new();
    while let Some(chunk) = response.chunk().await.map_err(|_| {
        if mutation {
            CalendarError::Ambiguous
        } else {
            CalendarError::Unavailable
        }
    })? {
        if bytes.len() + chunk.len() > MAX_BODY {
            return Err(if mutation {
                CalendarError::Ambiguous
            } else {
                CalendarError::InvalidResponse
            });
        }
        bytes.extend_from_slice(&chunk);
    }
    serde_json::from_slice(&bytes).map_err(|_| {
        if mutation {
            CalendarError::Ambiguous
        } else {
            CalendarError::InvalidResponse
        }
    })
}

fn google_time(value: &Value, fallback_zone: &str) -> Result<DateTime<Utc>, CalendarError> {
    if let Some(raw) = value.get("dateTime").and_then(Value::as_str) {
        if let Ok(time) = DateTime::parse_from_rfc3339(raw) {
            return Ok(time.with_timezone(&Utc));
        }
        let naive = NaiveDateTime::parse_from_str(raw, "%Y-%m-%dT%H:%M:%S%.f")
            .map_err(|_| CalendarError::InvalidResponse)?;
        let zone: Tz = value
            .get("timeZone")
            .and_then(Value::as_str)
            .unwrap_or(fallback_zone)
            .parse()
            .map_err(|_| CalendarError::InvalidResponse)?;
        return zone
            .from_local_datetime(&naive)
            .single()
            .map(|d| d.with_timezone(&Utc))
            .ok_or(CalendarError::InvalidResponse);
    }
    let raw = value
        .get("date")
        .and_then(Value::as_str)
        .ok_or(CalendarError::InvalidResponse)?;
    let day =
        NaiveDate::parse_from_str(raw, "%Y-%m-%d").map_err(|_| CalendarError::InvalidResponse)?;
    let zone: Tz = value
        .get("timeZone")
        .and_then(Value::as_str)
        .unwrap_or(fallback_zone)
        .parse()
        .map_err(|_| CalendarError::InvalidResponse)?;
    zone.from_local_datetime(
        &day.and_hms_opt(0, 0, 0)
            .ok_or(CalendarError::InvalidResponse)?,
    )
    .single()
    .map(|d| d.with_timezone(&Utc))
    .ok_or(CalendarError::InvalidResponse)
}
fn graph_time(value: &Value) -> Result<DateTime<Utc>, CalendarError> {
    let raw = value
        .get("dateTime")
        .and_then(Value::as_str)
        .ok_or(CalendarError::InvalidResponse)?;
    if let Ok(time) = DateTime::parse_from_rfc3339(raw) {
        return Ok(time.with_timezone(&Utc));
    }
    let naive = NaiveDateTime::parse_from_str(raw, "%Y-%m-%dT%H:%M:%S%.f")
        .map_err(|_| CalendarError::InvalidResponse)?;
    if value.get("timeZone").and_then(Value::as_str) != Some("UTC") {
        return Err(CalendarError::InvalidResponse);
    }
    Ok(Utc.from_utc_datetime(&naive))
}
fn event_interval(
    provider: Provider,
    event: &Value,
    zone: &str,
) -> Result<Interval, CalendarError> {
    let start = event.get("start").ok_or(CalendarError::InvalidResponse)?;
    let end = event.get("end").ok_or(CalendarError::InvalidResponse)?;
    let range = match provider {
        Provider::Gmail => Interval {
            start: google_time(start, zone)?,
            end: google_time(end, zone)?,
        },
        Provider::Microsoft => Interval {
            start: graph_time(start)?,
            end: graph_time(end)?,
        },
    };
    if range.end <= range.start {
        return Err(CalendarError::InvalidResponse);
    }
    Ok(range)
}
fn graph_cursor(raw: &str) -> Result<Url, CalendarError> {
    let url = Url::parse(raw).map_err(|_| CalendarError::InvalidResponse)?;
    if raw.len() > 16_384
        || url.scheme() != "https"
        || url.host_str() != Some("graph.microsoft.com")
        || url.port_or_known_default() != Some(443)
        || !url.username().is_empty()
        || url.password().is_some()
        || url.fragment().is_some()
        || !matches!(
            url.path(),
            "/v1.0/me/calendar/calendarView" | "/v1.0/me/calendarView"
        )
    {
        return Err(CalendarError::InvalidResponse);
    }
    Ok(url)
}

async fn events(
    state: &AppState,
    session: &AccountSession,
    range: &Interval,
    uid: Option<&str>,
) -> Result<(Provider, Vec<(Value, String)>), CalendarError> {
    let provider = require_calendar(session).map_err(|_| CalendarError::Rejected)?;
    let mut url = Url::parse(if provider == Provider::Gmail {
        GOOGLE
    } else {
        GRAPH
    })
    .map_err(|_| CalendarError::InvalidResponse)?;
    if provider == Provider::Gmail {
        url.query_pairs_mut().extend_pairs([
            ("timeMin", range.start.to_rfc3339()),
            ("timeMax", range.end.to_rfc3339()),
            ("singleEvents", "true".into()),
            ("showDeleted", "false".into()),
            ("maxResults", "1000".into()),
        ]);
        if let Some(uid) = uid {
            url.query_pairs_mut().append_pair("iCalUID", uid);
        }
    } else {
        url.query_pairs_mut().extend_pairs([("startDateTime",range.start.to_rfc3339()),("endDateTime",range.end.to_rfc3339()),("$top","1000".into()),("$select","id,iCalUId,start,end,showAs,isCancelled,isOrganizer,organizer,attendees,responseStatus".into())]);
    }
    let first = url.clone();
    let mut result = vec![];
    for _ in 0..10 {
        let value = request(
            state
                .http
                .get(url.clone())
                .bearer_auth(&session.credentials.access_token)
                .header("Prefer", "outlook.timezone=\"UTC\""),
            false,
        )
        .await?;
        let zone = if provider == Provider::Gmail {
            value
                .get("timeZone")
                .and_then(Value::as_str)
                .ok_or(CalendarError::InvalidResponse)?
        } else {
            "UTC"
        };
        let rows = match value.get(if provider == Provider::Gmail {
            "items"
        } else {
            "value"
        }) {
            Some(Value::Array(rows)) => rows.as_slice(),
            None if provider == Provider::Gmail
                && value.get("kind").and_then(Value::as_str) == Some("calendar#events") =>
            {
                &[]
            }
            _ => return Err(CalendarError::InvalidResponse),
        };
        if result.len() + rows.len() > 10_000 {
            return Err(CalendarError::InvalidResponse);
        }
        result.extend(rows.iter().cloned().map(|v| (v, zone.to_owned())));
        let next = value
            .get(if provider == Provider::Gmail {
                "nextPageToken"
            } else {
                "@odata.nextLink"
            })
            .and_then(Value::as_str);
        match next {
            None => return Ok((provider, result)),
            Some(next) if provider == Provider::Gmail => {
                if next.is_empty() || next.len() > 8192 {
                    return Err(CalendarError::InvalidResponse);
                }
                url = first.clone();
                url.query_pairs_mut().append_pair("pageToken", next);
            }
            Some(next) => url = graph_cursor(next)?,
        }
    }
    Err(CalendarError::InvalidResponse)
}

async fn busy(
    state: &AppState,
    session: &AccountSession,
    range: &Interval,
) -> Result<Vec<Interval>, CalendarError> {
    let (provider, events) = events(state, session, range, None).await?;
    let mut result = vec![];
    for (event, zone) in events {
        let free = match provider {
            Provider::Gmail => {
                event["status"] == "cancelled"
                    || event["transparency"] == "transparent"
                    || event["attendees"].as_array().is_some_and(|a| {
                        a.iter()
                            .any(|v| v["self"] == true && v["responseStatus"] == "declined")
                    })
            }
            Provider::Microsoft => {
                event["isCancelled"] == true
                    || event["showAs"] == "free"
                    || event["responseStatus"]["response"] == "declined"
            }
        };
        if free {
            continue;
        }
        let mut interval = event_interval(provider, &event, &zone)?;
        if interval.overlaps(range) {
            interval.start = interval.start.max(range.start);
            interval.end = interval.end.min(range.end);
            result.push(interval)
        }
    }
    result.sort_by_key(|r| r.start);
    Ok(result)
}

async fn create(
    state: &AppState,
    session: &AccountSession,
    event: &BookingEvent,
) -> Result<String, CalendarError> {
    let provider = require_calendar(session).map_err(|_| CalendarError::Rejected)?;
    let (url, body) = match provider {
        Provider::Gmail => (
            format!("{GOOGLE}?sendUpdates=all"),
            json!({"id":event.id.simple().to_string(),"summary":event.title,"description":event.description,"start":{"dateTime":event.interval.start.to_rfc3339()},"end":{"dateTime":event.interval.end.to_rfc3339()},"attendees":[{"email":event.guest_email,"displayName":event.guest_name}],"guestsCanInviteOthers":false,"guestsCanModify":false,"transparency":"opaque","visibility":"private"}),
        ),
        Provider::Microsoft => (
            "https://graph.microsoft.com/v1.0/me/events".into(),
            json!({"transactionId":event.id,"subject":event.title,"body":{"contentType":"text","content":event.description},"start":{"dateTime":event.interval.start.format("%Y-%m-%dT%H:%M:%S").to_string(),"timeZone":"UTC"},"end":{"dateTime":event.interval.end.format("%Y-%m-%dT%H:%M:%S").to_string(),"timeZone":"UTC"},"attendees":[{"emailAddress":{"address":event.guest_email,"name":event.guest_name},"type":"required"}],"showAs":"busy","sensitivity":"private","allowNewTimeProposals":false}),
        ),
    };
    let value = request(
        state
            .http
            .post(url)
            .bearer_auth(&session.credentials.access_token)
            .json(&body),
        true,
    )
    .await?;
    value
        .get("id")
        .and_then(Value::as_str)
        .filter(|id| !id.is_empty() && id.len() <= 4096)
        .map(str::to_owned)
        .ok_or(CalendarError::Ambiguous)
}

fn event_url(provider: Provider, id: &str) -> Result<Url, CalendarError> {
    if id.is_empty() || id.len() > 4096 {
        return Err(CalendarError::InvalidResponse);
    }
    let mut url = Url::parse(if provider == Provider::Gmail {
        GOOGLE
    } else {
        "https://graph.microsoft.com/v1.0/me/events"
    })
    .map_err(|_| CalendarError::InvalidResponse)?;
    url.path_segments_mut()
        .map_err(|_| CalendarError::InvalidResponse)?
        .push(id);
    Ok(url)
}
fn verified_invitation(
    provider: Provider,
    event: &Value,
    zone: &str,
    account_email: &str,
    input: &InvitationRequest,
) -> Result<String, CalendarError> {
    let uid = event
        .get(if provider == Provider::Gmail {
            "iCalUID"
        } else {
            "iCalUId"
        })
        .and_then(Value::as_str);
    let organizer = if provider == Provider::Gmail {
        event["organizer"]["email"].as_str()
    } else {
        event["organizer"]["emailAddress"]["address"].as_str()
    };
    let interval = event_interval(provider, event, zone)?;
    if uid != Some(input.ical_uid.as_str())
        || !organizer.is_some_and(|email| email.eq_ignore_ascii_case(&input.organizer))
        || interval.start != input.start
        || interval.end != input.end
    {
        return Err(CalendarError::NotFound);
    }
    if event["status"] == "cancelled"
        || event["isCancelled"] == true
        || event["organizer"]["self"] == true
        || event["isOrganizer"] == true
    {
        return Err(CalendarError::Rejected);
    }
    let attendees = event["attendees"]
        .as_array()
        .ok_or(CalendarError::Rejected)?;
    let own = attendees
        .iter()
        .filter_map(|a| match provider {
            Provider::Gmail if a["self"] == true => a["email"].as_str(),
            Provider::Microsoft => a["emailAddress"]["address"]
                .as_str()
                .filter(|email| email.eq_ignore_ascii_case(account_email)),
            _ => None,
        })
        .collect::<Vec<_>>();
    if own.len() != 1 || !provider::valid_email(own[0]) {
        return Err(CalendarError::Rejected);
    }
    Ok(own[0].to_owned())
}

pub async fn respond(
    state: &AppState,
    session: &AccountSession,
    input: &InvitationRequest,
) -> Result<(), AppError> {
    require_calendar(session)?;
    if input.ical_uid.is_empty()
        || input.ical_uid.len() > 1024
        || input.ical_uid.chars().any(char::is_control)
        || !provider::valid_email(&input.organizer)
        || input.end <= input.start
        || input.end - input.start > Duration::days(32)
    {
        return Err(AppError::bad_request(
            "The invitation does not contain a supported event identity and time.",
        ));
    }
    let range = Interval {
        start: input.start - Duration::seconds(1),
        end: input.end + Duration::seconds(1),
    };
    let (provider, listed) = tokio::time::timeout(
        StdDuration::from_secs(12),
        events(state, session, &range, Some(&input.ical_uid)),
    )
    .await
    .map_err(|_| AppError::unavailable())??;
    let matches = listed
        .into_iter()
        .filter(|(v, z)| verified_invitation(provider, v, z, &session.account.email, input).is_ok())
        .collect::<Vec<_>>();
    if matches.len() != 1 {
        return Err(AppError::conflict(
            "A matching invitation for this account was not found in its primary calendar. Check the organizer, time, and connected account.",
        ));
    }
    let (matched, zone) = &matches[0];
    let id = matched["id"]
        .as_str()
        .ok_or(CalendarError::InvalidResponse)?;
    let mut url = event_url(provider, id)?;
    let event = request(
        state
            .http
            .get(url.clone())
            .bearer_auth(&session.credentials.access_token)
            .header("Prefer", "outlook.timezone=\"UTC\""),
        false,
    )
    .await?;
    let own = verified_invitation(provider, &event, zone, &session.account.email, input)?;
    match provider {
        Provider::Gmail => {
            let etag = event["etag"]
                .as_str()
                .filter(|v| v.len() < 1024)
                .ok_or(CalendarError::InvalidResponse)?;
            url.query_pairs_mut().append_pair("sendUpdates", "all");
            request(state.http.patch(url).bearer_auth(&session.credentials.access_token).header("If-Match",etag).json(&json!({"attendeesOmitted":true,"attendees":[{"email":own,"responseStatus":input.response.google()}]})),true).await?;
        }
        Provider::Microsoft => {
            url.path_segments_mut()
                .map_err(|_| CalendarError::InvalidResponse)?
                .push(input.response.graph());
            request(
                state
                    .http
                    .post(url)
                    .bearer_auth(&session.credentials.access_token)
                    .json(&json!({"sendResponse":true})),
                true,
            )
            .await?;
        }
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn adjacent_intervals_do_not_overlap_and_all_day_uses_calendar_zone() {
        let start = Utc.with_ymd_and_hms(2026, 11, 1, 8, 0, 0).unwrap();
        let a = Interval {
            start,
            end: start + Duration::minutes(30),
        };
        let b = Interval {
            start: a.end,
            end: a.end + Duration::minutes(30),
        };
        assert!(!a.overlaps(&b));
        let start = google_time(&json!({"date":"2026-11-01"}), "America/New_York").unwrap();
        let end = google_time(&json!({"date":"2026-11-02"}), "America/New_York").unwrap();
        assert_eq!(end - start, Duration::hours(25));
        assert!(google_time(&json!({"date":"2026-11-01"}), "Unknown/Timezone").is_err());
    }
    #[test]
    fn graph_cursor_cannot_move_tokens_to_another_origin_or_resource() {
        assert!(
            graph_cursor("https://graph.microsoft.com/v1.0/me/calendar/calendarView?$skiptoken=a")
                .is_ok()
        );
        for url in [
            "http://graph.microsoft.com/v1.0/me/calendarView",
            "https://graph.microsoft.com.evil.test/v1.0/me/calendarView",
            "https://graph.microsoft.com/v1.0/me/messages",
            "https://user@graph.microsoft.com/v1.0/me/calendarView",
            "https://graph.microsoft.com:444/v1.0/me/calendarView",
        ] {
            assert!(graph_cursor(url).is_err())
        }
        assert_eq!(
            event_url(Provider::Microsoft, "id/../other?token")
                .unwrap()
                .path(),
            "/v1.0/me/events/id%2F..%2Fother%3Ftoken"
        );
    }
    #[test]
    fn rsvp_requires_provider_identity_organizer_time_and_own_attendee() {
        let start = Utc.with_ymd_and_hms(2026, 11, 18, 9, 0, 0).unwrap();
        let input = InvitationRequest {
            account_id: Uuid::new_v4(),
            ical_uid: "invitation@example.test".into(),
            organizer: "host@example.test".into(),
            start,
            end: start + Duration::hours(1),
            response: InvitationResponse::Accepted,
        };
        let mut event = json!({"iCalUID":input.ical_uid,"organizer":{"email":input.organizer,"self":false},"start":{"dateTime":input.start.to_rfc3339()},"end":{"dateTime":input.end.to_rfc3339()},"attendees":[{"email":"me@example.test","self":true}]});
        assert!(
            verified_invitation(Provider::Gmail, &event, "UTC", "me@example.test", &input).is_ok()
        );
        event["attendees"][0]["self"] = json!(false);
        assert!(
            verified_invitation(Provider::Gmail, &event, "UTC", "me@example.test", &input).is_err()
        );
        event["attendees"][0]["self"] = json!(true);
        event["organizer"]["email"] = json!("forged@example.test");
        assert!(
            verified_invitation(Provider::Gmail, &event, "UTC", "me@example.test", &input).is_err()
        );
        event["organizer"]["email"] = json!(input.organizer);
        event["start"]["dateTime"] = json!((input.start + Duration::hours(1)).to_rfc3339());
        assert!(
            verified_invitation(Provider::Gmail, &event, "UTC", "me@example.test", &input).is_err()
        );
    }
}
