import Foundation
import MoonletCore

/// A one-minute scripted scenario with six agents, played through the real
/// pipeline so anyone can see Moonlet work before connecting an agent. Each
/// moment brings out the companion in a different mood: asking for a
/// permission, celebrating a deploy, curious about a question, cheeky about a
/// typo, teary about a failure, nervous about `rm -rf`, and proud of green tests.
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
            (0.0, event("landing-page", .working, title: "Build the landing page", activity: "Building the pricing grid", done: 2, of: 6)),
            (0.2, event("api-refactor", .working, title: "Paginate the orders API", activity: "Editing Orders.swift", done: 3)),
            (0.4, event("db-migration", .working, title: "Move orders to the v2 schema", activity: "Applying migration 3", done: 2, of: 4)),
            (0.6, event("web-app", .working, title: "Ship the checkout fix", activity: "Running the deploy", done: 4)),
            (0.8, event("docs-site", .working, title: "Tidy the README", activity: "Reading README.md", done: 0, of: 1)),
            // Working agents stay silent: no companion, the normal arrow.
            (4.0, event("landing-page", .waiting, message: "Wants to run npm install")),
            (12.0, event("landing-page", .working, activity: "Installing packages", done: 3, of: 6)),
            (15.0, event("web-app", .done, summary: "Deployed to production. The checkout fix is live.", done: 5)),
            (22.0, event("api-refactor", .waiting, message: "Which database should the tests use? SQLite · Postgres")),
            (31.0, event("api-refactor", .working, activity: "Running tests", done: 4)),
            (33.0, event("docs-site", .done, summary: "Fixed a typo in the README.", done: 1, of: 1)),
            (39.0, event("db-migration", .failed, message: "Staging database refused the connection (ECONNREFUSED)")),
            (46.0, event("infra", .waiting, title: "Clean the build cache", message: "Wants to run rm -rf build/")),
            (53.0, event("infra", .working, activity: "Cleaning the build cache")),
            (55.0, event("api-refactor", .done, summary: "All 14 tests pass.", done: 5)),
            (66.0, event("landing-page", end: true)),
            (66.0, event("db-migration", end: true)),
            (66.0, event("api-refactor", end: true)),
            (66.0, event("web-app", end: true)),
            (66.0, event("docs-site", end: true)),
            (66.0, event("infra", end: true)),
        ]
    }
}
