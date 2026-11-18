import SwiftUI

@main
struct postmereApp: App {
    @NSApplicationDelegateAdaptor(PostmereAppDelegate.self) private var appDelegate
    @AppStorage("appearance") private var appearance: MailAppearance = .system
    @State private var runtime: MailRuntime

    init() {
        let runtime = MailRuntime()
        _runtime = State(initialValue: runtime)
        appDelegate.runtime = runtime
    }

    private var store: MailStore { runtime.store }

    var body: some Scene {
        Window("Postmere", id: "mail") {
            WorkspaceSceneGate(runtime: runtime) {
                ContentView(store: store)
            }
                .preferredColorScheme(appearance.colorScheme)
                .scrollIndicators(.never)
                .postmereStyle()
        }
        .defaultSize(width: 1280, height: 820)
        .windowToolbarStyle(.unified)
        .commands { MailCommands(store: store, runtime: runtime) }

        Window("New Message", id: "compose") {
            WorkspaceSceneGate(runtime: runtime, isComposer: true) {
                ComposerView(store: store)
            }
                .preferredColorScheme(appearance.colorScheme)
                .scrollIndicators(.never)
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
                .preferredColorScheme(appearance.colorScheme)
                .scrollIndicators(.never)
                .postmereStyle()
        }
    }
}

private struct WorkspaceSceneGate<Content: View>: View {
    let runtime: MailRuntime
    var isComposer = false
    @ViewBuilder var content: () -> Content
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.dismissWindow) private var dismissWindow

    var body: some View {
        Group {
            if runtime.backend.canAccessWorkspace {
                if isComposer && !runtime.canResumeComposer {
                    ContentUnavailableView {
                        PostmereLabel.emptyState("Draft kept in another workspace", symbol: "doc", size: 38)
                    } description: {
                        Text("Your unfinished draft is still held on this Mac. Sign in to its original workspace to resume and save it.")
                    }
                        .frame(minWidth: 540, minHeight: 520)
                } else {
                    content().id(runtime.backend.scope)
                }
            } else {
                WorkspaceOnboardingView(session: runtime.backend)
            }
        }
        .environment(runtime)
        .task { runtime.start() }
        .onChange(of: runtime.backend.canAccessWorkspace) {
            runtime.reconcileWorkspaceAccess()
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
                runtime.store.flushPersistence()
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)) { _ in
            runtime.store.flushPersistence()
        }
    }
}
