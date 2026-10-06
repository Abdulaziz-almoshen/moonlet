import Foundation
import MoonletCore
import MoonletIPC

/// `moonlet demo [--speed X]`: about 25 seconds of three scripted sessions that cover
/// progress, needing the user, resolving, finishing, and failing, so the app can be tried
/// without real agents.
enum DemoCommand {
    static func run(_ arguments: [String], paths: MoonletPaths) async throws -> Int32 {
        var arguments = Arguments(arguments)
        let speedText = try arguments.option("--speed")
        try arguments.finish()
        guard let speed = Double(speedText ?? "1"), speed > 0, speed.isFinite else {
            throw UsageError("--speed must be a positive number, such as 2 or 0.5.")
        }
        guard MoonletClient.status(paths: paths, timeout: 1) != nil else {
            Console.error("Moonlet isn't running. Start the app, then run the demo again.")
            return 1
        }

        let clock = ContinuousClock()
        let start = clock.now
        for step in script {
            try await clock.sleep(until: start + .milliseconds(Int(step.time * 1000 / speed)))
            var event = step.event
            event.ts = Date.now.timeIntervalSince1970
            guard MoonletClient.send(event, paths: paths, timeout: 1, spoolIfUnavailable: false) == .delivered else {
                Console.error("Moonlet stopped answering; ending the demo.")
                return 1
            }
            print(String(format: "%5.1fs  %@", step.time, step.description))
        }
        return 0
    }

    private struct Step {
        let time: Double
        let event: MoonletEvent

        var description: String {
            let state = event.kind == .end ? "ended" : event.state?.rawValue ?? "update"
            let detail =
                event.message ?? event.milestone ?? event.activity ?? event.summary.map { TextTools.firstSentence($0) } ?? ""
            return event.session.padding(toLength: 14, withPad: " ", startingAt: 0)
                + state.padding(toLength: 9, withPad: " ", startingAt: 0) + detail
        }
    }

    private static func update(
        _ time: Double, _ session: String, _ state: AgentState? = nil, configure: (inout MoonletEvent) -> Void = { _ in }
    ) -> Step {
        var event = MoonletEvent(source: "demo", session: session, label: session, state: state)
        configure(&event)
        return Step(time: time, event: event)
    }

    private static func end(_ time: Double, _ session: String) -> Step {
        Step(time: time, event: MoonletEvent(kind: .end, source: "demo", session: session))
    }

    /// The API refactor's plan, with the first `completed` tasks done and the next one underway.
    private static func refactorTasks(completed: Int) -> [TaskItem] {
        let titles = [
            "Map the current endpoints", "Extract a PaymentService", "Move validation into the service",
            "Update the API tests", "Write the migration notes",
        ]
        return titles.enumerated().map { index, title in
            let status: TaskItem.Status = index < completed ? .completed : index == completed ? .inProgress : .pending
            return TaskItem(id: "task-\(index + 1)", title: title, status: status)
        }
    }

    private static let script: [Step] = [
        update(0, "api-refactor", .working) {
            $0.title = "Refactor the payments API"
            $0.activity = "Reading PaymentsController.swift"
            $0.tasks = refactorTasks(completed: 0)
        },
        update(1, "landing-page", .working) {
            $0.title = "Build the new landing page"
            $0.activity = "Editing Hero.tsx"
            $0.progress = AgentProgress(done: 1, total: 6)
        },
        update(2, "db-migration", .working) {
            $0.title = "Move user IDs to UUIDs"
            $0.activity = "Running rails db:migrate"
        },
        update(4, "api-refactor") {
            $0.activity = "Editing PaymentService.swift"
            $0.tasks = refactorTasks(completed: 1)
        },
        update(5.5, "landing-page") {
            $0.activity = "Writing Pricing.tsx"
            $0.progress = AgentProgress(done: 2, total: 6)
        },
        update(7, "landing-page", .waiting) { $0.message = "Needs permission for Bash" },
        update(8.5, "db-migration") {
            $0.activity = "Backfilling 48,213 rows"
            $0.progress = AgentProgress(done: 1, total: 3)
        },
        update(10, "landing-page", .working) {
            $0.activity = "Running npm run build"
            $0.progress = AgentProgress(done: 3, total: 6)
        },
        update(11, "api-refactor") {
            $0.activity = "Moving validation into PaymentService"
            $0.milestone = "Committed changes"
            $0.tasks = refactorTasks(completed: 2)
        },
        update(12.5, "db-migration", .failed) { $0.message = "Migration failed: duplicate key in users.email" },
        update(14, "landing-page") {
            $0.activity = "Editing Faq.tsx"
            $0.progress = AgentProgress(done: 4, total: 6)
        },
        update(15.5, "api-refactor", .waiting) { $0.message = "Has a question for you" },
        update(18, "api-refactor", .working) {
            $0.activity = "Updating the API tests"
            $0.tasks = refactorTasks(completed: 3)
        },
        update(19.5, "landing-page", .done) {
            $0.progress = AgentProgress(done: 6, total: 6)
            $0.summary = """
                Built the landing page with a hero, a pricing table, and an FAQ. \
                Lighthouse scores 98 on mobile.
                """
        },
        update(21.5, "api-refactor") {
            $0.activity = "Writing MIGRATION.md"
            $0.tasks = refactorTasks(completed: 4)
        },
        update(23, "api-refactor", .done) {
            $0.tasks = refactorTasks(completed: 5)
            $0.summary = """
                Split the payments API into a **PaymentService** and thin controllers. All 214 tests pass, \
                and `MIGRATION.md` covers the endpoint changes.
                """
        },
        end(25, "api-refactor"),
        end(25, "landing-page"),
        end(25, "db-migration"),
    ]
}
