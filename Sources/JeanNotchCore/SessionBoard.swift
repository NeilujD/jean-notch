import Foundation

public enum SessionStatus: Equatable, Sendable {
    case idle, running, waiting(WaitKind), done, failed
}

public struct SessionState: Equatable, Sendable, Identifiable {
    public let id: String
    public var name: String
    public var projectName: String
    /// Empty when unknown (a session seen only in an event so far).
    public var projectId = ""
    public var worktreeId: String
    public var worktreeName: String
    public var worktreePath: String
    public var status: SessionStatus
    /// Done/failed result the user has not looked at yet.
    public var unseen = false
    public var changedAt: Date
    /// A wait that must survive the following `chat:done` (Claude's
    /// AskUserQuestion/ExitPlanMode or denied tools end the run).
    var pendingWait: WaitKind?
    /// The wait comes from a question in the last message's text (`markAsking`).
    /// Jean's snapshot has no flag for it, so `load` must keep it.
    var asksInText = false

    /// Lower is more urgent; nil means hidden.
    public var urgency: Int? {
        switch status {
        case .waiting: 0
        case .failed: unseen ? 1 : nil
        case .running: 2
        case .done: unseen ? 3 : nil
        case .idle: nil
        }
    }
}

public struct WorktreeGroup: Equatable, Identifiable, Sendable {
    public var id: String { worktreeId }
    public let worktreeId: String
    public let projectName: String
    public let worktreeName: String
    public let sessions: [SessionState]

    public init(worktreeId: String, projectName: String, worktreeName: String, sessions: [SessionState]) {
        self.worktreeId = worktreeId
        self.projectName = projectName
        self.worktreeName = worktreeName
        self.sessions = sessions
    }
}

public enum Urgency: Equatable, Sendable {
    case waiting, failed, done
}

/// Pure session-status reducer. No I/O, so tests drive it directly.
public struct SessionBoard: Equatable, Sendable {
    public private(set) var sessions: [String: SessionState] = [:]

    public init() {}

    public struct ApplyResult: Equatable, Sendable {
        /// Session that just moved into waiting/done/failed.
        public var alert: SessionState?
        /// Event named a session the board does not know; refetch the snapshot.
        public var needsSnapshot = false
    }

    // MARK: Snapshot

    /// Replaces the board with `snapshot`, keeping live knowledge the snapshot can't carry:
    /// unseen results, sticky waits, and anything changed after `requestedAt`
    /// (events that raced the in-flight request).
    public mutating func load(_ snapshot: AllSessionsResponse, requestedAt: Date) {
        var next: [String: SessionState] = [:]
        for entry in snapshot.entries {
            for dto in entry.sessions where dto.archivedAt == nil {
                var state = SessionState(
                    id: dto.id,
                    name: dto.name,
                    projectName: entry.projectName,
                    projectId: entry.projectId ?? "",
                    worktreeId: entry.worktreeId,
                    worktreeName: entry.worktreeName,
                    worktreePath: entry.worktreePath,
                    status: Self.status(of: dto),
                    changedAt: dto.updatedAt.map { Date(timeIntervalSince1970: TimeInterval($0)) } ?? requestedAt
                )
                if let old = sessions[dto.id] {
                    let snapshotIsQuiet = state.status == .idle || state.status == .failed || state.status == .done
                    if old.changedAt >= requestedAt || ((old.unseen || old.asksInText) && snapshotIsQuiet) {
                        state.status = old.status
                        state.unseen = old.unseen
                        state.changedAt = old.changedAt
                        state.pendingWait = old.pendingWait
                        state.asksInText = old.asksInText
                    } else if old.status == state.status {
                        state.changedAt = old.changedAt
                    }
                }
                next[dto.id] = state
            }
        }
        sessions = next
    }

    static func status(of dto: AllSessionsResponse.Session) -> SessionStatus {
        if dto.waitingForInput {
            return .waiting(dto.waitingForInputType == "plan" ? .plan : .question)
        }
        if dto.hasPendingApproval { return .waiting(.permission) }
        switch dto.lastRunStatus {
        case "running", "resumable": return .running
        case "crashed": return .failed
        default: return .idle
        }
    }

    // MARK: Events

    public mutating func apply(_ event: JeanEvent, now: Date) -> ApplyResult {
        let ref: SessionRef
        switch event {
        case .structureChanged, .resync:
            return ApplyResult(needsSnapshot: true)
        case .sending(let r), .done(let r, _), .failed(let r), .cancelled(let r),
             .permissionDenied(let r), .permissionRequest(let r, _), .approvalRequest(let r, _), .toolUse(let r, _):
            ref = r
        }

        var result = ApplyResult()
        var state = sessions[ref.sessionId] ?? {
            result.needsSnapshot = true
            return placeholder(for: ref, now: now)
        }()
        let before = state.status

        switch event {
        case .sending:
            state.status = .running
            state.pendingWait = nil
            state.unseen = false
        case .done(_, let waitingForPlan):
            if waitingForPlan {
                state.status = .waiting(.plan)
            } else if let wait = state.pendingWait {
                state.status = .waiting(wait)
            } else {
                state.status = .done
                state.unseen = true
            }
            state.pendingWait = nil
        case .failed:
            state.status = .failed
            state.unseen = true
            state.pendingWait = nil
        case .cancelled:
            state.status = .idle
            state.unseen = false
            state.pendingWait = nil
        case .permissionDenied:
            state.status = .waiting(.permission)
            state.pendingWait = .permission
        case .approvalRequest(_, let kind):
            state.status = .waiting(kind)
        case .permissionRequest:
            // Mid-run, unlike `permissionDenied`: the run continues once answered.
            state.status = .waiting(.permission)
        case .toolUse(_, let name):
            if let blocking = Self.blockingTools[name] {
                state.status = .waiting(blocking)
                state.pendingWait = blocking
            } else if state.pendingWait == nil {
                // A tool ran: any mid-run approval was answered.
                state.status = .running
            }
        case .structureChanged, .resync:
            break
        }

        if state.status != .waiting(.question) { state.asksInText = false }
        if state.status != before {
            state.changedAt = now
            switch state.status {
            case .waiting, .done, .failed: result.alert = state
            case .idle, .running: break
            }
        }
        sessions[ref.sessionId] = state
        return result
    }

    /// Claude tools that stop the run until the user answers (claude.rs kills the process).
    static let blockingTools: [String: WaitKind] = ["AskUserQuestion": .question, "ExitPlanMode": .plan]

    private func placeholder(for ref: SessionRef, now: Date) -> SessionState {
        let sibling = sessions.values.first { $0.worktreeId == ref.worktreeId }
        return SessionState(
            id: ref.sessionId,
            name: "New session",
            projectName: sibling?.projectName ?? "",
            projectId: sibling?.projectId ?? "",
            worktreeId: ref.worktreeId,
            worktreeName: sibling?.worktreeName ?? "",
            worktreePath: sibling?.worktreePath ?? "",
            status: .idle,
            changedAt: now
        )
    }

    // MARK: Questions asked as text

    /// Moves a finished session to waiting: its last message ends with a question.
    /// The wait stays until the session's next run, or until `clearAsking`.
    public mutating func markAsking(_ sessionId: String) {
        guard sessions[sessionId]?.status == .done else { return }
        sessions[sessionId]?.status = .waiting(.question)
        sessions[sessionId]?.asksInText = true
    }

    /// Undoes `markAsking`: the session is a finished session again, seen or not as before.
    public mutating func clearAsking(_ sessionId: String) {
        guard sessions[sessionId]?.asksInText == true else { return }
        sessions[sessionId]?.status = .done
        sessions[sessionId]?.asksInText = false
    }

    // MARK: Permission answered

    /// The user answered a live permission request: the run that waited on it goes on.
    public mutating func markResumed(_ sessionId: String) {
        guard sessions[sessionId]?.status == .waiting(.permission),
              sessions[sessionId]?.pendingWait == nil
        else { return }
        sessions[sessionId]?.status = .running
    }

    // MARK: Seen

    public mutating func markSeen(_ sessionId: String) {
        sessions[sessionId]?.unseen = false
    }

    public mutating func markAllSeen() {
        for id in sessions.keys { sessions[id]?.unseen = false }
    }

    // MARK: Views of the board

    /// Visible sessions grouped by worktree; groups and rows sorted by urgency, then recency.
    public var visibleGroups: [WorktreeGroup] {
        let visible = sessions.values.filter { $0.urgency != nil }
        let byWorktree = Dictionary(grouping: visible, by: \.worktreeId)
        let groups = byWorktree.map { worktreeId, members in
            let sorted = members.sorted(by: Self.moreUrgent)
            return WorktreeGroup(
                worktreeId: worktreeId,
                projectName: sorted[0].projectName,
                worktreeName: sorted[0].worktreeName,
                sessions: sorted
            )
        }
        return groups.sorted { Self.moreUrgent($0.sessions[0], $1.sessions[0]) }
    }

    static func moreUrgent(_ a: SessionState, _ b: SessionState) -> Bool {
        let (ua, ub) = (a.urgency ?? .max, b.urgency ?? .max)
        if ua != ub { return ua < ub }
        if a.changedAt != b.changedAt { return a.changedAt > b.changedAt }
        return a.id < b.id
    }

    public var runningCount: Int {
        sessions.values.count { $0.status == .running }
    }

    public var mostUrgent: Urgency? {
        let values = sessions.values
        if values.contains(where: { if case .waiting = $0.status { true } else { false } }) { return .waiting }
        if values.contains(where: { $0.status == .failed && $0.unseen }) { return .failed }
        if values.contains(where: { $0.status == .done && $0.unseen }) { return .done }
        return nil
    }
}
