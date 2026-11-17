#!/bin/bash
set -euo pipefail
project_dir="$(cd "$(dirname "$0")/.." && pwd)"
test_dir="$(mktemp -d /private/tmp/postmere-calendar.XXXXXX)"
trap 'rm -rf "$test_dir"' EXIT

xcrun swiftc -parse-as-library -swift-version 5 -default-isolation MainActor \
  -module-cache-path /private/tmp/postmere-test-module-cache \
  "$project_dir/postmere/postmere/Support/PostmereTheme.swift" \
  "$project_dir/postmere/postmere/Support/PostmereIcon.swift" \
  "$project_dir/postmere/postmere/Support/MailCalendar.swift" \
  "$project_dir/postmere/postmere/Support/MailCalendarInvitation.swift" \
  "$project_dir/postmere/postmere/Services/MailCalendarService.swift" \
  "$project_dir/postmere/postmere/Views/CalendarViews.swift" \
  "$project_dir/postmere/postmere/Views/CalendarInvitationView.swift" \
  "$project_dir/script/test_calendar.swift" -o "$test_dir/checks"

"$test_dir/checks"
