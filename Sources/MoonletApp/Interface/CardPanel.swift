import AppKit
import MoonletBrain
import QuartzCore
import SwiftUI

/// The card at the user's pointer. It never takes focus. The companion's
/// director places it: beside the companion while it rides with the pointer,
/// or parked in place for a request. A parked card takes clicks only while the
/// pointer rests on it; otherwise its window is click-through.
@MainActor
final class CardPanel {
    /// Where cards go when they leave on their own; the menu bar moon.
    var homeLocation: (() -> CGPoint?)?
    /// How many more times a card flies home before it simply fades, so the
    /// user learns where cards go without seeing the flight forever.
    var flightsLeft = 3

    /// Called when the user clicks a parked card.
    var onClick: (() -> Void)?
    /// Whether the card is parked for a request: it says what a click does, and
    /// takes clicks while the pointer rests on it.
    private(set) var isParked = false
    /// Whether the card's window takes mouse events right now.
    private(set) var takesInput = false
    /// When the card last went click-through, in seconds since startup, the
    /// clock of `NSEvent.timestamp`.
    private(set) var clickThroughSince: TimeInterval = 0

    private let panel: NSPanel
    private let host: FirstClickHostingView<CardView>
    private var leaving = false
    private var hint: String?
    private(set) var card: Card?

    init() {
        host = FirstClickHostingView(rootView: CardView(card: nil))
        panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 300, height: 60),
                        styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.isReleasedWhenClosed = false
        panel.contentView = host
    }

    /// Whether `window` is the card's own window.
    func owns(_ window: NSWindow?) -> Bool { window === panel }

    /// The card's window frame in screen coordinates, including its transparent margin.
    var frame: CGRect { panel.frame }
    /// The card's window size, including its transparent margin.
    var size: CGSize { panel.frame.size }

    /// Shows `card`, click-through, with its window at the origin `place` gives
    /// for the card's size, in screen coordinates.
    func show(_ card: Card, placedBy place: (CGSize) -> CGPoint) {
        self.card = card
        leaving = false
        isParked = false
        hint = nil
        setTakesInput(false)
        render()
        panel.setFrameOrigin(clamped(place(panel.frame.size), size: panel.frame.size))
        panel.alphaValue = 0
        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.18
            panel.animator().alphaValue = 1
        }
    }

    /// Moves the card's window to `origin` while it shows, kept inside the
    /// visible frame of its screen.
    func move(to origin: CGPoint) {
        guard card != nil, !leaving else { return }
        let origin = clamped(origin, size: panel.frame.size)
        if panel.frame.origin != origin { panel.setFrameOrigin(origin) }
    }

    /// Parks the card with a line saying what a click does, or lets it ride
    /// again, click-through. Parking alone doesn't take clicks; `setTakesInput` does.
    func setParked(_ parked: Bool, hint: String? = nil) {
        let hint = parked ? hint : nil
        guard parked != isParked || hint != self.hint else { return }
        isParked = parked
        self.hint = hint
        if !parked { setTakesInput(false) }
        if card != nil, !leaving { render() }
    }

    /// Lets a parked card's window take clicks, or makes it click-through.
    func setTakesInput(_ takes: Bool) {
        let takes = takes && isParked && card != nil && !leaving
        guard takes != takesInput else { return }
        takesInput = takes
        panel.ignoresMouseEvents = !takes
        if !takes { clickThroughSince = ProcessInfo.processInfo.systemUptime }
    }

    /// Whether an event that landed on the card at `timestamp` was made while it took input.
    func tookInput(at timestamp: TimeInterval) -> Bool {
        CompanionStage.cardTookEvent(at: timestamp, takesInputNow: takesInput, clickThroughSince: clickThroughSince)
    }

    private func render() {
        let action: (() -> Void)? = isParked ? { [weak self] in self?.onClick?() } : nil
        host.rootView = CardView(card: card, hint: hint, action: action)
        let size = host.fittingSize
        let top = panel.frame.maxY
        panel.setContentSize(size)
        if card != nil { panel.setFrameOrigin(CGPoint(x: panel.frame.minX, y: top - size.height)) }
    }

    /// `origin` kept inside the visible frame of the screen the card is on, so
    /// it never covers the menu bar or crosses onto another display.
    private func clamped(_ origin: CGPoint, size: CGSize) -> CGPoint {
        let center = CGPoint(x: origin.x + size.width / 2, y: origin.y + size.height / 2)
        let mouse = NSEvent.mouseLocation
        guard let screen = NSScreen.screens.first(where: { $0.frame.contains(center) })
            ?? NSScreen.screens.first(where: { NSMouseInRect(mouse, $0.frame, false) }) else { return origin }
        return CompanionStage.clamp(origin, size: size, into: screen.visibleFrame)
    }

    /// Hides the card; cards that leave on their own fly to the menu bar moon the first few times.
    func hide(flyHome: Bool) {
        guard card != nil, !leaving else { return }
        setTakesInput(false)
        leaving = true
        isParked = false
        hint = nil
        let start = panel.frame
        let target = flyHome && flightsLeft > 0 ? homeLocation?() : nil
        if target != nil { flightsLeft -= 1 }
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = target == nil ? 0.16 : 0.45
            context.timingFunction = CAMediaTimingFunction(name: .easeIn)
            if let target {
                panel.animator().setFrame(NSRect(x: target.x - 12, y: target.y - 4, width: 24, height: 8), display: true)
            }
            panel.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.leaving else { return }
                self.panel.orderOut(nil)
                self.panel.setFrame(start, display: false)
                self.card = nil
                self.leaving = false
            }
        })
    }
}

/// A few words about one or more agents.
struct CardView: View {
    var card: Card?
    /// What a click does, shown under the details while the card is parked.
    var hint: String?
    var action: (() -> Void)?

    var body: some View {
        if let card {
            let tint = Color(card.tone)
            HStack(alignment: .top, spacing: 8) {
                Circle().fill(tint).frame(width: 8, height: 8).padding(.top, 5)
                VStack(alignment: .leading, spacing: 1) {
                    Text(card.title)
                        .font(.system(size: 12.5, weight: .semibold))
                        .lineLimit(1)
                    if !card.detail.isEmpty {
                        Text(card.detail)
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                    if let hint {
                        Text(hint + " ↗")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(tint)
                            .padding(.top, 2)
                    }
                }
            }
            .padding(.horizontal, 11)
            .padding(.vertical, 8)
            .frame(minWidth: 170, maxWidth: 300, alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)
            .background(Backdrop().clipShape(RoundedRectangle(cornerRadius: 11, style: .continuous)))
            .overlay(RoundedRectangle(cornerRadius: 11, style: .continuous).strokeBorder(tint.opacity(0.6), lineWidth: 1))
            // Only the visible card takes a click, never its transparent margin.
            .contentShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
            .onTapGesture { action?() }
            .padding(10)
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(action == nil ? [] : .isButton)
        }
    }
}

/// Native translucent background that stays vivid in a window that never becomes key.
/// Snapshots (which can't capture AppKit views) get a plain window background instead.
struct Backdrop: View {
    var material: NSVisualEffectView.Material = .popover
    @Environment(\.isSnapshot) private var isSnapshot

    var body: some View {
        if isSnapshot {
            Color(nsColor: .windowBackgroundColor)
        } else {
            VisualEffect(material: material)
        }
    }
}

extension EnvironmentValues {
    /// True while rendering a still image for documentation.
    @Entry var isSnapshot = false
}

struct VisualEffect: NSViewRepresentable {
    var material: NSVisualEffectView.Material = .popover

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = material
        view.state = .active
        view.blendingMode = .behindWindow
        return view
    }

    func updateNSView(_ view: NSVisualEffectView, context: Context) {
        view.material = material
    }
}
