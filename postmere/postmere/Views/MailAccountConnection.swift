import AppKit
import Observation

/// The account picker and Accounts settings use the same browser sign-in flow.
@MainActor @Observable
final class MailAccountConnection {
    private(set) var provider: String?
    private(set) var reconnectingEmail: String?
    private(set) var errorMessage: String?
    /// An account this connection just added, waiting to be named.
    var newAccount: BackendAccount?
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var attemptID: UUID?

    func start(_ provider: String, session: BackendSession, reconnecting account: BackendAccount? = nil,
               calendarAccess: Bool = false, onSync: @escaping @MainActor @Sendable () async -> Void) {
        guard self.provider == nil, !session.isBusy, let generation = session.realtimeGeneration else { return }
        let id = UUID()
        attemptID = id
        self.provider = provider
        reconnectingEmail = account?.email
        errorMessage = nil
        session.errorMessage = nil
        let includeCalendar = calendarAccess || account?.capabilities?.contains("calendar") == true
        task = Task {
            defer {
                if attemptID == id { reset() }
            }
            do {
                let connection = try await session.startOAuth(provider: provider, calendarAccess: includeCalendar)
                try Task.checkCancellation()
                guard let url = URL(string: connection.authorizationUrl), url.scheme == "https",
                      ["accounts.google.com", "login.microsoftonline.com"].contains(url.host ?? ""),
                      url.user == nil, url.password == nil,
                      NSWorkspace.shared.open(url) else { throw BackendError.invalidURL }
                let known = Set(session.accounts.map(\.id))
                let connectedID = try await session.waitForOAuth(connection, expectedAccountID: account?.id)
                guard session.realtimeGeneration == generation else { return }
                if account == nil, !known.contains(connectedID),
                   let added = session.accounts.first(where: { $0.id == connectedID }), added.name == nil {
                    newAccount = added
                }
                // Installing the first account removes the picker. Its disappearance
                // can cancel browser polling, but must not cancel the mailbox sync.
                await Task { await onSync() }.value
            } catch is CancellationError {
            } catch {
                if attemptID == id, session.realtimeGeneration == generation {
                    errorMessage = error.localizedDescription
                    session.errorMessage = error.localizedDescription
                }
            }
        }
    }

    func cancel() {
        task?.cancel()
        reset()
    }

    private func reset() {
        task = nil
        attemptID = nil
        provider = nil
        reconnectingEmail = nil
    }
}
