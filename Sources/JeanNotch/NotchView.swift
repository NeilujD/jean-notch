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
    @AppStorage(WarningLimit.tokens.key) private var tokenWarning = WarningLimit.tokens.defaultValue
    @AppStorage(WarningLimit.usage.key) private var usageWarning = WarningLimit.usage.defaultValue
    @AppStorage(ExperimentalFeature.stopSessions.key) private var stopsSessions = false

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
                VStack(spacing: 10) {
                    list
                    if store.connection == .online, !store.usage.isEmpty {
                        UsageFooter(usage: store.usage, warning: usageWarning)
                    }
                }
                .padding(.horizontal, 14).padding(.bottom, 12)
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
        store.board.runningCount > 0 || store.board.mostUrgent != nil || store.connection != .online || usageOver
    }

    private var usageOver: Bool {
        usageWarning > 0 && store.usage.values.contains { $0.peakPercent > Double(usageWarning) }
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
        } else {
            HStack(spacing: 4) {
                if usageOver {
                    Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 8))
                        .foregroundStyle(.orange)
                        .accessibilityLabel("A provider is over the usage warning limit")
                }
                if let urgency = store.board.mostUrgent {
                    Circle().fill(urgency.color).frame(width: 7, height: 7)
                }
            }
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
                    HStack(spacing: 6) {
                        Text("\(group.projectName) › \(group.worktreeName)")
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                        if let badge = store.board.prBadges[group.worktreeId] {
                            PrBadgeView(badge: badge)
                        }
                    }
                    ForEach(group.sessions) { session in
                        SessionRow(
                            session: session, tokens: store.tokens[session.id], tokenLimit: tokenWarning, now: now,
                            panel: panel, action: { actions.open(session) },
                            stop: stopsSessions && session.status == .running ? { store.stop(session) } : nil,
                            stopping: store.stopping.contains(session.id)
                        )
                        if stopsSessions, session.status == .running, let failure = store.stopErrors[session.id] {
                            Text(failure).font(.system(size: 9)).foregroundStyle(.red).lineLimit(2)
                                .padding(.horizontal, 6)
                        }
                        if let question = store.questions[session.id] {
                            QuestionCard(
                                pending: question, panel: panel,
                                sending: store.answering.contains(question.id),
                                failure: store.answerErrors[question.id]
                            ) { store.answer(question, in: session, with: $0) }
                        }
                        if let request = store.permissions[session.id]?.first {
                            PermissionCard(
                                request: request, panel: panel,
                                sending: store.answeringPermissions.contains(request.rpcId),
                                failure: store.permissionErrors[request.rpcId]
                            ) { store.answerPermission(request, in: session, approved: $0) }
                        }
                        if let plan = store.plans[session.id] {
                            PlanCard(
                                plan: plan, sending: store.approving.contains(session.id),
                                failure: store.approveErrors[session.id]
                            ) { store.approve(plan, in: session) }
                        }
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
    let panel: PanelState
    let action: () -> Void
    /// Experimental. Nil when the row has no stop button.
    var stop: (() -> Void)?
    var stopping = false

    private var hovering: Bool { panel.hoveredRow == session.id }
    private var armed: Bool { hovering && panel.stopArmed }
    private var showsStop: Bool { stop != nil && (hovering || stopping) }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                StatusBadge(session: session)
                Text(session.name).font(.system(size: 12)).lineLimit(1).truncationMode(.tail)
                Spacer(minLength: 4)
                HStack(spacing: 8) {
                    if let tokens, tokens.total > 0 {
                        TokenCount(total: tokens.total, limit: tokenLimit)
                    }
                    Text(Self.age(from: session.changedAt, to: now))
                        .font(.system(size: 10).monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                .opacity(showsStop ? 0 : 1)
            }
            .padding(.vertical, 3)
            .padding(.horizontal, 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(.white)
        .overlay(alignment: .trailing) {
            if showsStop, let stop {
                stopButton(stop).padding(.trailing, 4)
            }
        }
        .background(RoundedRectangle(cornerRadius: 6).fill(.white.opacity(showsStop ? 0.08 : 0)))
        .onHover { panel.hoverRow(session.id, inside: $0) }
    }

    private func stopButton(_ stop: @escaping () -> Void) -> some View {
        Button {
            if panel.clickStop() { stop() }
        } label: {
            Group {
                if stopping {
                    Text("Stopping").padding(.horizontal, 8)
                } else if armed {
                    Text("Stop?").padding(.horizontal, 8)
                } else {
                    Image(systemName: "stop.fill").font(.system(size: 7)).frame(width: 18)
                }
            }
            .font(.system(size: 10, weight: .semibold))
            .frame(height: 16)
            .background(Capsule().fill(armed ? Urgency.failed.color : .white.opacity(0.15)))
            .foregroundStyle(.white)
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .disabled(stopping)
        .accessibilityLabel(armed ? "Click again to stop the session" : "Stop the session")
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

/// Experimental: the question a session waits on, with what led to it. The user picks
/// options, then sends them. Two clicks, because the notch can open under the pointer.
private struct QuestionCard: View {
    let pending: PendingQuestion
    let panel: PanelState
    let sending: Bool
    let failure: String?
    let send: (PendingQuestion.Picks) -> Void

    private var picks: PendingQuestion.Picks { panel.picks[pending.id] ?? [:] }
    private var canSend: Bool { !sending && pending.isAnswered(by: picks) }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if !pending.situation.isEmpty {
                Text(Self.inlineMarkdown(pending.situation))
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .lineLimit(8)
                    .fixedSize(horizontal: false, vertical: true)
            }
            ForEach(Array(pending.questions.enumerated()), id: \.offset) { index, question in
                VStack(alignment: .leading, spacing: 3) {
                    Text(question.question)
                        .font(.system(size: 11, weight: .semibold))
                        .fixedSize(horizontal: false, vertical: true)
                    ForEach(Array(question.options.enumerated()), id: \.offset) { option, choice in
                        OptionRow(
                            option: choice, multiSelect: question.multiSelect,
                            picked: picks[index]?.contains(option) == true
                        ) {
                            panel.togglePick(option, in: index, of: pending.id, multiSelect: question.multiSelect)
                        }
                    }
                }
            }
            HStack(spacing: 6) {
                Text(failure ?? "Experimental · for a different answer, open Jean")
                    .font(.system(size: 9))
                    .foregroundStyle(failure == nil ? AnyShapeStyle(.tertiary) : AnyShapeStyle(.red))
                    .lineLimit(2)
                Spacer(minLength: 4)
                Button(sending ? "Sending" : "Send") { send(picks) }
                    .buttonStyle(.plain)
                    .font(.system(size: 10, weight: .semibold))
                    .padding(.horizontal, 10).padding(.vertical, 3)
                    .background(Capsule().fill(canSend ? Urgency.waiting.color : .white.opacity(0.12)))
                    .foregroundStyle(canSend ? .black : .secondary)
                    .disabled(!canSend)
            }
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8).fill(.white.opacity(0.07)))
        .foregroundStyle(.white)
        .padding(.bottom, 2)
    }

    /// Bold, italic and code only. Links are removed: the text comes from a model, and a
    /// link in the notch must not open on a click.
    static func inlineMarkdown(_ text: String) -> AttributedString {
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        guard var styled = try? AttributedString(markdown: text, options: options) else {
            return AttributedString(text)
        }
        styled.link = nil
        return styled
    }
}

/// Experimental: the plan a session waits on, in a scroll area, with one Approve button
/// (build mode). Full access and plan edits stay in Jean.
private struct PlanCard: View {
    let plan: PendingPlan
    let sending: Bool
    let failure: String?
    let approve: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ScrollView {
                VStack(alignment: .leading, spacing: 3) {
                    ForEach(Array(Self.lines(plan.text).enumerated()), id: \.offset) { _, line in
                        line
                    }
                }
                .padding(8)
                .padding(.bottom, 12)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 180)
            .mask(LinearGradient(stops: [.init(color: .black, location: 0.85), .init(color: .clear, location: 1)],
                                 startPoint: .top, endPoint: .bottom))
            .background(RoundedRectangle(cornerRadius: 6).fill(.white.opacity(0.05)))
            HStack(spacing: 6) {
                Text(failure ?? "Experimental · Full access and edits: open Jean")
                    .font(.system(size: 9))
                    .foregroundStyle(failure == nil ? AnyShapeStyle(.tertiary) : AnyShapeStyle(.red))
                    .lineLimit(2)
                Spacer(minLength: 4)
                Button(sending ? "Approving" : "Approve", action: approve)
                    .buttonStyle(.plain)
                    .font(.system(size: 10, weight: .semibold))
                    .padding(.horizontal, 10).padding(.vertical, 3)
                    .background(Capsule().fill(sending ? .white.opacity(0.12) : Urgency.waiting.color))
                    .foregroundStyle(sending ? AnyShapeStyle(.secondary) : AnyShapeStyle(.black))
                    .disabled(sending)
            }
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8).fill(.white.opacity(0.07)))
        .foregroundStyle(.white)
        .padding(.bottom, 2)
    }

    /// Markdown blocks as lines: headings in bold, list items with a bullet, code fences dropped.
    static func lines(_ markdown: String) -> [AnyView] {
        markdown.components(separatedBy: "\n").compactMap { raw in
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("```") { return nil }
            if let heading = line.firstMatch(of: /^#{1,6}\s+(.+)/) {
                return AnyView(Text(QuestionCard.inlineMarkdown(String(heading.1)))
                    .font(.system(size: 11, weight: .semibold))
                    .padding(.top, 2))
            }
            let indent = CGFloat(raw.prefix { $0 == " " }.count / 2) * 10
            if let item = line.firstMatch(of: /^(?:[-*+]|\d+[.)])\s+(.+)/) {
                let mark = line.first?.isNumber == true ? String(line.prefix { $0 != " " }) : "•"
                return AnyView(HStack(alignment: .firstTextBaseline, spacing: 4) {
                    Text(mark).foregroundStyle(.secondary)
                    Text(QuestionCard.inlineMarkdown(String(item.1)))
                        .fixedSize(horizontal: false, vertical: true)
                }
                .font(.system(size: 10))
                .padding(.leading, indent))
            }
            return AnyView(Text(QuestionCard.inlineMarkdown(line))
                .font(.system(size: 10))
                .fixedSize(horizontal: false, vertical: true)
                .padding(.leading, indent))
        }
    }
}

private struct OptionRow: View {
    let option: PendingQuestion.Option
    let multiSelect: Bool
    let picked: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Image(systemName: symbol).font(.system(size: 10))
                    .foregroundStyle(picked ? AnyShapeStyle(Urgency.waiting.color) : AnyShapeStyle(.secondary))
                VStack(alignment: .leading, spacing: 1) {
                    Text(option.label).font(.system(size: 11))
                    if let description = option.description, !description.isEmpty {
                        Text(description).font(.system(size: 9)).foregroundStyle(.secondary).lineLimit(2)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(.vertical, 3).padding(.horizontal, 6)
            .background(RoundedRectangle(cornerRadius: 5).fill(.white.opacity(picked ? 0.12 : 0)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(picked ? .isSelected : [])
    }

    private var symbol: String {
        switch (multiSelect, picked) {
        case (true, true): "checkmark.square.fill"
        case (true, false): "square"
        case (false, true): "largecircle.fill.circle"
        case (false, false): "circle"
        }
    }
}

/// One line per provider: each plan window's percent used and the time until it resets.
private struct UsageFooter: View {
    let usage: [UsageProvider: ProviderUsage]
    let warning: Int

    var body: some View {
        TimelineView(.periodic(from: .now, by: 30)) { context in
            VStack(alignment: .leading, spacing: 3) {
                Rectangle().fill(.white.opacity(0.12)).frame(height: 0.5)
                ForEach(UsageProvider.allCases.filter { usage[$0] != nil }, id: \.self) { provider in
                    HStack(spacing: 10) {
                        Text(provider.name).font(.system(size: 10, weight: .medium))
                            .frame(width: 40, alignment: .leading)
                        ForEach(usage[provider]?.limits(for: provider) ?? [], id: \.label) { limit in
                            LimitLabel(limit: limit, warning: warning, now: context.date)
                        }
                        Spacer(minLength: 0)
                    }
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                }
            }
            .foregroundStyle(.secondary)
            .padding(.horizontal, 6)
        }
    }
}

private struct LimitLabel: View {
    let limit: ProviderUsage.Limit
    let warning: Int
    let now: Date

    private var over: Bool { warning > 0 && limit.window.usedPercent > Double(warning) }

    var body: some View {
        HStack(spacing: 2) {
            if over {
                Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 8))
            }
            Text("\(limit.label) \(Int(limit.window.usedPercent.rounded()))%")
            if let resetsAt = limit.window.resetsAt {
                Text("· \(ProviderUsage.timeLeft(until: resetsAt, now: now))").opacity(0.7)
            }
        }
        .font(.system(size: 10).monospacedDigit())
        .foregroundStyle(over ? AnyShapeStyle(.orange) : AnyShapeStyle(.secondary))
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
            Text(TokenUsage.format(total)).font(.system(size: 10).monospacedDigit())
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

private struct PrBadgeView: View {
    let badge: PrBadge

    var body: some View {
        Text("\(symbol) \(badge.label)")
            .font(.system(size: 9, weight: .semibold))
            .lineLimit(1)
            .fixedSize()
            .foregroundStyle(color)
            .padding(.horizontal, 6).padding(.vertical, 1)
            .background(Capsule().fill(color.opacity(0.15)))
            .accessibilityLabel("Pull request: \(badge.label)")
    }

    private var symbol: String {
        switch badge.kind {
        case .ciFailing: "✕"
        case .changesRequested: "●"
        case .ciRunning: "◌"
        case .ready: "✓"
        case .merged: "⇡"
        }
    }

    private var color: Color {
        switch badge.kind {
        case .ciFailing: .red
        case .changesRequested: .orange
        case .ciRunning: .gray
        case .ready: .green
        case .merged: .purple
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
