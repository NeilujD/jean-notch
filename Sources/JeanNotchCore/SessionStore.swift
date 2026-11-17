import Foundation
import Observation
import os

private let storeLog = Logger(subsystem: "build.jean.notch", category: "store")

public enum ConnectionState: Equatable, Sendable {
    case connecting, online, offline(String)
}

/// Main-actor owner of the board: feeds client events into the reducer and
/// refetches the `list_all_sessions` snapshot when needed.
@MainActor
@Observable
public final class SessionStore {
    public private(set) var board = SessionBoard()
    public private(set) var connection = ConnectionState.connecting
    /// Called when a session moves into waiting, done, or failed.
    @ObservationIgnored public var onAlert: ((SessionState) -> Void)?

    @ObservationIgnored private let client: JeanClient
    @ObservationIgnored private var tasks: [Task<Void, Never>] = []
    @ObservationIgnored private var refreshTask: Task<Void, Never>?

    public init(client: JeanClient = JeanClient()) {
        self.client = client
    }

    public func start() {
        let client = client
        tasks.append(Task { await client.run() })
        tasks.append(Task { [weak self] in
            for await event in client.events {
                self?.handle(event)
            }
        })
    }

    private func handle(_ event: ClientEvent) {
        switch event {
        case .connected:
            connection = .online
            scheduleRefresh(after: .zero)
        case .disconnected(let reason):
            connection = .offline(reason)
        case .event(let jeanEvent):
            let result = board.apply(jeanEvent, now: Date())
            storeLog.debug("Event \(String(describing: jeanEvent), privacy: .public)")
            if let alert = result.alert {
                storeLog.info("Alert \(alert.id, privacy: .public) -> \(String(describing: alert.status), privacy: .public)")
                onAlert?(alert)
            }
            if result.needsSnapshot {
                scheduleRefresh(after: jeanEvent == .resync ? .zero : .milliseconds(500))
            }
        }
    }

    /// Debounced: a burst of structure events triggers one fetch.
    private func scheduleRefresh(after delay: Duration) {
        refreshTask?.cancel()
        refreshTask = Task { [weak self, client] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            let requestedAt = Date()
            do {
                let raw = try await client.invoke("list_all_sessions")
                let snapshot = try ServerMessage.decodeData(AllSessionsResponse.self, from: raw)
                guard let self else { return }
                self.board.load(snapshot, requestedAt: requestedAt)
                let total = snapshot.entries.reduce(0) { $0 + $1.sessions.count }
                storeLog.info("Snapshot: \(snapshot.entries.count) worktrees, \(total) sessions, \(self.board.visibleGroups.count) visible groups, \(self.board.runningCount) running")
            } catch {
                storeLog.error("Snapshot failed: \(String(describing: error), privacy: .public)")
            }
        }
    }

    public func markSeen(_ sessionId: String) { board.markSeen(sessionId) }
    public func markAllSeen() { board.markAllSeen() }

    /// Asks Jean to make `session` its active session. Best effort: Jean stores the
    /// choice but its window may not switch to it yet.
    public func selectInJean(_ session: SessionState) async {
        do {
            _ = try await client.invoke("set_active_session", args: [
                "worktreeId": session.worktreeId,
                "worktreePath": session.worktreePath,
                "sessionId": session.id,
            ])
        } catch {
            storeLog.error("set_active_session failed: \(String(describing: error), privacy: .public)")
        }
    }
}
