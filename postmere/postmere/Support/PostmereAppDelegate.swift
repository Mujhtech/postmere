import AppKit

@MainActor
final class PostmereAppDelegate: NSObject, NSApplicationDelegate {
    weak var runtime: MailRuntime?
    private let scrollbars = PostmereScrollbars()
    private var appearanceObservation: AnyCancellable?

    func applicationWillFinishLaunching(_ notification: Notification) {
        appearanceObservation = MailAppearance.observe(in: .standard, application: .shared)
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        scrollbars.start()
        // Device registration is separate from authorization to show alerts.
        // NotificationService installs UNUserNotificationCenter's delegate in
        // App.init, before either launch or notification callbacks can arrive.
        NSApplication.shared.registerForRemoteNotifications()
    }

    func application(_ application: NSApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        runtime?.registeredForPush(token: deviceToken)
    }

    func application(_ application: NSApplication, didFailToRegisterForRemoteNotificationsWithError error: Error) {
        // Never log tokens or raw registration errors. Unsigned builds do not
        // provide evidence of APNs delivery and are expected to fail here.
        runtime?.push.registrationFailed()
    }

    func application(_ application: NSApplication, didReceiveRemoteNotification userInfo: [String: Any]) {
        guard let destination = MailPushDestination(userInfo: userInfo) else { return }
        runtime?.receivedPush(destination)
    }
}
