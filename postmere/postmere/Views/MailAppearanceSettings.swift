import SwiftUI

struct MailAppearanceSettings: View {
    @Environment(\.colorScheme) private var scheme
    @Environment(\.postmereAccent) private var accent
    @AppStorage(MailAppearance.preferenceKey) private var appearance: MailAppearance = .system
    @AppStorage(MailboxTheme.lightPreference) private var lightTheme: MailboxTheme = .native
    @AppStorage(MailboxTheme.darkPreference) private var darkTheme: MailboxTheme = .native
    @AppStorage(PostmereAccent.preferenceKey) private var primary = PostmereAccent.defaultRGB
    @AppStorage(MailboxTheme.customLightPreference) private var customLight = MailboxTheme.defaultCustomLight
    @AppStorage(MailboxTheme.customDarkPreference) private var customDark = MailboxTheme.defaultCustomDark
    @State private var editingScheme: ColorScheme?

    private static let swatches = [
        ("Postmere green", PostmereAccent.defaultRGB), ("Ocean", 0x367FA8), ("Indigo", 0x6257B4),
        ("Violet", 0x9A62AF), ("Rose", 0xBC5971), ("Copper", 0xBC7542), ("Slate", 0x697882)
    ]
    private var previewScheme: ColorScheme { appearance.colorScheme ?? editingScheme ?? scheme }
    private var selection: Binding<MailboxTheme> { previewScheme == .dark ? $darkTheme : $lightTheme }
    private var customTint: Binding<Int> { previewScheme == .dark ? $customDark : $customLight }
    private var isCustomAccent: Bool { !Self.swatches.contains { $0.1 == primary } }

    var body: some View {
        Form {
            Section {
                SettingsRow("Appearance", symbol: "paintpalette", tint: SettingsTint.indigo) {
                    GlassSegmentedControl(title: "Appearance", selection: $appearance, options: [
                        .init(value: .system, title: MailAppearance.system.title, symbol: "circle.lefthalf.filled"),
                        .init(value: .light, title: MailAppearance.light.title, symbol: "sun.max"),
                        .init(value: .dark, title: MailAppearance.dark.title, symbol: "moon"),
                    ])
                }
            }
            Section {
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: 4), spacing: 10) {
                    ForEach(MailboxTheme.allCases) { option in
                        ThemeCard(theme: option, scheme: previewScheme, accent: accent, customTint: customTint.wrappedValue,
                                  selected: selection.wrappedValue == option) {
                            withAnimation(.snappy(duration: 0.2)) { selection.wrappedValue = option }
                            // Choosing Custom goes straight to picking its colour.
                            if option == .custom {
                                let binding = customTint
                                ColorPanelBridge.shared.present(rgb: binding.wrappedValue) { binding.wrappedValue = $0 }
                            }
                        }
                    }
                }
                .padding(.vertical, 4)
                if selection.wrappedValue == .custom {
                    HStack(spacing: 10) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Custom \(previewScheme == .dark ? "dark" : "light") theme").font(.system(size: 12.5))
                            Text("Sidebar, list and reader are shaded from one colour.")
                                .font(.system(size: 11.5)).foregroundStyle(.secondary)
                        }
                        Spacer()
                        ColorWheelButton(title: "Choose the \(previewScheme == .dark ? "dark" : "light") theme colour",
                                         rgb: customTint, isCustom: true)
                    }
                    .transition(.opacity)
                }
                if appearance == .system, previewScheme != scheme {
                    Text("Applies when your Mac is in \(previewScheme == .dark ? "dark" : "light") mode.")
                        .font(.system(size: 11.5))
                        .foregroundStyle(.secondary)
                }
            } header: {
                HStack {
                    Text("Theme")
                    Spacer()
                    if appearance == .system {
                        GlassSegmentedControl(title: "Edit theme for", selection: Binding(
                            get: { previewScheme },
                            set: { editingScheme = $0 == scheme ? nil : $0 }
                        ), options: [
                            .init(value: ColorScheme.light, title: "Light", symbol: "sun.max"),
                            .init(value: ColorScheme.dark, title: "Dark", symbol: "moon"),
                        ], compact: true)
                    }
                }
            }
            Section("Accent") {
                HStack(spacing: 12) {
                    ForEach(Self.swatches, id: \.1) { name, rgb in
                        let swatch = PostmereAccent(rgb: rgb)
                        let selected = primary == rgb
                        Button { withAnimation(.snappy(duration: 0.2)) { primary = rgb } } label: {
                            Circle().fill(swatch.swatch.gradient)
                                .frame(width: 22, height: 22)
                                .padding(3)
                                .overlay(Circle().strokeBorder(selected ? swatch.swatch : .clear, lineWidth: 2))
                                .overlay {
                                    if selected { PostmereIcon("checkmark", size: 10).foregroundStyle(.white) }
                                }
                                .contentShape(Circle())
                        }
                        .buttonStyle(.plain)
                        .help(name)
                        .accessibilityLabel(name)
                        .accessibilityAddTraits(selected ? .isSelected : [])
                    }
                    Spacer()
                    ColorWheelButton(title: "Choose any colour", rgb: $primary, isCustom: isCustomAccent)
                }
                .padding(.vertical, 2)
            }
        }
        .formStyle(.grouped)
        .onChange(of: appearance) { editingScheme = nil }
        .onChange(of: scheme) { if editingScheme == scheme { editingScheme = nil } }
    }
}

/// A theme choice: a miniature of the mail window with its name.
private struct ThemeCard: View {
    let theme: MailboxTheme
    let scheme: ColorScheme
    let accent: PostmereAccent
    var customTint: Int? = nil
    let selected: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 5) {
                MailboxThemePreview(theme: theme, scheme: scheme, accent: accent, customTint: customTint)
                    .aspectRatio(1.9, contentMode: .fit)
                    .clipShape(.rect(cornerRadius: 7, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .strokeBorder(Color.primary.opacity(0.12), lineWidth: 0.5))
                    .padding(2.5)
                    .overlay(RoundedRectangle(cornerRadius: 9.5, style: .continuous)
                        .strokeBorder(selected ? accent.accent : .clear, lineWidth: 2))
                    .overlay(alignment: .topTrailing) {
                        if selected {
                            PostmereIcon("checkmark", size: 9)
                                .foregroundStyle(.white)
                                .frame(width: 18, height: 18)
                                .background(accent.accent, in: Circle())
                                .offset(x: 4, y: -4)
                                .transition(.scale.combined(with: .opacity))
                        }
                    }
                    .overlay(alignment: .bottomTrailing) {
                        if theme == .custom {
                            // Marks the card you colour yourself.
                            Circle()
                                .fill(AngularGradient(colors: [.red, .yellow, .green, .cyan, .blue, .purple, .red], center: .center))
                                .frame(width: 14, height: 14)
                                .overlay(Circle().strokeBorder(.white, lineWidth: 1.5))
                                .shadow(color: .black.opacity(0.2), radius: 1.5, y: 0.5)
                                .padding(8)
                        }
                    }
                    .shadow(color: .black.opacity(hovering ? 0.12 : 0.05), radius: hovering ? 8 : 3, y: hovering ? 4 : 1)
                    .offset(y: hovering ? -1.5 : 0)
                Text(theme.title)
                    .font(.system(size: 11.5, weight: selected ? .semibold : .regular))
                    .lineLimit(1)
                    .foregroundStyle(selected ? .primary : .secondary)
                    .padding(.leading, 3)
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.15), value: hovering)
        .accessibilityLabel("\(theme.title), \(scheme == .dark ? "dark" : "light") theme")
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

private struct MailboxThemePreview: View {
    let theme: MailboxTheme
    let scheme: ColorScheme
    let accent: PostmereAccent
    var customTint: Int?

    var body: some View {
        Canvas { context, size in
            let colors = theme.colors(for: scheme, customTint: customTint)
            let ink: Color = scheme == .dark ? .white : .black
            let width = size.width
            let height = size.height
            let sidebar = width * 0.19
            let list = width * 0.37
            let reader = sidebar + list
            func box(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat, _ fill: Color, radius: CGFloat = 0) {
                context.fill(Path(roundedRect: CGRect(x: x, y: y, width: w, height: h), cornerRadius: radius), with: .color(fill))
            }
            box(0, 0, width, height, colors.canvas)
            box(0, 0, sidebar, height, colors.sidebar)
            box(sidebar, 0, 0.8, height, ink.opacity(0.15))
            box(reader, 0, 0.8, height, ink.opacity(0.15))
            for dot in 0..<3 { box(5 + CGFloat(dot) * 4, 5, 2.5, 2.5, ink.opacity(0.35), radius: 1.25) }
            box(3, height * 0.22, sidebar - 6, height * 0.13, accent.selectionFill, radius: 2)
            for row in 0..<4 { box(7, height * (0.27 + Double(row) * 0.17), sidebar * 0.49, 2, ink.opacity(0.5), radius: 1) }
            for row in 0..<4 {
                let y = height * (0.07 + Double(row) * 0.24)
                if row == 1 { box(sidebar + 2, y - 1, list - 3.5, height * 0.22, accent.selectionFill, radius: 2) }
                box(sidebar + 5, y + 2, 5, 5, row == 1 ? accent.accentInk : ink.opacity(0.24), radius: 2.5)
                box(sidebar + 13, y + 2, list * (row.isMultiple(of: 2) ? 0.46 : 0.53), 2.5, ink.opacity(0.72), radius: 1)
                box(sidebar + 13, y + 7, list * 0.51, 1.8, ink.opacity(0.3), radius: 1)
            }
            let x = reader + 7
            let body = width - x - 7
            box(x, height * 0.13, body * 0.87, 3.2, ink.opacity(0.82), radius: 1)
            box(x, height * 0.27, 5, 5, accent.accentInk, radius: 2.5)
            box(x + 8, height * 0.29, body * 0.39, 2, ink.opacity(0.55), radius: 1)
            for (line, fraction) in [0.94, 0.80, 0.91, 0.63].enumerated() {
                box(x, height * (0.48 + Double(line) * 0.09), body * fraction, 1.8, ink.opacity(0.4), radius: 1)
            }
        }
        .environment(\.colorScheme, scheme)
        .accessibilityHidden(true)
    }
}
