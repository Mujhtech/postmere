import Foundation
import Observation
import Sparkle

/// Sparkle's standard updater: checks the appcast once a day, shows its own
/// update window, and installs through its sandbox installer service.
@MainActor @Observable
final class AppUpdater {
    static let shared = AppUpdater()

    @ObservationIgnored private let controller: SPUStandardUpdaterController
    @ObservationIgnored private var observations: [NSKeyValueObservation] = []
    private(set) var canCheckForUpdates = false
    private(set) var lastCheck: Date?

    private init() {
        controller = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: nil, userDriverDelegate: nil)
        let updater = controller.updater
        canCheckForUpdates = updater.canCheckForUpdates
        lastCheck = updater.lastUpdateCheckDate
        observations = [
            updater.observe(\.canCheckForUpdates, options: [.new]) { [weak self] updater, _ in
                let value = updater.canCheckForUpdates
                Task { @MainActor in self?.canCheckForUpdates = value }
            },
            updater.observe(\.lastUpdateCheckDate, options: [.new]) { [weak self] updater, _ in
                let value = updater.lastUpdateCheckDate
                Task { @MainActor in self?.lastCheck = value }
            },
        ]
    }

    var checksAutomatically: Bool {
        get { controller.updater.automaticallyChecksForUpdates }
        set { controller.updater.automaticallyChecksForUpdates = newValue }
    }

    var downloadsAutomatically: Bool {
        get { controller.updater.automaticallyDownloadsUpdates }
        set { controller.updater.automaticallyDownloadsUpdates = newValue }
    }

    func checkForUpdates() {
        controller.checkForUpdates(nil)
    }
}
