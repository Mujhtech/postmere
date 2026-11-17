import SwiftUI

@main
struct postmereApp: App {
    @AppStorage("appearance") private var appearance: MailAppearance = .system
    @State private var runtime = MailRuntime()
    @Environment(\.scenePhase) private var scenePhase

    private var store: MailStore { runtime.store }

    var body: some Scene {
        Window("Postmere", id: "mail") {
            ContentView(store: store)
                .environment(runtime)
                .task { runtime.start() }
                .onChange(of: scenePhase) { if scenePhase != .active { store.flushPersistence() } }
                .onReceive(NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)) { _ in store.flushPersistence() }
                .preferredColorScheme(appearance.colorScheme)
                .scrollIndicators(.never)
                .postmereStyle()
        }
        .defaultSize(width: 1280, height: 820)
        .windowToolbarStyle(.unified)
        .commands { MailCommands(store: store, runtime: runtime) }

        Window("New Message", id: "compose") {
            ComposerView(store: store)
                .environment(runtime)
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
            SettingsView(store: store, runtime: runtime)
                .preferredColorScheme(appearance.colorScheme)
                .scrollIndicators(.never)
                .postmereStyle()
        }
    }
}
