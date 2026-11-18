import JeanNotchCore
import SwiftUI

/// What the mascot acts out. Derived from the board, most urgent first.
enum MascotMood: Equatable {
    case sleeping, waiting, failed, done, running, idle

    init(connection: ConnectionState, board: SessionBoard) {
        if connection != .online { self = .sleeping; return }
        switch board.mostUrgent {
        case .waiting: self = .waiting
        case .failed: self = .failed
        case .done: self = .done
        case nil: self = board.runningCount > 0 ? .running : .idle
        }
    }
}

/// The logo's pixel J, small enough to sit beside the notch.
/// All motion is a pure function of time, so no view state is needed.
struct MascotView: View {
    let mood: MascotMood
    var pixel: CGFloat = 2.5
    /// Animate continuously. Otherwise the mascot only fidgets in short bursts,
    /// because every frame re-renders the whole notch (~3% CPU when continuous).
    var lively = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    // Y = body, E = eye. The shadow is drawn one pixel down-right of the body.
    private static let grid = [
        "....YYY",
        "....EYE",
        "....YYY",
        "YY..YYY",
        "YY..YYY",
        "..YYYY.",
    ].map(Array.init)

    private static let yellow = Color(red: 0.99, green: 0.82, blue: 0.31)
    private static let shadow = Color(red: 0.48, green: 0.39, blue: 0.19)
    private static let eye = Color(red: 0.17, green: 0.14, blue: 0.08)

    private var spriteSize: CGSize {
        CGSize(width: CGFloat(Self.grid[0].count + 1) * pixel, height: CGFloat(Self.grid.count + 1) * pixel)
    }

    var body: some View {
        let schedule = FidgetSchedule(continuous: lively)
        TimelineView(schedule) { context in
            let moving = !reduceMotion && schedule.isActive(at: context.date)
            let pose = Self.pose(for: mood, at: moving ? context.date.timeIntervalSinceReferenceDate : Self.restTime)
            HStack(spacing: 1) {
                sprite(eyes: pose.eyes)
                    .scaleEffect(x: 1 / pose.squash, y: pose.squash, anchor: .bottom)
                    .rotationEffect(.degrees(pose.tilt), anchor: pose.pivot)
                    .offset(y: -pose.lift)
                if let mark = pose.mark {
                    Text(mark.text)
                        .font(.system(size: 8, weight: .heavy, design: .rounded))
                        .foregroundStyle(mark.color)
                        .offset(y: pose.markLift - 4)
                }
            }
        }
        .accessibilityHidden(true)
    }

    private func sprite(eyes: Eyes) -> some View {
        Canvas { context, _ in
            // One path per color: separate per-cell fills leave hairline seams.
            var body = Path(), shade = Path(), eyeCells: [CGRect] = []
            for (y, row) in Self.grid.enumerated() {
                for (x, cell) in row.enumerated() where cell != "." {
                    let rect = CGRect(x: CGFloat(x) * pixel, y: CGFloat(y) * pixel, width: pixel, height: pixel)
                    body.addRect(rect)
                    shade.addRect(rect.offsetBy(dx: pixel, dy: pixel))
                    if cell == "E" { eyeCells.append(rect) }
                }
            }
            context.fill(shade, with: .color(Self.shadow))
            context.fill(body, with: .color(Self.yellow))
            for rect in eyeCells { draw(eyes, in: rect, context: &context) }
        }
        .frame(width: spriteSize.width, height: spriteSize.height)
    }

    private func draw(_ eyes: Eyes, in rect: CGRect, context: inout GraphicsContext) {
        switch eyes {
        case .open:
            context.fill(Path(rect), with: .color(Self.eye))
        case .closed:
            let line = CGRect(x: rect.minX, y: rect.midY - pixel * 0.2, width: rect.width, height: pixel * 0.4)
            context.fill(Path(line), with: .color(Self.eye))
        case .crossed:
            var cross = Path()
            let r = rect.insetBy(dx: -pixel * 0.2, dy: -pixel * 0.2)
            cross.move(to: CGPoint(x: r.minX, y: r.minY)); cross.addLine(to: CGPoint(x: r.maxX, y: r.maxY))
            cross.move(to: CGPoint(x: r.maxX, y: r.minY)); cross.addLine(to: CGPoint(x: r.minX, y: r.maxY))
            context.stroke(cross, with: .color(Self.eye), lineWidth: pixel * 0.45)
        }
    }

    // MARK: Choreography

    enum Eyes { case open, closed, crossed }

    struct Mark {
        let text: String
        let color: Color
    }

    struct Pose {
        var lift: CGFloat = 0
        var tilt: Double = 0
        var squash: CGFloat = 1
        var pivot = UnitPoint.bottom
        var eyes = Eyes.open
        var mark: Mark?
        var markLift: CGFloat = 0
    }

    /// A time at which every mood shows a calm, eyes-open frame.
    static let restTime: TimeInterval = 1

    static func pose(for mood: MascotMood, at t: TimeInterval) -> Pose {
        var pose = Pose()
        // Blink for 0.12 s every 3.2 s.
        if t.truncatingRemainder(dividingBy: 3.2) < 0.12 { pose.eyes = .closed }

        switch mood {
        case .idle:
            pose.lift = 1 + sin(t * 2) * 1

        case .running:
            // Quick hops, leaning forward.
            let hop = abs(sin(t * 9))
            pose.lift = hop * 3
            pose.tilt = 8
            pose.squash = hop < 0.15 ? 0.85 : 1

        case .waiting:
            // Impatient foot tap: rock side to side, "?" bobbing.
            pose.tilt = sin(t * 12) > 0 ? 7 : -7
            pose.mark = Mark(text: "?", color: .orange)
            pose.markLift = sin(t * 4) * 1.5

        case .done:
            // Big celebratory jump, squash on landing.
            let phase = t.truncatingRemainder(dividingBy: 1.1) / 1.1
            let jump = max(0, sin(phase * .pi * 2))
            pose.lift = jump * 6
            pose.squash = jump == 0 && phase > 0.5 && phase < 0.62 ? 0.75 : 1
            pose.tilt = jump > 0 ? sin(phase * .pi * 4) * 10 : 0
            pose.mark = Mark(text: "!", color: .green)
            pose.markLift = jump * 6

        case .failed:
            // Fell over: lying on its back, dazed.
            pose.tilt = -90
            pose.pivot = .center
            pose.eyes = .crossed
            pose.lift = abs(sin(t * 1.5)) * 0.6
            pose.mark = Mark(text: "x", color: .red)

        case .sleeping:
            pose.eyes = .closed
            pose.squash = 1 + sin(t * 1.5) * 0.04
            pose.mark = Mark(text: "z", color: .gray)
            pose.markLift = (t.truncatingRemainder(dividingBy: 2)) * 2
        }
        return pose
    }
}

/// 20 fps while active; no frames at all between fidget bursts.
/// Bursts are aligned to wall-clock time: `burst` seconds every `period` seconds.
struct FidgetSchedule: TimelineSchedule {
    var continuous: Bool
    var interval: TimeInterval = 1 / 20
    var period: TimeInterval = 15
    var burst: TimeInterval = 2.5

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
                // Next frame, or one last frame at the burst end to draw the rest pose.
                return date + min(interval, burst - phase)
            }
            return date + (period - phase)
        }
    }
}
