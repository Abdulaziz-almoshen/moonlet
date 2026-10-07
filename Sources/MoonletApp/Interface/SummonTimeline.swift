import AppKit
import MoonletBrain
import SwiftUI

/// The last hour on one line, newest on the right. Time runs on a square-root
/// scale, so the last few minutes get most of the room.
struct SummonTimeline: View {
    var events: [TimelineEvent]
    /// How many agents the number keys reach, for the hint.
    var agentCount: Int
    var now: Date
    @State private var hovered: UUID?

    private static let height: CGFloat = 16
    private static let marker: CGFloat = 12

    var body: some View {
        HStack(spacing: 8) {
            Text("1 h ago")
            GeometryReader { geometry in
                let width = geometry.size.width
                ZStack(alignment: .topLeading) {
                    Rectangle()
                        .fill(Color.primary.opacity(0.2))
                        .frame(width: width, height: 0.5)
                        .offset(y: Self.height / 2)
                    ForEach(recent) { event in
                        SummonMarker(event: event)
                            .onHover { inside in
                                if inside { hovered = event.id } else if hovered == event.id { hovered = nil }
                            }
                            .accessibilityLabel("\(event.label), \(SummonTime.ago(event.at, now: now))")
                            .position(x: x(of: event, width: width), y: Self.height / 2)
                    }
                    if let event = recent.first(where: { $0.id == hovered }) {
                        tip(for: event, at: x(of: event, width: width), width: width)
                    }
                }
            }
            .frame(height: Self.height)
            .accessibilityElement(children: .contain)
            .accessibilityLabel("The last hour")
            Text("now")
            Text(hint)
                .padding(.leading, 4)
        }
        .font(.system(size: 11))
        .foregroundStyle(.tertiary)
        .lineLimit(1)
    }

    private var recent: [TimelineEvent] {
        events.filter { now.timeIntervalSince($0.at) <= 3600 }
    }

    private var hint: String {
        let reach = min(agentCount, 9)
        let keys = reach > 1 ? "1–\(reach) open · " : reach == 1 ? "1 open · " : ""
        return keys + "↵ next · esc"
    }

    /// Where an event sits: `now` at the right edge, an hour ago at the left.
    private func x(of event: TimelineEvent, width: CGFloat) -> CGFloat {
        let minutes = min(60, max(0, now.timeIntervalSince(event.at) / 60))
        let inset = Self.marker / 2
        return inset + (1 - sqrt(minutes / 60)) * (width - 2 * inset)
    }

    /// What happened, floating above the marker and leaning away from the nearer edge.
    private func tip(for event: TimelineEvent, at x: CGFloat, width: CGFloat) -> some View {
        let leading = x < width / 2
        return Color.clear
            .frame(width: 1, height: 1)
            .overlay(alignment: leading ? .bottomLeading : .bottomTrailing) {
                Text("\(event.label) · \(SummonTime.ago(event.at, now: now))")
                    .font(.system(size: 11))
                    .foregroundStyle(.primary)
                    .fixedSize()
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(.background))
                    .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(.separator, lineWidth: 0.5))
                    .offset(x: leading ? -Self.marker / 2 : Self.marker / 2)
            }
            .position(x: x, y: -2)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }
}

/// A dot on the timeline whose glyph says what happened: a check for finished
/// work, a star for a celebration, `?` for a question, `!` for a failure or a stall.
private struct SummonMarker: View {
    var event: TimelineEvent

    private enum Glyph { case check, star, ask, alert }

    private static let ink = Color(nsColor: NSColor(srgbRed: 42 / 255, green: 36 / 255, blue: 28 / 255, alpha: 1))

    var body: some View {
        let glyph = glyph
        let fill = Color(event.kind)
        Canvas { context, size in
            context.translateBy(x: size.width / 2, y: size.height / 2)
            let disc = Path(ellipseIn: CGRect(x: -5.2, y: -5.2, width: 10.4, height: 10.4))
            context.fill(disc, with: .color(fill))
            context.stroke(disc, with: .color(Self.ink), lineWidth: 0.7)
            let line = StrokeStyle(lineWidth: 1.1, lineCap: .round, lineJoin: .round)
            switch glyph {
            case .check:
                var path = Path()
                path.move(to: CGPoint(x: -2, y: 0.1))
                path.addLine(to: CGPoint(x: -0.6, y: 1.5))
                path.addLine(to: CGPoint(x: 2, y: -1.3))
                context.stroke(path, with: .color(Self.ink), style: line)
            case .star:
                var path = Path()
                let points: [(CGFloat, CGFloat)] = [(0, -2.8), (0.75, -0.75), (2.8, 0), (0.75, 0.75),
                                                    (0, 2.8), (-0.75, 0.75), (-2.8, 0), (-0.75, -0.75)]
                path.addLines(points.map { CGPoint(x: $0.0 * 1.1, y: $0.1 * 1.1) })
                path.closeSubpath()
                context.fill(path, with: .color(Self.ink))
            case .ask:
                var path = Path()
                path.move(to: CGPoint(x: -1.25, y: -1.7))
                path.addQuadCurve(to: CGPoint(x: 0, y: -3.2), control: CGPoint(x: -1.25, y: -3.2))
                path.addQuadCurve(to: CGPoint(x: 1.35, y: -1.9), control: CGPoint(x: 1.35, y: -3.2))
                path.addQuadCurve(to: CGPoint(x: 0.35, y: -0.5), control: CGPoint(x: 1.35, y: -1))
                path.addQuadCurve(to: CGPoint(x: 0, y: 0.6), control: CGPoint(x: 0, y: -0.3))
                context.stroke(path, with: .color(Self.ink), style: line)
                context.fill(Path(ellipseIn: CGRect(x: -0.6, y: 1.9, width: 1.2, height: 1.2)), with: .color(Self.ink))
            case .alert:
                var path = Path()
                path.move(to: CGPoint(x: 0, y: -2.6))
                path.addLine(to: CGPoint(x: 0, y: 0.3))
                context.stroke(path, with: .color(Self.ink), style: line)
                context.fill(Path(ellipseIn: CGRect(x: -0.65, y: 1.5, width: 1.3, height: 1.3)), with: .color(Self.ink))
            }
        }
        .frame(width: 12, height: 12)
        .contentShape(Circle())
    }

    private var glyph: Glyph {
        switch event.kind {
        case .finished: event.mood == .celebrate ? .star : .check
        case .needsYou, .question: .ask
        case .failed, .stuck: .alert
        }
    }
}
