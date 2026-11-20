import AppKit
import CoreImage.CIFilterBuiltins
import SwiftUI

/// The Settings toolbar draws its own label and icon outside SwiftUI's tint environment.
struct SettingsTabForeground: NSViewRepresentable {
    let palette: PostmereAccent
    let selection: String

    func makeNSView(context: Context) -> Attachment { Attachment() }

    func updateNSView(_ view: Attachment, context: Context) {
        view.palette = palette
        view.scheduleUpdate()
    }

    final class Attachment: NSView {
        var palette = PostmereAccent(rgb: PostmereAccent.defaultRGB)
        private weak var itemView: NSView?
        private var tintFilter: CIFilter?
        private var appliedItem: NSToolbarItem.Identifier?
        private var appliedRGB: Int?
        private var appliedAppearance: NSAppearance.Name?
        private var pending = false

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            NotificationCenter.default.removeObserver(self)
            clearTint()
            guard let window else { return }
            for name in [NSWindow.didUpdateNotification, NSWindow.didBecomeKeyNotification, NSWindow.didResignKeyNotification] {
                NotificationCenter.default.addObserver(self, selector: #selector(scheduleUpdate), name: name, object: window)
            }
            scheduleUpdate()
        }

        override func viewDidChangeEffectiveAppearance() {
            super.viewDidChangeEffectiveAppearance()
            scheduleUpdate()
        }

        @objc func scheduleUpdate() {
            guard !pending else { return }
            pending = true
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                pending = false
                updateTint()
            }
        }

        private func updateTint() {
            guard let window, window.isKeyWindow, let toolbar = window.toolbar,
                  let selectedID = toolbar.selectedItemIdentifier else {
                clearTint()
                return
            }
            let appearance = window.effectiveAppearance
            if appliedItem == selectedID, appliedRGB == palette.rgb,
               appliedAppearance == appearance.name, let itemView, itemView.window === window,
               let tintFilter, itemView.contentFilters.contains(where: { ($0 as AnyObject) === tintFilter }) { return }

            clearTint()
            guard let item = toolbar.items.first(where: { $0.itemIdentifier == selectedID }),
                  let toolbarElement = window.accessibilityChildren()?.compactMap({ $0 as? NSAccessibilityProtocol })
                    .first(where: { $0.accessibilityRole() == .toolbar }),
                  let foreground = toolbarElement.accessibilityChildren()?.compactMap({ $0 as? NSView })
                    .first(where: { $0.accessibilityRole() == .button && $0.accessibilityLabel() == item.label }),
                  let space = CGColorSpace(name: CGColorSpace.extendedLinearSRGB).flatMap(NSColorSpace.init(cgColorSpace:))
            else { return }

            appearance.performAsCurrentDrawingAppearance {
                guard let color = NSColor(palette.accentInk).usingColorSpace(space) else { return }
                // Preserve the native foreground's alpha mask. Its glass platter is a separate view.
                let tint = CIFilter.colorMatrix()
                let zero = CIVector(x: 0, y: 0, z: 0, w: 0)
                tint.rVector = zero
                tint.gVector = zero
                tint.bVector = zero
                tint.biasVector = CIVector(x: color.redComponent, y: color.greenComponent, z: color.blueComponent, w: 0)
                if foreground.layer == nil { foreground.wantsLayer = true }
                foreground.contentFilters.append(tint)
                itemView = foreground
                tintFilter = tint
                appliedItem = selectedID
                appliedRGB = palette.rgb
                appliedAppearance = appearance.name
            }
        }

        private func clearTint() {
            if let itemView, let tintFilter {
                itemView.contentFilters.removeAll { ($0 as AnyObject) === tintFilter }
            }
            itemView = nil
            tintFilter = nil
            appliedItem = nil
        }
    }
}
