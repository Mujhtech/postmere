# Verification — 18 November 2026

This update closes the four code gaps listed after the persistent native sign-in work: MCP connection lifetime, provider notifications, server notification screening, and calendar workflows. Deployment and live provider testing remain separate.

## Implemented behavior

- MCP authorizations persist independently of browser-login expiry. Access tokens expire within 15 minutes and rotating refresh tokens keep the connection active until sign-out or revocation. Migration 0013 upgrades only currently valid authorizations. Connected assistants can be viewed and individually revoked from the browser page linked in Settings → Accounts.
- Offline native sign-out saves its original timestamp. Retrying it revokes existing workspace MCP connections while preserving later authorizations; canceled login cleanup does not revoke assistants.
- Gmail authenticated Pub/Sub and Microsoft Graph callbacks schedule durable sync hints. Watches/subscriptions renew, recover interrupted creation, and stop on disconnection. Polling remains a fallback. A callback arriving during a provider fetch survives that sync's commit.
- Versioned sender policies are encrypted and evaluated on the server before APNs delivery. Account-scoped, ordered rules cover unknown-sender screening and Inbox, Needs Reply, Archive and Blocked routes. Preference updates can use PATCH before another APNs token callback. The Mac preserves confirmed delivery ownership while retries are pending.
- Booking links select a writable destination and up to eight conflict calendars, with explicit times or bounded weekly hours in an IANA time zone. Sharing respects calendar selection. Cancellation and status checks use stable provider identities and do not repeat an uncertain event creation.

## Local checks

The affected native suites pass: `backend_push`, `backend_session`, `notifications`, `mail_backend`, `backend_client`, `backend_events`, and `calendar`. The combined unsigned macOS Debug build succeeds without warnings or errors. The updated app was not launched against the user's workspace.

`cargo test --workspace --locked` passes all **72 tests**: 43 unit tests and 29 PostgreSQL/API integration tests, with no failures, ignored tests or warnings. `cargo check --workspace --all-targets --locked`, workspace formatting and `git diff --check` also pass.

Server coverage includes persistent MCP refresh after browser expiry and 400-day-old authorization, refresh replay, scoped revocation, offline sign-out ordering, migration exclusions, signed JWT rejection, provider callback identity/replay, subscription lifecycle recovery, encrypted sender-policy enforcement, DST/weekly bounds, selected calendars, cancellation/reconciliation, and authorization changes during provider waits. Sync/disconnect and booking-lock regressions exercise actual PostgreSQL contention.

The final Docker release image builds and starts as the non-root runtime user. A fresh isolated Compose database applied all **16 migrations** and passed owner bootstrap, readiness, OAuth metadata, MCP authentication, persistent native sign-in, connected-assistant listing, sender-policy capability and authenticated SSE checks. The temporary containers and volumes were removed afterward.

The connected-assistants page was visually checked using rendered local fixture HTML. Browser tests cover escaped client names and CSRF/origin checks for revocation and sign-out.

## Deployment and live checks

Apply migrations through 0016 and deploy the updated server and Mac app together, following the [deployment guide](../server/deploy/README.md). Provider notifications need the [documented Google or Microsoft configuration](../server/crates/postmere-webhooks/README.md). MCP client setup is documented in the [remote MCP guide](remote-mcp.md).

Automated provider tests use local fixtures. No live watches, cloud Pub/Sub resources, invitations, mail, APNs alerts or external deployments were created. Public OAuth, configured provider delivery, signed-app APNs delivery, and operational backups/monitoring still require verification in the deployment.

A provider calendar can change outside Postmere between availability checking and event creation. An uncertain creation with no matching provider event remains reserved; an empty lookup alone does not prove that creation never happened. APNs delivery is best effort, and offline notification preference changes take effect remotely after successful synchronization.
