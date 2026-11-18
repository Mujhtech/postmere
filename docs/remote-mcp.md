# Remote MCP

Postmere exposes `https://YOUR_POSTMERE_HOST/mcp` using the official Rust MCP SDK
(`rmcp` 3.11.0), stateless Streamable HTTP and JSON responses. Every request
requires a dedicated MCP OAuth access token. Desktop workspace bearer tokens,
provider tokens, browser cookies and refresh tokens cannot authenticate `/mcp`.

## Connect a client

An optional [Docker Compose + HTTPS configuration](../server/deploy/README.md)
includes Caddy and the ChatGPT callback preset for deployment on your server.

1. Deploy the [workspace server](../server/README.md), apply migrations, and
   configure Google/Microsoft accounts in Postmere. Set `POSTMERE_PUBLIC_URL`
   to the externally reachable HTTPS origin, without a path or query.
2. Add that origin's `/mcp` URL to the client's remote MCP connection settings
   and choose OAuth with dynamic client registration.
3. Copy the exact callback URL shown by that client into the server's
   `POSTMERE_MCP_REDIRECT_URIS` JSON array and restart the server. No wildcard
   callbacks are allowed. HTTPS is required except for loopback development.
   The default empty array rejects registration.
4. Complete the client's connection flow. Sign into the Postmere browser page
   with your workspace ID, email and password, inspect the client name, callback
   and requested permissions, then choose **Allow access**.

For example, an allowlist can contain
`["https://chatgpt.com/connector_platform_oauth_redirect"]` **when that is the
exact callback displayed for your connection**. Postmere publishes matching
issuer metadata and returns the issuer in authorization redirects. ChatGPT
documents both stable and connection-specific callbacks; use the one shown
in its management page. See [OpenAI's authentication guide](https://developers.openai.com/plugins/build/auth).

The reverse proxy must preserve the public `Host` authority and `Authorization`
header. Requests with a different Host or a supplied Origin other than the
configured public origin are rejected. Browser consent POSTs require that exact
Origin, a browser session cookie and its CSRF token. Do not log request bodies,
Authorization/Cookie headers, token responses or OAuth callback query strings.

## Permissions and tools

| OAuth scope | Tools | Behavior |
| --- | --- | --- |
| `mail:read` | `list_accounts`, `list_messages`, `read_message`, `list_outbox`, `get_approval`, `list_approvals` | Read the current user's cached mail, queue state and approval status. |
| `mail:draft` | `create_draft`, `update_draft`, `get_draft`, `list_drafts`, `delete_draft` | Store and edit encrypted, versioned MCP drafts. No sending. |
| `mail:manage` | `manage_message`, `cancel_outbox` | Read/unread, star/unstar, archive/inbox; cancel a send before delivery starts. |
| `mail:manage` | `request_trash`, `request_disconnect` | Create a browser approval request. No immediate provider/account change. |
| `mail:send` | `request_send` | Request approval of a specific draft version. No immediate queueing. |

The tool catalog declares each required scope. Requests without that scope get
an OAuth scope challenge. Listing schemas does not grant access to their data.
Identity always comes from the token; tool arguments cannot choose a different
user or workspace. Provider connections remain individually owned within a
workspace.

## Approval and delivery

Create or read a draft, then call `request_send` with its ID, current version and
a fresh `request_id` UUID. Reuse that request ID if the call is retried. Give the
returned `approval_url` to the human user. Reading the URL or polling
`get_approval` does not approve the request.

The browser displays the account, all To/Cc/Bcc recipients, full text, escaped
HTML source, attachment names/sizes, schedule, undo delay and tracking settings.
HTML remains inert and loads no remote content. Review data is an immutable
snapshot: later draft edits or deletion cannot change the requested send. Make
a new request and cancel the old one to review different content.

Only the owning user in an authenticated browser session can approve or cancel.
MCP tokens cannot submit consent. Approvals expire after 15 minutes. Concurrent
or repeated approval submissions queue the same send once. A completed send
approval means **queued**, not delivered; check `list_outbox`. Existing undo,
scheduled delivery, failure and uncertain-outcome handling remain in force.
Polling approval and delivery status also requires `mail:read`; a send-only
grant can request approval but cannot read mailbox or queue data. Disconnecting
an account cancels pending sends; a send already in progress may finish.
An ambiguous or interrupted provider mutation is not automatically repeated.
Tracking is disabled unless explicitly included in the reviewed draft.

## OAuth behavior

- Discovery: `/.well-known/oauth-protected-resource/mcp` and
  `/.well-known/oauth-authorization-server`.
- Client registration: `/mcp/register`, with exact allowlisted callbacks and
  either `none` or `client_secret_basic` authentication. Client metadata URLs
  (CIMD) and `private_key_jwt` are not implemented.
- Authorization: `/mcp/authorize`, browser sign-in/consent, code + S256 PKCE.
  Clients must send the exact advertised `/mcp` resource in authorization and
  token requests. Codes expire after five minutes and are single use.
- Tokens: `/mcp/token`. Access tokens last at most 15 minutes. Refresh tokens
  rotate; replay of a consumed code or refresh token revokes its grant family.
  Scope reduction cannot be reversed by refresh. Tokens are stored as hashes.
  Each authorization owns a persistent session; refresh tokens and grants have
  no automatic expiry. The bounded browser login is used only for consent and
  action approvals, and its expiry does not disconnect the assistant.
- Revocation: `/mcp/revoke`, using the registered client's authentication and
  its access or refresh token. Sign-out from the Mac app or `/mcp/connected`
  revokes this user's existing assistant connections in that workspace.
  Membership removal or a disabled user/workspace also ends access.
- Connection management: `/mcp/connected` lists connected assistants and offers
  individual revocation and workspace sign-out with CSRF protection. Settings
  → Accounts → Manage connected assistants opens it. Native authenticated
  clients can use `GET /v1/mcp/connections` and
  `DELETE /v1/mcp/connections/{grant_id}`. MCP bearer tokens cannot use these APIs.
- Offline sign-out: the Mac app saves its sign-out timestamp and retries when
  connected. Grants authorized afterward survive a delayed sign-out. Existing
  server access ends when the revocation reaches the server. Failed or canceled
  login cleanup revokes only the temporary native credential.

Migration 0013 preserves currently valid grants and unused refresh tokens by
moving them to independent persistent sessions. It never revives expired or
revoked credentials. Clients whose old authorization has already expired must
connect once again.

Mail operation transactions recheck current identity and row-level security.
OAuth grant locks serialize calls with revocation and scope changes. Credentials
are never passed through to Google or Microsoft from the MCP client.

## Limits and verification

MCP drafts live on the server and are separate from native and provider-side
drafts. Search covers the synchronized cache; it is not provider-native search
syntax. Message reads include text (up to 64 KiB) and attachment metadata, not
file downloads. Draft uploads, including base64 files, must fit the 1 MiB MCP
request limit. Draft/approval lists are bounded to the most recent 50/25 entries.
No calendar, collaboration, unsubscribe or AI tools are exposed in this version.

The server bounds concurrent MCP requests and applies per-grant rate limits.
Tool content is untrusted mail data, not instructions or user consent. Database
fixtures verify protocol initialization/calls, OAuth/PKCE, rotation/replay,
scope enforcement, isolation, revocation, lock waits and explicit approvals.
See the [verification report](verification-2026-11-17.md).

A public deployment and an actual ChatGPT/client connection still need to be
verified with your configured URL and callbacks. Automated tests do not send
real email or grant access to a real mailbox.
