# Native realtime invalidations

`GET /v1/events` uses the existing workspace bearer session and returns
`text/event-stream`. The server shares one PostgreSQL `LISTEN` connection across
active subscribers. Transactional `NOTIFY` triggers publish only after a mail,
account, or outbox change commits. Each actor has an independent bounded queue.

Events use this payload, with a subset of the three kinds for `change`:

```text
event: ready
id: <opaque UUID>
retry: 3000
data: {"version":1,"kinds":["accounts","mail","outbox"]}
```

- `ready`: initial connection; refresh all three kinds.
- `change`: committed state changed; refresh the listed kinds.
- `reset`: reconnect, lost PostgreSQL notifications, or a lagged client; refresh
  all three kinds.

Every connection performs a fresh catch-up. `Last-Event-ID` is an optional ASCII
hint of at most 256 characters; event IDs do **not** promise replay or ordering.
Lost events are recovered from authoritative state, using the existing durable
per-account cache cursor with `POST /v1/mail/accounts/{id}/sync` and
`{"refresh_provider":false,"cursor":"..."}`. Omitting `refresh_provider` keeps the
existing provider refresh behavior. Account lists and outbox statuses use their
existing authenticated endpoints. No message text, subject, addresses, or
principal identifiers appear in stream data.

The server emits heartbeat comments every 15 seconds, rechecks session and
membership authorization every two seconds while the response is being polled,
and rechecks before each data event. Invalid authorization closes the response;
reconnecting then receives the normal authentication error. Streams release
their connection permit when the response body is dropped. Limits are four
streams per user/workspace and 128 per application instance. Main signals open
streams before HTTP graceful shutdown waits for them.

Provider checkpoints, token refresh, unchanged synchronization, and verification
bookkeeping do not emit invalidations. Notifications accelerate server-to-app
updates; upstream provider synchronization still follows its existing polling
schedule. APNs alerts while the app is closed are handled by `postmere-push`.
