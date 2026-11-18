//! Scoped live invalidations for native clients. PostgreSQL commits generate
//! hints; authoritative cache cursors recover gaps on every stream connection.
mod hub;

use axum::{
    Extension, Router,
    extract::State,
    http::{HeaderMap, HeaderValue},
    response::{IntoResponse, Response, Sse, sse::Event},
    routing::get,
};
use futures_util::stream;
use hub::{Hint, Hub, Kind, Permit};
use postmere_core::{AppState, auth::AuthContext, error::AppError};
use std::{collections::BTreeSet, convert::Infallible, sync::Arc, time::Duration};
use tokio::{
    sync::{broadcast, watch},
    time::{Instant, Interval},
};
use uuid::Uuid;

#[derive(Clone)]
pub struct ShutdownSignal(watch::Receiver<bool>);
/// Signal live response bodies before HTTP graceful shutdown waits for them.
pub fn shutdown_channel() -> (watch::Sender<bool>, ShutdownSignal) {
    let (sender, receiver) = watch::channel(false);
    (sender, ShutdownSignal(receiver))
}

/// One listener is shared by this application's response streams and shuts down
/// when the final subscriber leaves. Construct once while composing the app.
pub fn router() -> Router<AppState> {
    let hub = Hub::new();
    Router::new().route(
        "/v1/events",
        get(
            move |State(state): State<AppState>,
                  auth: AuthContext,
                  headers: HeaderMap,
                  shutdown: Option<Extension<ShutdownSignal>>| {
                let hub = hub.clone();
                async move { events(state, auth, headers, hub, shutdown.map(|s| s.0)).await }
            },
        ),
    )
}

async fn events(
    state: AppState,
    auth: AuthContext,
    headers: HeaderMap,
    hub: Arc<Hub>,
    shutdown: Option<ShutdownSignal>,
) -> Result<Response, AppError> {
    if headers.get_all("last-event-id").iter().count() > 1 {
        return Err(AppError::bad_request("Invalid event cursor."));
    }
    let reconnect = if let Some(cursor) = headers.get("last-event-id") {
        let cursor = cursor
            .to_str()
            .map_err(|_| AppError::bad_request("Invalid event cursor."))?;
        if cursor.is_empty() || cursor.len() > 256 || !cursor.bytes().all(|c| c.is_ascii_graphic())
        {
            return Err(AppError::bad_request("Invalid event cursor."));
        }
        true
    } else {
        false
    };
    state
        .auth
        .rate_limit("realtime_connect", &auth.session_id.to_string(), 300)
        .await?;
    let (receiver, permit) = hub
        .subscribe(&state, (auth.workspace_id, auth.user_id))
        .await?;
    authorize(&state, &auth).await?;
    let now = Instant::now();
    let data = StreamState {
        state,
        auth,
        receiver,
        _permit: permit,
        initial: Some(if reconnect { "reset" } else { "ready" }),
        authentication: tokio::time::interval_at(
            now + Duration::from_secs(2),
            Duration::from_secs(2),
        ),
        heartbeat: tokio::time::interval_at(now + Duration::from_secs(15), Duration::from_secs(15)),
        shutdown,
    };
    let stream = stream::unfold(data, |mut data| async move {
        match data.next().await {
            Some(event) => Some((Ok::<_, Infallible>(event), data)),
            None => None,
        }
    });
    let mut response = Sse::new(stream).into_response();
    response
        .headers_mut()
        .insert("x-accel-buffering", HeaderValue::from_static("no"));
    Ok(response)
}
async fn authorize(state: &AppState, auth: &AuthContext) -> Result<(), AppError> {
    let tx = auth.begin_authorized(&state.pool).await?;
    tx.commit().await?;
    Ok(())
}
struct StreamState {
    state: AppState,
    auth: AuthContext,
    receiver: broadcast::Receiver<Hint>,
    _permit: Permit,
    initial: Option<&'static str>,
    authentication: Interval,
    heartbeat: Interval,
    shutdown: Option<ShutdownSignal>,
}
impl StreamState {
    async fn next(&mut self) -> Option<Event> {
        if self.shutdown.as_ref().is_some_and(|s| *s.0.borrow()) {
            return None;
        }
        if let Some(name) = self.initial.take() {
            authorize(&self.state, &self.auth).await.ok()?;
            return Some(event(name, [Kind::Accounts, Kind::Mail, Kind::Outbox]));
        }
        loop {
            tokio::select! {
                biased;
                _=wait_for_shutdown(&mut self.shutdown)=>return None,
                _=self.authentication.tick()=>{authorize(&self.state,&self.auth).await.ok()?;}
                _=self.heartbeat.tick()=>{
                    authorize(&self.state,&self.auth).await.ok()?;
                    return Some(Event::default().comment("keep-alive"));
                }
                hint=self.receiver.recv()=>{
                    let mut kinds=BTreeSet::new();let mut reset=false;
                    match hint{
                        Ok(Hint::Change(kind))=>{kinds.insert(kind);}
                        Ok(Hint::Reset)|Err(broadcast::error::RecvError::Lagged(_))=>reset=true,
                        Ok(Hint::Close)|Err(broadcast::error::RecvError::Closed)=>return None,
                    }
                    // Coalesce a committed provider page and fast follow-up
                    // changes. The bounded drain cannot starve authorization.
                    for _ in 0..128{
                        match self.receiver.try_recv(){
                            Ok(Hint::Change(kind))=>{kinds.insert(kind);}
                            Ok(Hint::Reset)|Err(broadcast::error::TryRecvError::Lagged(_))=>reset=true,
                            Ok(Hint::Close)|Err(broadcast::error::TryRecvError::Closed)=>return None,
                            Err(broadcast::error::TryRecvError::Empty)=>break,
                        }
                    }
                    authorize(&self.state,&self.auth).await.ok()?;
                    if reset{return Some(event("reset",[Kind::Accounts,Kind::Mail,Kind::Outbox]));}
                    return Some(event("change",kinds));
                }
            }
        }
    }
}
async fn wait_for_shutdown(signal: &mut Option<ShutdownSignal>) {
    let Some(signal) = signal.as_mut() else {
        std::future::pending::<()>().await;
        return;
    };
    loop {
        if *signal.0.borrow() {
            return;
        }
        if signal.0.changed().await.is_err() {
            return;
        }
    }
}
fn event(name: &str, kinds: impl IntoIterator<Item = Kind>) -> Event {
    let kinds: Vec<_> = kinds.into_iter().collect();
    Event::default()
        .event(name)
        .id(Uuid::new_v4().to_string())
        .retry(Duration::from_secs(3))
        .data(serde_json::json!({"version":1,"kinds":kinds}).to_string())
}
