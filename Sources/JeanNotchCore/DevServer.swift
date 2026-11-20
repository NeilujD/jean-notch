import Foundation

// Shapes from Jean's `get_run_environments` (camelCase on the wire).

public struct RunEnvironmentsResponse: Decodable, Equatable, Sendable {
    public let environments: [RunEnvironment]
}

public struct RunEnvironment: Decodable, Equatable, Sendable {
    public let running: Bool
    public let worktreeName: String?
    public let projectName: String?
    public let isBaseSession: Bool?
    public let ports: [Port]?
    public let url: String?

    public struct Port: Decodable, Equatable, Sendable {
        public let port: Int
        public let url: String?
    }
}

/// One port of a running dev server, as the notch footer shows it: "web :5173".
public struct DevServer: Equatable, Hashable, Sendable {
    public let label: String
    public let url: URL

    /// One entry per port of each running environment. A port without an http(s) URL is
    /// left out: the footer only opens web pages.
    public static func list(from response: RunEnvironmentsResponse) -> [DevServer] {
        response.environments.filter(\.running).flatMap { env -> [DevServer] in
            let name = (env.isBaseSession == true ? env.projectName : env.worktreeName)
                ?? env.worktreeName ?? env.projectName ?? "dev"
            let ports = env.ports ?? []
            if ports.isEmpty {
                guard let url = webURL(env.url) else { return [] }
                return [DevServer(label: url.port.map { "\(name) :\($0)" } ?? name, url: url)]
            }
            return ports.compactMap { port in
                webURL(port.url ?? env.url).map { DevServer(label: "\(name) :\(port.port)", url: $0) }
            }
        }
    }

    private static func webURL(_ string: String?) -> URL? {
        guard let string, let url = URL(string: string), ["http", "https"].contains(url.scheme?.lowercased()) else {
            return nil
        }
        return url
    }
}
