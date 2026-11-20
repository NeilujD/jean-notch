import Foundation
import Testing
@testable import JeanNotchCore

// Samples follow Jean's `get_session` response: `Session` (chat/types.rs) with `messages`,
// `approved_plan_message_ids` and `plan_file_path`. Tool `input` keeps the CLI's keys.

private func detail(messages: String, session: String = "") throws -> PlanDetail {
    let json = #"{"type":"response","id":"1","data":{"id":"s1","messages":\#(messages)\#(session)}}"#
    return try ServerMessage.decodeData(PlanDetail.self, from: Data(json.utf8))
}

private func planning(input: String = ##"{"plan":"# Plan\n- Step"}"##, extra: String = "") -> String {
    #"""
    [{"id":"m1","role":"user","content":"Plan it","tool_calls":[]},
     {"id":"m2","role":"assistant","content":"Here is the plan.","tool_calls":[
        {"id":"t0","name":"Read","input":{"file_path":"/a"}},
        {"id":"t1","name":"ExitPlanMode","input":\#(input)}]\#(extra)}]
    """#
}

private let session = SessionState(
    id: "s1", name: "S", projectName: "p", worktreeId: "w1", worktreeName: "main",
    worktreePath: "/tmp/p", status: .waiting(.plan), changedAt: .now
)

@Test func readsThePlanOfTheLastAssistantMessage() throws {
    let plan = try #require(try detail(messages: planning()).pendingPlan)
    #expect(plan.messageId == "m2")
    #expect(plan.text == "# Plan\n- Step")
    #expect(plan.filePath == nil)
}

@Test func planTextFallsBackToPreviewThenMessageAndKeepsTheFilePath() throws {
    let preview = try #require(try detail(messages: planning(input: #"{"plan_preview":"Preview"}"#)).pendingPlan)
    #expect(preview.text == "Preview")

    let file = try #require(try detail(messages: planning(input: #"{"planFilePath":"/u/.claude/plans/a.md"}"#)).pendingPlan)
    #expect(file.text == "Here is the plan.")
    #expect(file.filePath == "/u/.claude/plans/a.md")

    // Claude wrote the plan file, and Jean added an empty `ExitPlanMode` call.
    let written = #"""
    [{"id":"m1","role":"assistant","content":"Plan ready.","tool_calls":[
        {"id":"t1","name":"Write","input":{"file_path":"/u/.claude/plans/c.md","content":"# C"}},
        {"id":"t2","name":"Write","input":{"file_path":"/repo/notes.md","content":"x"}},
        {"id":"t3","name":"ExitPlanMode","input":{}}]}]
    """#
    let edited = try #require(try detail(messages: written).pendingPlan)
    #expect(edited.filePath == "/u/.claude/plans/c.md")
    #expect(edited.text == "Plan ready.")

    let session = #","plan_file_path":"/u/.claude/plans/b.md""#
    #expect(try detail(messages: planning(), session: session).pendingPlan?.filePath == "/u/.claude/plans/b.md")

    // A Codex plan in text: no tool call, but Jean says the session waits on a plan.
    let text = #"[{"id":"m1","role":"assistant","content":"1. Do it","tool_calls":[]}]"#
    #expect(try detail(messages: text).pendingPlan == nil)
    #expect(try detail(messages: text, session: #","waiting_for_input_type":"plan""#).pendingPlan?.text == "1. Do it")
}

@Test func noPendingPlanOnceApprovedOrFollowedByAUserMessage() throws {
    #expect(try detail(messages: planning(), session: #","approved_plan_message_ids":["m2"]"#).pendingPlan == nil)
    #expect(try detail(messages: planning(extra: #","plan_approved":true"#)).pendingPlan == nil)

    let followed = planning().dropLast() + #","# + #"{"id":"m3","role":"user","content":"Go","tool_calls":[]}]"#
    #expect(try detail(messages: String(followed)).pendingPlan == nil)
    #expect(try detail(messages: "[]").pendingPlan == nil)
}

private func approval(backend: String = "claude", build: String = "{}", mcp: String? = nil) throws -> [PendingPlan.Request] {
    let plan = try #require(try detail(messages: planning()).pendingPlan)
    let prefs = try snakeCaseDecoder.decode(BuildPreferences.self, from: Data(build.utf8))
    return plan.approvalRequests(in: session, backend: backend, build: prefs, mcpConfig: mcp, chromeEnabled: true)
}

/// Args as JSON, the way the client sends them.
private func json(_ request: PendingPlan.Request) throws -> [String: Any] {
    try #require(JSONSerialization.jsonObject(with: JSONSerialization.data(withJSONObject: request.args)) as? [String: Any])
}

@Test func approvalMakesJeansRequestsInOrder() throws {
    let requests = try approval(mcp: #"{"mcpServers":{}}"#)
    #expect(requests.map(\.command) == [
        "mark_plan_approved", "update_session_state",
        "broadcast_session_setting", "broadcast_session_setting", "send_chat_message",
    ])

    let mark = try json(requests[0])
    #expect(mark as NSDictionary == ["sessionId": "s1", "worktreeId": "w1", "worktreePath": "/tmp/p", "messageId": "m2"])

    let update = try json(requests[1])
    #expect(update["waitingForInput"] as? Bool == false)
    #expect(update["waitingForInputType"] is NSNull)
    #expect(update["selectedExecutionMode"] as? String == "build")
    #expect(update["sessionId"] as? String == "s1")

    #expect(try json(requests[2]) as NSDictionary == ["sessionId": "s1", "key": "executionMode", "value": "build"])
    #expect(try json(requests[3]) as NSDictionary == ["sessionId": "s1", "key": "waitingForInput", "value": "false"])

    let send = try json(requests[4])
    #expect(send as NSDictionary == [
        "sessionId": "s1", "worktreeId": "w1", "worktreePath": "/tmp/p",
        "message": "Plan approved. Begin implementing the changes now. Do not re-explain the plan — start writing code.",
        "executionMode": "build", "chromeEnabled": true, "mcpConfig": #"{"mcpServers":{}}"#,
    ])
}

@Test func approvalUsesCodexWordsAndJeansBuildOverrides() throws {
    let codex = try json(try approval(backend: "codex").last!)
    #expect(codex["message"] as? String == "Execute the plan you created. Implement all changes described.")
    #expect(codex["mcpConfig"] == nil)

    let build = #"{"build_backend":"claude","build_model":"opus","build_thinking_level":"think","build_effort_level":"high"}"#
    let claude = try json(try approval(build: build).last!)
    #expect(claude["model"] as? String == "opus")
    #expect(claude["thinkingLevel"] as? String == "think")
    #expect(claude["effortLevel"] as? String == "high")

    // The overrides are for another backend: the session's own settings apply.
    let other = try json(try approval(backend: "codex", build: build).last!)
    #expect(other["model"] == nil && other["thinkingLevel"] == nil && other["effortLevel"] == nil)
}
