import SwiftUI

struct OnboardingDefaultMailStep: View {
    let defaultMail: DefaultMailAppService
    let onFinish: () -> Void
    @Environment(\.postmereAccent) private var palette
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            if defaultMail.isRequesting {
                ProgressView("Waiting for macOS…").controlSize(.small)
            } else {
                switch defaultMail.status {
                case nil:
                    ProgressView("Checking your default mail app…").controlSize(.small)
                    skipButton
                case .postmere:
                    Label("Postmere is your default mail app", systemImage: "checkmark.circle.fill")
                        .font(.callout.weight(.medium)).foregroundStyle(palette.accentInk)
                    Button("Open Postmere", action: onFinish)
                        .buttonStyle(OnboardingActionStyle())
                        .keyboardShortcut(.defaultAction)
                case let .other(name):
                    if let name {
                        HStack(spacing: 14) {
                            Text("Current default").foregroundStyle(.secondary)
                            Spacer(minLength: 0)
                            Text(name).fontWeight(.medium)
                        }
                        .font(.callout)
                        .padding(.vertical, 10)
                        .overlay(alignment: .bottom) { Divider() }
                        .accessibilityElement(children: .combine)
                    }
                    if let error = defaultMail.errorMessage {
                        Text(error).font(.callout).foregroundStyle(.red)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    HStack(spacing: 18) {
                        Button("Make Postmere default") { Task { await defaultMail.makeDefault() } }
                            .buttonStyle(OnboardingActionStyle())
                            .keyboardShortcut(.defaultAction)
                        skipButton
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .task(id: scenePhase) {
            if scenePhase == .active || defaultMail.status == nil { await defaultMail.refresh() }
        }
    }

    private var skipButton: some View {
        Button("Not now", action: onFinish)
            .buttonStyle(.link).foregroundStyle(palette.accentInk)
    }
}
