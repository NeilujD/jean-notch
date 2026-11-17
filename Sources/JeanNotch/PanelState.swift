import Foundation
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
