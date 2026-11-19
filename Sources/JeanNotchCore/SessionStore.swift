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
    /// Token usage of the sessions the notch shows, by session id.
    public private(set) var tokens: [String: TokenUsage] = [:]
    /// Plan limits of the providers that answered (a provider you are not logged in to errors).
    public private(set) var usage: [UsageProvider: ProviderUsage] = [:]
    /// Experimental. While true, the store reads the last message of each session that
    /// finished a run or waits on a question, to find the question it asks.
    public var answersQuestions = false {
        didSet {
            if answersQuestions { syncQuestions() } else { dropQuestions() }
        }
    }
    /// The open question of each session that asks one, by session id. Empty while `answersQuestions` is false.
    public private(set) var questions: [String: PendingQuestion] = [:]
    /// Ids of the open questions whose answer is on its way to Jean.
    public private(set) var answering: Set<String> = []
    /// Why Jean refused the last answer to an open question, by question id.
    public private(set) var answerErrors: [String: String] = [:]
    /// Called when a session moves into waiting, done, or failed.
    @ObservationIgnored public var onAlert: ((SessionState) -> Void)?

    @ObservationIgnored private let client: JeanClient
    @ObservationIgnored private var tasks: [Task<Void, Never>] = []
    @ObservationIgnored private var refreshTask: Task<Void, Never>?
    @ObservationIgnored private var tokenTasks: [String: Task<Void, Never>] = [:]
    @ObservationIgnored private var usageTask: Task<Void, Never>?
    /// One entry per session whose question was requested, so each is requested once.
    @ObservationIgnored private var questionTasks: [String: Task<Void, Never>] = [:]

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
            // Events were missed while offline: read every open question again after the snapshot.
            forgetQuestionRequests()
            scheduleRefresh(after: .zero)
            scheduleUsageRefresh(after: .zero)
        case .disconnected(let reason):
            connection = .offline(reason)
            usageTask?.cancel()
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
            switch jeanEvent {
            case .done(let ref, _), .failed(let ref), .cancelled(let ref):
                loadTokens(ref.sessionId)
                scheduleUsageRefresh(after: .seconds(2))
            case .sending(let ref) where tokens[ref.sessionId] == nil:
                loadTokens(ref.sessionId)
            default:
                break
            }
            // The run that just ended can end with a question, so read its last message (again).
            if case .done(let ref, _) = jeanEvent {
                questionTasks.removeValue(forKey: ref.sessionId)?.cancel()
            }
            syncQuestions()
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
                self.tokens = self.tokens.filter { self.board.sessions[$0.key] != nil }
                self.tokenTasks = self.tokenTasks.filter { self.board.sessions[$0.key] != nil }
                for group in self.board.visibleGroups {
                    for session in group.sessions where self.tokens[session.id] == nil {
                        self.loadTokens(session.id)
                    }
                }
                self.syncQuestions()
                let total = snapshot.entries.reduce(0) { $0 + $1.sessions.count }
                storeLog.info("Snapshot: \(snapshot.entries.count) worktrees, \(total) sessions, \(self.board.visibleGroups.count) visible groups, \(self.board.runningCount) running")
            } catch {
                storeLog.error("Snapshot failed: \(String(describing: error), privacy: .public)")
            }
        }
    }

    /// Jean saves a run's usage before it sends `chat:done`, so a fetch then sees the new total.
    private func loadTokens(_ sessionId: String) {
        guard let session = board.sessions[sessionId], !session.worktreePath.isEmpty else { return }
        tokenTasks[sessionId]?.cancel()
        tokenTasks[sessionId] = Task { [weak self, client] in
            do {
                let raw = try await client.invoke("get_session_debug_info", args: [
                    "worktreeId": session.worktreeId,
                    "worktreePath": session.worktreePath,
                    "sessionId": session.id,
                ])
                let info = try ServerMessage.decodeData(SessionDebugInfo.self, from: raw)
                guard !Task.isCancelled else { return }
                self?.tokens[sessionId] = info.totalUsage
                storeLog.debug("Tokens \(sessionId, privacy: .public): \(info.totalUsage.total)")
            } catch {
                storeLog.error("get_session_debug_info failed: \(String(describing: error), privacy: .public)")
            }
        }
    }

    /// Refreshes every provider, then again every 5 minutes. Each call replaces the pending one.
    private func scheduleUsageRefresh(after delay: Duration) {
        usageTask?.cancel()
        usageTask = Task { [weak self, client] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            var next: [UsageProvider: ProviderUsage] = [:]
            for provider in UsageProvider.allCases {
                do {
                    let raw = try await client.invoke(provider.command)
                    next[provider] = try ServerMessage.decodeData(ProviderUsage.self, from: raw)
                } catch {
                    storeLog.debug("\(provider.command, privacy: .public): \(String(describing: error), privacy: .public)")
                }
            }
            guard !Task.isCancelled, let self else { return }
            self.usage = next
            self.scheduleUsageRefresh(after: .seconds(300))
        }
    }

    // MARK: Questions (experimental)

    /// Reads the last message of each session that can ask a question: one that waits on a
    /// question, or one that finished (it can ask in its text). Drops the questions of the rest.
    private func syncQuestions() {
        guard answersQuestions else { return }
        let candidates = board.sessions.values.filter {
            ($0.status == .waiting(.question) || $0.status == .done) && !$0.worktreePath.isEmpty
        }
        let ids = Set(candidates.map(\.id))
        for id in questions.keys where !ids.contains(id) { questions[id] = nil }
        let open = Set(questions.values.map(\.id))
        for id in answering where !open.contains(id) { answering.remove(id) }
        for id in answerErrors.keys where !open.contains(id) { answerErrors[id] = nil }
        for (id, task) in questionTasks where !ids.contains(id) {
            task.cancel()
            questionTasks[id] = nil
        }
        for session in candidates where questionTasks[session.id] == nil {
            loadQuestion(session)
        }
    }

    private func forgetQuestionRequests() {
        for task in questionTasks.values { task.cancel() }
        questionTasks = [:]
    }

    private func dropQuestions() {
        forgetQuestionRequests()
        for id in board.sessions.keys { board.clearAsking(id) }
        questions = [:]
        answering = []
        answerErrors = [:]
    }

    /// `limit` counts runs: the last run holds the assistant message that asks.
    /// Reads a second time after 2 s when it finds no question: some backends can send
    /// `chat:done` before Jean saves the last message.
    private func loadQuestion(_ session: SessionState) {
        questionTasks[session.id] = Task { [weak self, client] in
            var pending: PendingQuestion?
            for attempt in 0..<2 where pending == nil {
                if attempt > 0 { try? await Task.sleep(for: .seconds(2)) }
                guard !Task.isCancelled else { return }
                do {
                    let raw = try await client.invoke("get_session", args: [
                        "worktreeId": session.worktreeId,
                        "worktreePath": session.worktreePath,
                        "sessionId": session.id,
                        "limit": 1,
                    ])
                    pending = try ServerMessage.decodeData(SessionDetail.self, from: raw).pendingQuestion
                } catch {
                    storeLog.error("get_session failed: \(String(describing: error), privacy: .private)")
                }
            }
            guard !Task.isCancelled, let self else { return }
            if self.questions[session.id] != pending { self.questions[session.id] = pending }
            if pending == nil {
                self.board.clearAsking(session.id)
            } else {
                self.board.markAsking(session.id)
            }
            storeLog.debug("Question \(session.id, privacy: .public): \(pending == nil ? "none" : "open", privacy: .public)")
        }
    }

    /// Sends the picked options to the session as a chat message, in the words Jean's own UI
    /// uses. Jean then starts the next run with the session's model and mode.
    /// The question closes on the `chat:sending` event. Jean answers the request itself only
    /// when that run ends, so only an error from it means something here.
    public func answer(_ question: PendingQuestion, in session: SessionState, with picks: PendingQuestion.Picks) {
        guard questions[session.id] == question, question.isAnswered(by: picks),
              !answering.contains(question.id)
        else { return }
        answering.insert(question.id)
        answerErrors[question.id] = nil
        storeLog.info("Answering question in \(session.id, privacy: .public)")
        Task { [weak self, client] in
            do {
                let context = try await Self.sendContext(for: session, client: client)
                // Jean's own card saves a tool question's answer before it sends, so its window
                // shows the picked options. A question asked as text has nothing to save.
                if question.form == .tool {
                    let saved = question.savedAnswers(for: picks, sessionResponse: context.sessionResponse)
                    _ = try await client.invoke("update_session_state", args: [
                        "worktreeId": session.worktreeId,
                        "worktreePath": session.worktreePath,
                        "sessionId": session.id,
                        "answeredQuestions": saved.answered,
                        "submittedAnswers": saved.submitted,
                    ])
                }
                var args: [String: any Sendable] = [
                    "sessionId": session.id,
                    "worktreeId": session.worktreeId,
                    "worktreePath": session.worktreePath,
                    "message": question.answerText(for: picks),
                    "chromeEnabled": context.chromeEnabled,
                ]
                if let mcpConfig = context.mcpConfig { args["mcpConfig"] = mcpConfig }
                _ = try await client.invoke("send_chat_message", args: args)
            } catch {
                storeLog.error("send_chat_message failed: \(String(describing: error), privacy: .private)")
                guard let self, self.answering.contains(question.id) else { return }
                self.answering.remove(question.id)
                // The socket can drop after Jean took the message, so this is not a sure failure.
                self.answerErrors[question.id] = if case ClientError.notConnected = error {
                    "Connection lost. Check the session in Jean."
                } else {
                    "Not sent: \(error)"
                }
            }
        }
    }

    /// What Jean's window would send with a message to this session now.
    private struct SendContext {
        /// Holds server settings (and can hold their secrets), so it is never logged.
        let mcpConfig: String?
        let chromeEnabled: Bool
        /// The raw `get_session` response, for the saved answers.
        let sessionResponse: Data
    }

    /// Read at each send, because the user can change these settings in Jean while the card is open.
    private static func sendContext(for session: SessionState, client: JeanClient) async throws -> SendContext {
        async let sessionRaw = client.invoke("get_session", args: [
            "worktreeId": session.worktreeId,
            "worktreePath": session.worktreePath,
            "sessionId": session.id,
            "limit": 1,
        ])
        async let projectsRaw = client.invoke("list_projects")
        async let preferencesRaw = client.invoke("load_preferences")
        let sessionResponse = try await sessionRaw
        let mcp = try ServerMessage.decodeData(SessionMcp.self, from: sessionResponse)
        let projects = try ServerMessage.decodeData([ProjectMcp].self, from: await projectsRaw)
        let preferences = try ServerMessage.decodeData(PreferencesMcp.self, from: await preferencesRaw)
        let project = projects.first { $0.id == session.projectId }
        let backend = mcp.backend ?? preferences.defaultBackend ?? "claude"
        let selection = McpSelection(
            sessionEnabled: mcp.enabledMcpServers,
            projectEnabled: project?.enabledMcpServers,
            globalEnabled: preferences.defaultEnabledMcpServers ?? [],
            known: project?.knownMcpServers ?? preferences.knownMcpServers ?? []
        )
        let servers = try? await client.invoke("get_mcp_servers", args: [
            "backend": backend,
            "worktreePath": session.worktreePath,
        ])
        let config = selection.config(serversResponse: servers, backend: backend)
        let count = (config.flatMap { try? JSONSerialization.jsonObject(with: Data($0.utf8)) } as? [String: [String: Any]])?["mcpServers"]?.count ?? 0
        let chrome = preferences.chromeEnabled ?? false
        storeLog.info("Send context for \(session.id, privacy: .public): \(count) MCP servers (\(backend, privacy: .public)), chrome \(chrome)")
        return SendContext(mcpConfig: config, chromeEnabled: chrome, sessionResponse: sessionResponse)
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
