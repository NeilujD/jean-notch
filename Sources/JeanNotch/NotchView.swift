import JeanNotchCore
import SwiftUI

struct NotchActions {
    var open: (SessionState) -> Void
    var showMenu: () -> Void
    var sizeChanged: (CGSize) -> Void
}

struct NotchView: View {
    let store: SessionStore
    let panel: PanelState
    let actions: NotchActions
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @AppStorage(TokenWarning.key) private var tokenWarning = TokenWarning.defaultLimit

    private let side: CGFloat = 44
    private let expandedWidth: CGFloat = 400
    private let maxRows = 12

    var body: some View {
        content
            .fixedSize(horizontal: false, vertical: true)
            .onGeometryChange(for: CGSize.self, of: \.size) { actions.sizeChanged($0) }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .environment(\.colorScheme, .dark)
    }

    private var content: some View {
        VStack(spacing: 0) {
            if panel.expanded {
                header
                list.padding(.horizontal, 14).padding(.bottom, 12)
                    .transition(reduceMotion ? .opacity : .opacity.combined(with: .move(edge: .top)))
            } else {
                collapsed.transition(.opacity)
            }
        }
        .frame(width: width)
        .background(NotchShape(radius: panel.expanded ? 18 : 8).fill(.black))
        .overlay {
            if let start = panel.celebration, panel.expanded, !reduceMotion {
                ConfettiView(start: start)
            }
        }
        .clipShape(NotchShape(radius: panel.expanded ? 18 : 8))
        .animation(morph, value: panel.expanded)
        .animation(morph, value: width)
    }

    private var morph: Animation {
        reduceMotion ? .easeInOut(duration: 0.15) : .spring(response: 0.38, dampingFraction: 0.8)
    }

    private var mood: MascotMood {
        MascotMood(connection: store.connection, board: store.board)
    }

    private var width: CGFloat {
        let notch = panel.geometry.width
        if panel.expanded { return max(expandedWidth, notch + 2 * side) }
        if !panel.geometry.hasNotch { return 2 * side + 8 }
        return hasIndicators ? notch + 2 * side : notch
    }

    private var hasIndicators: Bool {
        store.board.runningCount > 0 || store.board.mostUrgent != nil || store.connection != .online
    }

    // MARK: Collapsed

    private var collapsed: some View {
        HStack(spacing: 0) {
            runningIndicator.frame(width: side)
            Spacer(minLength: 0)
            urgencyIndicator.frame(width: side)
        }
        .frame(height: panel.geometry.height)
    }

    @ViewBuilder private var runningIndicator: some View {
        if hasIndicators {
            HStack(spacing: 3) {
                MascotView(mood: mood)
                let count = store.board.runningCount
                if count > 0 {
                    Text("\(count)").font(.system(size: 10, weight: .semibold).monospacedDigit())
                        .foregroundStyle(.white)
                        .contentTransition(.numericText())
                        .animation(morph, value: count)
                }
            }
        }
    }

    @ViewBuilder private var urgencyIndicator: some View {
        if store.connection != .online {
            Image(systemName: "bolt.slash.fill").font(.system(size: 9)).foregroundStyle(.gray)
        } else if let urgency = store.board.mostUrgent {
            Circle().fill(urgency.color).frame(width: 7, height: 7)
        }
    }

    // MARK: Expanded

    /// One slot each side of the hardware notch, so no text sits under it.
    private var header: some View {
        HStack(spacing: 0) {
            HStack(spacing: 6) {
                MascotView(mood: mood, pixel: 2, lively: true)
                Text("Jean")
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Color.clear.frame(width: panel.geometry.width + 12)
            HStack(spacing: 6) {
                Text(statusLine).lineLimit(1)
                Button(action: actions.showMenu) {
                    Image(systemName: "gearshape.fill").font(.system(size: 11))
                }
                .buttonStyle(.plain)
            }
            .frame(maxWidth: .infinity, alignment: .trailing)
        }
        .font(.system(size: 11, weight: .medium))
        .foregroundStyle(.secondary)
        .padding(.horizontal, 14)
        .frame(height: max(panel.geometry.height, 28))
    }

    private var statusLine: String {
        switch store.connection {
        case .connecting: "Connecting"
        case .offline: "Offline"
        case .online:
            store.board.runningCount == 0 ? "" : "\(store.board.runningCount) running"
        }
    }

    @ViewBuilder private var list: some View {
        if case .offline(let reason) = store.connection {
            Text(reason).font(.caption).foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            let groups = store.board.visibleGroups
            if groups.isEmpty {
                Text("No active sessions").font(.caption).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                TimelineView(.periodic(from: .now, by: 30)) { context in
                    rows(groups, now: context.date)
                }
            }
        }
    }

    private func rows(_ groups: [WorktreeGroup], now: Date) -> some View {
        let shown = Self.limit(groups, to: maxRows)
        let hidden = groups.reduce(0) { $0 + $1.sessions.count } - shown.reduce(0) { $0 + $1.sessions.count }
        return VStack(alignment: .leading, spacing: 8) {
            ForEach(shown) { group in
                VStack(alignment: .leading, spacing: 2) {
                    Text("\(group.projectName) › \(group.worktreeName)")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    ForEach(group.sessions) { session in
                        SessionRow(
                            session: session, tokens: store.tokens[session.id], tokenLimit: tokenWarning, now: now
                        ) { actions.open(session) }
                    }
                }
            }
            if hidden > 0 {
                Text("+\(hidden) more").font(.caption2).foregroundStyle(.secondary)
            }
        }
    }

    /// First `limit` sessions in board order, keeping their groups.
    static func limit(_ groups: [WorktreeGroup], to limit: Int) -> [WorktreeGroup] {
        var left = limit
        var result: [WorktreeGroup] = []
        for group in groups where left > 0 {
            let sessions = Array(group.sessions.prefix(left))
            left -= sessions.count
            result.append(WorktreeGroup(
                worktreeId: group.worktreeId, projectName: group.projectName,
                worktreeName: group.worktreeName, sessions: sessions
            ))
        }
        return result
    }
}

private struct SessionRow: View {
    let session: SessionState
    let tokens: TokenUsage?
    let tokenLimit: Int
    let now: Date
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                StatusBadge(session: session)
                Text(session.name).font(.system(size: 12)).lineLimit(1).truncationMode(.tail)
                Spacer(minLength: 4)
                if let tokens, tokens.total > 0 {
                    TokenCount(total: tokens.total, limit: tokenLimit)
                }
                Text(Self.age(from: session.changedAt, to: now))
                    .font(.system(size: 10).monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            .padding(.vertical, 3)
            .padding(.horizontal, 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(.white)
    }

    static func age(from date: Date, to now: Date) -> String {
        let seconds = max(0, Int(now.timeIntervalSince(date)))
        switch seconds {
        case ..<60: return "now"
        case ..<3600: return "\(seconds / 60)m"
        case ..<86400: return "\(seconds / 3600)h"
        default: return "\(seconds / 86400)d"
        }
    }
}

private struct TokenCount: View {
    let total: UInt64
    let limit: Int

    private var over: Bool { limit > 0 && total > UInt64(limit) }

    var body: some View {
        HStack(spacing: 2) {
            if over {
                Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 8))
            }
            Text("\(TokenUsage.format(total)) tokens").font(.system(size: 10).monospacedDigit())
        }
        .foregroundStyle(over ? AnyShapeStyle(.orange) : AnyShapeStyle(.secondary))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(over ? "\(total) tokens, over the warning limit" : "\(total) tokens")
    }
}

private struct StatusBadge: View {
    let session: SessionState

    var body: some View {
        HStack(spacing: 3) {
            if session.status == .running {
                ProgressView().controlSize(.mini)
            } else {
                Circle().fill(color).frame(width: 6, height: 6)
            }
            Text(label).font(.system(size: 9, weight: .semibold))
        }
        .foregroundStyle(color)
        .frame(width: 70, alignment: .leading)
    }

    private var label: String {
        switch session.status {
        case .waiting(.question): "Question"
        case .waiting(.plan): "Plan"
        case .waiting(.permission): "Approval"
        case .failed: "Failed"
        case .running: "Running"
        case .done: "Done"
        case .idle: "Idle"
        }
    }

    private var color: Color {
        switch session.status {
        case .waiting: Urgency.waiting.color
        case .failed: Urgency.failed.color
        case .done: Urgency.done.color
        case .running: .blue
        case .idle: .gray
        }
    }
}

extension Urgency {
    var color: Color {
        switch self {
        case .waiting: .orange
        case .failed: .red
        case .done: .green
        }
    }
}

/// Flat top edge flush with the screen, rounded bottom corners.
private struct NotchShape: Shape {
    var radius: CGFloat

    func path(in rect: CGRect) -> Path {
        let r = min(radius, rect.height / 2, rect.width / 2)
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY - r))
        path.addQuadCurve(to: CGPoint(x: rect.maxX - r, y: rect.maxY), control: CGPoint(x: rect.maxX, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.minX + r, y: rect.maxY))
        path.addQuadCurve(to: CGPoint(x: rect.minX, y: rect.maxY - r), control: CGPoint(x: rect.minX, y: rect.maxY))
        path.closeSubpath()
        return path
    }
}
