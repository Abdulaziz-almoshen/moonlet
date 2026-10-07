import AppKit
import MoonletBrain
import SwiftUI

/// Every agent at a glance, opened by a small circle, the shortcut, or the menu.
/// Unlike cards, this panel takes clicks and keys without activating Moonlet:
/// open an agent with a click, a number key, or Return; Escape or a click
/// anywhere else closes it.
@MainActor
final class SummonPanel {
    var onOpen: ((String) -> Void)?
    var onBatch: ((String, Bool) -> Void)?
    private(set) var isOpen = false
    private var anchor = CGPoint.zero
    private var content = SummonContent()
    /// Counts openings, so a timer from an earlier one leaves a later one alone.
    private var openings = 0
    private let live = SummonLive()
    private let panel: SummonWindow
    private let host: FirstClickHostingView<SummonView>

    init() {
        host = FirstClickHostingView(rootView: SummonView(content: SummonContent(), actions: .init(), live: live))
        panel = SummonWindow(contentRect: NSRect(x: 0, y: 0, width: 480, height: 300),
                             styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = .popUpMenu
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        panel.acceptsMouseMovedEvents = true
        panel.contentView = host
        panel.onKey = { [weak self] event in self?.handle(event) ?? false }
    }

    /// Opens the view with its well centered on `point`, in screen coordinates,
    /// and takes the keyboard so number keys, Return, and Escape work at once.
    func open(at point: CGPoint, content: SummonContent) {
        anchor = point
        live.motion.reset()
        live.clearHover()
        live.isRunning = true
        live.isSettling = true
        openings += 1
        let opening = openings
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.openings == opening else { return }
                self.live.isSettling = false
            }
        }
        let still = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        live.isShown = still
        update(content)
        isOpen = true
        panel.alphaValue = 0
        panel.orderFrontRegardless()
        panel.makeKey()
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.2
            panel.animator().alphaValue = 1
        }
        if !still {
            DispatchQueue.main.async { [live] in
                withAnimation(.spring(response: 0.32, dampingFraction: 0.78)) { live.isShown = true }
            }
        }
    }

    func update(_ content: SummonContent) {
        self.content = content
        let actions = SummonView.Actions(
            open: { [weak self] id in self?.onOpen?(id) },
            batch: { [weak self] project, accept in self?.onBatch?(project, accept) })
        host.rootView = SummonView(content: content, actions: actions, live: live)
        let size = host.fittingSize
        panel.setContentSize(size)
        place(size)
    }

    /// Fades the panel out and hands the keyboard back to the app the user was in.
    func close() {
        guard isOpen else { return }
        isOpen = false
        live.clearHover()
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.15
            panel.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            MainActor.assumeIsolated {
                guard let self, !self.isOpen else { return }
                // Ordering out gives up key status; Moonlet was never activated,
                // so the keyboard goes straight back to the frontmost app.
                self.panel.orderOut(nil)
                self.live.isRunning = false
            }
        })
    }

    /// Whether a screen point falls inside the panel.
    func contains(_ point: CGPoint) -> Bool {
        isOpen && panel.frame.contains(point)
    }

    /// Closes the view once the pointer wanders far from it.
    func pointerMoved(to point: CGPoint) {
        guard isOpen else { return }
        let frame = panel.frame.insetBy(dx: -160, dy: -160)
        if !frame.contains(point) { close() }
    }

    /// Number keys open that row, Return opens the Next up agent, Escape closes.
    /// Keys with Command, Control, or Option pass through.
    private func handle(_ event: NSEvent) -> Bool {
        guard isOpen else { return true }
        if !event.modifierFlags.intersection([.command, .control, .option]).isEmpty { return false }
        switch Int(event.keyCode) {
        case 53: // Escape
            close()
            return true
        case 36, 76: // Return, keypad Enter
            if let agent = content.nextUp { onOpen?(agent.id) }
            return true
        default:
            guard let digit = event.charactersIgnoringModifiers.flatMap(Int.init), (1...9).contains(digit) else { return false }
            let ranked = content.ranked
            if digit <= ranked.count { onOpen?(ranked[digit - 1].id) }
            return true
        }
    }

    /// Puts the well's center on the anchor, keeping the panel on screen.
    private func place(_ size: CGSize) {
        let screen = NSScreen.screens.first { NSMouseInRect(anchor, $0.frame, false) } ?? NSScreen.main
        let bounds = screen?.visibleFrame ?? .infinite
        let well = SummonView.wellCenter
        var origin = CGPoint(x: anchor.x - well.x, y: anchor.y - (size.height - well.y))
        origin.x = min(max(bounds.minX + 8, origin.x), bounds.maxX - size.width - 8)
        origin.y = min(max(bounds.minY + 8, origin.y), bounds.maxY - size.height - 8)
        panel.setFrameOrigin(origin)
        live.wellOnScreen = CGPoint(x: origin.x + well.x, y: origin.y + size.height - well.y)
    }
}

/// A borderless panel that can take the keyboard without activating Moonlet,
/// so the app the user was in stays in front.
private final class SummonWindow: NSPanel {
    /// Sees each key press first; returns true when it handled the key.
    var onKey: ((NSEvent) -> Bool)?

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    override func sendEvent(_ event: NSEvent) {
        if event.type == .keyDown, onKey?(event) == true { return }
        super.sendEvent(event)
    }
}

/// An `NSHostingView` that acts on the first click, so a click on a row opens
/// the agent even before the panel has the keyboard.
final class FirstClickHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

/// The summon view: a headline, the gravity well, the Next up card and the
/// other agents, and the last hour as a timeline.
struct SummonView: View {
    struct Actions {
        var open: (String) -> Void = { _ in }
        var batch: (String, Bool) -> Void = { _, _ in }
    }

    /// The transparent margin around the visible panel.
    static let margin: CGFloat = 12
    static let padding: CGFloat = 12
    static let width: CGFloat = 480
    private static let headerHeight: CGFloat = 34
    private static let headerGap: CGFloat = 6

    /// The well's center in the view's coordinates, y down, margin included.
    static let wellCenter = CGPoint(x: margin + padding + SummonWell.size / 2,
                                    y: margin + padding + headerHeight + headerGap + SummonWell.size / 2)

    /// Kept for the demo film until it anchors on `wellCenter`; its x matches.
    @available(*, deprecated, message: "Use wellCenter")
    static let orbitSize: CGFloat = 2 * (wellCenter.x - margin - 14)

    var content: SummonContent
    var actions: Actions
    @ObservedObject var live: SummonLive

    init(content: SummonContent, actions: Actions, live: SummonLive = SummonLive()) {
        self.content = content
        self.actions = actions
        self.live = live
    }

    var body: some View {
        // Redrawn every minute so the times stay true; the schedule's own date
        // is the start of the minute, so read the clock instead.
        TimelineView(.everyMinute) { _ in
            panel(now: Date())
        }
    }

    private func panel(now: Date) -> some View {
        let ranked = content.ranked
        let next = content.nextUp
        // The Next up card shows the top agent; the rows show everyone else.
        let others = ranked.enumerated().map { (rank: $0.offset, agent: $0.element) }.dropFirst(next == nil ? 0 : 1)
        return VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 1) {
                Text(content.headline(now: now))
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(1)
                let subline = content.subline
                if !subline.isEmpty {
                    Text(subline)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            .frame(height: Self.headerHeight, alignment: .topLeading)
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.isHeader)

            HStack(alignment: .top, spacing: 10) {
                VStack(spacing: 0) {
                    SummonWell(agents: ranked, hostExpression: content.hostExpression, open: actions.open, live: live)
                    Text("closer to the middle =\nneeds you sooner")
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.top, -2)
                        .accessibilityHidden(true)
                }
                .frame(width: SummonWell.size)
                VStack(alignment: .leading, spacing: 6) {
                    SummonNextUp(agent: next, ranked: ranked, now: now, open: actions.open, live: live)
                    SummonRows(rows: Array(others), now: now, open: actions.open, live: live)
                }
                .frame(maxWidth: .infinity, alignment: .topLeading)
            }
            .padding(.top, Self.headerGap)

            SummonTimeline(events: content.events, agentCount: ranked.count, now: now)
                .padding(.top, 8)

            if let project = content.suggestion {
                Divider().padding(.vertical, 8)
                HStack(spacing: 8) {
                    Text("You usually skip \(project). Collect its updates here instead?")
                        .font(.system(size: 11.5))
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                    Button("Collect") { actions.batch(project, true) }
                        .buttonStyle(SummonButtonStyle(prominent: true))
                    Button("No") { actions.batch(project, false) }
                        .buttonStyle(SummonButtonStyle())
                }
            }
        }
        .padding(.horizontal, Self.padding)
        .padding(.top, Self.padding)
        .padding(.bottom, 10)
        .frame(width: Self.width, alignment: .leading)
        .background(Backdrop(material: .popover).clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous)))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(.separator, lineWidth: 0.5))
        .scaleEffect(live.isShown ? 1 : 0.94, anchor: UnitPoint(
            x: (Self.wellCenter.x - Self.margin) / Self.width, y: 0.4))
        .padding(Self.margin)
    }
}
