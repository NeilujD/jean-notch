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
