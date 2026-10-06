/// The coarse lifecycle state of an agent session.
public enum AgentState: String, Codable, Sendable, CaseIterable {
    /// Open, but not working on anything.
    case idle
    /// Working on a request.
    case working
    /// Blocked on the user: a permission prompt, a question, or a plan to review.
    case waiting
    /// Finished the last request.
    case done
    /// Stopped because of an error.
    case failed

    /// Whether this state ends a turn (`done` or `failed`).
    public var isFinished: Bool { self == .done || self == .failed }
}
