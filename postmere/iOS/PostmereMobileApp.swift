import SwiftUI
import UIKit

@main
struct PostmereMobileApp: App {
    @UIApplicationDelegateAdaptor(MobileAppDelegate.self) private var appDelegate
    @AppStorage(MailAppearance.preferenceKey) private var appearance = MailAppearance.system
    @Environment(\.scenePhase) private var scenePhase

    private var runtime: MailRuntime { appDelegate.runtime }

    var body: some Scene {
        WindowGroup {
            MobileRoot(runtime: runtime)
                .environment(runtime)
                .postmereStyle()
                // Set on the window, like the Mac does on NSApp: sheets already open
                // follow at once, and System resumes live changes.
                .onChange(of: appearance, initial: true) { MailAppearance.applyToWindows(appearance) }
                .onAppear { MailAppearance.applyToWindows(appearance) }
                .onOpenURL { url in
                    if let route = PostmereLink.route(for: url) {
                        MobileRouter.shared.pending = route
                        return
                    }
                    guard url.scheme?.lowercased() == "mailto" else { return }
                    let scope = runtime.backend.canAccessWorkspace ? runtime.backend.scope : nil
                    if !runtime.mailLinks.receive(url, verifiedScope: scope) {
                        runtime.store.operationError = "Postmere couldn’t read this email link."
                    }
                }
        }
        .onChange(of: scenePhase) {
            switch scenePhase {
            case .active:
                MailAppearance.applyToWindows(appearance)
                Task {
                    await runtime.backend.expireSessionIfNeeded()
                    await runtime.notifications.refreshAuthorization()
                    await runtime.synchronizePush(forceStatus: true)
                    MobileAssistantActivities.refresh(runtime: runtime)
                    await runtime.sync()
                }
            case .background:
                MobileWidgetSync.publish(runtime: runtime)
                appDelegate.saveBeforeSuspension()
            default:
                break
            }
        }
    }
}

/// Owns the runtime so push callbacks, which can arrive before any scene, always reach it.
final class MobileAppDelegate: NSObject, UIApplicationDelegate {
    let runtime = MailRuntime()
    private var saveTask: UIBackgroundTaskIdentifier = .invalid

    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions options: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        runtime.start()
        MobileLiveActivities.start(runtime: runtime)
        MobileAssistantActivities.start(runtime: runtime)
        // Device registration is separate from permission to show alerts.
        application.registerForRemoteNotifications()
        return true
    }

    func application(_ application: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        runtime.registeredForPush(token: deviceToken)
    }

    func application(_ application: UIApplication, didFailToRegisterForRemoteNotificationsWithError error: Error) {
        // Never log tokens or raw registration errors; simulators always fail here.
        runtime.push.registrationFailed()
    }

    nonisolated func application(_ application: UIApplication, didReceiveRemoteNotification userInfo: [AnyHashable: Any]) async
        -> UIBackgroundFetchResult {
        guard let info = userInfo as? [String: Any], let destination = MailPushDestination(userInfo: info) else { return .noData }
        return await runtime.syncForPush(destination) ? .newData : .noData
    }

    /// Finishes the mailbox write after the app leaves the screen.
    func saveBeforeSuspension() {
        guard saveTask == .invalid else { return }
        saveTask = UIApplication.shared.beginBackgroundTask(withName: "Save mailbox") { [weak self] in self?.endSave() }
        runtime.store.finishPersistenceForQuit { [weak self] in self?.endSave() }
    }

    private func endSave() {
        guard saveTask != .invalid else { return }
        UIApplication.shared.endBackgroundTask(saveTask)
        saveTask = .invalid
    }
}

/// Signed out, restoring, or the mailbox.
private struct MobileRoot: View {
    let runtime: MailRuntime

    var body: some View {
        Group {
            if runtime.backend.isRestoring || runtime.store.isOpeningMailbox {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if runtime.backend.canAccessWorkspace || runtime.backend.showsCachedWorkspace {
                MobileMailbox(runtime: runtime)
                    .id(runtime.backend.scope ?? runtime.backend.provisionalScope)
            } else {
                MobileSignIn(session: runtime.backend)
            }
        }
        .background(MobileCanvas())
        .onChange(of: runtime.backend.canAccessWorkspace) {
            runtime.reconcileWorkspaceAccess()
            if runtime.backend.canAccessWorkspace { Task { await runtime.sync() } }
        }
    }
}

extension MailAppearance {
    var interfaceStyle: UIUserInterfaceStyle {
        switch self {
        case .system: .unspecified
        case .light: .light
        case .dark: .dark
        }
    }

    /// Every window, and every sheet presented in it, takes the chosen appearance.
    @MainActor static func applyToWindows(_ mode: MailAppearance) {
        for scene in UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }) {
            for window in scene.windows where window.overrideUserInterfaceStyle != mode.interfaceStyle {
                window.overrideUserInterfaceStyle = mode.interfaceStyle
            }
        }
    }
}
