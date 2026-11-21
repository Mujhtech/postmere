mod common;

use chrono::{Duration, Utc};
use postmere_core::{AppState, auth::AuthContext, db};
use postmere_mail::mail::{AccountSession, MessageMutationFuture, MessageMutationTransport};
use postmere_mcp_operations as ops;
use postmere_providers::{Address, Credentials, Message, Mutation, Outgoing};
use sha2::{Digest, Sha256};
use sqlx::PgPool;
use std::sync::atomic::{AtomicUsize, Ordering};
use uuid::Uuid;

#[derive(Default)]
struct FixtureMutation {
    calls: AtomicUsize,
    fail: bool,
}
impl MessageMutationTransport for FixtureMutation {
    fn apply<'a>(
        &'a self,
        _: &'a AppState,
        _: &'a AccountSession,
        old: &'a Message,
        mutation: &'a Mutation,
    ) -> MessageMutationFuture<'a> {
        Box::pin(async move {
            self.calls.fetch_add(1, Ordering::SeqCst);
            if self.fail {
                return Err(postmere_core::error::AppError::unavailable());
            }
            let mut changed = old.clone();
            if let Some(mailbox) = &mutation.mailbox {
                changed.mailbox = mailbox.clone();
            }
            Ok(changed)
        })
    }
}

async fn identity(pool: &PgPool, workspace: Uuid) -> AuthContext {
    let user = Uuid::new_v4();
    let session = Uuid::new_v4();
    sqlx::query("INSERT INTO users(id,email,password_hash) VALUES($1,$2,'not-used-by-fixture')")
        .bind(user)
        .bind(format!("mcp-{user}@example.test"))
        .execute(pool)
        .await
        .unwrap();
    sqlx::query("INSERT INTO workspaces(id,name) VALUES($1,'MCP operations fixture') ON CONFLICT DO NOTHING").bind(workspace).execute(pool).await.unwrap();
    sqlx::query("INSERT INTO memberships(workspace_id,user_id,role) VALUES($1,$2,'owner')")
        .bind(workspace)
        .bind(user)
        .execute(pool)
        .await
        .unwrap();
    sqlx::query("INSERT INTO sessions(id,workspace_id,user_id,token_hash,expires_at,absolute_expires_at) VALUES($1,$2,$3,$4,now()+interval '1 day',now()+interval '2 days')")
        .bind(session).bind(workspace).bind(user).bind(Sha256::digest(session.as_bytes()).to_vec()).execute(pool).await.unwrap();
    AuthContext {
        assistant: false,
        user_id: user,
        workspace_id: workspace,
        session_id: session,
        role: "owner".into(),
    }
}
async fn account(state: &AppState, auth: &AuthContext, email: &str) -> Uuid {
    let id = Uuid::new_v4();
    let credentials = Credentials {
        access_token: "fixture-never-network".into(),
        refresh_token: None,
        expires_at: Utc::now() + Duration::days(1),
        scopes: vec![],
    };
    let sealed = state
        .crypto
        .seal(
            auth.workspace_id,
            id,
            &serde_json::to_vec(&credentials).unwrap(),
        )
        .unwrap();
    let mut tx = auth.begin(&state.pool).await.unwrap();
    sqlx::query("INSERT INTO provider_accounts(id,workspace_id,user_id,provider,email,encrypted_credentials) VALUES($1,$2,$3,'gmail',$4,$5)")
        .bind(id).bind(auth.workspace_id).bind(auth.user_id).bind(email).bind(sealed).execute(&mut *tx).await.unwrap();
    tx.commit().await.unwrap();
    id
}
fn content(account: Uuid) -> ops::DraftContent {
    ops::DraftContent {
        account_id: Some(account),
        to: vec![Address {
            name: Some("Recipient".into()),
            email: "recipient@example.test".into(),
        }],
        subject: "Exact reviewed subject".into(),
        text_body: "Original reviewed content".into(),
        ..Default::default()
    }
}
async fn message(state: &AppState, auth: &AuthContext, account: Uuid) -> Uuid {
    let id = Uuid::new_v4();
    let m = Message {
        id,
        account_id: account,
        provider_message_id: format!("provider-{id}"),
        provider_thread_id: "fixture-thread".into(),
        subject: "Fixture search subject".into(),
        from: Address {
            name: None,
            email: "sender@example.test".into(),
        },
        to: vec![],
        cc: vec![],
        bcc: vec![],
        text_body: "x".repeat(70_000),
        html_body: None,
        preview: "Fixture preview".into(),
        sent_at: Utc::now(),
        is_read: false,
        is_starred: false,
        mailbox: "inbox".into(),
        provider_labels: vec![],
        categories: vec![],
        delivery_headers: None,
        attachments: vec![],
        has_mailing_list_id: false,
        list_unsubscribe: vec![],
        list_unsubscribe_post: vec![],
        authentication_results: vec![],
        dkim_signatures: vec![],
        rfc_message_id: None,
        in_reply_to: None,
        references: vec![],
    };
    let mut tx = auth.begin(&state.pool).await.unwrap();
    sqlx::query("INSERT INTO mail_messages(id,workspace_id,user_id,account_id,provider_message_id,provider_thread_id,sent_at,normalized,search_text) VALUES($1,$2,$3,$4,$5,$6,$7,$8,'Fixture search subject')")
        .bind(id).bind(auth.workspace_id).bind(auth.user_id).bind(account).bind(&m.provider_message_id).bind(&m.provider_thread_id).bind(m.sent_at).bind(serde_json::to_value(m).unwrap()).execute(&mut *tx).await.unwrap();
    tx.commit().await.unwrap();
    id
}
async fn outbox_count(state: &AppState, auth: &AuthContext) -> i64 {
    let mut tx = auth.begin(&state.pool).await.unwrap();
    sqlx::query_scalar("SELECT count(*) FROM mail_outbox")
        .fetch_one(&mut *tx)
        .await
        .unwrap()
}

#[tokio::test]
async fn drafts_and_browser_approvals_preserve_exact_content_and_actor_scope() {
    let url = std::env::var("POSTMERE_TEST_DATABASE_URL")
        .expect("Set isolated non-bypass PostgreSQL test database URL");
    let pool = db::connect(&url).await.unwrap();
    db::migrate(&pool).await.unwrap();
    let state = AppState::new(pool.clone(), common::config(url))
        .await
        .unwrap();
    let workspace = Uuid::new_v4();
    let foreign = Uuid::new_v4();
    let auth = identity(&pool, workspace).await;
    let peer = identity(&pool, workspace).await;
    let outsider = identity(&pool, foreign).await;
    let account_id = account(&state, &auth, "owner@example.test").await;
    let second_account = account(&state, &auth, "second@example.test").await;
    let message_id = message(&state, &auth, account_id).await;
    assert_eq!(ops::list_accounts(&state, &auth).await.unwrap().len(), 2);
    assert!(ops::list_accounts(&state, &peer).await.unwrap().is_empty());
    let read = ops::read_message(&state, &auth, message_id).await.unwrap();
    assert!(read.body_truncated);
    assert_eq!(read.text_body.len(), 65_536);
    assert!(ops::read_message(&state, &peer, message_id).await.is_err());
    let page = ops::list_messages(
        &state,
        &auth,
        ops::ListMessagesInput {
            query: Some("Fixture".into()),
            limit: Some(500),
            ..Default::default()
        },
    )
    .await
    .unwrap();
    assert_eq!(page.messages.len(), 1);
    assert!(
        ops::list_messages(
            &state,
            &peer,
            ops::ListMessagesInput {
                account_id: Some(account_id),
                ..Default::default()
            }
        )
        .await
        .unwrap()
        .messages
        .is_empty()
    );
    for _ in 0..51 {
        message(&state, &auth, account_id).await;
    }
    let first_page = ops::list_messages(
        &state,
        &auth,
        ops::ListMessagesInput {
            limit: Some(500),
            ..Default::default()
        },
    )
    .await
    .unwrap();
    assert_eq!(first_page.messages.len(), 50);
    assert!(first_page.has_more);
    let metadata = serde_json::to_value(&first_page).unwrap();
    assert!(metadata["messages"][0].get("text_body").is_none());
    let second_page = ops::list_messages(
        &state,
        &auth,
        ops::ListMessagesInput {
            cursor: first_page.next_cursor,
            limit: Some(50),
            ..Default::default()
        },
    )
    .await
    .unwrap();
    assert_eq!(second_page.messages.len(), 2);
    assert!(!second_page.has_more);
    assert!(
        ops::list_messages(
            &state,
            &auth,
            ops::ListMessagesInput {
                query: Some("%".into()),
                ..Default::default()
            }
        )
        .await
        .unwrap()
        .messages
        .is_empty(),
        "cached search treats wildcard characters literally"
    );

    let incomplete = ops::create_draft(
        &state,
        &auth,
        ops::CreateDraft {
            request_id: Uuid::new_v4(),
            content: Default::default(),
        },
    )
    .await
    .unwrap();
    assert!(
        ops::request_approval(
            &state,
            &auth,
            ops::ApprovalInput::SendDraft {
                request_id: Uuid::new_v4(),
                draft_id: incomplete.id,
                expected_version: 1
            }
        )
        .await
        .is_err()
    );
    ops::delete_draft(&state, &auth, incomplete.id, 1)
        .await
        .unwrap();
    let request_id = Uuid::new_v4();
    let draft = ops::create_draft(
        &state,
        &auth,
        ops::CreateDraft {
            request_id,
            content: content(account_id),
        },
    )
    .await
    .unwrap();
    assert_eq!(
        ops::create_draft(
            &state,
            &auth,
            ops::CreateDraft {
                request_id,
                content: content(account_id)
            }
        )
        .await
        .unwrap()
        .id,
        draft.id
    );
    let mut changed = content(account_id);
    changed.text_body = "Edited after approval".into();
    assert!(
        ops::create_draft(
            &state,
            &auth,
            ops::CreateDraft {
                request_id,
                content: changed.clone()
            }
        )
        .await
        .is_err()
    );
    assert!(ops::get_draft(&state, &peer, draft.id).await.is_err());
    assert!(ops::get_draft(&state, &outsider, draft.id).await.is_err());
    assert!(ops::list_drafts(&state, &peer).await.unwrap().is_empty());
    assert!(
        ops::update_draft(
            &state,
            &auth,
            ops::UpdateDraft {
                draft_id: draft.id,
                expected_version: 2,
                content: changed.clone()
            }
        )
        .await
        .is_err()
    );

    let approval_request = Uuid::new_v4();
    let approval = ops::request_approval(
        &state,
        &auth,
        ops::ApprovalInput::SendDraft {
            request_id: approval_request,
            draft_id: draft.id,
            expected_version: 1,
        },
    )
    .await
    .unwrap();
    assert_eq!(approval.status, "pending");
    assert_eq!(
        outbox_count(&state, &auth).await,
        0,
        "requesting review never queues delivery"
    );
    assert_eq!(
        ops::request_approval(
            &state,
            &auth,
            ops::ApprovalInput::SendDraft {
                request_id: approval_request,
                draft_id: draft.id,
                expected_version: 1
            }
        )
        .await
        .unwrap()
        .id,
        approval.id
    );
    assert!(
        ops::request_approval(
            &state,
            &auth,
            ops::ApprovalInput::DisconnectAccount {
                request_id: approval_request,
                account_id
            }
        )
        .await
        .is_err()
    );
    for other in [&peer, &outsider] {
        assert!(ops::get_approval(&state, other, approval.id).await.is_err());
        assert!(
            ops::approve_action(&state, other, approval.id)
                .await
                .is_err()
        );
    }
    ops::update_draft(
        &state,
        &auth,
        ops::UpdateDraft {
            draft_id: draft.id,
            expected_version: 1,
            content: changed,
        },
    )
    .await
    .unwrap();
    let (one, two) = tokio::join!(
        ops::approve_action(&state, &auth, approval.id),
        ops::approve_action(&state, &auth, approval.id)
    );
    let one = one.unwrap();
    let two = two.unwrap();
    assert_eq!(one.status, "completed");
    assert_eq!(one.result, two.result);
    assert_eq!(outbox_count(&state, &auth).await, 1);
    let outbox_id: Uuid = serde_json::from_value(one.result.unwrap()["outbox_id"].clone()).unwrap();
    let mut tx = auth.begin(&pool).await.unwrap();
    let encrypted: Vec<u8> =
        sqlx::query_scalar("SELECT encrypted_payload FROM mail_outbox WHERE id=$1")
            .bind(outbox_id)
            .fetch_one(&mut *tx)
            .await
            .unwrap();
    let outgoing: Outgoing =
        serde_json::from_slice(&state.crypto.open(workspace, outbox_id, &encrypted).unwrap())
            .unwrap();
    assert_eq!(outgoing.text_body, "Original reviewed content");
    assert_eq!(outgoing.to[0].email, "recipient@example.test");
    assert_eq!(outgoing.client_id, approval.id);
    tx.commit().await.unwrap();
    assert_eq!(
        ops::cancel_outbox(&state, &auth, outbox_id)
            .await
            .unwrap()
            .status,
        "cancelled"
    );
    assert!(ops::cancel_outbox(&state, &peer, outbox_id).await.is_err());

    let trash = ops::request_approval(
        &state,
        &auth,
        ops::ApprovalInput::TrashMessage {
            request_id: Uuid::new_v4(),
            message_id,
        },
    )
    .await
    .unwrap();
    assert_eq!(
        ops::cancel_action(&state, &auth, trash.id)
            .await
            .unwrap()
            .status,
        "cancelled"
    );
    assert_eq!(
        ops::approve_action(&state, &auth, trash.id)
            .await
            .unwrap()
            .status,
        "cancelled",
        "a declined action cannot execute"
    );
    assert!(
        ops::manage_message(
            &state,
            &auth,
            ops::ManageMessageInput {
                message_id,
                is_read: None,
                is_starred: None,
                mailbox: Some("trash".into())
            }
        )
        .await
        .is_err(),
        "trash cannot bypass browser approval"
    );

    let trash = ops::request_approval(
        &state,
        &auth,
        ops::ApprovalInput::TrashMessage {
            request_id: Uuid::new_v4(),
            message_id,
        },
    )
    .await
    .unwrap();
    let transport = FixtureMutation::default();
    let (first, second) = tokio::join!(
        ops::approve_action_with(&state, &auth, trash.id, &transport),
        ops::approve_action_with(&state, &auth, trash.id, &transport)
    );
    first.unwrap();
    second.unwrap();
    assert_eq!(
        ops::get_approval(&state, &auth, trash.id)
            .await
            .unwrap()
            .status,
        "completed"
    );
    assert_eq!(
        transport.calls.load(Ordering::SeqCst),
        1,
        "concurrent approvals perform provider mutation once"
    );
    assert_eq!(
        ops::read_message(&state, &auth, message_id)
            .await
            .unwrap()
            .summary
            .mailbox,
        "trash"
    );
    let uncertain = ops::request_approval(
        &state,
        &auth,
        ops::ApprovalInput::TrashMessage {
            request_id: Uuid::new_v4(),
            message_id,
        },
    )
    .await
    .unwrap();
    let uncertain_transport = FixtureMutation {
        fail: true,
        ..Default::default()
    };
    assert_eq!(
        ops::approve_action_with(&state, &auth, uncertain.id, &uncertain_transport)
            .await
            .unwrap()
            .status,
        "uncertain"
    );
    assert_eq!(
        ops::approve_action_with(&state, &auth, uncertain.id, &uncertain_transport)
            .await
            .unwrap()
            .status,
        "uncertain"
    );
    assert_eq!(
        uncertain_transport.calls.load(Ordering::SeqCst),
        1,
        "ambiguous provider failures are never automatically repeated"
    );

    // Hold the exact approval row while its deadline passes. The executor must
    // re-read wall-clock expiry after the lock wait, before any queue insertion.
    let expiring = ops::request_approval(
        &state,
        &auth,
        ops::ApprovalInput::SendDraft {
            request_id: Uuid::new_v4(),
            draft_id: draft.id,
            expected_version: 2,
        },
    )
    .await
    .unwrap();
    let mut blocker = auth.begin(&pool).await.unwrap();
    sqlx::query("UPDATE mcp_mail_approvals SET expires_at=clock_timestamp()+interval '250 milliseconds' WHERE id=$1").bind(expiring.id).execute(&mut *blocker).await.unwrap();
    let pid: i32 = sqlx::query_scalar("SELECT pg_backend_pid()")
        .fetch_one(&mut *blocker)
        .await
        .unwrap();
    let state_copy = state.clone();
    let auth_copy = auth.clone();
    let id = expiring.id;
    let waiting =
        tokio::spawn(async move { ops::approve_action(&state_copy, &auth_copy, id).await });
    tokio::time::timeout(std::time::Duration::from_secs(5), async {
        loop {
            let blocked: bool = sqlx::query_scalar(
                "SELECT EXISTS(SELECT 1 FROM pg_stat_activity WHERE $1=ANY(pg_blocking_pids(pid)))",
            )
            .bind(pid)
            .fetch_one(&pool)
            .await
            .unwrap();
            if blocked {
                break;
            }
            tokio::time::sleep(std::time::Duration::from_millis(10)).await;
        }
    })
    .await
    .unwrap();
    tokio::time::sleep(std::time::Duration::from_millis(300)).await;
    blocker.commit().await.unwrap();
    assert_eq!(waiting.await.unwrap().unwrap().status, "expired");
    assert_eq!(outbox_count(&state, &auth).await, 1);

    let disconnect = ops::request_approval(
        &state,
        &auth,
        ops::ApprovalInput::DisconnectAccount {
            request_id: Uuid::new_v4(),
            account_id: second_account,
        },
    )
    .await
    .unwrap();
    assert_eq!(ops::list_accounts(&state, &auth).await.unwrap().len(), 2);
    assert_eq!(
        ops::approve_action(&state, &auth, disconnect.id)
            .await
            .unwrap()
            .status,
        "completed"
    );
    assert_eq!(
        ops::approve_action(&state, &auth, disconnect.id)
            .await
            .unwrap()
            .status,
        "completed"
    );
    let accounts = ops::list_accounts(&state, &auth).await.unwrap();
    assert_eq!(accounts.len(), 1);
    assert_eq!(accounts[0].id, account_id);

    sqlx::query("UPDATE memberships SET revoked_at=now() WHERE workspace_id=$1 AND user_id=$2")
        .bind(workspace)
        .bind(auth.user_id)
        .execute(&pool)
        .await
        .unwrap();
    assert!(ops::get_draft(&state, &auth, draft.id).await.is_err());
    assert!(
        ops::list_messages(&state, &auth, Default::default())
            .await
            .is_err()
    );
    assert!(
        ops::approve_action(&state, &auth, approval.id)
            .await
            .is_err()
    );
    let unscoped: i64 = sqlx::query_scalar("SELECT count(*) FROM mcp_mail_drafts")
        .fetch_one(&pool)
        .await
        .unwrap();
    assert_eq!(unscoped, 0, "forced RLS denies an unscoped connection");
    sqlx::query("DELETE FROM workspaces WHERE id=ANY($1)")
        .bind(vec![workspace, foreign])
        .execute(&pool)
        .await
        .unwrap();
    sqlx::query("DELETE FROM users WHERE id=ANY($1)")
        .bind(vec![auth.user_id, peer.user_id, outsider.user_id])
        .execute(&pool)
        .await
        .unwrap();
}
