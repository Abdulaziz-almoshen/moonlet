import AppKit
import MoonletBrain
import SwiftUI

/// What the open summon view shares between its panel, the well, and the rows:
/// which agent the pointer is on, where the pointer is, and whether to animate.
@MainActor
final class SummonLive: ObservableObject {
    /// The agent under the pointer, in the well or in its row.
    @Published private(set) var hovered: String?
    /// Whether the panel is on screen. The well animates only then.
    @Published var isRunning = false
    /// True for the first moments after opening, while everyone pops in: the
    /// well draws at 60 frames a second then, and at 30 once it settles.
    @Published var isSettling = false
    /// False for the moment the panel opens, so the view can grow into place.
    @Published var isShown = true
    /// The well's center on screen, kept by the panel; nil in still images.
    var wellOnScreen: CGPoint?
    let motion = WellMotion()

    private var hoveredRow: String?
    private var hoveredInWell: String?

    /// The pointer relative to the well's center, y down; nil in still images.
    var pointerInWell: CGPoint? {
        guard let center = wellOnScreen else { return nil }
        let mouse = NSEvent.mouseLocation
        return CGPoint(x: mouse.x - center.x, y: center.y - mouse.y)
    }

    /// The pointer entered or left an agent's row or the Next up card.
    func hoverRow(_ id: String, inside: Bool) {
        if inside {
            hoveredRow = id
        } else if hoveredRow == id {
            hoveredRow = nil
        }
        settleHover()
    }

    /// The pointer moved over the well, onto an agent or off them all.
    func hoverInWell(_ id: String?) {
        hoveredInWell = id
        settleHover()
    }

    func clearHover() {
        hoveredRow = nil
        hoveredInWell = nil
        settleHover()
    }

    private func settleHover() {
        let next = hoveredRow ?? hoveredInWell
        if next != hovered { hovered = next }
    }
}

/// The gravity well: the companion at the center and every agent as a small
/// companion around it, closer the sooner it needs the user.
struct SummonWell: View {
    static let size: CGFloat = 184
    /// At most this many agents orbit; the list still shows the rest.
    static let capacity = 16

    /// Ranked, most urgent first.
    var agents: [AgentRow]
    var hostExpression: Expression
    var open: (String) -> Void
    @ObservedObject var live: SummonLive
    @Environment(\.isSnapshot) private var isSnapshot
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        TimelineView(.animation(minimumInterval: live.isSettling ? 1 / 60 : 1 / 30, paused: !live.isRunning)) { timeline in
            let frame = live.motion.step(
                agents: Array(agents.prefix(Self.capacity)), host: hostExpression, at: timeline.date,
                pointer: live.pointerInWell, hovered: live.hovered, settled: isSnapshot || !live.isRunning,
                still: reduceMotion)
            ZStack(alignment: .topLeading) {
                Canvas { context, size in Self.draw(frame, in: &context, size: size) }
                if let bubble = frame.bubble {
                    SummonBubble(text: bubble.text, below: bubble.below)
                        .position(x: min(max(bubble.anchor.x + Self.size / 2, Self.size / 2 - 10), Self.size + 30),
                                  y: bubble.anchor.y + Self.size / 2)
                }
            }
        }
        .frame(width: Self.size, height: Self.size)
        .contentShape(Rectangle())
        .onContinuousHover { phase in
            switch phase {
            case .active(let point): live.hoverInWell(live.motion.agent(at: Self.wellPoint(point)))
            case .ended: live.hoverInWell(nil)
            }
        }
        .onTapGesture(coordinateSpace: .local) { point in
            if let id = live.motion.agent(at: Self.wellPoint(point)) { open(id) }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Agents, closer to the middle the sooner they need you")
        .accessibilityChildren {
            ForEach(agents) { agent in
                Text("\(agent.label), \(agent.words)")
                    .accessibilityAddTraits(.isButton)
                    .accessibilityAction { open(agent.id) }
            }
        }
    }

    private static func wellPoint(_ point: CGPoint) -> CGPoint {
        CGPoint(x: point.x - size / 2, y: point.y - size / 2)
    }

    /// Dashed rings, the host companion, then the agents, least urgent first so
    /// the ones that need the user sit on top.
    private static func draw(_ frame: WellFrame, in context: inout GraphicsContext, size: CGSize) {
        let center = CGPoint(x: size.width / 2, y: size.height / 2)
        for (radius, opacity) in [(36.0, 0.55), (62.0, 0.35), (80.0, 0.25)] {
            let ring = Path(ellipseIn: CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2))
            context.stroke(ring, with: .color(.secondary.opacity(opacity)), style: StrokeStyle(lineWidth: 0.7, dash: [2, 4]))
        }
        context.withCGContext { cg in
            if frame.hostScale > 0.02 {
                drawCompanion(frame.host, in: cg, at: center, scale: frame.hostScale)
            }
            for mini in frame.minis.reversed() {
                drawCompanion(mini.pose, in: cg, at: CGPoint(x: center.x + mini.center.x, y: center.y + mini.center.y), scale: mini.scale)
            }
        }
    }

    /// Draws one companion clipped to a box around it, props included. Props
    /// that fade draw through transparency layers as big as the clip, so the
    /// box keeps each frame about three times cheaper than the whole well.
    private static func drawCompanion(_ pose: CompanionPose, in context: CGContext, at center: CGPoint, scale: CGFloat) {
        let reach = 24 * scale
        context.saveGState()
        context.clip(to: CGRect(x: center.x - reach, y: center.y - reach, width: reach * 2, height: reach * 2))
        CompanionArt.draw(pose, in: context, center: center, scale: scale, flipped: true)
        context.restoreGState()
    }
}

/// Words beside an agent the pointer rests on: above it, or below it near the
/// top of the well, so they never cover the headline.
private struct SummonBubble: View {
    var text: String
    var below: Bool

    var body: some View {
        // A 1-point anchor with the bubble hanging off it, so the bubble's
        // edge, not its center, sits at the anchor.
        Color.clear
            .frame(width: 1, height: 1)
            .overlay(alignment: below ? .top : .bottom) {
                Text(text)
                    .font(.system(size: 11))
                    .foregroundStyle(.primary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(.background))
                    .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).strokeBorder(.separator, lineWidth: 0.5))
                    .frame(width: 164)
            }
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }
}

/// One frame of the well: where everyone is and how they look.
struct WellFrame {
    struct Mini {
        var id: String
        /// Relative to the well's center, y down.
        var center: CGPoint
        var scale: CGFloat
        var pose: CompanionPose
    }

    var host = CompanionPose()
    var hostScale: CGFloat = 1.7
    /// Most urgent first.
    var minis: [Mini] = []
    /// Words for the agent under the pointer, anchored above it (or below, near the top).
    var bubble: (text: String, anchor: CGPoint, below: Bool)?
}

/// Moves the well's companions from frame to frame: they pop in by rank, then
/// spring toward the ring their activity puts them on.
@MainActor
final class WellMotion {
    /// Points per rig unit for the host and for each agent.
    static let hostScale: CGFloat = 1.7
    static let miniScale: CGFloat = 1.22

    private struct Body {
        var angle: Double
        var radius: Double
        /// Grows to 1.25 while the pointer rests on it.
        var hover: Double = 1
        /// Seconds after opening when it starts popping in.
        var popAt: Double
        var activity: AgentActivity
        /// When its activity changed while the view was open: it jumps and sparkles.
        var newsAt: Double?
        var blinker = Blinker()
    }

    private var bodies: [String: Body] = [:]
    private var openedAt = Date()
    private var lastTime: Double?
    private var hostBlinker = Blinker()
    private var last = WellFrame()

    /// Starts over, as the panel opens.
    func reset(now: Date = Date()) {
        bodies = [:]
        openedAt = now
        lastTime = nil
    }

    /// The agent drawn at `point`, relative to the well's center, y down.
    func agent(at point: CGPoint) -> String? {
        last.minis
            .map { (id: $0.id, distance: hypot($0.center.x - point.x, $0.center.y - point.y), reach: 12 * $0.scale) }
            .filter { $0.distance < $0.reach }
            .min { $0.distance < $1.distance }?.id
    }

    /// Advances to `date` and returns the frame to draw. `settled` puts
    /// everyone where they end up, for still images; `still` keeps them from
    /// drifting and bouncing, for Reduce Motion.
    func step(agents: [AgentRow], host: Expression, at date: Date, pointer: CGPoint?, hovered: String?,
              settled: Bool, still: Bool) -> WellFrame {
        // The clock starts with the first frame drawn, so nothing pops in unseen.
        let first = lastTime == nil
        if first, !settled { openedAt = date }
        let t = settled ? 10 : max(0, date.timeIntervalSince(openedAt))
        let dt = settled ? 1 : min(0.05, max(0, t - (lastTime ?? t)))
        lastTime = t
        let calm = settled || still

        // Everyone springs toward its ring and slot; working agents orbit slowly.
        for (rank, agent) in agents.enumerated() {
            var angle = Self.slot(rank)
            if agent.activity == .working, !calm { angle += t * 0.16 }
            let radius = Self.radius(agent.activity)
            var body = bodies[agent.id] ?? Body(angle: angle, radius: settled ? radius : 96,
                                                popAt: first ? 0.08 + Double(rank) * 0.08 : t,
                                                activity: agent.activity)
            if body.activity != agent.activity {
                body.activity = agent.activity
                body.newsAt = t
            }
            var turn = angle - body.angle
            while turn > .pi { turn -= 2 * .pi }
            while turn < -.pi { turn += 2 * .pi }
            if calm {
                body.angle = angle
                body.radius = radius
            } else {
                body.angle += turn * min(1, dt * 3)
                body.radius += (radius - body.radius) * min(1, dt * (t < 1 ? 5 : 2.2))
            }
            body.hover += ((hovered == agent.id ? 1.25 : 1) - body.hover) * min(1, dt * 14)
            bodies[agent.id] = body
        }
        let present = Set(agents.map(\.id))
        bodies = bodies.filter { present.contains($0.key) }

        func place(_ id: String) -> CGPoint? {
            bodies[id].map { CGPoint(x: cos($0.angle) * $0.radius, y: sin($0.angle) * $0.radius) }
        }
        let hoveredAt = hovered.flatMap(place)

        var frame = WellFrame()
        for (rank, agent) in agents.enumerated() {
            guard var body = bodies[agent.id], let at = place(agent.id) else { continue }
            let pop = calm ? 1 : Ease.backOut((t - body.popAt) / 0.35)
            let fresh = body.newsAt.map { t - $0 } ?? 99
            var (expression, kinds) = agent.face(now: date)
            let dozing = expression == .sleepy && agent.activity == .done
            let jump = fresh < 0.9 && !calm ? -sin(fresh / 0.9 * .pi) * 9 : 0
            let bob = calm ? 0 : sin(t * 2.2 + Double(rank)) * (dozing ? 0.4 : 1.1)
            if fresh < 1.2 { kinds.append(.sparkle) }

            var pose = CompanionPose()
            pose.expression = expression
            pose.phase = agent.phase
            pose.lid = settled ? 1 : body.blinker.step(dt)
            pose.look = Self.look(from: at, rank: rank, t: t, agent: agent, hovered: hovered, hoveredAt: hoveredAt, pointer: pointer)
            pose.props = kinds.map { kind in
                let progress: Double = switch kind {
                case .sign: t * 0.25
                case .hat: 0
                case .sparkle: min(1, fresh / 1.2)
                default: (t * 0.45 + Double(rank) * 0.2).truncatingRemainder(dividingBy: 1)
                }
                return CompanionProp(kind: kind, progress: progress)
            }
            bodies[agent.id] = body
            guard pop > 0.02 else { continue }
            frame.minis.append(.init(id: agent.id, center: CGPoint(x: at.x, y: at.y + bob + jump),
                                     scale: Self.miniScale * max(0.01, pop) * body.hover, pose: pose))
            if agent.id == hovered {
                let words = agent.activity == .working
                    ? [agent.status, agent.when(now: date)].filter { !$0.isEmpty }.joined(separator: " · ")
                    : agent.words
                let y = at.y + bob + jump
                let below = y < -44
                frame.bubble = (words.isEmpty ? agent.label : "\(agent.label): \(words)",
                                CGPoint(x: at.x, y: below ? y + 16 : y - 16), below)
            }
        }
        // The hovered agent is drawn last, on top of its neighbors.
        if let index = frame.minis.firstIndex(where: { $0.id == hovered }) {
            frame.minis.insert(frame.minis.remove(at: index), at: 0)
        }

        frame.host.expression = host
        frame.host.lid = settled ? 1 : hostBlinker.step(dt)
        if let hoveredAt, hypot(hoveredAt.x, hoveredAt.y) > 0 {
            let length = hypot(hoveredAt.x, hoveredAt.y)
            frame.host.look = CGVector(dx: hoveredAt.x / length, dy: hoveredAt.y / length)
        } else if let pointer {
            frame.host.look = CGVector(dx: min(max(pointer.x / 120, -1), 1), dy: min(max(pointer.y / 120, -1), 1))
        }
        frame.hostScale = Self.hostScale * (calm ? 1 : Ease.backOut(t / 0.4))
        last = frame
        return frame
    }

    /// Where an agent looks: at the agent the pointer rests on, at the pointer
    /// while it waits (or is itself pointed at), and otherwise idly around.
    private static func look(from at: CGPoint, rank: Int, t: Double, agent: AgentRow, hovered: String?,
                             hoveredAt: CGPoint?, pointer: CGPoint?) -> CGVector {
        func toward(_ target: CGPoint) -> CGVector {
            let dx = target.x - at.x, dy = target.y - at.y
            let length = hypot(dx, dy)
            return length > 0 ? CGVector(dx: dx / length, dy: dy / length) : .zero
        }
        if let hovered, hovered != agent.id, let hoveredAt { return toward(hoveredAt) }
        if agent.activity == .waiting || hovered == agent.id, let pointer { return toward(pointer) }
        return CGVector(dx: sin(t * 0.8 + Double(rank)) * 0.7, dy: 0)
    }

    /// The ring for an activity: waiting closest, then failed, working, and done.
    static func radius(_ activity: AgentActivity) -> Double {
        switch activity {
        case .waiting: 36
        case .failed: 48
        case .working: 62
        case .done, .idle: 80
        }
    }

    /// The angle for a rank: the first six fan out from the right, toward the
    /// Next up card; each one after that takes the middle of the widest gap
    /// left, so the rest spread evenly around.
    static func slot(_ rank: Int) -> Double {
        slots[min(rank, slots.count - 1)]
    }

    private static let slots: [Double] = {
        var slots: [Double] = [0, -0.95, 0.95, -1.9, 1.9, .pi]
        while slots.count < SummonWell.capacity {
            let sorted = slots.map { angle in
                let a = remainder(angle, 2 * .pi)
                return a >= .pi ? a - 2 * .pi : a
            }.sorted()
            var widest = (start: sorted[sorted.count - 1] - 2 * .pi, width: sorted[0] - (sorted[sorted.count - 1] - 2 * .pi))
            for (a, b) in zip(sorted, sorted.dropFirst()) where b - a > widest.width + 1e-9 {
                widest = (a, b - a)
            }
            slots.append(widest.start + widest.width / 2)
        }
        return slots
    }()
}
