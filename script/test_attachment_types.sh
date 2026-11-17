#!/bin/bash
set -euo pipefail

project_dir="$(cd "$(dirname "$0")/.." && pwd)"
test_dir="$(mktemp -d /private/tmp/postmere-attachment-types.XXXXXX)"
trap 'rm -rf "$test_dir"' EXIT

xcrun swiftc -parse-as-library -swift-version 5 -default-isolation MainActor \
  -module-cache-path /private/tmp/postmere-test-module-cache \
  "$project_dir/postmere/postmere/Support/AttachmentFileType.swift" \
  "$project_dir/script/test_attachment_types.swift" -o "$test_dir/checks"

"$test_dir/checks"
