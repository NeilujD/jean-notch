import Foundation

// Shapes from Jean's claude_cli/codex_cli/grok_cli `*UsageSnapshot` (camelCase on the wire).

/// Agent providers whose plan limits Jean can read. Order is display order.
public enum UsageProvider: String, CaseIterable, Sendable {
    case claude, codex, grok

    public var name: String {
        switch self {
        case .claude: "Claude"
        case .codex: "Codex"
        case .grok: "Grok"
        }
    }

    /// Jean answers from a 5-minute cache, so polling it is cheap.
    public var command: String { "get_\(rawValue)_usage" }
}

public struct UsageWindow: Decodable, Equatable, Sendable {
    public let usedPercent: Double
    /// Unix seconds.
    public let resetsAt: UInt64?
    public let limitWindowSeconds: UInt64?

    public init(usedPercent: Double, resetsAt: UInt64? = nil, limitWindowSeconds: UInt64? = nil) {
        self.usedPercent = usedPercent
        self.resetsAt = resetsAt
        self.limitWindowSeconds = limitWindowSeconds
    }
}

public struct ProviderUsage: Decodable, Equatable, Sendable {
    public let session: UsageWindow?
    public let weekly: UsageWindow?
    /// Claude only.
    public let sonnetWeekly: UsageWindow?

    public struct Limit: Equatable, Sendable {
        public let label: String
        public let window: UsageWindow
    }

    /// Claude's session window is 5 hours; Codex and Grok send the length.
    public func limits(for provider: UsageProvider) -> [Limit] {
        let sessionLabel = session?.limitWindowSeconds.map(Self.length) ?? (provider == .claude ? "5h" : "session")
        return [
            session.map { Limit(label: sessionLabel, window: $0) },
            weekly.map { Limit(label: "week", window: $0) },
            sonnetWeekly.map { Limit(label: "Sonnet week", window: $0) },
        ].compactMap { $0 }
    }

    /// Percent used of the tightest window.
    public var peakPercent: Double {
        [session, weekly, sonnetWeekly].compactMap { $0?.usedPercent }.max() ?? 0
    }

    static func length(_ seconds: UInt64) -> String {
        switch seconds {
        case 604_800: "week"
        case ..<86_400: "\(seconds / 3600)h"
        default: "\(seconds / 86_400)d"
        }
    }

    /// Time left until `resetsAt`: "42m", "4h55", "5d".
    public static func timeLeft(until resetsAt: UInt64, now: Date) -> String {
        let seconds = max(0, Int(resetsAt) - Int(now.timeIntervalSince1970))
        switch seconds {
        case ..<3600: return "\(seconds / 60)m"
        case ..<86_400: return String(format: "%dh%02d", seconds / 3600, seconds % 3600 / 60)
        default: return "\(seconds / 86_400)d"
        }
    }
}
