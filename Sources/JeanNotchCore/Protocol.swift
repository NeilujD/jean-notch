import Foundation

// Wire shapes from Jean's jean-core/src/http_server (websocket.rs, mod.rs)
// and chat/types.rs (`AllSessionsResponse`, `Session`).

public struct SessionRef: Equatable, Sendable {
    public let sessionId: String
    public let worktreeId: String

    public init(sessionId: String, worktreeId: String) {
        self.sessionId = sessionId
        self.worktreeId = worktreeId
    }
}

public enum WaitKind: String, Equatable, Sendable {
    case question, plan, permission
}

/// The Jean events JeanNotch reacts to. Everything else is dropped at parse time.
public enum JeanEvent: Equatable, Sendable {
    case sending(SessionRef)
    case done(SessionRef, waitingForPlan: Bool)
    case failed(SessionRef)
    case cancelled(SessionRef)
    /// Claude ended the run with denied tools; the user must approve and resend.
    case permissionDenied(SessionRef)
    /// Codex/OpenCode/Devin ask mid-run; the run resumes once answered.
    case approvalRequest(SessionRef, WaitKind)
    case toolUse(SessionRef, name: String)
    case structureChanged
    /// Jean's unread sessions may have changed (a session was opened or marked read).
    case unreadChanged
    case resync

    static func make(name: String, payload: EventPayload?) -> JeanEvent? {
        switch name {
        case "ws:resync": return .resync
        case "session-renamed", "worktree:created", "worktree:deleted":
            return .structureChanged
        case "cache:invalidate":
            let keys = Set(payload?.keys ?? [])
            if !keys.isDisjoint(with: ["sessions", "projects"]) { return .structureChanged }
            return keys.contains("unread-sessions") ? .unreadChanged : nil
        default: break
        }
        guard let ref = payload?.ref else { return nil }
        switch name {
        case "chat:sending": return .sending(ref)
        case "chat:done": return .done(ref, waitingForPlan: payload?.waitingForPlan ?? false)
        case "chat:error": return .failed(ref)
        case "chat:cancelled": return .cancelled(ref)
        case "chat:permission_denied": return .permissionDenied(ref)
        case "chat:codex_user_input_request", "chat:codex_mcp_elicitation_request":
            return .approvalRequest(ref, .question)
        case "chat:codex_permission_request", "chat:opencode_permission_request",
             "chat:codex_command_approval_request", "chat:codex_dynamic_tool_call_request":
            return .approvalRequest(ref, .permission)
        case "chat:tool_use":
            guard let toolName = payload?.name else { return nil }
            return .toolUse(ref, name: toolName)
        default: return nil
        }
    }
}

/// Union of the payload fields JeanNotch reads. Each field decodes leniently so
/// one odd field never drops the whole event.
struct EventPayload: Decodable {
    let sessionId: String?
    let worktreeId: String?
    let waitingForPlan: Bool?
    let name: String?
    let keys: [String]?

    var ref: SessionRef? {
        guard let sessionId, let worktreeId else { return nil }
        return SessionRef(sessionId: sessionId, worktreeId: worktreeId)
    }

    enum CodingKeys: String, CodingKey {
        case sessionId = "session_id", worktreeId = "worktree_id"
        case waitingForPlan = "waiting_for_plan", name, keys
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        sessionId = try? c.decodeIfPresent(String.self, forKey: .sessionId)
        worktreeId = try? c.decodeIfPresent(String.self, forKey: .worktreeId)
        waitingForPlan = try? c.decodeIfPresent(Bool.self, forKey: .waitingForPlan)
        name = try? c.decodeIfPresent(String.self, forKey: .name)
        keys = try? c.decodeIfPresent([String].self, forKey: .keys)
    }
}

public enum ServerMessage: Equatable, Sendable {
    /// `nil` when the event is not one JeanNotch cares about.
    case event(JeanEvent?)
    case heartbeat
    case response(id: String, raw: Data)
    case error(id: String, message: String)
    case unknown

    public static func parse(_ data: Data) throws -> ServerMessage {
        struct Envelope: Decodable {
            let type: String?
            let event: String?
            let id: String?
            let error: String?
            let payload: EventPayload?
        }
        let envelope = try JSONDecoder().decode(Envelope.self, from: data)
        switch envelope.type {
        case "event":
            guard let name = envelope.event else { return .unknown }
            return .event(JeanEvent.make(name: name, payload: envelope.payload))
        case "heartbeat": return .heartbeat
        case "response": return .response(id: envelope.id ?? "", raw: data)
        case "error": return .error(id: envelope.id ?? "", message: envelope.error ?? "unknown error")
        default: return .unknown
        }
    }

    /// Decodes the `data` field of a `response` message.
    public static func decodeData<T: Decodable>(_ type: T.Type, from raw: Data) throws -> T {
        try snakeCaseDecoder.decode(DataEnvelope<T>.self, from: raw).data
    }
}

private struct DataEnvelope<T: Decodable>: Decodable { let data: T }

let snakeCaseDecoder: JSONDecoder = {
    let decoder = JSONDecoder()
    decoder.keyDecodingStrategy = .convertFromSnakeCase
    return decoder
}()

// MARK: - list_all_sessions

public struct AllSessionsResponse: Decodable, Equatable, Sendable {
    public let entries: [Entry]

    public struct Entry: Decodable, Equatable, Sendable {
        /// Absent only in old snapshots.
        public let projectId: String?
        public let projectName: String
        public let worktreeId: String
        public let worktreeName: String
        public let worktreePath: String
        public let sessions: [Session]
    }

    public struct Session: Decodable, Equatable, Sendable {
        public let id: String
        public let name: String
        public let updatedAt: UInt64?
        public let archivedAt: UInt64?
        /// `RunStatus`: running, completed, cancelled, crashed, resumable.
        public let lastRunStatus: String?
        public let waitingForInput: Bool
        /// "question" (AskUserQuestion) or "plan" (ExitPlanMode).
        public let waitingForInputType: String?
        /// True when any `pending_*` approval list on the session is non-empty.
        public let hasPendingApproval: Bool

        enum CodingKeys: String, CodingKey {
            case id, name, updatedAt, archivedAt, lastRunStatus, waitingForInput, waitingForInputType
            case pendingPermissionDenials, pendingCodexPermissionRequests, pendingOpencodePermissionRequests
            case pendingCodexCommandApprovalRequests, pendingCodexUserInputRequests
            case pendingCodexMcpElicitationRequests, pendingCodexDynamicToolCallRequests
        }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            id = try c.decode(String.self, forKey: .id)
            name = try c.decode(String.self, forKey: .name)
            updatedAt = try c.decodeIfPresent(UInt64.self, forKey: .updatedAt)
            archivedAt = try c.decodeIfPresent(UInt64.self, forKey: .archivedAt)
            lastRunStatus = try c.decodeIfPresent(String.self, forKey: .lastRunStatus)
            waitingForInput = try c.decodeIfPresent(Bool.self, forKey: .waitingForInput) ?? false
            waitingForInputType = try c.decodeIfPresent(String.self, forKey: .waitingForInputType)
            let pendingKeys: [CodingKeys] = [
                .pendingPermissionDenials, .pendingCodexPermissionRequests, .pendingOpencodePermissionRequests,
                .pendingCodexCommandApprovalRequests, .pendingCodexUserInputRequests,
                .pendingCodexMcpElicitationRequests, .pendingCodexDynamicToolCallRequests,
            ]
            hasPendingApproval = pendingKeys.contains { key in
                ((try? c.decodeIfPresent([Opaque].self, forKey: key)) ?? nil)?.isEmpty == false
            }
        }
    }

    /// Matches any JSON value; used only to count array elements.
    struct Opaque: Decodable {
        init(from decoder: Decoder) throws {}
    }
}

// MARK: - Unread sessions

/// Jean's unread sessions: `list_unread_sessions` answers in the `list_all_sessions` shape.
public enum UnreadSessions {
    public static let listCommand = "list_unread_sessions"
    public static let markReadCommand = "set_sessions_last_opened_bulk"

    public static func ids(from raw: Data) throws -> Set<String> {
        let response = try ServerMessage.decodeData(AllSessionsResponse.self, from: raw)
        return Set(response.entries.flatMap { $0.sessions.map(\.id) })
    }

    /// Jean stamps each session as opened now, so it leaves Jean's unread list.
    public static func markReadArgs(_ ids: Set<String>) -> [String: any Sendable] {
        ["sessionIds": ids.sorted()]
    }
}

// MARK: - get_session_debug_info

/// A session's token usage summed over all its runs (`SessionDebugInfo.total_usage`).
/// Jean writes a run's usage when the run ends, so the count moves on `chat:done`.
public struct TokenUsage: Decodable, Equatable, Sendable {
    public let inputTokens: UInt64
    public let outputTokens: UInt64
    public let cacheReadInputTokens: UInt64
    public let cacheCreationInputTokens: UInt64

    public init(input: UInt64, output: UInt64, cacheRead: UInt64 = 0, cacheCreation: UInt64 = 0) {
        inputTokens = input
        outputTokens = output
        cacheReadInputTokens = cacheRead
        cacheCreationInputTokens = cacheCreation
    }

    /// Every token the model processed. Cache reads are most of it: each turn re-reads the context.
    public var total: UInt64 {
        inputTokens + outputTokens + cacheReadInputTokens + cacheCreationInputTokens
    }

    /// "950", "12k", "3.2M", "42M".
    public static func format(_ tokens: UInt64) -> String {
        func short(_ value: Double, _ unit: String) -> String {
            value < 10 ? String(format: "%.1f%@", (value * 10).rounded(.down) / 10, unit) : "\(Int(value))\(unit)"
        }
        switch tokens {
        case ..<1_000: return "\(tokens)"
        case ..<1_000_000: return short(Double(tokens) / 1_000, "k")
        default: return short(Double(tokens) / 1_000_000, "M")
        }
    }
}

public struct SessionDebugInfo: Decodable, Equatable, Sendable {
    public let totalUsage: TokenUsage
}
