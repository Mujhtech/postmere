import AppKit
import SwiftUI

/// Gives every in-app pop-up, pull-down and context menu the same selection as
/// the sidebar and message list: the primary color's selection fill with
/// selection ink, instead of AppKit's fixed asset-catalog accent.
///
/// AppKit draws the highlight as one visual-effect view that it moves behind the
/// hovered row, then switches that row's labels to `selectedMenuItemTextColor`.
/// A fill inside the effect view follows it automatically, and the highlighted
/// row's labels are recolored after AppKit updates them. Items keep their native
/// views, target/action and accessibility.
@MainActor
final class PostmereMenuHighlighter: NSObject {
    private var highlights: [ObjectIdentifier: MenuHighlight] = [:]

    func start() {
        let center = NotificationCenter.default
        center.addObserver(self, selector: #selector(menuWillTrack(_:)),
                           name: NSMenu.didBeginTrackingNotification, object: nil)
        center.addObserver(self, selector: #selector(menuDidClose(_:)),
                           name: NSMenu.didEndTrackingNotification, object: nil)
    }

    @objc private func menuWillTrack(_ note: Notification) {
        guard let menu = note.object as? NSMenu, menu.supermenu == nil,
              menu !== NSApp.mainMenu, highlights[ObjectIdentifier(menu)] == nil else { return }
        let rgb = UserDefaults.standard.object(forKey: PostmereAccent.preferenceKey) as? Int
        let accent = PostmereAccent(rgb: rgb ?? PostmereAccent.defaultRGB)
        attach(to: menu, fill: NSColor(accent.selectionFill), ink: NSColor(accent.selectionInk))
    }

    @objc private func menuDidClose(_ note: Notification) {
        guard let menu = note.object as? NSMenu, menu.supermenu == nil else { return }
        detach(from: menu)
    }

    private func attach(to menu: NSMenu, fill: NSColor, ink: NSColor) {
        highlights[ObjectIdentifier(menu)] = MenuHighlight(menu: menu, fill: fill, ink: ink)
        for item in menu.items {
            if let submenu = item.submenu { attach(to: submenu, fill: fill, ink: ink) }
        }
    }

    private func detach(from menu: NSMenu) {
        highlights.removeValue(forKey: ObjectIdentifier(menu))?.detach()
        for item in menu.items {
            if let submenu = item.submenu { detach(from: submenu) }
        }
    }
}

/// Wraps the menu's delegate to follow the highlighted row. Unhandled delegate
/// messages are forwarded to the original delegate.
@MainActor
private final class MenuHighlight: NSObject, NSMenuDelegate {
    private weak var menu: NSMenu?
    private weak var originalDelegate: NSMenuDelegate?
    private let fill: NSColor
    private let ink: NSColor
    private weak var fillView: SelectionFillView?
    private weak var pendingItem: NSMenuItem?

    init(menu: NSMenu, fill: NSColor, ink: NSColor) {
        self.menu = menu
        originalDelegate = menu.delegate
        self.fill = fill
        self.ink = ink
        super.init()
        menu.delegate = self
    }

    func detach() {
        fillView?.removeFromSuperview()
        if menu?.delegate === self { menu?.delegate = originalDelegate }
    }

    override func responds(to selector: Selector!) -> Bool {
        super.responds(to: selector) || originalDelegate?.responds(to: selector) == true
    }

    override func forwardingTarget(for selector: Selector!) -> Any? {
        originalDelegate?.responds(to: selector) == true ? originalDelegate : super.forwardingTarget(for: selector)
    }

    func menu(_ menu: NSMenu, willHighlight item: NSMenuItem?) {
        originalDelegate?.menu?(menu, willHighlight: item)
        guard let item, item.isEnabled, item.view == nil else { return }
        // AppKit moves the highlight and recolors labels after this callback.
        pendingItem = item
        RunLoop.main.perform(inModes: [.eventTracking, .default, .modalPanel]) { [weak self] in
            MainActor.assumeIsolated {
                guard let self, let item = self.pendingItem else { return }
                self.apply(to: item)
            }
        }
    }

    private func apply(to item: NSMenuItem) {
        let frame = item.accessibilityFrame()
        guard !frame.isEmpty, item.isHighlighted,
              let window = NSApp.windows.first(where: {
                  $0.isVisible && $0.level == .popUpMenu && $0.frame.contains(frame)
              }), let root = window.contentView?.superview else { return }
        let views = Self.descendants(of: root)

        if fillView?.window !== window,
           let highlight = views.lazy.compactMap({ $0 as? NSVisualEffectView })
               .first(where: { $0.className.contains("MenuWindowBackground") }) {
            fillView?.removeFromSuperview()
            let view = SelectionFillView(frame: highlight.bounds)
            view.autoresizingMask = [.width, .height]
            highlight.addSubview(view)
            fillView = view
        }
        fillView?.color = fill

        // Only the hovered row's labels use the selected text color.
        let selected = NSColor.selectedMenuItemTextColor
        for case let label as NSTextField in views where label.textColor == selected {
            label.textColor = ink
        }
    }

    private static func descendants(of view: NSView) -> [NSView] {
        view.subviews.flatMap { [$0] + descendants(of: $0) }
    }
}

/// Matches the inner rounded material layer of AppKit's menu highlight.
private final class SelectionFillView: NSView {
    var color: NSColor = .clear { didSet { updateLayer() } }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.cornerRadius = 7
        layer?.cornerCurve = .continuous
    }

    required init?(coder: NSCoder) { nil }

    override var wantsUpdateLayer: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func isAccessibilityElement() -> Bool { false }

    override func updateLayer() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor = color.cgColor
        }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }
}
