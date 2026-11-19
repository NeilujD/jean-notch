import Foundation

/// The MCP servers that Jean's window sends with a message (`mcpConfig` of `send_chat_message`).
/// Port of `resolveMcpConfigForSend` in Jean's src/services/mcp.ts:
/// the session's list, else the project's, else the global default; plus every server of a
/// backend that loads its servers itself; plus servers seen for the first time, unless the
/// session has its own list. A key is "backend:name", or a bare name from older versions.
public struct McpSelection: Equatable, Sendable {
    public let sessionEnabled: [String]?
    public let projectEnabled: [String]?
    public let globalEnabled: [String]
    public let known: [String]

    public init(sessionEnabled: [String]?, projectEnabled: [String]?, globalEnabled: [String], known: [String]) {
        self.sessionEnabled = sessionEnabled
        self.projectEnabled = projectEnabled
        self.globalEnabled = globalEnabled
        self.known = known
    }

    /// Backends whose CLI loads every enabled server from its own config (`isAutoLoadedMcpBackend`).
    static let autoLoadedBackends: Set<String> = ["antigravity", "muse"]

    private struct Server {
        let name: String
        let backend: String
        let disabled: Bool
        let config: Any
        var key: String { "\(backend):\(name)" }
    }

    /// `serversResponse` is the raw `get_mcp_servers` response message. Returns the
    /// `{"mcpServers": {...}}` JSON, or nil when no server is enabled (Jean then adds only its own).
    public func config(serversResponse raw: Data?, backend: String) -> String? {
        let servers = Self.servers(from: raw)
        var enabled = sessionEnabled ?? projectEnabled ?? globalEnabled
        for server in servers where Self.autoLoadedBackends.contains(server.backend) && !server.disabled {
            enabled.append(server.key)
        }
        enabled = enabled.reduce(into: []) { if !$0.contains($1) { $0.append($1) } }
        if sessionEnabled == nil {
            let skip = Set(enabled).union(known)
            enabled += servers.filter { !$0.disabled && !skip.contains($0.key) }.map(\.key)
        }

        var picked: [String: Any] = [:]
        for key in enabled {
            let (keyBackend, name) = key.firstIndex(of: ":").map {
                (String(key[..<$0]), String(key[key.index(after: $0)...]))
            } ?? ("", key)
            if !keyBackend.isEmpty, keyBackend != backend { continue }
            if let server = servers.first(where: { $0.name == name && $0.backend == backend }) {
                picked[name] = server.config
            }
        }
        guard !picked.isEmpty,
              let data = try? JSONSerialization.data(withJSONObject: ["mcpServers": picked], options: .sortedKeys)
        else { return nil }
        return String(decoding: data, as: UTF8.self)
    }

    /// Jean answers a failed discovery with no servers; so does this.
    private static func servers(from raw: Data?) -> [Server] {
        guard let raw,
              let message = try? JSONSerialization.jsonObject(with: raw) as? [String: Any],
              let list = message["data"] as? [[String: Any]]
        else { return [] }
        return list.compactMap { item in
            guard let name = item["name"] as? String, let backend = item["backend"] as? String,
                  let config = item["config"]
            else { return nil }
            return Server(name: name, backend: backend, disabled: item["disabled"] as? Bool ?? false, config: config)
        }
    }
}

// MARK: - Inputs, as Jean returns them

/// The MCP fields of `get_session`.
struct SessionMcp: Decodable {
    let enabledMcpServers: [String]?
    let backend: String?
}

/// The MCP fields of one `list_projects` item.
struct ProjectMcp: Decodable {
    let id: String
    let enabledMcpServers: [String]?
    /// Jean leaves the field out when the list is empty.
    let knownMcpServers: [String]?
}

/// The fields of `load_preferences` that a send needs.
struct PreferencesMcp: Decodable {
    let defaultEnabledMcpServers: [String]?
    let knownMcpServers: [String]?
    let defaultBackend: String?
    /// Jean's Chrome switch. Jean's window sends it with every message.
    let chromeEnabled: Bool?
}
