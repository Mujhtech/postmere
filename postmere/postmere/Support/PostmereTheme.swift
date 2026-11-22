import SwiftUI
import AppKit
import Combine

enum PostmereTheme {
    static let paper = adaptive(light: 0xFDFCF8, dark: 0x1E211F)
    static let ink = Color.primary
    static let secondary = Color.secondary
    static let icon = Color.secondary
    static let destructiveInk = adaptive(light: 0x98332F, dark: 0xFFAAA1)
    static let subtleFill = adaptive(light: 0xF1F0EB, dark: 0x282C29)
    // Native selection can brighten label text. Keep each monogram on its own
    // opaque surface so it stays readable in a selected row and the reader.
    static let avatarFill = adaptive(light: 0x53605A, dark: 0x47574F)
    static let avatarInk = adaptive(light: 0xFFFFFF, dark: 0xF3F6F4)
    static let rule = adaptive(light: 0xDEDFD8, dark: 0x3B403C)
    static let sheetTitle = Font.system(size: 17, weight: .semibold)
    static let utilitySymbol = Font.system(size: 13, weight: .regular)
    static let cardRadius: CGFloat = 8

    private static func adaptive(light: UInt32, dark: UInt32) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let hex = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
            return NSColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
                           green: CGFloat((hex >> 8) & 0xFF) / 255,
                           blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
        })
    }
}

extension View {
    func postmereStyle() -> some View {
        modifier(PostmereStyle())
    }

    func mailboxWindowSurface() -> some View {
        modifier(MailboxWindowSurface())
    }
}

private struct MailboxWindowSurface: ViewModifier {
    @Environment(\.mailboxTheme) private var theme
    @Environment(\.mailboxColors) private var colors

    func body(content: Content) -> some View {
        content
            .background {
                if theme != .native {
                    Color.clear.containerBackground(colors.canvas, for: .window)
                }
            }
            .toolbarBackgroundVisibility(theme == .native ? .automatic : .hidden, for: .windowToolbar)
    }
}

private struct PostmereStyle: ViewModifier {
    @Environment(\.colorScheme) private var scheme
    @AppStorage(MailboxTheme.lightPreference) private var light: MailboxTheme = .native
    @AppStorage(MailboxTheme.darkPreference) private var dark: MailboxTheme = .native
    @AppStorage(PostmereAccent.preferenceKey) private var rgb = PostmereAccent.defaultRGB
    @AppStorage(MailboxTheme.customLightPreference) private var customLight = MailboxTheme.defaultCustomLight
    @AppStorage(MailboxTheme.customDarkPreference) private var customDark = MailboxTheme.defaultCustomDark

    func body(content: Content) -> some View {
        let palette = PostmereAccent(rgb: rgb)
        let theme = scheme == .dark ? dark : light
        let colors = theme.colors(for: scheme, customTint: scheme == .dark ? customDark : customLight)
        content.environment(\.mailboxTheme, theme)
            .environment(\.mailboxColors, colors)
            .environment(\.mailboxInset, theme == .native ? PostmereTheme.subtleFill : colors.inset)
            .environment(\.postmereAccent, palette)
            .tint(palette.accent)
            // Every native button is a capsule, whatever its size or style.
            .buttonBorderShape(.capsule)
            .symbolRenderingMode(.monochrome)
    }
}

struct PostmereSheetHeader<Accessory: View>: View {
    @Environment(\.dismiss) private var dismiss
    let title: String
    let subtitle: String?
    let accessory: Accessory

    init(_ title: String, subtitle: String? = nil, @ViewBuilder accessory: () -> Accessory = { EmptyView() }) {
        self.title = title
        self.subtitle = subtitle
        self.accessory = accessory()
    }

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(PostmereTheme.sheetTitle)
                    .lineLimit(2)
                    .accessibilityAddTraits(.isHeader)
                if let subtitle, !subtitle.isEmpty {
                    Text(subtitle)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .textSelection(.enabled)
                }
            }
            Spacer(minLength: 8)
            accessory
            Button("Done") { dismiss() }
                .keyboardShortcut(.cancelAction)
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 16)
    }
}

enum MailAppearance: String, CaseIterable {
    case system, light, dark

    static let preferenceKey = "appearance"

    // AppKit owns the override so every window, native toolbar, and presented
    // panel inherits it. Clearing the override resumes live system changes.
    @MainActor
    static func observe(in defaults: UserDefaults, application: NSApplication) -> AnyCancellable {
        func applyPreference() {
            let mode = defaults.string(forKey: preferenceKey).flatMap(Self.init(rawValue:)) ?? .system
            let name: NSAppearance.Name? = switch mode {
            case .system: nil
            case .light: .aqua
            case .dark: .darkAqua
            }
            guard application.appearance?.name != name else { return }
            application.appearance = name.flatMap(NSAppearance.init(named:))
        }
        applyPreference()
        return NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification, object: defaults)
            .receive(on: DispatchQueue.main)
            .sink { _ in applyPreference() }
    }

    var title: String {
        switch self {
        case .system: "Match Mac"
        case .light: "Light"
        case .dark: "Dark"
        }
    }

    var colorScheme: ColorScheme? {
        switch self {
        case .system: nil
        case .light: .light
        case .dark: .dark
        }
    }
}
