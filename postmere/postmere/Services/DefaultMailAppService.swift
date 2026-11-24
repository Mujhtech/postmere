#if os(macOS)
import AppKit
#else
import UIKit
#endif
import Observation

nonisolated enum DefaultMailAppStatus: Equatable, Sendable {
    case postmere
    case other(String?)
}

@MainActor @Observable
final class DefaultMailAppService {
    private(set) var status: DefaultMailAppStatus?
    private(set) var isRequesting = false
    private(set) var errorMessage: String?

    private let readStatus: @MainActor () async -> DefaultMailAppStatus
    private let requestChange: @MainActor () async throws -> Void
    @ObservationIgnored private var latestRead = UUID()

    init(readStatus: @escaping @MainActor () async -> DefaultMailAppStatus,
         requestChange: @escaping @MainActor () async throws -> Void) {
        self.readStatus = readStatus
        self.requestChange = requestChange
    }

    convenience init() {
        #if os(macOS)
        self.init(readStatus: { await Self.systemStatus() }, requestChange: {
            try await NSWorkspace.shared.setDefaultApplication(at: Bundle.main.bundleURL,
                                                               toOpenURLsWithScheme: "mailto")
        })
        #else
        // iOS doesn't report the default mail app; the choice lives in Settings.
        self.init(readStatus: { .other(nil) }, requestChange: {
            if let settings = URL(string: UIApplication.openDefaultApplicationsSettingsURLString) {
                await UIApplication.shared.open(settings)
            }
        })
        #endif
    }

    func refresh() async {
        let read = UUID()
        latestRead = read
        let result = await readStatus()
        guard read == latestRead else { return }
        if status != result { errorMessage = nil }
        status = result
    }

    func makeDefault() async {
        guard case .other = status, !isRequesting else { return }
        isRequesting = true
        defer { isRequesting = false }
        errorMessage = nil
        var issue: String?
        do {
            try await requestChange()
        } catch {
            let systemError = error as NSError
            let cancelled = error is CancellationError
                || (systemError.domain == NSCocoaErrorDomain && systemError.code == NSUserCancelledError)
                || (systemError.domain == NSOSStatusErrorDomain && systemError.code == -128 /* userCanceledErr */)
            if !cancelled { issue = systemError.localizedDescription }
        }
        // The system can keep the previous handler when the confirmation is dismissed.
        await refresh()
        if status != .postmere { errorMessage = issue }
    }

    #if os(macOS)
    @concurrent private static func systemStatus() async -> DefaultMailAppStatus {
        guard let link = URL(string: "mailto:"),
              let handler = NSWorkspace.shared.urlForApplication(toOpen: link) else { return .other(nil) }
        let bundle = Bundle(url: handler)
        if handler.standardizedFileURL == Bundle.main.bundleURL.standardizedFileURL
            || (Bundle.main.bundleIdentifier != nil && bundle?.bundleIdentifier == Bundle.main.bundleIdentifier) {
            return .postmere
        }
        let name = bundle?.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String
            ?? bundle?.object(forInfoDictionaryKey: "CFBundleName") as? String
            ?? handler.deletingPathExtension().lastPathComponent
        return .other(name)
    }
    #endif
}
