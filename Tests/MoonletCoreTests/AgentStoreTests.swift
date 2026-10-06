import Foundation
import Testing

@testable import MoonletCore

@Suite("AgentStore")
struct AgentStoreTests {
    private let start = Date(timeIntervalSince1970: 1_790_000_000)

    private func at(_ seconds: TimeInterval) -> Date {
        start.addingTimeInterval(seconds)
    }

    private func update(
        _ session: String = "s1", _ configure: (inout MoonletEvent) -> Void = { _ in }
    ) -> MoonletEvent {
        var event = MoonletEvent(source: "cli", session: session, ts: 0)
        configure(&event)
        return event
    }

    /// `prune` returns whether it removed anything; `#expect` can't call mutating methods.
    private func prune(_ store: inout AgentStore, at date: Date) -> Bool {
        store.prune(now: date)
    }

    private func end(_ session: String = "s1") -> MoonletEvent {
        MoonletEvent(kind: .end, source: "cli", session: session, ts: 0)
    }

    // MARK: Creation and labels

    @Test func firstUpdateCreatesTheAgent() throws {
        var store = AgentStore()
        let signals = store.apply(update { $0.state = .working; $0.cwd = "/Users/example/code/api" }, now: start)
        #expect(signals == [.appeared(agentID: "cli:s1")])
        let agent = try #require(store.agent(id: "cli:s1"))
        #expect(agent.label == "api")
        #expect(agent.state == .working)
        #expect(agent.firstSeen == start)
        #expect(agent.stateChangedAt == start)
    }

    @Test func agentStartsIdleWithoutAState() {
        var store = AgentStore()
        store.apply(update { $0.activity = "Thinking" }, now: start)
        #expect(store.agents.first?.state == .idle)
    }

    @Test func labelPrefersEventLabelThenCwdThenSession() {
        var store = AgentStore()
        store.apply(update("a") { $0.label = "Deploy"; $0.cwd = "/x/web" }, now: start)
        store.apply(update("b") { $0.cwd = "/x/web/" }, now: start)
        store.apply(update("c9f3a7b2-11"), now: start)
        #expect(store.agents.map(\.label) == ["Deploy", "web", "session-c9f3a7"])
    }

    @Test func labelsAreUniqueAmongLiveAgents() {
        var store = AgentStore()
        for session in ["a", "b", "c"] {
            store.apply(update(session) { $0.cwd = "/x/api" }, now: start)
        }
        #expect(store.agents.map(\.label) == ["api", "api 2", "api 3"])

        store.apply(end("a"), now: at(1))
        store.apply(update("d") { $0.cwd = "/x/api" }, now: at(2))
        #expect(store.agent(id: "cli:d")?.label == "api")
    }

    @Test func laterLabelRenamesTheAgent() {
        var store = AgentStore()
        store.apply(update { $0.cwd = "/x/api" }, now: start)
        store.apply(update { $0.label = "Payments" }, now: at(1))
        #expect(store.agents.first?.label == "Payments")
    }

    @Test func agentsAreOrderedByFirstSeen() {
        var store = AgentStore()
        store.apply(update("b"), now: start)
        store.apply(update("a"), now: at(1))
        store.apply(update("b") { $0.state = .working }, now: at(2))
        #expect(store.agents.map(\.session) == ["b", "a"])
    }

    // MARK: Needs you

    @Test func waitingSignalsNeedsYouOnlyWhenStateOrMessageChanges() {
        var store = AgentStore()
        store.apply(update { $0.state = .working }, now: start)
        #expect(
            store.apply(update { $0.state = .waiting; $0.message = "Needs permission for Bash" }, now: at(1))
                == [.needsYou(agentID: "cli:s1", message: "Needs permission for Bash")])
        #expect(store.apply(update { $0.state = .waiting; $0.message = "Needs permission for Bash" }, now: at(2)) == [])
        #expect(store.apply(update { $0.state = .waiting }, now: at(3)) == [])
        #expect(
            store.apply(update { $0.state = .waiting; $0.message = "Has a question for you" }, now: at(4))
                == [.needsYou(agentID: "cli:s1", message: "Has a question for you")])
    }

    @Test func leavingWaitingResolvesAndClearsTheMessage() {
        var store = AgentStore()
        store.apply(update { $0.state = .waiting; $0.message = "Plan ready for review" }, now: start)
        #expect(store.apply(update { $0.state = .working }, now: at(1)) == [.resolved(agentID: "cli:s1")])
        #expect(store.agents.first?.message == nil)
    }

    // MARK: Finishing

    @Test func enteringDoneSignalsFinishedOnce() {
        var store = AgentStore()
        store.apply(update { $0.state = .working }, now: start)
        #expect(
            store.apply(update { $0.state = .done; $0.summary = "All set." }, now: at(1))
                == [.finished(agentID: "cli:s1", summary: "All set.")])
        #expect(store.apply(update { $0.state = .done; $0.summary = "All set again." }, now: at(2)) == [])
    }

    @Test func enteringFailedSignalsFailedWithTheMessage() {
        var store = AgentStore()
        store.apply(update { $0.state = .working }, now: start)
        #expect(
            store.apply(update { $0.state = .failed; $0.message = "Rate limited" }, now: at(1))
                == [.failed(agentID: "cli:s1", message: "Rate limited")])
        #expect(store.apply(update { $0.state = .failed }, now: at(2)) == [])
    }

    @Test func newAgentsSignalTheirInitialState() {
        var store = AgentStore()
        #expect(
            store.apply(update { $0.state = .done; $0.summary = "Built it." }, now: start)
                == [.appeared(agentID: "cli:s1"), .finished(agentID: "cli:s1", summary: "Built it.")])
    }

    @Test func signalsComeInDocumentedOrder() {
        var store = AgentStore()
        store.apply(update { $0.state = .waiting; $0.message = "Needs permission for Bash" }, now: start)
        let signals = store.apply(
            update {
                $0.state = .done
                $0.milestone = "Pushed changes"
                $0.progress = AgentProgress(done: 3, total: 3)
            }, now: at(1))
        #expect(
            signals == [
                .resolved(agentID: "cli:s1"), .milestone(agentID: "cli:s1", text: "Pushed changes"),
                .progressChanged(agentID: "cli:s1"), .finished(agentID: "cli:s1", summary: nil),
            ])
    }

    @Test func newTurnClearsTheLastTurnsResults() throws {
        var store = AgentStore()
        store.apply(update { $0.state = .working; $0.milestone = "Committed changes" }, now: start)
        store.apply(update { $0.state = .done; $0.summary = "Shipped." }, now: at(1))
        store.apply(update { $0.state = .working; $0.title = "Next task" }, now: at(2))
        let agent = try #require(store.agents.first)
        #expect(agent.summary == nil)
        #expect(agent.lastMilestone == nil)
        #expect(agent.title == "Next task")
        #expect(
            store.apply(update { $0.milestone = "Committed changes" }, now: at(3))
                == [.milestone(agentID: "cli:s1", text: "Committed changes")])
    }

    @Test func leavingWorkingClearsTheActivity() {
        var store = AgentStore()
        store.apply(update { $0.state = .working; $0.activity = "Running npm test" }, now: start)
        store.apply(update { $0.state = .done }, now: at(1))
        #expect(store.agents.first?.activity == nil)
    }

    // MARK: Milestones

    @Test func changedMilestoneTextSignalsOnce() {
        var store = AgentStore()
        store.apply(update { $0.state = .working }, now: start)
        #expect(
            store.apply(update { $0.milestone = "Committed changes" }, now: at(1))
                == [.milestone(agentID: "cli:s1", text: "Committed changes")])
        #expect(store.apply(update { $0.milestone = "Committed changes" }, now: at(2)) == [])
        #expect(
            store.apply(update { $0.milestone = "Pushed changes" }, now: at(3))
                == [.milestone(agentID: "cli:s1", text: "Pushed changes")])
        #expect(store.agents.first?.lastMilestone == "Pushed changes")
    }

    @Test func completingATaskIsAMilestone() {
        var store = AgentStore()
        let plan = [TaskItem(id: "1", title: "Write the parser"), TaskItem(id: "2", title: "Add tests")]
        store.apply(update { $0.state = .working; $0.tasks = plan }, now: start)
        let signals = store.apply(update { $0.task = TaskItem(id: "1", title: "", status: .completed) }, now: at(1))
        #expect(
            signals == [
                .milestone(agentID: "cli:s1", text: "Write the parser"), .progressChanged(agentID: "cli:s1"),
            ])
    }

    @Test func explicitMilestoneWinsOverCompletedTasks() {
        var store = AgentStore()
        store.apply(update { $0.tasks = [TaskItem(id: "1", title: "Write the parser")] }, now: start)
        let signals = store.apply(
            update {
                $0.tasks = [TaskItem(id: "1", title: "Write the parser", status: .completed)]
                $0.milestone = "Committed changes"
            }, now: at(1))
        #expect(signals.contains(.milestone(agentID: "cli:s1", text: "Committed changes")))
        #expect(!signals.contains(.milestone(agentID: "cli:s1", text: "Write the parser")))
    }

    @Test func tasksAlreadyCompletedOnFirstSightAreNotMilestones() {
        var store = AgentStore()
        let signals = store.apply(update { $0.tasks = [TaskItem(id: "1", title: "Old work", status: .completed)] }, now: start)
        #expect(signals == [.appeared(agentID: "cli:s1"), .progressChanged(agentID: "cli:s1")])
    }

    @Test func replacedTaskListWithNewIdsStillCountsCompletions() {
        var store = AgentStore()
        store.apply(update { $0.tasks = [TaskItem(id: "a0", title: "Lint"), TaskItem(id: "b0", title: "Test")] }, now: start)
        let signals = store.apply(
            update {
                $0.tasks = [TaskItem(id: "a1", title: "Lint", status: .completed), TaskItem(id: "b1", title: "Test")]
            }, now: at(1))
        #expect(signals.first == .milestone(agentID: "cli:s1", text: "Lint"))
    }

    // MARK: Tasks and progress

    @Test func progressPrefersExplicitThenTasks() throws {
        var store = AgentStore()
        store.apply(update { $0.tasks = [TaskItem(id: "1", title: "A", status: .completed), TaskItem(id: "2", title: "B")] }, now: start)
        #expect(store.agents.first?.progress == AgentProgress(done: 1, total: 2))

        store.apply(update { $0.progress = AgentProgress(done: 3, total: 7) }, now: at(1))
        #expect(store.agents.first?.progress == AgentProgress(done: 3, total: 7))

        store.apply(update { $0.progress = AgentProgress(done: 0, total: 0) }, now: at(2))
        #expect(store.agents.first?.progress == AgentProgress(done: 1, total: 2))

        store.apply(update("bare"), now: at(3))
        #expect(try #require(store.agent(id: "cli:bare")).progress == nil)
    }

    @Test func explicitProgressIsClamped() {
        var store = AgentStore()
        store.apply(update { $0.progress = AgentProgress(done: 9, total: 4) }, now: start)
        #expect(store.agents.first?.progress == AgentProgress(done: 4, total: 4))
    }

    @Test func progressChangedOnlyWhenEffectiveProgressMoves() {
        var store = AgentStore()
        store.apply(update { $0.progress = AgentProgress(done: 1, total: 3) }, now: start)
        #expect(store.apply(update { $0.progress = AgentProgress(done: 1, total: 3) }, now: at(1)) == [])
        #expect(
            store.apply(update { $0.progress = AgentProgress(done: 2, total: 3) }, now: at(2))
                == [.progressChanged(agentID: "cli:s1")])
    }

    @Test func taskUpsertsInsertUpdateAndDelete() {
        var store = AgentStore()
        store.apply(update { $0.task = TaskItem(id: "7", title: "Draft") }, now: start)
        store.apply(update { $0.task = TaskItem(id: "8", title: "Review") }, now: at(1))
        store.apply(update { $0.task = TaskItem(id: "7", title: "", status: .inProgress) }, now: at(2))
        #expect(
            store.agents.first?.tasks == [
                TaskItem(id: "7", title: "Draft", status: .inProgress), TaskItem(id: "8", title: "Review"),
            ])

        store.apply(update { $0.task = TaskItem(id: "8", title: "", status: .deleted) }, now: at(3))
        store.apply(update { $0.task = TaskItem(id: "99", title: "", status: .deleted) }, now: at(4))
        #expect(store.agents.first?.tasks.map(\.id) == ["7"])
    }

    @Test func taskListReplacementDropsDuplicatesAndDeletions() {
        var store = AgentStore()
        store.apply(
            update {
                $0.tasks = [
                    TaskItem(id: "1", title: "A"), TaskItem(id: "2", title: "B", status: .deleted),
                    TaskItem(id: "1", title: "A again", status: .completed),
                ]
            }, now: start)
        #expect(store.agents.first?.tasks == [TaskItem(id: "1", title: "A again", status: .completed)])
    }

    // MARK: Fields

    @Test func emptyStringsClearFields() {
        var store = AgentStore()
        store.apply(update { $0.title = "Fix it"; $0.activity = "Reading a.swift" }, now: start)
        store.apply(update { $0.title = ""; $0.activity = " " }, now: at(1))
        #expect(store.agents.first?.title == nil)
        #expect(store.agents.first?.activity == nil)
    }

    @Test func oneLineFieldsAreCollapsedAndBounded() throws {
        var store = AgentStore()
        let long = String(repeating: "word ", count: 40)
        store.apply(update { $0.activity = "Running\n  tests"; $0.title = long; $0.label = long }, now: start)
        let agent = try #require(store.agents.first)
        #expect(agent.activity == "Running tests")
        #expect(agent.title.map { $0.count <= 80 && $0.hasSuffix("…") } == true)
        #expect(agent.label.count <= 40)
    }

    @Test func summaryIsKeptVerbatim() {
        var store = AgentStore()
        let summary = "## Done\n\n- Fixed the bug\n- Added a test\n"
        store.apply(update { $0.state = .done; $0.summary = summary }, now: start)
        #expect(store.agents.first?.summary == summary)
    }

    @Test func cwdAndHostKeepTheirLastKnownValues() {
        var store = AgentStore()
        store.apply(update { $0.cwd = "/x/api"; $0.host = HostInfo(tty: "/dev/ttys001", pid: 10) }, now: start)
        store.apply(update { $0.cwd = ""; $0.host = HostInfo() }, now: at(1))
        #expect(store.agents.first?.cwd == "/x/api")
        #expect(store.agents.first?.host == HostInfo(tty: "/dev/ttys001", pid: 10))
    }

    @Test func stateChangeTimestampOnlyMovesOnChanges() {
        var store = AgentStore()
        store.apply(update { $0.state = .working }, now: start)
        store.apply(update { $0.state = .working; $0.activity = "Still going" }, now: at(5))
        #expect(store.agents.first?.stateChangedAt == start)
        #expect(store.agents.first?.lastUpdate == at(5))
    }

    // MARK: Ending

    @Test func endMarksEndedAndResolvesWaiting() {
        var store = AgentStore()
        store.apply(update { $0.state = .waiting; $0.message = "Needs permission for Bash" }, now: start)
        #expect(store.apply(end(), now: at(1)) == [.resolved(agentID: "cli:s1"), .ended(agentID: "cli:s1")])
        #expect(store.agents.first?.ended == true)
        #expect(store.apply(end(), now: at(2)) == [])
    }

    @Test func endForAnUnknownAgentIsIgnored() {
        var store = AgentStore()
        #expect(store.apply(end(), now: start) == [])
        #expect(store.agents.isEmpty)
    }

    @Test func updateAfterEndRevivesTheAgent() throws {
        var store = AgentStore()
        store.apply(update { $0.state = .done; $0.cwd = "/x/api" }, now: start)
        store.apply(end(), now: at(1))
        store.apply(update("other") { $0.cwd = "/x/api" }, now: at(2))
        let signals = store.apply(update { $0.state = .working }, now: at(3))
        #expect(signals == [.appeared(agentID: "cli:s1")])
        let agent = try #require(store.agent(id: "cli:s1"))
        #expect(!agent.ended)
        #expect(agent.label == "api 2")
    }

    // MARK: Pruning and counts

    @Test func pruneRemovesEndedUnfinishedAgentsAfterTheGrace() {
        var store = AgentStore(config: StoreConfig(endedGrace: 10))
        store.apply(update { $0.state = .working }, now: start)
        store.apply(end(), now: at(1))
        #expect(prune(&store, at: at(10)) == false)
        #expect(prune(&store, at: at(11)) == true)
        #expect(store.agents.isEmpty)
    }

    @Test func pruneKeepsFinishedAgentsUntilKeepFinished() {
        var store = AgentStore(config: StoreConfig(keepFinished: 100))
        store.apply(update("done") { $0.state = .done }, now: start)
        store.apply(update("failed") { $0.state = .failed }, now: start)
        store.apply(end("done"), now: at(1))
        #expect(prune(&store, at: at(99)) == false)
        #expect(prune(&store, at: at(100)) == true)
        #expect(store.agents.isEmpty)
    }

    @Test func prunePrunesSilentIdleAndWorkingAgentsButNotWaitingOnes() {
        var store = AgentStore(config: StoreConfig(staleAfter: 60))
        store.apply(update("idle") { $0.state = .idle }, now: start)
        store.apply(update("working") { $0.state = .working }, now: start)
        store.apply(update("waiting") { $0.state = .waiting }, now: start)
        store.apply(update("fresh") { $0.state = .working }, now: at(30))
        #expect(prune(&store, at: at(60)) == true)
        #expect(store.agents.map(\.session) == ["waiting", "fresh"])
        #expect(prune(&store, at: at(70)) == false)
    }

    @Test func defaultConfigMatchesTheDocumentedPolicy() {
        let config = StoreConfig()
        #expect(config.endedGrace == 10)
        #expect(config.keepFinished == 7200)
        #expect(config.staleAfter == 7200)
    }

    @Test func countsSkipAgentsThatEndedUnfinished() {
        var store = AgentStore()
        store.apply(update("a") { $0.state = .working }, now: start)
        store.apply(update("b") { $0.state = .waiting }, now: start)
        store.apply(update("c") { $0.state = .done }, now: start)
        store.apply(update("d") { $0.state = .working }, now: start)
        store.apply(end("c"), now: at(1))
        store.apply(end("d"), now: at(1))
        let counts = store.counts
        #expect(counts.working == 1)
        #expect(counts.waiting == 1)
        #expect(counts.done == 1)
        #expect(counts.total == 3)
        #expect(counts[.idle] == 0)
    }
}
