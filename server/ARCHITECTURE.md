# Server architecture

Postmere is one Rust service built from fifteen workspace crates. Feature crates
call each other through typed Rust APIs in the same process and share one
`AppState` and PostgreSQL pool.

## Crates and dependency graph

The table lists every direct workspace dependency. Dependency names omit the
`postmere-` prefix; external libraries are declared separately in the manifests.

| Crate | Responsibility | Direct workspace dependencies |
| --- | --- | --- |
| `postmere-core` | Authentication, configuration, credential encryption, errors, scoped database access, generic tokens, and `AppState` | None |
| `postmere-providers` | Google/Microsoft mail adapters, OAuth, normalized mail types, MIME, and provider validation | core |
| `postmere-tracking` | Opt-in open/link instrumentation, public tracking endpoints, and activity queries | core, providers |
| `postmere-mail` | Account ownership, OAuth orchestration, cached mail, synchronization, and durable delivery | core, providers, tracking |
| `postmere-calendar` | Booking links/reservations, free/busy sharing, invitations, calendar adapters, and booking assets | core, providers, mail |
| `postmere-collaboration` | Workspace members, shared thread snapshots, comments, presence, and templates | core, providers |
| `postmere-ai` | AI consent/settings, scoped mail retrieval, public sender web research, provider requests, and validated suggestions | core |
| `postmere-unsubscribe` | Raw DKIM verification and consent-bound unsubscribe requests with restricted networking | core, providers, mail |
| `postmere-mcp-auth` | MCP OAuth metadata, registration, browser authentication/consent, scoped tokens, rotation and revocation | core |
| `postmere-mcp-operations` | Versioned encrypted drafts, typed mail operations, immutable approval records and execution | core, providers, mail |
| `postmere-mcp` | Official MCP SDK transport, tool schemas, scope enforcement, browser action-review pages and assets | core, providers, mcp-auth, mcp-operations |
| `postmere-realtime` | Authenticated SSE, bounded subscriber queues, PostgreSQL invalidations, and shutdown signaling | core |
| `postmere-push` | APNs device registration, account preferences, durable alert queue, signing and delivery | core, mail |
| `postmere-webhooks` | Authenticated Gmail/Graph callbacks, subscription renewal and durable sync hints | core, mail, providers |
| `postmere-server` | HTTP composition, executable commands, worker lifecycle, and integration tests | core, tracking, mail, calendar, collaboration, ai, unsubscribe, mcp, mcp-auth, realtime, push, webhooks; providers and mcp-operations for tests |

This graph is acyclic. Core has no feature dependencies. Providers depend only
on core; features build on these shared types and services. The executable is
the composition root, and feature crates never depend on it.

## Boundary decisions

Core groups authentication with configuration, encryption, database scope, and
state because authentication extracts `AppState` while state owns `AuthService`.
Keeping this shared security foundation together avoids a crate dependency cycle.
`AppState` also owns the fixed-origin HTTP client; unsubscribe retains its own
restricted client for sender-controlled destinations.

Mail and synchronization remain two modules in `postmere-mail`. They share
account sessions, provider classification, cache writes, and transaction locks.
Their mutual calls stay internal to one crate, including helpers with
`pub(crate)` visibility.

Generic random-token generation, scoped-token parsing, and hashing live in
`postmere-core::tokens`. Tracking uses these helpers directly. Mail can therefore
call tracking to prepare a send without creating a tracking-to-mail dependency.

Calendar provider adapters stay in `postmere-calendar` because they use mail's
owned `AccountSession`. Its `static/` directory owns the booking HTML, CSS, and
JavaScript embedded with `include_str!`; the server routes serve those assets.

## Database and composition

Ordered SQL migrations remain centralized in `server/migrations/`. Core embeds
that directory through `sqlx::migrate!`; its build script tracks migration changes.
The crate split leaves the schema, transaction-local workspace/user scope,
forced row-level security, and runtime-role checks unchanged.

`postmere-server::feature_routes()` combines feature routers. `application()`
adds authentication routes, health checks, request limits, timeouts, and common
response headers. The `serve` command creates shared state, starts the mail
delivery and synchronization workers plus the optional APNs worker, and serves
the combined router. Shutdown closes SSE streams before draining HTTP, then
stops the workers. `migrate` and `bootstrap` remain executable
commands using core services.

## Build and verification

The workspace declares Rust 1.96 as its minimum. Run these commands from `server/`:

```sh
cargo build --locked -p postmere-server
cargo run --locked -p postmere-server -- serve
cargo check --locked --workspace --all-targets
cargo test --locked --workspace
cargo fmt --all -- --check
```

Serving requires the configuration described in [README.md](README.md). Database
tests require `POSTMERE_TEST_DATABASE_URL` for an isolated PostgreSQL database
whose role has `NOSUPERUSER NOBYPASSRLS` and can apply migrations. Missing test
configuration fails the database tests. All fourteen crates are default members;
the explicit `--workspace` command also makes member-unit coverage clear.
Integration tests remain in `server/tests/` and import each owning crate directly.

## Adding a feature

Add its crate under `crates/`, declare its workspace dependency in the root
manifest, and inherit workspace package metadata, dependencies, and lints.
Depend only on the crates whose APIs it uses; preserve the graph above and keep
core independent of features. Extract a shared primitive into a crate both
callers can depend on if a proposed edge would create a cycle. Keep implementation helpers
private and expose the typed API needed by callers.

Register the router in `feature_routes()` and any worker lifecycle in `main.rs`.
Add schema changes to the central migration sequence, keep feature assets with
their crate, and add unit tests beside the implementation plus integration tests
for cross-feature or database behavior. Run the workspace checks above and
update this dependency table when introducing an edge or crate.
