import Foundation
import MoonletBrain

/// One agent as Moonlet shows it in the summon view and the menu.
struct AgentRow: Identifiable, Equatable {
    var id: String
    var label: String
    /// Where the agent runs: iTerm, Terminal, VS Code, Claude.
    var place: String
    var activity: AgentActivity
    /// Completed share of the agent's own task list, when it keeps one.
    var progress: Double?
    /// A few words about what it's doing or did.
    var status: String
    /// When the agent entered its current state.
    var since: Date
    /// How its latest message felt, which sets its face. `nil` while it works quietly.
    var mood: CompanionMood?
    /// The choices in the agent's question, such as `SQLite` and `Postgres`.
    var options: [String] = []
    /// Minutes until a working agent is likely done, from its task-list pace.
    var etaMinutes: Int?
    /// Whether it changed since the user last opened the summon view.
    var isNew = false
}

/// Something that happened in the last hour, for the summon view's timeline.
struct TimelineEvent: Equatable, Identifiable {
    var id: UUID
    var at: Date
    var kind: MomentKind
    var mood: CompanionMood
    /// A few words: `api-refactor · Deployed to production`.
    var label: String
}

/// Everything the summon view shows.
struct SummonContent: Equatable {
    var agents: [AgentRow] = []
    /// The last hour, oldest first.
    var events: [TimelineEvent] = []
    var earlier: [Moment] = []
    var suggestion: String?
}
