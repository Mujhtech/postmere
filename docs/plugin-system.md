# Plugins

Status: phase 1 shipped · Scope: first-party plugins only · Runtime: MCP-shaped

Plugins add functions, interface or both to Postmere: an action on a message, a
card in the reader, a badge in the list, a step in compose, or work that runs
when mail arrives. This document defines what a plugin is, where it can appear,
how it runs, and what it may touch.

## Decisions

- **First-party only.** Every plugin is written and reviewed by us and ships
  with the workspace server. There is no directory, no install-from-URL and no
  third-party signing yet. The design keeps those possible later.
- **MCP-based.** A plugin is an MCP server plus a Postmere manifest. Functions
  are MCP tools. Interface is returned as declarative cards that Postmere draws
  natively. Postmere's workspace server is the MCP client.
- **Native interface, not web views.** Cards are data, so every plugin matches
  the app's themes, accent, light and dark mode, Reduce Motion and VoiceOver.

## Architecture

```
Mac app ──── extension points (render cards, run actions) ────┐
   ▲                                                         │
   │ realtime events / HTTPS                                 ▼
Workspace server ── plugin host (MCP client, rmcp) ── plugin (MCP server)
   │                    │                               built-in crate or
   │                    └── permissions, audit,          HTTPS endpoint
   └── mail, accounts      card cache, triggers
```

- **The workspace server hosts plugins.** It holds provider credentials, runs
  triggers while the Mac sleeps, enforces permissions and keeps the audit log.
  The Mac app never talks to a plugin directly.
- **Two plugin transports.**
  - *Built-in:* a Rust crate in this workspace implementing the plugin trait in
    process. Fast, no network hop, the default for first-party plugins.
  - *Remote:* an MCP server over streamable HTTP with OAuth, for plugins that
    need their own service (for example a CRM integration we run separately).
  Both expose the same tools and return the same cards.
- **One contract.** Built-in plugins implement the `Plugin` trait in
  `postmere-plugins`: tool name plus JSON arguments in, cards and effects out,
  the same shape as an MCP `tools/call`. The remote transport (phase 2) adds
  `rmcp`'s `client` feature and implements that trait over HTTPS, so the host,
  routes and app don't change.

## Manifest

Each plugin ships a manifest, versioned with the server. Example:

```json
{
  "id": "postmere.packages",
  "name": "Package Tracking",
  "version": 1,
  "icon": "shippingbox",
  "tint": "orange",
  "permissions": ["message.read", "network:api.17track.net"],
  "extensions": [
    { "point": "message.banner", "tool": "package_status",
      "when": { "detect": "tracking_number" } },
    { "point": "list.badge", "tool": "package_badge",
      "when": { "detect": "tracking_number" } },
    { "point": "message.action", "tool": "track_package",
      "title": "Track Package", "key": "⇧⌘T" }
  ],
  "triggers": [
    { "on": "mail.received", "when": { "detect": "tracking_number" },
      "tool": "watch_package" }
  ],
  "settings": [
    { "key": "notify_delivery", "type": "toggle", "title": "Notify when delivered", "default": true }
  ]
}
```

Icons name glyphs in Postmere's own icon set (`PostmereIcon`); a new plugin adds
any glyph it needs there, such as `shippingbox` above.

`when` filters run on the server before any plugin is called, so a plugin is
only invoked for mail it can act on. Filters are either a search query in
Postmere's query language (`from:*@ups.com has:attachment`) or a named detector
(`tracking_number`, `invoice`, `flight`, `calendar_invite`, `otp`) implemented
once in the host.

## Extension points

| Point | Where it shows | Plugin returns | Phase |
|---|---|---|---|
| `message.action` | Reader toolbar ⋯ menu, right-click, ⌘K, triage | a result card or a toast | 1 |
| `message.banner` | Top of the message, like the spam check | one card | 1 |
| `reader.panel` | The trailing panel slot shared with Ask | a card stack | 1 |
| `compose.action` | Composer toolbar and ⌘K while composing | text to insert, or a card | 2 |
| `list.badge` | Message list rows | a badge (icon, short label, tint) | 2 |
| `mail.received` trigger | Server, no UI | side effects and an optional banner | 2 |
| `settings` | Settings → Plugins → plugin page | declared fields, no code | 1 |

Rules for every point:

- **Fast or deferred.** Banners and badges have a 1.5 s budget. Slower results
  arrive through realtime and the card fades in. Nothing blocks opening a message.
- **Cached.** Card results are cached per message and plugin version and
  invalidated when the message changes, so scrolling never re-runs plugins.
- **One banner per message.** If several plugins match, the highest-priority
  card shows and the rest collapse into "2 more" behind it.

## Cards

The whole interface vocabulary. Postmere draws these with its own components,
so a plugin cannot look out of place.

```json
{
  "card": {
    "title": "Out for delivery",
    "subtitle": "UPS · arrives today by 7 PM",
    "icon": "shippingbox", "tint": "orange",
    "body": [
      { "type": "progress", "value": 0.8, "label": "4 of 5 steps" },
      { "type": "facts", "items": [["Tracking", "1Z999AA10123456784"], ["From", "Brooklyn, NY"]] }
    ],
    "actions": [
      { "title": "Open in UPS", "open": "https://www.ups.com/track?tracknum=1Z999AA10123456784" },
      { "title": "Mute", "tool": "mute_package", "args": { "id": "1Z999AA10123456784" }, "style": "secondary" }
    ]
  }
}
```

Components: `text`, `facts` (label and value pairs), `progress`, `list`,
`image` (https, size-limited, proxied), `badge`, `divider`, `form` (text, date,
picker, toggle fields that submit to a tool). Actions either open a URL,
call a tool with arguments, insert text (compose only) or copy to the clipboard.
The schema is versioned; unknown components are skipped, never rendered raw.

## Invoking a plugin

The host calls a tool with a context object and nothing more than the manifest
permits:

```json
{
  "message": { "id": "…", "subject": "…", "from": "…", "sent_at": "…", "text": "…" },
  "account": { "id": "…", "provider": "gmail" },
  "settings": { "notify_delivery": true },
  "locale": "en-GB", "time_zone": "Europe/London"
}
```

- Without `message.read`, `text` is omitted. Attachments are never included
  unless the manifest asks for `message.attachments`.
- Tools must return within 10 s for actions and 1.5 s for banners and badges;
  longer work returns a pending card and finishes through realtime.
- Errors become a quiet inline state ("Package Tracking couldn't load"), never
  an alert.

## Permissions

| Permission | Allows |
|---|---|
| `message.read` | Text of the message the user is looking at or a trigger matched |
| `message.attachments` | Attachment bytes for that message |
| `mail.search` | Searching the user's indexed mail |
| `drafts.write` | Creating and editing drafts |
| `mail.organize` | Labels, archive, snooze, needs-reply |
| `mail.send` | Sending, always behind the existing approval step |
| `network:<domain>` | Outbound requests to that domain only |

- **Enabled by the user.** First-party plugins ship off. Settings → Plugins
  shows each one with its permissions in plain language and a switch.
- **Account visibility.** The "hidden from assistants" rule applies to plugins
  too: plugin calls run in a transaction marked like assistant requests, so a
  hidden account's mail never reaches any plugin.
- **Audit.** Every call is logged (plugin, tool, message id, time, outcome),
  never content, kept seven days, visible in the plugin's settings page.
- **Network.** Remote plugins and `network:` permissions go through the
  existing public-network guard, so plugins cannot reach private addresses.

## Server changes

- New crate `postmere-plugins`: the host, the plugin trait, the manifest
  loader, detectors, the card schema and the built-in plugins.
- Tables: `plugin_installs` (workspace, user, plugin, enabled, settings),
  `plugin_cards` (message, plugin, version, card JSON, expires), `plugin_activity`
  (as `mcp_activity`).
- Endpoints: `GET /v1/plugins`, `PUT /v1/plugins/{id}` (enable and settings),
  `POST /v1/plugins/{id}/actions/{tool}`, `GET /v1/messages/{id}/plugin-cards`.
- Triggers hook into mail sync after messages are stored, run through a small
  job queue with retries, and publish card updates over realtime.

## Mac app changes

- A plugin registry fed by `GET /v1/plugins` and realtime updates.
- `PluginCardView`, the single renderer for every card component.
- Hooks at each extension point: the reader banner slot, the reader ⋯ menu and
  ⌘K, the trailing panel, the composer toolbar and list rows.
- Settings → Plugins: one row per plugin (icon tile, name, one-line summary,
  switch), and a detail page with its permissions, settings and activity.

## Phase 1 (shipped)

Server (`crates/postmere-plugins`, migration `0019_plugins.sql`):

- `GET /v1/plugins` lists each plugin with its permissions, whether it's on,
  its settings (each with its current value) and the last 20 tool calls.
- `PUT /v1/plugins/{id}` turns a plugin on or off and saves settings; unknown
  keys and invalid values are rejected.
- `GET /v1/mail/messages/{id}/plugins?today=YYYY-MM-DD` returns cards and
  message actions from enabled plugins. With nothing enabled it returns
  without reading the message.
- `POST /v1/plugins/{id}/tools/{tool}` runs a tool for a message and returns
  a card, a toast and effects (`open`, `remind`) the app applies locally.
- Plugins read mail in a transaction marked like assistant requests, so
  accounts hidden from assistants are hidden from plugins.
- Tool calls are logged (plugin, tool, outcome, time), kept seven days. Banner
  renders are not logged: built-in detectors are local rules with no effects.
- No server card cache yet. Rules run in microseconds; the app caches results
  per message and drops them when plugins or settings change.

Card components shipped: `text`, `facts`, `steps`, `badge`, `divider`. Actions:
open (https only), copy, tool. `list`, `image` and `form` wait for a plugin that
needs them.

Mac app: `MailPlugins` (catalog, per-message cache, actions),
`PluginCardView` (banner under the spam check, "N more" opens the Plugins side
panel), plugin actions in the reader's ⋯ menu, and Settings → Plugins.

Plugins:

1. **Package Tracking.** UPS, USPS, FedEx, DHL and Royal Mail numbers in
   shipping mail; stage (label created → delivered) as steps, the arrival
   estimate, Track and Copy Number. Setting: show delivered packages.
2. **Bills & Invoices.** Amount, due date, invoice number and payment link;
   paid and overdue states; Remind Me sets a follow-up on the morning of the
   chosen day. Setting: remind 1, 3 or 7 days before.
3. **GitHub.** On mail from github.com: what happened to a pull request,
   issue or discussion (review requested, approved, changes requested, merged,
   closed, new comment), why it reached you, and Open on GitHub, Copy
   Reference and Unsubscribe from Thread; failed or cancelled workflow runs
   with branch and commit; Dependabot and code scanning alerts with severity.
   Read from the subject, the "view it on GitHub" link and the "You are
   receiving this" footer, so it works on mail synced earlier. Links are only
   offered on https://github.com. Setting: show successful runs.
4. **Issue Tracking.** Linear and Jira: assigned to you, mentioned, moved to a
   status, commented, new or done; key, title, status and priority; Open in
   Linear or Jira, Copy Key and Copy Branch Name (`eng-123-fix-login`).
5. **Sentry.** Error title, project and environment, a New, Regression,
   Escalating or Resolved badge, issue ID and release; Open in Sentry.
6. **Deploys.** Vercel and Netlify: failed, cancelled or live, with project,
   environment and branch; Open Logs or Deployment and Visit for the preview.
   Setting: show successful deploys.
7. **Incidents.** PagerDuty and Opsgenie: triggered, acknowledged or resolved
   (the subject wins over the body), title, service, number and urgency; Open
   Incident. Acknowledge and resolve wait for per-plugin sign-in.

Every plugin checks the sender's domain, accepts links only on the
provider's own hosts (subdomain-aware, so `sentry.io.evil.test` fails), and
gives no card when the mail is marketing rather than a notification. Banner
priority follows the registry: incidents, GitHub, Sentry, deploys, issues,
packages, bills.

Phase 2 adds compose actions, list badges, triggers, a server card cache, and a
remote plugin (a CRM sender panel) over the `rmcp` client. Phase 3, if third
parties are ever allowed: signing, review, a directory and stricter sandboxing.

## Open questions

- Whether later detectors (flight, reservation) use the AI analyzer or stay
  rule-based like phase 1, for cost and privacy.
- Whether plugin banners count against a per-message attention budget with the
  spam check and needs-reply annotation, so a message never stacks three banners.
- Rate limits for remote plugins, and whether triggers are allowed to send
  notifications or only update cards.

## Brand marks

Plugin cards, Settings → Plugins and Settings → AI show the logo of the
service they connect to, only to identify it. Postmere's own interface keeps
its drawn icons.

- Single-colour marks for GitHub, Linear, Jira, Sentry, Vercel, Netlify,
  PagerDuty, Opsgenie, Claude, OpenAI and Cursor come from Simple Icons (CC0),
  drawn in each brand's official colour, unaltered.
- VS Code uses Microsoft's logo from code.visualstudio.com/brand; Microsoft
  asked Simple Icons not to carry its marks.
- Assets live in `Assets.xcassets/Brands`. A card names its service with
  `brand`; a plugin lists the services it covers in `brands` (two show as an
  overlapping pair). Follow each company's brand guidelines when adding one.
