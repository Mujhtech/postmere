import AppKit
import WebKit

/// Draw only the thumb. AppKit retains the full hit area, dragging and overlay fade.
final class PostmereScroller: NSScroller {
    override class var isCompatibleWithOverlayScrollers: Bool { true }

    override func drawKnobSlot(in slotRect: NSRect, highlight flag: Bool) {}

    override func drawKnob() {
        let knob = rect(for: .knob)
        guard !knob.isEmpty else { return }
        let vertical = bounds.height > bounds.width
        let width = min(4, vertical ? knob.width : knob.height)
        let thumb = vertical
            ? NSRect(x: knob.midX - width / 2, y: knob.minY, width: width, height: knob.height)
            : NSRect(x: knob.minX, y: knob.midY - width / 2, width: knob.width, height: width)
        NSColor.secondaryLabelColor.setFill()
        NSBezierPath(roundedRect: thumb, xRadius: width / 2, yRadius: width / 2).fill()
    }
}

@MainActor
final class PostmereScrollbars: NSObject {
    private var installing = false
    private let pending = NSHashTable<NSScrollView>.weakObjects()

    func start() {
        let center = NotificationCenter.default
        center.addObserver(self, selector: #selector(windowOpened), name: NSWindow.didBecomeKeyNotification, object: nil)
        center.addObserver(self, selector: #selector(frameChanged), name: NSView.frameDidChangeNotification, object: nil)
        center.addObserver(self, selector: #selector(scrollViewChanged), name: NSScrollView.willStartLiveScrollNotification, object: nil)
        for window in NSApp.windows { scheduleConfiguration(of: window) }
    }

    @objc private func windowOpened(_ notification: Notification) {
        if let window = notification.object as? NSWindow { scheduleConfiguration(of: window) }
    }

    @objc private func scrollViewChanged(_ notification: Notification) {
        if let scroll = notification.object as? NSScrollView { scheduleConfiguration(of: scroll) }
    }

    @objc private func frameChanged(_ notification: Notification) {
        let view = notification.object as? NSView
        if let scroll = view as? NSScrollView ?? (view as? NSClipView)?.enclosingScrollView {
            scheduleConfiguration(of: scroll)
        }
    }

    private func scheduleConfiguration(of scroll: NSScrollView) {
        guard !pending.contains(scroll) else { return }
        // Replacing scrollers tiles the scroll view. Frame, key-window and
        // live-scroll notifications may arrive during an active layout pass.
        pending.add(scroll)
        DispatchQueue.main.async { [weak self, weak scroll] in
            guard let self, let scroll else { return }
            pending.remove(scroll)
            if let window = scroll.window, !(window is NSSavePanel) { configure(scroll) }
        }
    }

    private func scheduleConfiguration(of window: NSWindow) {
        guard !(window is NSSavePanel) else { return }
        DispatchQueue.main.async { [weak self, weak window] in
            guard let self, let root = window?.contentView else { return }
            @MainActor func visit(_ view: NSView) {
                if let scroll = view as? NSScrollView { self.configure(scroll) }
                if view is NSTableView || view is WKWebView { return }
                for child in view.subviews { visit(child) }
            }
            visit(root)
        }
    }

    private func configure(_ scroll: NSScrollView) {
        guard !installing else { return }
        // WebKit owns scrolling inside the message body and its layer updates.
        var ancestor = scroll.superview
        while let view = ancestor {
            if view is WKWebView { return }
            ancestor = view.superview
        }
        installing = true
        defer { installing = false }
        var replaced = false
        if scroll.hasVerticalScroller, let old = scroll.verticalScroller, !(old is PostmereScroller) {
            scroll.verticalScroller = replacement(for: old)
            replaced = true
        }
        if scroll.hasHorizontalScroller, let old = scroll.horizontalScroller, !(old is PostmereScroller) {
            scroll.horizontalScroller = replacement(for: old)
            replaced = true
        }
        if scroll.scrollerStyle != .overlay { scroll.scrollerStyle = .overlay }
        if replaced { scroll.reflectScrolledClipView(scroll.contentView) }
    }

    private func replacement(for old: NSScroller) -> NSScroller {
        let scroller = PostmereScroller(frame: old.frame)
        scroller.knobProportion = old.knobProportion
        scroller.doubleValue = old.doubleValue
        scroller.controlSize = old.controlSize
        return scroller
    }
}
