import CoreGraphics
import MoonletBrain

/// Something the companion holds, wears, or gives off, with how far along its
/// little animation is (`progress`, 0...1; looping props wrap around).
struct CompanionProp: Equatable {
    enum Kind: Equatable {
        /// Two music notes rising while it hums.
        case notes
        /// A burst of six stars.
        case sparkle
        /// Confetti falling around it.
        case confetti
        /// Three z's drifting up while it dozes.
        case zzz
        /// A speck orbiting it while it thinks.
        case orbit
        /// A sweat drop beside its head.
        case drop
        /// A tear rolling down its cheek.
        case tear
        /// A heart floating up.
        case heart
        /// A party hat.
        case hat
        /// A small sign on a stick, held up by the right arm, with `?` or `!`.
        case sign(Character)
        /// A check badge popping in.
        case check
        /// A small rain cloud above its head.
        case cloud
    }

    var kind: Kind
    var progress: Double
}

/// Everything that decides how the companion looks in one frame. Distances are
/// in rig units: the body is a circle of radius 10, the origin at its center,
/// y growing downward.
struct CompanionPose: Equatable {
    var expression: Expression = .content
    /// Where it looks, -1...1 on each axis; (0, 0) is straight at you.
    var look = CGVector.zero
    /// 1 with eyes open, about 0.12 mid-blink.
    var lid: CGFloat = 1
    /// The body's offset from its resting place: hops, shivers.
    var offset = CGPoint.zero
    /// Body rotation in degrees, clockwise.
    var rotation: CGFloat = 0
    /// Vertical scale of the body; the width scales by 1/√squash so the volume stays.
    var squash: CGFloat = 1
    /// Extra stretch along the direction of travel, 0...0.25.
    var stretch: CGFloat = 0
    /// A short scale pulse when the expression changes, around 1.
    var pop: CGFloat = 1
    /// Arm angles in degrees; 0 hangs down. The left arm raises with positive
    /// angles, the right arm with negative ones.
    var armLeft: CGFloat = 0
    var armRight: CGFloat = 0
    /// Overrides the expression's blush, 0...1.6.
    var blush: CGFloat?
    /// Lit share of the face, like a moon phase: 1 is full, 0.5 half lit from the right.
    var phase: CGFloat = 1
    var props: [CompanionProp] = []
}
