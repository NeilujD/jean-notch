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
    /// Experimental. While true, the store keeps the live Claude permission requests to answer them.
    public var answersPermissions = false {
        didSet {
            if !answersPermissions { permissions = [:] }
        }
    }
    /// Live Claude permission requests by session id, oldest first. Empty while `answersPermissions` is false.
    public private(set) var permissions: [String: [PermissionRequest]] = [:]
    /// Rpc ids of the permission requests whose answer is on its way to Jean.
    public private(set) var answeringPermissions: Set<UInt64> = []
    /// Why Jean refused the answer to a permission request, by rpc id. The request goes away soon after.
    public private(set) var permissionErrors: [UInt64: String] = [:]
    /// Experimental. Ids of the sessions whose stop request is on its way to Jean.
    public private(set) var stopping: Set<String> = []
    /// Why the last stop of a running session failed, by session id.
    public private(set) var stopErrors: [String: String] = [:]
    /// Experimental. While true, the store reads the plan of each session that waits on one.
    public var approvesPlans = false {
        didSet {
            if approvesPlans { syncPlans() } else { dropPlans() }
        }
    }
    /// The plan each session waits on, by session id. Empty while `approvesPlans` is false.
    public private(set) var plans: [String: PendingPlan] = [:]
    /// Ids of the sessions whose plan approval is on its way to Jean.
    public private(set) var approving: Set<String> = []
    /// Why Jean refused the last approval, by session id.
    public private(set) var approveErrors: [String: String] = [:]
    /// Called when a session moves into waiting, done, or failed.
    @ObservationIgnored public var onAlert: ((SessionState) -> Void)?

    @ObservationIgnored private let client: JeanClient
    @ObservationIgnored private var tasks: [Task<Void, Never>] = []
    @ObservationIgnored private var refreshTask: Task<Void, Never>?
    @ObservationIgnored private var unreadTask: Task<Void, Never>?
    @ObservationIgnored private var tokenTasks: [String: Task<Void, Never>] = [:]
    @ObservationIgnored private var usageTask: Task<Void, Never>?
    /// One entry per session whose question was requested, so each is requested once.
    @ObservationIgnored private var questionTasks: [String: Task<Void, Never>] = [:]
    /// One entry per session whose plan was requested, so each is requested once.
    @ObservationIgnored private var planTasks: [String: Task<Void, Never>] = [:]

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
            forgetPlanRequests()
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
                stopErrors[ref.sessionId] = nil
                loadTokens(ref.sessionId)
                scheduleUsageRefresh(after: .seconds(2))
                scheduleUnreadRefresh()
            case .unreadChanged:
                scheduleUnreadRefresh()
            case .sending(let ref) where tokens[ref.sessionId] == nil:
                loadTokens(ref.sessionId)
            default:
                break
            }
            trackPermissions(jeanEvent)
            // The run that just ended can end with a question, so read its last message (again).
            if case .done(let ref, _) = jeanEvent {
                questionTasks.removeValue(forKey: ref.sessionId)?.cancel()
                planTasks.removeValue(forKey: ref.sessionId)?.cancel()
            }
            syncQuestions()
            syncPlans()
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
                self.scheduleUnreadRefresh(after: .zero)
                await self.loadPrCache()
                self.syncPlans()
                let total = snapshot.entries.reduce(0) { $0 + $1.sessions.count }
                storeLog.info("Snapshot: \(snapshot.entries.count) worktrees, \(total) sessions, \(self.board.visibleGroups.count) visible groups, \(self.board.runningCount) running")
            } catch {
                storeLog.error("Snapshot failed: \(String(describing: error), privacy: .public)")
            }
        }
    }

    /// Reads the PR state Jean saved on the worktrees of every project with sessions: a worktree
    /// can become visible later (unread list, new run) without a new snapshot.
    /// Jean checks PRs only while its window is focused, so this is the state at its last check.
    private func loadPrCache() async {
        let projectIds = Set(board.sessions.values.map(\.projectId)).subtracting([""])
        var cache: [String: PrStatus] = [:]
        for projectId in projectIds {
            do {
                let raw = try await client.invoke("list_worktrees", args: ["projectId": projectId])
                for worktree in try ServerMessage.decodeData([CachedWorktreePr].self, from: raw) {
                    cache[worktree.id] = worktree.status
                }
            } catch {
                storeLog.error("list_worktrees failed: \(String(describing: error), privacy: .public)")
                return
            }
        }
        guard !Task.isCancelled else { return }
        board.loadPrCache(cache)
    }

    /// Debounced like the snapshot. Jean has no unread event: it is read again after events
    /// that can change it (`chat:done`, `cache:invalidate`) and after each snapshot.
    private func scheduleUnreadRefresh(after delay: Duration = .milliseconds(300)) {
        unreadTask?.cancel()
        unreadTask = Task { [weak self, client] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            let requestedAt = Date()
            do {
                let ids = try UnreadSessions.ids(from: await client.invoke(UnreadSessions.listCommand))
                guard !Task.isCancelled, let self else { return }
                self.board.loadUnread(ids, requestedAt: requestedAt)
                self.syncQuestions()
                storeLog.info("Unread: \(ids.count) sessions, \(self.board.visibleGroups.count) visible groups")
            } catch {
                storeLog.error("\(UnreadSessions.listCommand, privacy: .public) failed: \(String(describing: error), privacy: .public)")
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
    /// question, or an unread one that finished (it can ask in its text). Drops the questions of the rest.
    private func syncQuestions() {
        guard answersQuestions else { return }
        let candidates = board.sessions.values.filter {
            ($0.status == .waiting(.question) || ($0.status == .done && $0.unread)) && !$0.worktreePath.isEmpty
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
        let backend: String
        /// The raw `load_preferences` response, for the build settings.
        let preferencesResponse: Data
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
        let preferencesResponse = try await preferencesRaw
        let preferences = try ServerMessage.decodeData(PreferencesMcp.self, from: preferencesResponse)
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
        return SendContext(
            mcpConfig: config, chromeEnabled: chrome, sessionResponse: sessionResponse,
            backend: backend, preferencesResponse: preferencesResponse
        )
    }

    // MARK: Plans (experimental)

    /// Reads the plan of each session that waits on one. Drops the plans of the rest:
    /// a plan approved in Jean's window, or a new run, ends the wait.
    private func syncPlans() {
        guard approvesPlans else { return }
        let ids = Set(board.sessions.values.filter { $0.status == .waiting(.plan) && !$0.worktreePath.isEmpty }.map(\.id))
        for id in plans.keys where !ids.contains(id) { plans[id] = nil }
        for id in approving where !ids.contains(id) { approving.remove(id) }
        for id in approveErrors.keys where !ids.contains(id) { approveErrors[id] = nil }
        for (id, task) in planTasks where !ids.contains(id) {
            task.cancel()
            planTasks[id] = nil
        }
        for id in ids where planTasks[id] == nil {
            if let session = board.sessions[id] { loadPlan(session) }
        }
    }

    private func forgetPlanRequests() {
        for task in planTasks.values { task.cancel() }
        planTasks = [:]
    }

    private func dropPlans() {
        forgetPlanRequests()
        plans = [:]
        approving = []
        approveErrors = [:]
    }

    /// Reads the last run's message, then the plan file when there is one.
    /// Reads a second time after 2 s when it finds no plan: Claude's `ExitPlanMode` puts the
    /// session in wait before Jean saves the message.
    private func loadPlan(_ session: SessionState) {
        planTasks[session.id] = Task { [weak self, client] in
            var pending: PendingPlan?
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
                    pending = try ServerMessage.decodeData(PlanDetail.self, from: raw).pendingPlan
                } catch {
                    storeLog.error("get_session failed: \(String(describing: error), privacy: .private)")
                }
            }
            if let path = pending?.filePath {
                do {
                    let raw = try await client.invoke("read_plan_file", args: ["path": path, "sessionId": session.id])
                    let text = try ServerMessage.decodeData(String.self, from: raw)
                    if !text.isEmpty { pending?.text = text }
                } catch {
                    storeLog.error("read_plan_file failed: \(String(describing: error), privacy: .private)")
                }
            }
            guard !Task.isCancelled, let self else { return }
            if pending?.text.isEmpty == true { pending = nil }
            if self.plans[session.id] != pending { self.plans[session.id] = pending }
            storeLog.debug("Plan \(session.id, privacy: .public): \(pending == nil ? "none" : "open", privacy: .public)")
        }
    }

    /// Approves the plan as Jean's own Approve button does, in build mode: Jean marks it
    /// approved, and the session starts to implement it. The card closes on `chat:sending`.
    /// Like Jean, goes on to the message when marking the plan fails.
    public func approve(_ plan: PendingPlan, in session: SessionState) {
        guard plans[session.id] == plan, !approving.contains(session.id) else { return }
        approving.insert(session.id)
        approveErrors[session.id] = nil
        storeLog.info("Approving plan in \(session.id, privacy: .public)")
        Task { [weak self, client] in
            do {
                let context = try await Self.sendContext(for: session, client: client)
                let build = try ServerMessage.decodeData(BuildPreferences.self, from: context.preferencesResponse)
                let requests = plan.approvalRequests(
                    in: session, backend: context.backend, build: build,
                    mcpConfig: context.mcpConfig, chromeEnabled: context.chromeEnabled
                )
                for request in requests {
                    do {
                        _ = try await client.invoke(request.command, args: request.args)
                    } catch where request.command != "send_chat_message" {
                        storeLog.error("\(request.command, privacy: .public) failed: \(String(describing: error), privacy: .private)")
                    }
                }
            } catch {
                storeLog.error("Plan approval failed: \(String(describing: error), privacy: .private)")
                guard let self, self.approving.contains(session.id) else { return }
                self.approving.remove(session.id)
                self.approveErrors[session.id] = if case ClientError.notConnected = error {
                    "Connection lost. Check the session in Jean."
                } else {
                    "Not sent: \(error)"
                }
            }
        }
    }

    // MARK: Permission requests (experimental)

    /// A new request opens a card. Any other event of the run means the requests were answered
    /// (maybe in Jean's window, which sends no event for it) or the run ended.
    private func trackPermissions(_ event: JeanEvent) {
        switch event {
        case .permissionRequest(let ref, let requests) where answersPermissions:
            let rpcIds = Set(requests.map(\.rpcId))
            permissions[ref.sessionId] = (permissions[ref.sessionId] ?? []).filter { !rpcIds.contains($0.rpcId) } + requests
        case .sending(let ref), .done(let ref, _), .failed(let ref), .cancelled(let ref), .toolUse(let ref, _):
            permissions[ref.sessionId] = nil
        default:
            break
        }
    }

    /// Answers one live request. Jean has no "always allow" for it. On error (the run already
    /// stopped, or Jean's window answered first) the card shows the error, then goes away.
    public func answerPermission(_ request: PermissionRequest, in session: SessionState, approved: Bool) {
        guard permissions[session.id]?.contains(request) == true,
              !answeringPermissions.contains(request.rpcId)
        else { return }
        answeringPermissions.insert(request.rpcId)
        storeLog.info("Answering permission \(request.rpcId) in \(session.id, privacy: .public): \(approved ? "allow" : "deny", privacy: .public)")
        Task { [weak self, client] in
            var failure: String?
            do {
                _ = try await client.invoke("respond_claude_permission", args: request.answerArgs(sessionId: session.id, approved: approved))
            } catch {
                storeLog.error("respond_claude_permission failed: \(String(describing: error), privacy: .public)")
                failure = "Not answered: \(error)"
            }
            guard let self else { return }
            self.answeringPermissions.remove(request.rpcId)
            if let failure {
                self.permissionErrors[request.rpcId] = failure
                try? await Task.sleep(for: .seconds(4))
                self.permissionErrors[request.rpcId] = nil
            }
            self.permissions[session.id]?.removeAll { $0 == request }
            if self.permissions[session.id]?.isEmpty == true {
                self.permissions[session.id] = nil
                if failure == nil { self.board.markResumed(session.id) }
            }
        }
    }

    // MARK: Stop (experimental)

    /// Asks Jean to cancel the session's run. Jean then sends `chat:cancelled`, which updates the row.
    public func stop(_ session: SessionState) {
        guard session.status == .running, !stopping.contains(session.id) else { return }
        stopping.insert(session.id)
        stopErrors[session.id] = nil
        storeLog.info("Stopping \(session.id, privacy: .public)")
        Task { [weak self, client] in
            var failure: String?
            do {
                let raw = try await client.invoke("cancel_chat_message", args: session.cancelArgs)
                // False: Jean found no run to cancel.
                if try !ServerMessage.decodeData(Bool.self, from: raw) { failure = "Not stopped: Jean found no run." }
            } catch {
                storeLog.error("cancel_chat_message failed: \(String(describing: error), privacy: .public)")
                failure = "Not stopped: \(error)"
            }
            guard let self else { return }
            self.stopping.remove(session.id)
            self.stopErrors[session.id] = failure
        }
    }

    /// Marks every unread session read, in the notch now and in Jean. Reads Jean's list first:
    /// it can hold sessions the board does not show.
    public func markAllRead() {
        let shown = board.unreadIds
        board.markRead(shown)
        syncQuestions()
        Task { [weak self, client] in
            do {
                let ids = try shown.union(UnreadSessions.ids(from: await client.invoke(UnreadSessions.listCommand)))
                _ = try await client.invoke(UnreadSessions.markReadCommand, args: UnreadSessions.markReadArgs(ids))
                storeLog.info("Marked \(ids.count) sessions read")
            } catch {
                storeLog.error("\(UnreadSessions.markReadCommand, privacy: .public) failed: \(String(describing: error), privacy: .public)")
            }
            self?.scheduleUnreadRefresh(after: .zero)
        }
    }

    /// Asks Jean to make `session` its active session, which also marks it read. Best effort:
    /// Jean stores the choice but its window may not switch to it yet.
    public func selectInJean(_ session: SessionState) async {
        board.markRead([session.id])
        syncQuestions()
        defer { scheduleUnreadRefresh(after: .zero) }
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

extension SessionState {
    /// Arguments of Jean's `cancel_chat_message` command.
    var cancelArgs: [String: any Sendable] {
        ["sessionId": id, "worktreeId": worktreeId]
    }
}
