import Foundation

/// What Moonlet knows about the user at one instant. Every field comes from
/// public macOS APIs that need no permission prompt.
public struct PresenceSnapshot: Sendable, Equatable {
    /// Seconds since the last key press, click, scroll, or pointer movement.
    public var secondsSinceInput: TimeInterval
    /// Seconds since the last key press.
    public var secondsSinceKey: TimeInterval
    /// True while the microphone or a camera is in use, which usually means a call.
    public var inCall: Bool
    /// Bundle identifier of the frontmost app.
    public var frontmostBundleID: String?

    public init(
        secondsSinceInput: TimeInterval,
        secondsSinceKey: TimeInterval,
        inCall: Bool = false,
        frontmostBundleID: String? = nil
    ) {
        self.secondsSinceInput = secondsSinceInput
        self.secondsSinceKey = secondsSinceKey
        self.inCall = inCall
        self.frontmostBundleID = frontmostBundleID
    }
}

/// How present the user is.
public enum PresenceLevel: String, Sendable {
    /// Input within the last few seconds.
    case active
    /// No input for a while; the user may be reading or thinking.
    case paused
    /// No input for minutes; the user has probably left.
    case away
}

/// Thresholds that turn raw input timing into a ``PresenceLevel``.
public struct PresencePolicy: Sendable, Equatable {
    /// Input more recent than this counts as active.
    public var activeWithin: TimeInterval = 5
    /// No input for this long counts as away.
    public var awayAfter: TimeInterval = 120
    /// A key press more recent than this means the user is typing.
    public var typingWithin: TimeInterval = 1.5

    public init() {}

    public func level(of presence: PresenceSnapshot) -> PresenceLevel {
        if presence.secondsSinceInput < activeWithin { return .active }
        if presence.secondsSinceInput < awayAfter { return .paused }
        return .away
    }

    public func isTyping(_ presence: PresenceSnapshot) -> Bool {
        presence.secondsSinceKey < typingWithin
    }
}
