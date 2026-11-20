import Foundation
import JeanNotchCore
import Observation

/// Whether the notch is expanded: while hovered, and for a few seconds after an alert.
@MainActor
@Observable
final class PanelState {
    var geometry = NotchGeometry(width: 0, height: 32, hasNotch: false)
    private(set) var hovering = false
    private(set) var alerting = false
    /// Start of the current confetti burst, if any.
    private(set) var celebration: Date?
    /// Picked options by question id. Kept here so they stay when the notch collapses.
    private(set) var picks: [String: PendingQuestion.Picks] = [:]
    /// Rpc id of the permission request whose **Allow** was clicked once.
    var confirmingAllow: UInt64?
    /// Experimental: the session row under the pointer, and whether its stop button asks "Stop?".
    private(set) var hoveredRow: String?
    private(set) var stopArmed = false

    var expanded: Bool { hovering || alerting }

    @ObservationIgnored private var hoverTask: Task<Void, Never>?
    @ObservationIgnored private var alertTask: Task<Void, Never>?
    @ObservationIgnored private var celebrationTask: Task<Void, Never>?

    /// Enter expands at once; leave collapses after a short grace period so the
    /// pointer can cross the panel edge while it resizes.
    func setHovering(_ value: Bool) {
        hoverTask?.cancel()
        if value {
            hovering = true
            return
        }
        hoverTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled else { return }
            self?.hovering = false
        }
    }

    func alert(for duration: Duration = .seconds(4)) {
        alertTask?.cancel()
        alerting = true
        alertTask = Task { [weak self] in
            try? await Task.sleep(for: duration)
            guard !Task.isCancelled else { return }
            self?.alerting = false
        }
    }

    /// A single-select question keeps one option; a second click on it clears it.
    func togglePick(_ option: Int, in question: Int, of id: String, multiSelect: Bool) {
        var picked = picks[id]?[question] ?? []
        if multiSelect {
            picked.formSymmetricDifference([option])
        } else {
            picked = picked == [option] ? [] : [option]
        }
        picks[id, default: [:]][question] = picked
    }

    /// Moving to another row, or out of it, turns "Stop?" back into the stop button.
    func hoverRow(_ id: String, inside: Bool) {
        guard inside || hoveredRow == id else { return }
        hoveredRow = inside ? id : nil
        stopArmed = false
    }

    /// The first click arms the stop button; the second returns true, so the run stops.
    /// Two clicks, because the notch can open under the pointer.
    func clickStop() -> Bool {
        stopArmed.toggle()
        return !stopArmed
    }

    func celebrate() {
        celebrationTask?.cancel()
        celebration = Date()
        celebrationTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(ConfettiView.duration))
            guard !Task.isCancelled else { return }
            self?.celebration = nil
        }
    }
}
