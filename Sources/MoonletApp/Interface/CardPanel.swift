import AppKit
import MoonletBrain
import QuartzCore
import SwiftUI

/// The card at the user's pointer. Click-through, never takes focus, and
/// rides along with the pointer while it shows.
@MainActor
final class CardPanel {
    /// Where cards go when they leave on their own; the menu bar moon.
    var homeLocation: (() -> CGPoint?)?
    /// How many more times a card flies home before it simply fades, so the
    /// user learns where cards go without seeing the flight forever.
    var flightsLeft = 3

    private let panel: NSPanel
    private let host: NSHostingView<CardView>
    private var displayLink: CADisplayLink?
    private var leaving = false
    private(set) var card: Card?

    init() {
        host = NSHostingView(rootView: CardView(card: nil))
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

    /// Whether `window` is the card's own click-through window.
    func owns(_ window: NSWindow?) -> Bool { window === panel }

    func show(_ card: Card) {
        self.card = card
        leaving = false
        host.rootView = CardView(card: card)
        panel.setContentSize(host.fittingSize)
        panel.alphaValue = 0
        follow()
        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.18
            panel.animator().alphaValue = 1
        }
        startFollowing()
    }

    /// Hides the card; cards that leave on their own fly to the menu bar moon the first few times.
    func hide(flyHome: Bool) {
        guard card != nil, !leaving else { return }
        leaving = true
        stopFollowing()
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

    // MARK: - Riding with the pointer

    private func startFollowing() {
        guard displayLink == nil, let screen = NSScreen.main else { return }
        let link = screen.displayLink(target: self, selector: #selector(step))
        link.add(to: .main, forMode: .common)
        displayLink = link
    }

    private func stopFollowing() {
        displayLink?.invalidate()
        displayLink = nil
    }

    @objc private func step() {
        follow()
    }

    /// Places the card below and to the right of the pointer, flipping at screen edges.
    private func follow() {
        let mouse = NSEvent.mouseLocation
        let size = panel.frame.size
        let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main
        let bounds = screen?.visibleFrame ?? .infinite
        var origin = NSPoint(x: mouse.x + 22, y: mouse.y - 30 - size.height)
        if origin.x + size.width > bounds.maxX - 8 { origin.x = mouse.x - 16 - size.width }
        if origin.y < bounds.minY + 8 { origin.y = mouse.y + 18 }
        origin.x = max(bounds.minX + 8, origin.x)
        origin.y = min(bounds.maxY - size.height - 8, origin.y)
        if panel.frame.origin != origin { panel.setFrameOrigin(origin) }
    }
}

/// A few words about one or more agents.
struct CardView: View {
    var card: Card?

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
                }
            }
            .padding(.horizontal, 11)
            .padding(.vertical, 8)
            .frame(minWidth: 170, maxWidth: 300, alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)
            .background(Backdrop().clipShape(RoundedRectangle(cornerRadius: 11, style: .continuous)))
            .overlay(RoundedRectangle(cornerRadius: 11, style: .continuous).strokeBorder(tint.opacity(0.6), lineWidth: 1))
            .padding(10)
            .accessibilityElement(children: .combine)
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
