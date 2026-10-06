/// Progress as `done` out of `total` steps.
///
/// Named `AgentProgress` rather than `Progress` so it never clashes with
/// `Foundation.Progress` in files that import both modules.
public struct AgentProgress: Codable, Sendable, Equatable {
    public var done: Int
    public var total: Int

    public init(done: Int, total: Int) {
        self.done = done
        self.total = total
    }

    /// Completed tasks out of all tasks, or `nil` for an empty list.
    public init?(tasks: [TaskItem]) {
        guard !tasks.isEmpty else { return nil }
        self.init(done: tasks.count { $0.status == .completed }, total: tasks.count)
    }

    /// The completed fraction, clamped to `0...1`.
    public var fraction: Double {
        guard total > 0 else { return 0 }
        return min(max(Double(done) / Double(total), 0), 1)
    }
}
