#!/usr/bin/env bash
set -euo pipefail

# This compiles a standalone fixture executable, never the app. URLProtocol replaces
# every Google request; credentials use an in-memory actor, not the real Keychain.
# Optional --loopback exercises only 127.0.0.1 and does not open a browser.
project_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
build_root="$(mktemp -d "${TMPDIR:-/tmp}/postmere-gmail.XXXXXX")"
trap 'rm -rf "$build_root"' EXIT
cd "$project_root"

swiftc -swift-version 5 -default-isolation MainActor \
  -module-cache-path "$build_root/module-cache" -parse-as-library \
  postmere/postmere/Models/MailMessage.swift \
  postmere/postmere/Models/MailWorkflow.swift \
  postmere/postmere/Services/GmailTypes.swift \
  postmere/postmere/Services/GmailKeychain.swift \
  postmere/postmere/Services/GoogleDesktopOAuth.swift \
  postmere/postmere/Services/GmailAPIClient.swift \
  postmere/postmere/Services/GmailMIME.swift \
  postmere/postmere/Services/GmailMessageMapper.swift \
  script/test_gmail_provider.swift \
  -o "$build_root/gmail-fixtures"

POSTMERE_FIXTURE_MIME_PATH="$build_root/message.eml" "$build_root/gmail-fixtures" "$@"

python3 - "$build_root/message.eml" <<'PY'
import sys
from email import policy
from email.parser import BytesParser
from pathlib import Path

raw = Path(sys.argv[1]).read_bytes()
message = BytesParser(policy=policy.default).parsebytes(raw)
assert str(message['Subject']) == 'A long café subject with ✓ and emoji 😊 that spans encoded words safely'
assert message['From'].addresses[0].display_name == 'Míriam'
assert message['Bcc'].addresses[0].addr_spec == 'private@example.com'
assert message['In-Reply-To'] == '<prior@example.com>'
assert message.get_body(preferencelist=('plain',)).get_content() == 'Hello café\r\n\r\nSecond paragraph'
assert message.get_body(preferencelist=('html',)).get_content() == '<p>Hello café</p>'
attachments = list(message.iter_attachments())
assert len(attachments) == 1
assert attachments[0].get_filename() == 'résumé.pdf'
assert attachments[0].get_payload(decode=True) == bytes([0, 1, 2, 3, 255])
assert not message.defects
assert all(len(line) <= 998 for line in raw.split(b'\r\n'))
print('PASS: independent Python MIME parser verified Unicode headers and filename, Bcc, reply headers, alternative bodies, binary attachment, and RFC line lengths')
PY
