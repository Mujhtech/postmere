import SwiftUI

/// A short decision in the style of a macOS alert, drawn by Postmere so its main
/// button follows the accent chosen in Settings. A system alert always uses the
/// accent the app was built with.
struct PostmereDecisionSheet: View {
    struct Choice {
        let title: String
        var role: ButtonRole?
        let action: () -> Void
    }

    let title: String
    let message: String
    let primary: Choice
    var destructive: Choice?
    let cancel: Choice
    @Environment(\.postmereAccent) private var palette
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 8) {
                Text(title).font(.system(size: 14, weight: .bold))
                Text(message).font(.system(size: 13)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, 4)
            VStack(spacing: 8) {
                button(primary, prominent: true)
                    .keyboardShortcut(.defaultAction)
                if let destructive { button(destructive, prominent: false).foregroundStyle(.red).tint(.red) }
                button(cancel, prominent: false)
                    .keyboardShortcut(.cancelAction)
            }
        }
        .padding(18)
        .frame(width: 300)
    }

    @ViewBuilder private func button(_ choice: Choice, prominent: Bool) -> some View {
        let label = Text(choice.title).frame(maxWidth: .infinity)
        if prominent {
            Button(role: choice.role) { dismiss(); choice.action() } label: { label }
                .buttonStyle(.borderedProminent)
                .buttonBorderShape(.capsule)
                .controlSize(.large)
                .tint(palette.accent)
        } else {
            Button(role: choice.role) { dismiss(); choice.action() } label: { label }
                .buttonStyle(.bordered)
                .buttonBorderShape(.capsule)
                .controlSize(.large)
        }
    }
}
