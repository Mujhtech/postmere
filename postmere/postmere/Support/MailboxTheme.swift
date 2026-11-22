import SwiftUI

/// Mailbox surfaces are separate from the user's primary color and from received HTML.
nonisolated enum MailboxTheme: String, CaseIterable, Identifiable {
    case native, cappuccino, velvet, lavender, glacier, neonCoast, custom

    static let lightPreference = "mailboxThemeLight"
    static let darkPreference = "mailboxThemeDark"
    /// The tint a custom theme is built from, one for each appearance.
    static let customLightPreference = "mailboxThemeCustomLightRGB"
    static let customDarkPreference = "mailboxThemeCustomDarkRGB"
    static let defaultCustomLight = 0xC9A27E
    static let defaultCustomDark = 0x4F7F8A
    var id: Self { self }

    var title: String {
        switch self {
        case .native: "Mac Default"
        case .cappuccino: "Cappuccino"
        case .velvet: "Velvet"
        case .lavender: "Lavender"
        case .glacier: "Glacier"
        case .neonCoast: "Neon Coast"
        case .custom: "Custom"
        }
    }

    struct Colors: Equatable {
        let sidebar: Color
        let canvas: Color
        let inset: Color

        init(_ sidebar: Int, _ canvas: Int, _ inset: Int) {
            self.sidebar = Self.color(sidebar)
            self.canvas = Self.color(canvas)
            self.inset = Self.color(inset)
        }

        /// Surfaces from one tint, mixed into the same near-white or near-black
        /// bases the built-in themes use, so text keeps its contrast whatever
        /// colour is chosen.
        init(tint: Int, dark: Bool) {
            func mix(_ base: Int, _ amount: Double) -> Int {
                func channel(_ shift: Int) -> Int {
                    let a = Double((base >> shift) & 255), b = Double((tint >> shift) & 255)
                    return Int((a + (b - a) * amount).rounded())
                }
                return channel(16) << 16 | channel(8) << 8 | channel(0)
            }
            if dark {
                self.init(mix(0x1F1F20, 0.20), mix(0x171718, 0.13), mix(0x2C2C2E, 0.26))
            } else {
                self.init(mix(0xFFFFFF, 0.26), mix(0xFFFFFF, 0.07), mix(0xFFFFFF, 0.17))
            }
        }

        private static func color(_ rgb: Int) -> Color {
            Color(.sRGB, red: Double((rgb >> 16) & 255) / 255,
                  green: Double((rgb >> 8) & 255) / 255, blue: Double(rgb & 255) / 255)
        }
    }

    /// `customTint` is the chosen tint for this scheme; only `.custom` uses it.
    func colors(for scheme: ColorScheme, customTint: Int? = nil) -> Colors {
        let dark = scheme == .dark
        switch self {
        case .custom:
            return Colors(tint: customTint ?? (dark ? Self.defaultCustomDark : Self.defaultCustomLight), dark: dark)
        case .native: return dark ? Colors(0x262626, 0x1D1D1E, 0x353537) : Colors(0xEEEFF0, 0xFFFFFF, 0xECEDEF)
        case .cappuccino: return dark ? Colors(0x292220, 0x211C1B, 0x3B302C) : Colors(0xEBDFCF, 0xFCF7ED, 0xF1E7D9)
        case .velvet: return dark ? Colors(0x302332, 0x251D27, 0x413044) : Colors(0xE8D7DD, 0xFBF4F6, 0xF0E3E9)
        case .lavender: return dark ? Colors(0x2C283B, 0x23202F, 0x3C364F) : Colors(0xE3DCF0, 0xF8F5FD, 0xEBE5F5)
        case .glacier: return dark ? Colors(0x20313B, 0x19262F, 0x2E424F) : Colors(0xD7E7ED, 0xF3F9FB, 0xE4EFF3)
        // Sunset pink by day, violet neon night after dark.
        case .neonCoast: return dark ? Colors(0x2B1838, 0x1E1229, 0x40214F) : Colors(0xF7D3DC, 0xFFF6F1, 0xFCE2E0)
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
    /// The current theme's surfaces for the current appearance, including a
    /// custom theme's, so views update the moment its tint changes.
    @Entry var mailboxColors: MailboxTheme.Colors = MailboxTheme.native.colors(for: .light)
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
    @Environment(\.mailboxColors) private var colors

    func body(content: Content) -> some View {
        content
            .scrollContentBackground(theme == .native ? .automatic : .hidden)
            .background {
                if isPresented && theme != .native {
                    let canvas = colors.canvas
                    canvas.presentationBackground(canvas)
                }
            }
    }
}
