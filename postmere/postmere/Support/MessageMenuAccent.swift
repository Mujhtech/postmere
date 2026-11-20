import AppKit
import Carbon.HIToolbox
import SwiftUI

/// SwiftUI creates the actions for the clicked selection. AppKit tracks the same menu.
struct MessageMenuAccent: NSViewRepresentable {
    let accent: PostmereAccent

    func makeNSView(context: Context) -> MessageMenuObserver { MessageMenuObserver() }

    func updateNSView(_ view: MessageMenuObserver, context: Context) {
        view.accent = accent
    }
}

final class MessageMenuObserver: NSView {
    var accent = PostmereAccent(rgb: PostmereAccent.defaultRGB)
    private weak var trackingMenu: NSMenu?
    private var highlights: [MenuHighlight] = []

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        let center = NotificationCenter.default
        stopTracking()
        center.removeObserver(self)
        if window != nil {
            center.addObserver(self, selector: #selector(menuWillTrack(_:)),
                               name: NSMenu.didBeginTrackingNotification, object: nil)
            center.addObserver(self, selector: #selector(menuDidClose(_:)),
                               name: NSMenu.didEndTrackingNotification, object: nil)
        }
    }

    @objc private func menuWillTrack(_ note: Notification) {
        guard accent.rgb != PostmereAccent.defaultRGB,
              let menu = note.object as? NSMenu, menu.supermenu == nil,
              let window, let event = NSApp.currentEvent, event.window === window else { return }

        switch event.type {
        case .rightMouseDown,
             .leftMouseDown where event.modifierFlags.contains(.control):
            guard bounds.contains(convert(event.locationInWindow, from: nil)) else { return }
        case .keyDown:
            guard let table = window.firstResponder as? NSTableView,
                  bounds.contains(convert(NSPoint(x: table.bounds.midX, y: table.visibleRect.midY), from: table)),
                  event.keyCode == kVK_ContextualMenu || (event.keyCode == kVK_F10 && event.modifierFlags.contains(.shift)) else { return }
        default:
            return
        }
        stopTracking()
        trackingMenu = menu
        attach(to: menu)
    }

    @objc private func menuDidClose(_ note: Notification) {
        guard let menu = note.object as? NSMenu, menu === trackingMenu else { return }
        stopTracking()
    }

    private func attach(to menu: NSMenu) {
        highlights.append(MenuHighlight(menu: menu, accent: NSColor(accent.accent)))
        for item in menu.items {
            if let submenu = item.submenu { attach(to: submenu) }
        }
    }

    private func stopTracking() {
        for highlight in highlights { highlight.detach() }
        highlights.removeAll()
        trackingMenu = nil
    }
}

/// AppKit retains its original menu items, target/action, and accessibility. The
/// overlay recolors only the highlight; the text and symbols remain native.
private final class MenuHighlight: NSObject, NSMenuDelegate {
    private weak var menu: NSMenu?
    private weak var originalDelegate: NSMenuDelegate?
    private let overlay = HighlightOverlay()
    private let accent: NSColor

    init(menu: NSMenu, accent: NSColor) {
        self.menu = menu
        originalDelegate = menu.delegate
        self.accent = accent
        super.init()
        menu.delegate = self
    }

    func detach() {
        overlay.removeFromSuperview()
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
        overlay.removeFromSuperview()
        guard let item, item.isEnabled, item.view == nil else { return }
        let frame = item.accessibilityFrame()
        guard !frame.isEmpty,
              let window = NSApp.windows.first(where: {
                  $0.isVisible && $0.level == .popUpMenu && $0.frame.contains(frame)
                      && abs($0.frame.width - frame.width) <= 1
              }), let content = window.contentView else { return }
        let row = content.convert(window.convertFromScreen(frame), from: nil)
        overlay.frame = row.insetBy(dx: 5, dy: 0)
        content.addSubview(overlay, positioned: .above, relativeTo: nil)
        overlay.wantsLayer = true
        overlay.layer?.cornerRadius = 6
        overlay.layer?.compositingFilter = CIFilter(name: "CIColorBlendMode")
        window.effectiveAppearance.performAsCurrentDrawingAppearance {
            overlay.layer?.backgroundColor = accent.cgColor
        }
    }
}

private final class HighlightOverlay: NSView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func isAccessibilityElement() -> Bool { false }
}
