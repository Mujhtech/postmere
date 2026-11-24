use postmere_core::{AppState, error::AppError};
use serde::Deserialize;
use sqlx::postgres::PgListener;
use std::{
    collections::HashMap,
    sync::{Arc, Mutex, Weak},
    time::Duration,
};
use tokio::{
    sync::{Mutex as AsyncMutex, broadcast},
    task::JoinHandle,
};
use uuid::Uuid;

pub(crate) const CHANNEL: &str = "postmere_events_v1";
type Scope = (Uuid, Uuid);
const MAX_STREAMS: usize = 128;
const MAX_ACTOR_STREAMS: usize = 4;

#[derive(Clone, Copy, Deserialize, serde::Serialize, PartialEq, Eq, PartialOrd, Ord)]
#[serde(rename_all = "lowercase")]
pub(crate) enum Kind {
    Accounts,
    Mail,
    Outbox,
    /// A connected assistant used a tool.
    Assistants,
}
#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct Notification {
    workspace_id: Uuid,
    user_id: Uuid,
    kind: Kind,
}
#[derive(Clone)]
pub(crate) enum Hint {
    Change(Kind),
    Reset,
    Close,
}
struct Actor {
    sender: broadcast::Sender<Hint>,
    connections: usize,
}
#[derive(Default)]
struct Subscribers {
    actors: HashMap<Scope, Actor>,
    total: usize,
}

/// Each actor has an independent bounded queue: another tenant's traffic cannot
/// cause lag resets or reveal that traffic through their event timing.
pub(crate) struct Hub {
    subscribers: Mutex<Subscribers>,
    listener: AsyncMutex<Option<JoinHandle<()>>>,
}
impl Hub {
    pub(crate) fn new() -> Arc<Self> {
        Arc::new(Self {
            subscribers: Mutex::new(Subscribers::default()),
            listener: AsyncMutex::new(None),
        })
    }
    pub(crate) async fn subscribe(
        self: &Arc<Self>,
        state: &AppState,
        scope: Scope,
    ) -> Result<(broadcast::Receiver<Hint>, Permit), AppError> {
        let (receiver, permit) = {
            let mut subscribers = self
                .subscribers
                .lock()
                .map_err(|_| AppError::internal("realtime_subscribers"))?;
            if subscribers.total >= MAX_STREAMS
                || subscribers
                    .actors
                    .get(&scope)
                    .is_some_and(|actor| actor.connections >= MAX_ACTOR_STREAMS)
            {
                return Err(AppError::rate_limited());
            }
            let actor = subscribers.actors.entry(scope).or_insert_with(|| Actor {
                sender: broadcast::channel(128).0,
                connections: 0,
            });
            actor.connections += 1;
            let receiver = actor.sender.subscribe();
            subscribers.total += 1;
            (
                receiver,
                Permit {
                    hub: self.clone(),
                    scope,
                },
            )
        };
        let mut task = self.listener.lock().await;
        if task.as_ref().is_none_or(|task| task.is_finished()) {
            let mut listener = PgListener::connect_with(&state.pool)
                .await
                .map_err(|_| AppError::unavailable())?;
            listener
                .listen(CHANNEL)
                .await
                .map_err(|_| AppError::unavailable())?;
            // Subscriber registration and LISTEN both precede the initial
            // ready/reset event, so cache catch-up cannot race listener startup.
            *task = Some(tokio::spawn(listen(listener, Arc::downgrade(self))));
        }
        Ok((receiver, permit))
    }
    fn dispatch(&self, notification: Notification) {
        if let Ok(subscribers) = self.subscribers.lock()
            && let Some(actor) = subscribers
                .actors
                .get(&(notification.workspace_id, notification.user_id))
        {
            let _ = actor.sender.send(Hint::Change(notification.kind));
        }
    }
    fn broadcast(&self, hint: Hint) {
        if let Ok(subscribers) = self.subscribers.lock() {
            for actor in subscribers.actors.values() {
                let _ = actor.sender.send(hint.clone());
            }
        }
    }
}
impl Drop for Hub {
    fn drop(&mut self) {
        if let Some(task) = self.listener.get_mut().take() {
            task.abort();
        }
    }
}
pub(crate) struct Permit {
    hub: Arc<Hub>,
    scope: Scope,
}
impl Drop for Permit {
    fn drop(&mut self) {
        if let Ok(mut subscribers) = self.hub.subscribers.lock() {
            if let Some(actor) = subscribers.actors.get_mut(&self.scope) {
                actor.connections = actor.connections.saturating_sub(1);
                if actor.connections == 0 {
                    subscribers.actors.remove(&self.scope);
                }
            }
            subscribers.total = subscribers.total.saturating_sub(1);
        }
    }
}
async fn listen(mut listener: PgListener, hub: Weak<Hub>) {
    let mut idle = tokio::time::interval(Duration::from_secs(2));
    loop {
        tokio::select! {
            result=listener.try_recv()=>{
                let Some(hub)=hub.upgrade()else{return};
                match result{
                    Ok(Some(notification))=>{
                        if notification.payload().len()<=512
                            && let Ok(notification)=serde_json::from_str(notification.payload()){
                                hub.dispatch(notification);
                            }
                    }
                    Ok(None)=>hub.broadcast(Hint::Reset), // SQLx has re-LISTENed before returning None.
                    Err(_)=>{
                        let mut task=hub.listener.lock().await;
                        task.take();hub.broadcast(Hint::Close);return
                    }
                }
            }
            _=idle.tick()=>{
                let Some(hub)=hub.upgrade()else{return};
                let mut task=hub.listener.lock().await;
                // Serialize shutdown with subscribe(). A new subscriber either
                // sees this listener alive or starts a fresh, fully ready one.
                if hub.subscribers.lock().map(|s|s.total==0).unwrap_or(true){
                    task.take();return;
                }
            }
        }
    }
}
