import MoonletBrain
import Testing

@Suite("Companion mood")
struct ExpressionTests {
    @Test("good news gets a mood that matches its words", arguments: [
        ("Deployed to production", CompanionMood.celebrate),
        ("PR #42 merged into main", .celebrate),
        ("All 14 tests pass", .proud),
        ("Fixed a typo in the README", .cheeky),
        ("Found 3 more flaky tests", .surprised),
        ("Thanks, that unblocked me", .grateful),
        ("Refactored the orders module", .happy),
    ])
    func finished(detail: String, mood: CompanionMood) {
        #expect(CompanionMood.read(kind: .finished, detail: detail) == mood)
    }

    @Test("requests are asking, curious, or nervous")
    func requests() {
        #expect(CompanionMood.read(kind: .needsYou, detail: "Wants to run npm install") == .asking)
        #expect(CompanionMood.read(kind: .needsYou, detail: "Wants to run rm -rf build/") == .nervous)
        #expect(CompanionMood.read(kind: .needsYou, detail: "Which database should the tests use? SQLite · Postgres") == .curious)
        #expect(CompanionMood.read(kind: .question, detail: "Ready to ship it") == .curious)
    }

    @Test("bad news is never read as good news")
    func badNews() {
        #expect(CompanionMood.read(kind: .failed, detail: "Deploy failed: staging refused the connection") == .teary)
        #expect(CompanionMood.read(kind: .failed, detail: "Hit the usage limit, back at 9:00") == .sleepy)
        #expect(CompanionMood.read(kind: .stuck, detail: "No news for 12 min") == .worried)
    }

    @Test("only requests wait for an answer, and the tint follows the mood")
    func waitingAndTint() {
        for mood in CompanionMood.allCases {
            #expect(mood.waitsForAnswer == (mood.tint == .needsYou))
        }
        #expect(CompanionMood.teary.tint == .problem)
        #expect(CompanionMood.celebrate.expression == .starry)
    }
}
