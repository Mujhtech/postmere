# Postmere verification — 17 November 2026

The native macOS app, Rust server, and release container were built locally. Provider requests in automated tests use fixtures; verification did not send email, create calendar invitations, call a paid AI model, grant calendar permissions, or connect a real account.

## Native checks

The Xcode Debug build succeeds with code signing disabled. Native UI checks covered inbox tabs, command discovery, calendar navigation, workspace/account setup, and empty-state layout. The public booking page was reviewed using sample availability from a temporary loopback-only preview.

Offline suites pass:

- `script/test_mail_backend.sh`: search, Split Inbox/VIPs, persistence, account isolation, scoped sync cursors/deletions, remote queue ownership, idempotency, early Sent synchronization, historical-import notification suppression, offline arrivals, and bounded file uploads.
- `script/test_gmail_provider.sh`: provider parsing, token handling, pagination, MIME, safe retries, and independent MIME parsing.
- `script/test_templates.sh`, `test_signatures.sh`, and `test_composer.sh`: rich content, placeholders, files, signature preferences, formatting, and native Undo/Redo, including AI replacement.
- `script/test_unsubscribe.sh`: header/URL parsing, transport restrictions, and refusal to trust copied authentication headers for direct Gmail.
- `script/test_calendar.sh`: dates, time zones/DST, conflicts, invitation parsing, and permission gates.
- `script/test_sender_context.sh`, `test_notifications.sh`, and `test_attachment_types.sh`: scoped contacts/notes, scheduling/Focus, and file types.
- `script/test_backend_client.sh`, `test_backend_session.sh`: HTTPS policy, bounded responses, explicit authentication, redirect rejection, credential lifecycle, and stale-response races. All credentials are in memory and HTTP traffic is intercepted.

## Server checks

After the [crate workspace refactor](../server/ARCHITECTURE.md), `cargo test --workspace --locked` passes all 39 tests, with no ignored tests. This includes 31 unit tests across the library crates and eight integration tests. Database tests use a real isolated PostgreSQL instance under a non-superuser role without RLS bypass. Coverage includes:

- Session authentication, rotation, expiry, role/membership revocation, encryption integrity, forced row security, and shared rate limits.
- Provider OAuth state/PKCE, account/message/file boundaries, mailbox synchronization, cursor continuity, durable delivery, duplicate prevention, and tracking consent/scope.
- Shared snapshots, comments/templates, version conflicts, reply presence, and member-revocation races while database locks are held.
- AI opt-in, connected-account retrieval, source validation, and ensuring suggested actions target their displayed citations.
- Booking races across different links for one host, idempotency, ambiguous event creation, encrypted guest data, RSVP verification, and final authorization after delayed availability reads.
- Actual cryptographically signed MIME fixtures and tampering attempts, raw-message/resource bounds, public-address validation, pinned DNS, and isolated unsubscribe POSTs.

`cargo check --workspace --all-targets --locked` and `cargo fmt --all -- --check` pass. Cargo metadata confirms that all nine crates are default test members and inherit the workspace's prohibition on unsafe code. External dependency versions and checksums are unchanged by the extraction. The Docker release image is built with Rust 1.96, includes booking assets, and runs as an unprivileged user. An unconfigured executable rejects startup instead of enabling a default account or secret.

## Remaining external verification

A production host, TLS, database/storage protection, secret management, provider OAuth registrations/consent, and optional OpenAI configuration are deployment work. Live account synchronization, delivery, RSVP, public booking access, and AI responses have not been exercised with real credentials. Follow [server setup](../server/README.md) before connecting accounts.

Booking checks cover the primary provider calendar; concurrent edits made directly in an external calendar cannot share the server's database lock. Uncertain booking or delivery outcomes require review and are not automatically repeated. Direct Gmail uses manual unsubscribe options; workspace one-click is offered only after raw DKIM verification succeeds. These checks provide evidence for the implemented boundaries, not a guarantee of absolute security.
