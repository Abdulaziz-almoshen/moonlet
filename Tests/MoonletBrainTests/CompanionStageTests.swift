import CoreGraphics
import Foundation
import Testing
@testable import MoonletBrain

@Suite("Companion stage")
struct CompanionStageTests {
    /// A 1440 x 900 screen with a 25-point menu bar and no Dock.
    let screen = CGRect(x: 0, y: 0, width: 1440, height: 900)
    let visible = CGRect(x: 0, y: 0, width: 1440, height: 875)
    let card = CGSize(width: 220, height: 78)

    func inside(_ point: CGPoint, _ rect: CGRect, reach: CGFloat = CompanionStage.reach) -> Bool {
        point.x - reach >= rect.minX && point.x + reach <= rect.maxX && point.y - reach >= rect.minY && point.y + reach <= rect.maxY
    }

    @Test("The companion rides below and right of the pointer")
    func ridesBesideThePointer() {
        let spot = CompanionStage.ridingSpot(pointer: CGPoint(x: 700, y: 450), screen: screen)
        #expect(spot == CGPoint(x: 720, y: 422))
    }

    @Test("Near the right edge the companion mirrors to the pointer's left; near the bottom it sits above the tip")
    func mirrorsAtEdges() {
        let right = CompanionStage.ridingSpot(pointer: CGPoint(x: 1430, y: 450), screen: screen)
        #expect(right.x < 1430)
        #expect(right == CGPoint(x: 1410, y: 422))
        let bottom = CompanionStage.ridingSpot(pointer: CGPoint(x: 700, y: 20), screen: screen)
        #expect(bottom.y > 20)
    }

    @Test("The companion never leaves the pointer's screen", arguments: [
        CGPoint(x: 0, y: 0), CGPoint(x: 1439, y: 0), CGPoint(x: 0, y: 899), CGPoint(x: 1439, y: 899),
        CGPoint(x: 1435, y: 5), CGPoint(x: 3, y: 450), CGPoint(x: 720, y: 899),
    ])
    func staysOnScreen(pointer: CGPoint) {
        #expect(inside(CompanionStage.ridingSpot(pointer: pointer, screen: screen), screen))
        // A second display to the right doesn't pull it over.
        let left = CGRect(x: -1440, y: 0, width: 1440, height: 900)
        let shifted = CGPoint(x: pointer.x - 1440, y: pointer.y)
        #expect(inside(CompanionStage.ridingSpot(pointer: shifted, screen: left), left))
    }

    @Test("The card stays on the visible frame and never covers the pointer's tip, wherever the pointer is")
    func cardNeverCoversTheTip() {
        for x in stride(from: CGFloat(0), through: 1439, by: 37) {
            for y in stride(from: CGFloat(0), through: 899, by: 29) {
                let pointer = CGPoint(x: x, y: y)
                let companion = CompanionStage.ridingSpot(pointer: pointer, screen: screen)
                let origin = CompanionStage.cardOrigin(companion: companion, size: card, bounds: visible)
                let frame = CGRect(origin: origin, size: card)
                #expect(visible.contains(frame), "card off screen for pointer \(pointer)")
                #expect(!CompanionStage.visibleBox(origin: origin, size: card).contains(pointer), "card covers pointer \(pointer)")
            }
        }
    }

    @Test("Without the companion, the card rides below and right of the pointer as it always did")
    func followsLikeBefore() {
        let origin = CompanionStage.followingOrigin(pointer: CGPoint(x: 700, y: 450), size: card, bounds: visible)
        #expect(origin == CGPoint(x: 722, y: 450 - 30 - card.height))
        // It flips left at the right edge and up at the bottom edge.
        let right = CompanionStage.followingOrigin(pointer: CGPoint(x: 1400, y: 450), size: card, bounds: visible)
        #expect(right.x == 1400 - 16 - card.width)
        let bottom = CompanionStage.followingOrigin(pointer: CGPoint(x: 700, y: 60), size: card, bounds: visible)
        #expect(bottom.y == CGFloat(60 + 18))
    }

    @Test("A card is clamped inside its screen's visible frame")
    func clamps() {
        let clamped = CompanionStage.clamp(CGPoint(x: 1300, y: 830), size: card, into: visible)
        #expect(visible.contains(CGRect(origin: clamped, size: card)))
        #expect(CompanionStage.clamp(CGPoint(x: 400, y: 300), size: card, into: visible) == CGPoint(x: 400, y: 300))
    }

    @Test("A parked card takes input only on its visible box, after a rest, and never around a scroll")
    func parkedCardInput() {
        let origin = CGPoint(x: 400, y: 300)
        let box = CompanionStage.visibleBox(origin: origin, size: card)
        let middle = CGPoint(x: box.midX, y: box.midY)
        #expect(CompanionStage.parkedCardTakesInput(pointer: middle, box: box, restedFor: 0.2, secondsSinceScroll: 10))
        // Just resting there isn't long enough yet.
        #expect(!CompanionStage.parkedCardTakesInput(pointer: middle, box: box, restedFor: 0.05, secondsSinceScroll: 10))
        // A scroll a moment ago keeps it click-through.
        #expect(!CompanionStage.parkedCardTakesInput(pointer: middle, box: box, restedFor: 2, secondsSinceScroll: 0.1))
        // The transparent margin never takes input.
        let margin = CGPoint(x: origin.x + 4, y: box.midY)
        #expect(!CompanionStage.parkedCardTakesInput(pointer: margin, box: box, restedFor: 2, secondsSinceScroll: 10))
    }

    @Test("Only events made while the card took input are its own")
    func eventsWhileTakingInput() {
        #expect(CompanionStage.cardTookEvent(at: 100, takesInputNow: true, clickThroughSince: 0))
        // A click queued behind the first, made before the card went click-through.
        #expect(CompanionStage.cardTookEvent(at: 99.8, takesInputNow: false, clickThroughSince: 100))
        // A click made well after it went click-through was captured by mistake.
        #expect(!CompanionStage.cardTookEvent(at: 101, takesInputNow: false, clickThroughSince: 100))
        // A card that never took input owns nothing.
        #expect(!CompanionStage.cardTookEvent(at: 5, takesInputNow: false, clickThroughSince: 0))
    }

    @Test("A card leads with the moment of its color and knows who waits on the user")
    func leadAndWaiting() {
        let now = Date()
        func moment(_ agent: String, _ kind: MomentKind, _ detail: String) -> Moment {
            Moment(agentID: agent, agentLabel: agent, project: agent, kind: kind, detail: detail, createdAt: now)
        }
        let digest = AttentionEngine.summaryCard([
            moment("deploy-bot", .finished, "Deployed to production"),
            moment("prod-api", .needsYou, "Wants to run npm install"),
            moment("web", .question, "Which port? 3000 · 8080"),
            moment("prod-api", .needsYou, "Wants to run npm test"),
        ], now: now)
        #expect(digest.tone == .needsYou)
        #expect(digest.leadMoment?.detail == "Wants to run npm install")
        #expect(digest.waitingAgentIDs == ["prod-api", "web"])

        let done = AttentionEngine.card(for: [moment("a", .finished, "Fixed a typo"), moment("b", .finished, "All 3 tests pass")], now: now)
        #expect(done.leadMoment?.detail == "Fixed a typo")
        #expect(done.waitingAgentIDs.isEmpty)
    }
}
