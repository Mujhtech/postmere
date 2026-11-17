#!/bin/bash
set -euo pipefail

project_dir="$(cd "$(dirname "$0")/.." && pwd)"
test_dir="$(mktemp -d /private/tmp/postmere-notifications.XXXXXX)"
trap 'rm -rf "$test_dir"' EXIT

xcrun swiftc -swift-version 5 -default-isolation MainActor \
  -target "$(uname -m)-apple-macos27.0" \
  -module-cache-path /private/tmp/postmere-test-module-cache \
  "$project_dir/postmere/postmere/Models/MailMessage.swift" \
  "$project_dir/postmere/postmere/Models/MailWorkflow.swift" \
  "$project_dir/postmere/postmere/Models/NotificationProfile.swift" \
  "$project_dir/postmere/postmere/Support/MailFocusFilter.swift" \
  "$project_dir/postmere/postmere/Services/MailNotificationService.swift" \
  "$project_dir/script/test_notifications.swift" \
  -o "$test_dir/checks"

"$test_dir/checks"
