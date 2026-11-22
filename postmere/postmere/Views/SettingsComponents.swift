import SwiftUI

/// Shared building blocks for the Settings window, so every tab reads the
/// same way: a tinted icon tile, a short title, at most one line of detail,
/// and the control on the trailing edge.
enum SettingsTint {
    static let blue = Color(red: 0.20, green: 0.48, blue: 0.96)
    static let indigo = Color(red: 0.36, green: 0.35, blue: 0.86)
    static let purple = Color(red: 0.62, green: 0.35, blue: 0.86)
    static let pink = Color(red: 0.93, green: 0.30, blue: 0.47)
    static let red = Color(red: 0.94, green: 0.29, blue: 0.27)
    static let orange = Color(red: 0.97, green: 0.56, blue: 0.16)
    static let yellow = Color(red: 0.95, green: 0.72, blue: 0.10)
    static let green = Color(red: 0.20, green: 0.70, blue: 0.40)
    static let teal = Color(red: 0.12, green: 0.66, blue: 0.72)
    static let gray = Color(red: 0.55, green: 0.57, blue: 0.62)
}

struct SettingsIcon: View {
    let symbol: String
    let tint: Color

    init(_ symbol: String, tint: Color) {
        self.symbol = symbol
        self.tint = tint
    }

    var body: some View {
        PostmereIcon(symbol, size: 13)
            .foregroundStyle(.white)
            .frame(width: 24, height: 24)
            .background {
                RoundedRectangle(cornerRadius: 6.5, style: .continuous)
                    .fill(LinearGradient(colors: [tint.opacity(0.88), tint], startPoint: .top, endPoint: .bottom))
                    .overlay(RoundedRectangle(cornerRadius: 6.5, style: .continuous)
                        .strokeBorder(.white.opacity(0.18), lineWidth: 0.5))
            }
            .accessibilityHidden(true)
    }
}

struct SettingsRow<Accessory: View>: View {
    let symbol: String
    let tint: Color
    let title: String
    var subtitle: String?
    /// Third-party marks shown instead of the icon tile, for a connected service.
    var brands: [Brand] = []
    @ViewBuilder var accessory: () -> Accessory

    init(_ title: String, symbol: String, tint: Color, subtitle: String? = nil, brands: [Brand] = [],
         @ViewBuilder accessory: @escaping () -> Accessory) {
        self.brands = brands
        self.title = title
        self.symbol = symbol
        self.tint = tint
        self.subtitle = subtitle
        self.accessory = accessory
    }

    var body: some View {
        HStack(spacing: 11) {
            if brands.count >= 2 {
                BrandPair(first: brands[0], second: brands[1])
            } else if let brand = brands.first {
                BrandTile(brand: brand)
            } else {
                SettingsIcon(symbol, tint: tint)
            }
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.system(size: 13))
                if let subtitle {
                    Text(subtitle)
                        .font(.system(size: 11.5))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 12)
            accessory()
        }
        .padding(.vertical, 1)
        .accessibilityElement(children: .combine)
    }
}

/// A row whose control is a switch.
struct SettingsToggle: View {
    let title: String
    let symbol: String
    let tint: Color
    var subtitle: String?
    @Binding var isOn: Bool

    init(_ title: String, symbol: String, tint: Color, subtitle: String? = nil, isOn: Binding<Bool>) {
        self.title = title
        self.symbol = symbol
        self.tint = tint
        self.subtitle = subtitle
        _isOn = isOn
    }

    var body: some View {
        SettingsRow(title, symbol: symbol, tint: tint, subtitle: subtitle) {
            Toggle(title, isOn: $isOn).toggleStyle(.switch).labelsHidden().controlSize(.small)
        }
    }
}

/// A compact state badge, such as "Allowed" or "Default".
struct SettingsPill: View {
    let title: String
    var tint: Color = SettingsTint.green
    var symbol: String? = "checkmark"

    var body: some View {
        HStack(spacing: 4) {
            if let symbol { PostmereIcon(symbol, size: 10) }
            Text(title).font(.system(size: 11.5, weight: .medium))
        }
        .foregroundStyle(tint)
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(tint.opacity(0.13), in: Capsule())
    }
}

/// One key of a shortcut, drawn like a physical key cap.
struct SettingsKeyCap: View {
    let key: String
    init(_ key: String) { self.key = key }

    var body: some View {
        Text(key)
            .font(.system(size: 11.5, weight: .medium, design: .rounded))
            .foregroundStyle(.primary.opacity(0.8))
            .padding(.horizontal, 6)
            .frame(minWidth: 22, minHeight: 21)
            .background {
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill(Color(nsColor: .controlBackgroundColor))
                    .shadow(color: .black.opacity(0.18), radius: 0, y: 1)
                    .overlay(RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .strokeBorder(Color.primary.opacity(0.12), lineWidth: 0.5))
            }
    }
}

/// An info button that keeps long explanations out of the layout.
struct SettingsInfoButton: View {
    let text: String
    @State private var shows = false

    var body: some View {
        Button { shows.toggle() } label: {
            PostmereIcon("info.circle", size: 13).foregroundStyle(.secondary)
        }
        .buttonStyle(.plain)
        .popover(isPresented: $shows, arrowEdge: .bottom) {
            Text(text)
                .font(.system(size: 12))
                .fixedSize(horizontal: false, vertical: true)
                .frame(width: 280, alignment: .leading)
                .padding(14)
        }
        .help("More about this")
        .accessibilityLabel("More information")
    }
}
