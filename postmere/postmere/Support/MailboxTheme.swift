import SwiftUI

/// Mailbox surfaces are separate from the user's primary color and from received HTML.
nonisolated enum MailboxTheme: String, CaseIterable, Identifiable {
    case native, cappuccino, velvet, lavender, glacier

    static let lightPreference = "mailboxThemeLight"
    static let darkPreference = "mailboxThemeDark"
    var id: Self { self }

    var title: String {
        switch self {
        case .native: "Mac Default"
        case .cappuccino: "Cappuccino"
        case .velvet: "Velvet"
        case .lavender: "Lavender"
        case .glacier: "Glacier"
        }
    }

    struct Colors {
        let sidebar: Color
        let canvas: Color
        let inset: Color

        init(_ sidebar: Int, _ canvas: Int, _ inset: Int) {
            self.sidebar = Self.color(sidebar)
            self.canvas = Self.color(canvas)
            self.inset = Self.color(inset)
        }

        private static func color(_ rgb: Int) -> Color {
            Color(.sRGB, red: Double((rgb >> 16) & 255) / 255,
                  green: Double((rgb >> 8) & 255) / 255, blue: Double(rgb & 255) / 255)
        }
    }

    func colors(for scheme: ColorScheme) -> Colors {
        let dark = scheme == .dark
        switch self {
        case .native: return dark ? Colors(0x262626, 0x1D1D1E, 0x353537) : Colors(0xEEEFF0, 0xFFFFFF, 0xECEDEF)
        case .cappuccino: return dark ? Colors(0x292220, 0x211C1B, 0x3B302C) : Colors(0xEBDFCF, 0xFCF7ED, 0xF1E7D9)
        case .velvet: return dark ? Colors(0x302332, 0x251D27, 0x413044) : Colors(0xE8D7DD, 0xFBF4F6, 0xF0E3E9)
        case .lavender: return dark ? Colors(0x2C283B, 0x23202F, 0x3C364F) : Colors(0xE3DCF0, 0xF8F5FD, 0xEBE5F5)
        case .glacier: return dark ? Colors(0x20313B, 0x19262F, 0x2E424F) : Colors(0xD7E7ED, 0xF3F9FB, 0xE4EFF3)
        }
    }
}

struct ReaderPanelDismissAction: Equatable {
    let requestID: UUID
    let perform: @MainActor @Sendable () -> Void

    @MainActor func callAsFunction() { perform() }
    nonisolated static func == (lhs: Self, rhs: Self) -> Bool { lhs.requestID == rhs.requestID }
}

extension EnvironmentValues {
    @Entry var dismissReaderPanel: ReaderPanelDismissAction? = nil
    @Entry var mailboxTheme: MailboxTheme = .native
    @Entry var mailboxInset: Color = PostmereTheme.subtleFill
}

extension View {
    /// Apply at the root of a Postmere sheet or popover so native lists reveal its canvas.
    func mailPanelSurface(isPresented: Bool = true) -> some View {
        modifier(MailPanelSurface(isPresented: isPresented))
    }
}

private struct MailPanelSurface: ViewModifier {
    let isPresented: Bool
    @Environment(\.mailboxTheme) private var theme
    @Environment(\.colorScheme) private var scheme

    func body(content: Content) -> some View {
        content
            .scrollContentBackground(theme == .native ? .automatic : .hidden)
            .background {
                if isPresented && theme != .native {
                    let canvas = theme.colors(for: scheme).canvas
                    canvas.presentationBackground(canvas)
                }
            }
    }
}
