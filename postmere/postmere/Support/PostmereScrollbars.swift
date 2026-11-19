import AppKit

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
        center.addObserver(self, selector: #selector(windowOpened), name: NSWindow.didUpdateNotification, object: nil)
        center.addObserver(self, selector: #selector(frameChanged), name: NSView.frameDidChangeNotification, object: nil)
        center.addObserver(self, selector: #selector(scrollViewChanged), name: NSScrollView.willStartLiveScrollNotification, object: nil)
        for window in NSApp.windows { configure(window) }
    }

    @objc private func windowOpened(_ notification: Notification) {
        if let window = notification.object as? NSWindow { configure(window) }
    }

    @objc private func scrollViewChanged(_ notification: Notification) {
        guard let scroll = notification.object as? NSScrollView, let window = scroll.window,
              !(window is NSSavePanel) else { return }
        configure(scroll)
    }

    @objc private func frameChanged(_ notification: Notification) {
        guard let scroll = notification.object as? NSScrollView, !pending.contains(scroll) else { return }
        // SwiftUI installs the platform scrollers after assigning the new frame.
        pending.add(scroll)
        DispatchQueue.main.async { [weak self, weak scroll] in
            guard let self, let scroll else { return }
            pending.remove(scroll)
            if let window = scroll.window, !(window is NSSavePanel) { configure(scroll) }
        }
    }

    private func configure(_ window: NSWindow) {
        guard !(window is NSSavePanel), let root = window.contentView else { return }
        func visit(_ view: NSView) {
            if let scroll = view as? NSScrollView { configure(scroll) }
            // A table's reusable rows don't own scrollers. Skip their view trees
            // when AppKit reports that the window has finished a layout update.
            if view is NSTableView { return }
            for child in view.subviews { visit(child) }
        }
        visit(root)
    }

    private func configure(_ scroll: NSScrollView) {
        guard !installing else { return }
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
