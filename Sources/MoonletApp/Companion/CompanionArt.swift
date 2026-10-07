import AppKit
import CoreGraphics
import MoonletBrain

/// Draws the companion: a tiny moon with a face. Flat fills and a dark outline,
/// so it reads at 24 points on light and dark desktops.
///
/// A port of the design prototype's rig. Everything below is in rig units with
/// y growing downward: the body is a circle of radius 10 around the origin, and
/// the shapes are the prototype's own path data.
enum CompanionArt {
    /// Draws `pose` centered on `center` (in the context's coordinates, which may
    /// have y up or down: `flipped` says y grows downward), at `scale` points per
    /// rig unit. At actual size the scale is about 1.15, a body 23 points across.
    static func draw(_ pose: CompanionPose, in context: CGContext, center: CGPoint, scale: CGFloat, flipped: Bool) {
        context.saveGState()
        defer { context.restoreGState() }
        context.translateBy(x: center.x, y: center.y)
        context.scaleBy(x: scale, y: flipped ? scale : -scale)
        context.setShouldAntialias(true)
        context.setMiterLimit(4)

        // Arms, face, and props all ride with the body.
        let pop = max(0.01, pose.pop), squash = max(0.01, pose.squash)
        context.translateBy(x: pose.offset.x, y: pose.offset.y)
        context.rotate(by: pose.rotation * .pi / 180)
        context.scaleBy(x: (1 - pose.stretch * 0.5) * pop / squash.squareRoot(), y: (1 + pose.stretch) / pop * squash)

        drawArm(x: -9.4, angle: pose.armLeft, in: context)
        drawArm(x: 9.4, angle: pose.armRight, in: context)
        drawBody(phase: pose.phase, in: context)
        let face = Face.of(pose.expression)
        let blush = min(1, 0.45 * (pose.blush ?? face.blush))
        for x: CGFloat in [-6.3, 6.3] {
            context.fill(ellipse(x, 3.6, 1.9, 1.15), Ink.cheek.copy(alpha: blush)!)
        }
        drawFace(face, look: face.look ?? pose.look, lid: pose.lid, in: context)
        for prop in pose.props { drawProp(prop, in: context) }
    }

    // MARK: - Body

    private static func drawArm(x: CGFloat, angle: CGFloat, in context: CGContext) {
        context.saveGState()
        context.translateBy(x: x, y: 3.2)
        context.rotate(by: angle * .pi / 180)
        context.fill(ellipse(0, 1.6, 2, 3), Ink.arm, stroke: Ink.line, width: 1)
        context.restoreGState()
    }

    private static func drawBody(phase: CGFloat, in context: CGContext) {
        let disc = ellipse(0, 0, 10, 10)
        context.fill(disc, Ink.shade)
        context.saveGState()
        context.addPath(disc)
        context.clip()
        context.fill(ellipse(-2.6, -2.8, 9.6, 9.6), Ink.lit)
        context.restoreGState()
        context.fill(ellipse(4.8, -5.4, 1.4, 1.4), Ink.crater)
        context.fill(ellipse(-6, -4.4, 0.8, 0.8), Ink.crater)
        context.fill(ellipse(6.6, 5.6, 0.9, 0.9), Ink.deepCrater)
        if let night = night(phase) { context.fill(night, Ink.night) }
        context.stroke(disc, Ink.line, width: 1.1)
    }

    /// The unlit part of the face for a moon phase: the left half of the disc,
    /// plus or minus half an ellipse, so 0.5 is half lit from the right and 0 is dark.
    private static func night(_ phase: CGFloat) -> CGPath? {
        guard phase < 0.995 else { return nil }
        let f = max(0, phase)
        // Where the line between day and night crosses the middle.
        let edge = (f < 0.5 ? 1 : -1) * abs(1 - 2 * f) * 10
        let k: CGFloat = 0.5523
        let path = CGMutablePath()
        path.move(to: CGPoint(x: 0, y: -10))
        path.addCurve(to: CGPoint(x: -10, y: 0), control1: CGPoint(x: -10 * k, y: -10), control2: CGPoint(x: -10, y: -10 * k))
        path.addCurve(to: CGPoint(x: 0, y: 10), control1: CGPoint(x: -10, y: 10 * k), control2: CGPoint(x: -10 * k, y: 10))
        path.addCurve(to: CGPoint(x: edge, y: 0), control1: CGPoint(x: edge * k, y: 10), control2: CGPoint(x: edge, y: 10 * k))
        path.addCurve(to: CGPoint(x: 0, y: -10), control1: CGPoint(x: edge, y: -10 * k), control2: CGPoint(x: edge * k, y: -10))
        path.closeSubpath()
        return path
    }

    // MARK: - Face

    private static func drawFace(_ face: Face, look: CGVector, lid: CGFloat, in context: CGContext) {
        let lx = look.dx * 1.1, ly = look.dy * 0.9
        context.saveGState()
        defer { context.restoreGState() }
        context.translateBy(x: lx * 0.35, y: ly * 0.3)
        for side: CGFloat in [-1, 1] {
            let eye = face.eye(side: side, lid: lid)
            let follow: CGFloat = if case .open = eye { 1 } else { 0.4 }
            context.saveGState()
            context.translateBy(x: side * 3.6 + lx * follow, y: 0.6 + ly * follow)
            switch eye {
            case .open:
                let s = face.eyeScale * face.pupil
                context.scaleBy(x: s, y: s * lid)
                context.fill(ellipse(0, 0, 1.95, 2.55), Ink.ink)
                let shine: CGFloat = face.glossy ? 0.95 : 0.75
                context.fill(ellipse(-0.6, -1, shine, shine), Ink.white)
                if face.glossy { context.fill(ellipse(0.7, 0.9, 0.38, 0.38), Ink.white) }
            case .line(let path):
                context.stroke(path, Ink.ink, width: 1.05, cap: .round, join: .round)
            case .star:
                context.fill(Shape.star, Ink.gold, stroke: Ink.ink, width: 0.5, join: .round)
            case .heart:
                context.fill(Shape.heart, Ink.red, stroke: Ink.ink, width: 0.5, join: .round)
            }
            context.restoreGState()
        }
        if let brows = Shape.brows[face.brows] {
            context.stroke(brows, Ink.ink, width: 0.9, cap: .round)
        }
        let mouth = Shape.mouths[face.mouth]!
        if mouth.filled {
            context.fill(mouth.path, Ink.ink)
        } else {
            context.stroke(mouth.path, Ink.ink, width: 0.95, cap: .round, join: .round)
        }
        if face.tongue {
            context.fill(ellipse(0.7, 6.1, 0.9, 1.1), Ink.tongue, stroke: Ink.ink, width: 0.5)
        }
    }

    // MARK: - Props

    private static func drawProp(_ prop: CompanionProp, in context: CGContext) {
        let p = CGFloat(prop.progress)
        switch prop.kind {
        case .notes:
            for k in 0..<2 {
                let q = min(max(p * 1.4 - CGFloat(k) * 0.4, 0), 1)
                guard q > 0, q < 1 else { continue }
                context.layer(alpha: sin(q * .pi), at: CGPoint(x: 11 + CGFloat(k) * 3 + sin(q * 7) * 1.4, y: -5 - q * 12)) {
                    let head = ellipse(0, 0, 1.15, 0.9)
                    context.stroke(head, Ink.rim, width: Ink.rimWidth)
                    context.stroke(Shape.noteStem, Ink.rim, width: 0.6 + Ink.rimWidth, cap: .round, join: .round)
                    context.fill(head, Ink.ink)
                    context.stroke(Shape.noteStem, Ink.ink, width: 0.6, cap: .round)
                }
            }
        case .sparkle:
            for k in 0..<6 {
                let a = CGFloat(k) / 6 * .pi * 2 + 0.4, d = 9 + ease(p) * 9
                context.layer(at: CGPoint(x: cos(a) * d, y: sin(a) * d - 2), scale: 1.5 * (1 - p) + 0.2) {
                    context.fill(Shape.star, Ink.gold, stroke: Ink.ink, width: 0.4)
                }
            }
        case .confetti:
            for k in 0..<12 {
                let a = CGFloat(k) * 2.399
                let x = cos(a) * (6 + CGFloat(k % 4) * 4) * (0.4 + p)
                let y = -12 + p * 26 * (0.6 + CGFloat(k % 3) * 0.2) + sin(a) * 3
                let angle = (CGFloat(k) * 40 + p * 500).rounded()
                context.layer(at: CGPoint(x: x, y: y), rotation: angle) {
                    context.fill(CGPath(rect: CGRect(x: -0.7, y: -0.4, width: 1.4, height: 0.8), transform: nil),
                                 Ink.confetti[k % 5].copy(alpha: 1 - p * p)!)
                }
            }
        case .zzz:
            for k in 0..<3 {
                let q = (p * 1.2 + CGFloat(k) / 3).truncatingRemainder(dividingBy: 1)
                context.layer(alpha: sin(q * .pi), at: CGPoint(x: 8 + q * 8, y: -8 - q * 11), scale: 0.6 + q * 0.7) {
                    context.stroke(Shape.zee, Ink.rim, width: 0.75 + Ink.rimWidth, cap: .round, join: .round)
                    context.stroke(Shape.zee, Ink.ink, width: 0.75, join: .round)
                }
            }
        case .orbit:
            let a = p * .pi * 3
            context.fill(ellipse(cos(a) * 13.5, sin(a) * 4.5 - 2, 1, 1), Ink.gold, stroke: Ink.ink, width: 0.35)
        case .drop:
            let q = wrap(p)
            context.layer(alpha: 1 - q * 0.7, at: CGPoint(x: 9, y: -7 + q * 4)) {
                context.fill(Shape.drop, Ink.water, stroke: Ink.ink, width: 0.55)
            }
        case .tear:
            let q = wrap(p)
            context.layer(alpha: q < 0.85 ? 1 : (1 - q) / 0.15, at: CGPoint(x: -4.6, y: 3 + q * 5), scale: 0.6 + q * 0.3) {
                context.fill(Shape.drop, Ink.water, stroke: Ink.ink, width: 0.6)
            }
        case .heart:
            context.layer(alpha: sin(p * .pi), at: CGPoint(x: 9 + sin(p * 9) * 1.2, y: -7 - p * 9), scale: 0.7 + p * 0.4) {
                context.fill(Shape.heart, Ink.red, stroke: Ink.ink, width: 0.4)
            }
        case .hat:
            context.layer(at: CGPoint(x: -3.4, y: -8.4), rotation: -17) {
                context.fill(Shape.hat, Ink.violet, stroke: Ink.ink, width: 0.7, join: .round)
                context.stroke(Shape.hatStripes, Ink.white, width: 0.8)
                context.fill(ellipse(0, -9.4, 1.3, 1.3), Ink.yellow, stroke: Ink.ink, width: 0.5)
            }
        case .sign(let mark):
            let alarm = mark == "!"
            context.layer(at: CGPoint(x: 0, y: sin(p * .pi * 4) * 0.6)) {
                context.stroke(Shape.signStick, Ink.line, width: 0.9, cap: .round)
                let board = CGPath(roundedRect: CGRect(x: 9.2, y: -16.2, width: 9, height: 8.6), cornerWidth: 2, cornerHeight: 2, transform: nil)
                context.fill(board, alarm ? Ink.alarm : Ink.yellow, stroke: Ink.ink, width: 0.8)
                if alarm {
                    context.stroke(Shape.bang, Ink.ink, width: 1.1, cap: .round)
                    context.fill(ellipse(13.7, -9.5, 0.65, 0.65), Ink.ink)
                } else {
                    context.layer(at: CGPoint(x: 13.7, y: -11.6)) {
                        context.stroke(Shape.question, Ink.ink, width: 1, cap: .round)
                    }
                    context.fill(ellipse(13.7, -9.4, 0.6, 0.6), Ink.ink)
                }
            }
        case .check:
            let s = p < 0.3 ? ease(p / 0.3) * 1.15 : 1.15 - min(0.15, p - 0.3)
            context.layer(at: CGPoint(x: 12, y: -10), scale: s) {
                context.fill(ellipse(0, 0, 3.8, 3.8), Ink.info, stroke: Ink.ink, width: 0.7)
                context.stroke(Shape.tick, Ink.ink, width: 0.95, cap: .round, join: .round)
            }
        case .cloud:
            context.layer(at: CGPoint(x: sin(p * .pi * 2) * 1.2, y: -17)) {
                context.fill(Shape.cloud, Ink.cloud, stroke: Ink.ink, width: 0.6, join: .round)
                for (k, x) in [CGFloat(-3), 0, 3].enumerated() {
                    let q = (p * 3 + CGFloat(k) * 0.33).truncatingRemainder(dividingBy: 1)
                    let streak = CGMutablePath()
                    streak.move(to: CGPoint(x: x, y: 3 + q * 3))
                    streak.addLine(to: CGPoint(x: x - 0.5, y: 4.4 + q * 3))
                    context.stroke(streak, Ink.info.copy(alpha: 1 - q)!, width: 0.6, cap: .round)
                }
            }
        }
    }

    private static func ease(_ p: CGFloat) -> CGFloat { CGFloat(Ease.inOut(Double(p))) }

    private static func wrap(_ p: CGFloat) -> CGFloat {
        let q = p.truncatingRemainder(dividingBy: 1)
        return q < 0 ? q + 1 : q
    }

    /// An ellipse around (`x`, `y`) with radii `rx` and `ry`.
    private static func ellipse(_ x: CGFloat, _ y: CGFloat, _ rx: CGFloat, _ ry: CGFloat) -> CGPath {
        CGPath(ellipseIn: CGRect(x: x - rx, y: y - ry, width: rx * 2, height: ry * 2), transform: nil)
    }
}

// MARK: - Faces

extension CompanionArt {
    /// What each expression is made of, as in the prototype's face table.
    fileprivate struct Face {
        enum Eyes { case open, happy, closed, squint, wink, star, heart }
        enum Brows { case none, worried, determined, up, curious }
        enum Mouth { case smile, grin, o, bigO, flat, wobble, frown, cat, tiny, blep }

        /// What one eye shows in a frame.
        enum Eye {
            case open
            case line(CGPath)
            case star
            case heart
        }

        var eyes: Eyes = .open
        /// Size of open eyes.
        var eyeScale: CGFloat = 1
        /// Extra shrink of open eyes, for a startled look.
        var pupil: CGFloat = 1
        /// Bigger shine and a second highlight: eyes about to well up.
        var glossy = false
        var brows: Brows = .none
        var mouth: Mouth = .smile
        var tongue = false
        var blush: CGFloat = 0.75
        /// Where it looks no matter what, such as down when shy.
        var look: CGVector?

        static func of(_ expression: Expression) -> Face {
            switch expression {
            case .content: Face(mouth: .smile, blush: 0.75)
            case .delighted: Face(eyes: .happy, mouth: .grin, blush: 1)
            case .proud: Face(eyes: .happy, mouth: .cat, blush: 1)
            case .starry: Face(eyes: .star, mouth: .grin, blush: 1)
            case .cheeky: Face(eyes: .wink, mouth: .cat, blush: 1)
            case .blep: Face(mouth: .blep, tongue: true, blush: 0.8)
            case .asking: Face(eyeScale: 1.12, brows: .up, mouth: .o, blush: 0.8)
            case .curious: Face(brows: .curious, mouth: .o, blush: 0.6)
            case .nervous: Face(eyeScale: 0.9, pupil: 0.85, brows: .worried, mouth: .wobble, blush: 0.5)
            case .surprised: Face(eyeScale: 1.22, pupil: 0.8, brows: .up, mouth: .bigO, blush: 0.5)
            case .worried: Face(brows: .worried, mouth: .frown, blush: 0.4)
            case .teary: Face(eyeScale: 1.18, glossy: true, brows: .worried, mouth: .wobble, blush: 0.9, look: CGVector(dx: 0, dy: 0.35))
            case .oops: Face(eyes: .squint, mouth: .wobble, blush: 0.9)
            case .sleepy: Face(eyes: .closed, mouth: .tiny, blush: 0.5)
            case .focused: Face(eyeScale: 0.92, brows: .determined, mouth: .flat, blush: 0.4)
            case .shy: Face(mouth: .tiny, blush: 1.6, look: CGVector(dx: -0.9, dy: 0.8))
            case .smitten: Face(eyes: .heart, mouth: .smile, blush: 1.5)
            case .pleading: Face(eyeScale: 1.2, glossy: true, brows: .worried, mouth: .tiny, blush: 1.1, look: .zero)
            }
        }

        /// The left eye is `side` -1, the right one 1. A blink (`lid` under 0.5)
        /// turns open eyes into a flat line.
        func eye(side: CGFloat, lid: CGFloat) -> Eye {
            let open: Eye = lid < 0.5 ? .line(Shape.blink) : .open
            switch eyes {
            case .open: return open
            case .happy: return .line(Shape.happyEye)
            case .closed: return .line(Shape.closedEye)
            case .squint: return .line(side < 0 ? Shape.squintLeft : Shape.squintRight)
            case .wink: return side > 0 ? .line(Shape.happyEye) : open
            case .star: return .star
            case .heart: return .heart
            }
        }
    }
}

// MARK: - Shapes and colors

/// The prototype's shapes, built once from its SVG path data. Paths are
/// immutable once built, so sharing them across threads is safe.
private enum Shape {
    nonisolated(unsafe) static let star = svg("M0 -2.8 L0.75 -0.75 L2.8 0 L0.75 0.75 L0 2.8 L-0.75 0.75 L-2.8 0 L-0.75 -0.75Z")
    nonisolated(unsafe) static let heart = svg("M0 2.3 C-2.7 0.5 -2.5 -1.9 -1.15 -2.05 C-0.5 -2.1 0 -1.6 0 -1.05 C0 -1.6 0.5 -2.1 1.15 -2.05 C2.5 -1.9 2.7 0.5 0 2.3Z")

    nonisolated(unsafe) static let blink = svg("M-1.9 0.2 L1.9 0.2")
    nonisolated(unsafe) static let happyEye = svg("M-1.9 0.7 Q0 -1.9 1.9 0.7")
    nonisolated(unsafe) static let closedEye = svg("M-1.9 -0.1 Q0 1.5 1.9 -0.1")
    nonisolated(unsafe) static let squintLeft = svg("M-1.5 -1.4 L1.3 0 L-1.5 1.4")
    nonisolated(unsafe) static let squintRight = svg("M1.5 -1.4 L-1.3 0 L1.5 1.4")

    nonisolated(unsafe) static let brows: [CompanionArt.Face.Brows: CGPath] = [
        .worried: svg("M-5.6 -3.3 L-2.1 -4.6 M2.1 -4.6 L5.6 -3.3"),
        .determined: svg("M-5.6 -4.7 L-2.1 -3.5 M2.1 -3.5 L5.6 -4.7"),
        .up: svg("M-5.4 -4.4 Q-3.6 -6 -1.8 -4.4 M1.8 -4.4 Q3.6 -6 5.4 -4.4"),
        .curious: svg("M-5.4 -4.2 L-1.9 -4.2 M1.8 -4.6 Q3.6 -6.4 5.4 -4.6"),
    ]

    /// Filled mouths are open: dark inside, no outline.
    nonisolated(unsafe) static let mouths: [CompanionArt.Face.Mouth: (path: CGPath, filled: Bool)] = [
        .smile: (svg("M-1.5 4.6 Q0 5.9 1.5 4.6"), false),
        .grin: (svg("M-2.3 4.2 Q0 4.7 2.3 4.2 Q1.9 7.1 0 7.1 Q-1.9 7.1 -2.3 4.2Z"), true),
        .o: (CGPath(ellipseIn: CGRect(x: -0.85, y: 4.2, width: 1.7, height: 2.1), transform: nil), true),
        .bigO: (CGPath(ellipseIn: CGRect(x: -1.5, y: 3.7, width: 3, height: 3.8), transform: nil), true),
        .flat: (svg("M-1.4 5 L1.4 5"), false),
        .wobble: (svg("M-2.1 5 Q-1.4 4.2 -0.7 5 Q0 5.8 0.7 5 Q1.4 4.2 2.1 5"), false),
        .frown: (svg("M-1.5 5.6 Q0 4.4 1.5 5.6"), false),
        .cat: (svg("M-2 4.4 Q-1 5.7 0 4.6 Q1 5.7 2 4.4"), false),
        .tiny: (svg("M-0.8 4.9 Q0 5.5 0.8 4.9"), false),
        .blep: (svg("M-1.6 4.6 Q0 5.6 1.6 4.6"), false),
    ]

    nonisolated(unsafe) static let noteStem = svg("M1 -0.2 L1 -4.4 L2.8 -3.6")
    nonisolated(unsafe) static let zee = svg("M-1.1 -1.1 L1.1 -1.1 L-1.1 1.1 L1.1 1.1")
    nonisolated(unsafe) static let drop = svg("M0 -2.1 Q1.7 0.4 0 1.7 Q-1.7 0.4 0 -2.1Z")
    nonisolated(unsafe) static let hat = svg("M-4.2 0.4 L0 -9 L4.2 0.4 Z")
    nonisolated(unsafe) static let hatStripes = svg("M-2.6 -3.2 L2.6 -3.2 M-1.3 -6.2 L1.3 -6.2")
    nonisolated(unsafe) static let signStick = svg("M11.6 3 L13.4 -7.5")
    nonisolated(unsafe) static let bang = svg("M13.7 -14.4 L13.7 -11.3")
    nonisolated(unsafe) static let question = svg("M-1.25 -1.5 Q-1.25 -3 0 -3 Q1.35 -3 1.35 -1.7 Q1.35 -0.8 0.35 -0.3 Q0 -0.1 0 0.8")
    nonisolated(unsafe) static let tick = svg("M-1.8 0.1 L-0.5 1.4 L1.9 -1.3")
    nonisolated(unsafe) static let cloud = svg("M-5 1.6 Q-6.6 1.6 -6.4 -0.2 Q-6.2 -1.8 -4.4 -1.6 Q-3.8 -4 -1 -3.6 Q1.2 -5 3 -3 Q5.8 -3.2 5.6 -0.6 Q6.8 0.2 6 1.6 Z")

    /// Builds a path from SVG path data with absolute `M`, `L`, `Q`, `C`, and `Z`.
    static func svg(_ data: String) -> CGPath {
        var tokens: [String] = []
        var number = ""
        func flush() {
            if !number.isEmpty { tokens.append(number) }
            number = ""
        }
        for character in data {
            if character.isLetter {
                flush()
                tokens.append(String(character))
            } else if character == " " || character == "," {
                flush()
            } else if character == "-" {
                flush()
                number = "-"
            } else {
                number.append(character)
            }
        }
        flush()

        let path = CGMutablePath()
        var index = 0
        var command = "M"
        func point() -> CGPoint {
            defer { index += 2 }
            return CGPoint(x: Double(tokens[index])!, y: Double(tokens[index + 1])!)
        }
        while index < tokens.count {
            if tokens[index].first!.isLetter {
                command = tokens[index]
                index += 1
                if command == "Z" { path.closeSubpath() }
                continue
            }
            switch command {
            case "M":
                path.move(to: point())
                command = "L"
            case "L":
                path.addLine(to: point())
            case "Q":
                let control = point()
                path.addQuadCurve(to: point(), control: control)
            case "C":
                let control1 = point(), control2 = point()
                path.addCurve(to: point(), control1: control1, control2: control2)
            default:
                preconditionFailure("Unsupported path command \(command)")
            }
        }
        return path
    }
}

/// The companion's colors, as in the prototype.
private enum Ink {
    static let ink = rgb(0x2A241C)
    static let line = rgb(0x3B3428)
    static let shade = rgb(0xE6D8B0)
    static let lit = rgb(0xFBF4DE)
    static let crater = rgb(0xEADCB4)
    static let deepCrater = rgb(0xDCCB9C)
    static let night = rgb(0xC9B98A, alpha: 0.55)
    static let arm = rgb(0xE9DDBA)
    static let cheek = rgb(0xF2A39C)
    static let tongue = rgb(0xEF7F86)
    static let white = rgb(0xFFFFFF)
    static let gold = rgb(0xF5B82E)
    static let red = rgb(0xE5484D)
    static let water = rgb(0x9AD8F7)
    static let violet = rgb(0xB69CFF)
    static let yellow = rgb(0xFFC53D)
    /// The nervous sign: orange, since red means something went wrong.
    static let alarm = rgb(0xFF9F0A)
    static let info = rgb(0x5EC0E8)
    static let cloud = rgb(0xC3C8D0)
    static let confetti = [0x5EC0E8, 0xFFC53D, 0xFF8FA3, 0x7BD389, 0xB69CFF].map { rgb($0) }
    /// A thin edge in the face's own cream under the marks drawn in ink alone
    /// (notes and z's), so they still read on a dark desktop.
    /// On a light one it all but disappears.
    static let rim = lit
    static let rimWidth: CGFloat = 1.1

    static func rgb(_ hex: UInt32, alpha: CGFloat = 1) -> CGColor {
        CGColor(srgbRed: CGFloat(hex >> 16 & 0xFF) / 255, green: CGFloat(hex >> 8 & 0xFF) / 255,
                blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
    }
}

private extension CGContext {
    func fill(_ path: CGPath, _ color: CGColor) {
        addPath(path)
        setFillColor(color)
        fillPath()
    }

    /// Fills `path`, then outlines it.
    func fill(_ path: CGPath, _ color: CGColor, stroke: CGColor, width: CGFloat, join: CGLineJoin = .miter) {
        fill(path, color)
        self.stroke(path, stroke, width: width, join: join)
    }

    func stroke(_ path: CGPath, _ color: CGColor, width: CGFloat, cap: CGLineCap = .butt, join: CGLineJoin = .miter) {
        addPath(path)
        setStrokeColor(color)
        setLineWidth(width)
        setLineCap(cap)
        setLineJoin(join)
        strokePath()
    }

    /// Draws `content` moved to `origin`, rotated by `rotation` degrees, and
    /// scaled, faded as one piece when `alpha` is under 1.
    func layer(alpha: CGFloat = 1, at origin: CGPoint, rotation: CGFloat = 0, scale: CGFloat = 1, _ content: () -> Void) {
        guard alpha > 0.001 else { return }
        saveGState()
        defer { restoreGState() }
        translateBy(x: origin.x, y: origin.y)
        if rotation != 0 { rotate(by: rotation * .pi / 180) }
        if scale != 1 { scaleBy(x: scale, y: scale) }
        if alpha < 1 {
            setAlpha(alpha)
            beginTransparencyLayer(auxiliaryInfo: nil)
            content()
            endTransparencyLayer()
        } else {
            content()
        }
    }
}
