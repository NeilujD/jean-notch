import Foundation

/// Where and how to reach Jean's local WebSocket server.
/// `description` never includes the token, so the value is safe to log.
public struct ServerConfig: Equatable, Sendable, CustomStringConvertible {
    public let host: String
    public let port: Int
    public let token: String?

    public var webSocketURL: URL {
        let urlHost = host.contains(":") ? "[\(host)]" : host
        return URL(string: "ws://\(urlHost):\(port)/ws")!
    }

    public var description: String {
        "\(webSocketURL.absoluteString) (token \(token == nil ? "missing" : "set"))"
    }
}

public enum PreferencesError: Error, CustomStringConvertible {
    case unreadable(String)
    case nonLocalHost(String)

    public var description: String {
        switch self {
        case .unreadable(let reason): "Jean preferences unreadable: \(reason)"
        case .nonLocalHost(let host): "Jean binds to non-local host \(host); JeanNotch only connects to localhost"
        }
    }
}

/// Reads Jean's `preferences.json` (`http_server_port`, `http_server_token`, `http_server_bind_host`).
public enum Preferences {
    public static let defaultURL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/com.jean.desktop/preferences.json")

    public static func load(from url: URL = defaultURL) throws -> ServerConfig {
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            throw PreferencesError.unreadable(error.localizedDescription)
        }
        return try parse(data)
    }

    public static func parse(_ data: Data) throws -> ServerConfig {
        struct Raw: Decodable {
            let http_server_port: Int?
            let http_server_token: String?
            let http_server_bind_host: String?
        }
        let raw: Raw
        do {
            raw = try JSONDecoder().decode(Raw.self, from: data)
        } catch {
            throw PreferencesError.unreadable("invalid JSON")
        }
        let token = raw.http_server_token.flatMap { $0.isEmpty ? nil : $0 }
        return ServerConfig(
            host: try localHost(for: raw.http_server_bind_host),
            port: raw.http_server_port ?? 3456,
            token: token
        )
    }

    /// Loopback binds connect as-is; wildcard binds connect through 127.0.0.1;
    /// anything else is refused so the token never leaves this machine.
    static func localHost(for bindHost: String?) throws -> String {
        let host = (bindHost ?? "").trimmingCharacters(in: .whitespaces).lowercased()
        switch host {
        case "", "0.0.0.0", "::", "127.0.0.1", "localhost": return "127.0.0.1"
        case "::1": return "::1"
        default: throw PreferencesError.nonLocalHost(host)
        }
    }
}
