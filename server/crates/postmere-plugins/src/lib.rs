//! First-party plugins. The host decides which plugins apply to a message,
//! keeps each user's choices and settings, and logs tool calls. See
//! docs/plugin-system.md for the design.
use axum::{
    Json, Router,
    extract::{DefaultBodyLimit, Path, Query, State},
    routing::{get, post},
};
use chrono::{NaiveDate, Utc};
use postmere_core::{AppState, auth::AuthContext, error::AppError};
use postmere_mail::mail;
use serde::{Deserialize, Serialize};
use serde_json::{Map, Value};
use sqlx::Row;
use std::collections::HashMap;
use uuid::Uuid;

pub mod bills;
pub mod card;
pub mod deploys;
pub mod detect;
pub mod github;
pub mod incidents;
pub mod issues;
pub mod packages;
pub mod plugin;
pub mod sentry;
#[cfg(test)]
mod testing;

use card::{Card, ToolResult};
use plugin::{Context, MessageAction, Plugin, SettingField, ToolError};

/// Every plugin this server ships, in banner priority order.
pub fn registry() -> &'static [&'static dyn Plugin] {
    &[
        &incidents::Incidents,
        &github::GitHub,
        &sentry::Sentry,
        &deploys::Deploys,
        &issues::Issues,
        &packages::Packages,
        &bills::Bills,
    ]
}

fn find(id: &str) -> Option<&'static dyn Plugin> {
    registry().iter().copied().find(|p| p.manifest().id == id)
}

pub fn router() -> Router<AppState> {
    Router::new()
        .route("/v1/plugins", get(list))
        .route(
            "/v1/plugins/{id}",
            axum::routing::put(update).layer(DefaultBodyLimit::max(8192)),
        )
        .route(
            "/v1/plugins/{id}/tools/{tool}",
            post(call_tool).layer(DefaultBodyLimit::max(8192)),
        )
        .route("/v1/mail/messages/{id}/plugins", get(message_plugins))
}

// MARK: Installs

struct Install {
    enabled: bool,
    settings: Map<String, Value>,
}

async fn installs(
    state: &AppState,
    auth: &AuthContext,
) -> Result<HashMap<String, Install>, AppError> {
    let mut tx = auth.begin(&state.pool).await?;
    let rows = sqlx::query("SELECT plugin_id, enabled, settings FROM plugin_installs")
        .fetch_all(&mut *tx)
        .await?;
    tx.commit().await?;
    rows.iter()
        .map(|row| {
            let settings = match row.try_get::<Value, _>("settings")? {
                Value::Object(map) => map,
                _ => Map::new(),
            };
            Ok((
                row.try_get("plugin_id")?,
                Install {
                    enabled: row.try_get("enabled")?,
                    settings,
                },
            ))
        })
        .collect::<Result<_, sqlx::Error>>()
        .map_err(Into::into)
}

/// Saved values for known fields, defaults for the rest.
fn resolved_settings(
    fields: &[SettingField],
    saved: Option<&Map<String, Value>>,
) -> Map<String, Value> {
    fields
        .iter()
        .map(|field| {
            let value = saved
                .and_then(|s| s.get(field.key))
                .filter(|v| field.accepts(v))
                .cloned()
                .unwrap_or_else(|| field.default_value());
            (field.key.to_owned(), value)
        })
        .collect()
}

#[derive(Serialize)]
struct PluginInfo {
    id: &'static str,
    name: &'static str,
    summary: &'static str,
    version: u32,
    icon: &'static str,
    tint: &'static str,
    brands: Vec<&'static str>,
    /// Plain-language descriptions of what the plugin may access.
    permissions: Vec<&'static str>,
    enabled: bool,
    /// Each field carries its current value, so clients never key a map by
    /// setting name (and never trip over key-case conversion).
    settings: Vec<SettingState>,
    activity: Vec<Activity>,
}

#[derive(Serialize)]
struct SettingState {
    #[serde(flatten)]
    field: SettingField,
    value: Value,
}

#[derive(Serialize)]
struct Activity {
    tool: String,
    succeeded: bool,
    at: chrono::DateTime<Utc>,
}

#[derive(Serialize)]
struct PluginList {
    plugins: Vec<PluginInfo>,
}

async fn activity(
    state: &AppState,
    auth: &AuthContext,
) -> Result<HashMap<String, Vec<Activity>>, AppError> {
    let mut tx = auth.begin(&state.pool).await?;
    let rows = sqlx::query(
        "SELECT plugin_id, tool, succeeded, at FROM (SELECT *, row_number() OVER (PARTITION BY plugin_id ORDER BY at DESC) AS n FROM plugin_activity WHERE at > now() - interval '7 days') recent WHERE n <= 20 ORDER BY at DESC",
    )
    .fetch_all(&mut *tx)
    .await?;
    tx.commit().await?;
    let mut grouped: HashMap<String, Vec<Activity>> = HashMap::new();
    for row in rows {
        grouped
            .entry(row.try_get("plugin_id")?)
            .or_default()
            .push(Activity {
                tool: row.try_get("tool")?,
                succeeded: row.try_get("succeeded")?,
                at: row.try_get("at")?,
            });
    }
    Ok(grouped)
}

fn info(plugin: &dyn Plugin, install: Option<&Install>, activity: Vec<Activity>) -> PluginInfo {
    let manifest = plugin.manifest();
    let mut values = resolved_settings(&manifest.settings, install.map(|i| &i.settings));
    PluginInfo {
        id: manifest.id,
        name: manifest.name,
        summary: manifest.summary,
        version: manifest.version,
        icon: manifest.icon,
        tint: manifest.tint,
        brands: manifest.brands.clone(),
        permissions: manifest
            .permissions
            .iter()
            .map(|p| p.description())
            .collect(),
        enabled: install.is_some_and(|i| i.enabled),
        settings: manifest
            .settings
            .into_iter()
            .map(|field| SettingState {
                value: values
                    .remove(field.key)
                    .unwrap_or_else(|| field.default_value()),
                field,
            })
            .collect(),
        activity,
    }
}

async fn list(
    auth: AuthContext,
    State(state): State<AppState>,
) -> Result<Json<PluginList>, AppError> {
    let installs = installs(&state, &auth).await?;
    let mut activity = activity(&state, &auth).await?;
    Ok(Json(PluginList {
        plugins: registry()
            .iter()
            .map(|p| {
                let id = p.manifest().id;
                info(
                    *p,
                    installs.get(id),
                    activity.remove(id).unwrap_or_default(),
                )
            })
            .collect(),
    }))
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct UpdateInput {
    enabled: bool,
    #[serde(default)]
    values: Map<String, Value>,
}

async fn update(
    auth: AuthContext,
    State(state): State<AppState>,
    Path(id): Path<String>,
    Json(input): Json<UpdateInput>,
) -> Result<Json<PluginInfo>, AppError> {
    let plugin = find(&id).ok_or_else(AppError::not_found)?;
    let fields = plugin.manifest().settings;
    for (key, value) in &input.values {
        let field = fields
            .iter()
            .find(|f| f.key == key)
            .ok_or_else(|| AppError::bad_request("Unknown plugin setting."))?;
        if !field.accepts(value) {
            return Err(AppError::bad_request("Invalid plugin setting."));
        }
    }
    let settings = resolved_settings(&fields, Some(&input.values));
    let mut tx = auth.begin_authorized(&state.pool).await?;
    sqlx::query(
        "INSERT INTO plugin_installs (workspace_id, user_id, plugin_id, enabled, settings) VALUES ($1, $2, $3, $4, $5) ON CONFLICT (workspace_id, user_id, plugin_id) DO UPDATE SET enabled = excluded.enabled, settings = excluded.settings, updated_at = now()",
    )
    .bind(auth.workspace_id)
    .bind(auth.user_id)
    .bind(&id)
    .bind(input.enabled)
    .bind(Value::Object(settings.clone()))
    .execute(&mut *tx)
    .await?;
    tx.commit().await?;
    let install = Install {
        enabled: input.enabled,
        settings,
    };
    let mut activity = activity(&state, &auth).await?;
    Ok(Json(info(
        plugin,
        Some(&install),
        activity.remove(&id).unwrap_or_default(),
    )))
}

// MARK: Messages

#[derive(Deserialize)]
struct DayQuery {
    /// The user's local date. The server doesn't know their time zone, and
    /// "due tomorrow" must mean their tomorrow.
    today: Option<NaiveDate>,
}

fn today(requested: Option<NaiveDate>) -> NaiveDate {
    let utc = Utc::now().date_naive();
    requested
        .filter(|d| (*d - utc).num_days().abs() <= 1)
        .unwrap_or(utc)
}

/// Plugins read mail like assistants do: accounts hidden from assistants
/// stay hidden from plugins too.
fn plugin_auth(auth: &AuthContext) -> AuthContext {
    AuthContext {
        assistant: true,
        ..auth.clone()
    }
}

#[derive(Serialize)]
struct PluginCard {
    plugin_id: &'static str,
    plugin_name: &'static str,
    icon: &'static str,
    tint: &'static str,
    card: Card,
}

#[derive(Serialize)]
struct PluginAction {
    plugin_id: &'static str,
    #[serde(flatten)]
    action: MessageAction,
}

#[derive(Serialize)]
struct MessagePlugins {
    schema: u32,
    cards: Vec<PluginCard>,
    actions: Vec<PluginAction>,
}

async fn message_plugins(
    auth: AuthContext,
    State(state): State<AppState>,
    Path(id): Path<Uuid>,
    Query(day): Query<DayQuery>,
) -> Result<Json<MessagePlugins>, AppError> {
    let installs = installs(&state, &auth).await?;
    let enabled: Vec<_> = registry()
        .iter()
        .filter_map(|p| {
            let manifest = p.manifest();
            installs.get(manifest.id).filter(|i| i.enabled).map(|i| {
                (
                    *p,
                    manifest,
                    resolved_settings(&p.manifest().settings, Some(&i.settings)),
                )
            })
        })
        .collect();
    let mut result = MessagePlugins {
        schema: card::SCHEMA_VERSION,
        cards: Vec::new(),
        actions: Vec::new(),
    };
    if enabled.is_empty() {
        return Ok(Json(result));
    }
    let message = match mail::cached_message(&state, &plugin_auth(&auth), id).await {
        Ok(message) => message,
        Err(error) if error.status == axum::http::StatusCode::NOT_FOUND => return Ok(Json(result)),
        Err(error) => return Err(error),
    };
    let text = detect::MailText::new(&message);
    let today = today(day.today);
    for (plugin, manifest, settings) in &enabled {
        let context = Context {
            message: &message,
            text: &text,
            settings,
            today,
        };
        if let Some(card) = plugin.banner(&context) {
            result.cards.push(PluginCard {
                plugin_id: manifest.id,
                plugin_name: manifest.name,
                icon: manifest.icon,
                tint: manifest.tint,
                card,
            });
        }
        result.actions.extend(
            plugin
                .actions(&context)
                .into_iter()
                .map(|action| PluginAction {
                    plugin_id: manifest.id,
                    action,
                }),
        );
    }
    Ok(Json(result))
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct ToolInput {
    message_id: Uuid,
    #[serde(default)]
    args: Value,
    today: Option<NaiveDate>,
}

async fn call_tool(
    auth: AuthContext,
    State(state): State<AppState>,
    Path((id, tool)): Path<(String, String)>,
    Json(input): Json<ToolInput>,
) -> Result<Json<ToolResult>, AppError> {
    let plugin = find(&id).ok_or_else(AppError::not_found)?;
    if tool.is_empty() || tool.len() > 64 {
        return Err(AppError::not_found());
    }
    state
        .auth
        .rate_limit("plugin_tool", &auth.user_id.to_string(), 120)
        .await?;
    let installs = installs(&state, &auth).await?;
    let install = installs
        .get(id.as_str())
        .filter(|i| i.enabled)
        .ok_or_else(|| AppError::conflict("Turn this plugin on in Settings → Plugins first."))?;
    let settings = resolved_settings(&plugin.manifest().settings, Some(&install.settings));
    let message = mail::cached_message(&state, &plugin_auth(&auth), input.message_id).await?;
    let text = detect::MailText::new(&message);
    let context = Context {
        message: &message,
        text: &text,
        settings: &settings,
        today: today(input.today),
    };
    let outcome = plugin.call(&tool, &context, &input.args);
    record(&state, &auth, &id, &tool, outcome.is_ok()).await;
    match outcome {
        Ok(result) => Ok(Json(result)),
        Err(ToolError::UnknownTool) => Err(AppError::not_found()),
        Err(ToolError::InvalidArguments(message) | ToolError::NotApplicable(message)) => {
            Err(AppError::bad_request(message))
        }
    }
}

/// Best effort: a failed audit write never fails the user's action.
async fn record(state: &AppState, auth: &AuthContext, plugin: &str, tool: &str, succeeded: bool) {
    let result: Result<(), AppError> = async {
        let mut tx = auth.begin(&state.pool).await?;
        sqlx::query(
            "INSERT INTO plugin_activity (workspace_id, user_id, plugin_id, tool, succeeded) VALUES ($1, $2, $3, $4, $5)",
        )
        .bind(auth.workspace_id)
        .bind(auth.user_id)
        .bind(plugin)
        .bind(tool)
        .bind(succeeded)
        .execute(&mut *tx)
        .await?;
        sqlx::query("DELETE FROM plugin_activity WHERE at < now() - interval '7 days'")
            .execute(&mut *tx)
            .await?;
        tx.commit().await?;
        Ok(())
    }
    .await;
    if result.is_err() {
        tracing::warn!(plugin, tool, "plugin activity was not recorded");
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use card::{ActionKind, Effect};
    use postmere_providers::Message;
    use serde_json::json;

    fn message(subject: &str, text: &str, html: Option<&str>) -> Message {
        serde_json::from_value(json!({
            "id": Uuid::nil(), "account_id": Uuid::nil(),
            "provider_message_id": "m", "provider_thread_id": "t",
            "subject": subject, "from": {"name": "Acme Billing", "email": "billing@acme.test"},
            "to": [], "cc": [], "bcc": [], "text_body": text, "html_body": html,
            "preview": "", "sent_at": "2026-11-20T10:00:00Z", "is_read": false, "is_starred": false,
            "mailbox": "inbox", "provider_labels": [], "attachments": [],
            "list_unsubscribe": [], "list_unsubscribe_post": []
        }))
        .unwrap()
    }

    fn run(
        plugin: &dyn Plugin,
        message: &Message,
        settings: Map<String, Value>,
    ) -> (Option<Card>, Vec<MessageAction>) {
        let text = detect::MailText::new(message);
        let context = Context {
            message,
            text: &text,
            settings: &settings,
            today: NaiveDate::from_ymd_opt(2026, 11, 21).unwrap(),
        };
        (plugin.banner(&context), plugin.actions(&context))
    }

    #[test]
    fn package_banner_tracks_the_shipment() {
        let mail = message(
            "Out for delivery: your order",
            "UPS tracking 1Z999AA10123456784. Arriving today by 7 PM.",
            None,
        );
        let (card, actions) = run(&packages::Packages, &mail, Map::new());
        let card = card.unwrap();
        assert_eq!(card.title, "Out for delivery");
        assert_eq!(card.brand, Some("ups"));
        assert_eq!(
            card.subtitle.as_deref(),
            Some("UPS · Arriving today by 7 PM")
        );
        assert!(
            matches!(&card.actions[0].kind, ActionKind::Open(url) if url.ends_with("1Z999AA10123456784"))
        );
        assert_eq!(actions[0].tool, "track_package");

        let delivered = message("Delivered: your order", "Tracking 1Z999AA10123456784", None);
        let hide = Map::from_iter([("show_delivered".into(), json!(false))]);
        assert!(run(&packages::Packages, &delivered, hide).0.is_none());
        assert!(
            run(
                &packages::Packages,
                &message("Hello", "1Z999AA10123456784", None),
                Map::new()
            )
            .0
            .is_none()
        );
    }

    #[test]
    fn bill_banner_shows_amount_due_date_and_reminder() {
        let html = r#"<p>Invoice #INV-2041</p><p>Amount due: $120.00</p><p>Due date: December 5, 2026</p><a href="https://acme.test/pay/2041">Pay now</a>"#;
        let mail = message("Your Acme invoice", "", Some(html));
        let settings = resolved_settings(&bills::Bills.manifest().settings, None);
        let (card, actions) = run(&bills::Bills, &mail, settings.clone());
        let card = card.unwrap();
        assert_eq!(card.title, "$120.00 due Dec 5");
        assert_eq!(card.brand, None);
        assert_eq!(card.subtitle.as_deref(), Some("Acme Billing"));
        assert!(
            matches!(&card.actions[0].kind, ActionKind::Open(url) if url == "https://acme.test/pay/2041")
        );
        assert_eq!(card.actions[1].title, "Remind Me on Dec 2");
        assert_eq!(
            actions.iter().map(|a| a.tool).collect::<Vec<_>>(),
            ["remind_bill", "pay_bill"]
        );

        let text = detect::MailText::new(&mail);
        let context = Context {
            message: &mail,
            text: &text,
            settings: &settings,
            today: NaiveDate::from_ymd_opt(2026, 11, 21).unwrap(),
        };
        let result = bills::Bills
            .call("remind_bill", &context, &json!({"date": "2026-12-02"}))
            .unwrap();
        assert_eq!(
            result.effects,
            vec![Effect::Remind {
                date: "2026-12-02".into()
            }]
        );
        assert_eq!(result.toast.as_deref(), Some("Reminder set for Wed, Dec 2"));
        assert!(
            bills::Bills
                .call("remind_bill", &context, &json!({"date": "2026-11-01"}))
                .is_err()
        );
        assert_eq!(
            bills::Bills
                .call("nope", &context, &Value::Null)
                .unwrap_err(),
            ToolError::UnknownTool
        );
    }

    #[test]
    fn paid_and_overdue_bills_read_differently() {
        let paid = message(
            "Payment received",
            "Thank you for your payment. Amount paid: £42.10",
            None,
        );
        assert_eq!(
            run(&bills::Bills, &paid, Map::new()).0.unwrap().title,
            "£42.10 paid"
        );
        let late = message(
            "Reminder: invoice overdue",
            "Balance due: $80 was due Nov 10",
            None,
        );
        let (card, actions) = run(&bills::Bills, &late, Map::new());
        assert_eq!(card.unwrap().title, "$80 overdue");
        assert!(actions.is_empty());
    }

    #[test]
    fn settings_fall_back_to_defaults() {
        let fields = bills::Bills.manifest().settings;
        let saved = Map::from_iter([("remind_days_before".into(), json!("99"))]);
        assert_eq!(
            resolved_settings(&fields, Some(&saved))["remind_days_before"],
            json!("3")
        );
        let ids: Vec<_> = registry().iter().map(|p| p.manifest().id).collect();
        assert_eq!(
            ids,
            [
                "postmere.incidents",
                "postmere.github",
                "postmere.sentry",
                "postmere.deploys",
                "postmere.issues",
                "postmere.packages",
                "postmere.bills"
            ]
        );
    }
}
