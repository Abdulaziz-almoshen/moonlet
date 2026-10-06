import Foundation
import MoonletCore

/// A one-minute scripted scenario with three agents, played through the real
/// pipeline so anyone can see Moonlet work before connecting an agent: a
/// permission request and a question (yellow), news (blue), and a failure (red).
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
            (0.0, event("landing-page", .working, title: "Build the landing page", activity: "Building the pricing grid")),
            (0.2, event("api-refactor", .working, title: "Paginate the orders API", activity: "Editing Orders.swift", done: 3)),
            (0.4, event("db-migration", .working, title: "Move orders to the v2 schema", activity: "Applying migration 3", done: 2, of: 4)),
            // Working agents stay silent; the pointer is the normal arrow.
            (4.0, event("landing-page", .waiting, message: "Wants to run npm install")),
            (14.0, event("landing-page", .working, activity: "Installing packages")),
            (16.0, event("api-refactor", .waiting, message: "Which database should the tests use? SQLite · Postgres")),
            (26.0, event("api-refactor", .working, activity: "Running tests", done: 4)),
            (28.0, event("landing-page", .done, summary: "The landing page is live on the preview URL and Lighthouse scores 98.")),
            (36.0, event("db-migration", .failed, message: "Staging database refused the connection (ECONNREFUSED)")),
            (46.0, event("api-refactor", .done, summary: "Cursor pagination shipped on /orders and all 14 tests pass.", done: 5)),
            (60.0, event("landing-page", end: true)),
            (60.0, event("db-migration", end: true)),
            (60.0, event("api-refactor", end: true)),
        ]
    }
}
