import Foundation

/// A plan that a session's last message asks the user to approve:
/// a Claude `ExitPlanMode` or Codex `CodexPlan` call that Jean has not marked approved.
public struct PendingPlan: Equatable, Sendable {
    /// The message that holds the plan. Jean marks this message approved.
    public let messageId: String
    /// The plan as Markdown: the plan file when Jean can read it, else the tool input or the message text.
    public var text: String
    /// The `~/.claude/plans/….md` file that holds the plan, when the session has one.
    let filePath: String?

    /// One request to Jean.
    public struct Request: Sendable {
        public let command: String
        public let args: [String: any Sendable]
    }

    /// The requests that Jean's own Approve button makes, in order (`handlePlanApproval` in
    /// Jean's src/components/chat/hooks/useMessageHandlers.ts, with the two
    /// `broadcast_session_setting` calls of its canvas card, usePlanApproval.ts, so other
    /// Jean windows update). Build mode. Omitted settings take the session's selection in Jean.
    /// `mcpConfig` and `chromeEnabled` are what Jean's window sends with any message.
    func approvalRequests(
        in session: SessionState, backend: String, build: BuildPreferences,
        mcpConfig: String?, chromeEnabled: Bool
    ) -> [Request] {
        let ids: [String: any Sendable] = [
            "sessionId": session.id, "worktreeId": session.worktreeId, "worktreePath": session.worktreePath,
        ]
        var send = ids
        send["message"] = Self.approvalMessage(backend: backend)
        send["executionMode"] = "build"
        send["chromeEnabled"] = chromeEnabled
        if let mcpConfig { send["mcpConfig"] = mcpConfig }
        // Jean's build overrides apply when no build backend is set, or when it is the session's.
        if build.buildBackend == nil || build.buildBackend == backend {
            if let model = build.buildModel { send["model"] = model }
            if let level = build.buildThinkingLevel { send["thinkingLevel"] = level }
            if let level = build.buildEffortLevel { send["effortLevel"] = level }
        }
        return [
            Request(command: "mark_plan_approved", args: ids.merging(["messageId": messageId]) { $1 }),
            Request(command: "update_session_state", args: ids.merging([
                "waitingForInput": false,
                "waitingForInputType": NSNull(),
                "selectedExecutionMode": "build",
            ]) { $1 }),
            Request(command: "broadcast_session_setting", args: ["sessionId": session.id, "key": "executionMode", "value": "build"]),
            Request(command: "broadcast_session_setting", args: ["sessionId": session.id, "key": "waitingForInput", "value": "false"]),
            Request(command: "send_chat_message", args: send),
        ]
    }

    /// Codex resumes a thread, so Jean asks it in other words.
    static func approvalMessage(backend: String) -> String {
        backend == "codex"
            ? "Execute the plan you created. Implement all changes described."
            : "Plan approved. Begin implementing the changes now. Do not re-explain the plan — start writing code."
    }
}

/// The build-mode settings of Jean's `load_preferences` response. Nil when not set.
struct BuildPreferences: Decodable {
    let buildBackend: String?
    let buildModel: String?
    let buildThinkingLevel: String?
    let buildEffortLevel: String?
}

// MARK: - get_session

/// The fields of Jean's `get_session` response that tell if a plan waits for approval.
public struct PlanDetail: Decodable, Sendable {
    let messages: [Message]
    let approvedPlanMessageIds: [String]
    let planFilePath: String?
    let waitingForInputType: String?

    struct Message: Decodable {
        let id: String
        let role: String
        let content: String
        let planApproved: Bool
        let planCall: PlanCall?

        enum CodingKeys: String, CodingKey { case planApproved, toolCalls }

        init(from decoder: Decoder) throws {
            // Same id, role and text as for questions.
            let message = try SessionDetail.Message(from: decoder)
            let c = try decoder.container(keyedBy: CodingKeys.self)
            id = message.id
            role = message.role
            content = message.content
            planApproved = (try? c.decodeIfPresent(Bool.self, forKey: .planApproved)) ?? false
            let calls = (try? c.decodeIfPresent([Lenient<PlanCall>].self, forKey: .toolCalls)) ?? []
            planCall = calls.compactMap(\.value).last
        }
    }

    /// A plan tool call. Decoding fails for other tools.
    struct PlanCall: Decodable {
        let plan: String?
        let planPreview: String?
        let planFilePath: String?

        enum CodingKeys: String, CodingKey { case name, input }
        enum InputKeys: String, CodingKey { case plan, planPreview, planFilePath }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            let name = try c.decode(String.self, forKey: .name)
            guard name == "ExitPlanMode" || name == "CodexPlan" else {
                throw DecodingError.dataCorruptedError(forKey: .name, in: c, debugDescription: "Not a plan tool")
            }
            // `plan_preview` and `plan_file_path` arrive in camelCase from the snake-case decoder.
            let input = try? c.nestedContainer(keyedBy: InputKeys.self, forKey: .input)
            func text(_ key: InputKeys) -> String? {
                (try? input?.decodeIfPresent(String.self, forKey: key))?
                    .trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
            }
            plan = text(.plan)
            planPreview = text(.planPreview)
            planFilePath = text(.planFilePath)
        }
    }

    private struct Lenient<T: Decodable>: Decodable {
        let value: T?
        init(from decoder: Decoder) throws { value = try? T(from: decoder) }
    }

    enum CodingKeys: String, CodingKey { case messages, approvedPlanMessageIds, planFilePath, waitingForInputType }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        messages = (try? c.decodeIfPresent([Message].self, forKey: .messages)) ?? []
        approvedPlanMessageIds = (try? c.decodeIfPresent([String].self, forKey: .approvedPlanMessageIds)) ?? []
        planFilePath = (try? c.decodeIfPresent(String.self, forKey: .planFilePath))?.nilIfEmpty
        waitingForInputType = try? c.decodeIfPresent(String.self, forKey: .waitingForInputType)
    }

    /// The plan in the last message, when the assistant wrote that message (no user message
    /// came after it) and Jean has not marked it approved. A plan without a plan tool call
    /// (a Codex plan in text) counts while Jean says the session waits on a plan.
    public var pendingPlan: PendingPlan? {
        guard let last = messages.last, last.role == "assistant", !last.planApproved,
              !approvedPlanMessageIds.contains(last.id),
              last.planCall != nil || waitingForInputType == "plan"
        else { return nil }
        let text = last.planCall?.plan ?? last.planCall?.planPreview ?? last.content
        let filePath = planFilePath ?? last.planCall?.planFilePath
        guard !text.isEmpty || filePath != nil else { return nil }
        return PendingPlan(messageId: last.id, text: text, filePath: filePath)
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
