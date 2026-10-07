import AppKit
import MoonletBrain
import SwiftUI

/// Every session at a glance, opened by a small circle, the shortcut, or the menu.
/// Unlike cards, this panel is clickable: open an agent, or click anywhere else to close.
@MainActor
final class SummonPanel {
    var onOpen: ((String) -> Void)?
    var onBatch: ((String, Bool) -> Void)?
    private(set) var isOpen = false
    private var anchor = CGPoint.zero
    private let panel: NSPanel
    private let host: FirstClickHostingView<SummonView>

    init() {
        host = FirstClickHostingView(rootView: SummonView(content: SummonContent(), actions: .init()))
        panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 420, height: 200),
                        styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = .popUpMenu
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        panel.isReleasedWhenClosed = false
        panel.contentView = host
    }

    /// Opens the view with its orbit centered on `point`, in screen coordinates.
    func open(at point: CGPoint, content: SummonContent) {
        anchor = point
        update(content)
        isOpen = true
        panel.alphaValue = 0
        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.2
            panel.animator().alphaValue = 1
        }
    }

    func update(_ content: SummonContent) {
        let actions = SummonView.Actions(
            open: { [weak self] id in self?.onOpen?(id) },
            batch: { [weak self] project, accept in self?.onBatch?(project, accept) })
        host.rootView = SummonView(content: content, actions: actions)
        let size = host.fittingSize
        panel.setContentSize(size)
        place(size)
    }

    func close() {
        guard isOpen else { return }
        isOpen = false
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.15
            panel.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            MainActor.assumeIsolated {
                guard let self, !self.isOpen else { return }
                self.panel.orderOut(nil)
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

    /// Puts the orbit's center on the anchor, keeping the panel on screen.
    private func place(_ size: CGSize) {
        let screen = NSScreen.screens.first { NSMouseInRect(anchor, $0.frame, false) } ?? NSScreen.main
        let bounds = screen?.visibleFrame ?? .infinite
        let orbitCenter = CGPoint(x: SummonView.orbitSize / 2 + 14, y: size.height - SummonView.orbitSize / 2 - 14)
        var origin = CGPoint(x: anchor.x - orbitCenter.x, y: anchor.y - orbitCenter.y)
        origin.x = min(max(bounds.minX + 8, origin.x), bounds.maxX - size.width - 8)
        origin.y = min(max(bounds.minY + 8, origin.y), bounds.maxY - size.height - 8)
        panel.setFrameOrigin(origin)
    }
}

/// An `NSHostingView` that acts on the first click, so rows work in a panel
/// that never becomes key.
final class FirstClickHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

struct SummonView: View {
    struct Actions {
        var open: (String) -> Void = { _ in }
        var batch: (String, Bool) -> Void = { _, _ in }
    }

    static let orbitSize: CGFloat = 92
    var content: SummonContent
    var actions: Actions

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Orbit(agents: content.agents)
                .frame(width: Self.orbitSize, height: Self.orbitSize)
            VStack(alignment: .leading, spacing: 2) {
                Text(headline)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 6)
                    .padding(.bottom, 2)
                if content.agents.isEmpty {
                    Text("No agents right now")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .padding(6)
                }
                ForEach(content.agents) { agent in
                    Button { actions.open(agent.id) } label: { AgentRowView(agent: agent) }
                        .buttonStyle(RowButtonStyle())
                        .help("Open \(agent.label) in \(agent.place)")
                }
                if !content.earlier.isEmpty {
                    Divider().padding(.vertical, 4)
                    Text("Earlier")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 6)
                    ForEach(content.earlier.prefix(3)) { moment in
                        Text("\(moment.agentLabel) · \(moment.detail)")
                            .font(.system(size: 11.5))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .padding(.horizontal, 6)
                    }
                }
                if let project = content.suggestion {
                    Divider().padding(.vertical, 4)
                    HStack(spacing: 6) {
                        Text("You usually skip \(project). Collect its updates here instead?")
                            .font(.system(size: 11.5))
                            .fixedSize(horizontal: false, vertical: true)
                        Button("Collect") { actions.batch(project, true) }
                        Button("No") { actions.batch(project, false) }
                    }
                    .controlSize(.small)
                    .padding(.horizontal, 6)
                }
            }
            .frame(width: 290, alignment: .leading)
        }
        .padding(14)
        .background(Backdrop(material: .popover).clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous)))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(.separator, lineWidth: 0.5))
        .padding(12)
    }

    private var headline: String {
        let counts: [(AgentActivity, String)] = [(.waiting, "need you"), (.working, "working"), (.failed, "failed"), (.done, "done")]
        let parts = counts.compactMap { activity, word -> String? in
            let n = content.agents.filter { $0.activity == activity }.count
            return n > 0 ? "\(n) \(activity == .waiting && n == 1 ? "needs you" : word)" : nil
        }
        return parts.isEmpty ? "Moonlet" : parts.joined(separator: " · ")
    }
}

/// The agents as moons circling the spot where the user summoned them.
private struct Orbit: View {
    var agents: [AgentRow]

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 30)) { timeline in
            let t = timeline.date.timeIntervalSinceReferenceDate
            GeometryReader { geometry in
                let center = CGPoint(x: geometry.size.width / 2, y: geometry.size.height / 2)
                let radius = min(geometry.size.width, geometry.size.height) / 2 - 10
                ZStack {
                    Circle()
                        .strokeBorder(.separator, lineWidth: 1)
                        .frame(width: radius * 2, height: radius * 2)
                        .position(center)
                    ForEach(Array(agents.prefix(12).enumerated()), id: \.element.id) { index, agent in
                        let angle = -Double.pi / 2 + Double(index) * 2 * .pi / Double(max(agents.prefix(12).count, 1)) + t / 6
                        Moon(activity: agent.activity, phase: Moon.phase(for: agent.activity, progress: agent.progress), size: 12)
                            .position(x: center.x + radius * cos(angle), y: center.y + radius * sin(angle))
                    }
                }
            }
        }
    }
}

private struct AgentRowView: View {
    var agent: AgentRow

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Moon(activity: agent.activity, phase: Moon.phase(for: agent.activity, progress: agent.progress), size: 11)
                .padding(.top, 2)
            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    Text(agent.label).font(.system(size: 12.5, weight: .semibold)).lineLimit(1)
                    Spacer(minLength: 6)
                    Text(agent.place).font(.system(size: 11)).foregroundStyle(.tertiary).lineLimit(1)
                }
                Text(statusLine)
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .contentShape(Rectangle())
    }

    private var statusLine: String {
        var parts = [label(agent.activity)]
        if agent.activity == .working, let progress = agent.progress { parts.append("\(Int((progress * 100).rounded()))%") }
        if !agent.status.isEmpty { parts.append(agent.status) }
        parts.append(Self.elapsed(since: agent.since))
        return parts.joined(separator: " · ")
    }

    private func label(_ activity: AgentActivity) -> String {
        switch activity {
        case .working: "Working"
        case .waiting: "Needs you"
        case .done: "Done"
        case .failed: "Failed"
        case .idle: "Idle"
        }
    }

    static func elapsed(since date: Date) -> String {
        let seconds = max(0, Int(Date().timeIntervalSince(date)))
        if seconds < 60 { return "now" }
        if seconds < 3600 { return "\(seconds / 60) min" }
        return "\(seconds / 3600) h"
    }
}

private struct RowButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        RowBackground(configuration: configuration)
    }

    private struct RowBackground: View {
        let configuration: ButtonStyle.Configuration
        @State private var hovering = false

        var body: some View {
            configuration.label
                .padding(.horizontal, 6)
                .padding(.vertical, 4)
                .background(RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(Color.primary.opacity(configuration.isPressed ? 0.12 : hovering ? 0.07 : 0)))
                .onHover { hovering = $0 }
        }
    }
}
