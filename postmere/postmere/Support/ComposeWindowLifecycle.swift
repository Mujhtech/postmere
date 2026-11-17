import AppKit
import SwiftUI

/// Intercepts native close requests while leaving SwiftUI's window delegate in the forwarding chain.
struct ComposeWindowLifecycle: NSViewRepresentable {
    let store: MailStore
    let requestClose: () -> Void

    init(store: MailStore, requestClose: @escaping () -> Void) {
        self.store = store
        self.requestClose = requestClose
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(store: store, requestClose: requestClose)
    }

    func makeNSView(context: Context) -> WindowAttachmentView {
        let view = WindowAttachmentView()
        view.coordinator = context.coordinator
        return view
    }

    func updateNSView(_ view: WindowAttachmentView, context: Context) {
        context.coordinator.store = store
        context.coordinator.requestClose = requestClose
        context.coordinator.attach(to: view.window)
    }

    static func dismantleNSView(_ view: WindowAttachmentView, coordinator: Coordinator) {
        view.coordinator = nil
        coordinator.detach()
    }

    final class WindowAttachmentView: NSView {
        weak var coordinator: Coordinator?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            coordinator?.attach(to: window)
        }
    }

    @MainActor
    final class Coordinator: NSObject, NSWindowDelegate {
        var store: MailStore
        var requestClose: () -> Void
        private weak var attachedWindow: NSWindow?
        private weak var originalDelegate: (any NSWindowDelegate)?

        init(store: MailStore, requestClose: @escaping () -> Void) {
            self.store = store
            self.requestClose = requestClose
        }

        func attach(to window: NSWindow?) {
            if attachedWindow === window, window?.delegate === self { return }
            detach()
            guard let window else { return }
            attachedWindow = window
            originalDelegate = window.delegate
            window.delegate = self
        }

        func detach() {
            if attachedWindow?.delegate === self {
                attachedWindow?.delegate = originalDelegate
            }
            attachedWindow = nil
            originalDelegate = nil
        }

        func windowShouldClose(_ sender: NSWindow) -> Bool {
            if store.isComposing {
                requestClose()
                return false
            }
            return originalDelegate?.windowShouldClose?(sender) ?? true
        }

        func windowWillClose(_ notification: Notification) {
            let previousDelegate = originalDelegate
            if store.isComposing { store.discardDraftChanges() }
            previousDelegate?.windowWillClose?(notification)
        }

        // AppKit asks and calls its window delegate on the main thread.
        nonisolated override func responds(to selector: Selector!) -> Bool {
            if super.responds(to: selector) { return true }
            return MainActor.assumeIsolated {
                originalDelegate?.responds(to: selector) ?? false
            }
        }

        nonisolated override func forwardingTarget(for selector: Selector!) -> Any? {
            let target: AnyObject? = MainActor.assumeIsolated {
                guard let originalDelegate, originalDelegate.responds(to: selector) else { return nil }
                return originalDelegate
            }
            return target ?? super.forwardingTarget(for: selector)
        }
    }
}
