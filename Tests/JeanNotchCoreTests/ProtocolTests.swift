import Foundation
import Testing
@testable import JeanNotchCore

// Samples follow the shapes in Jean's jean-core/src/http_server/websocket.rs
// (envelope, heartbeat, InvokeResponse) and chat/*.rs event structs.

private func parse(_ json: String) throws -> ServerMessage {
    try ServerMessage.parse(Data(json.utf8))
}

private let ref = SessionRef(sessionId: "s1", worktreeId: "w1")

@Test func parsesChatDone() throws {
    let message = try parse(#"{"type":"event","event":"chat:done","payload":{"session_id":"s1","worktree_id":"w1","waiting_for_plan":true}}"#)
    #expect(message == .event(.done(ref, waitingForPlan: true)))
}

@Test func parsesToolUseAndIgnoresExtraFields() throws {
    let message = try parse(#"{"type":"event","event":"chat:tool_use","payload":{"session_id":"s1","worktree_id":"w1","id":"t1","name":"AskUserQuestion","input":{"questions":[]}}}"#)
    #expect(message == .event(.toolUse(ref, name: "AskUserQuestion")))
}

@Test func mapsApprovalEventsToWaitKinds() throws {
    let question = try parse(#"{"type":"event","event":"chat:codex_user_input_request","payload":{"session_id":"s1","worktree_id":"w1","request_id":"r"}}"#)
    let permission = try parse(#"{"type":"event","event":"chat:opencode_permission_request","payload":{"session_id":"s1","worktree_id":"w1"}}"#)
    #expect(question == .event(.approvalRequest(ref, .question)))
    #expect(permission == .event(.approvalRequest(ref, .permission)))
}

@Test func parsesResyncAndStructureEvents() throws {
    #expect(try parse(#"{"type":"event","event":"ws:resync","payload":{}}"#) == .event(.resync))
    #expect(try parse(#"{"type":"event","event":"session-renamed","payload":{"session_id":"s1"}}"#) == .event(.structureChanged))
    #expect(try parse(#"{"type":"event","event":"cache:invalidate","payload":{"keys":["sessions"]}}"#) == .event(.structureChanged))
    #expect(try parse(#"{"type":"event","event":"cache:invalidate","payload":{"keys":["preferences"]}}"#) == .event(nil))
}

@Test func dropsUnknownEventsAndEventsWithoutIds() throws {
    #expect(try parse(#"{"type":"event","event":"chat:chunk","payload":{"session_id":"s1","worktree_id":"w1","content":"x"}}"#) == .event(nil))
    #expect(try parse(#"{"type":"event","event":"chat:done","payload":{"session_id":"s1"}}"#) == .event(nil))
}

@Test func parsesHeartbeatResponseAndError() throws {
    #expect(try parse(#"{"type":"heartbeat","interval_ms":5000}"#) == .heartbeat)
    let raw = #"{"type":"response","id":"abc","data":null}"#
    #expect(try parse(raw) == .response(id: "abc", raw: Data(raw.utf8)))
    #expect(try parse(#"{"type":"error","id":"abc","error":"boom"}"#) == .error(id: "abc", message: "boom"))
}

@Test func decodesAllSessionsSnapshot() throws {
    let raw = Data(#"""
    {"type":"response","id":"1","data":{"entries":[{
      "project_id":"p1","project_name":"jean","worktree_id":"w1","worktree_name":"main","worktree_path":"/tmp/jean",
      "sessions":[
        {"id":"a","name":"Plan","updated_at":1763400000,"last_run_status":"completed","waiting_for_input":true,"waiting_for_input_type":"plan"},
        {"id":"b","name":"Codex","updated_at":1763400000,"pending_codex_permission_requests":[{"rpc_id":1}]},
        {"id":"c","name":"Old","updated_at":1763400000,"archived_at":1763400100},
        {"id":"d","name":"Run","updated_at":1763400000,"last_run_status":"running","pending_permission_denials":[]}
      ]}]}}
    """#.utf8)
    let snapshot = try ServerMessage.decodeData(AllSessionsResponse.self, from: raw)
    let sessions = snapshot.entries[0].sessions
    #expect(snapshot.entries[0].worktreePath == "/tmp/jean")
    #expect(sessions.map(\.id) == ["a", "b", "c", "d"])
    #expect(sessions[0].waitingForInputType == "plan")
    #expect(sessions[1].hasPendingApproval)
    #expect(sessions[2].archivedAt == 1763400100)
    #expect(!sessions[3].hasPendingApproval)
    #expect(sessions[3].lastRunStatus == "running")
}

@Test func preferencesReadPortAndTokenAndRefuseRemoteHosts() throws {
    let config = try Preferences.parse(Data(#"{"http_server_port":4000,"http_server_token":"secret","http_server_bind_host":"0.0.0.0"}"#.utf8))
    #expect(config.webSocketURL.absoluteString == "ws://127.0.0.1:4000/ws")
    #expect(config.token == "secret")
    #expect(!config.description.contains("secret"))
    #expect(throws: PreferencesError.self) {
        try Preferences.parse(Data(#"{"http_server_bind_host":"192.168.1.5"}"#.utf8))
    }
}

@Test func decodesSessionTokenUsage() throws {
    let raw = Data(#"{"type":"response","id":"1","data":{"app_data_dir":"/x","run_log_files":[],"total_usage":{"input_tokens":82,"output_tokens":22012,"cache_read_input_tokens":3109257,"cache_creation_input_tokens":98820}}}"#.utf8)
    let info = try ServerMessage.decodeData(SessionDebugInfo.self, from: raw)
    #expect(info.totalUsage == TokenUsage(input: 82, output: 22012, cacheRead: 3_109_257, cacheCreation: 98820))
    #expect(info.totalUsage.total == 3_230_171)
}

@Test func formatsTokenCountsCompactly() {
    #expect(TokenUsage.format(950) == "950")
    #expect(TokenUsage.format(9_999) == "9.9k")
    #expect(TokenUsage.format(12_400) == "12k")
    #expect(TokenUsage.format(3_230_171) == "3.2M")
    #expect(TokenUsage.format(42_090_055) == "42M")
}
