import CoreGraphics
import Foundation

/// Where the companion and its card go on screen, and when a parked card takes
/// input. Screen points with y growing upward, as AppKit reports them. Pure, so
/// the app's director only reads the screen and applies the answers.
public enum CompanionStage {
    /// Where the companion rides relative to the pointer's tip, in points, y down:
    /// just past the arrow's tail, so it never covers the tip or the arrow.
    public static let pointerOffset = CGVector(dx: 20, dy: 28)
    /// How far the companion reaches from its center: its body and arms.
    public static let reach: CGFloat = 14
    /// The card window's transparent margin around its visible box (`CardView` padding).
    public static let cardInset: CGFloat = 10
    /// How long the pointer rests on a parked card before the card takes clicks.
    public static let restBeforeInput: TimeInterval = 0.15
    /// How long a parked card stays click-through after any scroll, so it never catches one.
    public static let quietAfterScroll: TimeInterval = 0.3

    // MARK: - Placement

    /// Where the companion rides for the pointer at `pointer`, on a screen whose
    /// frame is `screen`: below and right of the tip, mirrored to the pointer's
    /// left near the right edge, above the tip near the bottom edge, and always
    /// inside the screen.
    public static func ridingSpot(pointer: CGPoint, screen: CGRect) -> CGPoint {
        var x = pointer.x + pointerOffset.dx
        var y = pointer.y - pointerOffset.dy
        if x + reach > screen.maxX { x = pointer.x - pointerOffset.dx }
        if y - reach < screen.minY { y = pointer.y + reach }
        return keepOnScreen(CGPoint(x: x, y: y), screen: screen)
    }

    /// The companion at `point`, moved just enough to stay whole inside `screen`.
    public static func keepOnScreen(_ point: CGPoint, screen: CGRect) -> CGPoint {
        CGPoint(x: min(max(screen.minX + reach, point.x), screen.maxX - reach),
                y: min(max(screen.minY + reach, point.y), screen.maxY - reach))
    }

    /// Where a card's window of `size` goes for the companion at `companion`: to
    /// its right and a little above, flipping below and to its left near the
    /// right edge, so it never covers the pointer's tip. Kept inside `bounds`,
    /// the screen's visible frame.
    public static func cardOrigin(companion: CGPoint, size: CGSize, bounds: CGRect) -> CGPoint {
        var x = companion.x + 22 - cardInset
        var top = companion.y + 20 + cardInset
        if x + size.width > bounds.maxX - 8 {
            x = companion.x - 22 - (size.width - cardInset)
            top = companion.y - 14 + cardInset
        }
        var origin = CGPoint(x: x, y: top - size.height)
        origin.x = min(max(bounds.minX + 4, origin.x), bounds.maxX - size.width - 4)
        origin.y = min(max(bounds.minY + 4, origin.y), bounds.maxY - size.height - 4)
        return origin
    }

    /// Where a card's window of `size` goes without the companion, as cards always
    /// rode: below and right of the pointer, flipping left and up at the edges of
    /// `bounds`, the screen's visible frame.
    public static func followingOrigin(pointer: CGPoint, size: CGSize, bounds: CGRect) -> CGPoint {
        var origin = CGPoint(x: pointer.x + 22, y: pointer.y - 30 - size.height)
        if origin.x + size.width > bounds.maxX - 8 { origin.x = pointer.x - 16 - size.width }
        if origin.y < bounds.minY + 8 { origin.y = pointer.y + 18 }
        origin.x = max(bounds.minX + 8, origin.x)
        origin.y = min(bounds.maxY - size.height - 8, origin.y)
        return origin
    }

    /// `origin` moved just enough that a window of `size` lies inside `bounds`.
    /// A window too big to fit keeps its top-left corner on screen.
    public static func clamp(_ origin: CGPoint, size: CGSize, into bounds: CGRect) -> CGPoint {
        CGPoint(x: max(bounds.minX, min(origin.x, bounds.maxX - size.width)),
                y: min(bounds.maxY - size.height, max(bounds.minY, origin.y)))
    }

    /// The part of a card's window the user sees: the window without its margin.
    public static func visibleBox(origin: CGPoint, size: CGSize) -> CGRect {
        CGRect(origin: origin, size: size).insetBy(dx: cardInset, dy: cardInset)
    }

    // MARK: - Input

    /// Whether a parked card takes clicks now: only with the pointer on its
    /// visible `box` (never its transparent margin) for `restBeforeInput`, and
    /// never within `quietAfterScroll` of a scroll. Otherwise it's click-through.
    public static func parkedCardTakesInput(
        pointer: CGPoint, box: CGRect, restedFor: TimeInterval, secondsSinceScroll: TimeInterval
    ) -> Bool {
        box.contains(pointer) && restedFor >= restBeforeInput && secondsSinceScroll >= quietAfterScroll
    }

    /// Whether an event that landed on the card at `timestamp` was made while the
    /// card took input: it takes input now, or the event is no newer than the
    /// moment it last went click-through, such as a second click queued behind
    /// the first. Times are seconds since startup, the clock of `NSEvent.timestamp`.
    public static func cardTookEvent(at timestamp: TimeInterval, takesInputNow: Bool, clickThroughSince: TimeInterval) -> Bool {
        takesInputNow || timestamp <= clickThroughSince + 0.05
    }
}

extension Card {
    /// The moment the card is about: the first whose kind sets the card's
    /// color, else the first. Its words decide the companion's mood.
    public var leadMoment: Moment? {
        moments.first { $0.kind == tone } ?? moments.first
    }

    /// The agents on the card that wait on the user, in card order, each once.
    public var waitingAgentIDs: [String] {
        var seen = Set<String>()
        return moments.filter { $0.kind.isBlocking && seen.insert($0.agentID).inserted }.map(\.agentID)
    }
}
