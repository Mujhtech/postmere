import SwiftUI

/// The Postmere paper canvas with a soft accent glow. Only sign-in uses it now;
/// the mail screens sit on plain system backgrounds so dark mode is true black.
struct MobileCanvas: View {
    var glowAt = UnitPoint(x: 0.5, y: 0)
    var glow = 0.10
    @Environment(\.postmereAccent) private var palette

    var body: some View {
        GeometryReader { proxy in
            PostmereTheme.paper.overlay {
                RadialGradient(colors: [palette.swatch.opacity(glow), .clear], center: glowAt,
                               startRadius: 0, endRadius: max(300, proxy.size.width * 0.9))
            }
        }
        .ignoresSafeArea()
    }
}

/// Dense, fast, low-chrome styling for the mail screens.
enum Mobile {
    static let background = Color(uiColor: .systemBackground)
    static let raised = Color(uiColor: .secondarySystemBackground)
    static let hairline = Color(uiColor: .separator).opacity(0.6)
    static let gutter: CGFloat = 18

    static let screenTitle = Font.system(size: 30, weight: .bold)
    static let rowSender = Font.system(size: 16, weight: .semibold)
    static let rowSenderRead = Font.system(size: 16, weight: .regular)
    static let rowLine = Font.system(size: 14.5)
    static let meta = Font.system(size: 13)
}

/// A one-point rule that runs edge to edge, or from a leading inset.
struct MobileHairline: View {
    var leading: CGFloat = 0

    var body: some View {
        Rectangle().fill(Mobile.hairline).frame(height: 0.5).padding(.leading, leading)
    }
}

/// A short, quiet empty state: a symbol, one bold line and a note.
struct MobileEmptyState<Actions: View>: View {
    let symbol: String
    let title: String
    let message: String
    @ViewBuilder var actions: () -> Actions

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: symbol)
                .font(.system(size: 34, weight: .light))
                .foregroundStyle(.tertiary)
                .padding(.bottom, 6)
            Text(title)
                .font(.title3.weight(.semibold))
                .accessibilityAddTraits(.isHeader)
            Text(message)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 300)
            actions().padding(.top, 10)
        }
        .padding(.horizontal, 28)
        .frame(maxWidth: .infinity)
    }
}

extension MobileEmptyState where Actions == EmptyView {
    init(symbol: String, title: String, message: String) {
        self.init(symbol: symbol, title: title, message: message) { EmptyView() }
    }
}

/// An account's photo with its mail provider's logo (Gmail, Outlook) tucked in the corner.
struct MobileAccountAvatar: View {
    let address: String
    var name = ""
    var provider: String?
    var size: CGFloat = 40

    var body: some View {
        ParticipantPhoto(address: address, name: name, size: size)
            .overlay(alignment: .bottomTrailing) {
                if let brand = provider.flatMap(Brand.init(mailProvider:)) {
                    let badge = max(14, size * 0.42)
                    BrandMark(brand: brand, size: badge * 0.66)
                        .frame(width: badge, height: badge)
                        .background(.white, in: Circle())
                        .overlay { Circle().strokeBorder(Color(uiColor: .systemBackground), lineWidth: max(1.5, size * 0.04)) }
                        .offset(x: badge * 0.18, y: badge * 0.18)
                }
            }
            .accessibilityHidden(true)
    }
}

extension Brand {
    /// "Gmail" or "Outlook", for a connected account's provider.
    static func providerName(_ provider: String?) -> String? {
        switch provider.flatMap(Brand.init(mailProvider:)) {
        case .gmail: "Gmail"
        case .outlook: "Outlook"
        default: nil
        }
    }
}

/// A leading-aligned vertical stack that adds no spacing around children with no height,
/// so views that only run a task until they have something to show don't leave gaps.
struct MobileCollapsingStack: Layout {
    var spacing: CGFloat = 10

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        var height: CGFloat = 0, width: CGFloat = 0, placed = 0
        for subview in subviews {
            let size = subview.sizeThatFits(ProposedViewSize(width: proposal.width, height: nil))
            guard size.height > 0 else { continue }
            height += size.height + (placed > 0 ? spacing : 0)
            width = max(width, size.width)
            placed += 1
        }
        return CGSize(width: proposal.width ?? width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY, placed = 0
        for subview in subviews {
            let size = subview.sizeThatFits(ProposedViewSize(width: bounds.width, height: nil))
            guard size.height > 0 else {
                subview.place(at: CGPoint(x: bounds.minX, y: y), proposal: .zero)
                continue
            }
            if placed > 0 { y += spacing }
            subview.place(at: CGPoint(x: bounds.minX, y: y), proposal: ProposedViewSize(width: bounds.width, height: size.height))
            y += size.height
            placed += 1
        }
    }
}

// MARK: - Motion

/// The app's few motion curves, so screens move with one voice.
enum MobileMotion {
    /// Things arriving or growing: a soft spring with a hint of settle.
    static let reveal = Animation.spring(duration: 0.5, bounce: 0.18)
    /// Small toggles and disclosure.
    static let quick = Animation.snappy(duration: 0.3)
    /// Content that streams in a piece at a time.
    static let stream = Animation.smooth(duration: 0.35)

    /// A card dropping in from the view above it, and settling back out.
    static var card: AnyTransition {
        .asymmetric(insertion: .scale(scale: 0.94, anchor: .top).combined(with: .opacity).combined(with: .offset(y: -8)),
                    removal: .scale(scale: 0.97, anchor: .top).combined(with: .opacity))
    }

    /// One row of a list arriving after the ones before it.
    static func staggered(_ index: Int) -> AnyTransition {
        .asymmetric(insertion: .opacity.combined(with: .offset(y: 8))
                        .animation(reveal.delay(Double(min(index, 8)) * 0.05)),
                    removal: .opacity.animation(quick))
    }
}

/// A light sheen that sweeps across its content, for placeholders that are still loading.
struct MobileShimmer: ViewModifier {
    var isActive = true
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var colorScheme

    func body(content: Content) -> some View {
        content.overlay {
            if isActive && !reduceMotion {
                TimelineView(.animation) { context in
                    let period = 1.5
                    let phase = context.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: period) / period
                    GeometryReader { proxy in
                        let band = max(80, proxy.size.width * 0.45)
                        LinearGradient(colors: [.clear, .white.opacity(colorScheme == .dark ? 0.16 : 0.6), .clear],
                                       startPoint: .leading, endPoint: .trailing)
                            .frame(width: band)
                            .offset(x: -band + phase * (proxy.size.width + band * 2))
                    }
                }
                .mask(content)
                .allowsHitTesting(false)
                .transition(.opacity)
            }
        }
    }
}

extension View {
    func mobileShimmer(_ isActive: Bool = true) -> some View { modifier(MobileShimmer(isActive: isActive)) }
}

/// Rounded bars standing in for lines of text that haven't arrived yet.
struct MobileSkeletonLines: View {
    var widths: [CGFloat] = [1, 0.94, 0.62]
    var lineHeight: CGFloat = 11
    var tint: Color = .primary

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            ForEach(Array(widths.enumerated()), id: \.offset) { _, width in
                // Measured against this view's own width: the scroll view's would overflow a card.
                GeometryReader { proxy in
                    Capsule()
                        .fill(tint.opacity(0.13))
                        .frame(width: proxy.size.width * width)
                }
                .frame(height: lineHeight)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .mobileShimmer()
        .accessibilityHidden(true)
    }
}

/// The edge of a card the assistant is working on: a band of accent light travelling round it,
/// fading to a still hairline once the work is done.
struct MobileAIGlowBorder: View {
    var isActive: Bool
    var color: Color
    var cornerRadius: CGFloat = 16
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        ZStack {
            shape.strokeBorder(color.opacity(0.18))
            TimelineView(.animation(paused: !isActive || reduceMotion)) { context in
                let degrees = (context.date.timeIntervalSinceReferenceDate * 140).truncatingRemainder(dividingBy: 360)
                let gradient = AngularGradient(colors: [color.opacity(0.05), color, color.opacity(0.35), color.opacity(0.05),
                                                        color.opacity(0.7), color.opacity(0.05)],
                                               center: .center, angle: .degrees(degrees))
                ZStack {
                    shape.strokeBorder(gradient, lineWidth: 1.6)
                    shape.strokeBorder(gradient, lineWidth: 5).blur(radius: 8).opacity(0.55)
                }
            }
            .opacity(isActive ? 1 : 0)
            .animation(.easeOut(duration: 0.7), value: isActive)
        }
        .allowsHitTesting(false)
    }
}

// MARK: - Settings surfaces

/// The Mac Settings window's look on the phone: a warm canvas with paper cards
/// edged by a hairline, instead of the system's cool grey.
enum MobileSettingsStyle {
    static let canvas = Color(uiColor: UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor(red: 0.071, green: 0.078, blue: 0.075, alpha: 1)
            : UIColor(red: 0.945, green: 0.941, blue: 0.922, alpha: 1)
    })
    static let card = PostmereTheme.paper
    static let edge = PostmereTheme.rule.opacity(0.75)
}

extension View {
    /// A settings group card.
    func mobileSettingsCard(cornerRadius: CGFloat = 22) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        return background(MobileSettingsStyle.card, in: shape)
            .overlay { shape.strokeBorder(MobileSettingsStyle.edge, lineWidth: 0.5) }
    }

    /// The settings canvas behind a screen, including lists pushed inside Settings.
    func mobileSettingsCanvas() -> some View {
        scrollContentBackground(.hidden)
            .background { MobileSettingsStyle.canvas.ignoresSafeArea() }
            .containerBackground(MobileSettingsStyle.canvas, for: .navigation)
    }

    /// List rows drawn as paper cards on the settings canvas.
    func mobileSettingsRows() -> some View {
        listRowBackground(MobileSettingsStyle.card)
    }
}

// MARK: - Expandable sheets

extension EnvironmentValues {
    /// True while a medium/large sheet is pulled up to full height.
    @Entry var mobileSheetExpanded = false
}

/// Compact, a sheet keeps the system's glass. Pulled up to full height, it takes
/// the Settings look: the warm canvas behind, and lists drawn on it.
private struct MobileSheetSurface: ViewModifier {
    let detents: Set<PresentationDetent>
    @State private var detent: PresentationDetent

    init(detents: Set<PresentationDetent>, initial: PresentationDetent) {
        self.detents = detents
        var start = initial
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("-PostmereSheetsLarge"), detents.contains(.large) { start = .large }
        #endif
        _detent = State(initialValue: start)
    }

    func body(content: Content) -> some View {
        let expanded = detent == .large
        content
            .scrollContentBackground(expanded ? .hidden : .automatic)
            .background {
                MobileSettingsStyle.canvas
                    .ignoresSafeArea()
                    .opacity(expanded ? 1 : 0)
                    .animation(.smooth(duration: 0.3), value: expanded)
            }
            .environment(\.mobileSheetExpanded, expanded)
            .presentationDetents(detents, selection: $detent)
    }
}

/// List rows that become paper cards when their sheet is expanded.
private struct MobileSheetRows: ViewModifier {
    @Environment(\.mobileSheetExpanded) private var expanded

    func body(content: Content) -> some View {
        content.listRowBackground(expanded ? MobileSettingsStyle.card : nil)
    }
}

extension View {
    /// Medium and large detents with the glass-to-Settings surface change.
    func mobileSheetDetents(_ detents: Set<PresentationDetent> = [.medium, .large],
                            initial: PresentationDetent = .medium) -> some View {
        modifier(MobileSheetSurface(detents: detents, initial: initial))
    }

    /// Apply to a list's sections inside an expandable sheet.
    func mobileSheetRows() -> some View {
        modifier(MobileSheetRows())
    }
}
