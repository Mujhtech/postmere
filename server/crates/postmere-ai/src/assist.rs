//! Smaller assistance calls that return a fixed JSON shape: one-tap replies,
//! proofreading, learning the user's writing style, plain-English search,
//! attachment summaries, labels described in words, and action items.
//!
//! Each call reuses the same guardrails as the rest of this crate: AI must be
//! enabled by the user, message IDs are resolved inside the user's own scope,
//! the model gets no tools, and its output is checked before it is returned.

use std::collections::HashSet;

use axum::{
    Json, Router,
    extract::State,
    routing::post,
};
use chrono::{DateTime, Utc};
use serde::{Deserialize, Serialize};
use serde_json::{Value, json};
use sqlx::Row;
use uuid::Uuid;

use postmere_core::{AppState, auth::AuthContext, error::AppError};

use crate::{
    AiFailure, RULES, Source, authorize, bound_sources, call_model, model_request, response_text,
    selected_sources, source_from_row,
};

pub fn router() -> Router<AppState> {
    Router::new()
        .route("/v1/ai/quick-replies", post(quick_replies))
        .route("/v1/ai/proofread", post(proofread))
        .route("/v1/ai/style/learn", post(learn_style))
        .route("/v1/ai/search", post(search))
        .route("/v1/ai/document", post(document))
        .route("/v1/ai/classify", post(classify))
        .route("/v1/ai/tasks", post(tasks))
}

/// One model call whose output must match `schema` exactly.
async fn structured(
    state: &AppState,
    name: &str,
    task: Value,
    sources: &[Source],
    schema: Value,
    max_output_tokens: u32,
) -> Result<Value, AppError> {
    let request = json!({"model":state.config.ai_model,"store":false,"max_output_tokens":max_output_tokens,
        "input":[{"role":"developer","content":RULES},{"role":"user","content":json!({
            "task":task,"current_date":Utc::now().date_naive().to_string(),"current_time":Utc::now().to_rfc3339(),
            "sources":sources}).to_string()}],
        "text":{"format":{"type":"json_schema","name":name,"strict":true,"schema":schema}}});
    let value = call_model(model_request(state)?, &request).await?;
    let text = response_text(&value)?;
    serde_json::from_str(&text).map_err(|_| {
        tracing::warn!(event = "ai_output_rejected", mode = name, reason = "decode");
        AiFailure::InvalidOutput.error()
    })
}

fn object(required: &[&str], properties: Value) -> Value {
    json!({"type":"object","additionalProperties":false,"required":required,"properties":properties})
}

fn invalid(mode: &str) -> AppError {
    tracing::warn!(event = "ai_output_rejected", mode, reason = "bounds");
    AiFailure::InvalidOutput.error()
}

fn trimmed(value: &str, limit: usize) -> String {
    value.trim().chars().take(limit).collect()
}

// MARK: One-tap replies

#[derive(Deserialize)]
pub struct MessagesInput {
    pub message_ids: Vec<Uuid>,
}

#[derive(Deserialize, Serialize)]
pub struct QuickReply {
    pub label: String,
    pub text: String,
}

#[derive(Serialize)]
pub struct QuickReplies {
    pub replies: Vec<QuickReply>,
}

async fn quick_replies(
    State(state): State<AppState>,
    auth: AuthContext,
    Json(input): Json<MessagesInput>,
) -> Result<Json<QuickReplies>, AppError> {
    let style = authorize(&state, &auth).await?;
    let sources = selected_sources(&state, &auth, &input.message_ids, false).await?;
    let task = json!({"instruction":"Suggest three short, clearly different replies the user could send to the newest message in this conversation, written as the user. Cover different intents where they make sense, such as agreeing, asking a question, or politely declining. Each label is two to four words naming the intent. Each text is one to three sentences of body text only: no greeting line is required, no subject, no signature, and no facts, dates or commitments that are not in the conversation. When the newest message needs no reply, still offer brief, natural acknowledgements.","writing_style":style});
    let schema = object(&["replies"], json!({"replies":{"type":"array","minItems":1,"maxItems":3,
        "items":object(&["label","text"], json!({"label":{"type":"string"},"text":{"type":"string"}}))}}));
    let output = structured(&state, "quick_replies", task, &sources, schema, 1200).await?;
    let replies: Vec<QuickReply> = serde_json::from_value(output["replies"].clone())
        .map_err(|_| invalid("quick_replies"))?;
    let replies: Vec<_> = replies
        .into_iter()
        .map(|reply| QuickReply { label: trimmed(&reply.label, 40), text: trimmed(&reply.text, 600) })
        .filter(|reply| !reply.label.is_empty() && !reply.text.is_empty())
        .take(3)
        .collect();
    if replies.is_empty() {
        return Err(invalid("quick_replies"));
    }
    Ok(Json(QuickReplies { replies }))
}

// MARK: Proofreading

#[derive(Deserialize)]
pub struct ProofreadInput {
    pub draft_text: String,
    #[serde(default)]
    pub subject: String,
    #[serde(default)]
    pub recipients: Vec<String>,
    #[serde(default)]
    pub message_ids: Vec<Uuid>,
}

#[derive(Deserialize, Serialize)]
pub struct ProofreadIssue {
    pub kind: String,
    pub excerpt: String,
    pub suggestion: String,
    pub explanation: String,
}

#[derive(Serialize)]
pub struct Proofread {
    pub issues: Vec<ProofreadIssue>,
}

const ISSUE_KINDS: [&str; 6] = ["spelling", "grammar", "name", "date", "clarity", "tone"];

async fn proofread(
    State(state): State<AppState>,
    auth: AuthContext,
    Json(input): Json<ProofreadInput>,
) -> Result<Json<Proofread>, AppError> {
    authorize(&state, &auth).await?;
    if input.draft_text.trim().is_empty() || input.draft_text.len() > 32_000 || input.subject.len() > 1_000
        || input.recipients.len() > 50
    {
        return Err(AppError::bad_request("The draft is empty or too long to check."));
    }
    let sources = selected_sources(&state, &auth, &input.message_ids, true).await?;
    let task = json!({"instruction":"Proofread the user's draft before it is sent. Report only real problems, most important first, at most eight: spelling and grammar mistakes; a name that does not match the recipients or the conversation; a date or weekday that is inconsistent or contradicts the conversation; a sentence that is genuinely unclear; tone that is likely to read as rude. Do not rewrite for style and do not report quoted text below the user's message. excerpt must be copied exactly from the draft and be as short as possible; suggestion is its corrected replacement; explanation is one short sentence. Return no issues when the draft is fine.",
        "draft":input.draft_text,"subject":input.subject,"recipients":input.recipients});
    let schema = object(&["issues"], json!({"issues":{"type":"array","maxItems":8,"items":object(
        &["kind","excerpt","suggestion","explanation"], json!({"kind":{"type":"string","enum":ISSUE_KINDS},
        "excerpt":{"type":"string"},"suggestion":{"type":"string"},"explanation":{"type":"string"}}))}}));
    let output = structured(&state, "proofread", task, &sources, schema, 2000).await?;
    let issues: Vec<ProofreadIssue> = serde_json::from_value(output["issues"].clone())
        .map_err(|_| invalid("proofread"))?;
    // An issue the person can't find in their own draft is no use to them.
    let issues = issues
        .into_iter()
        .filter(|issue| {
            ISSUE_KINDS.contains(&issue.kind.as_str()) && !issue.excerpt.trim().is_empty()
                && input.draft_text.contains(issue.excerpt.as_str()) && issue.excerpt != issue.suggestion
        })
        .map(|issue| ProofreadIssue {
            kind: issue.kind,
            excerpt: issue.excerpt.chars().take(400).collect(),
            suggestion: issue.suggestion.chars().take(400).collect(),
            explanation: trimmed(&issue.explanation, 300),
        })
        .collect();
    Ok(Json(Proofread { issues }))
}

// MARK: Writing style

#[derive(Serialize)]
pub struct LearnedStyle {
    pub learned_style: String,
    pub learned_at: DateTime<Utc>,
    pub messages_read: usize,
}

/// The user's own words: text above the first quoted reply or forwarded block.
pub(crate) fn own_words(text: &str) -> String {
    let mut kept = Vec::new();
    for line in text.lines() {
        let trimmed = line.trim();
        let quote_header = (trimmed.starts_with("On ") && trimmed.ends_with("wrote:"))
            || trimmed.starts_with("-----Original Message-----")
            || trimmed.starts_with("---------- Forwarded message")
            || trimmed.starts_with("From: ");
        if quote_header || trimmed.starts_with('>') {
            break;
        }
        kept.push(line);
    }
    kept.join("\n").trim().chars().take(1_500).collect()
}

async fn learn_style(
    State(state): State<AppState>,
    auth: AuthContext,
) -> Result<Json<LearnedStyle>, AppError> {
    authorize(&state, &auth).await?;
    let mut tx = auth.begin(&state.pool).await?;
    let rows = sqlx::query("SELECT m.id,m.account_id,m.sent_at,m.normalized,m.label_text FROM mail_messages m JOIN provider_accounts a ON a.id=m.account_id AND a.workspace_id=m.workspace_id AND a.user_id=m.user_id WHERE m.deleted_at IS NULL AND a.disabled_at IS NULL AND a.status='connected' AND lower(m.normalized->'from'->>'email')=lower(a.email) AND length(coalesce(m.normalized->>'text_body',''))>40 ORDER BY m.sent_at DESC LIMIT 40")
        .fetch_all(&mut *tx)
        .await?;
    tx.commit().await?;
    let samples: Vec<Source> = rows
        .iter()
        .map(source_from_row)
        .filter_map(|mut source| {
            source.text = own_words(&source.text);
            (source.text.chars().count() >= 30).then_some(source)
        })
        .take(25)
        .collect();
    if samples.len() < 3 {
        return Err(AppError::bad_request(
            "Postmere needs a few more messages you’ve sent before it can learn your style.",
        ));
    }
    let messages_read = samples.len();
    let samples = bound_sources(samples);
    let task = json!({"instruction":"These are messages the user wrote. Describe how they write so drafts can match it: usual greeting and sign-off, typical length, formality, sentence style, punctuation and emoji habits, and any recurring phrases. Write it as concise guidance in the second person (for example, \"Open with 'Hi' and the first name\"), at most 900 characters. Describe style only: never include names, addresses, phone numbers, dates, or any content from the messages."});
    let schema = object(&["style_guide"], json!({"style_guide":{"type":"string"}}));
    let output = structured(&state, "writing_style", task, &samples, schema, 1500).await?;
    let learned: String = output["style_guide"].as_str().map(|s| trimmed(s, 1_000)).unwrap_or_default();
    if learned.is_empty() {
        return Err(invalid("writing_style"));
    }
    let mut tx = auth.begin(&state.pool).await?;
    let learned_at: DateTime<Utc> = sqlx::query("INSERT INTO ai_preferences(workspace_id,user_id,enabled,learned_style,learned_at) VALUES($1,$2,true,$3,now()) ON CONFLICT(workspace_id,user_id) DO UPDATE SET learned_style=EXCLUDED.learned_style,learned_at=EXCLUDED.learned_at,updated_at=now() RETURNING learned_at")
        .bind(auth.workspace_id).bind(auth.user_id).bind(&learned)
        .fetch_one(&mut *tx).await?.get("learned_at");
    tx.commit().await?;
    Ok(Json(LearnedStyle { learned_style: learned, learned_at, messages_read }))
}

// MARK: Plain-English search

#[derive(Deserialize)]
pub struct SearchInput {
    pub request: String,
}

#[derive(Deserialize, Serialize)]
pub struct SearchTranslation {
    pub query: String,
    pub explanation: String,
}

const SEARCH_SYNTAX: &str = "Postmere search syntax. Terms separated by spaces must all match; OR between terms means either; a leading minus excludes a term; double quotes make a phrase; parentheses group. Fields: from: to: cc: bcc: subject: body: filename: domain: account: label: category: before:YYYY-MM-DD after:YYYY-MM-DD date:YYYY-MM-DD in:inbox|archive|sent|drafts|trash|spam|needsreply|starred has:attachment has:unsubscribe filetype:pdf|image|doc|sheet|slides|zip is:unread|read|starred|vip|needsreply|needsyou|subscription|purchase|outgoing|incoming|draft|snoozed|followup. Values with spaces need quotes, for example subject:\"design review\". Words without a field search everything.";

async fn search(
    State(state): State<AppState>,
    auth: AuthContext,
    Json(input): Json<SearchInput>,
) -> Result<Json<SearchTranslation>, AppError> {
    authorize(&state, &auth).await?;
    let request = input.request.trim();
    if request.is_empty() || request.chars().count() > 500 {
        return Err(AppError::bad_request("Describe what you’re looking for in 500 characters or fewer."));
    }
    let task = json!({"instruction":"Translate the user's description of the mail they want into one search query in the syntax below. Use fields wherever the description names a person, company, date, kind of file, mailbox or state; keep other meaningful words as plain terms. Resolve relative dates against current_date. Use only fields from the syntax. explanation restates the search in one short plain sentence.","syntax":SEARCH_SYNTAX,"description":request});
    let schema = object(&["query","explanation"], json!({"query":{"type":"string"},"explanation":{"type":"string"}}));
    let output = structured(&state, "search_query", task, &[], schema, 800).await?;
    let translation: SearchTranslation = serde_json::from_value(output).map_err(|_| invalid("search_query"))?;
    let query = trimmed(&translation.query, 500);
    if query.is_empty() {
        return Err(invalid("search_query"));
    }
    Ok(Json(SearchTranslation { query, explanation: trimmed(&translation.explanation, 300) }))
}

// MARK: Attachment summaries

#[derive(Deserialize)]
pub struct DocumentInput {
    pub message_id: Uuid,
    pub filename: String,
    pub text: String,
}

#[derive(Deserialize, Serialize)]
pub struct DocumentPoint {
    pub kind: String,
    pub text: String,
}

#[derive(Serialize)]
pub struct DocumentSummary {
    pub summary: String,
    pub points: Vec<DocumentPoint>,
}

const POINT_KINDS: [&str; 5] = ["fact", "date", "amount", "action", "party"];

async fn document(
    State(state): State<AppState>,
    auth: AuthContext,
    Json(input): Json<DocumentInput>,
) -> Result<Json<DocumentSummary>, AppError> {
    authorize(&state, &auth).await?;
    if input.text.trim().is_empty() || input.text.chars().count() > 60_000 || input.filename.chars().count() > 255 {
        return Err(AppError::bad_request("This attachment has no readable text, or too much of it."));
    }
    // The attachment must belong to a message this user can read.
    let mut sources = selected_sources(&state, &auth, &[input.message_id], false).await?;
    for source in &mut sources {
        source.text = source.text.chars().take(2_000).collect();
    }
    let task = json!({"instruction":"Summarize the attached document for the user. summary is two to four plain sentences on what it is and what matters in it. points lists at most eight key details, most important first: parties involved, amounts, dates and deadlines, obligations or actions the user must take, and notable facts. Use only what the document says; say when something important is unclear or missing. The email in sources is context only.","filename":input.filename,"document_text":input.text});
    let schema = object(&["summary","points"], json!({"summary":{"type":"string"},"points":{"type":"array","maxItems":8,
        "items":object(&["kind","text"], json!({"kind":{"type":"string","enum":POINT_KINDS},"text":{"type":"string"}}))}}));
    let output = structured(&state, "document_summary", task, &sources, schema, 2500).await?;
    let summary = output["summary"].as_str().map(|s| trimmed(s, 1_500)).unwrap_or_default();
    let points: Vec<DocumentPoint> = serde_json::from_value(output["points"].clone()).map_err(|_| invalid("document_summary"))?;
    if summary.is_empty() {
        return Err(invalid("document_summary"));
    }
    let points = points
        .into_iter()
        .filter(|point| POINT_KINDS.contains(&point.kind.as_str()) && !point.text.trim().is_empty())
        .map(|point| DocumentPoint { kind: point.kind, text: trimmed(&point.text, 400) })
        .collect();
    Ok(Json(DocumentSummary { summary, points }))
}

// MARK: Labels described in words

#[derive(Deserialize)]
pub struct DescribedLabel {
    pub id: String,
    pub name: String,
    pub description: String,
}

#[derive(Deserialize)]
pub struct ClassifyInput {
    pub labels: Vec<DescribedLabel>,
    pub message_ids: Vec<Uuid>,
}

#[derive(Deserialize, Serialize)]
pub struct Classification {
    pub message_id: Uuid,
    pub label_ids: Vec<String>,
}

#[derive(Serialize)]
pub struct Classifications {
    pub matches: Vec<Classification>,
}

async fn classify(
    State(state): State<AppState>,
    auth: AuthContext,
    Json(input): Json<ClassifyInput>,
) -> Result<Json<Classifications>, AppError> {
    authorize(&state, &auth).await?;
    let ids: HashSet<&str> = input.labels.iter().map(|label| label.id.as_str()).collect();
    if input.labels.is_empty() || input.labels.len() > 20 || ids.len() != input.labels.len()
        || input.labels.iter().any(|label| label.id.is_empty() || label.id.len() > 100
            || label.name.chars().count() > 100 || label.description.chars().count() > 400)
        || input.message_ids.len() > 20
    {
        return Err(AppError::bad_request("Describe between one and 20 labels and classify up to 20 messages at a time."));
    }
    let mut sources = selected_sources(&state, &auth, &input.message_ids, false).await?;
    // Deciding a label needs the gist of a message, not all of it.
    for source in &mut sources {
        source.text = source.text.chars().take(3_000).collect();
    }
    let labels: Vec<Value> = input.labels.iter()
        .map(|label| json!({"id":label.id,"name":label.name,"description":label.description}))
        .collect();
    let message_ids: Vec<String> = sources.iter().map(|source| source.id.to_string()).collect();
    let label_ids: Vec<&str> = ids.iter().copied().collect();
    let task = json!({"instruction":"For each message in sources, decide which of the user's labels it clearly belongs to, judging by each label's description. A message may match several labels or none. Only assign a label when the message plainly fits its description; when unsure, leave it out. Return one entry per message.","labels":labels});
    let schema = object(&["matches"], json!({"matches":{"type":"array","items":object(&["message_id","label_ids"], json!({
        "message_id":{"type":"string","enum":message_ids},"label_ids":{"type":"array","items":{"type":"string","enum":label_ids}}}))}}));
    let output = structured(&state, "classify", task, &sources, schema, 3000).await?;
    let matches: Vec<Classification> = serde_json::from_value(output["matches"].clone()).map_err(|_| invalid("classify"))?;
    let allowed: HashSet<Uuid> = sources.iter().map(|source| source.id).collect();
    let mut seen = HashSet::new();
    let matches = matches
        .into_iter()
        .filter(|entry| allowed.contains(&entry.message_id) && seen.insert(entry.message_id))
        .map(|entry| Classification {
            message_id: entry.message_id,
            label_ids: entry.label_ids.into_iter().filter(|id| ids.contains(id.as_str()))
                .collect::<HashSet<_>>().into_iter().collect(),
        })
        .collect();
    Ok(Json(Classifications { matches }))
}

// MARK: Action items

#[derive(Deserialize, Serialize)]
pub struct ActionItem {
    pub title: String,
    pub due_at: Option<DateTime<Utc>>,
    pub source_id: Uuid,
}

#[derive(Serialize)]
pub struct ActionItems {
    pub tasks: Vec<ActionItem>,
}

async fn tasks(
    State(state): State<AppState>,
    auth: AuthContext,
    Json(input): Json<MessagesInput>,
) -> Result<Json<ActionItems>, AppError> {
    authorize(&state, &auth).await?;
    let sources = selected_sources(&state, &auth, &input.message_ids, false).await?;
    let ids: Vec<String> = sources.iter().map(|source| source.id.to_string()).collect();
    let task = json!({"instruction":"List what the user personally has to do because of this conversation, at most six, most urgent first. Each title is a short imperative to-do (for example, \"Send the signed lease to Ada\"). Set due_at only when the mail states or clearly implies a deadline, resolved against current_date in UTC; otherwise null. source_id names the message the task comes from. Leave out things other people must do, things already done, and marketing calls to action. Return no tasks when there are none."});
    let schema = object(&["tasks"], json!({"tasks":{"type":"array","maxItems":6,"items":object(&["title","due_at","source_id"], json!({
        "title":{"type":"string"},"due_at":{"anyOf":[{"type":"string","format":"date-time"},{"type":"null"}]},
        "source_id":{"type":"string","enum":ids}}))}}));
    let output = structured(&state, "action_items", task, &sources, schema, 1500).await?;
    let items: Vec<ActionItem> = serde_json::from_value(output["tasks"].clone()).map_err(|_| invalid("action_items"))?;
    let allowed: HashSet<Uuid> = sources.iter().map(|source| source.id).collect();
    let tasks = items
        .into_iter()
        .filter(|item| allowed.contains(&item.source_id) && !item.title.trim().is_empty())
        .map(|item| ActionItem { title: trimmed(&item.title, 200), ..item })
        .collect();
    Ok(Json(ActionItems { tasks }))
}

#[cfg(test)]
mod tests {
    use super::own_words;

    #[test]
    fn own_words_stop_at_quoted_history() {
        let text = "Hi Ada,\n\nThursday works for me.\n\nThanks,\nMu\n\nOn Mon, 3 Nov 2026, Ada wrote:\n> Does Thursday work?";
        assert_eq!(own_words(text), "Hi Ada,\n\nThursday works for me.\n\nThanks,\nMu");
        assert_eq!(own_words("> only a quote"), "");
        assert_eq!(own_words("Short note\n-----Original Message-----\nFrom: x"), "Short note");
    }
}
