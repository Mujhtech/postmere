import ActivityKit
import Foundation
import SwiftUI

/// Keeps the server able to show what connected assistants are doing on this
/// iPhone: it reports the push-to-start token and each activity's own token,
/// follows activities the server started, and starts one itself when it sees an
/// assistant working while Postmere is open.
@MainActor
enum MobileAssistantActivities {
    typealias AssistantActivity = Activity<AssistantActivityAttributes>
    static let preferenceKey = "assistantLiveActivities"

    private static var isRunning = false
    private static var startToken: String?
    private static var activityTokens: [String: String] = [:]
    private static var followed: Set<String> = []
    private static var uploadedStartToken: (generation: UUID, token: String)?
    private static var uploadedActivityTokens: [String: (generation: UUID, token: String)] = [:]

    static var isEnabled: Bool {
        UserDefaults.standard.object(forKey: preferenceKey) as? Bool ?? true
    }

    static func start(runtime: MailRuntime) {
        guard !isRunning else { return }
        isRunning = true
        Task {
            for await data in AssistantActivity.pushToStartTokenUpdates {
                startToken = hex(data)
                await upload(runtime: runtime)
            }
        }
        Task {
            for await activity in AssistantActivity.activityUpdates { follow(activity, runtime: runtime) }
        }
        for activity in AssistantActivity.activities { follow(activity, runtime: runtime) }
        observe(runtime)
    }

    /// Re-sends tokens when the workspace session changes, and starts an activity
    /// for an assistant that began working while the app is open.
    private static func observe(_ runtime: MailRuntime) {
        withObservationTracking {
            _ = runtime.backend.realtimeGeneration
            _ = runtime.assistants.connections
        } onChange: {
            Task { @MainActor in
                await upload(runtime: runtime)
                startForWorkingAssistants(runtime: runtime)
                observe(runtime)
            }
        }
    }

    /// Call when the setting changes or the app returns to the foreground.
    static func refresh(runtime: MailRuntime) {
        Task {
            if !isEnabled {
                for activity in AssistantActivity.activities { await activity.end(nil, dismissalPolicy: .immediate) }
            }
            await upload(runtime: runtime, force: true)
            startForWorkingAssistants(runtime: runtime)
        }
    }

    private static func follow(_ activity: AssistantActivity, runtime: MailRuntime) {
        let grant = activity.attributes.grantID
        guard followed.insert(activity.id).inserted else { return }
        Task {
            for await data in activity.pushTokenUpdates {
                activityTokens[grant] = hex(data)
                await upload(runtime: runtime)
            }
        }
        Task {
            for await state in activity.activityStateUpdates where state == .dismissed || state == .ended {
                activityTokens[grant] = nil
                uploadedActivityTokens[grant] = nil
                if state == .dismissed { await send("DELETE", path(runtime, "assistants/\(grant)"), token: nil, runtime: runtime) }
                followed.remove(activity.id)
            }
        }
    }

    private static func startForWorkingAssistants(runtime: MailRuntime) {
        guard isEnabled, ActivityAuthorizationInfo().areActivitiesEnabled,
              UIApplication.shared.applicationState == .active else { return }
        let showing = Set(AssistantActivity.activities.filter { $0.activityState == .active }.map(\.attributes.grantID))
        for connection in runtime.assistants.working where !showing.contains(connection.id.uuidString.lowercased()) {
            let tools = connection.recent.map(\.tool)
            let state = AssistantActivityAttributes.ContentState(
                tool: tools.first ?? "working", recent: Array(tools.prefix(3)), calls: max(1, tools.count),
                startedAt: (connection.recent.last?.at ?? connection.lastUsedAt ?? .now).timeIntervalSince1970,
                lastAt: (connection.lastUsedAt ?? .now).timeIntervalSince1970, working: true)
            let attributes = AssistantActivityAttributes(grantID: connection.id.uuidString.lowercased(), clientName: connection.clientName)
            let content = ActivityContent(state: state, staleDate: (connection.lastUsedAt ?? .now).addingTimeInterval(120))
            if let activity = try? AssistantActivity.request(attributes: attributes, content: content, pushType: .token) {
                follow(activity, runtime: runtime)
            }
        }
    }

    /// Sends what the server hasn't got for this session. A 404 means the device
    /// hasn't registered for notifications yet; the next change tries again.
    private static func upload(runtime: MailRuntime, force: Bool = false) async {
        guard let generation = runtime.backend.realtimeGeneration else {
            uploadedStartToken = nil
            uploadedActivityTokens = [:]
            return
        }
        if isEnabled, let token = startToken,
           force || uploadedStartToken?.generation != generation || uploadedStartToken?.token != token {
            if await send("PUT", path(runtime, "start-token"), token: token, runtime: runtime) {
                uploadedStartToken = (generation, token)
            }
        } else if !isEnabled, uploadedStartToken != nil || force {
            if await send("DELETE", path(runtime, "start-token"), token: nil, runtime: runtime) { uploadedStartToken = nil }
        }
        for (grant, token) in activityTokens
        where force || uploadedActivityTokens[grant]?.generation != generation || uploadedActivityTokens[grant]?.token != token {
            if await send("PUT", path(runtime, "assistants/\(grant)"), token: token, runtime: runtime) {
                uploadedActivityTokens[grant] = (generation, token)
            }
        }
    }

    private nonisolated struct TokenBody: Encodable, Sendable { let token: String }

    @discardableResult
    private static func send(_ method: String, _ path: String?, token: String?, runtime: MailRuntime) async -> Bool {
        guard let path, runtime.backend.canAccessWorkspace else { return false }
        do {
            if let token {
                let _: BackendEmpty = try await runtime.backend.request(method, path, body: TokenBody(token: token))
            } else {
                let _: BackendEmpty = try await runtime.backend.request(method, path)
            }
            return true
        } catch {
            return false
        }
    }

    private static func path(_ runtime: MailRuntime, _ suffix: String) -> String? {
        guard let installation = runtime.backend.pushInstallationID else { return nil }
        return "/v1/push/devices/\(installation.uuidString)/live-activities/\(suffix)"
    }

    private static func hex(_ data: Data) -> String {
        data.map { String(format: "%02x", $0) }.joined()
    }
}
