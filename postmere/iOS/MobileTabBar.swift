import SwiftUI
import UIKit

/// The three places on a phone: mail, the assistant, and a triage pass.
enum MobileTab: String, CaseIterable, Identifiable {
    case home, ai, triage
    var id: String { rawValue }

    var title: String {
        switch self {
        case .home: "Home"
        case .ai: "Ask"
        case .triage: "Triage"
        }
    }

    func symbol(selected: Bool) -> String {
        switch self {
        case .home: selected ? "house.fill" : "house"
        case .ai: "sparkles"
        case .triage: selected ? "rectangle.stack.fill" : "rectangle.stack"
        }
    }
}

/// Plain icons on the page, with one glass capsule under the selected tab. Tap a tab,
/// or press and drag the capsule: it lifts, follows the finger and settles on the
/// nearest tab. Touch and hold Home to switch accounts.
struct MobileTabBar: View {
    @Binding var selection: MobileTab
    let onHoldHome: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// The capsule's centre while a finger is moving it, else nil.
    @State private var dragX: CGFloat?

    private let tabs = MobileTab.allCases
    /// Each tab takes a fixed slot, so the bar hugs its tabs in the centre and
    /// widens on its own when a tab is added.
    private let slot: CGFloat = 60
    private let capsuleWidth: CGFloat = 54
    private let height: CGFloat = 44

    var body: some View {
        let width = slot * CGFloat(tabs.count)
        let restingX = slot * (CGFloat(index(of: selection)) + 0.5)
        let x = dragX ?? restingX
        let hovered = dragX.map { tab(at: $0, slot: slot) } ?? selection
        HStack {
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(.clear)
                    .frame(width: capsuleWidth, height: height)
                    .glassEffect(.regular.tint(Color(uiColor: .systemGray4).opacity(0.35)).interactive(), in: Capsule())
                    .scaleEffect(dragX == nil ? 1 : 1.18)
                    .offset(x: x - capsuleWidth / 2)
                    .allowsHitTesting(false)
                HStack(spacing: 0) {
                    ForEach(tabs) { tab in item(tab, highlighted: tab == hovered) }
                }
            }
            .frame(width: width, height: height)
            .contentShape(Rectangle())
            .gesture(drag(slot: slot, width: width))
        }
        .frame(maxWidth: .infinity)
        .sensoryFeedback(.selection, trigger: selection)
    }

    private func item(_ tab: MobileTab, highlighted: Bool) -> some View {
        Image(systemName: tab.symbol(selected: highlighted))
            .font(.system(size: 18, weight: highlighted ? .semibold : .regular))
            .foregroundStyle(highlighted ? Color.primary : Color.secondary)
            .contentTransition(.symbolEffect(.replace))
            .frame(width: slot, height: height)
            .contentShape(Rectangle())
            .onTapGesture { select(tab) }
            .onLongPressGesture(minimumDuration: 0.35) {
                guard tab == .home else { return select(tab) }
                UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                onHoldHome()
            }
            .accessibilityElement()
            .accessibilityLabel(tab.title)
            .accessibilityAddTraits(selection == tab ? [.isButton, .isSelected] : .isButton)
            .accessibilityAction { select(tab) }
            .accessibilityAction(named: "Switch Account") { if tab == .home { onHoldHome() } }
    }

    /// Moving more than a few points takes over from tap and hold.
    private func drag(slot: CGFloat, width: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 6)
            .onChanged { value in
                let clamped = min(max(value.location.x, capsuleWidth / 2), width - capsuleWidth / 2)
                if dragX == nil {
                    UIImpactFeedbackGenerator(style: .light).impactOccurred()
                    withAnimation(.snappy(duration: 0.2)) { dragX = clamped }
                } else {
                    let before = tab(at: dragX ?? clamped, slot: slot)
                    dragX = clamped
                    if tab(at: clamped, slot: slot) != before { UISelectionFeedbackGenerator().selectionChanged() }
                }
            }
            .onEnded { value in
                let target = tab(at: value.predictedEndLocation.x, slot: slot)
                withAnimation(reduceMotion ? .easeOut(duration: 0.15) : .bouncy(duration: 0.45, extraBounce: 0.1)) {
                    selection = target
                    dragX = nil
                }
            }
    }

    private func index(of tab: MobileTab) -> Int { tabs.firstIndex(of: tab) ?? 0 }

    private func tab(at x: CGFloat, slot: CGFloat) -> MobileTab {
        tabs[min(max(Int(x / slot), 0), tabs.count - 1)]
    }

    private func select(_ tab: MobileTab) {
        guard selection != tab else { return }
        withAnimation(reduceMotion ? .easeOut(duration: 0.15) : .bouncy(duration: 0.4, extraBounce: 0.08)) {
            selection = tab
        }
    }
}

extension EnvironmentValues {
    /// Height of the floating tab bar, which each tab keeps its bottom content above.
    @Entry var mobileTabBarInset: CGFloat = 0
}

extension View {
    /// Lifts this screen's bottom content (and its own bottom insets) above the tab bar.
    func aboveMobileTabBar() -> some View { modifier(AboveTabBar()) }
}

private struct AboveTabBar: ViewModifier {
    @Environment(\.mobileTabBarInset) private var inset
    func body(content: Content) -> some View { content.safeAreaPadding(.bottom, inset) }
}

// MARK: - Home accessory

/// Search and compose above the tabs on Home.
struct MobileHomeAccessory: View {
    let store: MailStore
    @Environment(\.postmereAccent) private var palette
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(.secondary)
                TextField("Search mail", text: Binding(get: { store.searchText }, set: store.searchFieldChanged))
                    .font(.system(size: 16))
                    .focused($focused)
                    .submitLabel(.search)
                    .autocorrectionDisabled()
                if focused || store.isSearchActive {
                    Button("Cancel Search", systemImage: "xmark.circle.fill") {
                        store.endSearch()
                        focused = false
                    }
                    .labelStyle(.iconOnly)
                    .foregroundStyle(.tertiary)
                    .transition(.opacity)
                }
            }
            .padding(.horizontal, 15)
            .frame(height: 44)
            .glassEffect(.regular.interactive(), in: Capsule())
            if !focused {
                // Drawn at exactly the field's height: a prominent glass button style
                // would add its own padding around the label.
                Button { store.beginCompose() } label: {
                    Image(systemName: "square.and.pencil")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(width: 44, height: 44)
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .glassEffect(.regular.tint(palette.accent).interactive(), in: Circle())
                .disabled(MailAccount.sendingAccounts.isEmpty)
                .accessibilityLabel("Compose")
                .transition(.scale.combined(with: .opacity))
            }
        }
        .animation(.snappy(duration: 0.25), value: focused)
        .padding(.horizontal, 16)
    }
}

// MARK: - Account switcher

/// Touch and hold Home: every account, or all of them together. The sheet is only
/// as tall as its rows, up to a cap, after which the list scrolls.
struct MobileAccountSwitcher: View {
    let runtime: MailRuntime
    @Environment(\.dismiss) private var dismiss
    @Environment(\.postmereAccent) private var palette
    @State private var contentHeight: CGFloat = 180

    private var store: MailStore { runtime.store }
    private let headerHeight: CGFloat = 58
    /// The device's height, not the sheet's, so the cap doesn't depend on itself.
    private var screenHeight: CGFloat {
        (UIApplication.shared.connectedScenes.first as? UIWindowScene)?.screen.bounds.height ?? 800
    }

    var body: some View {
        VStack(spacing: 0) {
                HStack {
                    Text("Switch Account").font(.headline)
                    Spacer()
                    Button("Close", systemImage: "xmark") { dismiss() }
                        .labelStyle(.iconOnly)
                        .font(.system(size: 14, weight: .bold))
                        .foregroundStyle(.secondary)
                        .frame(width: 32, height: 32)
                        .background(Mobile.raised, in: Circle())
                        .buttonStyle(.plain)
                }
                .padding(.horizontal, 20)
                .frame(height: headerHeight)
                ScrollView {
                    VStack(spacing: 0) {
                        row(nil, title: "All Accounts", detail: MailAccount.allCases.count == 1 ? "1 account" : "\(MailAccount.allCases.count) accounts", address: nil)
                        ForEach(MailAccount.allCases) { account in
                            MobileHairline(leading: 70)
                            row(account.rawValue, title: account.title,
                                detail: account.title == account.email ? nil : account.email, address: account.email)
                        }
                    }
                    .background(Mobile.raised, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                    .padding(.horizontal, 16)
                    .padding(.bottom, 12)
                }
                .scrollBounceBehavior(.basedOnSize)
                .onScrollGeometryChange(for: CGFloat.self, of: { $0.contentSize.height }) { contentHeight = $1 }
            }
        .presentationDetents([.height(min(headerHeight + contentHeight, screenHeight * 0.55))])
        .presentationDragIndicator(.hidden)
    }

    private func row(_ id: String?, title: String, detail: String?, address: String?) -> some View {
        Button {
            store.selectAccount(id)
            UISelectionFeedbackGenerator().selectionChanged()
            dismiss()
        } label: {
            HStack(spacing: 14) {
                if let address {
                    MobileAccountAvatar(address: address, name: title,
                                        provider: MailAccount(rawValue: id ?? "")?.remote?.provider, size: 40)
                } else {
                    Image(systemName: "tray.2.fill")
                        .font(.system(size: 17))
                        .foregroundStyle(.white)
                        .frame(width: 40, height: 40)
                        .background(palette.accent, in: Circle())
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.body.weight(.semibold)).foregroundStyle(.primary).lineLimit(1)
                    if let detail { Text(detail).font(.footnote).foregroundStyle(.secondary).lineLimit(1) }
                }
                Spacer()
                if store.selectedAccount == id {
                    Image(systemName: "checkmark.circle.fill").font(.title3).foregroundStyle(palette.accent)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 11)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(store.selectedAccount == id ? .isSelected : [])
    }
}

// MARK: - Triage tab

/// The Triage tab: a pass in progress, or what's waiting and a button to start.
struct MobileTriageTab: View {
    let runtime: MailRuntime
    let isActive: Bool
    @Environment(\.postmereAccent) private var palette

    private var store: MailStore { runtime.store }
    private var waiting: [MailMessage] {
        (store.mailboxViewData.map { Array($0.messages) } ?? []).filter { !$0.isDraft && $0.mailbox != .outbox }
    }
    private var unread: Int { waiting.count(where: \.isUnread) }

    var body: some View {
        if let session = runtime.triage {
            MobileTriageScreen(session: session, runtime: runtime, isActive: isActive)
        } else {
            VStack(spacing: 16) {
                Spacer()
                Image(systemName: "rectangle.stack.fill")
                    .font(.system(size: 34))
                    .foregroundStyle(palette.accent)
                    .frame(width: 76, height: 76)
                    .background(palette.accent.opacity(0.12), in: Circle())
                Text(unread == 0 ? "You’re caught up" : "\(min(unread, 40)) to triage")
                    .font(.system(size: 28, weight: .bold))
                Text(unread == 0
                     ? "Nothing unread in \(store.selectedMailbox.title). You can still go through recent mail."
                     : "One conversation at a time: archive, snooze, reply or skip. Suggestions show what each one needs.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 300)
                Button { runtime.startTriage(waiting, store: store) } label: {
                    Text(unread == 0 ? "Review Recent Mail" : "Start Triage")
                        .font(.headline)
                        .frame(maxWidth: 260, minHeight: 44)
                }
                .buttonStyle(.glassProminent)
                .tint(palette.accent)
                .disabled(waiting.isEmpty)
                .padding(.top, 8)
                Spacer()
                Spacer()
            }
            .padding(.horizontal, 28)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .aboveMobileTabBar()
            .background(Mobile.background)
            .task { await runtime.triageSuggestions.prefetch(Array(waiting.filter(\.isUnread).prefix(12)), session: runtime.backend) }
            #if DEBUG
            .task(id: waiting.count) {
                if ProcessInfo.processInfo.arguments.contains("-PostmereStartTriage"), !waiting.isEmpty {
                    runtime.startTriage(waiting, store: store)
                }
            }
            #endif
        }
    }
}

extension MailRuntime {
    /// Works through conversations one at a time, likely-important first, with bulk
    /// mail offered as one decision. Unread mail is the work; with none, recent mail.
    func startTriage(_ rows: [MailMessage], store: MailStore) {
        let candidates = rows.filter { !$0.isDraft && $0.mailbox != .outbox }
        let unread = candidates.filter(\.isUnread)
        let queue = Array((unread.isEmpty ? candidates : unread).prefix(40))
        let ids = triageSuggestions.ordered(queue.map(\.id))
        guard !ids.isEmpty else { return }
        let title = store.selectedInboxSplitID.flatMap { id in store.visibleInboxSplits.first { $0.id == id }?.name }
            ?? store.selectedMailbox.title
        withAnimation(.snappy) {
            triage = TriageSession(title: title, ids: ids, batch: triageSuggestions.batch(in: ids))
        }
    }
}
