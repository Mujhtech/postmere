# Postmere verification — 17 November 2026

See the [18 November follow-up](verification-2026-11-18.md) for the completed MCP, webhook, sender-screening and calendar updates.

The native macOS app, Rust server, and release container were built locally. Provider requests in automated tests use fixtures; verification did not send email, create calendar invitations, call a paid AI model, grant calendar permissions, or connect a real account.

## Native checks

The Xcode Debug build succeeds with code signing disabled. Native UI checks covered inbox tabs, command discovery, calendar navigation, workspace/account setup, the Previous local drafts recovery section, and empty-state layout. Required onboarding was checked in the main and Settings windows: incomplete or invalid sign-in stays blocked, and New Message, command-palette shortcuts, and mail commands cannot bypass setup. The public booking page was reviewed using sample availability from a temporary loopback-only preview.

The reader was checked at 320 and 820 points. Star updated the selected message, Snooze opened its scheduler, and Reply All addressed the sender and copied the other participant. Direct messages, drafts, and queued mail each showed their applicable actions.

Workspace setup was exercised at 440 and 1,050 points. An invalid server address or workspace ID focused the corresponding field. A rejected sign-in cleared the submitted password. After a successful simulated sign-in, the empty inbox offered one account setup action, which opened the Google and Outlook choices in Accounts settings.

All 72 custom symbols were rendered at 12, 16, and 24 points in both appearances. In native inbox captures, the Filter glyph's contrast against its dark background rose from 1.26:1 to 16.67:1. With a filter active, the inbox also displayed its name and a Clear action. Calendar and Snippets empty-state icons improved from 2.25:1 to 5.86:1. Native checks also covered the command palette, inbox selection, reader controls, attachment library, all six Settings tabs, composer and formatting menus, the attachment button, and the onboarding error icon.

Offline suites pass:

- `script/test.sh mail_backend`: search, Split Inbox/VIPs, persistence, account isolation, scoped sync cursors/deletions, remote queue ownership, stopped legacy sends and explicit draft recovery, preservation of interrupted-delivery warnings and inactive-workspace recovered drafts, idempotency, early Sent synchronization, historical-import notification suppression, offline arrivals, and bounded file uploads.
- `script/test.sh templates signatures composer`: rich content, placeholders, files, signature preferences, formatting, and native Undo/Redo, including AI replacement.
- `script/test.sh unsubscribe`: header/URL parsing, transport restrictions, and workspace message mapping and refusal to trust copied authentication headers.
- `script/test.sh calendar`: dates, time zones/DST, conflicts, invitation parsing, and permission gates.
- `script/test.sh sender_context notifications attachment_types`: scoped contacts/notes, scheduling/Focus across 32 accounts, cancellation during sign-out races, foreground presentation after Focus lookup, and file types.
- `script/test.sh backend_client backend_session`: HTTPS policy, bounded responses, explicit authentication, redirect rejection, credential lifecycle, mandatory workspace access during sign-in/restoration, immediate lock on logout/expiry, 32 independent account identities, repeated additions, targeted reconnect/disconnect, and stale-response races. All credentials are in memory and HTTP traffic is intercepted.
- `script/test.sh backend_events backend_push`: bounded SSE parsing, reconnect/backoff, event coalescing and stale-session cancellation; every APNs token callback, no token reuse after logout, 300 account preferences, local screening rules, scoped notification links and logout deregistration. A transient unknown device status defers local alerts until delivery ownership is resolved. Notification regressions also cover APNs/local transitions and Focus races.

After realtime and push integration, all six affected native suites passed and the final unsigned Debug build completed without warnings or errors. The app was not launched or restarted during these checks; APNs and notification-center calls use fixtures.

The persistent sign-in update also passes all six affected suites and an unsigned Debug build with no warnings or errors. Coverage includes session and APNs ownership beyond 24 hours, server-verified migration of old cached deadlines, automatic network/408/429/503 reconnects, token-matching Keychain updates, durable offline sign-out, Keychain failure recovery, and signing out while an expired legacy session is being verified. Pending revocations cannot restore an old login or clear a newer one. Tests use in-memory credential stores and intercepted HTTP.

## Server checks

After the [crate workspace refactor](../server/ARCHITECTURE.md), remote MCP, notifications and persistent sign-in implementations, `cargo test --workspace --locked` passes all 53 tests, with no ignored tests or warnings. This includes 34 unit tests across the library crates and 19 integration tests. Database tests use a real isolated PostgreSQL instance under a non-superuser role without RLS bypass. Coverage includes:

- Session authentication, rotation, expiry, role/membership revocation, encryption integrity, forced row security, and shared rate limits.
- Persistent native sessions and notification registrations at simulated ages of 2, 45 and 400 days, service restart, token rotation without lost push consent, and actual logout cancelling queued/future alerts. Migration tests upgrade only valid native sessions, preserve bounded browser sessions, reject malformed lifetime pairs and never revive revoked or expired access. A rotation that crosses a bounded session's expiry while waiting for a device lock rolls back completely.
- Provider OAuth state/PKCE, 24 mixed Google/Microsoft account identities, concurrent reconnect callbacks, independent disconnect, account/message/file boundaries, mailbox synchronization, fair bounded sync workers and cancellation, cursor continuity, durable delivery, duplicate prevention, and tracking consent/scope.
- Shared snapshots, comments/templates, version conflicts, reply presence, and member-revocation races while database locks are held.
- AI opt-in, connected-account retrieval, source validation, and ensuring suggested actions target their displayed citations.
- Booking races across different links for one host, idempotency, ambiguous event creation, encrypted guest data, RSVP verification, and final authorization after delayed availability reads.
- Actual cryptographically signed MIME fixtures and tampering attempts, raw-message/resource bounds, public-address validation, pinned DNS, and isolated unsubscribe POSTs.
- Remote MCP initialization and tool calls, required scopes, dedicated token types, origin/host and body bounds, scoped drafts and mail operations, and denial of client self-approval.
- Browser OAuth/PKCE, exact callback allowlists, resource/client binding, hashed token storage, refresh rotation/replay, scope reduction, session/membership revocation, and grant/identity lock ordering and expiry races.
- Immutable send/trash/disconnect reviews, actor/workspace isolation, browser CSRF and Origin, read-only review GETs, concurrent/idempotent consent, no queue before approval, fixture-only delivery/mutations, bounded message summaries, and preventing content disclosure through action scopes.
- Committed SSE invalidations, cross-user isolation, cursor catch-up, bounded stream counts, lag recovery, authorization revocation, cache-only refresh and graceful shutdown.
- Encrypted APNs tokens, account preferences and quiet hours/DST, real ES256 signature verification and JWT reuse, historical-import suppression, 129-account registration, cross-workspace token rebinding, duplicate prevention, ambiguous outcomes, APNs invalid-token timestamps, lock ordering and expiry during a blocked registration. Apple delivery is replaced with a test transport.

`cargo check --workspace --all-targets --locked` and `cargo fmt --all -- --check` pass. All fourteen crates are default test members and inherit the workspace's prohibition on unsafe code. The MCP integration adds the official `rmcp` SDK pinned at 3.11.0 and records its dependencies in Cargo.lock. The Docker release image uses Rust 1.96, embeds booking and MCP approval assets, and runs as an unprivileged user. An unconfigured executable rejects startup instead of enabling a default account or secret.

MCP approval pages were visually checked at 390px and 1280px using the actual rendered fixture HTML. Review covers recipients, content, attachments, reply headers, schedule, undo and tracking; no approval was clicked in the browser. A final targeted browser-approval regression passed after the authentication-race redirect adjustment.

The Docker Compose setup was exercised with an isolated fresh database: private configuration generation, refusing overwrite, separate migration/runtime roles, forced password authentication over the shared Unix socket, migrations, first-owner bootstrap, backend startup, health, OAuth discovery, MCP authentication, fixture sign-in, disabled-APNs status and authenticated SSE all passed. Caddy configuration validation passed. A temporary internal-CA certificate and private container network verified HTTPS forwarding and five consecutive SSE disconnect/reconnect cycles without leaking the four-stream allowance. No public listeners, ACME certificate request or deployment were created by that check.

The final persistent-session release image applied all twelve migrations to a fresh Compose database and passed startup, sign-in, identity metadata and SSE checks. Login and `/v1/auth/me` reported persistent sessions with null expiry fields. Temporary test containers and database volumes were removed afterward.

## Remaining external verification

A production host, TLS, database/storage protection, secret management, provider OAuth registrations/consent, and optional OpenAI configuration are deployment work. Live account synchronization, delivery, RSVP, public booking access, and AI responses have not been exercised with real credentials. Follow [server setup](../server/README.md) before connecting accounts.

The public ChatGPT/other-client OAuth connection still needs validation against the deployed HTTPS origin and configured callback allowlist; see [remote MCP setup](remote-mcp.md). Automated tests exercise the protocol and OAuth routes locally and never connect a real mailbox.

Real APNs delivery requires an Apple signing key, enabled App ID/provisioning and a signed app, plus notification permission. Those were not exercised. Native sessions and registrations have no automatic expiry; alerts remain best effort, and synced sender policies apply to remote delivery while the app is closed. The 24-hour queue lifetime applies to each individual message, not the device registration. Configured provider callbacks trigger durable sync hints; polling about once a minute remains a fallback. See the [deployment and APNs guide](../server/deploy/README.md).

Booking checks cover selected provider calendars; concurrent edits made directly in an external calendar cannot share the server's database lock. Booking cancellation and status reconciliation use stable provider identities. Uncertain event creation or delivery is not automatically repeated. One-click unsubscribe is offered only after server-side raw DKIM verification succeeds. These checks provide evidence for the implemented boundaries, not a guarantee of absolute security.
