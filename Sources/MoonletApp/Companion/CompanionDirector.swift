import AppKit
import MoonletBrain
import QuartzCore

/// Brings the companion out of the pointer when an agent talks, performs the
/// mood of what it said, and puts it away when the talk is over.
///
/// It also places the card: beside the companion while it rides with the
/// pointer, and parked in place for a question or permission request, so the
/// user can reach it instead of chasing it. The companion and its card live
/// exactly as long as the attention engine shows the card; the engine's
/// reminders bring a request back.
@MainActor
final class CompanionDirector {
    /// Show the companion. When off, cards ride below and right of the pointer,
    /// click-through, as they did before the companion. Takes effect at once.
    var isEnabled = true {
        didSet { if isEnabled != oldValue { enabledChanged() } }
    }
    /// Opens an agent's tab or app, by agent identifier, after a click on the parked card.
    var onOpen: ((_ agentID: String, _ card: Card) -> Void)?
    /// Where an agent runs, such as `iTerm`, by agent identifier.
    var placeName: ((String) -> String?)?

    private let cards: CardPanel
    private let window = CompanionPanel()
    private var timer: Timer?
    private var scene: Scene?
    private var position = CGPoint.zero
    private var velocity = CGVector.zero
    private var blinker = Blinker()
    private var lastStep = CACurrentMediaTime()
    private var lastEntrance: [CompanionMood: Int] = [:]
    private var lastBehavior: CompanionBehavior?

    /// Points per rig unit at actual size: a body about 23 points across.
    static let scale: CGFloat = 1.15
    /// Where the companion rides relative to the pointer's tip, in points, y down:
    /// just past the arrow's tail, so it never covers the tip or the arrow.
    static let pointerOffset = CompanionStage.pointerOffset
    /// The card's transparent margin around its visible box (`CardView` padding).
    private static let cardInset = CompanionStage.cardInset

    init(cards: CardPanel) {
        self.cards = cards
        cards.onClick = { [weak self] in self?.cardClicked() }
    }

    /// Whether `window` is the companion's own click-through window.
    func owns(_ window: NSWindow?) -> Bool { self.window.owns(window) }

    /// Whether the companion is out right now.
    var isPerforming: Bool { scene != nil }

    // MARK: - What the attention engine decides

    func show(_ card: Card) {
        begin(Scene(card: card, mood: Self.mood(of: card), shownAt: Date()))
        cards.show(card) { size in
            isEnabled ? cardOrigin(forCompanionAt: position, size: size) : followingOrigin(size: size)
        }
    }

    /// The engine let go of the card: seen, clicked elsewhere, the user went
    /// away, a call, the summon view, more urgent news, or the agent no longer
    /// waits. The card and the companion go with it.
    func hide(_ card: Card, reason: HideReason) {
        guard let current = scene, current.card.id == card.id else {
            // Not the card on stage; just make sure it isn't left showing.
            if cards.card?.id == card.id { cards.hide(flyHome: flies(home: reason == .seen)) }
            return
        }
        switch reason {
        // Only a request thanks the user; a stuck agent that moved on fades quietly.
        case .resolved where current.mood.waitsForAnswer: thank()
        case .seen: leave(flyHome: true)
        default: leave(quickly: true)
        }
    }

    /// The agent stopped waiting on the user. When it was the only agent the
    /// card waits on, the companion thanks the user for the answer or, if the
    /// agent's session ended, fades quietly. While other agents on the card
    /// still wait, the engine's own effects decide.
    func resolved(agentID: String, ended: Bool = false) {
        guard var current = scene, current.waiting.contains(agentID),
              current.phase == .arriving || current.phase == .performing else { return }
        guard current.waiting == [agentID] else {
            current.waiting.removeAll { $0 == agentID }
            scene = current
            if current.park != nil { cards.setParked(true, hint: hint(for: current)) }
            return
        }
        guard isEnabled else { return }
        if ended || !current.mood.waitsForAnswer { leave(quickly: true) } else { thank() }
    }

    /// The summon view covers everything, so the companion steps aside.
    func summonOpened() {
        if scene != nil { leave(quickly: true) }
    }

    /// Mouse movements between timer ticks, so the companion keeps up with the pointer.
    func pointerMoved() {
        if timer != nil { step() }
    }

    /// The companion's mood for `card`, from the words of the moment it leads
    /// with. Never its title, which holds agent and project names, nor a list of
    /// agents.
    static func mood(of card: Card) -> CompanionMood {
        CompanionMood.read(kind: card.tone, detail: card.leadMoment?.detail ?? "")
    }

    // MARK: - Scenes

    private struct Park {
        var origin: CGPoint
        var target: CGPoint
        var away = 0.0
    }

    private enum Phase { case arriving, performing, thanking, leaving }

    private struct Scene {
        var card: Card
        var mood: CompanionMood
        /// Agents on the card still waiting on the user, in card order.
        var waiting: [String]
        var shownAt: Date
        var t = 0.0
        var phase = Phase.arriving
        var visibility: CGFloat = 0
        var entrance: MoodPerformance.Entrance?
        var performance: MoodPerformance
        var bonus: CompanionBehavior?
        var act: CompanionBehavior?
        var actT = 0.0
        var nextAct = 0.6
        var park: Park?
        /// When the pointer came to rest on the parked card's visible box, in media time.
        var restingSince: CFTimeInterval?
        var wasNear = false
        var hopAt: Double?
        var cardOut = true
        var phaseT = 0.0
        var quickly = false
        /// The answer came within a few seconds of the card: heart eyes.
        var answeredQuickly = false
        var lastExpression: Expression?
        var popT = 1.0

        init(card: Card, mood: CompanionMood, shownAt: Date) {
            self.card = card
            self.mood = mood
            self.shownAt = shownAt
            waiting = card.waitingAgentIDs
            performance = MoodPerformance.of(mood)
        }

        /// The agent a click on the card opens: the first still waiting, else the card's first.
        var openID: String? { waiting.first ?? card.moments.first?.agentID }
    }

    private var reduceMotion: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }

    /// Whether a card that leaves on its own flies home. With the companion and
    /// Reduce Motion on, it fades where it is; without the companion, cards fly as they always did.
    private func flies(home: Bool) -> Bool { home && !(isEnabled && reduceMotion) }

    private func begin(_ next: Scene) {
        var next = next
        if scene == nil || (scene?.visibility ?? 0) < 0.05 {
            popOut()
        } else {
            next.visibility = scene?.visibility ?? 0
            next.phase = .performing
        }
        let entrances = next.performance.entrances
        var index = Int.random(in: 0..<entrances.count)
        if entrances.count > 1, index == lastEntrance[next.mood] { index = (index + 1) % entrances.count }
        lastEntrance[next.mood] = index
        next.entrance = entrances[index]
        // About one appearance in seven brings a small surprise.
        if Double.random(in: 0...1) < 0.15 { next.bonus = [.sneeze, .spin, .blush].randomElement() }
        cards.setParked(false)
        scene = next
        startTimer()
    }

    /// Puts the companion at the pointer's tip, where it pops out from.
    private func popOut() {
        let mouse = NSEvent.mouseLocation
        position = CompanionStage.keepOnScreen(CGPoint(x: mouse.x + 4, y: mouse.y - 6), screen: screenFrame(at: mouse))
        velocity = .zero
    }

    /// The agent got its answer while its card showed: heart eyes and a heart if
    /// the user was quick, else a delighted hop. Then the companion fades.
    private func thank() {
        guard var current = scene, current.phase == .arriving || current.phase == .performing else { return }
        if current.cardOut { cards.hide(flyHome: false); current.cardOut = false }
        guard isEnabled else { scene = current; end(); return }
        current.phase = .thanking
        current.phaseT = 0
        current.answeredQuickly = Date().timeIntervalSince(current.shownAt) < 6
        scene = current
    }

    private func leave(quickly: Bool = false, flyHome: Bool = false) {
        guard var current = scene, current.phase != .leaving else { return }
        if current.cardOut { cards.hide(flyHome: flies(home: flyHome)); current.cardOut = false }
        guard isEnabled else { scene = current; end(); return }
        current.phase = .leaving
        current.phaseT = 0
        current.quickly = quickly
        scene = current
    }

    /// A click on the parked card opens the agent's tab; the companion waves and fades.
    private func cardClicked() {
        // A second click queued behind the first finds the scene already leaving.
        guard let current = scene, current.park != nil, current.cardOut, current.phase == .performing,
              let id = current.openID else { return }
        let card = current.card
        leave()
        // Opening can wait on AppleScript; the card is click-through before it starts.
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated { self?.onOpen?(id, card) }
        }
    }

    /// The setting flipped while a card shows; it takes effect at once.
    private func enabledChanged() {
        guard var current = scene else { return }
        if isEnabled {
            // The companion pops out of the pointer and brings the card from here.
            popOut()
            current.t = 0
            current.phase = .arriving
            current.visibility = 0
            current.hopAt = nil
            scene = current
        } else {
            window.hide()
            guard current.cardOut, current.phase == .arriving || current.phase == .performing else { end(); return }
            current.park = nil
            current.restingSince = nil
            current.wasNear = false
            scene = current
            cards.setParked(false)
        }
        step()
    }

    private func end() {
        scene = nil
        window.hide()
        cards.setParked(false)
        timer?.invalidate()
        timer = nil
    }

    private func startTimer() {
        guard timer == nil else { return }
        lastStep = CACurrentMediaTime()
        // A timer, not the display's refresh, so nothing freezes after the screen sleeps.
        let timer = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.step() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    // MARK: - One frame

    private func step() {
        let now = CACurrentMediaTime()
        let dt = min(0.05, now - lastStep)
        lastStep = now
        guard var s = scene else { end(); return }
        s.t += dt
        if s.phase == .arriving, s.t > 0.45 { s.phase = .performing }
        let mouse = NSEvent.mouseLocation

        // Without the companion, the card rides below and right of the pointer, as it always did.
        guard isEnabled else {
            if s.cardOut { cards.move(to: followingOrigin(size: cards.size)) }
            scene = s
            window.hide()
            return
        }

        // With Reduce Motion: no entrances, moves, springs, hops, waves, or glides.
        let still = reduceMotion
        var size = cards.size
        let inset = Self.cardInset

        // A request parks so the user can reach it; it catches up if the user moves far away.
        var parked = false, near = false
        if s.mood.waitsForAnswer, s.cardOut, s.phase == .performing, s.t > 0.7 {
            if s.park == nil {
                // The hint line makes the card taller, so it parks at its parked size.
                cards.setParked(true, hint: hint(for: s))
                size = cards.size
                let origin = cardOrigin(forCompanionAt: position, size: size)
                s.park = Park(origin: origin, target: origin)
            }
            var park = s.park!
            let center = CGPoint(x: park.origin.x + size.width / 2, y: park.origin.y + size.height / 2)
            let distance = hypot(mouse.x - center.x, mouse.y - center.y)
            park.away = distance > 260 ? park.away + dt : 0
            if park.away > 0.9 {
                park.target = cardOrigin(forCompanionAt: ridingSpot(for: mouse), size: size)
                park.away = 0
                s.hopAt = s.t
            }
            if still {
                park.origin = park.target
            } else {
                let k = min(1, dt * 5)
                park.origin.x += (park.target.x - park.origin.x) * k
                park.origin.y += (park.target.y - park.origin.y) * k
            }
            s.park = park
            parked = true
            near = distance < 150
            if near, !s.wasNear { s.hopAt = s.t }
            s.wasNear = near
        }

        let target = parked
            ? CGPoint(x: s.park!.origin.x + inset + 1, y: s.park!.origin.y + size.height - inset - 1)
            : ridingSpot(for: mouse)
        if still {
            position = target
            velocity = .zero
        } else {
            velocity.dx += ((target.x - position.x) * 140 - velocity.dx * 15) * dt
            velocity.dy += ((target.y - position.y) * 140 - velocity.dy * 15) * dt
            position.x += velocity.dx * dt
            position.y += velocity.dy * dt
        }
        if s.cardOut { cards.move(to: parked ? s.park!.origin : cardOrigin(forCompanionAt: position, size: size)) }

        // A parked card takes a click only once the pointer rests on what the user
        // sees, and never around a scroll; otherwise it stays click-through.
        if parked {
            let box = CompanionStage.visibleBox(origin: cards.frame.origin, size: cards.frame.size)
            s.restingSince = box.contains(mouse) ? (s.restingSince ?? now) : nil
            let rested = s.restingSince.map { now - $0 } ?? 0
            let sinceScroll = rested >= CompanionStage.restBeforeInput
                ? CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: .scrollWheel) : 0
            cards.setTakesInput(CompanionStage.parkedCardTakesInput(
                pointer: mouse, box: box, restedFor: rested, secondsSinceScroll: sinceScroll))
        }

        let speed = hypot(velocity.dx, velocity.dy)
        var change = PoseChange()
        switch s.phase {
        case .arriving, .performing:
            if !still {
                if let entrance = s.entrance, s.t < entrance.duration {
                    entrance.apply(s.t / entrance.duration, &change)
                } else {
                    if let bonus = s.bonus { s.act = bonus; s.actT = 0; s.bonus = nil }
                    if s.act == nil {
                        s.nextAct -= dt
                        if s.nextAct <= 0 {
                            let pool = s.performance.pool.filter { $0 != lastBehavior }
                            s.act = pool.randomElement() ?? s.performance.pool.first
                            lastBehavior = s.act
                            s.actT = 0
                        }
                    }
                    if let act = s.act {
                        s.actT += dt
                        let p = s.actT / act.duration
                        if p >= 1 {
                            s.act = nil
                            s.nextAct = Double.random(in: 0.7...2.3)
                        } else {
                            act.apply(p, to: &change)
                        }
                    }
                }
                if let hop = s.hopAt, s.t - hop < 0.5 { change.offset.y -= sin((s.t - hop) / 0.5 * .pi) * 5 }
            }
            if near { change.look = nil; change.blush = 1.3 }
            if !parked, speed > 650 { change.armLeft = 135; change.armRight = -135; change.squash = 0.94 }
        case .thanking:
            s.phaseT += dt
            if s.answeredQuickly {
                change.expression = .smitten
                change.add(.heart, still ? 0.5 : min(1, s.phaseT / 1.3))
            } else {
                change.expression = .delighted
                if !still { change.offset.y -= sin(min(1, s.phaseT / 0.7) * .pi) * 5 }
            }
            if s.phaseT > 1.3 { scene = s; leave(quickly: true); return }
        case .leaving:
            s.phaseT += dt
            // A wave goodbye, then a fade; with Reduce Motion, only the fade.
            let wave = s.quickly || still ? 0 : 0.45
            if s.phaseT < wave {
                change.expression = .delighted
                change.armRight = -125 + sin(s.phaseT * 30) * 30
            } else {
                s.visibility = max(0, 1 - CGFloat((s.phaseT - wave) / 0.35))
                if s.visibility <= 0 { end(); return }
            }
        }
        if s.phase != .leaving { s.visibility = min(1, s.visibility + CGFloat(dt / 0.35)) }

        let expression = change.expression ?? s.mood.expression
        if expression != s.lastExpression { s.lastExpression = expression; s.popT = 0 }
        s.popT = min(1, s.popT + dt * 5)
        // Looping props hold one frame with Reduce Motion.
        let propTime = still ? 1 : s.t
        let keeps = s.phase == .thanking || s.phase == .leaving
            ? s.performance.keeps(propTime).filter { $0.kind == .hat }
            : s.performance.keeps(propTime)
        let dx = mouse.x - position.x, dy = -(mouse.y - position.y), d = max(1, hypot(dx, dy))
        let appear = s.phase == .arriving && !still ? Ease.backOut(s.t / 0.45) : 1
        let pose = CompanionPose(
            expression: expression,
            look: change.look ?? CGVector(dx: dx / d, dy: dy / d),
            lid: blinker.step(dt),
            offset: change.offset,
            rotation: min(max(velocity.dx / 40, -18), 18) + change.rotation,
            squash: change.squash,
            stretch: min(0.22, speed / 2600),
            pop: still ? 1 : 1 + CGFloat(sin(s.popT * .pi)) * 0.08,
            armLeft: change.armLeft,
            armRight: change.armRight,
            blush: change.blush,
            phase: 1,
            props: keeps + change.props)
        scene = s
        // Leaving, it shrinks as it fades; with Reduce Motion it only fades.
        let grow = s.phase == .leaving && !still ? s.visibility : CGFloat(appear)
        window.update(center: position, pose: pose, scale: Self.scale * max(0.01, grow), alpha: min(1, s.visibility * 1.4))
    }

    // MARK: - Places on screen

    /// The hint under a parked card: where a click takes the user.
    private func hint(for scene: Scene) -> String {
        scene.openID.flatMap { placeName?($0) }.map { "Open in \($0)" } ?? "Open"
    }

    /// The screen the pointer at `point` is on.
    private func screen(at point: CGPoint) -> NSScreen? {
        NSScreen.screens.first { NSMouseInRect(point, $0.frame, false) } ?? NSScreen.main
    }

    private func screenFrame(at point: CGPoint) -> CGRect {
        screen(at: point)?.frame ?? Self.anywhere
    }

    /// The visible frame of the pointer's screen, where cards go.
    private func cardBounds() -> CGRect {
        screen(at: NSEvent.mouseLocation)?.visibleFrame ?? Self.anywhere
    }

    private static let anywhere = CGRect(x: -1e5, y: -1e5, width: 2e5, height: 2e5)

    /// Where the companion rides for the pointer at `mouse`, always on the pointer's screen.
    private func ridingSpot(for mouse: CGPoint) -> CGPoint {
        CompanionStage.ridingSpot(pointer: mouse, screen: screenFrame(at: mouse))
    }

    /// Where the card goes for a companion at `point`: to its right and a little
    /// above, flipping below and to the left at the screen's right edge, so it
    /// never covers the pointer's tip.
    private func cardOrigin(forCompanionAt point: CGPoint, size: CGSize) -> CGPoint {
        CompanionStage.cardOrigin(companion: point, size: size, bounds: cardBounds())
    }

    /// Where the card goes without the companion: below and right of the pointer.
    private func followingOrigin(size: CGSize) -> CGPoint {
        CompanionStage.followingOrigin(pointer: NSEvent.mouseLocation, size: size, bounds: cardBounds())
    }
}

/// The companion's own window: a small, click-through square that rides with it.
@MainActor
final class CompanionPanel {
    private static let side: CGFloat = 140
    private let panel: NSPanel
    private let view = CompanionView(frame: NSRect(x: 0, y: 0, width: side, height: side))
    private var showing = false

    init() {
        panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: Self.side, height: Self.side),
                        styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        // Just above the card it sits on; far below the pointer and the screen-shield band.
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue + 1)
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.isReleasedWhenClosed = false
        panel.contentView = view
    }

    func owns(_ window: NSWindow?) -> Bool { window === panel }

    func update(center: CGPoint, pose: CompanionPose, scale: CGFloat, alpha: CGFloat) {
        let origin = CGPoint(x: (center.x - Self.side / 2).rounded(), y: (center.y - Self.side / 2).rounded())
        let offset = CGPoint(x: center.x - Self.side / 2 - origin.x, y: center.y - Self.side / 2 - origin.y)
        if panel.frame.origin != origin { panel.setFrameOrigin(origin) }
        view.pose = pose
        view.scale = scale
        view.subpixel = offset
        view.needsDisplay = true
        panel.alphaValue = alpha
        if !showing {
            showing = true
            panel.orderFrontRegardless()
        }
    }

    func hide() {
        guard showing else { return }
        showing = false
        panel.orderOut(nil)
    }
}

/// Draws the companion at the center of its window.
final class CompanionView: NSView {
    var pose = CompanionPose()
    var scale: CGFloat = CompanionDirector.scale
    /// The fraction of a point the window's whole-point origin is off from the
    /// companion's true position, so it glides instead of stepping.
    var subpixel = CGPoint.zero

    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        let center = CGPoint(x: bounds.midX + subpixel.x, y: bounds.midY - subpixel.y)
        CompanionArt.draw(pose, in: context, center: center, scale: scale, flipped: true)
    }
}
