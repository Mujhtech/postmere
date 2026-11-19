# Postmere

A native SwiftUI email client for macOS. All Google and Microsoft mail accounts connect through a Rust/PostgreSQL workspace server, with no application-imposed limit on connected accounts. The backend uses a [Cargo workspace of connected feature crates](server/ARCHITECTURE.md).

Messages, unfinished drafts, rich text, attachments, snippets, saved views, sender rules, and private notes persist on this Mac. File attachments are copied into app-owned storage. An interrupted draft can be resumed after launch; a damaged mailbox file is preserved and reported instead of silently overwritten.

## Working with mail

- **Command palette:** ⌘K searches actions, mailboxes, saved views, settings, and the attachment library.
- **Keyboard triage:** J/K moves through the focused message list; E archives, # moves to Trash, R replies, and S toggles a star. These keys do not intercept typing in search or the composer.
- **Batch actions:** Command-click or Shift-click messages, then archive, trash, mark read, star, or add them to Needs Reply. Mailbox moves support Undo.
- **Workflow queues:** Needs Reply, Snoozed, Follow-ups, and New Senders show one task per conversation. Message actions include private notes, custom snooze dates, and follow-up reminders that cancel when a newer reply arrives.
- **Split Inbox and VIPs:** Reorder or hide focused inbox tabs, customize their filters, and mark people or domains as VIPs. Choose first-match or overlapping tab membership; unread counts and selections persist.
- **Search and saved views:** Use `from:`, `to:`, `subject:`, `before:`, `after:`, `has:attachment`, `is:unread`, `is:starred`, quoted phrases, and exclusions. Save the same criteria as a view or inbox tab. Provider-wide search supports pagination beyond the local cache.
- **Sender rules:** Settings → Rules enables screening of unfamiliar incoming senders and routes accepted senders to Inbox, Archive, Needs Reply, or Trash.
- **Attachment library:** ⌥⌘A searches files by name, sender, or subject and supports Quick Look, Save As, and opening the source message. Attachments download through the workspace on demand.

Conversations expand earlier messages individually or together. A thin overlay scrollbar shows your position and supports dragging.

With no message selected, the reader shows unread conversations, replies due, and follow-ups for the current account. **Start triage** opens the first conversation in its queue. The reader toolbar includes Star, Snooze, and Summarize. Click **Reply** to reply directly or use its arrow for Reply All and Forward.

The chevron beside the recipients opens message details, including the return path, declared signing domains, and receiving hop’s transport when available. Settings → Privacy controls automatic remote images and sender tracking protection. Both are on by default. Turn off automatic images to decide per message. The reader counts detected tracking pixels that it blocks. Sender and recipient avatars use available Contacts photos and optional Gravatar photos. For other participants, Postmere can look up their organization’s website icon. This setting is on by default. Settings → Privacy explains which domains and identifiers each service receives.

Postmere uses a shared custom vector icon family for navigation, actions, and formatting. Attachments have distinct file-type artwork and extension badges across the reader, composer, library, and preview window. Available local files can show a Quick Look content thumbnail; remote, missing, or unsupported files keep their type artwork without downloading anything. Thumbnail work is asynchronous, cached, and cancelled when no longer needed.

## Composing and delivery

Composition uses a separate native window with To/Cc/Bcc fields, account selection, recipient suggestions, attachments, rich-text formatting, and saved snippets. Reusable templates preserve subject, recipients, rich text, files, and fields such as `{{name}}`; preview append or replace before applying with native Undo. Per-account signatures support new messages, replies, and forwards. Optional Markdown substitutions support inline formatting, headings, lists, quotes, and fenced code with native Undo.

The attachment button and editor context menu support macOS Continuity Camera. Available nearby iPhone/iPad photo, scan, and sketch actions are supplied by macOS; supported devices must use the same Apple Account and meet Apple's Continuity requirements. Camera hardware availability is not simulated.

Send places mail in a durable Outbox with a configurable 5–60 second Undo Send delay. The send menu also schedules delivery and follow-up reminders. Cancel a pending send to restore its draft; failed sends stay in Outbox with the actual error and a retry action. An ambiguous or interrupted provider delivery requires checking Sent before retrying, to avoid duplicates.

Sends upload immediately to the durable server queue. Keep Postmere open until server acceptance appears; delivery then continues while the Mac is closed or asleep. The server itself must remain running. An unconfirmed provider response is never automatically resent. Tests never send real email.

## Account setup

On first launch, sign in on the required workspace setup screen using your server URL, workspace ID, email, and password. Postmere opens mail only after the server verifies the session. You stay signed in until you sign out or access is revoked. Saved sessions are checked before restoring access; signing out returns every window to setup. Mail shortcuts and auxiliary windows cannot bypass this screen.

If the connection is unavailable, Postmere retries your saved sign-in without asking for a password. Signing out locks the Mac immediately; any pending server revocation is stored securely and retried when the app can reconnect.

Once connected, open **Settings → Accounts**. Choose **Add Google** or **Add Outlook**, finish browser sign-in, and repeat for each email account. Each account has its own sender identity, inbox, signature, and notification settings. The account menu supports reconnecting or disconnecting one account without replacing the others. Enable calendar access during connection if you want booking and RSVP.

There is no connected-account count cap in Postmere. Provider quotas and server capacity still determine throughput. The server bounds concurrent operations and unfinished sign-in attempts separately from the number of connected accounts.

Provider OAuth configuration and credentials live on the server; see [server setup](server/README.md). The Mac keeps only its workspace session in Keychain and needs outgoing network access. Use an appropriately signed Xcode build for Keychain-backed sign-in; unsigned verification builds may be unable to save credentials.

Mail, sync cursors, notes, and files are scoped to server, workspace, user, and account. Disconnecting hides cached mail from the active workspace but retains local data. Fresh installs start empty. Previous direct-Gmail connections are no longer used; existing caches and drafts remain saved, and old local sends are stopped rather than transferred or sent automatically. Open **Settings → Accounts → Previous local drafts** to review those drafts. Recoverable drafts require an explicit workspace sender selection before sending; previously interrupted attempts retain their provider warning and a reminder to check Sent.

Live OAuth, account sync/send, and device capture require configured services or hardware. Automated provider checks use fixtures.

## Notifications and Focus

Settings → Notifications controls each account separately, including weekdays, working hours, and subject previews. Enable notifications when ready. macOS Focus Filters allow specific accounts through a Focus. Reminder scheduling is local; no-reply cancellation can take effect only after Postmere has synced the reply. A live connection refreshes the Mac app when server mail, accounts, or delivery status changes; reconnecting catches up from saved cursors. Configured Gmail and Microsoft notifications trigger server sync; polling about once a minute remains a fallback.

Optional Apple push notifications deliver new-mail alerts while Postmere is closed, subject to macOS delivery and Focus settings. They require a signed app, APNs credentials, and a running server; follow the [Docker Compose setup](server/deploy/README.md). Device registrations remain active until sign-out, access revocation, account disconnection or notifications are disabled; keeping the app closed does not expire them. Sender-screening and routing preferences also apply to server alerts while the app is closed. Offline preference changes reach the server when the app reconnects. Focus account choices come from your connected workspace accounts.

## Workspace, calendar, collaboration, and AI

Provider credentials remain encrypted on the server; the Mac stores its workspace session in Keychain. Mail, sync cursors, private notes, and cached attachments are scoped to the server, workspace, user, and account. Provider-confirmed deletions hide cached originals while retaining private notes and drafts.

The server requires deployment and provider configuration; see [server setup](server/README.md). No production server or provider account is provisioned automatically.

The backend also provides [remote MCP](docs/remote-mcp.md) for ChatGPT and other OAuth clients. Assistants stay connected until workspace sign-out or access revocation. They can read mail, draft, and manage messages; sending, trashing, and disconnecting accounts require explicit approval in Postmere's browser review page. Manage or revoke connections from Settings → Accounts.

- **Unsubscribe:** The message reader offers standard mailing-list actions. Workspace one-click requests require a cryptographically verified DKIM signature and an explicit action. The server fetches raw MIME from Google or Microsoft, verifies that the signature covers both list headers, and rechecks the exact URL before an isolated HTTPS request. Browser/email fallbacks and archive/block actions show their separate outcomes.
- **Calendar:** Message → Calendar Agenda opens calendars on this Mac, booking links, and team availability. Local calendar access is requested only when enabled. Recognized dates open an editable event draft; `.ics` attachments have invitation previews. The composer can insert static availability or a live booking link.
- **Provider scheduling:** Enable calendar access when connecting an account to create booking links or RSVP to invitations. Choose an event destination and up to eight calendars for conflict checks, then offer specific times or weekly hours in a chosen time zone. Teammate free/busy access requires explicit sharing of the selected calendars. Booking history supports cancellation and provider status checks; uncertain outcomes keep their time reserved until confirmed, without creating another event.
- **Sender context:** The message menu opens scoped conversations, recent files, VIP settings, and private contact notes. Recipient suggestions use available mail and exclude Bcc-only contacts and screened/trashed senders.
- **Collaboration:** Message → Workspace contains shared snapshots, comments, reply presence, team templates, and members. Share Conversation lets the owner choose participants and view/comment access. Snapshots omit Bcc and attachment contents; later messages require an explicit refresh. Team templates have a separate content preview before publishing recipients and files.
- **AI:** Enable optional assistance in Settings after the server administrator configures OpenAI. Actions include sourced summaries, draft/rewrite, reviewable follow-up/archive/Needs Reply suggestions, and questions over server-indexed mail. Outputs stay editable; suggestions require an explicit apply action. Attachments and calendar data are excluded from AI context. The server uses bounded, scoped retrieval and never gives the model mail-sending or arbitrary tools.
- **Delivery activity:** The composer’s Send menu has separate opt-in open and link tracking. Sent messages open an activity panel with counts, first/latest opens, device categories, and request history. Privacy proxies and automated requests are identified where possible; activity is a signal, not proof a person read the message.

External OAuth consent, real provider delivery/RSVP, public booking access, and paid AI calls require deployment and the user's configured accounts. Offline tests use intercepted provider traffic; no real mail or calendar invitations are sent.

## Build and verification

See the [verification report](docs/verification-2026-11-18.md) for completed checks and remaining live-service verification.

Open `postmere/postmere.xcodeproj` in Xcode, or run:

```sh
./script/build_and_run.sh --verify
```

The project targets macOS 27 and uses Xcode 27.1. Local builds disable code signing and write products and logs to `.build/`. Use `--debug` for LLDB or `--logs` for app logs. Signed builds enable outgoing network access; provider OAuth callbacks terminate on the server.

Run the offline regression suites together or select individual suites by name.

```sh
./script/test.sh
./script/test.sh composer templates
./script/test.sh --help
```

Provider protocol, OAuth, MIME, synchronization, delivery, and account-isolation regressions run in the [Rust workspace suite](server/README.md#verification). Native suites use temporary state, in-memory credentials, intercepted HTTP, and a fake notification center; they do not send real email or request permissions.

The editable layered icon is `postmere/postmere/AppIcon.icon`; its SVG sources and previews are in `design/icon/`.
