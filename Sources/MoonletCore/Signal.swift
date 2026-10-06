/// Something worth telling the user about, produced by `AgentStore.apply(_:now:)`.
public enum Signal: Sendable, Equatable {
    /// The agent is blocked on the user.
    case needsYou(agentID: String, message: String?)
    /// The agent is no longer blocked on the user.
    case resolved(agentID: String)
    /// The agent finished its request.
    case finished(agentID: String, summary: String?)
    /// The agent stopped because of an error.
    case failed(agentID: String, message: String?)
    /// The agent reached a notable step.
    case milestone(agentID: String, text: String)
    /// The agent's effective progress changed.
    case progressChanged(agentID: String)
    /// The store started tracking the agent, or it came back after ending.
    case appeared(agentID: String)
    /// The agent's session is over.
    case ended(agentID: String)

    /// The agent the signal is about.
    public var agentID: String {
        switch self {
        case .needsYou(let id, _), .resolved(let id), .finished(let id, _), .failed(let id, _),
            .milestone(let id, _), .progressChanged(let id), .appeared(let id), .ended(let id):
            id
        }
    }
}
