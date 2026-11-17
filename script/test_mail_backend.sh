#!/bin/bash
set -euo pipefail

project_root="$(cd "$(dirname "$0")/.." && pwd)"
test_directory="$(mktemp -d "${TMPDIR:-/tmp}/postmere-backend.XXXXXX")"
trap 'rm -rf "$test_directory"' EXIT

sources=(
  "$project_root/postmere/postmere/Models/MailMessage.swift"
  "$project_root/postmere/postmere/Models/BackendMail.swift"
  "$project_root/postmere/postmere/Models/MailWorkflow.swift"
  "$project_root/postmere/postmere/Models/MailSearchQuery.swift"
  "$project_root/postmere/postmere/Models/InboxSplit.swift"
  "$project_root/postmere/postmere/Models/SampleMail.swift"
  "$project_root/postmere/postmere/Stores/"*.swift
  "$project_root/postmere/postmere/Support/ComposeAttachments.swift"
  "$project_root/postmere/postmere/Support/MailTemplate.swift"
  "$project_root/postmere/postmere/Support/MailSignature.swift"
  "$project_root/postmere/postmere/Support/MailSenderContext.swift"
  "$project_root/script/test_mail_backend.swift"
  "$project_root/script/test_search_splits.swift"
  "$project_root/script/test_remote_mail.swift"
)
xcrun swiftc -module-cache-path "$test_directory/ModuleCache" -swift-version 6 \
  -default-isolation MainActor -o "$test_directory/regression" "${sources[@]}"
"$test_directory/regression"
