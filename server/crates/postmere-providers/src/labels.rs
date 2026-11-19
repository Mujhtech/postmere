use super::{
    AppState, Credentials, GOOGLE_API, GRAPH_API, MAX_RESPONSE, Provider, ProviderError,
    message_url, read_bytes, request_json, validated_graph_collection_cursor,
};
use serde::{Deserialize, Serialize};
use serde_json::{Value, json};
use std::collections::HashSet;
use url::Url;

/// IDs identify catalog entries. Outlook stores the category's display name on
/// each message, while Gmail stores its label ID.
#[derive(Clone, Debug, Deserialize, Serialize, PartialEq, Eq)]
pub struct MailLabel {
    pub id: String,
    pub name: String,
}

pub fn has_label_scope(provider: Provider, credentials: &Credentials) -> bool {
    match provider {
        // Pre-scope-tracking Gmail accounts already requested gmail.modify.
        Provider::Gmail => {
            credentials.scopes.is_empty()
                || credentials.scopes.iter().any(|s| {
                    s == "https://www.googleapis.com/auth/gmail.modify"
                        || s == "https://mail.google.com/"
                })
        }
        Provider::Microsoft => credentials.scopes.iter().any(|s| {
            s.eq_ignore_ascii_case("MailboxSettings.ReadWrite")
                || s.eq_ignore_ascii_case("https://graph.microsoft.com/MailboxSettings.ReadWrite")
        }),
    }
}

fn catalog_url(provider: Provider, id: Option<&str>) -> Result<Url, ProviderError> {
    let (base, path) = match provider {
        Provider::Gmail => (GOOGLE_API, "labels"),
        Provider::Microsoft => (GRAPH_API, "outlook/masterCategories"),
    };
    let mut url = Url::parse(base)
        .and_then(|base| base.join(path))
        .map_err(|_| ProviderError::InvalidResponse)?;
    if let Some(id) = id {
        if id.is_empty()
            || id == "."
            || id == ".."
            || id.len() > 4096
            || id.chars().any(char::is_control)
        {
            return Err(ProviderError::Rejected);
        }
        url.path_segments_mut()
            .map_err(|_| ProviderError::InvalidResponse)?
            .push(id);
    }
    Ok(url)
}

fn parse_label(provider: Provider, item: &Value) -> Result<Option<MailLabel>, ProviderError> {
    if provider == Provider::Gmail {
        match item.get("type").and_then(Value::as_str) {
            Some("system") => return Ok(None),
            Some("user") => {}
            _ => return Err(ProviderError::InvalidResponse),
        }
    }
    let text = |key| {
        item.get(key)
            .and_then(Value::as_str)
            .filter(|s| !s.is_empty())
            .map(str::to_owned)
            .ok_or(ProviderError::InvalidResponse)
    };
    let name = if provider == Provider::Gmail {
        "name"
    } else {
        "displayName"
    };
    Ok(Some(MailLabel {
        id: text("id")?,
        name: text(name)?,
    }))
}

pub async fn list_labels(
    state: &AppState,
    provider: Provider,
    token: &str,
) -> Result<Vec<MailLabel>, ProviderError> {
    let mut url = catalog_url(provider, None)?;
    let mut labels = Vec::new();
    let mut seen_pages = HashSet::new();
    loop {
        if !seen_pages.insert(url.clone()) {
            return Err(ProviderError::InvalidResponse);
        }
        let page = request_json(state.http.get(url).bearer_auth(token)).await?;
        let key = if provider == Provider::Gmail {
            "labels"
        } else {
            "value"
        };
        let items = page
            .get(key)
            .and_then(Value::as_array)
            .ok_or(ProviderError::InvalidResponse)?;
        for item in items {
            if let Some(label) = parse_label(provider, item)? {
                labels.push(label);
            }
        }
        if provider == Provider::Gmail {
            break;
        }
        let Some(cursor) = page.get("@odata.nextLink").and_then(Value::as_str) else {
            break;
        };
        url = validated_graph_collection_cursor(cursor, "/v1.0/me/outlook/masterCategories")?;
    }
    Ok(labels)
}

pub async fn create_label(
    state: &AppState,
    provider: Provider,
    token: &str,
    name: &str,
) -> Result<MailLabel, ProviderError> {
    let name = name.trim();
    if name.is_empty() || name.len() > 1024 || name.chars().any(char::is_control) {
        return Err(ProviderError::Rejected);
    }
    let body = match provider {
        Provider::Gmail => json!({"name":name}),
        Provider::Microsoft => json!({"displayName":name, "color":"none"}),
    };
    let response = state
        .http
        .post(catalog_url(provider, None)?)
        .bearer_auth(token)
        .json(&body)
        .send()
        .await
        .map_err(|_| ProviderError::Unavailable)?;
    // A retried create can find the first request already succeeded. Return
    // the existing catalog entry if the provider rejects a duplicate.
    if matches!(response.status().as_u16(), 400 | 409) {
        let key = name.to_lowercase();
        return list_labels(state, provider, token)
            .await?
            .into_iter()
            .find(|label| label.name.to_lowercase() == key)
            .ok_or(ProviderError::Rejected);
    }
    let item = super::read_json(response).await?;
    parse_label(provider, &item)?.ok_or(ProviderError::InvalidResponse)
}

async fn message_membership_resource(
    state: &AppState,
    provider: Provider,
    token: &str,
    id: &str,
) -> Result<Value, ProviderError> {
    let mut url = message_url(provider, id, None)?;
    let request = match provider {
        Provider::Gmail => {
            url.query_pairs_mut()
                .append_pair("format", "minimal")
                .append_pair("fields", "id,labelIds");
            state.http.get(url)
        }
        Provider::Microsoft => {
            url.query_pairs_mut()
                .append_pair("$select", "id,categories,changeKey");
            state
                .http
                .get(url)
                .header("Prefer", "IdType=\"ImmutableId\"")
        }
    };
    request_json(request.bearer_auth(token)).await
}

fn membership(provider: Provider, item: &Value) -> Result<Vec<String>, ProviderError> {
    let key = if provider == Provider::Gmail {
        "labelIds"
    } else {
        "categories"
    };
    let Some(value) = item.get(key) else {
        // Gmail omits empty repeated fields, including labelIds for an
        // unlabelled archived message. Graph specifies a categories collection.
        if provider == Provider::Gmail && item.get("id").and_then(Value::as_str).is_some() {
            return Ok(Vec::new());
        }
        return Err(ProviderError::InvalidResponse);
    };
    serde_json::from_value(value.clone()).map_err(|_| ProviderError::InvalidResponse)
}

pub async fn message_label_membership(
    state: &AppState,
    provider: Provider,
    token: &str,
    message_id: &str,
) -> Result<Vec<String>, ProviderError> {
    let item = message_membership_resource(state, provider, token, message_id).await?;
    membership(provider, &item)
}

fn category_patch(
    resource: &Value,
    name: &str,
    applied: bool,
) -> Result<Option<(String, Vec<String>)>, ProviderError> {
    let mut values = membership(Provider::Microsoft, resource)?;
    let folded = name.to_lowercase();
    let matches = |value: &String| value.to_lowercase() == folded;
    if values.iter().any(matches) == applied {
        return Ok(None);
    }
    if applied {
        values.push(name.into());
    } else {
        values.retain(|value| !matches(value));
    }
    let tag = resource
        .get("@odata.etag")
        .and_then(Value::as_str)
        .filter(|tag| !tag.is_empty() && *tag != "*" && !tag.chars().any(char::is_control))
        .ok_or(ProviderError::InvalidResponse)?;
    Ok(Some((tag.to_owned(), values)))
}

pub async fn set_message_label(
    state: &AppState,
    provider: Provider,
    token: &str,
    message_id: &str,
    label_id: &str,
    applied: bool,
) -> Result<(), ProviderError> {
    let entry = request_json(
        state
            .http
            .get(catalog_url(provider, Some(label_id))?)
            .bearer_auth(token),
    )
    .await?;
    let label = parse_label(provider, &entry)?.ok_or(ProviderError::Rejected)?;
    if label.id != label_id {
        return Err(ProviderError::InvalidResponse);
    }
    if provider == Provider::Gmail {
        let key = if applied {
            "addLabelIds"
        } else {
            "removeLabelIds"
        };
        request_json(
            state
                .http
                .post(message_url(provider, message_id, Some("modify"))?)
                .bearer_auth(token)
                .json(&json!({(key):[label.id]})),
        )
        .await?;
        return Ok(());
    }
    // Graph replaces the whole categories collection. Merge against the live
    // version and condition the write so other Outlook clients' edits survive.
    for _ in 0..3 {
        let current = message_membership_resource(state, provider, token, message_id).await?;
        let Some((etag, categories)) = category_patch(&current, &label.name, applied)? else {
            return Ok(());
        };
        let response = state
            .http
            .patch(message_url(provider, message_id, None)?)
            .header("If-Match", etag)
            .header("Prefer", "IdType=\"ImmutableId\"")
            .bearer_auth(token)
            .json(&json!({"categories":categories}))
            .send()
            .await
            .map_err(|_| ProviderError::Unavailable)?;
        if matches!(response.status().as_u16(), 409 | 412) {
            continue;
        }
        read_bytes(response, MAX_RESPONSE).await?;
        return Ok(());
    }
    Err(ProviderError::CategoryConflict)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn editable_catalog_excludes_gmail_system_labels_and_keeps_graph_ids_distinct_from_names() {
        let system = json!({"id":"TRASH","name":"TRASH","type":"system"});
        let user = json!({"id":"Label_482","name":"Projects/Fieldnotes","type":"user"});
        assert_eq!(parse_label(Provider::Gmail, &system).unwrap(), None);
        assert_eq!(
            parse_label(Provider::Gmail, &user).unwrap(),
            Some(MailLabel {
                id: "Label_482".into(),
                name: "Projects/Fieldnotes".into()
            })
        );
        assert_eq!(
            parse_label(Provider::Gmail, &json!({"id":"INBOX", "name":"Inbox"})),
            Err(ProviderError::InvalidResponse)
        );
        let category = json!({"id":"category-id","displayName":"Review","color":"preset9"});
        assert_eq!(
            parse_label(Provider::Microsoft, &category)
                .unwrap()
                .unwrap()
                .name,
            "Review"
        );
        assert_eq!(
            membership(Provider::Gmail, &json!({"id":"22"})).unwrap(),
            Vec::<String>::new()
        );
        assert_eq!(
            membership(
                Provider::Gmail,
                &json!({"id":"22","labelIds":["Label_482","STARRED"]})
            )
            .unwrap(),
            ["Label_482", "STARRED"]
        );
        assert!(
            membership(
                Provider::Microsoft,
                &json!({"id":"22","parentFolderId":"F1"})
            )
            .is_err()
        );
    }

    #[test]
    fn graph_category_writes_merge_live_membership_and_require_a_matching_version() {
        let original = json!({"categories":["Design", "Blue"], "@odata.etag":"W/\"a\""});
        assert_eq!(category_patch(&original, "BLUE", true).unwrap(), None);
        assert_eq!(category_patch(&original, "Draft", false).unwrap(), None);
        assert_eq!(
            category_patch(&original, "Draft", true).unwrap(),
            Some((
                "W/\"a\"".into(),
                vec!["Design".into(), "Blue".into(), "Draft".into()]
            ))
        );
        let changed =
            json!({"categories":["Design", "Blue", "External edit"], "@odata.etag":"W/\"b\""});
        assert_eq!(
            category_patch(&changed, "blue", false).unwrap(),
            Some((
                "W/\"b\"".into(),
                vec!["Design".into(), "External edit".into()]
            ))
        );
        for invalid in [
            json!({"categories":["A"]}),
            json!({"categories":["A"],"@odata.etag":"*"}),
            json!({"@odata.etag":"W/\"a\""}),
        ] {
            assert!(category_patch(&invalid, "B", true).is_err());
        }
    }

    #[test]
    fn category_catalog_requests_stay_in_the_account_catalog() {
        let url = catalog_url(Provider::Gmail, Some("Label/one?#")).unwrap();
        assert_eq!(url.path(), "/gmail/v1/users/me/labels/Label%2Fone%3F%23");
        assert_eq!(url.query(), None);
        assert!(catalog_url(Provider::Microsoft, Some("..")).is_err());
        assert!(catalog_url(Provider::Microsoft, Some("")).is_err());
        let path = "/v1.0/me/outlook/masterCategories";
        assert!(
            validated_graph_collection_cursor(
                "https://graph.microsoft.com/v1.0/me/outlook/masterCategories?$skip=10",
                path
            )
            .is_ok()
        );
        assert!(
            validated_graph_collection_cursor(
                "https://graph.microsoft.com/v1.0/me/messages?$skip=10",
                path
            )
            .is_err()
        );
        assert!(
            validated_graph_collection_cursor(
                "https://other.example/v1.0/me/outlook/masterCategories?$skip=10",
                path
            )
            .is_err()
        );
    }

    #[test]
    fn existing_microsoft_mail_grants_need_category_consent() {
        let mut credentials = Credentials {
            access_token: "fixture".into(),
            refresh_token: None,
            expires_at: chrono::Utc::now(),
            scopes: vec![],
        };
        assert!(has_label_scope(Provider::Gmail, &credentials));
        assert!(!has_label_scope(Provider::Microsoft, &credentials));
        credentials.scopes = vec!["Mail.ReadWrite".into(), "Calendars.ReadWrite".into()];
        assert!(!has_label_scope(Provider::Microsoft, &credentials));
        credentials
            .scopes
            .push("https://graph.microsoft.com/MailboxSettings.ReadWrite".into());
        assert!(has_label_scope(Provider::Microsoft, &credentials));
    }
}
