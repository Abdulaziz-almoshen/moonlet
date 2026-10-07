import MoonletBrain
import Testing

@Suite("Companion mood")
struct ExpressionTests {
    @Test("good news gets a mood that matches its words", arguments: [
        ("Deployed to production", CompanionMood.celebrate),
        ("PR #42 merged into main", .celebrate),
        ("The pricing page is now live", .celebrate),
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

    @Test("a finished turn that reports bad news worries instead of celebrating", arguments: [
        ("Couldn't deploy: the staging credentials are missing.", CompanionMood.worried),
        ("Couldn’t deploy: the staging credentials are missing.", .worried),
        ("Deploy failed: staging refused the connection", .worried),
        ("The PR isn't merged yet; CI is red.", .worried),
        ("Not yet deployed, waiting on review", .worried),
        ("Benchmark shows a 40% regression", .worried),
        ("Lighthouse score dropped to 61", .worried),
        ("2 tests failed, 12 passed", .worried),
        ("Fixed 2 of 5 tests, 3 still failing", .worried),
        ("Release blocked by a missing signing key", .worried),
        ("The upload timed out", .worried),
        ("Hit the usage limit, back at 9:00", .sleepy),
        ("Deploy failed: rate limited by the registry", .sleepy),
    ])
    func finishedBadNews(detail: String, mood: CompanionMood) {
        #expect(CompanionMood.read(kind: .finished, detail: detail) == mood)
    }

    @Test("good news that names a bad word stays good news", arguments: [
        ("All 14 tests pass, no errors", CompanionMood.proud),
        ("Merged into main, 0 failures", .celebrate),
        ("Fixed 3 lint errors", .cheeky),
        ("Fixed the failing login test", .happy),
        ("Added the missing tests for checkout", .happy),
        ("Added error handling to the orders API", .happy),
        ("Added regression tests for the parser", .happy),
        ("Added rate limiting to the login endpoint", .happy),
    ])
    func finishedGoodNews(detail: String, mood: CompanionMood) {
        #expect(CompanionMood.read(kind: .finished, detail: detail) == mood)
    }

    @Test("only finished work celebrates, and only small fixes are cheeky", arguments: [
        ("Release notes drafted", CompanionMood.happy),
        ("Wrote the deployment guide.", .happy),
        ("Launched the dev server on localhost:3000", .happy),
        ("Renamed the orders table and migrated 2M rows", .happy),
        ("Updated the typography scale", .happy),
        ("Cleaned up whitespace in the config", .cheeky),
        ("A one-liner in the router", .cheeky),
        ("Addressed the review nits", .cheeky),
    ])
    func narrowWords(detail: String, mood: CompanionMood) {
        #expect(CompanionMood.read(kind: .finished, detail: detail) == mood)
    }

    @Test("only what the agent said decides the mood, not who said it")
    func detailOnly() {
        // A request from a project called prod-api: its card title is not read.
        #expect(CompanionMood.read(kind: .needsYou, detail: "Wants to run npm install") == .asking)
        // Agent names on a "2 agents done" card are not news.
        #expect(CompanionMood.read(kind: .finished, detail: "web-app, deploy-bot") == .happy)
        #expect(CompanionMood.read(kind: .finished, detail: "deploy-tools") == .happy)
        #expect(CompanionMood.read(kind: .finished, detail: "release-please") == .happy)
    }

    @Test("only the first 500 characters are read")
    func longMessages() {
        let padding = String(repeating: "Details follow. ", count: 40)
        #expect(CompanionMood.read(kind: .finished, detail: "Deployed to production. " + padding + "One step failed.") == .celebrate)
        #expect(CompanionMood.read(kind: .finished, detail: "One step failed. " + padding + "Deployed to production.") == .worried)
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
