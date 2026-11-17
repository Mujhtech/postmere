import SwiftUI
import AppKit

enum PostmereTheme {
    // The app icon's forest green anchors every window. Control fills and
    // foreground accents share a hue but keep their own contrast in Dark Mode.
    static let accent = Color("AccentColor")
    static let accentInk = adaptive(light: 0x123F36, dark: 0x94C9BE)
    static let paper = adaptive(light: 0xFDFCF8, dark: 0x1E211F)
    static let ink = Color.primary
    static let secondary = Color.secondary
    static let icon = Color.secondary
    static let subtleFill = adaptive(light: 0xF1F0EB, dark: 0x282C29)
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
        self.tint(PostmereTheme.accent)
            .symbolRenderingMode(.monochrome)
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
