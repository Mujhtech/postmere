import CoreSpotlight
import SwiftUI

@main
struct postmereApp: App {
    @NSApplicationDelegateAdaptor(PostmereAppDelegate.self) private var appDelegate
    @State private var runtime: MailRuntime
    @AppStorage(MenuBarInboxHost.visibilityPreference) private var showsMenuBarInbox = true

    init() {
        let runtime = MailRuntime()
        _runtime = State(initialValue: runtime)
        appDelegate.runtime = runtime
        _ = AppUpdater.shared
    }

    private var store: MailStore { runtime.store }

    var body: some Scene {
        Window("Postmere", id: "mail") {
            WorkspaceSceneGate(runtime: runtime, offersInboxSetup: true) {
                ContentView(store: store)
            }
                .onOpenURL { url in
                    guard url.scheme?.lowercased() == "mailto" else { return }
                    if !runtime.mailLinks.receive(url, verifiedScope: runtime.backend.canAccessWorkspace ? runtime.backend.scope : nil) {
                        store.operationError = "Postmere couldn’t read this email link."
                    }
                }
                .onContinueUserActivity(MailContinuity.messageActivityType) { runtime.continueActivity($0) }
                .onContinueUserActivity(CSSearchableItemActionType) { runtime.continueActivity($0) }
                .handlesExternalEvents(preferring: ["mailto:"], allowing: ["mailto:"])
                .postmereStyle()
        }
        .handlesExternalEvents(matching: ["mailto:"])
        .defaultSize(width: 1280, height: 820)
        .windowResizability(.contentMinSize)
        .windowToolbarStyle(.unified)
        .commands { MailCommands(store: store, runtime: runtime) }

        Window("New Message", id: "compose") {
            WorkspaceSceneGate(runtime: runtime, isComposer: true) {
                ComposerView(store: store)
            }
                .postmereStyle()
        }
        .defaultSize(width: 840, height: 780)
        .windowResizability(.contentMinSize)
        .windowToolbarStyle(.unified)
        .defaultLaunchBehavior(.suppressed)
        .restorationBehavior(.disabled)

        Settings {
            WorkspaceSceneGate(runtime: runtime) {
                SettingsView(store: store, runtime: runtime)
            }
                .postmereStyle()
        }

        MenuBarExtra(isInserted: $showsMenuBarInbox) {
            MenuBarInboxHost(runtime: runtime)
                .postmereStyle()
        } label: {
            MenuBarInboxLabel(runtime: runtime)
        }
        .menuBarExtraStyle(.window)
    }
}

private struct WorkspaceSceneGate<Content: View>: View {
    let runtime: MailRuntime
    var isComposer = false
    var offersInboxSetup = false
    @State private var finishingSetup = false
    @ViewBuilder var content: () -> Content
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.dismissWindow) private var dismissWindow

    var body: some View {
        Group {
            if runtime.store.isOpeningMailbox {
                ProgressView("Opening mailbox…")
                    .controlSize(.small)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .mailboxWindowSurface()
            } else if !(runtime.backend.canAccessWorkspace || runtime.backend.showsCachedWorkspace) || finishingSetup {
                WorkspaceOnboardingView(session: runtime.backend, notifications: runtime.notifications,
                                        defaultMail: runtime.defaultMail,
                                        offersInboxSetup: offersInboxSetup,
                                        onHoldSetup: { finishingSetup = $0 && offersInboxSetup },
                                        onOpenMailbox: { finishingSetup = false },
                                        onSync: { await runtime.syncBackend() })
            } else {
                if isComposer && !runtime.canResumeComposer {
                    ContentUnavailableView {
                        PostmereLabel.emptyState("Draft kept in another workspace", symbol: "doc", size: 38)
                    } description: {
                        Text("Your unfinished draft is still held on this Mac. Sign in to its original workspace to resume and save it.")
                    }
                        .frame(minWidth: 540, minHeight: 520)
                        .mailboxWindowSurface()
                } else {
                    // Verifying the cached workspace keeps the same identity, so
                    // the window does not rebuild when the session is confirmed.
                    content().id(runtime.backend.scope ?? runtime.backend.provisionalScope)
                }
            }
        }
        .environment(runtime)
        .task { runtime.start() }
        .onChange(of: runtime.backend.canAccessWorkspace) {
            runtime.reconcileWorkspaceAccess()
            if !runtime.backend.canAccessWorkspace { finishingSetup = false }
            if isComposer, !runtime.backend.canAccessWorkspace, !runtime.store.isComposing {
                dismissWindow(id: "compose")
            }
        }
        .onChange(of: scenePhase) {
            if scenePhase == .active {
                NSApplication.shared.registerForRemoteNotifications()
                Task {
                    await runtime.backend.expireSessionIfNeeded()
                    await runtime.notifications.refreshAuthorization()
                    await runtime.synchronizePush(forceStatus: true)
                }
            } else {
                runtime.store.schedulePersistence()
            }
        }
    }
}
