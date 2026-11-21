//! Streams the leading prose of a summary, suggestion or question response.
//! Answers to questions first list the retrieved messages they draw on.
//! Suggested actions are sent as each one completes and passes the per-item
//! checks; other details and citations wait for the completed response. The
//! final event always carries the result validated as a whole.
use super::{
    API_URL, AiFailure, AppError, AppState, Generated, Item, OutputMode, Source, parse_response,
    provider_response_failure, provider_status_error, provider_transport_error, result,
    withhold_invalid_items,
};
use axum::{
    http::{HeaderValue, header},
    response::{
        IntoResponse, Response,
        sse::{Event, KeepAlive, Sse},
    },
};
use futures_util::{StreamExt, TryStreamExt};
use serde_json::{Value, json};
use std::{convert::Infallible, io, time::Duration};
use tokio::io::{AsyncBufRead, AsyncBufReadExt, AsyncReadExt, BufReader, Lines};
use tokio_util::io::StreamReader;

const STREAM_LIMIT: u64 = 4 * 1024 * 1024;
const IDLE_LIMIT: Duration = Duration::from_secs(60);

pub(super) async fn generate(
    state: AppState,
    sources: Vec<Source>,
    request: Value,
    mode: OutputMode,
    announce_sources: bool,
) -> Result<Response, AppError> {
    let options = StreamOptions {
        mode,
        announce_sources,
    };
    let key = state
        .config
        .ai_api_key
        .as_deref()
        .ok_or_else(|| AiFailure::NotConfigured.error())?;
    request_stream(
        &state.http,
        API_URL,
        key,
        state.config.ai_model.clone(),
        sources,
        request,
        options,
    )
    .await
}

#[derive(Clone, Copy)]
struct StreamOptions {
    mode: OutputMode,
    /// Lists the retrieved messages before the answer (questions only).
    announce_sources: bool,
}

async fn request_stream(
    client: &reqwest::Client,
    url: &str,
    key: &str,
    model: String,
    sources: Vec<Source>,
    mut request: Value,
    StreamOptions {
        mode,
        announce_sources,
    }: StreamOptions,
) -> Result<Response, AppError> {
    request["stream"] = true.into();
    let call = client
        .post(url)
        .bearer_auth(key)
        .header(header::ACCEPT, "text/event-stream")
        .json(&request)
        .timeout(Duration::from_secs(180));
    let response = tokio::time::timeout(Duration::from_secs(90), call.send())
        .await
        .map_err(|_| AiFailure::Timeout.error())?
        .map_err(provider_transport_error)?;
    if !response.status().is_success() {
        return Err(provider_status_error(response.status()));
    }

    // The downstream response owns the upstream body. Dropping the reader
    // cancels generation locally without leaving a detached forwarding task.
    let reader = StreamReader::new(response.bytes_stream().map_err(io::Error::other));
    let mut lines = BufReader::new(reader.take(STREAM_LIMIT)).lines();
    // Retrieved messages are announced before generation starts; like the
    // final result, they carry citation metadata only.
    let retrieved: Option<Value> = announce_sources.then(|| {
        sources
            .iter()
            .map(|source| {
                json!({"id":source.id,"account_id":source.account_id,"subject":source.subject,
                "sender":source.sender,"sent_at":source.sent_at})
            })
            .collect()
    });
    let events = async_stream::try_stream! {
        if let Some(retrieved) = retrieved {
            yield Event::default().data(json!({"type":"sources","sources":retrieved}).to_string());
        }
        let mut prose = SummaryProse::default();
        let mut items = ItemScanner::default();
        let mut sent_items = 0;
        let mut text_bytes = 0;
        loop {
            let event = next_event(&mut lines).await?;
            match event["type"].as_str() {
                Some("response.output_text.delta") => {
                    let delta = event["delta"].as_str().ok_or_else(|| AiFailure::InvalidOutput.error())?;
                    let text = prose.push(delta)?;
                    text_bytes += text.len();
                    if text_bytes > 32_000 { Err(AiFailure::InvalidOutput.error())?; }
                    if !text.is_empty() {
                        yield Event::default().data(json!({"type":"delta", "text":text}).to_string());
                    }
                    if mode == OutputMode::Suggestions {
                        for raw in items.push(delta) {
                            // Items that fail validation are withheld here and from
                            // the final result, using the same rule.
                            let Ok(item) = serde_json::from_str::<Item>(&raw) else { continue };
                            let mut single = Generated { text: String::new(), items: vec![item] };
                            withhold_invalid_items(&mut single, &sources, mode);
                            if sent_items >= 20 || single.items.is_empty() { continue; }
                            sent_items += 1;
                            yield Event::default().data(json!({"type":"item", "item":single.items[0]}).to_string());
                        }
                    }
                }
                Some("response.completed" | "response.incomplete" | "response.failed") => {
                    let generated = parse_response(&event["response"], &sources, mode)?;
                    let summary = result(&model, generated, sources);
                    yield Event::default().data(json!({"type":"done","result":summary}).to_string());
                    break;
                }
                Some("response.refusal.delta" | "response.refusal.done") => Err(AiFailure::Refused.error())?,
                Some("error") => Err(provider_response_failure(&event))?,
                _ => {}
            }
        }
    };
    let events = events.map(|event: Result<Event, AppError>| {
        Ok::<_, Infallible>(event.unwrap_or_else(|err| {
            Event::default().data(json!({"type":"error", "code":err.code}).to_string())
        }))
    });
    let mut response = Sse::new(events)
        .keep_alive(KeepAlive::default())
        .into_response();
    response
        .headers_mut()
        .insert(header::CACHE_CONTROL, HeaderValue::from_static("no-store"));
    Ok(response)
}

async fn next_event<R: AsyncBufRead + Unpin>(lines: &mut Lines<R>) -> Result<Value, AppError> {
    let mut data = String::new();
    loop {
        let line = tokio::time::timeout(IDLE_LIMIT, lines.next_line())
            .await
            .map_err(|_| AiFailure::Timeout.error())?
            .map_err(|err| {
                if err
                    .get_ref()
                    .and_then(|e| e.downcast_ref::<reqwest::Error>())
                    .is_some_and(reqwest::Error::is_timeout)
                {
                    AiFailure::Timeout.error()
                } else {
                    AiFailure::Incomplete.error()
                }
            })?
            .ok_or_else(|| AiFailure::Incomplete.error())?;
        if line.is_empty() && !data.is_empty() {
            if data == "[DONE]" {
                return Err(AiFailure::Incomplete.error());
            }
            return serde_json::from_str(&data).map_err(|_| AiFailure::InvalidOutput.error());
        }
        if let Some(part) = line.strip_prefix("data:") {
            if !data.is_empty() {
                data.push('\n');
            }
            data.push_str(part.strip_prefix(' ').unwrap_or(part));
        }
    }
}

// Structured Outputs emits properties in schema order. If the provider uses
// a different order, wait for the full object instead of showing its markup.
enum SummaryProse {
    Prefix(String),
    Text(String),
    End,
}

impl Default for SummaryProse {
    fn default() -> Self {
        Self::Prefix(String::new())
    }
}

impl SummaryProse {
    fn push(&mut self, chunk: &str) -> Result<String, AppError> {
        match self {
            Self::Prefix(pending) => {
                pending.push_str(chunk);
                let mut tail = pending.as_str();
                for token in ["{", "\"text\"", ":", "\""] {
                    tail = tail.trim_start();
                    if let Some(rest) = tail.strip_prefix(token) {
                        tail = rest;
                    } else {
                        if !token.starts_with(tail) || pending.len() > 128 {
                            *self = Self::End;
                        }
                        return Ok(String::new());
                    }
                }
                *self = Self::Text(tail.to_owned());
            }
            Self::Text(pending) => pending.push_str(chunk),
            Self::End => return Ok(String::new()),
        }
        let Self::Text(pending) = self else {
            unreachable!()
        };
        let bytes = pending.as_bytes();
        // Decode complete JSON escapes together, retaining at most an unfinished
        // escape (including a UTF-16 surrogate pair) for the next model event.
        let mut i = 0;
        while i < bytes.len() {
            match bytes[i] {
                b'"' => break,
                b'\\' => {
                    let Some(&escaped) = bytes.get(i + 1) else {
                        break;
                    };
                    let mut length = if escaped == b'u' { 6 } else { 2 };
                    if length == 6
                        && bytes.get(i + 2..i + 6).is_some_and(|hex| {
                            hex[0].eq_ignore_ascii_case(&b'd')
                                && matches!(hex[1], b'8' | b'9' | b'A' | b'a' | b'B' | b'b')
                        })
                    {
                        length = 12;
                    }
                    if i + length > bytes.len() {
                        break;
                    }
                    i += length;
                }
                _ => i += 1,
            }
        }
        let complete = bytes.get(i) == Some(&b'"');
        let fragment = pending
            .get(..i)
            .ok_or_else(|| AiFailure::InvalidOutput.error())?;
        let text: String = serde_json::from_str(&format!("\"{fragment}\""))
            .map_err(|_| AiFailure::InvalidOutput.error())?;
        if complete {
            *self = Self::End
        } else {
            pending.drain(..i);
        }
        Ok(text)
    }
}

/// Finds each completed object in the response's `items` array. The root
/// object is depth 1, the array depth 2 and each item depth 3; `text` is a
/// string, so it never changes the depth.
#[derive(Default)]
struct ItemScanner {
    raw: String,
    depth: u32,
    in_string: bool,
    escaped: bool,
    start: Option<usize>,
}

impl ItemScanner {
    fn push(&mut self, chunk: &str) -> Vec<String> {
        let offset = self.raw.len();
        self.raw.push_str(chunk);
        let mut complete = vec![];
        for (index, byte) in chunk.bytes().enumerate() {
            let position = offset + index;
            if self.in_string {
                match byte {
                    _ if self.escaped => self.escaped = false,
                    b'\\' => self.escaped = true,
                    b'"' => self.in_string = false,
                    _ => {}
                }
                continue;
            }
            match byte {
                b'"' => self.in_string = true,
                b'{' | b'[' => {
                    self.depth += 1;
                    if byte == b'{' && self.depth == 3 {
                        self.start = Some(position);
                    }
                }
                b'}' | b']' => {
                    if byte == b'}'
                        && self.depth == 3
                        && let Some(start) = self.start.take()
                    {
                        complete.push(self.raw[start..=position].to_owned());
                    }
                    self.depth = self.depth.saturating_sub(1);
                }
                _ => {}
            }
        }
        // Text before the current item is no longer needed.
        let keep = self.start.unwrap_or(self.raw.len());
        self.raw.drain(..keep);
        if let Some(start) = &mut self.start {
            *start = 0;
        }
        complete
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use axum::{Json, Router, http::HeaderMap, routing::post};
    use chrono::Utc;
    use std::sync::{
        Arc,
        atomic::{AtomicUsize, Ordering},
    };
    use tokio::sync::Notify;
    use uuid::Uuid;

    #[test]
    fn streams_prose_across_every_character_boundary_and_omits_the_details() {
        let encoded =
            r#" { "text" : "Café \"Q\"\n\ud83d\ude42 \\ OK", "items":[{"text":"not prose"}]}"#;
        let mut prose = SummaryProse::default();
        let mut result = String::new();
        for c in encoded.chars() {
            result.push_str(&prose.push(&c.to_string()).unwrap());
        }
        assert_eq!(result, "Café \"Q\"\n🙂 \\ OK");
        assert!(
            SummaryProse::default()
                .push(r#"{"items":[{"text":"nested"}]}"#)
                .unwrap()
                .is_empty()
        );
    }

    #[test]
    fn finds_each_completed_item_across_chunk_boundaries() {
        let encoded = r#"{"text":"Has } and { and \"]\"","items":[{"kind":"suggestion","text":"Reply {soon}","source_ids":["a"]},{"text":"b","source_ids":[]}]}"#;
        let mut scanner = ItemScanner::default();
        let mut found = vec![];
        for c in encoded.chars() {
            found.extend(scanner.push(&c.to_string()));
        }
        assert_eq!(
            found,
            [
                r#"{"kind":"suggestion","text":"Reply {soon}","source_ids":["a"]}"#,
                r#"{"text":"b","source_ids":[]}"#
            ]
        );
    }

    #[tokio::test]
    async fn a_truncated_stream_is_an_error_even_after_text_arrives() {
        let mut lines = BufReader::new(&b": heartbeat\r\n\r\ndata: {\"type\":\r\ndata: \"response.in_progress\"}\r\n\r\ndata: [DONE]\r\n\r\n"[..]).lines();
        assert_eq!(
            next_event(&mut lines).await.unwrap()["type"],
            "response.in_progress"
        );
        assert_eq!(
            next_event(&mut lines).await.unwrap_err().code,
            "ai_incomplete"
        );
        assert_eq!(
            next_event(&mut lines).await.unwrap_err().code,
            "ai_incomplete"
        );
    }

    #[tokio::test]
    async fn first_text_reaches_reader_before_completion_using_one_provider_call() {
        let source = Source {
            id: Uuid::new_v4(),
            account_id: Uuid::new_v4(),
            subject: "Fixture".into(),
            sender: "sender@example.test".into(),
            sent_at: Utc::now(),
            text: "Fixture email body".into(),
            labels: String::new(),
        };
        let release = Arc::new(Notify::new());
        let count = Arc::new(AtomicUsize::new(0));
        let app = Router::new().route("/responses", post({
            let release = release.clone();
            let count = count.clone();
            let id = source.id;
            move |headers: HeaderMap, Json(body): Json<Value>| {
                let release = release.clone();
                let count = count.clone();
                async move {
                    count.fetch_add(1, Ordering::SeqCst);
                    assert_eq!(headers[header::ACCEPT], "text/event-stream");
                    assert_eq!(body["stream"], true);
                    assert_eq!(body["store"], false);
                    let events = async_stream::stream! {
                        yield Ok::<_, Infallible>(Event::default().json_data(json!({
                            "type":"response.output_text.delta","delta":"{\"text\":\"First"
                        })).unwrap());
                        release.notified().await;
                        let full = json!({"text":"First and last.","items":[{"kind":"fact","text":"Detail","source_ids":[id]}]});
                        yield Ok(Event::default().json_data(json!({"type":"response.completed","response":{
                            "status":"completed","output":[{"type":"message","content":[{"type":"output_text","text":full.to_string()}]}]
                        }})).unwrap());
                    };
                    Sse::new(events)
                }
            }
        }));
        let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
        let address = listener.local_addr().unwrap();
        let fixture = tokio::spawn(async move { axum::serve(listener, app).await.unwrap() });
        let response = request_stream(
            &reqwest::Client::new(),
            &format!("http://{address}/responses"),
            "test-key",
            "fixture".into(),
            vec![source.clone()],
            json!({"store":false}),
            StreamOptions {
                mode: OutputMode::Summary,
                announce_sources: false,
            },
        )
        .await
        .unwrap();
        let reader = StreamReader::new(
            response
                .into_body()
                .into_data_stream()
                .map_err(io::Error::other),
        );
        let mut lines = BufReader::new(reader).lines();
        let first = tokio::time::timeout(Duration::from_secs(5), next_event(&mut lines))
            .await
            .unwrap()
            .unwrap();
        assert_eq!(first, json!({"type":"delta","text":"First"}));
        release.notify_one();
        let last = next_event(&mut lines).await.unwrap();
        assert_eq!(last["type"], "done");
        assert_eq!(last["result"]["text"], "First and last.");
        assert_eq!(
            last["result"]["items"][0]["source_ids"][0],
            source.id.to_string()
        );
        assert_eq!(last["result"]["sources"][0]["text"], "");
        assert_eq!(count.load(Ordering::SeqCst), 1);
        fixture.abort();
    }

    #[tokio::test]
    async fn suggestions_arrive_one_by_one_and_forged_items_are_withheld() {
        let source = Source {
            id: Uuid::new_v4(),
            account_id: Uuid::new_v4(),
            subject: "Fixture".into(),
            sender: "sender@example.test".into(),
            sent_at: Utc::now(),
            text: "Can you confirm by Friday?".into(),
            labels: String::new(),
        };
        let id = source.id;
        let forged = Uuid::new_v4();
        let release = Arc::new(Notify::new());
        let app = Router::new().route("/responses", post({
            let release = release.clone();
            move || {
                let release = release.clone();
                async move {
                    let item = json!({"kind":"suggestion","text":"They asked for a reply.","source_ids":[id],
                        "action":"needs_reply","message_id":id,"due_at":null});
                    let bad = json!({"kind":"suggestion","text":"Forged.","source_ids":[forged],
                        "action":"archive","message_id":forged,"due_at":null});
                    let first = format!("{{\"text\":\"Needs you.\",\"items\":[{item}");
                    let events = async_stream::stream! {
                        yield Ok::<_, Infallible>(Event::default().json_data(json!({
                            "type":"response.output_text.delta","delta":first})).unwrap());
                        yield Ok(Event::default().json_data(json!({
                            "type":"response.output_text.delta","delta":format!(",{bad}")})).unwrap());
                        release.notified().await;
                        let full = json!({"text":"Needs you.","items":[item]});
                        yield Ok(Event::default().json_data(json!({"type":"response.completed","response":{
                            "status":"completed","output":[{"type":"message","content":[{"type":"output_text","text":full.to_string()}]}]
                        }})).unwrap());
                    };
                    Sse::new(events)
                }
            }
        }));
        let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
        let address = listener.local_addr().unwrap();
        let fixture = tokio::spawn(async move { axum::serve(listener, app).await.unwrap() });
        let response = request_stream(
            &reqwest::Client::new(),
            &format!("http://{address}/responses"),
            "test-key",
            "fixture".into(),
            vec![source],
            json!({"store":false}),
            StreamOptions {
                mode: OutputMode::Suggestions,
                announce_sources: false,
            },
        )
        .await
        .unwrap();
        let reader = StreamReader::new(
            response
                .into_body()
                .into_data_stream()
                .map_err(io::Error::other),
        );
        let mut lines = BufReader::new(reader).lines();
        let mut next = async || {
            tokio::time::timeout(Duration::from_secs(5), next_event(&mut lines))
                .await
                .unwrap()
                .unwrap()
        };
        assert_eq!(next().await, json!({"type":"delta","text":"Needs you."}));
        let item = next().await;
        assert_eq!(item["type"], "item");
        assert_eq!(item["item"]["action"], "needs_reply");
        assert_eq!(item["item"]["message_id"], id.to_string());
        release.notify_one();
        let done = next().await;
        assert_eq!(done["type"], "done", "the forged item was not forwarded");
        assert_eq!(done["result"]["items"].as_array().unwrap().len(), 1);
        fixture.abort();
    }

    #[tokio::test]
    async fn answers_list_retrieved_sources_before_prose_without_bodies() {
        let source = Source {
            id: Uuid::new_v4(),
            account_id: Uuid::new_v4(),
            subject: "Invoice".into(),
            sender: "billing@example.test".into(),
            sent_at: Utc::now(),
            text: "Private body text".into(),
            labels: String::new(),
        };
        let id = source.id;
        let app = Router::new().route("/responses", post(move || async move {
            let full = json!({"text":"It is due Friday.","items":[{"kind":"fact","text":"Due Friday","source_ids":[id],
                "action":null,"message_id":null,"due_at":null}]});
            let events = async_stream::stream! {
                yield Ok::<_, Infallible>(Event::default().json_data(json!({
                    "type":"response.output_text.delta","delta":"{\"text\":\"It is due"})).unwrap());
                yield Ok(Event::default().json_data(json!({"type":"response.completed","response":{
                    "status":"completed","output":[{"type":"message","content":[{"type":"output_text","text":full.to_string()}]}]
                }})).unwrap());
            };
            Sse::new(events)
        }));
        let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
        let address = listener.local_addr().unwrap();
        let fixture = tokio::spawn(async move { axum::serve(listener, app).await.unwrap() });
        let response = request_stream(
            &reqwest::Client::new(),
            &format!("http://{address}/responses"),
            "test-key",
            "fixture".into(),
            vec![source],
            json!({"store":false}),
            StreamOptions {
                mode: OutputMode::Assistance,
                announce_sources: true,
            },
        )
        .await
        .unwrap();
        let reader = StreamReader::new(
            response
                .into_body()
                .into_data_stream()
                .map_err(io::Error::other),
        );
        let mut lines = BufReader::new(reader).lines();
        let first = next_event(&mut lines).await.unwrap();
        assert_eq!(first["type"], "sources");
        assert_eq!(first["sources"][0]["id"], id.to_string());
        assert!(
            first["sources"][0].get("text").is_none(),
            "retrieved bodies are not echoed"
        );
        assert_eq!(
            next_event(&mut lines).await.unwrap(),
            json!({"type":"delta","text":"It is due"})
        );
        assert_eq!(next_event(&mut lines).await.unwrap()["type"], "done");
        fixture.abort();
    }
}
