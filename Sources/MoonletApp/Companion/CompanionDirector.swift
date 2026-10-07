import AppKit
import MoonletBrain
import QuartzCore

/// Brings the companion out of the pointer when an agent talks, performs the
/// mood of what it said, and puts it away when the talk is over.
///
/// It also places the card: beside the companion while it rides with the
/// pointer, and parked in place for a question or permission request, so the
/// user can reach it instead of chasing it.
@MainActor
final class CompanionDirector {
    /// Show the companion. When off, cards still follow the pointer as before.
    var isEnabled = true
    /// Opens an agent's tab or app, by agent identifier.
    var onOpen: ((String) -> Void)?
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
    static let pointerOffset = CGVector(dx: 20, dy: 28)
    /// The card's transparent margin around its visible box (`CardView` padding).
    private static let cardInset: CGFloat = 10

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
        let mood = Self.mood(of: card)
        begin(Scene(card: card, mood: mood, agentID: card.moments.first?.agentID, shownAt: Date()))
        cards.show(card, at: cardOrigin(forCompanionAt: position, size: cards.size))
    }

    func hide(_ card: Card, reason: HideReason) {
        guard var current = scene, current.card?.id == card.id else {
            cards.hide(flyHome: reason == .seen)
            return
        }
        // The agent still waits on the user: the card stays where it parked, so the
        // user can reach it, until the agent gets its answer.
        if current.mood.waitsForAnswer, card.tone.isBlocking, reason == .seen || reason == .clicked {
            current.engineDone = true
            scene = current
            return
        }
        switch reason {
        case .resolved: thank()
        case .seen: leave(flyHome: true)
        default: leave(quickly: true)
        }
    }

    /// The agent stopped waiting on the user: it got its answer.
    func resolved(agentID: String) {
        guard let current = scene, current.agentID == agentID, current.mood.waitsForAnswer,
              current.phase == .arriving || current.phase == .performing else { return }
        thank()
    }

    /// The summon view covers everything, so the companion steps aside.
    func summonOpened() {
        if scene != nil { leave(quickly: true) }
    }

    /// A quick task the user watched finish: a short peek out of the pointer, no card.
    func peek(_ kind: MomentKind) {
        guard scene == nil, isEnabled else { return }
        begin(Scene(card: nil, mood: kind == .finished ? .cheeky : CompanionMood.read(kind: kind, detail: ""), agentID: nil, shownAt: Date()))
    }

    /// Mouse movements between timer ticks, so the companion keeps up with the pointer.
    func pointerMoved() {
        if timer != nil { step() }
    }

    static func mood(of card: Card) -> CompanionMood {
        let detail = card.isDigest ? card.moments.map(\.detail).joined(separator: " ") : card.detail
        return CompanionMood.read(kind: card.tone, title: card.title, detail: detail)
    }

    // MARK: - Scenes

    private struct Park {
        var origin: CGPoint
        var target: CGPoint
        var away = 0.0
    }

    private enum Phase { case arriving, performing, thanking, leaving }

    private struct Scene {
        var card: Card?
        var mood: CompanionMood
        var agentID: String?
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
        var wasNear = false
        var hopAt: Double?
        /// The engine is done with the card, but the agent still waits, so it stays parked.
        var engineDone = false
        var cardOut = true
        var phaseT = 0.0
        var quickly = false
        var lastExpression: Expression?
        var popT = 1.0

        init(card: Card?, mood: CompanionMood, agentID: String?, shownAt: Date) {
            self.card = card
            self.mood = mood
            self.agentID = agentID
            self.shownAt = shownAt
            self.cardOut = card != nil
            performance = MoodPerformance.of(mood)
        }
    }

    private var reduceMotion: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }

    private func begin(_ next: Scene) {
        var next = next
        if scene == nil || (scene?.visibility ?? 0) < 0.05 {
            // Pop out of the pointer's tip.
            let mouse = NSEvent.mouseLocation
            position = CGPoint(x: mouse.x + 4, y: mouse.y - 6)
            velocity = .zero
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
        cards.setClickable(false)
        scene = next
        startTimer()
    }

    private func thank() {
        guard var current = scene else { return }
        current.phase = .thanking
        current.phaseT = 0
        if current.cardOut { cards.hide(flyHome: false); current.cardOut = false }
        cards.setClickable(false)
        scene = current
    }

    private func leave(quickly: Bool = false, flyHome: Bool = false) {
        guard var current = scene, current.phase != .leaving else { return }
        current.phase = .leaving
        current.phaseT = 0
        current.quickly = quickly
        if current.cardOut { cards.hide(flyHome: flyHome); current.cardOut = false }
        cards.setClickable(false)
        scene = current
    }

    private func cardClicked() {
        guard let id = scene?.agentID else { return }
        onOpen?(id)
        leave()
    }

    private func end() {
        scene = nil
        window.hide()
        cards.setClickable(false)
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
        let mouse = NSEvent.mouseLocation
        let size = cards.size

        // A request parks so the user can reach it; it catches up if the user moves far away.
        var parked = false, near = false
        if s.mood.waitsForAnswer, s.cardOut, s.phase == .performing, s.t > 0.7 {
            if s.park == nil {
                let origin = cardOrigin(forCompanionAt: position, size: size)
                s.park = Park(origin: origin, target: origin)
                cards.setClickable(true, hint: s.agentID.flatMap { placeName?($0) }.map { "Open in \($0)" } ?? "Open")
            }
            var park = s.park!
            let center = CGPoint(x: park.origin.x + size.width / 2, y: park.origin.y + size.height / 2)
            let distance = hypot(mouse.x - center.x, mouse.y - center.y)
            park.away = distance > 260 ? park.away + dt : 0
            if park.away > 0.9 {
                park.target = cardOrigin(forCompanionAt: CGPoint(x: mouse.x + Self.pointerOffset.dx, y: mouse.y - Self.pointerOffset.dy), size: size)
                park.away = 0
                s.hopAt = s.t
            }
            let k = min(1, dt * 5)
            park.origin.x += (park.target.x - park.origin.x) * k
            park.origin.y += (park.target.y - park.origin.y) * k
            s.park = park
            parked = true
            near = distance < 150
            if near, !s.wasNear { s.hopAt = s.t }
            s.wasNear = near
            // An unanswered request doesn't sit there forever; its reminders bring it back.
            if s.t > 600 { scene = s; leave(quickly: false); return }
        }

        let inset = Self.cardInset
        let target = parked
            ? CGPoint(x: s.park!.origin.x + inset + 1, y: s.park!.origin.y + size.height - inset - 1)
            : CGPoint(x: mouse.x + Self.pointerOffset.dx, y: mouse.y - Self.pointerOffset.dy)
        if reduceMotion {
            position = target
            velocity = .zero
        } else {
            velocity.dx += ((target.x - position.x) * 140 - velocity.dx * 15) * dt
            velocity.dy += ((target.y - position.y) * 140 - velocity.dy * 15) * dt
            position.x += velocity.dx * dt
            position.y += velocity.dy * dt
        }
        if s.cardOut { cards.move(to: parked ? s.park!.origin : cardOrigin(forCompanionAt: position, size: size)) }

        let speed = hypot(velocity.dx, velocity.dy)
        var change = PoseChange()
        switch s.phase {
        case .arriving, .performing:
            if s.phase == .arriving, s.t > 0.45 { s.phase = .performing }
            if let entrance = s.entrance, s.t < entrance.duration, !reduceMotion {
                entrance.apply(s.t / entrance.duration, &change)
            } else if !reduceMotion {
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
                        s.nextAct = s.engineDone ? Double.random(in: 2.5...4.5) : Double.random(in: 0.7...2.3)
                    } else {
                        act.apply(p, to: &change)
                    }
                }
            }
            if let hop = s.hopAt, s.t - hop < 0.5, !reduceMotion { change.offset.y -= sin((s.t - hop) / 0.5 * .pi) * 5 }
            if near { change.look = nil; change.blush = 1.3 }
            if !parked, speed > 650 { change.armLeft = 135; change.armRight = -135; change.squash = 0.94 }
            // A peek is over almost as soon as it starts.
            if s.card == nil, s.t > 1.1 { scene = s; leave(quickly: true); return }
        case .thanking:
            s.phaseT += dt
            let fast = Date().timeIntervalSince(s.shownAt) < 6
            change.expression = fast ? .smitten : .delighted
            change.offset.y -= sin(min(1, s.phaseT / 0.7) * .pi) * 5
            if fast { change.add(.heart, min(1, s.phaseT / 1.3)) }
            if s.phaseT > 1.3 { scene = s; leave(); return }
        case .leaving:
            s.phaseT += dt
            let wave = s.quickly ? 0 : 0.45
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
        let keeps = s.phase == .thanking || s.phase == .leaving
            ? s.performance.keeps(s.t).filter { $0.kind == .hat }
            : s.performance.keeps(s.t)
        let dx = mouse.x - position.x, dy = -(mouse.y - position.y), d = max(1, hypot(dx, dy))
        let appear = s.phase == .arriving && !reduceMotion ? Ease.backOut(s.t / 0.45) : 1
        let pose = CompanionPose(
            expression: expression,
            look: change.look ?? CGVector(dx: dx / d, dy: dy / d),
            lid: blinker.step(dt),
            offset: change.offset,
            rotation: min(max(velocity.dx / 40, -18), 18) + change.rotation,
            squash: change.squash,
            stretch: min(0.22, speed / 2600),
            pop: 1 + CGFloat(sin(s.popT * .pi)) * 0.08,
            armLeft: change.armLeft,
            armRight: change.armRight,
            blush: change.blush,
            phase: 1,
            props: keeps + change.props)
        scene = s
        guard isEnabled else { window.hide(); return }
        let grow = s.phase == .leaving ? s.visibility : CGFloat(appear)
        window.update(center: position, pose: pose, scale: Self.scale * max(0.01, grow), alpha: min(1, s.visibility * 1.4))
    }

    /// Where the card goes for a companion at `point`: to its right and a little
    /// above, flipping below and to the left at the screen's right edge, so it
    /// never covers the pointer's tip.
    private func cardOrigin(forCompanionAt point: CGPoint, size: CGSize) -> CGPoint {
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main
        let bounds = screen?.visibleFrame ?? CGRect(x: -1e5, y: -1e5, width: 2e5, height: 2e5)
        let inset = Self.cardInset
        var x = point.x + 22 - inset
        var top = point.y + 20 + inset
        if x + size.width > bounds.maxX - 8 {
            x = point.x - 22 - (size.width - inset)
            top = point.y - 14 + inset
        }
        var origin = CGPoint(x: x, y: top - size.height)
        origin.x = min(max(bounds.minX + 4, origin.x), bounds.maxX - size.width - 4)
        origin.y = min(max(bounds.minY + 4, origin.y), bounds.maxY - size.height - 4)
        return origin
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
