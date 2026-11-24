#!/usr/bin/env bash
set -euo pipefail

suites=(mail_backend notifications composer attachment_types templates signatures
        backend_events backend_push
        unsubscribe calendar sender_context sender_profile backend_client backend_session plugins links triage)

usage() {
    printf 'Usage: %s [suite ...]\nRun all native suites by default. Available suites:\n' "${0##*/}"
    printf '  %s\n' "${suites[@]}"
}

if [[ ${1:-} == --help || ${1:-} == -h ]]; then
    usage
    exit 0
fi
if [[ $# -eq 0 ]]; then
    set -- "${suites[@]}"
fi

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
project_root="$(dirname -- "$script_dir")"
cd "$project_root/postmere/postmere"
test_dir="$(mktemp -d "${TMPDIR:-/tmp}/postmere-tests.XXXXXX")"
trap 'rm -rf "$test_dir"' EXIT

mail_models=(Models/MailMessage.swift Models/ReceivedMailBody.swift Models/MailHTMLDocument.swift Models/MailWorkflow.swift)
backend_models=("${mail_models[@]}" Models/BackendMail.swift Models/BackendSenderMark.swift Models/BackendAssistants.swift Support/MailPlatform.swift)
summary_sources=(Models/MailAI.swift Services/BackendSummaryStream.swift)
store_sources=("${backend_models[@]}" Models/MailMessage+SmartCategories.swift Models/MailReplyIntent.swift Models/MailSearchQuery.swift Models/InboxSplit.swift
              Models/SampleMail.swift Stores/*.swift Support/ComposeAttachments.swift
              Support/MailTemplate.swift Support/MailSignature.swift Support/MailSenderContext.swift Support/MailSenderDomain.swift)
theme=(Support/MailPlatform.swift Support/MailboxTheme.swift Support/PostmereAccent.swift Support/PostmereTheme.swift Support/PostmereIcon.swift)
attachment_views=(Support/AttachmentFileType.swift Support/AttachmentIconView.swift)
editor_sources=("${mail_models[@]}" "${theme[@]}" Support/MailTemplate.swift
                Support/MarkdownSubstitutions.swift Support/ComposeContinuityCamera.swift
                Support/ComposeBodyEditor.swift)
mac_target=(-target "$(uname -m)-apple-macos27.0")

# Source groups overlap (the platform shim is in several), so list each file once.
unique_sources() {
    local -a unique=()
    local source
    for source in "${sources[@]}"; do
        [[ " ${unique[*]-} " == *" $source "* ]] || unique+=("$source")
    done
    sources=("${unique[@]}")
}

run_suite() {
    local suite="$1"
    local fixture="$script_dir/test_$suite.swift"
    local binary="$test_dir/$suite"
    local -a sources flags
    case "$suite" in
        mail_backend)
            flags=(-swift-version 6)
            sources=("${store_sources[@]}" Models/MailSyncActivity.swift Support/MailVerificationCode.swift "$script_dir/test_search_splits.swift" "$script_dir/test_remote_mail.swift")
            ;;
        sender_profile)
            flags=(-swift-version 6 -parse-as-library)
            sources=("${mail_models[@]}" Models/BackendSenderProfile.swift Services/MailSenderProfile.swift Services/BackendHTTPClient.swift
                     "$script_dir/test_realtime_support.swift")
            ;;
        sender_context)
            flags=(-swift-version 6)
            sources=("${store_sources[@]}" Models/BackendSenderProfile.swift Services/MailSenderProfile.swift Services/MailContactNotesStore.swift Services/MailRemoteParticipantImages.swift Services/BackendHTTPClient.swift
                     "${theme[@]}" "${attachment_views[@]}" Views/SenderContextView.swift Views/RecipientSuggestionsView.swift
                     "$script_dir/test_realtime_support.swift")
            ;;
        backend_client)
            flags=(-swift-version 6 -parse-as-library -O)
            sources=(Services/BackendHTTPClient.swift Services/BackendEvents.swift "${summary_sources[@]}")
            ;;
        backend_session)
            flags=(-swift-version 6 -parse-as-library -O)
            sources=("${store_sources[@]}" "${summary_sources[@]}" Services/BackendHTTPClient.swift Services/BackendEvents.swift Services/BackendKeychain.swift Services/BackendSession.swift Services/MailSpamChecks.swift)
            ;;
        triage)
            flags=(-swift-version 6 -parse-as-library)
            sources=(Stores/TriageSession.swift)
            ;;
        links)
            flags=(-swift-version 6 -parse-as-library)
            sources=(Support/MailLinkDetector.swift)
            ;;
        plugins)
            flags=(-swift-version 6 -parse-as-library)
            sources=(Models/BackendPlugins.swift Models/BackendTriage.swift Services/BackendHTTPClient.swift)
            ;;
        backend_events)
            flags=(-swift-version 6 -parse-as-library -O)
            sources=(Services/BackendHTTPClient.swift Services/BackendEvents.swift "$script_dir/test_realtime_support.swift")
            ;;
        backend_push)
            flags=(-swift-version 6 -parse-as-library -O)
            sources=("${backend_models[@]}" "${summary_sources[@]}" Models/NotificationProfile.swift Models/MailPushModels.swift Services/BackendHTTPClient.swift Services/BackendEvents.swift
                     Services/BackendKeychain.swift Services/BackendSession.swift Services/MailPushService.swift "$script_dir/test_realtime_support.swift")
            ;;
        calendar)
            flags=(-swift-version 5 -parse-as-library)
            sources=("${theme[@]}" Models/BackendCalendar.swift Support/MailCalendar.swift Support/MailCalendarInvitation.swift
                     Services/MailCalendarService.swift Views/CalendarViews.swift Views/CalendarInvitationView.swift Views/SettingsComponents.swift Support/BrandMark.swift)
            ;;
        notifications)
            flags=(-swift-version 5 "${mac_target[@]}")
            sources=("${mail_models[@]}" Models/NotificationProfile.swift Models/MailPushModels.swift Services/BackendHTTPClient.swift
                     Services/BackendKeychain.swift Support/MailFocusFilter.swift Services/MailNotificationService.swift Support/MailPlatform.swift)
            ;;
        unsubscribe)
            flags=(-swift-version 5 -parse-as-library)
            sources=("${backend_models[@]}" Services/MailUnsubscribeService.swift)
            ;;
        attachment_types)
            flags=(-swift-version 5 -parse-as-library)
            sources=(Support/AttachmentFileType.swift)
            ;;
        composer|templates|signatures)
            flags=(-swift-version 5 -parse-as-library "${mac_target[@]}")
            sources=("${editor_sources[@]}")
            case "$suite" in
                composer) sources+=("${attachment_views[@]}" Views/SnippetPickerView.swift) ;;
                templates) sources+=(Models/InboxSplit.swift Stores/MailSyncIdentity.swift Stores/MailSyncRepair.swift
                                     Stores/MailPersistence.swift Support/ComposeAttachments.swift
                                     "${attachment_views[@]}" Views/SnippetPickerView.swift) ;;
                signatures) sources+=(Support/MailSignature.swift Views/SignatureEditorView.swift) ;;
            esac
            # These fixtures exercise file-private editor behavior in the same source file.
            unique_sources
            cat "${sources[@]}" "$fixture" > "$test_dir/$suite.swift"
            fixture="$test_dir/$suite.swift"
            sources=()
            ;;
        *)
            printf 'Unknown suite: %s\n' "$suite" >&2
            usage >&2
            return 2
            ;;
    esac

    sources+=("$fixture")
    unique_sources
    printf '\nRunning %s\n' "$suite"
    xcrun swiftc -default-isolation MainActor -module-cache-path "$test_dir/module-cache" \
        "${flags[@]}" "${sources[@]}" -o "$binary"
    if [[ $suite == composer ]]; then
        "$binary" "$project_root"
    else
        "$binary"
    fi
}

for suite in "$@"; do
    run_suite "$suite"
done
printf '\nAll requested suites passed.\n'
