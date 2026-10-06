import MoonletBrain
import SwiftUI

/// One agent as a small moon: the color is its state, the lit part its progress.
struct Moon: View {
    var activity: AgentActivity
    /// Lit fraction, 0...1. Finished, failed, and blocked agents are drawn full.
    var phase: Double
    var size: CGFloat = 12

    var body: some View {
        ZStack {
            Circle()
                .fill(Color(nsColor: .windowBackgroundColor))
                .frame(width: size + 3, height: size + 3)
            Circle()
                .fill(Color(activity).opacity(0.25))
                .frame(width: size, height: size)
            if activity == .failed {
                Circle()
                    .strokeBorder(Color(activity), lineWidth: 1.5)
                    .frame(width: size, height: size)
            } else {
                MoonLight(phase: phase)
                    .fill(Color(activity))
                    .frame(width: size, height: size)
            }
        }
        .frame(width: size + 3, height: size + 3)
        .accessibilityHidden(true)
    }

    /// The phase to draw for an agent with optional task progress.
    static func phase(for activity: AgentActivity, progress: Double?) -> Double {
        switch activity {
        case .working: max(0.12, progress ?? 0.5)
        case .idle: 0
        case .waiting, .done, .failed: 1
        }
    }
}

/// The lit part of a moon: a crescent below half, a gibbous above.
struct MoonLight: Shape {
    var phase: Double

    var animatableData: Double {
        get { phase }
        set { phase = newValue }
    }

    func path(in rect: CGRect) -> Path {
        let r = min(rect.width, rect.height) / 2
        let c = CGPoint(x: rect.midX, y: rect.midY)
        var path = Path()
        guard phase > 0.001 else { return path }
        if phase >= 0.999 {
            path.addEllipse(in: CGRect(x: c.x - r, y: c.y - r, width: 2 * r, height: 2 * r))
            return path
        }
        // The lit right half, then back up along the terminator, an ellipse
        // bulging right for a crescent and left for a gibbous.
        path.move(to: CGPoint(x: c.x, y: c.y - r))
        path.addArc(center: c, radius: r, startAngle: .degrees(-90), endAngle: .degrees(90), clockwise: false)
        let rx = abs(1 - 2 * phase) * r * (phase < 0.5 ? 1 : -1)
        let k: CGFloat = 0.5523
        path.addCurve(to: CGPoint(x: c.x + rx, y: c.y),
                      control1: CGPoint(x: c.x + rx * k, y: c.y + r),
                      control2: CGPoint(x: c.x + rx, y: c.y + r * k))
        path.addCurve(to: CGPoint(x: c.x, y: c.y - r),
                      control1: CGPoint(x: c.x + rx, y: c.y - r * k),
                      control2: CGPoint(x: c.x + rx * k, y: c.y - r))
        path.closeSubpath()
        return path
    }
}
