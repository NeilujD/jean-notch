import Foundation
import Testing
@testable import JeanNotchCore

@Test func cancelArgsNameTheSessionAndItsWorktree() throws {
    let json = #"""
    {"entries":[{"project_id":"p","project_name":"proj","worktree_id":"w1","worktree_name":"main","worktree_path":"/tmp/p","sessions":[{"id":"s1","name":"s1","updated_at":1763400000,"last_run_status":"running"}]}]}
    """#
    var board = SessionBoard()
    board.load(try snakeCaseDecoder.decode(AllSessionsResponse.self, from: Data(json.utf8)), requestedAt: Date())
    let session = try #require(board.sessions["s1"])
    #expect(session.cancelArgs as? [String: String] == ["sessionId": "s1", "worktreeId": "w1"])
}
