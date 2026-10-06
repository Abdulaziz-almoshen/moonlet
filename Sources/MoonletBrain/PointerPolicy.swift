import Foundation

/// What the agents are doing, as far as the summon view is concerned.
public enum AgentActivity: String, Sendable, Codable {
    case idle, working, waiting, done, failed
}

/// The look of the user's pointer. It changes only while an agent is talking
/// to the user; silent work never changes it.
public enum PointerTint: String, Sendable, Equatable {
    /// The standard macOS arrow.
    case system
    /// Blue: an agent is telling the user something, such as a finished task.
    case info
    /// Yellow: an agent is asking the user something and waits for the answer.
    case needsYou
    /// Red: an agent failed or seems stuck.
    case problem

    /// The tint for a card's tone.
    public init(_ kind: MomentKind) {
        switch kind {
        case .needsYou, .question: self = .needsYou
        case .failed, .stuck: self = .problem
        case .finished: self = .info
        }
    }
}

/// Decides the pointer's tint from who is talking to the user right now.
///
/// - The card at the pointer sets the color while it shows: blue for news,
///   yellow for a request, red for a problem.
/// - With no card, an agent still waiting on the user keeps the pointer yellow
///   until the user answers.
/// - Otherwise the pointer is the standard macOS arrow, including while agents work.
public struct PointerPolicy: Sendable {
    public var flashDuration: TimeInterval = 1.6
    private var flash: (tint: PointerTint, until: Date)?

    public init() {}

    /// A brief tint without a card, such as blue for a quick task the user just watched finish.
    public mutating func flash(_ tint: PointerTint, now: Date) {
        flash = (tint, now.addingTimeInterval(flashDuration))
    }

    /// The tint to show now.
    /// - Parameters:
    ///   - card: the tone of the card at the pointer, if one is showing.
    ///   - waitingOnUser: whether any agent is blocked on the user's answer.
    public mutating func tint(card: MomentKind?, waitingOnUser: Bool, now: Date) -> PointerTint {
        if let current = flash {
            if now < current.until { return current.tint }
            flash = nil
        }
        if let card { return PointerTint(card) }
        return waitingOnUser ? .needsYou : .system
    }
}
