use chrono::{DateTime, Duration, Utc};
use postmere_core::{AppState, error::AppError};
use postmere_providers::Provider;
use serde_json::{Value, json};
use zeroize::Zeroizing;

pub struct SubscriptionRequest {
    pub provider: Provider,
    pub access_token: Zeroizing<String>,
    pub subscription_id: Option<String>,
    pub callback: String,
    pub client_state: Zeroizing<String>,
    pub gmail_topic: Option<String>,
}
#[derive(Debug)]
pub struct Subscription {
    pub id: Option<String>,
    pub expires_at: DateTime<Utc>,
}
pub type TransportFuture<'a, T> =
    std::pin::Pin<Box<dyn std::future::Future<Output = Result<T, AppError>> + Send + 'a>>;
pub trait SubscriptionTransport: Send + Sync {
    fn ensure<'a>(
        &'a self,
        state: &'a AppState,
        request: &'a SubscriptionRequest,
    ) -> TransportFuture<'a, Subscription>;
    fn remove<'a>(
        &'a self,
        state: &'a AppState,
        request: &'a SubscriptionRequest,
    ) -> TransportFuture<'a, ()>;
}
pub struct HttpSubscriptions;

async fn response(
    request: reqwest::RequestBuilder,
) -> Result<(reqwest::StatusCode, Value), AppError> {
    let mut response = request.send().await.map_err(|_| AppError::unavailable())?;
    let status = response.status();
    let mut bytes = Vec::new();
    while let Some(chunk) = response
        .chunk()
        .await
        .map_err(|_| AppError::unavailable())?
    {
        if bytes.len() + chunk.len() > 64 * 1024 {
            return Err(AppError::unavailable());
        }
        bytes.extend_from_slice(&chunk);
    }
    let body = if bytes.is_empty() {
        Value::Null
    } else {
        serde_json::from_slice(&bytes).map_err(|_| AppError::unavailable())?
    };
    Ok((status, body))
}
fn graph_url(id: &str) -> Result<String, AppError> {
    if id.is_empty()
        || id.len() > 512
        || !id
            .bytes()
            .all(|b| b.is_ascii_alphanumeric() || b"-_=+".contains(&b))
    {
        return Err(AppError::internal("invalid_graph_subscription"));
    }
    let mut url = url::Url::parse("https://graph.microsoft.com/v1.0/subscriptions/").unwrap();
    url.path_segments_mut().unwrap().push(id);
    Ok(url.into())
}
fn graph_subscription(value: Value) -> Result<Subscription, AppError> {
    let id = value["id"]
        .as_str()
        .ok_or_else(AppError::unavailable)?
        .to_owned();
    graph_url(&id)?;
    let expires_at = value["expirationDateTime"]
        .as_str()
        .and_then(|v| DateTime::parse_from_rfc3339(v).ok())
        .map(|v| v.with_timezone(&Utc))
        .ok_or_else(AppError::unavailable)?;
    if expires_at <= Utc::now() + Duration::minutes(1)
        || expires_at > Utc::now() + Duration::days(8)
    {
        return Err(AppError::unavailable());
    }
    Ok(Subscription {
        id: Some(id),
        expires_at,
    })
}

trait GraphRequests: Send + Sync {
    fn execute<'a>(
        &'a self,
        method: reqwest::Method,
        url: &'a str,
        body: Option<Value>,
    ) -> TransportFuture<'a, (reqwest::StatusCode, Value)>;
}
struct GraphHttp<'a> {
    state: &'a AppState,
    token: &'a str,
}
impl GraphRequests for GraphHttp<'_> {
    fn execute<'a>(
        &'a self,
        method: reqwest::Method,
        url: &'a str,
        body: Option<Value>,
    ) -> TransportFuture<'a, (reqwest::StatusCode, Value)> {
        Box::pin(async move {
            let request = self
                .state
                .http
                .request(method, url)
                .bearer_auth(self.token)
                .header("Prefer", "IdType=\"ImmutableId\"");
            response(if let Some(body) = body {
                request.json(&body)
            } else {
                request
            })
            .await
        })
    }
}
fn graph_page(raw: &str) -> Result<String, AppError> {
    let url = url::Url::parse(raw).map_err(|_| AppError::unavailable())?;
    if raw.len() > 4096
        || url.scheme() != "https"
        || url.host_str() != Some("graph.microsoft.com")
        || url.port_or_known_default() != Some(443)
        || !url.username().is_empty()
        || url.password().is_some()
        || url.fragment().is_some()
        || url.path() != "/v1.0/subscriptions"
    {
        return Err(AppError::unavailable());
    }
    Ok(url.into())
}
fn owned_subscription(value: &Value, request: &SubscriptionRequest) -> bool {
    value["notificationUrl"] == request.callback
        && value["lifecycleNotificationUrl"] == request.callback
        && value["clientState"].as_str() == Some(&*request.client_state)
        && value["resource"].as_str().is_some_and(|r| {
            r.eq_ignore_ascii_case("me/messages") || r.eq_ignore_ascii_case("/me/messages")
        })
        && value["includeResourceData"] != true
        && value["changeType"].as_str().is_some_and(|types| {
            let mut types: Vec<_> = types.split(',').map(str::trim).collect();
            types.sort_unstable();
            types == ["created", "deleted", "updated"]
        })
}
async fn find_graph_owned(
    request: &SubscriptionRequest,
    http: &impl GraphRequests,
) -> Result<Option<String>, AppError> {
    use reqwest::{Method, StatusCode};
    // List omits clientState. Fetch matching random callback candidates before
    // adopting one, and renew before validating its resulting lifetime.
    let mut next = "https://graph.microsoft.com/v1.0/subscriptions".to_owned();
    let mut seen = std::collections::HashSet::new();
    let mut total = 0;
    loop {
        if seen.len() >= 16 || !seen.insert(next.clone()) {
            return Err(AppError::unavailable());
        }
        let (status, listed) = http.execute(Method::GET, &next, None).await?;
        if !status.is_success() {
            return Err(AppError::unavailable());
        }
        let items = listed["value"]
            .as_array()
            .ok_or_else(AppError::unavailable)?;
        total += items.len();
        if total > 1000 {
            return Err(AppError::unavailable());
        }
        for item in items {
            if item["notificationUrl"] != request.callback {
                continue;
            }
            let id = item["id"].as_str().ok_or_else(AppError::unavailable)?;
            let url = graph_url(id)?;
            let (status, detail) = http.execute(Method::GET, &url, None).await?;
            if matches!(status, StatusCode::NOT_FOUND | StatusCode::GONE) {
                continue;
            }
            if !status.is_success() {
                return Err(AppError::unavailable());
            }
            if !owned_subscription(&detail, request) {
                return Err(AppError::unavailable());
            }
            return Ok(Some(id.to_owned()));
        }
        match listed.get("@odata.nextLink") {
            Some(Value::String(link)) => next = graph_page(link)?,
            None | Some(Value::Null) => return Ok(None),
            _ => return Err(AppError::unavailable()),
        }
    }
}
async fn ensure_graph(
    request: &SubscriptionRequest,
    http: &impl GraphRequests,
) -> Result<Subscription, AppError> {
    use reqwest::{Method, StatusCode};
    let expires = (Utc::now() + Duration::days(2)).to_rfc3339();
    if let Some(id) = &request.subscription_id {
        let (status, value) = http
            .execute(
                Method::PATCH,
                &graph_url(id)?,
                Some(json!({"expirationDateTime":expires})),
            )
            .await?;
        if status.is_success() {
            return graph_subscription(value);
        }
        if !matches!(status, StatusCode::NOT_FOUND | StatusCode::GONE) {
            return Err(AppError::unavailable());
        }
    }
    if let Some(id) = find_graph_owned(request, http).await? {
        let (status, value) = http
            .execute(
                Method::PATCH,
                &graph_url(&id)?,
                Some(json!({"expirationDateTime":expires})),
            )
            .await?;
        if status.is_success() {
            return graph_subscription(value);
        }
        if !matches!(status, StatusCode::NOT_FOUND | StatusCode::GONE) {
            return Err(AppError::unavailable());
        }
    }
    let (status,value)=http.execute(Method::POST,"https://graph.microsoft.com/v1.0/subscriptions",Some(json!({"changeType":"created,updated,deleted","notificationUrl":request.callback,"lifecycleNotificationUrl":request.callback,"resource":"me/messages","expirationDateTime":expires,"clientState":&*request.client_state,"includeResourceData":false,"latestSupportedTlsVersion":"v1_2"}))).await?;
    if !status.is_success() {
        return Err(AppError::unavailable());
    }
    graph_subscription(value)
}
impl SubscriptionTransport for HttpSubscriptions {
    fn ensure<'a>(
        &'a self,
        state: &'a AppState,
        request: &'a SubscriptionRequest,
    ) -> TransportFuture<'a, Subscription> {
        Box::pin(async move {
            match request.provider {
                Provider::Gmail => {
                    let topic = request
                        .gmail_topic
                        .as_ref()
                        .ok_or_else(AppError::unavailable)?;
                    // No label restriction: Inbox moves, reads and deletions are also hints.
                    let (status, value) = response(
                        state
                            .http
                            .post("https://gmail.googleapis.com/gmail/v1/users/me/watch")
                            .bearer_auth(&*request.access_token)
                            .json(&json!({"topicName":topic})),
                    )
                    .await?;
                    if !status.is_success() {
                        return Err(AppError::unavailable());
                    }
                    let millis = value["expiration"]
                        .as_str()
                        .and_then(|s| s.parse::<i64>().ok())
                        .ok_or_else(AppError::unavailable)?;
                    let expires_at = DateTime::from_timestamp_millis(millis)
                        .ok_or_else(AppError::unavailable)?;
                    if expires_at <= Utc::now() + Duration::minutes(1)
                        || expires_at > Utc::now() + Duration::days(8)
                    {
                        return Err(AppError::unavailable());
                    }
                    Ok(Subscription {
                        id: None,
                        expires_at,
                    })
                }
                Provider::Microsoft => {
                    ensure_graph(
                        request,
                        &GraphHttp {
                            state,
                            token: &request.access_token,
                        },
                    )
                    .await
                }
            }
        })
    }
    fn remove<'a>(
        &'a self,
        state: &'a AppState,
        request: &'a SubscriptionRequest,
    ) -> TransportFuture<'a, ()> {
        Box::pin(async move {
            let request_builder = match request.provider {
                Provider::Gmail => state
                    .http
                    .post("https://gmail.googleapis.com/gmail/v1/users/me/stop"),
                Provider::Microsoft => {
                    let discovered;
                    let id = if let Some(id) = &request.subscription_id {
                        id
                    } else {
                        discovered = find_graph_owned(
                            request,
                            &GraphHttp {
                                state,
                                token: &request.access_token,
                            },
                        )
                        .await?;
                        let Some(id) = &discovered else {
                            return Ok(());
                        };
                        id
                    };
                    state.http.delete(graph_url(id)?)
                }
            };
            let (status, _) = response(request_builder.bearer_auth(&*request.access_token)).await?;
            if status.is_success()
                || matches!(
                    status,
                    reqwest::StatusCode::NOT_FOUND | reqwest::StatusCode::GONE
                )
            {
                Ok(())
            } else {
                Err(AppError::unavailable())
            }
        })
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::{collections::VecDeque, sync::Mutex};
    struct Fixture(Mutex<VecDeque<(reqwest::Method, String, reqwest::StatusCode, Value)>>);
    impl GraphRequests for Fixture {
        fn execute<'a>(
            &'a self,
            method: reqwest::Method,
            url: &'a str,
            body: Option<Value>,
        ) -> TransportFuture<'a, (reqwest::StatusCode, Value)> {
            Box::pin(async move {
                let (expected_method, expected_url, status, value) = self
                    .0
                    .lock()
                    .unwrap()
                    .pop_front()
                    .expect("unexpected provider request");
                assert_eq!(method, expected_method);
                assert_eq!(url, expected_url);
                if method == reqwest::Method::PATCH {
                    assert!(body.unwrap()["expirationDateTime"].as_str().is_some());
                }
                Ok((status, value))
            })
        }
    }
    fn request() -> SubscriptionRequest {
        SubscriptionRequest {
            provider: Provider::Microsoft,
            access_token: Zeroizing::new("fixture".into()),
            subscription_id: None,
            callback: "https://postmere.test/v1/webhooks/microsoft/random".into(),
            client_state: Zeroizing::new("secret".into()),
            gmail_topic: None,
        }
    }
    #[tokio::test]
    async fn interrupted_graph_create_reconciles_list_without_secret_and_renews_near_expiry() {
        let request = request();
        let id = "fixture-subscription";
        let url = graph_url(id).unwrap();
        let detail = json!({"id":id,"notificationUrl":request.callback,"lifecycleNotificationUrl":request.callback,"clientState":"secret","resource":"me/messages","changeType":"created,updated,deleted","expirationDateTime":(Utc::now()+Duration::seconds(15)).to_rfc3339()});
        let fixture = Fixture(Mutex::new(VecDeque::from([
            (
                reqwest::Method::GET,
                "https://graph.microsoft.com/v1.0/subscriptions".into(),
                reqwest::StatusCode::OK,
                json!({"value":[{"id":id,"notificationUrl":request.callback,"clientState":null}]}),
            ),
            (
                reqwest::Method::GET,
                url.clone(),
                reqwest::StatusCode::OK,
                detail,
            ),
            (
                reqwest::Method::PATCH,
                url,
                reqwest::StatusCode::OK,
                json!({"id":id,"expirationDateTime":(Utc::now()+Duration::days(2)).to_rfc3339()}),
            ),
        ])));
        let renewed = ensure_graph(&request, &fixture).await.unwrap();
        assert_eq!(renewed.id.as_deref(), Some(id));
        assert!(fixture.0.lock().unwrap().is_empty());
    }
    #[test]
    fn subscription_cursors_and_ownership_do_not_accept_foreign_resources_or_secrets() {
        for url in [
            "http://graph.microsoft.com/v1.0/subscriptions",
            "https://graph.microsoft.com.evil.test/v1.0/subscriptions",
            "https://user@graph.microsoft.com/v1.0/subscriptions",
            "https://graph.microsoft.com/v1.0/me/messages",
            "https://graph.microsoft.com:444/v1.0/subscriptions",
            "https://graph.microsoft.com/v1.0/subscriptions#fragment",
        ] {
            assert!(graph_page(url).is_err());
        }
        assert!(
            graph_page("https://graph.microsoft.com/v1.0/subscriptions?$skiptoken=opaque").is_ok()
        );
        let request = request();
        let mut detail = json!({"notificationUrl":request.callback,"lifecycleNotificationUrl":request.callback,"clientState":"secret","resource":"me/messages","changeType":"updated,deleted,created"});
        assert!(owned_subscription(&detail, &request));
        detail["clientState"] = json!("wrong");
        assert!(!owned_subscription(&detail, &request));
        detail["clientState"] = json!("secret");
        detail["resource"] = json!("me/events");
        assert!(!owned_subscription(&detail, &request));
    }
}
