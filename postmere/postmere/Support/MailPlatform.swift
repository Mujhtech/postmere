import SwiftUI
#if os(macOS)
import AppKit
#else
import UIKit
import UserNotifications
#endif

/// The few operating-system services the shared mail core needs.
///
/// Models, stores and services call these instead of AppKit or UIKit, so the
/// iOS companion can compile the same core. Interface code stays per platform.
@MainActor
enum MailPlatform {
    static var deviceName: String {
        #if os(macOS)
        "Mac"
        #else
        UIDevice.current.userInterfaceIdiom == .pad ? "iPad" : "iPhone"
        #endif
    }

    @discardableResult
    static func open(_ url: URL) -> Bool {
        #if os(macOS)
        return NSWorkspace.shared.open(url)
        #else
        guard ["http", "https", "mailto"].contains(url.scheme?.lowercased() ?? "") || url.scheme == "app-settings" else { return false }
        UIApplication.shared.open(url)
        return true
        #endif
    }

    static func copy(_ text: String) {
        #if os(macOS)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        #else
        UIPasteboard.general.string = text
        #endif
    }

    /// The unread badge on the Dock tile or the Home Screen icon.
    static func setBadge(_ count: Int?) {
        #if os(macOS)
        let label = count?.formatted()
        if let tile = NSApp?.dockTile, tile.badgeLabel != label { tile.badgeLabel = label }
        #else
        UNUserNotificationCenter.current().setBadgeCount(count ?? 0)
        #endif
    }

    static func setRegisteredForPush(_ registered: Bool) {
        #if os(macOS)
        if registered { NSApp?.registerForRemoteNotifications() } else { NSApp?.unregisterForRemoteNotifications() }
        #else
        if registered { UIApplication.shared.registerForRemoteNotifications() }
        else { UIApplication.shared.unregisterForRemoteNotifications() }
        #endif
    }

    /// Brings the app forward after a notification is opened. iOS already does.
    static func activate() {
        #if os(macOS)
        NSApp.activate(ignoringOtherApps: true)
        #endif
    }

    /// Closes native file and formatting panels that no SwiftUI sheet owns.
    static func dismissNativePanels() {
        #if os(macOS)
        for panel in (NSApp?.windows ?? []).compactMap({ $0 as? NSPanel }) {
            if let filePanel = panel as? NSSavePanel { filePanel.cancel(nil) } else { panel.orderOut(nil) }
        }
        #endif
    }

    static var didBecomeActive: Notification.Name {
        #if os(macOS)
        NSApplication.didBecomeActiveNotification
        #else
        UIApplication.didBecomeActiveNotification
        #endif
    }

    /// A color that follows the light or dark appearance, from sRGB components.
    nonisolated static func adaptiveColor(light: SIMD3<Double>, dark: SIMD3<Double>) -> Color {
        #if os(macOS)
        Color(nsColor: NSColor(name: nil) { appearance in
            let c = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
            return NSColor(srgbRed: c.x, green: c.y, blue: c.z, alpha: 1)
        })
        #else
        Color(uiColor: UIColor { traits in
            let c = traits.userInterfaceStyle == .dark ? dark : light
            return UIColor(red: c.x, green: c.y, blue: c.z, alpha: 1)
        })
        #endif
    }

    /// Renders SVG data to a bitmap at the proposed size, or nil where the
    /// system has no SVG decoder for arbitrary data.
    nonisolated static func rasterizeSVG(_ data: Data, size: CGSize) -> CGImage? {
        #if os(macOS)
        guard let image = NSImage(data: data) else { return nil }
        var bounds = CGRect(origin: .zero, size: size)
        return image.cgImage(forProposedRect: &bounds, context: nil, hints: nil)
        #else
        return nil
        #endif
    }
}
