import Foundation

/// What happened to an agent that may deserve the user's attention.
public enum MomentKind: String, Sendable, Codable, CaseIterable {
    /// The agent is blocked until the user acts: a permission prompt, a plan to review.
    case needsYou
    /// The agent finished its turn, but its last message asks the user something.
    case question
    /// The agent's run failed.
    case failed
    /// A working agent has been silent for unusually long.
    case stuck
    /// The agent finished its task.
    case finished

    /// Lower values are shown first.
    public var priority: Int {
        switch self {
        case .needsYou, .question: 0
        case .failed: 1
        case .stuck: 2
        case .finished: 3
        }
    }

    /// Whether the agent stays blocked until the user acts.
    public var isBlocking: Bool { self == .needsYou || self == .question }
}

/// One notification-worthy event, already reduced to a few words.
public struct Moment: Sendable, Equatable, Identifiable, Codable {
    public var id: UUID
    /// Stable identity of the agent session (`source:session`).
    public var agentID: String
    /// Unique display name of the agent, such as `api-refactor` or `api-refactor 2`.
    public var agentLabel: String
    /// Project the agent works in; drives per-project learning and batching.
    public var project: String
    public var kind: MomentKind
    /// A few words: an outcome, a request, or an error.
    public var detail: String
    public var createdAt: Date
    /// Bundle identifier of the app hosting the agent (terminal, IDE, Claude app).
    public var hostBundleID: String?
    /// True when this moment repeats an earlier, still unresolved one.
    public var isReminder: Bool

    public init(
        id: UUID = UUID(),
        agentID: String,
        agentLabel: String,
        project: String,
        kind: MomentKind,
        detail: String,
        createdAt: Date,
        hostBundleID: String? = nil,
        isReminder: Bool = false
    ) {
        self.id = id
        self.agentID = agentID
        self.agentLabel = agentLabel
        self.project = project
        self.kind = kind
        self.detail = detail
        self.createdAt = createdAt
        self.hostBundleID = hostBundleID
        self.isReminder = isReminder
    }
}
