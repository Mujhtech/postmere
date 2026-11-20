import SwiftUI

struct MailAppearanceSettings: View {
    @Environment(\.colorScheme) private var scheme
    @Environment(\.postmereAccent) private var accent
    @AppStorage(MailAppearance.preferenceKey) private var appearance: MailAppearance = .system
    @AppStorage(MailboxTheme.lightPreference) private var lightTheme: MailboxTheme = .native
    @AppStorage(MailboxTheme.darkPreference) private var darkTheme: MailboxTheme = .native
    @AppStorage(PostmereAccent.preferenceKey) private var primary = PostmereAccent.defaultRGB
    @State private var editingScheme: ColorScheme?

    private static let swatches = [
        ("Postmere green", PostmereAccent.defaultRGB), ("Ocean", 0x367FA8), ("Indigo", 0x6257B4),
        ("Violet", 0x9A62AF), ("Rose", 0xBC5971), ("Copper", 0xBC7542), ("Slate", 0x697882)
    ]
    private var previewScheme: ColorScheme { appearance.colorScheme ?? editingScheme ?? scheme }
    private var selection: Binding<MailboxTheme> { previewScheme == .dark ? $darkTheme : $lightTheme }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 21) {
                HStack {
                    Text("Color mode").font(.headline)
                    Spacer()
                    Picker("Appearance", selection: $appearance) {
                        ForEach(MailAppearance.allCases, id: \.self) { mode in Text(mode.title).tag(mode) }
                    }
                    .pickerStyle(.segmented).labelsHidden().fixedSize()
                }
                Divider()
                HStack {
                    Text("Theme").font(.headline)
                    Spacer()
                    if appearance == .system {
                        Picker("Edit theme for", selection: Binding(
                            get: { previewScheme },
                            set: { editingScheme = $0 == scheme ? nil : $0 }
                        )) {
                            Text("When light").tag(ColorScheme.light)
                            Text("When dark").tag(ColorScheme.dark)
                        }
                        .pickerStyle(.segmented).labelsHidden().controlSize(.small).fixedSize()
                    }
                }
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 16), count: 3),
                          alignment: .leading, spacing: 16) {
                    ForEach(MailboxTheme.allCases) { option in
                        let selected = selection.wrappedValue == option
                        Button { selection.wrappedValue = option } label: {
                            VStack(alignment: .leading, spacing: 6) {
                                MailboxThemePreview(theme: option, scheme: previewScheme, accent: accent)
                                    .aspectRatio(2.4, contentMode: .fit)
                                    .clipShape(.rect(cornerRadius: 7))
                                    .overlay {
                                        RoundedRectangle(cornerRadius: 7).strokeBorder(
                                            selected ? accent.accentInk : Color.primary.opacity(0.16), lineWidth: selected ? 2 : 1)
                                    }
                                HStack(spacing: 5) {
                                    Text(option.title).font(.callout.weight(selected ? .semibold : .regular))
                                    if selected { Image(systemName: "checkmark").font(.caption.bold()).foregroundStyle(accent.accentInk) }
                                }
                                .frame(height: 18, alignment: .leading)
                            }
                            .contentShape(.rect)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("\(option.title), \(previewScheme == .dark ? "dark" : "light") theme")
                        .accessibilityAddTraits(selected ? .isSelected : [])
                    }
                }
                if appearance == .system, previewScheme != scheme {
                    Text("\(selection.wrappedValue.title) will apply when your Mac switches to \(previewScheme == .dark ? "dark" : "light") appearance.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                Divider()
                HStack(spacing: 10) {
                    Text("Primary color").font(.headline)
                    Spacer()
                    ForEach(Self.swatches, id: \.1) { name, rgb in
                        let swatch = PostmereAccent(rgb: rgb)
                        Button { primary = rgb } label: {
                            ZStack {
                                Circle().fill(swatch.swatch).padding(3)
                                if primary == rgb {
                                    Circle().strokeBorder(.primary, lineWidth: 1.5)
                                }
                            }
                            .frame(width: 24, height: 24).contentShape(.rect)
                        }
                        .buttonStyle(.plain).help(name).accessibilityLabel(name)
                        .accessibilityAddTraits(primary == rgb ? .isSelected : [])
                    }
                    Divider().frame(height: 18)
                    ColorPicker("Custom primary color", selection: Binding(
                        get: { accent.swatch },
                        set: { if let rgb = PostmereAccent.rgbValue(of: $0) { primary = rgb } }
                    ), supportsOpacity: false)
                    .labelsHidden().help("Choose a custom primary color")
                }
            }
            .frame(maxWidth: 660, alignment: .leading)
            .padding(28)
            .frame(maxWidth: .infinity)
        }
        .onChange(of: appearance) { editingScheme = nil }
        .onChange(of: scheme) { if editingScheme == scheme { editingScheme = nil } }
    }
}

private struct MailboxThemePreview: View {
    let theme: MailboxTheme
    let scheme: ColorScheme
    let accent: PostmereAccent

    var body: some View {
        Canvas { context, size in
            let colors = theme.colors(for: scheme)
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
