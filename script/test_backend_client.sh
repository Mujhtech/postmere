#!/usr/bin/env bash
set -euo pipefail

# Offline transport fixtures. URLProtocol intercepts every HTTP request.
project_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
test_root="$(mktemp -d "${TMPDIR:-/tmp}/postmere-http-client.XXXXXX")"
trap 'rm -rf "$test_root"' EXIT

xcrun swiftc -O -swift-version 6 -default-isolation MainActor -parse-as-library \
  -module-cache-path "$test_root/module-cache" \
  "$project_root/postmere/postmere/Services/BackendHTTPClient.swift" \
  "$project_root/script/test_backend_client.swift" \
  -o "$test_root/backend-client-fixtures"
"$test_root/backend-client-fixtures"
