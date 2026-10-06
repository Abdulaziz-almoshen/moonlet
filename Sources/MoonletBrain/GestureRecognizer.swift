import CoreGraphics
import Foundation

/// Recognizes the summon gesture from raw pointer samples: a small circle
/// ("call your moonlets into orbit").
///
/// Feed every pointer movement; samples taken with a mouse button held are
/// ignored, so drawing and dragging never summon by accident.
public struct GestureRecognizer: Sendable {
    public enum Gesture: Sendable, Equatable {
        case circle(center: CGPoint)
    }

    public struct Config: Sendable, Equatable {
        public var circleEnabled = true
        /// Time window a whole circle must fit in.
        public var circleWindow: TimeInterval = 1.2
        /// Total angle swept around the centroid, in radians (about 0.9 of a turn).
        public var minimumSweep: Double = 5.6
        public var radiusRange: ClosedRange<Double> = 15...160
        /// Standard deviation of the radius divided by its mean; lower is rounder.
        public var maximumWobble: Double = 0.45
        /// Quiet period after a recognized gesture.
        public var cooldown: TimeInterval = 1.0
        public init() {}
    }

    public var config: Config
    private var samples: [(point: CGPoint, time: TimeInterval)] = []
    private var quietUntil: TimeInterval = 0

    public init(config: Config = Config()) {
        self.config = config
    }

    /// Adds a pointer sample. Returns a gesture when one completes.
    public mutating func add(_ point: CGPoint, at time: TimeInterval, buttonsDown: Bool = false) -> Gesture? {
        guard !buttonsDown else {
            reset()
            return nil
        }
        guard time >= quietUntil, config.circleEnabled, let circle = trackCircle(point, time) else { return nil }
        return finish(circle, time)
    }

    public mutating func reset() {
        samples.removeAll()
    }

    private mutating func finish(_ gesture: Gesture, _ time: TimeInterval) -> Gesture {
        reset()
        quietUntil = time + config.cooldown
        return gesture
    }

    private mutating func trackCircle(_ point: CGPoint, _ time: TimeInterval) -> Gesture? {
        samples.append((point, time))
        samples.removeAll { time - $0.time > config.circleWindow }
        guard samples.count >= 14 else { return nil }

        let n = Double(samples.count)
        let cx = samples.reduce(0) { $0 + Double($1.point.x) } / n
        let cy = samples.reduce(0) { $0 + Double($1.point.y) } / n
        let radii = samples.map { hypot(Double($0.point.x) - cx, Double($0.point.y) - cy) }
        let meanRadius = radii.reduce(0, +) / n
        guard config.radiusRange.contains(meanRadius) else { return nil }
        let variance = radii.reduce(0) { $0 + ($1 - meanRadius) * ($1 - meanRadius) } / n
        guard variance.squareRoot() / meanRadius <= config.maximumWobble else { return nil }

        var sweep = 0.0
        for i in 1..<samples.count {
            let a0 = atan2(Double(samples[i - 1].point.y) - cy, Double(samples[i - 1].point.x) - cx)
            let a1 = atan2(Double(samples[i].point.y) - cy, Double(samples[i].point.x) - cx)
            var delta = a1 - a0
            if delta > .pi { delta -= 2 * .pi }
            if delta < -.pi { delta += 2 * .pi }
            sweep += delta
        }
        guard abs(sweep) >= config.minimumSweep else { return nil }
        return .circle(center: CGPoint(x: cx, y: cy))
    }
}
