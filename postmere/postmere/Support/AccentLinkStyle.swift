import SwiftUI

/// A text link in the primary color. AppKit's link style draws with the fixed
/// asset-catalog accent, so it ignores the color chosen in Settings.
struct AccentLinkStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        Link(configuration: configuration)
    }

    private struct Link: View {
        let configuration: ButtonStyleConfiguration
        @Environment(\.postmereAccent) private var palette
        @Environment(\.isEnabled) private var isEnabled
        @State private var hovering = false

        var body: some View {
            configuration.label
                .foregroundStyle(palette.accentInk)
                .underline(hovering && isEnabled, color: palette.accentInk.opacity(0.5))
                .opacity(isEnabled ? (configuration.isPressed ? 0.6 : 1) : 0.4)
                .contentShape(Rectangle())
                .onHover { hovering = $0 }
                .pointerStyle(.link)
        }
    }
}

extension ButtonStyle where Self == AccentLinkStyle {
    static var accentLink: AccentLinkStyle { AccentLinkStyle() }
}
