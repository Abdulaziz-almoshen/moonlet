import Testing
@testable import MoonletBrain

@Suite("Summaries")
struct SummaryTests {
    @Test("Model replies become short outcomes, without trailing punctuation")
    func parsesOutcome() {
        #expect(SummaryWriter.parse("Refactored /orders, improved tests, updated spec.") ==
                Summary(kind: .outcome, text: "Refactored /orders, improved tests, updated spec"))
        #expect(SummaryWriter.parse("  \"Deployment failed ECONNREFUSED 5432\"  ") ==
                Summary(kind: .outcome, text: "Deployment failed ECONNREFUSED 5432"))
    }

    @Test("ASK replies become questions")
    func parsesQuestion() {
        #expect(SummaryWriter.parse("ASK: Backfill legacy users table?") ==
                Summary(kind: .question, text: "Backfill legacy users table?"))
    }

    @Test("Rambling or thinking replies are rejected so the caller falls back")
    func rejectsRambling() {
        #expect(SummaryWriter.parse("We are given a user message that describes what they did. The task is") == nil)
        #expect(SummaryWriter.parse("<think>hmm</think>") == nil)
        #expect(SummaryWriter.parse("") == nil)
    }

    @Test("Thinking tags are stripped before parsing")
    func stripsThinking() {
        #expect(SummaryWriter.parse("<think>\nlet me see\n</think>\n14 tests pass") == Summary(kind: .outcome, text: "14 tests pass"))
    }

    @Test("Without a model, the first sentence is used and questions are still caught")
    func fallback() {
        let done = SummaryWriter.fallback(for: "Pagination shipped. I also updated the OpenAPI spec and the README.")
        #expect(done == Summary(kind: .outcome, text: "Pagination shipped"))
        let ask = SummaryWriter.fallback(for: "The migration is ready. Should I also backfill the users table?")
        #expect(ask.kind == .question)
        #expect(ask.text == "Should I also backfill the users table?")
    }

    @Test("Long fallbacks are cut at a word boundary")
    func shortens() {
        let text = SummaryWriter.shorten(String(repeating: "word ", count: 30))
        #expect(text.count <= SummaryWriter.maximumLength)
        #expect(text.hasSuffix("…"))
    }

    @Test("Long messages keep their beginning and their end in the prompt")
    func promptBudget() {
        let message = "START " + String(repeating: "middle ", count: 1000) + " END"
        let prompt = SummaryWriter.prompt(for: message)
        #expect(prompt.contains("START"))
        #expect(prompt.contains("END"))
        #expect(prompt.count < 2000)
    }
}
