import Foundation

/// The fields of Jean's `PrStatus` (`pr:status-update` payload) that pick the badge.
public struct PrStatus: Equatable, Sendable {
    public let worktreeId: String
    public let number: Int?
    /// open, closed, merged.
    public let state: String
    /// approved, changes_requested, review_required, or nil.
    public let reviewDecision: String?
    /// success, failure, pending, error, or nil.
    public let checkStatus: String?

    public init(worktreeId: String, number: Int?, state: String, reviewDecision: String?, checkStatus: String?) {
        self.worktreeId = worktreeId
        self.number = number
        self.state = state
        self.reviewDecision = reviewDecision
        self.checkStatus = checkStatus
    }
}

/// The PR state Jean saved on a worktree (`list_worktrees`). Jean writes it at each PR check,
/// so JeanNotch can show a badge at start, before any `pr:status-update`.
public struct CachedWorktreePr: Decodable, Equatable, Sendable {
    public let id: String
    public let prNumber: Int?
    /// draft, open, review, merged, closed.
    public let cachedPrStatus: String?
    /// success, failure, pending, error.
    public let cachedCheckStatus: String?

    public init(id: String, prNumber: Int?, cachedPrStatus: String?, cachedCheckStatus: String?) {
        self.id = id
        self.prNumber = prNumber
        self.cachedPrStatus = cachedPrStatus
        self.cachedCheckStatus = cachedCheckStatus
    }

    /// Nil when the worktree has no PR or Jean has not checked it yet.
    /// The cache has no review decision, so it never gives "Changes requested".
    public var status: PrStatus? {
        guard prNumber != nil, let display = cachedPrStatus else { return nil }
        let state = switch display {
        case "merged", "closed": display
        default: "open"
        }
        return PrStatus(worktreeId: id, number: prNumber, state: state, reviewDecision: nil, checkStatus: cachedCheckStatus)
    }
}

/// One badge per worktree header: the state of its PR that matters most.
public struct PrBadge: Equatable, Sendable {
    public enum Kind: Equatable, Sendable {
        case ciFailing, changesRequested, ciRunning, ready, merged
    }

    public let kind: Kind
    public let number: Int?

    /// Nil when the PR is closed without a merge.
    public init?(_ status: PrStatus) {
        switch (status.state, status.checkStatus, status.reviewDecision) {
        case ("merged", _, _): kind = .merged
        case ("open", "failure", _), ("open", "error", _): kind = .ciFailing
        case ("open", _, "changes_requested"): kind = .changesRequested
        case ("open", "pending", _): kind = .ciRunning
        case ("open", _, _): kind = .ready
        default: return nil
        }
        number = status.number
    }

    /// "CI failing · #12"; a merged PR shows no number.
    public var label: String {
        let text = switch kind {
        case .ciFailing: "CI failing"
        case .changesRequested: "Changes requested"
        case .ciRunning: "CI running"
        case .ready: "Ready"
        case .merged: "Merged"
        }
        guard kind != .merged, let number else { return text }
        return "\(text) · #\(number)"
    }
}
