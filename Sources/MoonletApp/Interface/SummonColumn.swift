import AppKit
import MoonletBrain
import SwiftUI

/// The agent that needs the user first, with what it said and the way to it.
/// Moonlet can't answer for the user, so a question's options show as tags
/// and the action brings the agent's tab forward.
struct SummonNextUp: View {
    var agent: AgentRow?
    var ranked: [AgentRow]
    var now: Date
    var open: (String) -> Void
    @ObservedObject var live: SummonLive

    /// Text on the yellow and red buttons.
    private static let ink = Color(nsColor: NSColor(srgbRed: 42 / 255, green: 36 / 255, blue: 28 / 255, alpha: 1))

    var body: some View {
        if let agent {
            pending(agent)
        } else {
            quiet
        }
    }

    private func pending(_ agent: AgentRow) -> some View {
        let tint = Color(agent.activity)
        return VStack(alignment: .leading, spacing: 2) {
            Text("Next up · \(agent.when(now: now))")
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
            Text(title(agent))
                .font(.system(size: 12.5, weight: .semibold))
                .lineLimit(1)
            if !agent.detail.isEmpty {
                Text(agent.detail)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if !agent.options.isEmpty {
                SummonTags(options: agent.options)
                    .padding(.top, 4)
            }
            Button { open(agent.id) } label: {
                HStack(spacing: 5) {
                    Text("Open in \(agent.place)")
                    if live.takesKeys { Text("↵").opacity(0.55) }
                }
            }
            .buttonStyle(SummonButtonStyle(prominent: true, tint: tint,
                                           ink: agent.activity == .failed ? .white : Self.ink))
            .padding(.top, 6)
            .accessibilityLabel("Open \(agent.label) in \(agent.place)")
        }
        .padding(.horizontal, 10)
        .padding(.top, 7)
        .padding(.bottom, 9)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 11, style: .continuous).fill(tint.opacity(0.07)))
        .overlay(RoundedRectangle(cornerRadius: 11, style: .continuous).strokeBorder(tint, lineWidth: 1))
        .onHover { live.hoverRow(agent.id, inside: $0) }
        .accessibilityElement(children: .contain)
    }

    private var quiet: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("Next up")
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
            Text("Nothing needs you")
                .font(.system(size: 12.5, weight: .semibold))
            Text(soonest)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(RoundedRectangle(cornerRadius: 11, style: .continuous).strokeBorder(.separator, lineWidth: 1))
        .accessibilityElement(children: .combine)
    }

    private func title(_ agent: AgentRow) -> String {
        switch agent.activity {
        case .failed: "\(agent.label) failed"
        default: agent.asks ? "\(agent.label) asks" : "\(agent.label) needs you"
        }
    }

    /// Which agent finishes first, when nothing needs the user.
    private var soonest: String {
        let working = ranked.filter { $0.activity == .working }
        if let first = working.first(where: { $0.etaMinutes != nil }), let eta = first.etaMinutes {
            return "\(first.label) finishes in ~\(eta) min"
        }
        if working.count == 1 { return "\(working[0].label) is still working" }
        if working.count > 1 { return "\(working.count) agents are still working" }
        return ranked.isEmpty ? "No agents are running" : "Every agent is done"
    }
}

/// The other agents, one line each, with the number key that opens them when
/// the panel has the keyboard.
struct SummonRows: View {
    /// Each agent with its rank in the whole list, which sets its number key.
    var rows: [(rank: Int, agent: AgentRow)]
    var now: Date
    var open: (String) -> Void
    @ObservedObject var live: SummonLive

    static let rowHeight: CGFloat = 22
    /// Rows beyond this scroll.
    static let visibleRows = 8

    var body: some View {
        if rows.count > Self.visibleRows {
            ScrollView { list }
                .frame(height: Self.rowHeight * CGFloat(Self.visibleRows))
        } else {
            list
        }
    }

    private var list: some View {
        VStack(spacing: 0) {
            ForEach(rows, id: \.agent.id) { row in
                SummonRow(rank: row.rank, agent: row.agent, now: now, open: open, live: live)
            }
        }
    }
}

private struct SummonRow: View {
    var rank: Int
    var agent: AgentRow
    var now: Date
    var open: (String) -> Void
    @ObservedObject var live: SummonLive

    var body: some View {
        let highlighted = live.hovered == agent.id
        Button { open(agent.id) } label: {
            HStack(spacing: 6) {
                if live.takesKeys {
                    Text(rank < 9 ? "\(rank + 1)" : "")
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.tertiary)
                        .frame(width: 9)
                }
                Text(agent.label)
                    .font(.system(size: 12, weight: .semibold))
                    .lineLimit(1)
                    .layoutPriority(1)
                Text(agent.activity == .working ? agent.status : agent.detail)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Text(agent.when(now: now))
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .fixedSize()
                if agent.isNew {
                    Circle()
                        .fill(Color(nsColor: Palette.info))
                        .frame(width: 6, height: 6)
                }
            }
            .padding(.horizontal, 5)
            .frame(height: SummonRows.rowHeight)
            .background(RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(Color.primary.opacity(highlighted ? 0.07 : 0)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { live.hoverRow(agent.id, inside: $0) }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityText)
        .accessibilityHint("Opens in \(agent.place)")
        .accessibilityAddTraits(.isButton)
    }

    private var accessibilityText: String {
        var parts = [agent.label, agent.activity == .working ? agent.status : agent.detail, agent.when(now: now)]
        if agent.isNew { parts.append("new") }
        return parts.filter { !$0.isEmpty }.joined(separator: ", ")
    }
}

/// A question's options, as quiet tags that wrap onto more lines when needed.
struct SummonTags: View {
    var options: [String]

    var body: some View {
        SummonFlow(spacing: 5) {
            ForEach(Array(options.enumerated()), id: \.offset) { _, option in
                Text(option)
                    .font(.system(size: 11))
                    .lineLimit(1)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(Color.primary.opacity(0.05)))
                    .overlay(Capsule().strokeBorder(Color.primary.opacity(0.2), lineWidth: 0.5))
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Options: " + options.joined(separator: ", "))
    }
}

/// Lays its views out left to right, wrapping onto a new line when one is full.
private struct SummonFlow: Layout {
    var spacing: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        let frames = arrange(subviews, width: width)
        let used = frames.map(\.maxX).max() ?? 0
        return CGSize(width: proposal.width.map { _ in min(width, used) } ?? used, height: frames.map(\.maxY).max() ?? 0)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        for (frame, subview) in zip(arrange(subviews, width: bounds.width), subviews) {
            subview.place(at: CGPoint(x: bounds.minX + frame.minX, y: bounds.minY + frame.minY), proposal: ProposedViewSize(frame.size))
        }
    }

    private func arrange(_ subviews: Subviews, width: CGFloat) -> [CGRect] {
        var frames: [CGRect] = []
        var x: CGFloat = 0, y: CGFloat = 0, lineHeight: CGFloat = 0
        for subview in subviews {
            var size = subview.sizeThatFits(.unspecified)
            size.width = min(size.width, width)
            if x > 0, x + size.width > width {
                x = 0
                y += lineHeight + spacing
                lineHeight = 0
            }
            frames.append(CGRect(origin: CGPoint(x: x, y: y), size: size))
            x += size.width + spacing
            lineHeight = max(lineHeight, size.height)
        }
        return frames
    }
}

/// A small, flat button that draws the same on screen and in still images.
struct SummonButtonStyle: ButtonStyle {
    var prominent = false
    var tint: Color = .accentColor
    var ink: Color = .white

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: prominent ? .semibold : .regular))
            .foregroundStyle(prominent ? ink : .primary)
            .padding(.horizontal, 10)
            .padding(.vertical, 3)
            .background(RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(prominent ? tint : Color.primary.opacity(0.08)))
            .opacity(configuration.isPressed ? 0.75 : 1)
            .contentShape(Rectangle())
    }
}
