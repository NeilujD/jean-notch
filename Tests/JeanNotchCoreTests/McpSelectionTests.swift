import Foundation
import Testing
@testable import JeanNotchCore

// Rules from `resolveMcpConfigForSend` and `buildMcpConfigJson` in Jean's src/services/mcp.ts.
// Servers follow the `get_mcp_servers` response: `McpServerInfo { name, config, scope, disabled, backend }`.

private let servers = Data(#"""
{"type":"response","id":"1","data":[
  {"name":"github","backend":"claude","scope":"user","disabled":false,"config":{"type":"http","url":"https://gh.example"}},
  {"name":"slack","backend":"claude","scope":"user","disabled":false,"config":{"command":"slack-mcp"}},
  {"name":"old","backend":"claude","scope":"user","disabled":true,"config":{"command":"old-mcp"}},
  {"name":"github","backend":"codex","scope":"user","disabled":false,"config":{"command":"codex-gh"}}
]}
"""#.utf8)

private func names(_ config: String?) throws -> [String: String] {
    let json = try #require(config.flatMap { try JSONSerialization.jsonObject(with: Data($0.utf8)) } as? [String: [String: [String: Any]]])
    let picked = try #require(json["mcpServers"])
    return picked.mapValues { ($0["url"] ?? $0["command"]) as? String ?? "?" }
}

@Test func sessionListWinsAndStopsAutoEnable() throws {
    let selection = McpSelection(sessionEnabled: ["claude:slack"], projectEnabled: ["claude:github"], globalEnabled: ["claude:github"], known: [])
    #expect(try names(selection.config(serversResponse: servers, backend: "claude")) == ["slack": "slack-mcp"])

    let emptySession = McpSelection(sessionEnabled: [], projectEnabled: ["claude:github"], globalEnabled: [], known: [])
    #expect(emptySession.config(serversResponse: servers, backend: "claude") == nil)
}

@Test func projectListWinsOverGlobalAndNewServersAreAdded() throws {
    let project = McpSelection(sessionEnabled: nil, projectEnabled: ["claude:github"], globalEnabled: ["claude:slack"], known: ["claude:slack", "claude:old"])
    #expect(try names(project.config(serversResponse: servers, backend: "claude")) == ["github": "https://gh.example"])

    let unknownSlack = McpSelection(sessionEnabled: nil, projectEnabled: nil, globalEnabled: ["claude:github"], known: ["claude:github"])
    #expect(try names(unknownSlack.config(serversResponse: servers, backend: "claude")) == ["github": "https://gh.example", "slack": "slack-mcp"])
}

@Test func keepsOnlyServersOfTheSessionBackend() throws {
    let selection = McpSelection(sessionEnabled: ["codex:github", "github", "claude:old"], projectEnabled: nil, globalEnabled: [], known: [])
    #expect(try names(selection.config(serversResponse: servers, backend: "codex")) == ["github": "codex-gh"])
    #expect(try names(selection.config(serversResponse: servers, backend: "claude")) == ["github": "https://gh.example", "old": "old-mcp"])
}

@Test func addsServersOfAutoLoadedBackendsAndToleratesFailedDiscovery() throws {
    let muse = Data(#"{"type":"response","id":"1","data":[{"name":"docs","backend":"muse","disabled":false,"config":{"command":"docs-mcp"}}]}"#.utf8)
    let selection = McpSelection(sessionEnabled: [], projectEnabled: nil, globalEnabled: [], known: [])
    #expect(try names(selection.config(serversResponse: muse, backend: "muse")) == ["docs": "docs-mcp"])

    let global = McpSelection(sessionEnabled: nil, projectEnabled: nil, globalEnabled: ["claude:github"], known: [])
    #expect(global.config(serversResponse: nil, backend: "claude") == nil)
}
