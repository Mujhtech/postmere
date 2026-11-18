# Deploy Postmere on your server

This Docker Compose configuration runs PostgreSQL, the Rust service and Caddy
with automatic HTTPS. The service
must remain running for mail synchronization, scheduled delivery and push
notifications. Use persistent compute; do not scale it to zero between requests.

## Configure

Point a hostname you control at the server, allow inbound TCP 80/443 (and UDP
443 for HTTP/3), then copy this directory with the server source. From this
directory, generate the private configuration:

```sh
python3 configure.py --host mail.example.com --email owner@example.com
```

The generator creates independent database passwords and encryption/rate-limit
keys, writes `.env` with mode 0600, and refuses to overwrite an existing file.
Add your mail-provider OAuth credentials and optional APNs settings. Keep
credential keys when updating the app;
replacing them makes stored provider credentials and drafts unreadable.
PostgreSQL initializes separate administrator, migration-owner and runtime
roles. The app's role is `NOSUPERUSER NOBYPASSRLS` with table DML access, and it
does not receive the administrator or migration password. Container database
connections use a shared Unix socket with SCRAM password authentication; the
database has no published TCP port. Keep keys and database backups outside the source
repository. Private environment files and `secrets/` are ignored by Git and the
Docker build context.

The Compose file derives `POSTMERE_PUBLIC_URL=https://POSTMERE_HOST`. Caddy
preserves the public Host and Authorization headers, flushes SSE responses, and
does not enable access logs containing OAuth callback query strings. Only Caddy
publishes network ports; the Rust server stays on the private container network.
See [Caddy's proxy documentation](https://caddyserver.com/docs/caddyfile/directives/reverse_proxy).

Set up these OAuth URLs for a deployment at `https://mail.example.com`:

| Service | URL |
| --- | --- |
| ChatGPT remote MCP server | `https://mail.example.com/mcp` |
| ChatGPT callback allowed by Postmere | `https://chatgpt.com/connector_platform_oauth_redirect`, or the exact callback shown by ChatGPT |
| Google web OAuth authorized redirect | `https://mail.example.com/v1/mail/oauth/gmail/callback` |
| Microsoft web OAuth redirect | `https://mail.example.com/v1/mail/oauth/microsoft/callback` |

The ChatGPT callback is a URL hosted by ChatGPT, not your mail server. Keep the
allowlist exact. Postmere's issuer metadata supports ChatGPT's stable callback;
confirm it matches the connection management page. See
[OpenAI's authentication guide](https://developers.openai.com/plugins/build/auth)
and [Postmere's MCP guide](../../docs/remote-mcp.md).

## Start

```sh
docker compose config --quiet
docker compose build app
docker compose up -d postgres migrate
docker compose run --rm -T app bootstrap owner@example.com 'My workspace' < /secure/path/owner-password
docker compose up -d app caddy
```

Run bootstrap only for the first workspace and retain its printed workspace ID.
The password input must be a protected file or password-manager pipe; it is not
a command-line argument. The app waits for successful migrations before
starting. Database initialization runs only on an empty data volume: changing
passwords in `.env` does not rotate existing PostgreSQL roles. Rotate role
passwords in PostgreSQL and update configuration together.

Then verify the public service:

```sh
curl --fail https://mail.example.com/health/ready
curl --fail https://mail.example.com/.well-known/oauth-protected-resource/mcp
curl --fail https://mail.example.com/.well-known/oauth-authorization-server
curl -i https://mail.example.com/mcp
```

The last request should return `401` with an OAuth `WWW-Authenticate` discovery
header. Add the `/mcp` URL in ChatGPT using OAuth/Dynamic Client Registration,
sign in to your Postmere workspace and review its requested permissions. Sign
in to the native app using the same public origin and connect your mail accounts.

## Apple push notifications

Enable Push Notifications on the Apple Developer App ID matching
`mujhtech.postmere`, use a provisioning profile with the macOS APNs entitlement,
and create an APNs signing key for the correct Apple team. Set all five
`POSTMERE_APNS_*` values shown in `.env.example`, install the `.p8` key in
`secrets/`, and grant container UID 65532 access to that directory and key
(for example, owner UID 65532, directory mode 0700, key mode 0400). Never put the key in the
Mac app. A development-signed app uses the sandbox environment; a distribution
build uses production. The configured server environment must match.

The `.p8` key, provisioning, a signed app and a running deployed server are
required for an actual device delivery check. Unsigned local builds cannot
verify APNs registration. User notification permission and each account's
notification settings still determine whether alerts are shown.

The Mac app uploads the APNs token and per-account preferences after permission
is granted. Its Debug build uses `development` and Release uses `production`
for the `com.apple.developer.aps-environment` entitlement; set the server to
`sandbox` or `production` respectively. A token is tied to the signed-in
workspace session and remains active until sign-out or access revocation, even
when the app stays closed. There is no daily sign-in requirement. Each queued
message has a separate 24-hour delivery window to avoid stale alerts; new mail
continues to create notifications beyond that window.
Sender screening and routing preferences are uploaded as an encrypted policy;
the server evaluates them before sending an alert even while the app is closed.
Changes made offline apply to remote delivery after the next successful sync.
macOS controls delivery while asleep and under Focus; push delivery is not guaranteed.

## Provider notifications

Set `POSTMERE_MICROSOFT_WEBHOOKS=true` to let the server register and renew Graph
mail subscriptions at its public HTTPS origin. For Gmail, create an authenticated
Pub/Sub push subscription and supply the four `POSTMERE_GMAIL_*` values in `.env`.
The topic must be in the OAuth project's Google Cloud project and grant Gmail's
publisher access; the push identity and exact audience must match the server
configuration. Full setup and verification are in the [webhook guide](../crates/postmere-webhooks/README.md).
The server maintains subscriptions for existing and newly connected accounts.
Callbacks schedule sync; the once-a-minute poll remains a fallback. No provider
subscriptions are created when their configuration is disabled.

## Update

Back up the database and keyring, build the new image, apply migrations, then
recreate the app service. Do not remove the Caddy data volume; it retains the
certificate state. Migration rollback is not automatic.

Deploy the updated Mac app alongside migrations `0011`–`0016`. Existing
valid native sessions and push registrations carry forward; expired or revoked
sessions require sign-in again. The app verifies the server's current session
state before replacing an old cached expiry. Migration `0013` carries forward
currently valid MCP connections; `0014`–`0016` add provider notifications,
encrypted sender policies and booking workflows. Stop the old backend before
applying these migrations: it cannot interpret persistent session rows and
could otherwise reject an active user's token during the update.

```sh
docker compose build app
docker compose stop app
docker compose run --rm migrate
docker compose up -d app caddy
```

On an existing managed HTTPS platform, use the same environment and callback
values without Caddy. Disable response buffering for `/v1/events`, preserve
the public Host header, and retain PostgreSQL connectivity and background CPU.
For an external PostgreSQL service, replace the socket URLs and remove the
bundled database dependencies; use `sslmode=verify-full` with a non-superuser,
non-RLS-bypass runtime role as described in the [server guide](../README.md).
