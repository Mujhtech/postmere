import SwiftUI

/// The preference stores the chosen sRGB color. Controls, labels and selections derive their own contrast from it.
nonisolated struct PostmereAccent: Equatable, Sendable {
    static let preferenceKey = "primaryColorRGB"
    static let defaultRGB = 0x498775

    let rgb: Int
    let swatch: Color
    let accent: Color
    let accentInk: Color
    let accentInkCSS: String
    let selectionFill: Color
    let selectionInk: Color
    let selectionSecondaryInk: Color

    init(rgb: Int) {
        self.rgb = (0...0xFFFFFF).contains(rgb) ? rgb : Self.defaultRGB
        let source = RGB(self.rgb)
        let white = RGB(0xFFFFFF)
        let black = RGB(0x000000)
        let darkSurface = RGB(0x292B2A)
        let lightControl = source.legible(on: white, toward: black)
        let darkControl = lightControl.legible(on: darkSurface, toward: white, ratio: 3)
        let darkInk = source.legible(on: darkSurface, toward: white, ratio: 5)
        let lightSecondary = RGB(0x414743)
        let darkSecondary = RGB(0xDCE4DF)

        swatch = Color(.sRGB, red: source.components.x, green: source.components.y, blue: source.components.z)
        accent = Self.adaptive(lightControl, darkControl.legible(on: white, toward: black))
        let lightInk = source.legible(on: white, toward: black, ratio: 5)
        accentInk = Self.adaptive(lightInk, darkInk)
        accentInkCSS = "light-dark(\(lightInk.css), \(darkInk.css))"
        selectionFill = Self.adaptive(
            lightControl.mixed(with: white, amount: 0.68).legible(on: lightSecondary, toward: white),
            darkInk.mixed(with: darkSurface, amount: 0.52).legible(on: darkSecondary, toward: black)
        )
        selectionInk = Self.adaptive(RGB(0x17221D), RGB(0xF6FAF7))
        selectionSecondaryInk = Self.adaptive(lightSecondary, darkSecondary)
    }

    static func == (lhs: Self, rhs: Self) -> Bool { lhs.rgb == rhs.rgb }

    static func rgbValue(of color: Color) -> Int? {
        guard let srgb = color.resolve(in: EnvironmentValues()).cgColor
                .converted(to: CGColorSpace(name: CGColorSpace.sRGB)!, intent: .defaultIntent, options: nil),
              let c = srgb.components, c.count >= 3 else { return nil }
        func byte(_ component: CGFloat) -> Int { Int((min(1, max(0, component)) * 255).rounded()) }
        return byte(c[0]) << 16 | byte(c[1]) << 8 | byte(c[2])
    }

    private static func adaptive(_ light: RGB, _ dark: RGB) -> Color {
        MailPlatform.adaptiveColor(light: light.components, dark: dark.components)
    }

    private struct RGB {
        let r: Double
        let g: Double
        let b: Double

        init(_ hex: Int) {
            self.init(r: Double((hex >> 16) & 255) / 255,
                      g: Double((hex >> 8) & 255) / 255,
                      b: Double(hex & 255) / 255)
        }

        private init(r: Double, g: Double, b: Double) {
            self.r = r
            self.g = g
            self.b = b
        }

        var components: SIMD3<Double> { SIMD3(r, g, b) }

        var css: String {
            "rgb(\(Int((r * 255).rounded())), \(Int((g * 255).rounded())), \(Int((b * 255).rounded())))"
        }

        func mixed(with other: Self, amount: Double) -> Self {
            Self(r: r + (other.r - r) * amount, g: g + (other.g - g) * amount, b: b + (other.b - b) * amount)
        }

        private var luminance: Double {
            func linear(_ channel: Double) -> Double {
                channel <= 0.04045 ? channel / 12.92 : pow((channel + 0.055) / 1.055, 2.4)
            }
            return 0.2126 * linear(r) + 0.7152 * linear(g) + 0.0722 * linear(b)
        }

        /// Find the smallest adjustment that meets the contrast ratio, including for very pale or dark picks.
        func legible(on background: Self, toward target: Self, ratio: Double = 4.5) -> Self {
            let surface = background.luminance
            func meetsContrast(_ sample: Self) -> Bool {
                let ink = sample.luminance
                return (max(surface, ink) + 0.05) / (min(surface, ink) + 0.05) >= ratio
            }
            if meetsContrast(self) { return self }
            var lower = 0.0
            var upper = 1.0
            for _ in 0..<10 {
                let middle = (lower + upper) / 2
                if meetsContrast(mixed(with: target, amount: middle)) { upper = middle }
                else { lower = middle }
            }
            return mixed(with: target, amount: upper)
        }
    }
}

extension EnvironmentValues {
    @Entry var postmereAccent = PostmereAccent(rgb: PostmereAccent.defaultRGB)
}
