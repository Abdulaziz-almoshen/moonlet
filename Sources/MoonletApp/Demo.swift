import Foundation
import MoonletCore

/// A one-minute scripted scenario with three agents, played through the real
/// pipeline so anyone can see Moonlet work before connecting an agent.
@MainActor
final class Demo {
    private let send: (MoonletEvent) -> Void
    private var pending: [DispatchWorkItem] = []

    init(send: @escaping (MoonletEvent) -> Void) {
        self.send = send
    }

    func start() {
        for (delay, event) in Self.script() {
            let item = DispatchWorkItem { [send] in MainActor.assumeIsolated { send(event) } }
            pending.append(item)
            DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: item)
        }
    }

    func cancel() {
        pending.forEach { $0.cancel() }
        pending.removeAll()
    }

    static func script() -> [(TimeInterval, MoonletEvent)] {
        func event(_ session: String, _ state: AgentState? = nil, title: String? = nil, activity: String? = nil,
                   summary: String? = nil, message: String? = nil, done: Int? = nil, of total: Int = 5,
                   end: Bool = false) -> MoonletEvent {
            MoonletEvent(kind: end ? .end : .update, source: "demo", session: session, label: session, state: state,
                         title: title, activity: activity, summary: summary, message: message,
                         progress: done.map { AgentProgress(done: $0, total: total) }, cwd: "/tmp/\(session)")
        }
        return [
            (0.0, event("api-refactor", .working, title: "Paginate the orders API", activity: "Reading routes/orders.ts", done: 1)),
            (0.3, event("landing-page", .working, title: "Build the landing page", activity: "Scaffolding the hero section")),
            (0.6, event("db-migration", .working, title: "Move orders to the v2 schema", activity: "Planning schema changes", done: 0, of: 4)),
            (3.0, event("api-refactor", activity: "Editing orders.ts", done: 2)),
            (5.0, event("landing-page", .waiting, message: "Needs permission to run npm install")),
            (7.0, event("db-migration", activity: "Applying migration 3", done: 3, of: 4)),
            (9.0, event("api-refactor", activity: "Running tests", done: 4)),
            (11.0, event("landing-page", .working, activity: "Building the pricing grid")),
            (13.0, event("api-refactor", .done, summary: """
                I refactored /orders to cursor-based pagination, added an index on (created_at, id), \
                and wrote 6 new tests. All 14 tests in the orders suite pass.
                """, done: 5)),
            (16.0, event("db-migration", .failed, message: "Staging database refused the connection (ECONNREFUSED)")),
            (20.0, event("landing-page", .done, summary: """
                The landing page is live on the preview URL and Lighthouse scores 98. \
                Should I also add the pricing FAQ section?
                """)),
            (60.0, event("api-refactor", end: true)),
            (60.0, event("db-migration", end: true)),
            (90.0, event("landing-page", end: true)),
        ]
    }
}
