/// One entry of an agent's task list.
public struct TaskItem: Codable, Sendable, Equatable, Identifiable {
    /// Where a task stands.
    public enum Status: String, Codable, Sendable, CaseIterable {
        case pending
        case inProgress = "in_progress"
        case completed
        /// Removes the task. Only meaningful in a single-task upsert; never stored.
        case deleted
    }

    /// Identifier, unique within one agent's list.
    public var id: String
    /// What the task is about. In an upsert, an empty title keeps the stored one.
    public var title: String
    public var status: Status

    public init(id: String, title: String, status: Status = .pending) {
        self.id = id
        self.title = title
        self.status = status
    }
}
