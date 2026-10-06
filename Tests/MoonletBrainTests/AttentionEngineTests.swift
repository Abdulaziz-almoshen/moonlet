import Foundation
import Testing
@testable import MoonletBrain

private let t0 = Date(timeIntervalSince1970: 1_800_000_000)

private func at(_ seconds: TimeInterval) -> Date { t0.addingTimeInterval(seconds) }

/// Presence where the last input happened `idle` seconds ago and the last key press `key` seconds ago.
private func presence(idle: TimeInterval = 0.5, key: TimeInterval = 60, call: Bool = false, front: String? = nil) -> PresenceSnapshot {
    PresenceSnapshot(secondsSinceInput: idle, secondsSinceKey: key, inCall: call, frontmostBundleID: front)
}

private func moment(_ label: String, _ kind: MomentKind, _ detail: String = "x", at time: TimeInterval = 0,
                    host: String? = nil) -> Moment {
    Moment(agentID: "claude-code:\(label)", agentLabel: label, project: label, kind: kind, detail: detail,
           createdAt: at(time), hostBundleID: host)
}

@Suite("Attention engine")
struct AttentionEngineTests {
    @Test("An active user sees a card that leaves on its own after the hold time")
    func activeUserHold() {
        var engine = AttentionEngine()
        let effects = engine.receive(moment("api", .finished, "Pagination shipped"), presence: presence(), now: at(0))
        guard case .show(let card)? = effects.first else { Issue.record("expected a card"); return }
        #expect(card.title == "api done")
        #expect(card.detail == "Pagination shipped")
        // The user keeps working while the card shows.
        #expect(engine.tick(presence: presence(idle: 0.2), now: at(2)).isEmpty)
        let gone = engine.tick(presence: presence(idle: 0.2), now: at(4.1))
        #expect(gone.first.isHide(.seen))
        #expect(engine.current == nil)
        #expect(engine.history.first?.agentLabel == "api")
    }

    @Test("A card shown to an idle user waits, then leaves shortly after they return")
    func waitsForReturn() {
        var engine = AttentionEngine()
        _ = engine.receive(moment("api", .finished), presence: presence(idle: 30), now: at(0))
        #expect(engine.current != nil)
        // Ninety seconds of nobody touching anything: still there.
        #expect(engine.tick(presence: presence(idle: 120 - 1), now: at(89)).isEmpty)
        #expect(engine.current != nil)
        // The user comes back.
        #expect(engine.tick(presence: presence(idle: 0.1), now: at(90)).isEmpty)
        #expect(engine.tick(presence: presence(idle: 0.1), now: at(92)).isEmpty)
        #expect(engine.tick(presence: presence(idle: 0.1), now: at(93.1)).first.isHide(.seen))
    }

    @Test("If nobody touches anything during the hold, the card keeps waiting instead of vanishing")
    func noInputDuringHold() {
        var engine = AttentionEngine()
        _ = engine.receive(moment("api", .finished), presence: presence(idle: 1), now: at(0))
        // The user stopped right as it appeared: input stays older than the card.
        #expect(engine.tick(presence: presence(idle: 5), now: at(4)).isEmpty)
        #expect(engine.current != nil)
        #expect(engine.current?.deadline == nil)
    }

    @Test("Leaving for two minutes moves the card into a welcome-back summary")
    func awayBecomesSummary() {
        var engine = AttentionEngine()
        _ = engine.receive(moment("api", .finished), presence: presence(idle: 30), now: at(0))
        let left = engine.tick(presence: presence(idle: 121), now: at(91))
        #expect(left.first.isHide(.wentAway))
        // More news while away.
        #expect(engine.receive(moment("web", .needsYou, "Run npm install?", at: 100), presence: presence(idle: 130), now: at(100)).isEmpty)
        #expect(engine.unseenCount == 2)
        // Back at the desk: one summary, blocked agents counted first.
        let back = engine.tick(presence: presence(idle: 0.1), now: at(200))
        guard case .show(let card)? = back.first else { Issue.record("expected the summary"); return }
        #expect(card.isDigest)
        #expect(card.title == "While you were away")
        #expect(card.detail == "1 needs you · 1 done")
        #expect(card.tone == .needsYou)
    }

    @Test("Cards wait for a typing pause, within each kind's patience")
    func typingPause() {
        var engine = AttentionEngine()
        #expect(engine.receive(moment("api", .finished), presence: presence(idle: 0.1, key: 0.2), now: at(0)).isEmpty)
        #expect(engine.tick(presence: presence(idle: 0.1, key: 0.2), now: at(5)).isEmpty)
        // A pause in typing lets it through.
        guard case .show? = engine.tick(presence: presence(idle: 1.6, key: 1.6), now: at(6)).first else {
            Issue.record("expected the card at the pause"); return
        }
    }

    @Test("Blocked agents interrupt typing after a short patience")
    func blockedPatience() {
        var engine = AttentionEngine()
        #expect(engine.receive(moment("web", .needsYou), presence: presence(idle: 0.1, key: 0.1), now: at(0)).isEmpty)
        #expect(engine.tick(presence: presence(idle: 0.1, key: 0.1), now: at(2.9)).isEmpty)
        guard case .show(let card)? = engine.tick(presence: presence(idle: 0.1, key: 0.1), now: at(3)).first else {
            Issue.record("expected the blocked card"); return
        }
        #expect(card.title == "web needs you")
    }

    @Test("A click hides the card at once and counts as seen")
    func clickDismisses() {
        var engine = AttentionEngine()
        _ = engine.receive(moment("api", .failed, "Tests failed"), presence: presence(), now: at(0))
        #expect(engine.click(now: at(1)).first.isHide(.clicked))
        #expect(engine.history.first?.kind == .failed)
        #expect(engine.unseenCount == 0)
    }

    @Test("Same-kind news arriving together shares one card")
    func batching() {
        var engine = AttentionEngine()
        _ = engine.receive(moment("web", .needsYou), presence: presence(), now: at(0))
        _ = engine.receive(moment("api", .finished, at: 0.2), presence: presence(), now: at(0.2))
        _ = engine.receive(moment("db", .finished, at: 0.6), presence: presence(), now: at(0.6))
        // The blocked agent shows first; the two finished ones wait together.
        #expect(engine.current?.title == "web needs you")
        _ = engine.click(now: at(1))
        guard case .show(let card)? = engine.tick(presence: presence(), now: at(1.1)).first else {
            Issue.record("expected the grouped card"); return
        }
        #expect(card.title == "2 agents done")
        #expect(card.detail == "api, db")
    }

    @Test("A repeat of the same unresolved request doesn't show a second card")
    func repeatedRequest() {
        var engine = AttentionEngine()
        _ = engine.receive(moment("web", .needsYou, "Wants to run npm install"), presence: presence(), now: at(0))
        _ = engine.click(now: at(1))
        #expect(engine.receive(moment("web", .needsYou, "Needs permission for Bash", at: 6), presence: presence(), now: at(6)).isEmpty)
        #expect(engine.queue.isEmpty)
        // Once resolved, the next request is new news.
        _ = engine.resolve(agentID: "claude-code:web", now: at(10))
        guard case .show? = engine.receive(moment("web", .needsYou, "Wants to edit Orders.swift", at: 12), presence: presence(), now: at(12)).first else {
            Issue.record("expected a card for the new request"); return
        }
    }

    @Test("Cards for blocked agents stay longer than other cards")
    func blockingHold() {
        var engine = AttentionEngine()
        _ = engine.receive(moment("web", .needsYou), presence: presence(), now: at(0))
        #expect(engine.tick(presence: presence(idle: 0.2), now: at(5)).isEmpty)
        #expect(engine.tick(presence: presence(idle: 0.2), now: at(8.1)).first.isHide(.seen))
    }

    @Test("A failure that arrives while another card waits still shows after it")
    func queuedFailureShows() {
        var engine = AttentionEngine()
        // The user is reading, not touching anything: the done card waits for them.
        _ = engine.receive(moment("landing", .finished, "Live on preview"), presence: presence(idle: 10, key: 60), now: at(0))
        #expect(engine.current?.title == "landing done")
        var shown: [String] = []
        for case .show(let card) in engine.receive(moment("db", .failed, "Staging DB refused", at: 8), presence: presence(idle: 18, key: 60), now: at(8)) {
            shown.append(card.title)
        }
        // The user comes back and starts typing.
        for step in 0..<200 {
            let t = 20 + Double(step) * 0.2
            for case .show(let card) in engine.tick(presence: presence(idle: 0.1, key: 0.1), now: at(t)) { shown.append(card.title) }
        }
        #expect(shown == ["db failed"])
    }

    @Test("A failure takes the pointer from a done card that waits for the user")
    func failurePreemptsNews() {
        var engine = AttentionEngine()
        _ = engine.receive(moment("landing", .finished, "Live on preview"), presence: presence(idle: 10), now: at(0))
        let effects = engine.receive(moment("db", .failed, "Staging DB refused", at: 10), presence: presence(idle: 20), now: at(10))
        #expect(effects.first.isHide(.preempted))
        guard case .show(let card)? = effects.last else { Issue.record("expected the failure card"); return }
        #expect(card.title == "db failed")
        // The done card had its time, so it doesn't come back.
        #expect(engine.queue.isEmpty)
    }

    @Test("A preempted card that barely showed comes back afterwards")
    func preemptedCardReturns() {
        var engine = AttentionEngine()
        _ = engine.receive(moment("landing", .finished), presence: presence(), now: at(0))
        _ = engine.receive(moment("web", .needsYou, "Wants to run npm install", at: 1), presence: presence(), now: at(1))
        #expect(engine.current?.title == "web needs you")
        #expect(engine.queue.first?.moment.agentLabel == "landing")
    }

    @Test("Resolving a blocked agent removes its card")
    func resolveHides() {
        var engine = AttentionEngine()
        _ = engine.receive(moment("web", .needsYou), presence: presence(), now: at(0))
        #expect(engine.resolve(agentID: "claude-code:web", now: at(1)).first.isHide(.resolved))
        #expect(engine.blockedAgents.isEmpty)
    }

    @Test("Blocked agents are mentioned again at 2, 10, and 30 minutes, then never")
    func reminders() {
        var engine = AttentionEngine()
        _ = engine.receive(moment("web", .needsYou, "Run npm install?"), presence: presence(), now: at(0))
        _ = engine.click(now: at(1))
        var shown: [String] = []
        for second in stride(from: 2.0, through: 3600, by: 1) {
            for case .show(let card) in engine.tick(presence: presence(), now: at(second)) {
                shown.append(card.detail)
                _ = engine.click(now: at(second))
            }
        }
        #expect(shown == ["Waiting 2 min · Run npm install?", "Waiting 10 min · Run npm install?",
                          "Waiting 30 min · Run npm install?"])
    }

    @Test("A finished agent whose app is in front flashes the pointer instead of showing a card")
    func alreadyWatching() {
        var engine = AttentionEngine()
        let effects = engine.receive(moment("api", .finished, host: "com.googlecode.iterm2"),
                                     presence: presence(front: "com.googlecode.iterm2"), now: at(0))
        #expect(effects == [.flash(.finished)])
        #expect(engine.current == nil)
    }

    @Test("Calls hold every card until they end, then summarize")
    func callMode() {
        var engine = AttentionEngine()
        #expect(engine.receive(moment("api", .finished), presence: presence(call: true), now: at(0)).isEmpty)
        #expect(engine.receive(moment("web", .needsYou, at: 5), presence: presence(call: true), now: at(5)).isEmpty)
        #expect(engine.tick(presence: presence(call: true), now: at(60)).isEmpty)
        guard case .show(let card)? = engine.tick(presence: presence(), now: at(61)).first else {
            Issue.record("expected the summary after the call"); return
        }
        #expect(card.isDigest)
    }

    @Test("Batched projects collect quietly for the summon view")
    func batchedProjects() {
        var config = AttentionConfig()
        config.batchedProjects = ["api"]
        var engine = AttentionEngine(config: config)
        #expect(engine.receive(moment("api", .finished), presence: presence(), now: at(0)).isEmpty)
        #expect(engine.unseenCount == 1)
        _ = engine.summoned(now: at(1))
        #expect(engine.unseenCount == 0)
        #expect(engine.history.count == 1)
    }

    @Test("Only the latest news from an agent is kept")
    func latestWins() {
        var engine = AttentionEngine()
        _ = engine.receive(moment("api", .finished), presence: presence(idle: 200), now: at(0))
        _ = engine.receive(moment("api", .failed, at: 1), presence: presence(idle: 201), now: at(1))
        #expect(engine.queue.count == 1)
        #expect(engine.queue.first?.moment.kind == .failed)
    }
}

private extension Optional where Wrapped == AttentionEffect {
    func isHide(_ reason: HideReason) -> Bool {
        if case .hide(_, let actual)? = self { return actual == reason }
        return false
    }
}
