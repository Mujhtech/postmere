#!/usr/bin/env bash
set -euo pipefail

# Standalone offline fixtures only. Every HTTP request is intercepted and DNS
# answers are injected. This never contacts or unsubscribes a real mailing list.
project_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
test_root="$(mktemp -d "${TMPDIR:-/tmp}/postmere-unsubscribe.XXXXXX")"
trap 'rm -rf "$test_root"' EXIT

swiftc -swift-version 5 -default-isolation MainActor -parse-as-library \
  -module-cache-path "$test_root/module-cache" \
  "$project_root/postmere/postmere/Models/MailMessage.swift" \
  "$project_root/postmere/postmere/Models/MailWorkflow.swift" \
  "$project_root/postmere/postmere/Services/GmailTypes.swift" \
  "$project_root/postmere/postmere/Services/GmailMessageMapper.swift" \
  "$project_root/postmere/postmere/Services/MailUnsubscribeService.swift" \
  "$project_root/script/test_unsubscribe.swift" \
  -o "$test_root/unsubscribe-fixtures"

"$test_root/unsubscribe-fixtures"
