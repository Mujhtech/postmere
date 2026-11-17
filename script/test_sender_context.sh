#!/bin/bash
set -euo pipefail
project_dir="$(cd "$(dirname "$0")/.." && pwd)"
test_dir="$(mktemp -d /private/tmp/postmere-contact-context.XXXXXX)"
trap 'rm -rf "$test_dir"' EXIT

xcrun swiftc -swift-version 6 -default-isolation MainActor \
  -module-cache-path /private/tmp/postmere-test-module-cache \
  "$project_dir/postmere/postmere/Models/MailMessage.swift" \
  "$project_dir/postmere/postmere/Models/BackendMail.swift" \
  "$project_dir/postmere/postmere/Models/MailWorkflow.swift" \
  "$project_dir/postmere/postmere/Models/MailSearchQuery.swift" \
  "$project_dir/postmere/postmere/Models/InboxSplit.swift" \
  "$project_dir/postmere/postmere/Models/SampleMail.swift" \
  "$project_dir/postmere/postmere/Stores/"*.swift \
  "$project_dir/postmere/postmere/Support/ComposeAttachments.swift" \
  "$project_dir/postmere/postmere/Support/MailTemplate.swift" \
  "$project_dir/postmere/postmere/Support/MailSignature.swift" \
  "$project_dir/postmere/postmere/Support/MailSenderContext.swift" \
  "$project_dir/postmere/postmere/Services/MailContactNotesStore.swift" \
  "$project_dir/postmere/postmere/Support/PostmereTheme.swift" \
  "$project_dir/postmere/postmere/Support/PostmereIcon.swift" \
  "$project_dir/postmere/postmere/Support/AttachmentFileType.swift" \
  "$project_dir/postmere/postmere/Support/AttachmentIconView.swift" \
  "$project_dir/postmere/postmere/Views/SenderContextView.swift" \
  "$project_dir/postmere/postmere/Views/RecipientSuggestionsView.swift" \
  "$project_dir/script/test_sender_context.swift" -o "$test_dir/checks"

"$test_dir/checks"
