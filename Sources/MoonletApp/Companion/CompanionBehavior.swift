import CoreGraphics
import Foundation
import MoonletBrain

/// What a behavior changes in one frame, on top of the mood's resting pose.
/// Mirrors `CompanionPose`, with `nil` meaning "leave it to the mood".
struct PoseChange {
    var expression: Expression?
    var look: CGVector?
    var offset = CGPoint.zero
    var rotation: CGFloat = 0
    var squash: CGFloat = 1
    var armLeft: CGFloat = 0
    var armRight: CGFloat = 0
    var blush: CGFloat?
    var props: [CompanionProp] = []

    mutating func add(_ kind: CompanionProp.Kind, _ progress: Double) {
        props.append(CompanionProp(kind: kind, progress: progress))
    }
}

/// A short move the companion makes while it has something to say. Picked at
/// random from the mood's pool, never twice in a row, so no two appearances
/// look the same.
enum CompanionBehavior: CaseIterable {
    case lookAround, lookAtYou, hop, wiggle, hum, wave, spin, blep, ponder, blush, sniffle, fidget, yawn, glanceAtOptions, sneeze

    var duration: Double {
        switch self {
        case .lookAround: 2.4
        case .lookAtYou: 1.8
        case .hop: 0.75
        case .wiggle: 1.2
        case .hum: 2.6
        case .wave: 1.6
        case .spin: 0.95
        case .blep: 1.6
        case .ponder: 2.4
        case .blush: 1.5
        case .sniffle: 1.4
        case .fidget: 1.4
        case .yawn: 2.2
        case .glanceAtOptions: 2.2
        case .sneeze: 1.6
        }
    }

    /// Applies the behavior at `p`, 0...1 through its duration.
    func apply(_ p: Double, to change: inout PoseChange) {
        let pi = Double.pi
        switch self {
        case .lookAround:
            change.look = CGVector(dx: sin(p * pi * 2) * 0.95, dy: -0.15)
        case .lookAtYou:
            change.look = .zero
            change.blush = 1.3
        case .hop:
            change.offset.y -= sin(p * pi) * 5.5
            change.squash = p < 0.12 ? 0.84 : p > 0.9 ? 0.86 : 1.07
            change.expression = .delighted
        case .wiggle:
            change.rotation = sin(p * pi * 6) * 10 * (1 - p)
        case .hum:
            change.expression = .proud
            change.rotation = sin(p * pi * 4) * 7
            change.add(.notes, p)
        case .wave:
            change.armRight = -125 + sin(p * pi * 6) * 32
        case .spin:
            change.expression = .delighted
            change.rotation = Ease.inOut(p) * 360
            change.offset.y -= sin(p * pi) * 4
        case .blep:
            change.expression = .blep
            change.look = .zero
        case .ponder:
            change.expression = .curious
            change.add(.orbit, p)
        case .blush:
            change.expression = .shy
            change.add(.heart, p)
        case .sniffle:
            change.squash = 1 - sin(p * pi * 3) * 0.05
            change.offset.y += sin(p * pi * 3) * 0.6
        case .fidget:
            change.offset.x += sin(p * 70) * 0.45
            change.look = CGVector(dx: sin(p * 9) * 0.8, dy: 0.1)
        case .yawn:
            let a = sin(min(max(p * 1.5, 0), 1) * pi)
            change.expression = p < 0.6 ? .surprised : .sleepy
            change.armLeft = 150 * a
            change.armRight = -150 * a
            change.squash = 1 + 0.1 * a
        case .glanceAtOptions:
            change.look = CGVector(dx: p < 0.5 ? -0.9 : 0.9, dy: 0.9)
        case .sneeze:
            if p < 0.55 {
                let q = p / 0.55
                change.expression = .oops
                change.squash = 1 + q * 0.18
                change.rotation = -q * 9
            } else {
                let q = (p - 0.55) / 0.45
                change.expression = q < 0.5 ? .surprised : .delighted
                change.offset.x += 2.5 * (1 - q)
                change.add(.sparkle, q)
            }
        }
    }
}

/// How each mood performs: an entrance (two variants, so it varies), what it
/// keeps with it, and the moves it picks from while the card shows.
struct MoodPerformance {
    struct Entrance {
        var duration: Double
        var apply: (Double, inout PoseChange) -> Void
    }

    var entrances: [Entrance]
    var pool: [CompanionBehavior]
    /// Props it keeps the whole time, at time `t` seconds into the scene.
    var keeps: (Double) -> [CompanionProp]

    static func of(_ mood: CompanionMood) -> MoodPerformance {
        let pi = Double.pi
        func prop(_ kind: CompanionProp.Kind, _ progress: Double) -> CompanionProp { CompanionProp(kind: kind, progress: progress) }
        switch mood {
        case .celebrate:
            return MoodPerformance(entrances: [
                Entrance(duration: 1.3) { p, c in
                    c.rotation = Ease.inOut(p) * 360; c.offset.y -= sin(p * pi) * 7; c.squash = p < 0.1 ? 0.82 : 1.05; c.add(.confetti, p)
                },
                Entrance(duration: 1.3) { p, c in
                    c.offset.y -= abs(sin(p * pi * 2)) * 6; let a = sin(p * pi); c.armLeft = 150 * a; c.armRight = -150 * a
                    c.add(.confetti, p); c.add(.sparkle, p)
                },
            ], pool: [.hop, .spin, .hum, .wave], keeps: { _ in [prop(.hat, 0)] })
        case .proud:
            return MoodPerformance(entrances: [
                Entrance(duration: 1.1) { p, c in c.squash = 1 + sin(p * pi) * 0.12; c.add(.check, p) },
                Entrance(duration: 1.4) { p, c in c.rotation = sin(p * pi * 4) * 6; c.add(.notes, p); c.add(.check, p) },
            ], pool: [.hum, .lookAtYou, .hop], keeps: { _ in [] })
        case .happy:
            return MoodPerformance(entrances: [
                Entrance(duration: 1) { p, c in c.offset.y -= sin(p * pi) * 5; c.armRight = -130 * sin(p * pi); c.add(.check, p) },
                Entrance(duration: 1.1) { p, c in c.rotation = Ease.inOut(p) * 360; c.offset.y -= sin(p * pi) * 4; c.add(.check, p) },
            ], pool: [.hop, .wave, .lookAtYou], keeps: { _ in [] })
        case .cheeky:
            return MoodPerformance(entrances: [
                Entrance(duration: 1.1) { p, c in c.rotation = sin(p * pi * 4) * 12 * (1 - p); c.expression = p < 0.5 ? .blep : .cheeky },
                Entrance(duration: 1) { p, c in c.expression = p < 0.3 ? .oops : .cheeky; c.offset.x -= sin(p * pi) * 2; c.add(.heart, p) },
            ], pool: [.blep, .wiggle, .blush], keeps: { _ in [] })
        case .surprised:
            return MoodPerformance(entrances: [
                Entrance(duration: 0.9) { p, c in c.offset.y -= sin(p * pi) * 6; c.offset.x -= sin(p * pi) * 2; c.add(.sparkle, p) },
            ], pool: [.lookAround, .ponder], keeps: { _ in [] })
        case .asking:
            return MoodPerformance(entrances: [
                Entrance(duration: 0.9) { p, c in c.armRight = -150 * sin(min(1, p * 1.4) * pi / 2); c.offset.y -= sin(p * pi) * 3 },
            ], pool: [.lookAtYou, .lookAround, .wave], keeps: { t in [prop(.sign("?"), t * 0.25)] })
        case .curious:
            return MoodPerformance(entrances: [
                Entrance(duration: 1) { p, c in c.rotation = -sin(p * pi) * 14; c.look = CGVector(dx: 0.9, dy: 0.6) },
            ], pool: [.glanceAtOptions, .ponder, .lookAtYou], keeps: { t in [prop(.sign("?"), t * 0.25)] })
        case .nervous:
            return MoodPerformance(entrances: [
                Entrance(duration: 1) { p, c in c.offset.x += sin(p * 80) * 0.7 * (1 - p); c.expression = p < 0.4 ? .oops : .nervous },
            ], pool: [.fidget, .lookAtYou], keeps: { t in [prop(.sign("!"), t * 0.25), prop(.drop, (t * 0.5).truncatingRemainder(dividingBy: 1))] })
        case .teary:
            return MoodPerformance(entrances: [
                Entrance(duration: 1.2) { p, c in let q = min(1, p * 2); c.offset.y += sin(q * pi / 2) * 1.6; c.squash = 1 - q * 0.08 },
            ], pool: [.sniffle, .lookAtYou], keeps: { t in
                [prop(.tear, (t * 0.55).truncatingRemainder(dividingBy: 1)), prop(.cloud, (t * 0.25).truncatingRemainder(dividingBy: 1))]
            })
        case .worried:
            return MoodPerformance(entrances: [
                Entrance(duration: 0.9) { p, c in c.offset.x += sin(p * 40) * 0.6 * (1 - p) },
            ], pool: [.ponder, .lookAround, .fidget], keeps: { t in [prop(.drop, (t * 0.5).truncatingRemainder(dividingBy: 1))] })
        case .sleepy:
            return MoodPerformance(entrances: [
                Entrance(duration: 1.6) { p, c in
                    c.expression = p < 0.6 ? .surprised : .sleepy; let a = sin(min(max(p * 1.5, 0), 1) * pi); c.armLeft = 140 * a; c.armRight = -140 * a
                },
            ], pool: [.yawn, .lookAtYou], keeps: { t in [prop(.zzz, (t * 0.35).truncatingRemainder(dividingBy: 1))] })
        case .grateful:
            return MoodPerformance(entrances: [
                Entrance(duration: 1) { p, c in c.add(.heart, p); c.offset.y -= sin(p * pi) * 4 },
            ], pool: [.blush, .hop], keeps: { _ in [] })
        }
    }
}

enum Ease {
    static func inOut(_ p: Double) -> Double { p < 0.5 ? 2 * p * p : 1 - pow(-2 * p + 2, 2) / 2 }
    /// Overshoots a little, then settles: for things popping into view.
    static func backOut(_ p: Double) -> Double {
        let c = 1.9, q = min(max(p, 0), 1) - 1
        return 1 + (c + 1) * q * q * q + c * q * q
    }
}

/// Blinks at natural, uneven intervals, with an occasional double blink.
struct Blinker {
    private var next = Double.random(in: 1...3)
    private var left = 0.0

    /// The lid for this frame: 1 open, about 0.12 closed.
    mutating func step(_ dt: Double) -> CGFloat {
        next -= dt
        if next <= 0 {
            left = 0.13
            next = Double.random(in: 0...1) < 0.18 ? 0.22 : Double.random(in: 2.2...6.2)
        }
        left = max(0, left - dt)
        return left > 0 ? 0.12 : 1
    }
}
