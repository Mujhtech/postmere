#!/bin/bash
set -euo pipefail

project_dir="$(cd "$(dirname "$0")/.." && pwd)"
test_dir="$(mktemp -d /private/tmp/postmere-signatures.XXXXXX)"
trap 'rm -rf "$test_dir"' EXIT

cat "$project_dir/postmere/postmere/Models/MailMessage.swift" \
  "$project_dir/postmere/postmere/Models/MailWorkflow.swift" \
  "$project_dir/postmere/postmere/Support/PostmereTheme.swift" \
  "$project_dir/postmere/postmere/Support/PostmereIcon.swift" \
  "$project_dir/postmere/postmere/Support/MailTemplate.swift" \
  "$project_dir/postmere/postmere/Support/MailSignature.swift" \
  "$project_dir/postmere/postmere/Support/MarkdownSubstitutions.swift" \
  "$project_dir/postmere/postmere/Support/ComposeContinuityCamera.swift" \
  "$project_dir/postmere/postmere/Support/ComposeBodyEditor.swift" \
  "$project_dir/postmere/postmere/Views/SignatureEditorView.swift" \
  "$project_dir/script/test_signatures.swift" > "$test_dir/checks.swift"

xcrun swiftc -parse-as-library -swift-version 5 -default-isolation MainActor \
  -target "$(uname -m)-apple-macos27.0" \
  -module-cache-path /private/tmp/postmere-test-module-cache \
  "$test_dir/checks.swift" -o "$test_dir/checks"

"$test_dir/checks"
