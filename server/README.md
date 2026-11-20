# Postmere server

Built and verified with Rust 1.96 and PostgreSQL 17; the schema supports PostgreSQL 16+. From this directory, build with `cargo build --locked -p postmere-server`.
This service hosts the workspace API; the desktop client keeps its bearer token
in Keychain. No account, password, or provider access is enabled by default.

The backend is a Cargo workspace with thirteen library crates and a small server
crate that composes their routers and workers. See [the architecture guide](ARCHITECTURE.md)
for crate ownership, dependency boundaries, and how to add features.

For a self-hosted stack, use the included [Docker Compose setup](deploy/README.md)
with PostgreSQL, automatic migrations, Caddy HTTPS, ChatGPT OAuth callbacks,
and optional Apple push notifications.

## Configuration

Provide secrets through your deployment secret manager; do not commit them:

| Variable | Purpose |
| --- | --- |
| `DATABASE_URL` | PostgreSQL connection URL. Remote databases require `sslmode=verify-full`; loopback and Unix sockets are allowed for local development. |
| `POSTMERE_PUBLIC_URL` | Public HTTPS origin; HTTP is accepted only on loopback for development. |
| `POSTMERE_BIND` | Bind address; default `127.0.0.1:8080`. Containers normally use `0.0.0.0:8080`. |
| `POSTMERE_MCP_REDIRECT_URIS` | JSON array of exact allowed MCP client OAuth callbacks. Defaults to `[]`, which disables new registrations. See [remote MCP setup](../docs/remote-mcp.md). |
| `POSTMERE_CREDENTIAL_KEYS` | JSON object mapping integer key IDs to independent base64-encoded 32-byte keys. |
| `POSTMERE_ACTIVE_CREDENTIAL_KEY` | Key ID used for new encrypted credentials. |
| `POSTMERE_RATE_LIMIT_KEY` | Separate base64-encoded 32-byte secret for private rate-limit identities. |
| `GOOGLE_CLIENT_ID`, `GOOGLE_CLIENT_SECRET` | Optional Google OAuth web application credentials. |
| `MICROSOFT_CLIENT_ID`, `MICROSOFT_CLIENT_SECRET` | Optional Microsoft confidential web application credentials. |
| `MICROSOFT_TENANT` | Microsoft tenant ID/domain; default `common`. |
| `POSTMERE_GMAIL_PUBSUB_TOPIC`, `POSTMERE_GMAIL_PUBSUB_SUBSCRIPTION`, `POSTMERE_GMAIL_PUSH_AUDIENCE`, `POSTMERE_GMAIL_PUSH_SERVICE_ACCOUNT` | Optional Gmail authenticated Pub/Sub delivery; configure all four together. |
| `POSTMERE_MICROSOFT_WEBHOOKS` | Set `true` to maintain Microsoft mail subscriptions. Requires public HTTPS. |
| `OPENAI_API_KEY`, `POSTMERE_AI_MODEL` | Optional AI provider configuration; user opt-in is separate. |
| `POSTMERE_DECISION_URL`, `POSTMERE_DECISION_TOKEN` | Optional HTTPS endpoint and bearer token for a spam analyzer, used in preference to OpenAI for explicit spam checks. |
| `POSTMERE_APNS_KEY_FILE`, `POSTMERE_APNS_KEY_ID`, `POSTMERE_APNS_TEAM_ID` | Optional server-only APNs `.p8` signing key path and Apple key/team identifiers. Configure all APNs values together. |
| `POSTMERE_APNS_TOPIC`, `POSTMERE_APNS_ENVIRONMENT` | Signed app bundle ID and `sandbox` or `production`; these must match the app's provisioning. |

Generate independent keys using a cryptographically secure random generator.
Retain old credential keys during rotation: add a new key ID, make it active,
then re-encrypt stored envelopes before retiring old keys. Removing a key before
its data has been migrated makes those credentials unreadable. Back up the
keyring separately from database backups.

## Remote MCP

`/mcp` serves authenticated Streamable HTTP using the official Rust MCP SDK.
ChatGPT and other OAuth clients can read/search cached mail, maintain drafts,
manage mailbox state, and request sending. Send, trash, and account-disconnect
requests require explicit browser approval of the exact saved action. The MCP
client has no approval tool. See [setup, permissions, and limits](../docs/remote-mcp.md).

## Realtime updates and Apple push

`GET /v1/events` provides an authenticated SSE stream of committed account,
mail and outbox changes. The Mac app coalesces updates and refreshes the server
cache without launching a provider sync for every event. Reconnects catch up from
durable mail cursors; the stream itself is not an event history. See the
[event contract](crates/postmere-realtime/README.md). Authenticated Gmail Pub/Sub
and Microsoft Graph callbacks queue durable account sync hints. The subscription
worker renews watches and reconciles interrupted registrations. Polling about
every 60 seconds remains a fallback. See [provider notification setup](crates/postmere-webhooks/README.md).

Optional APNs alerts can arrive when the Mac app is closed. Device registration
uses `GET`, `PUT`, `PATCH`, and `DELETE /v1/push/devices/{installation_id}` under the native
workspace session. Tokens are encrypted, scoped to the current user/workspace,
and rebound when the same device changes identity. Alerts are queued for new,
unread Inbox messages arriving after consent, account connection and registration.
Historical imports and the user's own outgoing messages do not create alerts.

The server honors per-account notification schedules, time zone and subject
preview preferences. APNs receives a generic title and optional subject, with
account-specific Focus filter criteria. Local reminders remain local. Versioned,
encrypted sender policies apply the same account-scoped first-match rules as
the Mac app: Inbox and Needs Reply allow unread Inbox alerts; Archive, Blocked,
and screened unknown senders suppress them. `PATCH` updates preferences without
waiting for a new APNs token callback. The app preserves the last server-confirmed
delivery ownership while updates retry, preventing duplicate local alerts.
Older servers retain local screening until they advertise policy support.

Native registrations have no time-based expiry. They stop at logout, access
revocation, account disconnection or when notifications are disabled. APNs
delivery is best effort, and macOS can delay presentation while asleep or in
Focus. Each individual mail alert expires after 24 hours to avoid delivering
stale mail notifications; that limit does not expire the registration or stop
future alerts. The queue does not retry ambiguous delivery outcomes. Follow the
[APNs deployment steps](deploy/README.md#apple-push-notifications) for credentials,
provisioning and a real device check.

## Database and first owner

The runtime role **must have `NOSUPERUSER NOBYPASSRLS`**. Startup rejects roles
that bypass row security. Use a separate migration role in production and grant
the runtime role only schema usage plus required table DML. `FORCE ROW LEVEL
SECURITY` also protects tables when the development role owns them.

Run `cargo run --locked -p postmere-server -- migrate` with the migration connection, then switch
to the runtime connection. Create the initial workspace with
`cargo run --locked -p postmere-server -- bootstrap owner@example.com 'My workspace'` and pipe a
12–1024-byte password from a protected file or password manager into stdin.
Interactive plaintext entry is rejected. The command prints the workspace UUID,
which the desktop sign-in screen requires. It never prints the password.

Run `cargo run --locked -p postmere-server -- serve`. `/health/live` checks the process and
`/health/ready` checks database connectivity. Deploy behind TLS with request-size
and connection limits. Bind the service only to trusted ingress. Client IP
limits use the actual TCP peer; spoofable forwarding headers are ignored.

## Authentication and storage boundaries

`POST /v1/auth/login` accepts `{email,password,workspace_id}` and returns an opaque
bearer token, session/user/workspace IDs and role. Native sessions are persistent:
`expires_at` and `absolute_expires_at` are both `null`, with no idle or absolute
timeout. `GET /v1/auth/me` reports both lifetime fields and `persistent`, so an
updated client can refresh previously cached expiry metadata after migration.
Send `Authorization: Bearer <token>` on authenticated calls.

`POST /v1/auth/rotate` replaces the old token and preserves the session's lifetime
mode. Logout revokes the current token and existing MCP connections in that
workspace; logout-all revokes all of the user's sessions. User, workspace, and
membership revocation are checked on every authenticated request. Native tokens
remain in Keychain until sign-out or invalidation. Browser cookies, authorization
codes and access tokens remain short-lived; each MCP grant has its own persistent
session and rotating refresh tokens, independent of the browser login.

`POST /v1/auth/logout` accepts optional `{signed_out_at,revoke_mcp}`. Native clients
persist the original RFC3339 sign-out timestamp for offline retries, preserving
MCP grants created afterward. `revoke_mcp:false` is for canceled/failed-login
credential cleanup, not an intentional workspace sign-out. Omitted fields mean
current-time sign-out including MCP revocation.

Migration `0011` upgrades still-valid native sessions without changing their
tokens. It does not revive expired or revoked sessions, or extend browser OAuth
sessions. Deploy the updated Mac app with the server so it can read the nullable
expiry fields and replace its old cached deadlines.

Passwords use Argon2id. Session tokens have 256 bits of randomness and only their
SHA-256 hashes are stored. Login identity and TCP-peer rate limits are shared in
PostgreSQL and remain effective across instances/restarts. Password hashing is
concurrency-limited. Authentication failures do not reveal which identity exists.

Provider credentials use versioned AES-256-GCM envelopes with a fresh nonce for
every write; workspace and resource IDs are authenticated additional data.
Copying ciphertext to another workspace or account fails authentication.
Feature tables use transaction-local workspace/user scope and forced RLS. Never
use `scoped_transaction` with arbitrary user input unless a service job or
one-time OAuth nonce has independently established the identity.

No provider body, SQL statement, password, bearer token, OAuth code, or credential
is included in public errors. Configure reverse-proxy logs to omit authorization
headers and OAuth callback query strings. Data backups and storage volumes should
be encrypted and access controlled by the deployment.

## Verification

Use an isolated test database and export `POSTMERE_TEST_DATABASE_URL` with a
non-superuser, NOBYPASSRLS role that can apply migrations. Then run
`cargo test --workspace --locked`. All crates are also default workspace members,
so plain `cargo test` includes their unit tests. The integration tests fail when the required database is
not configured; they do not silently skip security checks. Tests use unique
fixture identities and exercise actual PostgreSQL RLS, not a mocked database.

Cryptography tests cover tenant/resource binding, envelope tampering, nonce
uniqueness, and key rotation. Authentication tests cover invalid credentials,
wrong workspace, concurrent rotation, expiry, logout, logout-all, membership
revocation, same-workspace cross-user access, missing scope, forbidden writes,
and rate-limit persistence.

## Collaboration API

Thread sharing is an explicit snapshot of up to 100 cached messages / 10 MiB.
It does not grant access to the owner's mailbox or provider credentials. Bcc,
unsubscribe/authentication metadata and attachment bodies are removed from
shared thread snapshots; file names remain visible. New private replies are
published only when the owner explicitly refreshes the snapshot. Shared
templates separately support actual file contents and RTF formatting.

| Route | Behavior |
| --- | --- |
| `GET /v1/workspace/members` | Active members of the authenticated workspace. |
| `POST /v1/workspace/members` | Owner/admin provisions a new user with `{email,initial_password,role}`. Only an owner can create an admin. Existing emails conflict; passwords are never reset. No email is sent. |
| `DELETE /v1/workspace/members/{id}` | Owner/admin revokes a member and their workspace sessions; owner/self revocation is rejected. |
| `GET, POST /v1/shared/threads` | List visible shares or create `{account_id,provider_thread_id,members:[{user_id,permission}]}`. Permissions are `view` or `comment`. |
| `GET, DELETE /v1/shared/threads/{id}` | Read snapshot/discussion/presence or let its owner revoke the share. |
| `PUT /v1/shared/threads/{id}/members` | Owner replaces recipients using `{members,expected_version}`. |
| `POST /v1/shared/threads/{id}/refresh` | Owner publishes current cached thread using `{expected_version}`. |
| `GET, POST /v1/shared/threads/{id}/comments` | Read comments or post `{body}` with comment permission. `?before=<comment UUID>` paginates older comments. |
| `DELETE /v1/shared/threads/{id}/comments/{comment_id}` | Author or share owner removes a comment. |
| `PUT /v1/shared/threads/{id}/presence` | `{active:true}` sets 60-second reply presence; `{active:false}` clears it. Refresh while composing, and clear on exit. |
| `GET, POST /v1/shared/snippets` | List summaries or share `{template}` across the workspace. |
| `GET, PUT, DELETE /v1/shared/snippets/{id}` | Fetch full template; its owner can update `{template,expected_version}` or remove it. |

Template fields: `title`, `body`, `kind` (`snippet`/`template`), optional
`body_rtf_base64`, `to`, `cc`, `bcc`, `subject`, and `attachments` containing
`{filename,mime_type,data_base64}`. Combined file bytes are limited to 20 MiB.
The list endpoint excludes file bodies; fetch the selected template explicitly.
Version conflicts return HTTP 409, so reload before replacing a stale share or
template. Private notes are never included in shared snapshots.

## Verified sender marks

`GET /v1/mail/messages/{id}/sender-mark` checks a received Gmail message when
the reader opens it. A successful response contains `verified_sender_mark` with
the exact From domain, `provider: "gmail"`, `verified_by: "postmere"`, a
base64-encoded certified SVG and an RFC3339 `expires_at`. The field is null
when the message has no qualifying proof. Temporary verification failures
return HTTP 503.

Postmere checks the signature against the raw message, verifies the domain's
DMARC policy, then checks the BIMI mark certificate and its embedded artwork.
The DNS resolver receives only DNS names. The client can cache the result through
the earlier of its reported expiry and 24 hours. A domain favicon, imported
authentication header or ordinary contact photo cannot grant a verification badge.

## Unsubscribe API

`GET /v1/mail/messages/{id}/unsubscribe` returns `{one_click_url,reason}` without
requesting the sender's endpoint. The explicit user action posts
`{expected_url}` to the same route. The server fetches fresh raw MIME from the fixed Gmail or Microsoft API endpoint,
cryptographically verifies the signed list headers, checks the exact consent URL, and returns `{accepted,http_status,host,message}`.
A sender's redirect or non-success status has `accepted:false`; an HTTP 2xx from
the sender confirms request acceptance, not future delivery. Archive/block
actions remain separate and must never be presented as unsubscribe success.

The implementation follows [RFC 8058](https://www.rfc-editor.org/rfc/rfc8058.html):
isolated HTTPS form POST, no cookies or authorization context, no redirects,
and a cryptographically verified SHA-256 DKIM signature covering the sole
`List-Unsubscribe` and `List-Unsubscribe-Post` fields. Verification uses
`mail-auth` with ring cryptography and bounded DNS-over-TLS key lookups through
Cloudflare. The verifier caps raw messages at 8 MiB, headers at 64 KiB, and
signatures at eight, with an eight-second DNS/verification deadline. Deployment
egress must allow the provider APIs and DNS-over-TLS (TCP 853).

Ordinary `Authentication-Results` headers are not accepted as proof: imported
mail can contain sender-supplied copies. Workspace Gmail and Microsoft offer
one-click only when raw verification succeeds; browser/email options remain
available when verification fails. Invalid signatures, ambiguous fields,
modified messages, unsupported signatures, and unavailable DNS fail closed to
manual options. No message body or recipient is sent to the DNS resolver.

Every resolved address must pass conservative public-address checks based on
the [IANA IPv4 registry](https://www.iana.org/assignments/iana-ipv4-special-registry/)
and [IPv6 registry](https://www.iana.org/assignments/iana-ipv6-special-registry/).
The HTTP client pins those addresses in a resolver that cannot fall back to
another name or lookup. It disables proxies, follows no redirects, and drops
the response body immediately. Fixtures sign actual messages and reject altered
URLs/bodies/headers, duplicate fields, borrowed signatures, forged authentication
results, and oversized input. They also cover private/mixed DNS answers, encoded
addresses, DNS pinning, exact form contents, redirect rejection, and bounded
response handling.

## Calendar access, booking links, and RSVP

Calendar access is optional and separate from connecting mail. Start OAuth with
`POST /v1/mail/oauth/{gmail|microsoft}/start` and `{"calendar_access":true}` only
after the user chooses to connect their calendar. The ordinary `{}` request
remains mail-only. A successful callback records the `calendar` capability only
when the request explicitly opted in and the token response actually granted
Google `calendar.events` or Microsoft `Calendars.ReadWrite`. Existing accounts
must reconnect with that explicit choice. Enable Google Calendar API on the
OAuth project and configure the corresponding delegated calendar permission
for Microsoft; no additional server secrets are needed.

Booking links choose a writable destination calendar and up to eight calendars
for conflict checks; the primary calendar remains the default. Discovery uses
Google's additional `calendar.calendarlist.readonly` scope, or the existing
Microsoft calendar grant. Older Google grants keep primary-calendar support
and report `requires_reconnect:true` for discovery until consent is renewed.
Google events are expanded across the requested interval; Microsoft uses calendarView.
All-day times use the provider calendar's IANA time zone, including daylight
saving transitions. Missing pages, unsupported time zones, provider errors, and
lost access fail closed; they are not reported as free time. Adapters use fixed
HTTPS origins, bounded bodies/pages/timeouts, and validated pagination links.

Authenticated API:

- `GET /v1/calendar/accounts/{account_id}/calendars` returns
  `{items:[{id,name,is_primary,can_write}],requires_reconnect}` for an owned account.
- `GET /v1/calendar/booking-links` returns `{items:[...]}`. `POST` accepts
  `{account_id,title,description,time_zone,duration_minutes,expires_at,slots,
  calendar_id,conflict_calendar_ids,availability}`. Calendar fields default to
  `primary`; 1–8 distinct conflict calendars must include the writable destination.
  Each explicit slot is `{start,end}` in RFC3339. Choose 15–240 minute meetings and
  up to 100 explicit future times within 90 days. Alternatively, supply
  `availability:{start_date,end_date,weekdays,start_minute,end_minute}` with ISO
  dates and Monday=1 through Sunday=7. Weekly hours materialize at most 1,000 slots
  within 90 days and before expiry in the selected IANA time zone; ambiguous or
  nonexistent DST times are omitted. Weekly rules and explicit slots are mutually
  exclusive. The response preserves the calendar selection and rule plus `id`, `url`,
  `created_at`, `disabled_at`, and slots with stable UUIDs. `DELETE
  /v1/calendar/booking-links/{id}` revokes the link, without canceling meetings
  already sent to the provider.
- `GET /v1/calendar/bookings` returns the owner's recent reservations with guest
  name/email, start/end, and `checking`, `creating`, `confirmed`, `failed`,
  `uncertain`, `cancelling`, `cancel_uncertain`, or `cancelled` status. Guest details and reusable link secrets are encrypted at
  rest; only token hashes authorize public access.
- `POST /v1/calendar/bookings/{id}/reconcile` looks up the reservation by stable
  provider identity without repeating creation. `POST /v1/calendar/bookings/{id}/cancel`
  records cancellation intent before deleting the identified provider event.
  Repeated cancellations address the same event; ambiguous/202 responses retain
  the reservation as `cancel_uncertain`. Only confirmed cancellation releases it.
- `GET /v1/calendar/sharing` returns owned calendars and explicitly shared
  calendars in the same workspace. `PUT /v1/calendar/sharing/{account_id}` with
  `{enabled:true|false,calendar_ids:[...]}` controls an owned account's sharing;
  omitted calendar IDs default to `primary`. Sharing is off by
  default. Revocation works without contacting the provider, including when
  OAuth credentials have expired.
- `POST /v1/calendar/free-busy` accepts `{account_ids,start,end}` for up to eight
  accounts and 31 days, combining their explicitly selected calendars. It returns `{calendars:[{account_id,busy:[{start,end}]}],
  start,end}`. Only busy intervals are shared; event subjects, attendees, and
  bodies never leave the owner scope. The share is checked again after provider
  I/O so an in-flight revocation prevents disclosure.
- `POST /v1/calendar/invitations/respond` accepts
  `{account_id,ical_uid,organizer,start,end,response}` with `accepted`,
  `tentative`, or `declined`. It looks up the event in the owned primary calendar
  and verifies the provider's UID, organizer, exact occurrence times, and the
  account's attendee identity. A canceled, ambiguous, missing, or organizer-owned
  event cannot receive an RSVP. Google updates only the account's attendee
  response with an ETag precondition; Microsoft uses its response action. The
  server returns `{status:"responded",response}` only after provider acceptance.
  A local `.ics` copy does not qualify as a provider invitation.

`/book/{secret}` serves the public booking page and its local static assets. Its
JSON API, `/v1/calendar/public/{secret}`, returns current available slots on GET.
POST accepts `{client_id,slot_id,name,email}`. The `client_id` UUID is an
idempotency key: repeat the identical request after a connection failure. The
page preserves that key and locks the selection while checking an unknown
result. Public endpoints are rate-limited, have no session cookies/CORS, reject
foreign Origin writes, and apply a restrictive CSP and no-referrer policy.
Anyone holding a booking link can see its offered times and request a meeting;
the host should revoke a link when it is no longer intended for sharing.

A database advisory lock serializes reservations across **all links for the
same host account**, including overlapping alternative slots. The server
commits a durable reservation, checks provider availability, rechecks link and
account authorization, then records `creating` before sending an invitation.
An ambiguous provider response or interrupted creation keeps the time blocked
as `uncertain` and is never retried automatically. Check Status looks for the
provider event using Google's deterministic event ID or Microsoft's persisted
booking property. An absent uncertain creation stays reserved because absence
alone does not prove the event was never created. Interrupted cancellations can
be checked or retried against the same event. No API can atomically lock a provider
calendar against unrelated clients: a meeting added in another app between the
availability check and event creation can still conflict.

The calendar integration test uses a real isolated PostgreSQL database and an
injected calendar transport; it sends no real invitations. It covers tenant and
same-workspace ownership, forced RLS, capability/nonce checks, encryption,
concurrent overlapping booking links, idempotency, provider conflicts,
interrupted/ambiguous creation, share revocation, and revoked memberships.
Provider parser fixtures cover calendar time zones/DST, cursor-origin checks,
and RSVP identity checks. Production OAuth and live provider behavior still
require validation with the deployment's test accounts.

Provider references: [Google events.list](https://developers.google.com/workspace/calendar/api/v3/reference/events/list),
[Google event attendee responses](https://developers.google.com/workspace/calendar/api/v3/reference/events),
[Microsoft calendarView](https://learn.microsoft.com/en-us/graph/api/user-list-calendarview?view=graph-rest-1.0),
[Microsoft event creation](https://learn.microsoft.com/en-us/graph/api/user-post-events?view=graph-rest-1.0),
and [Microsoft RSVP](https://learn.microsoft.com/en-us/graph/api/event-accept?view=graph-rest-1.0).

## Optional AI assistance

Set `OPENAI_API_KEY` on the server and choose a supported Responses API model
with `POSTMERE_AI_MODEL` (the compatibility default is `gpt-6-luna`). Each
user separately enables assistance through `GET/PUT /v1/ai/settings`. The
settings response includes availability, provider/model, a data notice, and an
editable style guide. No API key is stored in the desktop application.

### Checking a message for spam

After enabling AI in their workspace, a user can submit one cached message to
`POST /v1/decisions/spam` with `{"message_id":"<UUID>"}`. The response contains
the same `message_id`, a `verdict` and a short plain-text `reason`. The three
verdicts are `possible_spam`, `no_spam_signals` and `uncertain`. They describe
the evidence in the excerpt. The endpoint never moves, reports or modifies a
message. Sender and link authenticity require separate verification.

The server checks that the message belongs to the requesting user and workspace,
that its account is connected, and that AI is enabled. It sends only the sender
domain, the first 300 characters of the subject and up to 4,000 characters of
plain-text content. The excerpt can contain personal or confidential information.
The analyzer receives no internal IDs, separate recipient fields, attachments,
HTML, mailbox history or credentials for the user's email account.

By default the check uses the configured OpenAI model with structured output,
no tools and `store:false`. To select a different analyzer, set both
`POSTMERE_DECISION_URL` (an administrator-chosen HTTPS endpoint) and
`POSTMERE_DECISION_TOKEN`. Postmere sends an HTTP POST containing JSON and
`Authorization: Bearer <token>`. Redirects are disabled. Custom providers
control their own data retention. A custom provider failure is returned to the
requester without sending the message to another provider.

The adapter accepts this request and returns the following JSON shape.

```json
{"task":"spam","message":{"sender_domain":"example.test","subject":"Invoice","text":"Please review the invoice."}}
```

```json
{"verdict":"uncertain","reason":"The excerpt provides little context."}
```

The adapter must return a successful HTTP status and a single-line reason of
1–500 characters. Postmere rejects unknown verdicts and unexpected fields.
`GET /v1/ai/settings` exposes `decision_available` whenever a spam analyzer is
configured. The existing `available` field covers the other OpenAI features.

### Sender research and mail assistance

`POST /v1/mail/messages/{message_id}/sender-profile` researches the selected
incoming sender's public professional identity using the same OpenAI key,
configured model, and user AI preference. The model must support Responses API
`web_search` and structured JSON output. No separate enrichment subscription or
API key is needed. The request body is `{ "refresh": false }`; use `true` for
an explicit refresh. Only the sender's name and email address from the owned
message envelope are used for research, never the subject, body, attachments,
private notes, or conversation history.

The response reports whether a profile was matched, no reliable match was
found, or AI is disabled/unconfigured. Available profile fields cover name,
role, company, general location, a short introduction, and public profile/site
links. Each finding cites URLs returned by the provider's actual web research;
the server rejects source URLs absent from the search metadata and withholds
matches marked uncertain or inconsistent with the sender's name/address.
Sender research is bounded, rate-limited, and cached within the current server
process by workspace, user, account, and sender. Access and AI opt-in are
rechecked after waiting and before returning a result. No model receives mail
tools or credentials. The Mac displays the findings alongside the email and
keeps source links available beside the facts.

See [OpenAI's web search guide](https://developers.openai.com/api/docs/guides/tools-web-search)
for tool/model support and search billing. Actual sender coverage depends on
available public information; a name or email address does not guarantee a match.

`POST /v1/ai/summary` and `/suggestions` accept selected `message_ids`;
`/draft` accepts those IDs plus `draft_text`, `instruction`, and `notes`.
`/ask` accepts a `question` and optional `account_ids`. Retrieval is bounded
PostgreSQL text search over the user's cached mail in the current workspace,
with up to 20 retrieved messages; it is not a full-history or calendar search.
Responses include source metadata and only validated source UUIDs. Structured
outputs are bounded, generated suggestions have no direct write authority, and
no arbitrary model tools or URLs are executed.

For an inline summary, send `Accept: text/event-stream` with the same
`POST /v1/ai/summary` request. Each SSE data field is JSON. A `delta` event
contains the next piece of prose in `text`. The terminal `done` event carries
the complete summary and validated citations in `result`. A terminal `error`
carries a public error `code`. A stream that ends before either terminal event
is incomplete. Clients requesting JSON receive the complete result in one response.

For mail assistance, only selected/retrieved message text, user instructions,
and the style guide are sent to OpenAI. Public sender research instead uses the
sender's name and address in a separate web-enabled request. Attachments and private notes are excluded. Requests use
`store:false`; this does not promise zero provider abuse-monitoring retention.
Review the provider's data policy for the deployment's account. Missing setup,
invalid model output, unauthorized sources, and rate limits fail explicitly.
Unit tests use a local mock Responses endpoint; database tests verify opt-in,
account/workspace boundaries, and unauthorized message rejection before any
provider request. Live model calls are not part of the regression suite.

## Mail accounts and provider OAuth

Set `GOOGLE_CLIENT_ID` and `GOOGLE_CLIENT_SECRET` for a Google **web application**
OAuth client, and register the exact callback
`<POSTMERE_PUBLIC_URL>/v1/mail/oauth/gmail/callback`. Set `MICROSOFT_CLIENT_ID`,
`MICROSOFT_CLIENT_SECRET`, and optionally `MICROSOFT_TENANT` (`common` by default)
for a Microsoft web application with callback
`<POSTMERE_PUBLIC_URL>/v1/mail/oauth/microsoft/callback`. Configure the provider's
consent screen, app audience, and production verification before external use.
Production callback URLs must use HTTPS.

The desktop starts a connection with authenticated
`POST /v1/mail/oauth/{gmail|microsoft}/start` and `{}`. It receives
`{connection_id,authorization_url,expires_at}`, opens the authorization URL, and
polls `GET /v1/mail/oauth/connections/{id}` for
`{status,account_id,error}`. A connection lasts ten minutes. Server-side state
has a random 256-bit nonce; only its hash is stored. Its locked, single-use
verification establishes the initiating workspace and user before code exchange.
The PKCE verifier is encrypted with the connection ID as part of its binding.
Provider access and refresh tokens never reach the desktop.

Ordinary Gmail connections request `gmail.modify`. Microsoft connections request
`offline_access User.Read Mail.ReadWrite Mail.Send MailboxSettings.ReadWrite`.
Existing Microsoft connections can reconnect to grant access to Outlook's category list. The explicit body
`{calendar_access:true}` additionally requests Google `calendar.events` and
`calendar.calendarlist.readonly`, or Microsoft `Calendars.ReadWrite`. The account gains the `calendar` capability only
when that request was explicit **and** the returned token grant includes the
required scope. Refresh-token rotation is serialized per account, and a refresh
that removes calendar permission removes its capability.

`GET /v1/mail/accounts` returns an array of
`{id,provider,email,display_name,status,last_synced_at,capabilities}`. Multiple
accounts are scoped to their connecting user inside the workspace. There is no
configured limit on connected accounts; requests, provider quotas, and server
capacity still bound throughput. Google and Microsoft sign-in both offer an
account chooser. Reconnecting the same provider/email for one user retains its
account ID and changes only that account’s credentials, even for simultaneous
callbacks. The ten-attempt limit applies only to unfinished OAuth handshakes.
Disconnect
with `DELETE /v1/mail/accounts/{id}`; this disables the account, cancels pending
sends, stops synchronization, and disables calendar sharing. It does not erase
cached mail or claim to revoke consent at the provider.

## Mail synchronization, search and attachments

The server starts a background account-sync worker alongside the send worker.
OAuth connection and explicit synchronization seed an identifier-only scheduler.
Four concurrent workers each process at most one account page per tick. Due-time
ordering gives other waiting accounts a turn before a busy account takes another
page; one slow provider request does not block every account. Worker shutdown
cancels in-flight child work. Active user/workspace membership
and account ownership are checked before credentials are opened and again before
results are committed. Disabled or revoked accounts are removed from the queue.
Provider checkpoints and bounded batches survive server restarts.

Gmail starts with full mailbox paging and then consumes Gmail history changes.
An expired history bookmark restarts the bootstrap without deleting absent cache
rows. Microsoft starts with full paging, then uses an overlapping
`lastModifiedDateTime` watermark. A rotating set of exact provider-ID checks
covers deletions that are unavailable in that listing or lost to expired Gmail
history. Only explicit history deletions or a targeted provider 404 hide cached
mail. Empty/limited pages never imply deletion. Google and Microsoft requests
use fixed origins; Graph continuation URLs are validated before attaching tokens.

`POST /v1/mail/accounts/{id}/sync` accepts `{cursor?,limit?}`. This cursor belongs
to the **desktop cache**, independently of the provider checkpoint. The response
is `{messages,deleted_message_ids,next_cursor,has_more}`. Persist `next_cursor`
only after successfully merging messages and explicit deletion IDs. Fetch more
while `has_more` is true; retain the cursor even for an empty response. This
allows a client to catch changes fetched while it was closed.

Cache cursors use authenticated encryption bound to the workspace, account and
user, and are limited to 4 KiB. All pages in a cycle keep a stable upper
watermark. Per-account write locks and database clock timestamps ensure later
changes are delivered in a subsequent cycle instead of being skipped. Retain
old encryption keys while clients still use their cursor versions. After an
intentional old-key retirement, `Invalid sync cursor` means the client should
clear only that account's cursor and perform a complete cache resync; it must not
treat missing pages as deletions.

| Route | Behavior |
| --- | --- |
| `GET /v1/mail/messages?account_id=&query=&cursor=&limit=` | Search/browse the scoped server cache. This route uses plain text; native advanced query parsing remains local. |
| `GET /v1/mail/messages/{id}` | Fetch one normalized cached message, including RFC threading metadata. Add `?view=envelope` to fetch recipient and delivery details without the body or attachments. |
| `GET /v1/mail/accounts/{account}/labels` | List editable Gmail labels or Outlook categories for this account. |
| `POST /v1/mail/accounts/{account}/labels` | Create a label or category with `{"name":"…"}` and return its provider ID and name. |
| `GET /v1/mail/accounts/{account}/messages/{message}/label` | Return the provider catalog and the message’s currently applied label IDs. |
| `PUT /v1/mail/accounts/{account}/messages/{message}/label` | Apply or remove one provider label using `{"label_id":"…","applied":true}`. Return the updated message. Older Outlook grants can return HTTP 412 until reconnected. |
| `POST /v1/mail/accounts/{id}/search` | `{query,cursor?,limit?}` searches deeper at the provider and caches the results. Query syntax is Gmail search or Microsoft Graph search, respectively. |
| `PATCH /v1/mail/messages/{id}` | `{is_read?,is_starred?,mailbox?}`; destinations are `inbox`, `archive`, or `trash`. Returns `{}` after provider confirmation and cache update. |
| `GET /v1/mail/messages/{id}/attachments/{attachment_id}` | Return an attachment owned by that scoped message, with a 25 MiB download limit. |
| `GET /v1/mail/messages/{id}/calendar-invitation` | Recover an invitation from the original MIME of an owned, previously cached message. Returns up to 512 KiB of `text/calendar`, or 404 if there is no event. |

Messages contain server/account/provider IDs, sender and recipient address
objects, plain/HTML bodies, preview, timestamp, read/star state, mailbox, provider
labels, attachment metadata, list headers and optional `rfc_message_id`,
`in_reply_to`, and `references`. Message and attachment UUIDs are stable within
an account. Attachment content is never fetched using a caller-supplied URL.
Synchronization, deep-search cache writes and message mutations serialize per
account so a stale provider read cannot overwrite a newer confirmed mutation.

## Durable delivery and reply threading

`POST /v1/mail/outbox` accepts:

```json
{
  "client_id": "stable-client-uuid",
  "account_id": "connected-account-uuid",
  "to": [{"name": "Pat", "email": "pat@example.com"}],
  "cc": [],
  "bcc": [],
  "subject": "Hello",
  "text_body": "A message",
  "html_body": null,
  "attachments": [],
  "scheduled_at": null,
  "undo_seconds": 10,
  "track_opens": false,
  "track_links": false,
  "in_reply_to": null,
  "references": [],
  "provider_thread_id": null
}
```

Attachments use `{filename,mime_type,data_base64}`; decoded files are limited to
20 MiB total. There may be at most 100 recipients and 50 attachments. Reply IDs
are validated against header injection and length limits. A supplied provider
thread ID must belong to a cached thread in the same account. Gmail receives
MIME reply headers plus `threadId`. Microsoft uses its supported base64 MIME
`sendMail` mode so standard `In-Reply-To` and `References` headers are preserved.
The shared MIME builder has independent parsing fixtures for Unicode subjects,
addresses, attachment names, binary files, and reply headers.

The encrypted send payload is saved before success is returned. A scoped
`client_id` plus payload hash makes repeated uploads return the same job; reusing
that identifier for changed content returns 409. Upload before the scheduled
send time so delivery can continue with the app closed. The undo window is
5–60 seconds and is always respected before a worker can claim the job.

The response is
`{id,client_id,account_id,status,scheduled_at,undo_until,provider_message_id,error_code,created_at}`.
`GET /v1/mail/outbox` returns `{items:[...]}`. `POST /v1/mail/outbox/{id}/cancel`
transactionally cancels a pending job; a claimed job cannot be cancelled.
`POST /v1/mail/outbox/{id}/retry` accepts only a confirmed `failed` job.

The worker marks `delivering` before contacting a provider. A confirmed provider
acceptance becomes `sent`; a definite rejection becomes `failed`. A network
ambiguity or interrupted delivery becomes `uncertain` and is **never retried
automatically**. The user must inspect Sent before composing another copy. A
provider receipt confirms acceptance by the provider, not recipient delivery.

## Optional open and link activity

Tracking is off unless `track_opens` or `track_links` is explicitly true for that
message. The server adds one image request and/or rewrites eligible quoted HTTP(S)
anchor destinations. It preserves scripts, comments, other attributes, mailto
links and local destinations. Random tokens are stored only as hashes and are
scoped to the owning user and workspace. Public pixels reveal no message data;
invalid pixels return the same transparent image. Tracking redirects never make
server-side requests to the destination.

`GET /v1/mail/activity?message_id=<outbox UUID>` returns
`{items:[{outbox_id,opens,clicks,first_open_at,last_open_at,first_click_at,last_click_at,events}],attribution_notice}`.
Events contain `{id,kind,occurred_at,recipient,device,is_proxy_or_bot}`. Recipient
attribution is null for multi-recipient messages. No raw IP or complete
user-agent is stored. Rapid duplicate probes are coalesced over ten seconds;
event collection stops after 180 days.

Open counts measure image requests, **not verified reads**. Privacy proxies,
blocked images, scanners and forwarding affect counts and attribution. Device
names are coarse inferences from the requesting client. Display the returned
notice beside activity rather than treating these signals as proof of reading.

Mail tests inject fake delivery and synchronization transports. They exercise
actual PostgreSQL isolation, OAuth nonce replay, idempotency, cancellation,
uncertain-send recovery, membership revocation, durable checkpoints, opaque
cursor tampering/account binding, changes during pagination and explicit
provider deletions. They do not contact Google/Microsoft or send real email.
Live OAuth consent, provider quotas and production delivery still require
configured credentials and an explicit deployment verification run.
