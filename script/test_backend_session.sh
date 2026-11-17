#!/usr/bin/env bash
set -euo pipefail

# Offline session-state fixtures. Uses in-memory credentials and URLProtocol;
# never reads or modifies the user's Keychain or contacts a real server.
project_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
test_root="$(mktemp -d "${TMPDIR:-/tmp}/postmere-session.XXXXXX")"
trap 'rm -rf "$test_root"' EXIT
xcrun swiftc -O -swift-version 6 -default-isolation MainActor -parse-as-library \
  -module-cache-path "$test_root/module-cache" \
  "$project_root/postmere/postmere/Models/MailMessage.swift" \
  "$project_root/postmere/postmere/Models/MailWorkflow.swift" \
  "$project_root/postmere/postmere/Models/BackendMail.swift" \
  "$project_root/postmere/postmere/Services/BackendHTTPClient.swift" \
  "$project_root/postmere/postmere/Services/BackendKeychain.swift" \
  "$project_root/postmere/postmere/Services/BackendSession.swift" \
  "$project_root/script/test_backend_session.swift" \
  -o "$test_root/backend-session-fixtures"
"$test_root/backend-session-fixtures"
