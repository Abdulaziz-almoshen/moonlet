import Foundation

/// The app's view of one agent session, built from events by `AgentStore`.
public struct Agent: Codable, Sendable, Equatable, Identifiable {
    /// `"source:session"`.
    public let id: String
    public let source: String
    public let session: String
    /// Display label, unique among agents that haven't ended.
    public var label: String
    public var state: AgentState
    /// What the agent was asked.
    public var title: String?
    /// What it's doing now.
    public var activity: String?
    /// Its final message, unabridged.
    public var summary: String?
    /// What it needs (waiting) or why it failed (failed).
    public var message: String?
    public var lastMilestone: String?
    public var tasks: [TaskItem]
    /// Progress reported explicitly by the producer.
    public var explicitProgress: AgentProgress?
    public var cwd: String?
    public var host: HostInfo?
    public var firstSeen: Date
    public var lastUpdate: Date
    public var stateChangedAt: Date
    /// Whether the session is over.
    public var ended: Bool

    public init(
        source: String,
        session: String,
        label: String,
        state: AgentState = .idle,
        title: String? = nil,
        activity: String? = nil,
        summary: String? = nil,
        message: String? = nil,
        lastMilestone: String? = nil,
        tasks: [TaskItem] = [],
        explicitProgress: AgentProgress? = nil,
        cwd: String? = nil,
        host: HostInfo? = nil,
        firstSeen: Date,
        lastUpdate: Date? = nil,
        stateChangedAt: Date? = nil,
        ended: Bool = false
    ) {
        self.id = Self.id(source: source, session: session)
        self.source = source
        self.session = session
        self.label = label
        self.state = state
        self.title = title
        self.activity = activity
        self.summary = summary
        self.message = message
        self.lastMilestone = lastMilestone
        self.tasks = tasks
        self.explicitProgress = explicitProgress
        self.cwd = cwd
        self.host = host
        self.firstSeen = firstSeen
        self.lastUpdate = lastUpdate ?? firstSeen
        self.stateChangedAt = stateChangedAt ?? firstSeen
        self.ended = ended
    }

    /// The agent identifier for a source and session.
    public static func id(source: String, session: String) -> String {
        "\(source):\(session)"
    }

    /// Explicit progress if reported, otherwise completed tasks out of all tasks, otherwise `nil`.
    public var progress: AgentProgress? {
        explicitProgress ?? AgentProgress(tasks: tasks)
    }

    // MARK: Codable

    // Dates travel as seconds since 1970, and `progress` carries the effective value,
    // so clients never need to know how it was derived.
    enum CodingKeys: String, CodingKey {
        case id, source, session, label, state, title, activity, summary, message
        case lastMilestone = "last_milestone"
        case tasks, progress, cwd, host
        case firstSeen = "first_seen"
        case lastUpdate = "last_update"
        case stateChangedAt = "state_changed_at"
        case ended
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        source = try container.decode(String.self, forKey: .source)
        session = try container.decode(String.self, forKey: .session)
        label = try container.decode(String.self, forKey: .label)
        state = try container.decode(AgentState.self, forKey: .state)
        title = try container.decodeIfPresent(String.self, forKey: .title)
        activity = try container.decodeIfPresent(String.self, forKey: .activity)
        summary = try container.decodeIfPresent(String.self, forKey: .summary)
        message = try container.decodeIfPresent(String.self, forKey: .message)
        lastMilestone = try container.decodeIfPresent(String.self, forKey: .lastMilestone)
        tasks = try container.decodeIfPresent([TaskItem].self, forKey: .tasks) ?? []
        explicitProgress = try container.decodeIfPresent(AgentProgress.self, forKey: .progress)
        cwd = try container.decodeIfPresent(String.self, forKey: .cwd)
        host = try container.decodeIfPresent(HostInfo.self, forKey: .host)
        firstSeen = Date(timeIntervalSince1970: try container.decode(Double.self, forKey: .firstSeen))
        lastUpdate = Date(timeIntervalSince1970: try container.decode(Double.self, forKey: .lastUpdate))
        stateChangedAt = Date(timeIntervalSince1970: try container.decode(Double.self, forKey: .stateChangedAt))
        ended = try container.decodeIfPresent(Bool.self, forKey: .ended) ?? false
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(source, forKey: .source)
        try container.encode(session, forKey: .session)
        try container.encode(label, forKey: .label)
        try container.encode(state, forKey: .state)
        try container.encodeIfPresent(title, forKey: .title)
        try container.encodeIfPresent(activity, forKey: .activity)
        try container.encodeIfPresent(summary, forKey: .summary)
        try container.encodeIfPresent(message, forKey: .message)
        try container.encodeIfPresent(lastMilestone, forKey: .lastMilestone)
        try container.encode(tasks, forKey: .tasks)
        try container.encodeIfPresent(progress, forKey: .progress)
        try container.encodeIfPresent(cwd, forKey: .cwd)
        try container.encodeIfPresent(host, forKey: .host)
        try container.encode(firstSeen.timeIntervalSince1970, forKey: .firstSeen)
        try container.encode(lastUpdate.timeIntervalSince1970, forKey: .lastUpdate)
        try container.encode(stateChangedAt.timeIntervalSince1970, forKey: .stateChangedAt)
        try container.encode(ended, forKey: .ended)
    }
}
