//! Browser-only review and consent for immutable MCP action requests.
//! No bearer credential or GET request can approve an action.
use axum::{
    Form, Router,
    extract::{DefaultBodyLimit, Path, State, rejection::FormRejection},
    http::{HeaderMap, HeaderValue, StatusCode, header},
    response::{Html, IntoResponse, Redirect, Response},
    routing::get,
};
use chrono::{DateTime, Utc};
use postmere_core::{AppState, error::AppError};
use postmere_mcp_auth::{browser_session, login_redirect, verify_browser_post};
use postmere_mcp_operations::{
    Approval, ApprovalReview, approve_action, cancel_action, get_approval,
};
use postmere_providers::Address;
use serde::Deserialize;
use uuid::Uuid;

const STYLESHEET: &str = include_str!("../static/approvals.css");
const PAGE_CSP: &str = "default-src 'none'; style-src 'self'; form-action 'self'; frame-ancestors 'none'; base-uri 'none'";

pub fn router() -> Router<AppState> {
    Router::new()
        .route("/mcp/approvals.css", get(stylesheet))
        .route("/mcp/approvals/{id}", get(review).post(decide))
        .layer(DefaultBodyLimit::max(16 * 1024))
}

async fn stylesheet() -> Response {
    secure(
        (
            [(header::CONTENT_TYPE, "text/css; charset=utf-8")],
            STYLESHEET,
        )
            .into_response(),
    )
}

async fn review(
    State(state): State<AppState>,
    Path(id): Path<Uuid>,
    headers: HeaderMap,
) -> Response {
    let browser = match browser_session(&state, &headers).await {
        Ok(browser) => browser,
        Err(error) => return auth_error(error, id),
    };
    match get_approval(&state, &browser.auth, id).await {
        Ok(approval) => page(
            StatusCode::OK,
            render_approval(&approval, &browser.csrf_token),
        ),
        Err(error) => auth_error(error, id),
    }
}

#[derive(Deserialize)]
#[serde(rename_all = "snake_case")]
enum Decision {
    Approve,
    Cancel,
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct DecisionForm {
    csrf: String,
    action: Decision,
}

async fn decide(
    State(state): State<AppState>,
    Path(id): Path<Uuid>,
    headers: HeaderMap,
    form: Result<Form<DecisionForm>, FormRejection>,
) -> Response {
    if let Err(error) = browser_session(&state, &headers).await {
        return auth_error(error, id);
    }
    let input = match form {
        Ok(Form(input)) => input,
        Err(_) => {
            return error_page(AppError::bad_request(
                "Choose Approve or Cancel on the approval page.",
            ));
        }
    };
    let browser = match verify_browser_post(&state, &headers, &input.csrf).await {
        Ok(browser) => browser,
        Err(error) => return auth_error(error, id),
    };
    let result = match input.action {
        Decision::Approve => approve_action(&state, &browser.auth, id).await,
        Decision::Cancel => cancel_action(&state, &browser.auth, id).await,
    };
    match result {
        // POST/Redirect/GET avoids accidental resubmission on refresh. The
        // operation layer also binds ownership, checks expiry, and claims once.
        Ok(_) => secure(Redirect::to(&approval_path(id)).into_response()),
        Err(error) => auth_error(error, id),
    }
}

fn approval_path(id: Uuid) -> String {
    format!("/mcp/approvals/{id}")
}

fn auth_error(error: AppError, id: Uuid) -> Response {
    if error.status == StatusCode::UNAUTHORIZED {
        secure(login_redirect(&approval_path(id)))
    } else {
        error_page(error)
    }
}

fn secure(mut response: Response) -> Response {
    let headers = response.headers_mut();
    headers.insert(header::CACHE_CONTROL, HeaderValue::from_static("no-store"));
    headers.insert(
        header::X_CONTENT_TYPE_OPTIONS,
        HeaderValue::from_static("nosniff"),
    );
    headers.insert(
        header::REFERRER_POLICY,
        HeaderValue::from_static("no-referrer"),
    );
    headers.insert(
        header::CONTENT_SECURITY_POLICY,
        HeaderValue::from_static(PAGE_CSP),
    );
    response
}

fn page(status: StatusCode, html: String) -> Response {
    secure((status, Html(html)).into_response())
}

fn error_page(error: AppError) -> Response {
    let (title, message) = match error.status {
        StatusCode::NOT_FOUND | StatusCode::FORBIDDEN => (
            "Approval unavailable",
            "This request is unavailable to your signed-in workspace account. Return to your assistant to request a new approval.",
        ),
        StatusCode::BAD_REQUEST | StatusCode::UNPROCESSABLE_ENTITY => (
            "This request could not be submitted",
            "Return to the approval page, review the details, then choose Approve or Cancel.",
        ),
        StatusCode::CONFLICT => (
            "This request has changed",
            "Return to your assistant to check the result or request a new approval.",
        ),
        _ => (
            "Approval temporarily unavailable",
            "The request could not be completed. Try opening the approval page again.",
        ),
    };
    page(
        error.status,
        shell(
            title,
            &format!(
                "<main class=\"error-layout\"><section class=\"intro\"><p class=\"eyebrow\">ACTION APPROVAL</p><h1>{}</h1><p class=\"lead\">{}</p><p class=\"quiet\">You can close this tab when you’re finished.</p></section></main>",
                escape(title),
                escape(message)
            ),
        ),
    )
}

fn render_approval(approval: &Approval, csrf: &str) -> String {
    let pending = approval.status == "pending" && approval.expires_at > Utc::now();
    let status = if approval.status == "pending" && !pending {
        "expired"
    } else {
        &approval.status
    };
    let (title, explanation, approve_label) = match &approval.review {
        ApprovalReview::SendDraft { .. } => (
            "Send this message?",
            "Review the recipients and message before sending. Approval queues this exact version, including the attachments and tracking shown below.",
            "Approve send",
        ),
        ApprovalReview::TrashMessage { .. } => (
            "Move this message to Trash?",
            "Review the message and account below. Approval moves this message to Trash in your connected email account.",
            "Approve move to Trash",
        ),
        ApprovalReview::DisconnectAccount { .. } => (
            "Disconnect this account?",
            "Review the email account below. Approval stops syncing this account and cancels its pending sends.",
            "Approve disconnect",
        ),
    };
    let (status_label, status_description) = status_copy(status);
    let heading = if pending { title } else { status_label };
    let mut details = String::new();
    match &approval.review {
        ApprovalReview::SendDraft {
            account_email,
            to,
            cc,
            bcc,
            subject,
            text_body,
            html_body,
            attachments,
            scheduled_at,
            undo_seconds,
            track_opens,
            track_links,
            in_reply_to,
            references,
            provider_thread_id,
            ..
        } => {
            details.push_str("<section class=\"review-card\" aria-labelledby=\"message-heading\"><h2 id=\"message-heading\">Message to send</h2><dl class=\"fields\">");
            details.push_str(&row("From", &escape(account_email)));
            details.push_str(&row("To", &addresses(to)));
            details.push_str(&row("Cc", &addresses(cc)));
            details.push_str(&row("Bcc", &addresses(bcc)));
            details.push_str(&row(
                "Subject",
                &escape(if subject.is_empty() {
                    "(No subject)"
                } else {
                    subject
                }),
            ));
            details.push_str("</dl><h3>Message</h3>");
            details.push_str(&format!(
                "<pre class=\"message-body\">{}</pre>",
                escape(text_body)
            ));
            if let Some(html) = html_body {
                details.push_str("<div class=\"html-notice\"><p>This message also includes an HTML version. Review its source before approving.</p><details><summary>Review HTML source</summary>");
                details.push_str(&format!(
                    "<pre class=\"html-source\">{}</pre></details></div>",
                    escape(html)
                ));
            }
            details.push_str("<h3>Attachments</h3>");
            if attachments.is_empty() {
                details.push_str("<p class=\"quiet\">No attachments</p>");
            } else {
                details.push_str("<ul class=\"attachments\">");
                for attachment in attachments {
                    details.push_str(&format!(
                        "<li><span class=\"attachment-name\">{}</span><span class=\"attachment-meta\">{} · {} bytes</span></li>",
                        escape(&attachment.filename), escape(&attachment.mime_type), attachment.size_bytes
                    ));
                }
                details.push_str("</ul>");
            }
            details.push_str("<h3>Delivery &amp; tracking</h3><dl class=\"fields\">");
            details.push_str(&row(
                "Scheduled",
                &scheduled_at
                    .map(|date| timestamp(date))
                    .unwrap_or_else(|| "After approval and the undo window".into()),
            ));
            details.push_str(&row(
                "Undo window",
                &format!("{} seconds", undo_seconds.unwrap_or(10).clamp(5, 60)),
            ));
            details.push_str(&row(
                "Open tracking",
                if *track_opens { "On" } else { "Off" },
            ));
            details.push_str(&row(
                "Link tracking",
                if *track_links { "On" } else { "Off" },
            ));
            details.push_str("</dl>");
            if in_reply_to.is_some() || !references.is_empty() || provider_thread_id.is_some() {
                details.push_str("<details class=\"reply-context\"><summary>Review conversation headers</summary><dl class=\"fields\">");
                if let Some(message_id) = in_reply_to {
                    details.push_str(&row("In reply to", &escape(message_id)));
                }
                if !references.is_empty() {
                    details.push_str(&row("References", &escape(&references.join("\n"))));
                }
                if let Some(thread_id) = provider_thread_id {
                    details.push_str(&row("Thread ID", &escape(thread_id)));
                }
                details.push_str("</dl></details>");
            }
            details.push_str("</section>");
        }
        ApprovalReview::TrashMessage {
            account_email,
            subject,
            from,
            preview,
            ..
        } => {
            details.push_str("<section class=\"review-card\" aria-labelledby=\"message-heading\"><h2 id=\"message-heading\">Message to move</h2><dl class=\"fields\">");
            details.push_str(&row("Account", &escape(account_email)));
            details.push_str(&row("From", &address(from)));
            details.push_str(&row(
                "Subject",
                &escape(if subject.is_empty() {
                    "(No subject)"
                } else {
                    subject
                }),
            ));
            details.push_str(&row("Destination", "Trash"));
            details.push_str("</dl><h3>Message preview</h3>");
            details.push_str(&format!(
                "<pre class=\"message-body\">{}</pre></section>",
                escape(preview)
            ));
        }
        ApprovalReview::DisconnectAccount {
            email,
            provider,
            display_name,
            ..
        } => {
            details.push_str("<section class=\"review-card\" aria-labelledby=\"account-heading\"><h2 id=\"account-heading\">Account to disconnect</h2><dl class=\"fields\">");
            details.push_str(&row("Email", &escape(email)));
            details.push_str(&row(
                "Provider",
                &escape(match provider.as_str() {
                    "gmail" => "Google",
                    "microsoft" => "Microsoft Outlook",
                    other => other,
                }),
            ));
            if let Some(name) = display_name {
                details.push_str(&row("Name", &escape(name)));
            }
            details.push_str("</dl><p class=\"quiet\">Your other connected accounts are unaffected.</p></section>");
        }
    }
    let actions = if pending {
        format!(
            "<form method=\"post\" action=\"{}\" class=\"approval-actions\"><input type=\"hidden\" name=\"csrf\" value=\"{}\"><p>Approve only the action described above.</p><div class=\"buttons\"><button type=\"submit\" name=\"action\" value=\"approve\" class=\"primary\">{}</button><button type=\"submit\" name=\"action\" value=\"cancel\" class=\"secondary\">Cancel request</button></div></form>",
            approval_path(approval.id),
            escape(csrf),
            approve_label
        )
    } else {
        format!(
            "<section class=\"result\" aria-label=\"Approval result\"><h2>{}</h2><p>{}</p><p class=\"quiet\">You can return to your assistant or close this tab.</p></section>",
            escape(status_label),
            escape(status_description)
        )
    };
    shell(
        heading,
        &format!(
            "<main><section class=\"intro\"><p class=\"eyebrow\">ACTION APPROVAL</p><h1>{}</h1><p class=\"lead\">{}</p><span class=\"status\">{}</span><dl class=\"request-meta\"><dt>Requested</dt><dd>{}</dd><dt>Expires</dt><dd>{}</dd></dl><p class=\"quiet\">Requested through a connected assistant. This approval applies only to the action shown here.</p></section><div class=\"review-column\">{}{}</div></main>",
            escape(heading),
            escape(if pending {
                explanation
            } else {
                status_description
            }),
            escape(status_label),
            timestamp(approval.created_at),
            timestamp(approval.expires_at),
            details,
            actions
        ),
    )
}

fn status_copy(status: &str) -> (&'static str, &'static str) {
    match status {
        "pending" => (
            "Awaiting your approval",
            "Review the details before choosing an action.",
        ),
        "executing" => (
            "Action in progress",
            "Your approval was received. The action is being processed. Refresh this page to check its result.",
        ),
        "completed" => (
            "Action approved",
            "Your approval was accepted and the requested action was submitted. Your assistant can check its delivery or completion status.",
        ),
        "cancelled" => (
            "Request cancelled",
            "This request was cancelled. No action will be taken from this approval.",
        ),
        "expired" => (
            "Request expired",
            "This approval has expired. Ask your assistant for a new request if you still want to proceed.",
        ),
        "failed" => (
            "Action could not be completed",
            "The action could not be completed. Return to your assistant to check the result before requesting another approval.",
        ),
        "uncertain" => (
            "Check the action’s result",
            "The email provider did not confirm the outcome. Check your account before requesting this action again.",
        ),
        _ => (
            "Approval unavailable",
            "This request can no longer be approved. Return to your assistant to check its status.",
        ),
    }
}

fn timestamp(date: DateTime<Utc>) -> String {
    format!(
        "<time datetime=\"{}\">{} UTC</time>",
        date.to_rfc3339(),
        date.format("%b %-d, %Y · %H:%M")
    )
}

fn row(label: &str, value_html: &str) -> String {
    format!("<div><dt>{}</dt><dd>{value_html}</dd></div>", escape(label))
}

fn addresses(values: &[Address]) -> String {
    if values.is_empty() {
        return "<span class=\"quiet\">None</span>".into();
    }
    format!(
        "<ul class=\"addresses\">{}</ul>",
        values
            .iter()
            .map(|value| format!("<li>{}</li>", address(value)))
            .collect::<String>()
    )
}

fn address(value: &Address) -> String {
    match &value.name {
        Some(name) if !name.is_empty() => {
            format!("{} &lt;{}&gt;", escape(name), escape(&value.email))
        }
        _ => escape(&value.email),
    }
}

/// Escape both text and quoted attribute contexts. Review data never becomes
/// markup, even when the message itself contains HTML.
fn escape(value: &str) -> String {
    value
        .chars()
        .fold(String::with_capacity(value.len()), |mut html, character| {
            match character {
                '&' => html.push_str("&amp;"),
                '<' => html.push_str("&lt;"),
                '>' => html.push_str("&gt;"),
                '"' => html.push_str("&quot;"),
                '\'' => html.push_str("&#39;"),
                other => html.push(other),
            }
            html
        })
}

fn shell(title: &str, content: &str) -> String {
    format!(
        "<!doctype html><html lang=\"en\"><head><meta charset=\"utf-8\"><meta name=\"viewport\" content=\"width=device-width, initial-scale=1\"><meta name=\"color-scheme\" content=\"light\"><title>{} · Postmere</title><link rel=\"stylesheet\" href=\"/mcp/approvals.css\"></head><body><header><span class=\"wordmark\">Postmere<span aria-hidden=\"true\">.</span></span><span class=\"header-note\">Your workspace. Your decision.</span></header>{content}<footer>Postmere workspace approval</footer></body></html>",
        escape(title)
    )
}
