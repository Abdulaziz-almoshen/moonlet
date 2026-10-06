import CoreGraphics
import Foundation
import Testing
@testable import MoonletBrain

@Suite("Gestures")
struct GestureTests {
    /// Samples a circle of `radius` around `center`, `turns` times, at 120 Hz over `duration` seconds.
    func circle(radius: Double, turns: Double = 1, duration: Double = 0.8, center: CGPoint = .init(x: 500, y: 400))
        -> [(CGPoint, TimeInterval)] {
        let count = Int(duration * 120)
        return (0...count).map { i in
            let t = Double(i) / Double(count)
            let angle = t * turns * 2 * .pi
            return (CGPoint(x: center.x + radius * cos(angle), y: center.y + radius * sin(angle)), 10 + t * duration)
        }
    }

    @Test("A small circle summons, centered where it was drawn")
    func recognizesCircle() {
        var recognizer = GestureRecognizer()
        let result = circle(radius: 40).compactMap { recognizer.add($0.0, at: $0.1) }.first
        guard case .circle(let center)? = result else { Issue.record("expected a circle"); return }
        #expect(abs(center.x - 500) < 12 && abs(center.y - 400) < 12)
    }

    @Test("Drawing with a button held never summons")
    func ignoresDrags() {
        var recognizer = GestureRecognizer()
        #expect(circle(radius: 40).compactMap { recognizer.add($0.0, at: $0.1, buttonsDown: true) }.isEmpty)
    }

    @Test("Straight movement and huge sweeps are not circles")
    func rejectsNonCircles() {
        var recognizer = GestureRecognizer()
        let line = (0...120).map { i in (CGPoint(x: 100 + Double(i) * 6, y: 300), 20 + Double(i) / 120) }
        #expect(line.compactMap { recognizer.add($0.0, at: $0.1) }.isEmpty)
        #expect(circle(radius: 400).compactMap { recognizer.add($0.0, at: $0.1) }.isEmpty)
    }

    @Test("A quick side-to-side shake does not summon")
    func ignoresShake() {
        var recognizer = GestureRecognizer()
        var samples: [(CGPoint, TimeInterval)] = []
        for i in 0..<48 {
            let phase = Double(i) / 8 * .pi
            samples.append((CGPoint(x: 600 + 60 * sin(phase), y: 300), 30 + Double(i) / 120))
        }
        #expect(samples.compactMap { recognizer.add($0.0, at: $0.1) }.isEmpty)
    }
}

@Suite("Pointer tint")
struct PointerPolicyTests {
    let now = Date(timeIntervalSince1970: 1_800_000_000)

    @Test("Silent work never changes the pointer")
    func silentWork() {
        var policy = PointerPolicy()
        #expect(policy.tint(card: nil, waitingOnUser: false, now: now) == .system)
    }

    @Test("A card colors the pointer while it shows: blue for news, yellow for requests, red for problems")
    func cardTones() {
        var policy = PointerPolicy()
        #expect(policy.tint(card: .finished, waitingOnUser: false, now: now) == .info)
        #expect(policy.tint(card: .needsYou, waitingOnUser: true, now: now) == .needsYou)
        #expect(policy.tint(card: .question, waitingOnUser: true, now: now) == .needsYou)
        #expect(policy.tint(card: .failed, waitingOnUser: false, now: now) == .problem)
        #expect(policy.tint(card: .stuck, waitingOnUser: false, now: now) == .problem)
    }

    @Test("An unanswered question keeps the pointer yellow after its card leaves, until answered")
    func waitingStaysYellow() {
        var policy = PointerPolicy()
        #expect(policy.tint(card: nil, waitingOnUser: true, now: now) == .needsYou)
        // News from another agent takes over while its card shows, then yellow returns.
        #expect(policy.tint(card: .finished, waitingOnUser: true, now: now) == .info)
        #expect(policy.tint(card: nil, waitingOnUser: true, now: now) == .needsYou)
        #expect(policy.tint(card: nil, waitingOnUser: false, now: now) == .system)
    }

    @Test("A flash shows briefly, then the pointer returns to its rule")
    func flash() {
        var policy = PointerPolicy()
        policy.flash(.info, now: now)
        #expect(policy.tint(card: nil, waitingOnUser: false, now: now.addingTimeInterval(1)) == .info)
        #expect(policy.tint(card: nil, waitingOnUser: false, now: now.addingTimeInterval(2)) == .system)
    }
}

@Suite("Insight")
struct InsightTests {
    @Test("Real questions at the end of a final message are caught", arguments: [
        "I added the migration. Should I also backfill the users table?",
        "Two options: keep the cache or drop it. Which approach do you prefer?",
        "The plan is ready. Would you like me to start with the API layer",
        "Done with step 1. Please confirm the staging URL before I deploy.",
    ])
    func catchesQuestions(text: String) {
        #expect(QuestionDetector.asksUser(text))
    }

    @Test("Statements and polite closers are not questions", arguments: [
        "Pagination shipped and all 14 tests pass.",
        "All done. Let me know if you need anything else!",
        "Fixed the bug. Anything else?",
        "```swift\nlet x = y ?? z\n```\nRefactor complete.",
    ])
    func ignoresStatements(text: String) {
        #expect(!QuestionDetector.asksUser(text))
    }

    @Test("Silent working agents are flagged once per silence")
    func stuck() {
        var detector = StuckDetector()
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        #expect(detector.newlyStuck(working: [("a", start)], now: start.addingTimeInterval(599)).isEmpty)
        #expect(detector.newlyStuck(working: [("a", start)], now: start.addingTimeInterval(600)) == ["a"])
        #expect(detector.newlyStuck(working: [("a", start)], now: start.addingTimeInterval(900)).isEmpty)
        let news = start.addingTimeInterval(950)
        #expect(detector.newlyStuck(working: [("a", news)], now: news.addingTimeInterval(600)) == ["a"])
    }

    @Test("Projects the user always waves away are suggested for batching, once")
    func learning() {
        var tracker = EngagementTracker()
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        for i in 0..<5 { tracker.record(.dismissedQuickly, project: "docs-site", now: now.addingTimeInterval(Double(i))) }
        for i in 0..<5 { tracker.record(.dismissedQuickly, project: "api", now: now.addingTimeInterval(Double(i))) }
        tracker.record(.opened, project: "api", now: now)
        #expect(tracker.suggestions(excluding: [], now: now.addingTimeInterval(10)) == ["docs-site"])
        tracker.decline(project: "docs-site")
        #expect(tracker.suggestions(excluding: [], now: now.addingTimeInterval(10)).isEmpty)
    }
}
