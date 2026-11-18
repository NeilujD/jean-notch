import JeanNotchCore
import SwiftUI

/// What the J shows. Urgency has its own dot, so the J only tells whether work is happening.
enum MascotMood: Equatable {
    case asleep, busy, idle

    init(connection: ConnectionState, board: SessionBoard) {
        if connection != .online { self = .asleep }
        else { self = board.runningCount > 0 ? .busy : .idle }
    }
}

/// The logo's pixel J, flat, small enough to sit beside the notch.
/// Busy: a slow opacity pulse. Asleep: dimmed. Idle: still.
struct MascotView: View {
    let mood: MascotMood
    var pixel: CGFloat = 2.5
    /// Pulse continuously. Otherwise the J pulses once every 15 s,
    /// because every frame re-renders the whole notch (~3% CPU when continuous).
    var lively = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private static let grid = [
        "....#",
        "....#",
        "....#",
        "....#",
        "#...#",
        ".###.",
    ].map(Array.init)

    private static let yellow = Color(red: 0.99, green: 0.82, blue: 0.31)

    var body: some View {
        if mood == .busy && !reduceMotion {
            let schedule = FidgetSchedule(continuous: lively)
            TimelineView(schedule) { context in
                let date = context.date
                sprite.opacity(schedule.isActive(at: date) ? Self.pulse(at: date.timeIntervalSinceReferenceDate) : 1)
            }
        } else {
            sprite.opacity(mood == .asleep ? 0.35 : 1)
        }
    }

    /// 1 → 0.45 → 1 over one burst. Bursts start on a multiple of the period, so each burst is one full cycle.
    static func pulse(at t: TimeInterval) -> Double {
        let cycle = FidgetSchedule.burstLength
        return 0.725 + 0.275 * cos(t.truncatingRemainder(dividingBy: cycle) / cycle * 2 * .pi)
    }

    private var sprite: some View {
        Canvas { context, _ in
            // One path: separate per-cell fills leave hairline seams.
            var path = Path()
            for (y, row) in Self.grid.enumerated() {
                for (x, cell) in row.enumerated() where cell == "#" {
                    path.addRect(CGRect(x: CGFloat(x) * pixel, y: CGFloat(y) * pixel, width: pixel, height: pixel))
                }
            }
            context.fill(path, with: .color(Self.yellow))
        }
        .frame(width: CGFloat(Self.grid[0].count) * pixel, height: CGFloat(Self.grid.count) * pixel)
        .accessibilityHidden(true)
    }
}

/// 20 fps while active; no frames at all between bursts.
/// Bursts are aligned to wall-clock time: `burst` seconds every `period` seconds.
struct FidgetSchedule: TimelineSchedule {
    static let burstLength: TimeInterval = 2.5

    var continuous: Bool
    var interval: TimeInterval = 1 / 20
    var period: TimeInterval = 15
    var burst: TimeInterval = burstLength

    func isActive(at date: Date) -> Bool {
        continuous || phase(of: date) < burst
    }

    private func phase(of date: Date) -> TimeInterval {
        date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: period)
    }

    func entries(from startDate: Date, mode: TimelineScheduleMode) -> UnfoldSequence<Date, (Date?, Bool)> {
        sequence(first: startDate) { date in
            if continuous { return date + interval }
            let phase = phase(of: date)
            if phase < burst {
                // Next frame, or one last frame at the burst end to draw the rest state.
                return date + min(interval, burst - phase)
            }
            return date + (period - phase)
        }
    }
}
