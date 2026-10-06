import Foundation

/// How long `AgentStore` keeps agents around. The defaults suit an always-on menu bar app.
public struct StoreConfig: Sendable, Equatable {
    /// How long an agent that ended without finishing stays listed. Default: 10 seconds.
    public var endedGrace: TimeInterval
    /// How long `done` and `failed` agents stay listed after finishing, ended or not.
    /// Default: 2 hours.
    public var keepFinished: TimeInterval
    /// How long an `idle` or `working` agent may go without updates before it's dropped,
    /// which covers sessions that died without ending. `waiting` agents never expire this
    /// way, because they need the user. Default: 2 hours.
    public var staleAfter: TimeInterval

    public init(
        endedGrace: TimeInterval = 10,
        keepFinished: TimeInterval = 2 * 60 * 60,
        staleAfter: TimeInterval = 2 * 60 * 60
    ) {
        self.endedGrace = endedGrace
        self.keepFinished = keepFinished
        self.staleAfter = staleAfter
    }
}

/// Agent totals by state.
public struct AgentCounts: Sendable, Equatable {
    public var idle = 0
    public var working = 0
    public var waiting = 0
    public var done = 0
    public var failed = 0

    public init() {}

    public var total: Int { idle + working + waiting + done + failed }

    public subscript(state: AgentState) -> Int {
        get {
            switch state {
            case .idle: idle
            case .working: working
            case .waiting: waiting
            case .done: done
            case .failed: failed
            }
        }
        set {
            switch state {
            case .idle: idle = newValue
            case .working: working = newValue
            case .waiting: waiting = newValue
            case .done: done = newValue
            case .failed: failed = newValue
            }
        }
    }
}

/// Turns a stream of `MoonletEvent`s into agents and the `Signal`s worth surfacing.
///
/// A plain value type: the owner decides where it lives and serializes access.
public struct AgentStore: Sendable {
    public var config: StoreConfig
    /// Tracked agents, oldest first.
    public private(set) var agents: [Agent] = []
    /// The label each agent asked for, before de-duplication.
    private var requestedLabels: [String: String] = [:]

    public init(config: StoreConfig = StoreConfig()) {
        self.config = config
    }

    public func agent(id: String) -> Agent? {
        agents.first { $0.id == id }
    }

    /// Totals by state. Agents that ended without finishing aren't counted.
    public var counts: AgentCounts {
        var counts = AgentCounts()
        for agent in agents where !agent.ended || agent.state.isFinished {
            counts[agent.state] += 1
        }
        return counts
    }

    /// Applies an event and returns the signals it caused, in this order: `appeared`,
    /// `resolved`, `milestone`, `progressChanged`, then one of `needsYou`, `finished`, or
    /// `failed`; or for an end event, `resolved` and `ended`.
    @discardableResult
    public mutating func apply(_ event: MoonletEvent, now: Date) -> [Signal] {
        switch event.kind {
        case .update: update(with: event, now: now)
        case .end: end(id: event.agentID, now: now)
        }
    }

    /// Drops agents that have outlived `config`. Returns whether any were removed.
    @discardableResult
    public mutating func prune(now: Date) -> Bool {
        let config = config
        let expired = Set(agents.lazy.filter { $0.isExpired(at: now, config: config) }.map(\.id))
        guard !expired.isEmpty else { return false }
        agents.removeAll { expired.contains($0.id) }
        for id in expired {
            requestedLabels[id] = nil
        }
        return true
    }

    // MARK: Updates

    private mutating func update(with event: MoonletEvent, now: Date) -> [Signal] {
        let id = event.agentID
        var signals: [Signal] = []
        let previous: Agent?
        var agent: Agent

        if let existing = self.agent(id: id) {
            previous = existing
            agent = existing
            if agent.ended {
                agent.ended = false
                agent.label = uniqueLabel(requestedLabels[id] ?? agent.label, for: id)
                signals.append(.appeared(agentID: id))
            }
            if let label = Self.label(from: event.label), label != requestedLabels[id] {
                requestedLabels[id] = label
                agent.label = uniqueLabel(label, for: id)
            }
        } else {
            previous = nil
            let label = Self.initialLabel(for: event)
            requestedLabels[id] = label
            agent = Agent(
                source: event.source, session: event.session, label: uniqueLabel(label, for: id),
                state: event.state ?? .idle, firstSeen: now)
            signals.append(.appeared(agentID: id))
        }

        agent.merge(event, now: now)

        let oldState = previous?.state
        if oldState == .waiting, agent.state != .waiting {
            signals.append(.resolved(agentID: id))
        }

        if let milestone = Self.line(event.milestone, limit: FieldLimit.milestone) {
            if milestone != agent.lastMilestone {
                agent.lastMilestone = milestone
                signals.append(.milestone(agentID: id, text: milestone))
            }
        } else if let previous,
            let title = Self.newlyCompletedTaskTitle(before: previous.tasks, after: agent.tasks)
        {
            agent.lastMilestone = title
            signals.append(.milestone(agentID: id, text: title))
        }

        if agent.progress != previous?.progress {
            signals.append(.progressChanged(agentID: id))
        }

        switch agent.state {
        case .waiting where oldState != .waiting || agent.message != previous?.message:
            signals.append(.needsYou(agentID: id, message: agent.message))
        case .done where oldState != .done:
            signals.append(.finished(agentID: id, summary: agent.summary))
        case .failed where oldState != .failed:
            signals.append(.failed(agentID: id, message: agent.message ?? agent.summary))
        default:
            break
        }

        if let index = agents.firstIndex(where: { $0.id == id }) {
            agents[index] = agent
        } else {
            agents.append(agent)
        }
        return signals
    }

    private mutating func end(id: String, now: Date) -> [Signal] {
        guard let index = agents.firstIndex(where: { $0.id == id }), !agents[index].ended else {
            return []
        }
        var signals: [Signal] = []
        if agents[index].state == .waiting {
            signals.append(.resolved(agentID: id))
        }
        agents[index].ended = true
        agents[index].lastUpdate = now
        signals.append(.ended(agentID: id))
        return signals
    }

    // MARK: Labels

    private func uniqueLabel(_ label: String, for id: String) -> String {
        let taken = Set(agents.lazy.filter { $0.id != id && !$0.ended }.map(\.label))
        guard taken.contains(label) else { return label }
        var suffix = 2
        while taken.contains("\(label) \(suffix)") {
            suffix += 1
        }
        return "\(label) \(suffix)"
    }

    private static func initialLabel(for event: MoonletEvent) -> String {
        if let label = label(from: event.label) {
            return label
        }
        if let cwd = event.cwd, let label = label(from: TextTools.label(fromCwd: cwd)) {
            return label
        }
        return "session-\(event.session.prefix(6))"
    }

    private static func label(from text: String?) -> String? {
        line(text, limit: FieldLimit.label)
    }

    // MARK: Helpers

    /// `text` as a single line of at most `limit` characters, or `nil` when it's missing or blank.
    static func line(_ text: String?, limit: Int) -> String? {
        guard let text else { return nil }
        let line = TextTools.oneLine(text, max: limit)
        return line.isEmpty ? nil : line
    }

    /// The title of a task that just became completed, if the completed count rose.
    static func newlyCompletedTaskTitle(before: [TaskItem], after: [TaskItem]) -> String? {
        let completedBefore = before.filter { $0.status == .completed }
        let completedAfter = after.filter { $0.status == .completed }
        guard completedAfter.count > completedBefore.count else { return nil }
        let previouslyCompleted = Set(completedBefore.map(\.id))
        let newlyCompleted = completedAfter.filter { !previouslyCompleted.contains($0.id) }
        let candidates = newlyCompleted.isEmpty ? completedAfter : newlyCompleted
        return candidates.last { !$0.title.isEmpty }?.title
    }
}

/// Upper bounds, in characters, for the one-line fields the store keeps.
enum FieldLimit {
    static let label = 40
    static let title = 80
    static let activity = 60
    static let message = 120
    static let milestone = 80
}

extension Agent {
    /// Applies an update event's fields. Signals are derived by the store afterwards.
    fileprivate mutating func merge(_ event: MoonletEvent, now: Date) {
        let oldState = state
        if let newState = event.state, newState != state {
            state = newState
            stateChangedAt = now
            if oldState == .waiting {
                message = nil
            }
            if oldState == .working {
                activity = nil
            }
            // Starting new work after a finished or idle turn wipes that turn's results.
            if oldState == .idle || oldState.isFinished, newState == .working || newState == .waiting {
                summary = nil
                lastMilestone = nil
            }
        }

        patch(\.title, with: event.title, limit: FieldLimit.title)
        patch(\.activity, with: event.activity, limit: FieldLimit.activity)
        patch(\.message, with: event.message, limit: FieldLimit.message)
        if let summary = event.summary {
            self.summary = summary.isEmpty ? nil : summary
        }
        if let tasks = event.tasks {
            self.tasks = []
            for task in tasks {
                upsert(task)
            }
        }
        if let task = event.task {
            upsert(task)
        }
        if let progress = event.progress {
            explicitProgress =
                progress.total > 0
                ? AgentProgress(done: min(max(progress.done, 0), progress.total), total: progress.total)
                : nil
        }
        if let cwd = event.cwd, !cwd.isEmpty {
            self.cwd = cwd
        }
        if let host = event.host, !host.isEmpty {
            self.host = host
        }
        lastUpdate = now
    }

    private mutating func patch(_ field: WritableKeyPath<Agent, String?>, with value: String?, limit: Int) {
        guard let value else { return }
        self[keyPath: field] = AgentStore.line(value, limit: limit)
    }

    /// Inserts, updates, or removes a task by id. An empty title keeps the stored title.
    private mutating func upsert(_ task: TaskItem) {
        let index = tasks.firstIndex { $0.id == task.id }
        switch (index, task.status) {
        case (let index?, .deleted):
            tasks.remove(at: index)
        case (nil, .deleted):
            break
        case (let index?, _):
            tasks[index].status = task.status
            if !task.title.isEmpty {
                tasks[index].title = task.title
            }
        case (nil, _):
            tasks.append(task)
        }
    }

    fileprivate func isExpired(at now: Date, config: StoreConfig) -> Bool {
        if state.isFinished {
            return now.timeIntervalSince(stateChangedAt) >= config.keepFinished
        }
        if ended {
            return now.timeIntervalSince(lastUpdate) >= config.endedGrace
        }
        switch state {
        case .idle, .working:
            return now.timeIntervalSince(lastUpdate) >= config.staleAfter
        case .waiting, .done, .failed:
            return false
        }
    }
}
