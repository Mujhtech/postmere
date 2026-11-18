# Provider change notifications

This crate adds Gmail watches and Microsoft Graph subscriptions to the existing
mail synchronizer. Verified callbacks only enqueue identifier-only hints.
Synchronization still polls every 60 seconds, independently of webhook setup,
to recover delayed or missing notifications. No provider history bookmark is
advanced from a callback payload.

## Gmail configuration

Set all four values together:

```dotenv
POSTMERE_GMAIL_PUBSUB_TOPIC=projects/YOUR_GOOGLE_PROJECT/topics/postmere-mail
POSTMERE_GMAIL_PUBSUB_SUBSCRIPTION=projects/YOUR_GOOGLE_PROJECT/subscriptions/postmere-mail
POSTMERE_GMAIL_PUSH_AUDIENCE=https://YOUR_POSTMERE_HOST/v1/webhooks/gmail
POSTMERE_GMAIL_PUSH_SERVICE_ACCOUNT=postmere-push@YOUR_GOOGLE_PROJECT.iam.gserviceaccount.com
```

Create the topic in the Google Cloud project that owns the Gmail OAuth client.
Grant Pub/Sub Publisher on that topic to
`gmail-api-push@system.gserviceaccount.com`. Create a **wrapped, authenticated push
subscription** whose endpoint is `https://YOUR_POSTMERE_HOST/v1/webhooks/gmail`.
Configure its authentication service account and audience to match the last two
values exactly. Grant the Pub/Sub service agent permission to mint tokens for
that service account as described in Google's setup guide. Do not enable payload
unwrapping. Existing `gmail.modify` consent is sufficient for watches.

The backend verifies RS256 signatures against Google's fixed HTTPS JWKS endpoint,
then checks Google issuer, exact audience, the expected verified service-account
email, subject, issue time and expiry. It honors bounded JWKS cache lifetimes and
limits refreshes on unknown key IDs. Callback envelopes must name the configured
subscription. Stale envelopes and non-increasing mailbox history IDs cannot
schedule repeated work. Gmail may reuse a signed authentication token across
requests; the token itself is not treated as a single-use event ID.

Watch renewal occurs at least daily. Watches cover all mailbox changes, including
read-state changes, moves and deletions. Connecting the same Gmail mailbox in
several workspaces fans a verified hint out to their independently authorized
accounts. Disconnecting one binding does not stop another binding's watch.

Official references: [Gmail push setup](https://developers.google.com/workspace/gmail/api/guides/push),
[watch API](https://developers.google.com/workspace/gmail/api/reference/rest/v1/users/watch),
[authenticated Pub/Sub push](https://docs.cloud.google.com/pubsub/docs/authenticate-push-subscriptions),
[Google key discovery](https://developers.google.com/identity/openid-connect/openid-connect).

## Microsoft configuration

```dotenv
POSTMERE_MICROSOFT_WEBHOOKS=true
```

The backend creates basic subscriptions for `me/messages` using existing delegated
`Mail.ReadWrite` consent. No mailbox content is requested in notifications.
Notification and lifecycle endpoints use the same random per-account callback:
`https://YOUR_POSTMERE_HOST/v1/webhooks/microsoft/{route-id}`. Allow unauthenticated
POST access through the reverse proxy; the endpoint performs its own validation.
Graph's `validationToken` challenge is returned as bounded plain text.

Every actionable notification must match both the current subscription ID and
the secret `clientState`. The secret is encrypted at rest; comparisons use its
one-way hash. The resource identity in a payload is never used to authorize or
select a mailbox. Duplicate hints have bounded ten-minute replay memory.

Subscriptions request a two-day lifetime and renew daily or sooner as required.
`reauthorizationRequired` uses a single PATCH that renews and reauthorizes;
`subscriptionRemoved` recreates the subscription; `missed` requests synchronization.
An interrupted creation is reconciled through bounded, fixed-origin list paging
and GET before another POST. Graph list responses omit `clientState`, so only
the detailed response can establish ownership. Near-expiry candidates are renewed
before their new lifetime is validated.

Official references: [webhook delivery](https://learn.microsoft.com/en-us/graph/change-notifications-delivery-webhooks),
[lifecycle notifications](https://learn.microsoft.com/en-us/graph/change-notifications-lifecycle-events),
[subscription lifetime](https://learn.microsoft.com/en-us/graph/api/resources/subscription?view=graph-rest-1.0),
[list subscriptions](https://learn.microsoft.com/en-us/graph/api/subscription-list?view=graph-rest-1.0),
[get subscription](https://learn.microsoft.com/en-us/graph/api/subscription-get?view=graph-rest-1.0).

## Lifecycle and operations

Both integrations require a public HTTPS origin. Missing configuration leaves
that provider on polling; partial Gmail configuration fails startup explicitly.
No cloud resources are created by deployment configuration generation.

Migration `0014` seeds existing provider accounts and transactionally schedules
connection/disconnection changes. Four bounded worker lanes claim durable leases;
per-route locks serialize renewal across server processes. Operations have a
60-second deadline and failures use exponential backoff capped at one hour.
`provider_webhooks` records the last success, expiry and a generic deferred error
for operational inspection, without storing provider error bodies. Account and
membership revocation prevent callbacks from scheduling work immediately.
Subscriptions are cancelled on disconnect. Before an external creation, the
worker persists a bounded cancellation horizon; interrupted Graph creations
without a saved provider ID are discovered through the same verified callback
and secret before deletion. If provider access has already been revoked,
cancellation retries remain bounded by the provider lease. Disconnected
accounts cannot authorize further callback work.

Separate `mail_sync_signals` rows preserve notifications arriving during a sync.
Only the signal generation observed before the provider fetch is consumed;
newer hints remain runnable even when the normal polling deadline is in the
future. Provider failures defer retry without removing polling fallback.

Tests use signed RSA fixtures, a real isolated PostgreSQL schema and injected
provider transports. They cover callback validation, scope/revocation, replay,
renewal/recreation, shared Gmail watches, interrupted Graph creation and a hint
arriving during an in-flight sync. They do not create live watches, subscriptions,
Pub/Sub resources or send mail.
