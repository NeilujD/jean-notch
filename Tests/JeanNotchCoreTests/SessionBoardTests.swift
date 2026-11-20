import Foundation
import Testing
@testable import JeanNotchCore

private let t0 = Date(timeIntervalSince1970: 1_763_400_000)

private func snapshot(_ sessions: [(id: String, json: String)], worktree: String = "w1") throws -> AllSessionsResponse {
    let list = sessions.map { #"{"id":"\#($0.id)","name":"\#($0.id)","updated_at":1763400000\#($0.json)}"# }
    let json = #"""
    {"entries":[{"project_id":"p","project_name":"proj","worktree_id":"\#(worktree)","worktree_name":"main","worktree_path":"/tmp/p","sessions":[\#(list.joined(separator: ","))]}]}
    """#
    return try snakeCaseDecoder.decode(AllSessionsResponse.self, from: Data(json.utf8))
}

private func ref(_ id: String) -> SessionRef { SessionRef(sessionId: id, worktreeId: "w1") }

private func board(_ ids: String...) throws -> SessionBoard {
    var board = SessionBoard()
    board.load(try snapshot(ids.map { ($0, "") }), requestedAt: t0)
    return board
}

@Test func snapshotMapsStatusesAndSkipsArchived() throws {
    var board = SessionBoard()
    board.load(try snapshot([
        ("q", #","waiting_for_input":true,"waiting_for_input_type":"question""#),
        ("r", #","last_run_status":"running""#),
        ("x", #","last_run_status":"crashed""#),
        ("p", #","pending_permission_denials":[{"tool_name":"Bash"}]"#),
        ("i", #","last_run_status":"completed""#),
        ("a", #","archived_at":1"#),
    ]), requestedAt: t0)
    #expect(board.sessions["q"]?.status == .waiting(.question))
    #expect(board.sessions["r"]?.status == .running)
    #expect(board.sessions["x"]?.status == .failed)
    #expect(board.sessions["p"]?.status == .waiting(.permission))
    #expect(board.sessions["i"]?.status == .idle)
    #expect(board.sessions["a"] == nil)
}

@Test func runThenDoneAlertsAndStaysUnseenUntilSeen() throws {
    var board = try board("s")
    #expect(board.apply(.sending(ref("s")), now: t0).alert == nil)
    #expect(board.sessions["s"]?.status == .running)
    #expect(board.runningCount == 1)

    let result = board.apply(.done(ref("s"), waitingForPlan: false), now: t0)
    #expect(result.alert?.status == .done)
    #expect(board.sessions["s"]?.unseen == true)
    #expect(board.mostUrgent == .done)
    #expect(board.visibleGroups.count == 1)

    board.markSeen("s")
    #expect(board.mostUrgent == nil)
    #expect(board.visibleGroups.isEmpty)
}

@Test func doneWithPlanWaits() throws {
    var board = try board("s")
    _ = board.apply(.sending(ref("s")), now: t0)
    let result = board.apply(.done(ref("s"), waitingForPlan: true), now: t0)
    #expect(result.alert?.status == .waiting(.plan))
}

@Test func claudeBlockingToolSurvivesDone() throws {
    var board = try board("s")
    _ = board.apply(.sending(ref("s")), now: t0)
    let ask = board.apply(.toolUse(ref("s"), name: "AskUserQuestion"), now: t0)
    #expect(ask.alert?.status == .waiting(.question))
    // Same status: no second alert, and done keeps the wait.
    #expect(board.apply(.done(ref("s"), waitingForPlan: false), now: t0).alert == nil)
    #expect(board.sessions["s"]?.status == .waiting(.question))
    // Next send clears it.
    _ = board.apply(.sending(ref("s")), now: t0)
    #expect(board.sessions["s"]?.status == .running)
}

@Test func permissionDeniedSurvivesDone() throws {
    var board = try board("s")
    _ = board.apply(.sending(ref("s")), now: t0)
    _ = board.apply(.permissionDenied(ref("s")), now: t0)
    _ = board.apply(.done(ref("s"), waitingForPlan: false), now: t0)
    #expect(board.sessions["s"]?.status == .waiting(.permission))
}

@Test func midRunApprovalResumesOnNextTool() throws {
    var board = try board("s")
    _ = board.apply(.sending(ref("s")), now: t0)
    _ = board.apply(.approvalRequest(ref("s"), .permission), now: t0)
    #expect(board.mostUrgent == .waiting)
    _ = board.apply(.toolUse(ref("s"), name: "Bash"), now: t0)
    #expect(board.sessions["s"]?.status == .running)
}

@Test func errorAndCancel() throws {
    var board = try board("a", "b")
    _ = board.apply(.sending(ref("a")), now: t0)
    #expect(board.apply(.failed(ref("a")), now: t0).alert?.status == .failed)
    #expect(board.mostUrgent == .failed)
    _ = board.apply(.sending(ref("b")), now: t0)
    #expect(board.apply(.cancelled(ref("b")), now: t0).alert == nil)
    #expect(board.sessions["b"]?.status == .idle)
}

@Test func unknownSessionAsksForSnapshot() throws {
    var board = try board("s")
    let result = board.apply(.sending(ref("new")), now: t0)
    #expect(result.needsSnapshot)
    #expect(board.sessions["new"]?.status == .running)
    #expect(board.sessions["new"]?.projectName == "proj")
    #expect(board.apply(.resync, now: t0).needsSnapshot)
}

@Test func sortsByUrgencyThenRecency() throws {
    var board = try board("run", "done", "fail", "wait", "idle")
    _ = board.apply(.sending(ref("done")), now: t0)
    _ = board.apply(.done(ref("done"), waitingForPlan: false), now: t0.addingTimeInterval(4))
    _ = board.apply(.sending(ref("run")), now: t0.addingTimeInterval(5))
    _ = board.apply(.sending(ref("fail")), now: t0)
    _ = board.apply(.failed(ref("fail")), now: t0.addingTimeInterval(1))
    _ = board.apply(.approvalRequest(ref("wait"), .question), now: t0)
    #expect(board.visibleGroups.first?.sessions.map(\.id) == ["wait", "fail", "run", "done"])
}

@Test func groupsSortByTheirMostUrgentSession() throws {
    var board = SessionBoard()
    var entries = try snapshot([("a", "")], worktree: "w1").entries
    entries += try snapshot([("b", "")], worktree: "w2").entries
    board.load(AllSessionsResponse(entries: entries), requestedAt: t0)
    _ = board.apply(.sending(SessionRef(sessionId: "a", worktreeId: "w1")), now: t0)
    _ = board.apply(.approvalRequest(SessionRef(sessionId: "b", worktreeId: "w2"), .plan), now: t0)
    #expect(board.visibleGroups.map(\.worktreeId) == ["w2", "w1"])
}

@Test func snapshotKeepsUnseenResultAndNewerLiveState() throws {
    var board = try board("done", "live")
    _ = board.apply(.sending(ref("done")), now: t0)
    _ = board.apply(.done(ref("done"), waitingForPlan: false), now: t0)
    // An event that raced the in-flight snapshot request.
    let requestedAt = t0.addingTimeInterval(10)
    _ = board.apply(.sending(ref("live")), now: t0.addingTimeInterval(11))

    board.load(try snapshot([("done", #","last_run_status":"completed""#), ("live", "")]), requestedAt: requestedAt)
    #expect(board.sessions["done"]?.status == .done)
    #expect(board.sessions["done"]?.unseen == true)
    #expect(board.sessions["live"]?.status == .running)
}

@Test func snapshotOverridesStaleLiveState() throws {
    var board = try board("s")
    _ = board.apply(.sending(ref("s")), now: t0)
    board.load(try snapshot([("s", #","last_run_status":"completed""#)]), requestedAt: t0.addingTimeInterval(60))
    #expect(board.sessions["s"]?.status == .idle)
    #expect(board.runningCount == 0)
}

@Test func textQuestionWaitSurvivesSnapshotsUntilTheNextRun() throws {
    var board = try board("s")
    _ = board.apply(.sending(ref("s")), now: t0)
    _ = board.apply(.done(ref("s"), waitingForPlan: false), now: t0)
    board.markAsking("s")
    #expect(board.sessions["s"]?.status == .waiting(.question))
    #expect(board.mostUrgent == .waiting)

    board.markSeen("s")
    board.load(try snapshot([("s", #","last_run_status":"completed""#)]), requestedAt: t0.addingTimeInterval(60))
    #expect(board.sessions["s"]?.status == .waiting(.question))

    _ = board.apply(.sending(ref("s")), now: t0.addingTimeInterval(61))
    _ = board.apply(.done(ref("s"), waitingForPlan: false), now: t0.addingTimeInterval(62))
    board.markSeen("s")
    board.load(try snapshot([("s", #","last_run_status":"completed""#)]), requestedAt: t0.addingTimeInterval(120))
    #expect(board.sessions["s"]?.status == .idle)
}

@Test func clearAskingEndsOnlyATextQuestionWait() throws {
    var board = try board("text", "tool", "idle")
    for id in ["text", "tool"] { _ = board.apply(.sending(ref(id)), now: t0) }
    _ = board.apply(.done(ref("text"), waitingForPlan: false), now: t0)
    _ = board.apply(.toolUse(ref("tool"), name: "AskUserQuestion"), now: t0)
    for id in ["text", "tool", "idle"] { board.markAsking(id) }
    #expect(board.sessions["idle"]?.status == .idle)

    for id in ["text", "tool"] { board.clearAsking(id) }
    #expect(board.sessions["text"]?.status == .done)
    #expect(board.sessions["text"]?.unseen == true)
    #expect(board.sessions["tool"]?.status == .waiting(.question))
}

private func pr(_ state: String, check: String? = nil, review: String? = nil) -> PrStatus {
    PrStatus(worktreeId: "w1", number: 12, state: state, reviewDecision: review, checkStatus: check)
}

@Test func mapsEachPrStateToOneBadge() {
    #expect(PrBadge(pr("merged", check: "failure"))?.kind == .merged)
    #expect(PrBadge(pr("open", check: "failure", review: "changes_requested"))?.kind == .ciFailing)
    #expect(PrBadge(pr("open", check: "error"))?.kind == .ciFailing)
    #expect(PrBadge(pr("open", check: "pending", review: "changes_requested"))?.kind == .changesRequested)
    #expect(PrBadge(pr("open", check: "pending"))?.kind == .ciRunning)
    #expect(PrBadge(pr("open", check: "success", review: "approved"))?.kind == .ready)
    #expect(PrBadge(pr("open"))?.kind == .ready)
    #expect(PrBadge(pr("closed", check: "failure")) == nil)
    #expect(PrBadge(pr("open", check: "failure"))?.label == "CI failing · #12")
    #expect(PrBadge(pr("merged"))?.label == "Merged")
}

@Test func prStatusUpdateReplacesTheWorktreeBadgeWithoutAlert() throws {
    var board = try board("a")
    let before = board.sessions
    let first = board.apply(.prStatus(pr("open", check: "pending")), now: t0)
    #expect(first == SessionBoard.ApplyResult())
    #expect(board.prBadges["w1"]?.kind == .ciRunning)
    _ = board.apply(.prStatus(pr("open", check: "success")), now: t0)
    #expect(board.prBadges["w1"]?.kind == .ready)
    _ = board.apply(.prStatus(pr("closed")), now: t0)
    #expect(board.prBadges["w1"] == nil)
    #expect(board.sessions == before)
}
