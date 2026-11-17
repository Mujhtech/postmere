# Postmere

A native SwiftUI email client for macOS, with local sample accounts, optional direct Gmail, and a Rust/PostgreSQL workspace server for multiple Google and Microsoft accounts. The backend uses a [Cargo workspace of connected feature crates](server/ARCHITECTURE.md).

Messages, unfinished drafts, rich text, attachments, snippets, saved views, sender rules, and private notes persist on this Mac. File attachments are copied into app-owned storage. An interrupted draft can be resumed after launch; a damaged mailbox file is preserved and reported instead of silently overwritten.

## Working with mail

- **Command palette:** ⌘K searches actions, mailboxes, saved views, settings, and the attachment library.
- **Keyboard triage:** J/K moves through the focused message list; E archives, # moves to Trash, R replies, and S toggles a star. These keys do not intercept typing in search or the composer.
- **Batch actions:** Command-click or Shift-click messages, then archive, trash, mark read, star, or add them to Needs Reply. Mailbox moves support Undo.
- **Workflow queues:** Needs Reply, Snoozed, Follow-ups, and New Senders show one task per conversation. Message actions include private notes, custom snooze dates, and follow-up reminders that cancel when a newer reply arrives.
- **Split Inbox and VIPs:** Reorder or hide focused inbox tabs, customize their filters, and mark people or domains as VIPs. Choose first-match or overlapping tab membership; unread counts and selections persist.
- **Search and saved views:** Use `from:`, `to:`, `subject:`, `before:`, `after:`, `has:attachment`, `is:unread`, `is:starred`, quoted phrases, and exclusions. Save the same criteria as a view or inbox tab. Workspace accounts also have a separate provider-wide search with pagination.
- **Sender rules:** Settings → Rules enables screening of unfamiliar incoming senders and routes accepted senders to Inbox, Archive, Needs Reply, or Trash.
- **Attachment library:** ⌥⌘A searches files by name, sender, or subject and supports Quick Look, Save As, and opening the source message. Gmail attachments download on demand.

The selected **Fieldnotes — identity direction** sample demonstrates a three-message conversation. Earlier messages expand individually or together. Scroll indicators remain hidden while scrolling stays available.

Postmere uses a shared custom vector icon family for navigation, actions, and formatting. Attachments have distinct file-type artwork and extension badges across the reader, composer, library, and preview window. Available local files can show a Quick Look content thumbnail; remote, missing, or unsupported files keep their type artwork without downloading anything. Thumbnail work is asynchronous, cached, and cancelled when no longer needed.

## Composing and delivery

Composition uses a separate native window with To/Cc/Bcc fields, account selection, recipient suggestions, attachments, rich-text formatting, and saved snippets. Reusable templates preserve subject, recipients, rich text, files, and fields such as `{{name}}`; preview append or replace before applying with native Undo. Per-account signatures support new messages, replies, and forwards. Optional Markdown substitutions support inline formatting, headings, lists, quotes, and fenced code with native Undo.

The attachment button and editor context menu support macOS Continuity Camera. Available nearby iPhone/iPad photo, scan, and sketch actions are supplied by macOS; supported devices must use the same Apple Account and meet Apple's Continuity requirements. Camera hardware availability is not simulated.

Send places mail in a durable Outbox with a configurable 5–60 second Undo Send delay. The send menu also schedules delivery and follow-up reminders. Cancel a pending send to restore its draft; failed sends stay in Outbox with the actual error and a retry action. An ambiguous or interrupted Gmail delivery requires checking Sent before retrying, to avoid duplicates.

**Direct Gmail and sample-account delivery require Postmere to remain open and the Mac awake.** Due local delivery resumes on the next launch. Workspace sends upload immediately to the durable server queue; after the app shows server acceptance, delivery continues while the Mac is closed or asleep. The server itself must remain running. An unconfirmed provider response is never automatically resent. Work and Personal are local sample accounts; their Send Preview action only adds to local Sent. Gmail sends real email after connection. No real email is sent by the test suites.

## Gmail setup

Open Settings → Accounts. Create a **Desktop app** OAuth client in your Google Cloud project, enable the Gmail API, and configure the consent screen. While the project is in testing, add the signing-in account as a test user. Enter the client ID and optional client secret, then choose **Save setup for later** or **Sign in with Google**.

Postmere uses Google's browser sign-in, PKCE, an ephemeral loopback callback, and the macOS Keychain for OAuth credentials. It requests Gmail read/send/organize access (`gmail.modify`). A public distribution may require Google's verification. See [Google's installed-app OAuth guide](https://developers.google.com/identity/protocols/oauth2/native-app) and [Gmail scopes](https://developers.google.com/workspace/gmail/api/auth/scopes).

Use an appropriately signed Xcode build for real Gmail setup. The macOS data-protection Keychain relies on the app's signing identity and application identifier; unsigned verification builds may be unable to save credentials. The sandbox also needs outgoing network access and incoming network access for the callback, which binds only to `127.0.0.1` on a temporary port. No custom URL scheme or Google password is stored.

Direct Gmail supports one connected account at a time. The workspace connection supports multiple Google and Microsoft accounts. Cached mail and local drafts remain on disk after disconnecting; account identity checks prevent an old account's drafts or actions from being applied to a new account. The initial and periodic sync cover the latest 500 messages, including Trash but excluding Spam; Settings indicates when older mail remains in Gmail. Up to 12 cached messages outside that window are checked separately per sync, with a 30-minute minimum between repeat checks. Only an explicit Gmail not-found response marks a cached message unavailable; falling outside the window never counts as deletion, and local notes and drafts remain intact. Read/star/archive/trash changes sync to Gmail. Drafts, notes, workflow queues, saved views, and sender rules are local to this Mac. HTML-only messages use a plain-text rendering, without loading remote tracking images.

Live OAuth consent, real-account sync/send, and device capture require the user's credentials or hardware. Offline fixtures cover protocol behavior, parsing, MIME generation, token refresh, account isolation, and the loopback callback.

## Notifications and Focus

Settings → Notifications controls each account separately, including weekdays, working hours, and subject previews. Enable notifications when ready. macOS Focus Filters allow specific accounts through a Focus. Reminder scheduling is local; no-reply cancellation can take effect only after Postmere has synced the reply. When the app is closed, direct Gmail is not polled. A configured workspace server continues account sync and delivery; notifications on this Mac resume after the client reconnects.

## Workspace, calendar, collaboration, and AI

Open Settings → Accounts → Workspace and enter your server URL, workspace ID, and sign-in details. Connect Google or Microsoft through their browser OAuth flow. Provider credentials remain encrypted on the server; the Mac stores its workspace session in Keychain. Mail, sync cursors, private notes, and cached attachments are scoped to the server, workspace, user, and account. Provider-confirmed deletions hide cached originals while retaining private notes and drafts.

The server requires deployment and provider configuration; see [server setup](server/README.md). No production server or provider account is provisioned automatically.

- **Unsubscribe:** The message reader offers standard mailing-list actions. Workspace one-click requests require a cryptographically verified DKIM signature and an explicit action. The server fetches raw MIME from Google or Microsoft, verifies that the signature covers both list headers, and rechecks the exact URL before an isolated HTTPS request. Direct Gmail uses browser/email options because copied authentication headers alone cannot prove authenticity. Browser/email fallbacks and archive/block actions show their separate outcomes.
- **Calendar:** Message → Calendar Agenda opens calendars on this Mac, booking links, and team availability. Local calendar access is requested only when enabled. Recognized dates open an editable event draft; `.ics` attachments have invitation previews. The composer can insert static availability or a live booking link.
- **Provider scheduling:** Enable calendar access when connecting an account to create booking links or RSVP to invitations. Booking pages check the primary provider calendar and reserve slots across all links for that account. They do not check secondary calendars. Teammate free/busy access requires explicit sharing within the workspace. An uncertain event-creation response reserves its slot for review rather than risking another booking.
- **Sender context:** The message menu opens scoped conversations, recent files, VIP settings, and private contact notes. Recipient suggestions use available mail and exclude Bcc-only contacts and screened/trashed senders.
- **Collaboration:** Message → Workspace contains shared snapshots, comments, reply presence, team templates, and members. Share Conversation lets the owner choose participants and view/comment access. Snapshots omit Bcc and attachment contents; later messages require an explicit refresh. Team templates have a separate content preview before publishing recipients and files.
- **AI:** Enable optional assistance in Settings after the server administrator configures OpenAI. Actions include sourced summaries, draft/rewrite, reviewable follow-up/archive/Needs Reply suggestions, and questions over server-indexed mail. Outputs stay editable; suggestions require an explicit apply action. Attachments and calendar data are excluded from AI context. The server uses bounded, scoped retrieval and never gives the model mail-sending or arbitrary tools.
- **Delivery activity:** The composer’s Send menu has separate opt-in open and link tracking. Sent messages open an activity panel with counts, first/latest opens, device categories, and request history. Privacy proxies and automated requests are identified where possible; activity is a signal, not proof a person read the message.

External OAuth consent, real provider delivery/RSVP, public booking access, and paid AI calls require deployment and the user's configured accounts. Offline tests use intercepted provider traffic; no real mail or calendar invitations are sent.

## Build and verification

See the [verification report](docs/verification-2026-11-17.md) for completed checks and remaining live-service verification.

Open `postmere/postmere.xcodeproj` in Xcode, or run:

```sh
./script/build_and_run.sh --verify
```

The project targets macOS 27 and uses Xcode 27.1. Local builds disable code signing and write products and logs to `.build/`. Use `--debug` for LLDB or `--logs` for app logs. Signed builds enable outgoing network access and a loopback listener for OAuth.

Offline regression checks:

```sh
bash script/test_mail_backend.sh
bash script/test_gmail_provider.sh
bash script/test_notifications.sh
bash script/test_composer.sh
bash script/test_attachment_types.sh
bash script/test_templates.sh
bash script/test_signatures.sh
bash script/test_unsubscribe.sh
bash script/test_calendar.sh
bash script/test_sender_context.sh
bash script/test_backend_client.sh
bash script/test_backend_session.sh
```

The Gmail fixture runner uses in-memory credentials and intercepts every Google request; it never accesses the real Keychain or sends email. Add `--loopback` to check the actual local OAuth callback and state validation without opening a browser. The runner also validates its generated message with Python's independent MIME parser.

The provider runner also accepts `--loopback` to test the local OAuth callback without opening a browser. The suites use temporary state, in-memory credentials, and a fake notification center; they do not send real email or request permissions.

The editable layered icon is `postmere/postmere/AppIcon.icon`; its SVG sources and previews are in `design/icon/`.
