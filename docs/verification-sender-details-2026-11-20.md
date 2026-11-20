# Sender details verification — 20 November 2026

Sender details now use the existing OpenAI integration with web search and
appear in a collapsible panel beside the message. The lookup sends the selected
sender's name and address, without the message body or conversation history.
Available facts and social/site links retain their public sources. There is no
new database migration or separate enrichment-provider key.

## Checks completed

- **20 AI unit tests passed**, including nine sender-research tests covering
  required live search, evidence-backed fields, useful partial profiles,
  fabricated or private URLs, consumer email domains, exact public matches for
  personal `hello@`/`contact@` addresses, incomplete/refused output,
  and bounded cache/refresh behavior.
- **Six server tests passed**: the AI deadline check, existing AI authorization
  regression, and four new sender-profile database tests. These exercise
  workspace/user/account isolation, consent and configuration states, envelope
  minimization, request coalescing, and authorization changes during provider
  waits. Logout, revoked membership, disconnected/reconnect-required accounts,
  AI opt-out, and deleted messages cannot return an in-flight profile.
- **Three native suites passed**: `sender_profile`, `sender_context`, and
  `backend_client`. Coverage includes selected-message transport, scope changes,
  cancellation, stale-result rejection, response/address binding, source links,
  and revalidating with the server on each selection. The final link regression
  keeps an independently sourced LinkedIn URL when an employer page supplies its
  supporting citation, while excluding an invented link absent from sources.
- **Unsigned Debug Mac build passed**, including the reader split, inline AI
  enable action, matching toolbar icons, and content-based window minimum size.
- **Workspace compilation and formatting checks passed.**
- **Release Docker image built successfully** as `postmere-server:local`.
  Running services were not restarted.
- **Caddy configuration validation passed**, including the longer response-header
  timeout for sender research.
- **Synthetic layout previews inspected** in light/dark appearances and at
  725-point and 661-point reader widths. The message and profile remain side by
  side, and citations and social links remain readable.

## Reproduce

From the repository root:

```sh
./script/test.sh sender_profile sender_context backend_client
```

From `server/`, configure `POSTMERE_TEST_DATABASE_URL` for a disposable,
non-superuser PostgreSQL database with `NOBYPASSRLS`, then run:

```sh
cargo test --locked -p postmere-ai
cargo test --locked -p postmere-server --lib --test ai_security --test sender_profile
cargo check --locked --workspace --all-targets
cargo fmt --all -- --check
```

Provider responses were intercepted or replaced with deterministic fixtures;
no live sender research, mail delivery, or provider account mutation was used
for verification. Previews contain sample data. Actual profile coverage and
model access require the configured OpenAI account and available public sources.
