import SwiftUI
import AppKit

enum PostmereTheme {
    static let paper = adaptive(light: 0xFDFCF8, dark: 0x1E211F)
    static let ink = Color.primary
    static let secondary = Color.secondary
    static let icon = Color.secondary
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
}

private struct PostmereStyle: ViewModifier {
    @AppStorage(PostmereAccent.preferenceKey) private var rgb = PostmereAccent.defaultRGB

    func body(content: Content) -> some View {
        let palette = PostmereAccent(rgb: rgb)
        content.environment(\.postmereAccent, palette)
            .tint(palette.accent)
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

    var title: String {
        switch self {
        case .system: "System"
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
