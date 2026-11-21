import Foundation

/// Keeps the list of connected assistants current, so the app can show when
/// one is working. Polls lightly while a workspace is connected.
@MainActor @Observable
final class AssistantActivityMonitor {
    private(set) var connections: [AssistantConnection] = []
    private(set) var lastError: String?
    @ObservationIgnored private var task: Task<Void, Never>?

    var working: [AssistantConnection] { connections.filter { $0.isWorking() } }

    func start(session: BackendSession) {
        guard task == nil else { return }
        task = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refresh(session: session)
                try? await Task.sleep(for: .seconds(15))
            }
        }
    }

    func refresh(session: BackendSession) async {
        guard session.canAccessWorkspace else {
            if !connections.isEmpty { connections = [] }
            return
        }
        do {
            let latest = try await session.assistantConnections()
            if latest != connections { connections = latest }
            lastError = nil
        } catch {
            lastError = error.localizedDescription
        }
    }

    func revoke(_ connection: AssistantConnection, session: BackendSession) async {
        do {
            try await session.revokeAssistant(id: connection.id)
            connections.removeAll { $0.id == connection.id }
        } catch {
            lastError = error.localizedDescription
        }
    }
}
