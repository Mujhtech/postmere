import SwiftUI
import WidgetKit

// The look shared by every Postmere widget: the app's warm paper, an accent glow,
// serif numerals like the app's headings, and colour that steps aside when the
// Home Screen is tinted or clear.

extension Color {
    init(rgb: Int) {
        self.init(red: Double((rgb >> 16) & 0xFF) / 255, green: Double((rgb >> 8) & 0xFF) / 255,
                  blue: Double(rgb & 0xFF) / 255)
    }
}

extension MailWidgetSnapshot {
    var accent: Color { Color(rgb: accentRGB) }
}

enum WidgetInk {
    /// Needs Reply's warm amber, distinct from the inbox accent.
    static let ember = Color(red: 0.86, green: 0.47, blue: 0.16)
    static let paperLight = Color(red: 0.985, green: 0.975, blue: 0.955)
    static let paperDark = Color(red: 0.075, green: 0.082, blue: 0.08)
}

/// The widget background: paper in light mode, near-black in dark, lit by the accent.
struct WidgetCanvas: View {
    var tint: Color
    var glowAt: UnitPoint = .topLeading
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let paper = scheme == .dark ? WidgetInk.paperDark : WidgetInk.paperLight
        ZStack {
            paper
            RadialGradient(colors: [tint.opacity(scheme == .dark ? 0.30 : 0.20), .clear],
                           center: glowAt, startRadius: 0, endRadius: 220)
            LinearGradient(colors: [.clear, tint.opacity(scheme == .dark ? 0.08 : 0.05)],
                           startPoint: .top, endPoint: .bottom)
        }
    }
}

/// True when the Home Screen is tinted or clear and colour fills would turn to grey slabs.
struct WidgetFullColor {
    let mode: WidgetRenderingMode
    var isFull: Bool { mode == .fullColor }
}

/// The app icon's idea in miniature: an envelope on a rounded accent stamp.
struct WidgetStamp: View {
    var symbol = "envelope.fill"
    var size: CGFloat = 26
    var tint: Color
    @Environment(\.widgetRenderingMode) private var mode

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: size * 0.48, weight: .semibold))
            .foregroundStyle(mode == .fullColor ? AnyShapeStyle(.white) : AnyShapeStyle(.primary))
            .frame(width: size, height: size)
            .background {
                RoundedRectangle(cornerRadius: size * 0.3, style: .continuous)
                    .fill(mode == .fullColor
                          ? AnyShapeStyle(LinearGradient(colors: [tint.mix(with: .white, by: 0.12), tint],
                                                         startPoint: .top, endPoint: .bottom))
                          : AnyShapeStyle(.primary.opacity(0.18)))
            }
            .widgetAccentable()
            .accessibilityHidden(true)
    }
}

/// Large numerals in the app's serif.
struct WidgetFigure: View {
    let value: Int
    var size: CGFloat = 46

    var body: some View {
        Text(value, format: .number)
            .font(.system(size: size, weight: .semibold, design: .serif))
            .monospacedDigit()
            .contentTransition(.numericText(value: Double(value)))
            .minimumScaleFactor(0.5)
            .lineLimit(1)
    }
}

/// Initials on a soft gradient chosen from the sender's name, so the same person
/// always gets the same colour. Widgets can't load photos at render time.
struct WidgetAvatar: View {
    let name: String
    let initials: String
    var size: CGFloat = 28
    @Environment(\.widgetRenderingMode) private var mode

    init(message: MailWidgetSnapshot.Message, size: CGFloat = 28) {
        name = message.sender
        initials = message.initials
        self.size = size
    }

    private static let palette: [Color] = [
        Color(red: 0.29, green: 0.53, blue: 0.46), Color(red: 0.21, green: 0.50, blue: 0.66),
        Color(red: 0.38, green: 0.34, blue: 0.71), Color(red: 0.60, green: 0.38, blue: 0.69),
        Color(red: 0.74, green: 0.35, blue: 0.44), Color(red: 0.76, green: 0.47, blue: 0.24),
        Color(red: 0.36, green: 0.45, blue: 0.53), Color(red: 0.24, green: 0.55, blue: 0.62),
    ]

    var body: some View {
        let index = abs(name.unicodeScalars.reduce(0) { ($0 &* 31) &+ Int($1.value) }) % Self.palette.count
        let color = Self.palette[index]
        Text(initials)
            .font(.system(size: size * 0.38, weight: .semibold, design: .rounded))
            .foregroundStyle(mode == .fullColor ? AnyShapeStyle(.white) : AnyShapeStyle(.primary))
            .frame(width: size, height: size)
            .background {
                Circle().fill(mode == .fullColor
                              ? AnyShapeStyle(LinearGradient(colors: [color.mix(with: .white, by: 0.18), color],
                                                             startPoint: .topLeading, endPoint: .bottomTrailing))
                              : AnyShapeStyle(.primary.opacity(0.15)))
            }
            .accessibilityHidden(true)
    }
}

/// A row of overlapping avatars: who's in the list at a glance.
struct WidgetAvatarStack: View {
    let messages: [MailWidgetSnapshot.Message]
    var size: CGFloat = 26
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        HStack(spacing: -size * 0.32) {
            ForEach(messages.prefix(3)) { message in
                WidgetAvatar(message: message, size: size)
                    .overlay { Circle().strokeBorder(scheme == .dark ? WidgetInk.paperDark : WidgetInk.paperLight, lineWidth: 2) }
            }
        }
    }
}

/// One message: avatar, sender, time, subject and optionally the preview.
struct WidgetMessageRow: View {
    let message: MailWidgetSnapshot.Message
    var showsPreview = false
    var avatarSize: CGFloat = 30
    var tint: Color

    var body: some View {
        Link(destination: PostmereLink.url(.message(message.id))) {
            HStack(alignment: .center, spacing: 10) {
                WidgetAvatar(message: message, size: avatarSize)
                    .overlay(alignment: .topLeading) {
                        if message.isUnread {
                            Circle().fill(tint)
                                .frame(width: 9, height: 9)
                                .overlay { Circle().strokeBorder(.background, lineWidth: 1.5) }
                                .offset(x: -2, y: -1)
                                .widgetAccentable()
                        }
                    }
                VStack(alignment: .leading, spacing: 1) {
                    HStack(alignment: .firstTextBaseline, spacing: 4) {
                        Text(message.sender)
                            .font(.system(size: 13.5, weight: message.isUnread ? .semibold : .medium))
                            .lineLimit(1)
                        if message.isStarred {
                            Image(systemName: "star.fill").font(.system(size: 9)).foregroundStyle(.orange)
                        }
                        if message.hasAttachments {
                            Image(systemName: "paperclip").font(.system(size: 9.5, weight: .semibold)).foregroundStyle(.tertiary)
                        }
                        Spacer(minLength: 4)
                        Text(message.sentAt, format: .relativeShort)
                            .font(.system(size: 11.5, weight: .medium))
                            .foregroundStyle(message.isUnread ? AnyShapeStyle(tint) : AnyShapeStyle(.tertiary))
                            .widgetAccentable(message.isUnread)
                    }
                    Text(message.subject.isEmpty ? "No subject" : message.subject)
                        .font(.system(size: 12.5, weight: message.isUnread ? .medium : .regular))
                        .foregroundStyle(message.isUnread ? .primary : .secondary)
                        .lineLimit(1)
                    if showsPreview, !message.preview.isEmpty {
                        Text(message.preview)
                            .font(.system(size: 12))
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                    }
                }
            }
        }
    }
}

/// A fine rule between rows.
struct WidgetRule: View {
    var inset: CGFloat = 40
    var body: some View {
        Rectangle().fill(.primary.opacity(0.08)).frame(height: 0.5).padding(.leading, inset)
    }
}

/// A pill-shaped shortcut: icon and label in the accent.
struct WidgetActionPill: View {
    let title: String
    let symbol: String
    let route: PostmereLink.Route
    var tint: Color

    var body: some View {
        Link(destination: PostmereLink.url(route)) {
            Label(title, systemImage: symbol)
                .font(.system(size: 12, weight: .semibold))
                .labelStyle(WidgetPillLabelStyle())
                .frame(maxWidth: .infinity, minHeight: 32)
                .foregroundStyle(tint)
                .background(tint.opacity(0.13), in: Capsule())
                .widgetAccentable()
        }
    }
}

private struct WidgetPillLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 5) {
            configuration.icon.font(.system(size: 11.5, weight: .bold))
            configuration.title
        }
    }
}

/// Shown when no account is signed in yet.
struct WidgetSignedOut: View {
    var tint: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            WidgetStamp(size: 30, tint: tint)
            Spacer(minLength: 0)
            Text("Postmere")
                .font(.system(size: 20, weight: .semibold, design: .serif))
            Text("Open the app to sign in and see your mail here.")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

/// A calm all-clear: a check in the accent and one line.
struct WidgetAllClear: View {
    let title: String
    var tint: Color

    var body: some View {
        VStack(spacing: 6) {
            Image(systemName: "checkmark.seal.fill")
                .font(.system(size: 24))
                .foregroundStyle(tint)
                .widgetAccentable()
            Text(title)
                .font(.system(size: 13, weight: .semibold, design: .serif))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

extension FormatStyle where Self == RelativeShortFormat {
    /// "now", "4m", "2h", "Mon", "12 Nov".
    static var relativeShort: RelativeShortFormat { RelativeShortFormat() }
}

struct RelativeShortFormat: FormatStyle {
    func format(_ date: Date) -> String {
        let seconds = Date.now.timeIntervalSince(date)
        if seconds < 60 { return "now" }
        if seconds < 3600 { return "\(Int(seconds / 60))m" }
        if Calendar.current.isDateInToday(date) { return "\(Int(seconds / 3600))h" }
        if seconds < 6 * 86400 { return date.formatted(.dateTime.weekday(.abbreviated)) }
        return date.formatted(.dateTime.day().month(.abbreviated))
    }
}
