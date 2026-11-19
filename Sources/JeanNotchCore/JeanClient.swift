import Foundation
import os

let log = Logger(subsystem: "build.jean.notch", category: "client")

public enum ClientEvent: Sendable {
    case connected
    case disconnected(reason: String)
    case event(JeanEvent)
}

public enum ClientError: Error, CustomStringConvertible {
    case notConnected
    case server(String)

    public var description: String {
        switch self {
        case .notConnected: "not connected"
        case .server(let message): "server error: \(message)"
        }
    }
}

/// WebSocket client for Jean's built-in server: connect, reconnect with backoff,
/// request/response by id, and a stream of parsed events.
public actor JeanClient {
    public nonisolated let events: AsyncStream<ClientEvent>
    private let continuation: AsyncStream<ClientEvent>.Continuation
    private let loadConfig: @Sendable () throws -> ServerConfig
    private let session = URLSession(configuration: .ephemeral)
    private var task: URLSessionWebSocketTask?
    private var pending: [String: CheckedContinuation<Data, Error>] = [:]
    private var lastInbound = Date()

    /// `loadConfig` runs before every connection attempt, so a changed port or
    /// rotated token is picked up on the next reconnect.
    public init(loadConfig: @escaping @Sendable () throws -> ServerConfig = { try Preferences.load() }) {
        self.loadConfig = loadConfig
        (events, continuation) = AsyncStream.makeStream(of: ClientEvent.self)
    }

    /// Runs the connect/reconnect loop until the surrounding task is cancelled.
    public func run() async {
        var attempt = 0
        while !Task.isCancelled {
            let reason = await connectOnce(onOpen: { attempt = 0 })
            log.info("Disconnected: \(reason, privacy: .public)")
            continuation.yield(.disconnected(reason: reason))
            let delay = min(30.0, pow(2.0, Double(attempt)))
            attempt += 1
            try? await Task.sleep(for: .seconds(delay))
        }
    }

    /// Opens one connection and returns why it ended.
    private func connectOnce(onOpen: () -> Void) async -> String {
        let config: ServerConfig
        do {
            config = try loadConfig()
        } catch {
            return String(describing: error)
        }
        var request = URLRequest(url: config.webSocketURL)
        if let token = config.token {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        let task = session.webSocketTask(with: request)
        task.maximumMessageSize = 64 * 1024 * 1024
        self.task = task
        task.resume()
        defer {
            task.cancel(with: .goingAway, reason: nil)
            self.task = nil
            failPending(ClientError.notConnected)
        }

        do {
            try await ping(task)
        } catch {
            let status = (task.response as? HTTPURLResponse)?.statusCode
            if status == 401 || status == 403 {
                return "auth rejected (HTTP \(status!)); preferences are re-read on retry"
            }
            return "cannot reach \(config.webSocketURL.absoluteString): \(error.localizedDescription)"
        }

        log.info("Connected to \(config.description, privacy: .public)")
        onOpen()
        lastInbound = Date()
        continuation.yield(.connected)

        let watchdog = Task { await self.watch(task) }
        defer { watchdog.cancel() }
        do {
            while true {
                let message = try await task.receive()
                lastInbound = Date()
                handle(message)
            }
        } catch {
            return "connection lost: \(error.localizedDescription)"
        }
    }

    /// Jean sends a heartbeat every 5 s. Drop the socket after 20 s of silence;
    /// ping meanwhile so the server's 45 s idle check sees inbound traffic.
    private func watch(_ task: URLSessionWebSocketTask) async {
        while !Task.isCancelled {
            try? await Task.sleep(for: .seconds(10))
            if Date().timeIntervalSince(lastInbound) > 20 {
                log.warning("No traffic for 20 s, reconnecting")
                task.cancel(with: .goingAway, reason: nil)
                return
            }
            task.sendPing { _ in }
        }
    }

    private func ping(_ task: URLSessionWebSocketTask) async throws {
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
            task.sendPing { error in
                if let error { c.resume(throwing: error) } else { c.resume() }
            }
        }
    }

    private func handle(_ message: URLSessionWebSocketTask.Message) {
        let data: Data
        switch message {
        case .string(let text): data = Data(text.utf8)
        case .data(let bytes): data = bytes
        @unknown default: return
        }
        guard let parsed = try? ServerMessage.parse(data) else {
            log.debug("Unparseable message (\(data.count) bytes)")
            return
        }
        switch parsed {
        case .event(let event?):
            continuation.yield(.event(event))
        case .response(let id, let raw):
            pending.removeValue(forKey: id)?.resume(returning: raw)
        case .error(let id, let message):
            pending.removeValue(forKey: id)?.resume(throwing: ClientError.server(message))
        case .event(nil), .heartbeat, .unknown:
            break
        }
    }

    /// Sends `{"type":"invoke"}` and returns the raw response message; decode it
    /// with `ServerMessage.decodeData`.
    public func invoke(_ command: String, args: [String: any Sendable] = [:]) async throws -> Data {
        guard let task else { throw ClientError.notConnected }
        let id = UUID().uuidString
        let body = try JSONSerialization.data(withJSONObject: [
            "type": "invoke", "id": id, "command": command, "args": args,
        ] as [String: Any])
        let text = String(decoding: body, as: UTF8.self)
        return try await withCheckedThrowingContinuation { c in
            pending[id] = c
            Task {
                do {
                    try await task.send(.string(text))
                } catch {
                    self.fail(id, error)
                }
            }
        }
    }

    private func fail(_ id: String, _ error: Error) {
        pending.removeValue(forKey: id)?.resume(throwing: error)
    }

    private func failPending(_ error: Error) {
        let waiting = pending
        pending = [:]
        for c in waiting.values { c.resume(throwing: error) }
    }
}
