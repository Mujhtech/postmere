import Foundation
import Observation

@MainActor
@Observable
final class MailPushService {
    let installationID: UUID
    let environment: MailPushEnvironment?
    private(set) var remoteAccountIDs: Set<String> = []
    private(set) var statusText: String
    private var synchronizationError: String?
    private var registrationError: String?
    var lastError: String? { synchronizationError ?? registrationError }
    private static let foregroundOnly = "This build delivers notifications while Postmere is open."
    private static let checkingStatus = "Checking background notification availability."
    private static let waitingForRegistration = "Waiting for this Mac to register for background notifications."
    @ObservationIgnored private var generation: UUID?
    @ObservationIgnored private var currentToken: String?
    @ObservationIgnored private var callbacks: [String] = []
    @ObservationIgnored private var lastPreferences: MailPushPreferences?
    @ObservationIgnored private var desiredPreferences: MailPushPreferences?
    @ObservationIgnored private var senderPolicyVersion: Int?
    @ObservationIgnored private var hasRemoteRegistration = false
    @ObservationIgnored private var stateChecked = false
    @ObservationIgnored private var lastStateCheck = Date.distantPast
    @ObservationIgnored private var synchronization: Task<Void, Never>?
    @ObservationIgnored private var synchronizationID: UUID?
    @ObservationIgnored private var nextAttempt = Date.distantPast
    @ObservationIgnored private var failures = 0
    @ObservationIgnored private var attemptedPreferences: MailPushPreferences?

    var hasResolvedDeliveryOwnership: Bool { environment == nil || stateChecked }
    func allowsLocalIncoming(for account: String) -> Bool {
        hasResolvedDeliveryOwnership && !remoteAccountIDs.contains(account)
    }

    init(preferences: UserDefaults = .standard, environment: MailPushEnvironment? = .signedEnvironment()) {
        if let saved = preferences.string(forKey: "postmerePushInstallation.v1").flatMap(UUID.init(uuidString:)) {
            installationID = saved
        } else {
            installationID = UUID()
            preferences.set(installationID.uuidString, forKey: "postmerePushInstallation.v1")
        }
        self.environment = environment
        statusText = environment == nil ? Self.foregroundOnly : Self.checkingStatus
    }

    func registered(token: Data) {
        guard environment != nil, !token.isEmpty else { return }
        let value = token.map { String(format: "%02x", $0) }.joined()
        currentToken = value
        // Every callback is queued, even if Apple returned the same token.
        // Tokens remain in memory and are never used as a persisted truth.
        callbacks.append(value)
        nextAttempt = .distantPast
        registrationError = nil
    }

    func registrationFailed() {
        guard environment != nil else { return }
        registrationError = "Apple couldn’t update this Mac’s background notification registration."
    }

    func reset(generation newGeneration: UUID?) {
        guard generation != newGeneration else { return }
        synchronization?.cancel()
        synchronization = nil
        synchronizationID = nil
        generation = newGeneration
        remoteAccountIDs = []
        stateChecked = false
        lastStateCheck = .distantPast
        lastPreferences = nil
        desiredPreferences = nil
        senderPolicyVersion = nil
        hasRemoteRegistration = false
        attemptedPreferences = nil
        nextAttempt = .distantPast
        failures = 0
        if newGeneration == nil { currentToken = nil; callbacks = [] }
        synchronizationError = nil
        if environment == nil { statusText = Self.foregroundOnly }
        else if newGeneration == nil {
            statusText = "Sign in to receive notifications while Postmere is closed."
            registrationError = nil
        } else { statusText = Self.checkingStatus }
    }

    func synchronize(session: BackendSession, preferences: MailPushPreferences, forceStatus: Bool = false) async {
        reset(generation: session.realtimeGeneration)
        guard let requestGeneration = generation, let environment else { return }
        desiredPreferences = preferences
        if let synchronization {
            await synchronization.value
            return
        }
        guard Date.now >= nextAttempt || attemptedPreferences != preferences || forceStatus else { return }
        guard !stateChecked || forceStatus || Date.now.timeIntervalSince(lastStateCheck) >= 60
                || !callbacks.isEmpty || lastPreferences != preferences.compatible(with: senderPolicyVersion) else { return }
        let operationID = UUID()
        synchronizationID = operationID
        attemptedPreferences = preferences
        let operation = Task { [weak self] in
            guard let self else { return }
            await self.performSynchronization(session: session, environment: environment,
                                              generation: requestGeneration, forceStatus: forceStatus)
        }
        synchronization = operation
        await operation.value
        if synchronizationID == operationID { synchronization = nil; synchronizationID = nil }
    }

    private func performSynchronization(session: BackendSession, environment: MailPushEnvironment, generation requestGeneration: UUID,
                                        forceStatus: Bool) async {
        let path = "/v1/push/devices/\(installationID.uuidString)"
        do {
            if !stateChecked || forceStatus || Date.now.timeIntervalSince(lastStateCheck) >= 60 {
                let state: MailPushDeviceState?
                do { state = try await session.request("GET", path) }
                catch BackendError.response(404, _) { state = nil }
                guard !Task.isCancelled, generation == requestGeneration else { return }
                if let state {
                    apply(state, environment: environment)
                } else {
                    remoteAccountIDs = []
                    hasRemoteRegistration = false
                    senderPolicyVersion = nil
                    lastPreferences = nil
                    statusText = Self.waitingForRegistration
                }
                stateChecked = true
                lastStateCheck = .now
            }
            while let desiredPreferences {
                guard !Task.isCancelled, generation == requestGeneration, session.realtimeGeneration == requestGeneration else { return }
                let preferences = desiredPreferences.compatible(with: senderPolicyVersion)
                let state: MailPushDeviceState
                if let token = callbacks.first {
                    let body = MailPushRegistration(token: token, environment: environment.rawValue, enabled: preferences.enabled, accounts: preferences.accounts)
                    state = try await session.request("PUT", path, body: body)
                    guard !Task.isCancelled, generation == requestGeneration else { return }
                    callbacks.removeFirst()
                } else if lastPreferences != preferences, senderPolicyVersion == 1, hasRemoteRegistration {
                    // Preference edits do not depend on another Apple token
                    // callback. The server updates only this session's device.
                    state = try await session.request("PATCH", path, body: preferences)
                } else if lastPreferences != preferences, let currentToken {
                    callbacks.append(currentToken)
                    continue
                } else { break }
                guard !Task.isCancelled, generation == requestGeneration else { return }
                lastPreferences = preferences
                apply(state, environment: environment)
            }
            synchronizationError = nil
            failures = 0
            nextAttempt = .distantPast
        } catch {
            guard !Task.isCancelled, generation == requestGeneration else { return }
            lastStateCheck = .now
            nextAttempt = Date.now.addingTimeInterval(min(60, pow(2, Double(min(failures, 6)))))
            failures = min(failures + 1, 6)
            synchronizationError = "Could not update remote notification settings. Your last confirmed server settings may still apply."
        }
    }

    private func apply(_ state: MailPushDeviceState, environment: MailPushEnvironment) {
        guard state.deviceId == installationID else {
            remoteAccountIDs = []
            hasRemoteRegistration = false
            statusText = "Could not confirm background notifications for this Mac."
            return
        }
        senderPolicyVersion = state.senderPolicyVersion
        hasRemoteRegistration = state.active ?? state.enabled
        let active = Set(state.accountIds)
        remoteAccountIDs = state.configured && state.enabled && state.environment == environment.rawValue
            ? Set((desiredPreferences?.accounts ?? []).filter { active.contains($0.accountId) }.map(\.filterCriteria)) : []
        if !state.configured { statusText = "Your workspace server has not enabled Apple push notifications." }
        else if let serverEnvironment = state.environment, serverEnvironment != environment.rawValue {
            statusText = "This build cannot receive background notifications from this workspace."
        }
        else if !hasRemoteRegistration { statusText = Self.waitingForRegistration }
        else if !state.enabled { statusText = "Background notifications are off for this Mac." }
        else if remoteAccountIDs.isEmpty { statusText = "Enable notifications for an eligible account to receive them while Postmere is closed." }
        else { statusText = "Apple push notifications are enabled for \(remoteAccountIDs.count) account\(remoteAccountIDs.count == 1 ? "" : "s")." }
    }
}
