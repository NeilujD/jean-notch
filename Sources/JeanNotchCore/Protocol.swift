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
    case resync

    static func make(name: String, payload: EventPayload?) -> JeanEvent? {
        switch name {
        case "ws:resync": return .resync
        case "session-renamed", "worktree:created", "worktree:deleted":
            return .structureChanged
        case "cache:invalidate":
            let keys = Set(payload?.keys ?? [])
            return keys.isDisjoint(with: ["sessions", "projects"]) ? nil : .structureChanged
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
