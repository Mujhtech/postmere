#if os(macOS)
import AppKit
#else
import UIKit
#endif
import SwiftUI

/// Third-party marks for services Postmere connects to, used only to say
/// "this is GitHub" or "this is Claude". Single-colour marks come from Simple
/// Icons (CC0) in each brand's own colour; VS Code uses the logo from
/// code.visualstudio.com/brand, which Simple Icons may not carry.
/// Postmere's own interface keeps using `PostmereIcon`.
enum Brand: String, CaseIterable, Sendable {
    case github, linear, jira, sentry, vercel, netlify, pagerduty, opsgenie
    case claude, openai, cursor, vscode
    case ups, usps, fedex, dhl
    case gmail, outlook

    /// Official brand colour.
    var color: Color {
        switch self {
        case .github: Color(hex: 0x181717)
        case .linear: Color(hex: 0x5E6AD2)
        case .jira: Color(hex: 0x0052CC)
        case .sentry: Color(hex: 0x362D59)
        case .vercel, .cursor: Color(hex: 0x000000)
        case .netlify: Color(hex: 0x00C7B7)
        case .pagerduty: Color(hex: 0x06AC38)
        case .opsgenie: Color(hex: 0x172B4D)
        case .claude: Color(hex: 0xD97757)
        case .openai: Color(hex: 0x412991)
        case .vscode: Color(hex: 0x007ACC)
        case .ups: Color(hex: 0x351C15)
        case .usps: Color(hex: 0x333366)
        case .fedex: Color(hex: 0x4D148C)
        case .dhl: Color(hex: 0xFFCC00)
        case .gmail: Color(hex: 0xEA4335)
        case .outlook: Color(hex: 0x0F6CBD)
        }
    }

    /// Near-black brands draw in the primary colour on their own, so they stay
    /// visible in dark mode.
    var isDark: Bool { [.github, .vercel, .cursor, .sentry, .opsgenie, .ups, .usps].contains(self) }

    /// DHL's yellow is too light for a mark, so it draws in DHL red, and in
    /// red on yellow inside a tile, the way DHL prints it.
    var markColor: Color? { self == .dhl ? Color(hex: 0xD40511) : nil }

    /// These marks are full-colour icons rather than templates.
    var isFullColor: Bool { [.vscode, .gmail, .outlook].contains(self) }

    /// The mailbox provider behind a connected account.
    init?(mailProvider: String) {
        switch mailProvider {
        case "gmail": self = .gmail
        case "microsoft": self = .outlook
        default: return nil
        }
    }

    var image: Image { Image("Brands/\(rawValue)") }

    /// Recognises an assistant from the name it registered with.
    init?(clientName: String) {
        let name = clientName.lowercased()
        if name.contains("claude") { self = .claude }
        else if name.contains("codex") || name.contains("chatgpt") || name.contains("openai") { self = .openai }
        else if name.contains("cursor") { self = .cursor }
        else if name.contains("vs code") || name.contains("vscode") || name.contains("visual studio code") { self = .vscode }
        else { return nil }
    }
}

extension Color {
    init(hex: UInt32) {
        self.init(red: Double((hex >> 16) & 0xFF) / 255, green: Double((hex >> 8) & 0xFF) / 255, blue: Double(hex & 0xFF) / 255)
    }
}

/// The bare mark, in its brand colour unless a colour is set by the caller.
struct BrandMark: View {
    let brand: Brand
    var size: CGFloat = 16
    var tint: Color?

    var body: some View {
        Group {
            if brand.isFullColor {
                brand.image.resizable().interpolation(.high).scaledToFit()
            } else {
                brand.image.resizable().renderingMode(.template).scaledToFit()
                    .foregroundStyle(tint ?? brand.markColor ?? (brand.isDark ? Color.primary : brand.color))
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

/// A rounded tile like `SettingsIcon`: the mark in white on the brand colour,
/// or VS Code's own icon on a light tile.
struct BrandTile: View {
    let brand: Brand
    var size: CGFloat = 24

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: size * 0.27, style: .continuous)
        Group {
            if brand.isFullColor {
                BrandMark(brand: brand, size: size * 0.74)
                    .frame(width: size, height: size)
                    .background(Color.white, in: shape)
            } else {
                BrandMark(brand: brand, size: size * 0.56, tint: brand.markColor ?? .white)
                    .frame(width: size, height: size)
                    .background(LinearGradient(colors: [brand.color.opacity(0.88), brand.color], startPoint: .top, endPoint: .bottom), in: shape)
            }
        }
        .overlay(shape.strokeBorder(Color.primary.opacity(brand.isFullColor ? 0.12 : 0), lineWidth: 0.5))
        .overlay(shape.strokeBorder(.white.opacity(brand.isFullColor ? 0 : 0.18), lineWidth: 0.5))
        .accessibilityHidden(true)
    }
}

/// Two services covered by one plugin, such as Linear and Jira: tiles
/// overlapping on the diagonal inside one tile's footprint.
struct BrandPair: View {
    let first: Brand
    let second: Brand
    var size: CGFloat = 24

    var body: some View {
        ZStack(alignment: .topLeading) {
            BrandTile(brand: first, size: size * 0.72)
            BrandTile(brand: second, size: size * 0.72)
                .padding(1.5)
                .background(Self.backdrop, in: RoundedRectangle(cornerRadius: size * 0.24, style: .continuous))
                .offset(x: size * 0.28 - 1.5, y: size * 0.28 - 1.5)
        }
        .frame(width: size, height: size, alignment: .topLeading)
        .accessibilityHidden(true)
    }

    #if os(macOS)
    private static let backdrop = Color(nsColor: .windowBackgroundColor)
    #else
    private static let backdrop = Color(uiColor: .secondarySystemGroupedBackground)
    #endif
}

#if os(macOS)
extension Brand {
    /// The mark scaled to fit `side` points, for menus and pickers, which
    /// draw images at their file's own size and ignore SwiftUI frames.
    @MainActor func menuImage(side: CGFloat = 16) -> Image {
        guard let source = NSImage(named: "Brands/\(rawValue)") else { return image }
        let size = source.size
        let scale = min(side / max(size.width, 1), side / max(size.height, 1))
        let fitted = NSSize(width: (size.width * scale).rounded(), height: (size.height * scale).rounded())
        let result = NSImage(size: fitted, flipped: false) { rect in
            source.draw(in: rect)
            return true
        }
        result.isTemplate = !isFullColor
        return Image(nsImage: result)
    }
}
#endif
