import SwiftUI

/// A one-shot burst of pixel confetti from the top center, started at `start`.
/// Particle paths are a pure function of index and elapsed time.
struct ConfettiView: View {
    let start: Date

    static let duration: TimeInterval = 1.6
    private static let count = 40
    private static let colors: [Color] = [
        Color(red: 0.99, green: 0.82, blue: 0.31), .orange, .green, .pink, .cyan,
    ]

    var body: some View {
        TimelineView(.animation) { context in
            let elapsed = context.date.timeIntervalSince(start)
            Canvas { canvas, size in
                guard elapsed >= 0, elapsed < Self.duration else { return }
                let fade = 1 - elapsed / Self.duration
                for i in 0..<Self.count {
                    let p = Self.particle(i, at: elapsed, width: size.width)
                    let side = i.isMultiple(of: 3) ? 4.0 : 3.0
                    let rect = CGRect(x: p.x - side / 2, y: p.y - side / 2, width: side, height: side)
                    canvas.opacity = fade
                    canvas.fill(Path(rect), with: .color(Self.colors[i % Self.colors.count]))
                }
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    /// Fan out downward from the top center under gravity.
    static func particle(_ i: Int, at t: TimeInterval, width: CGFloat) -> CGPoint {
        // Cheap deterministic pseudo-random values per particle.
        func rand(_ salt: Int) -> Double {
            let x = sin(Double(i * 127 + salt * 311)) * 43758.5453
            return x - x.rounded(.down)
        }
        let angle = (rand(1) - 0.5) * .pi * 0.9  // around straight down
        let speed = 90 + rand(2) * 140
        let vx = sin(angle) * speed
        let vy = cos(angle) * speed * 0.6
        let gravity = 260.0
        return CGPoint(x: width / 2 + vx * t, y: 10 + vy * t + gravity * t * t / 2 - 60 * t)
    }
}
