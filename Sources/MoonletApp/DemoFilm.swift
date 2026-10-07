import AppKit
import MoonletBrain
import SwiftUI

/// Renders Moonlet's demo film, frame by frame, from the app's own interface
/// code (cards, summon view, pointer artwork):
///
///     swift run MoonletApp --render-film /tmp/moonlet-frames
///
/// `scripts/make-demo.sh` encodes the frames as MP4 and GIF. The film shows the
/// pain first (agents finish or wait unnoticed), then how Moonlet's companion
/// brings each piece of news to the pointer, in the mood of what was said.
@MainActor
enum DemoFilm {
    static let size = CGSize(width: 1280, height: 800)
    static let scale: CGFloat = 1.5
    static let fps = 30
    static let duration: Double = 26
    /// Moonlet's pointer and cards are drawn larger than life so they read in a small GIF.
    static let zoom: CGFloat = 1.6
    /// The film's pointer is 42 points across before zoom, about 2.2 times a real one,
    /// so the companion's size and its distances from the pointer scale by the same.
    static let companionZoom: CGFloat = 2.2

    // MARK: - Rendering

    static func render(to directory: URL) {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let assets = Assets()
        let frames = Int(duration * Double(fps))
        for frame in 0..<frames {
            let t = Double(frame) / Double(fps)
            guard let image = draw(at: t, assets: assets),
                  let data = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else { continue }
            try? data.write(to: directory.appendingPathComponent(String(format: "frame%04d.png", frame)))
        }
        print("Rendered \(frames) frames to \(directory.path)")
    }

    private static func draw(at t: Double, assets: Assets) -> CGImage? {
        let pixels = CGSize(width: size.width * scale, height: size.height * scale)
        guard let context = CGContext(data: nil, width: Int(pixels.width), height: Int(pixels.height), bitsPerComponent: 8,
                                      bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.scaleBy(x: scale, y: scale)
        context.translateBy(x: 0, y: size.height)
        context.scaleBy(x: 1, y: -1)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: true)
        defer { NSGraphicsContext.restoreGraphicsState() }

        if t >= Timeline.endCard {
            drawEndCard(t: t, assets: assets)
        } else {
            drawDesktop(t: t, assets: assets)
            let fade = 1 - min(max((t - (Timeline.endCard - 0.6)) / 0.6, 0), 1)
            if fade < 1 {
                NSColor.black.withAlphaComponent(1 - fade).setFill()
                CGRect(origin: .zero, size: size).fill()
            }
        }
        return context.makeImage()
    }

    // MARK: - Timeline

    private enum Timeline {
        static let moonlet = 8.2
        static let ask = 9.6
        static let park = 10.3
        /// The user types "y" in the landing-page terminal, which is in front.
        static let typed = 10.9
        /// The agent gets its answer while its card shows, so the companion thanks.
        static let answered = 11.4
        static let tell = 12.9
        static let tellEnd = 15.6
        static let warn = 16.0
        static let warnEnd = 18.6
        static let circle = 18.9
        static let summon = 19.8
        static let endCard = 23.0
    }

    /// The pointer's path: (time, position) keyframes, eased between.
    private static let path: [(Double, CGPoint)] = [
        (0.0, CGPoint(x: 640, y: 430)), (1.4, CGPoint(x: 360, y: 205)), (2.8, CGPoint(x: 330, y: 245)),
        (4.4, CGPoint(x: 930, y: 215)), (5.8, CGPoint(x: 380, y: 560)), (7.0, CGPoint(x: 960, y: 560)),
        (8.2, CGPoint(x: 640, y: 440)), (9.6, CGPoint(x: 560, y: 410)), (10.6, CGPoint(x: 548, y: 404)),
        (11.8, CGPoint(x: 548, y: 404)), (12.9, CGPoint(x: 560, y: 350)), (15.6, CGPoint(x: 572, y: 356)),
        (16.0, CGPoint(x: 600, y: 380)), (18.6, CGPoint(x: 590, y: 386)), (18.9, CGPoint(x: 598, y: 380)),
    ]

    private static let circleCenter = CGPoint(x: 560, y: 380)
    private static let circleRadius: CGFloat = 38

    private static func pointer(at t: Double) -> CGPoint {
        if t >= Timeline.circle, t < Timeline.summon {
            let progress = (t - Timeline.circle) / (Timeline.summon - Timeline.circle)
            let angle = progress * 2 * .pi
            return CGPoint(x: circleCenter.x + circleRadius * cos(angle), y: circleCenter.y + circleRadius * sin(angle))
        }
        if t >= Timeline.summon { return CGPoint(x: circleCenter.x + circleRadius, y: circleCenter.y) }
        guard let next = path.firstIndex(where: { $0.0 > t }) else { return path.last!.1 }
        guard next > 0 else { return path[0].1 }
        let (t0, p0) = path[next - 1]
        let (t1, p1) = path[next]
        let x = min(max((t - t0) / (t1 - t0), 0), 1)
        let eased = x < 0.5 ? 4 * x * x * x : 1 - pow(-2 * x + 2, 3) / 2
        return CGPoint(x: p0.x + (p1.x - p0.x) * eased, y: p0.y + (p1.y - p0.y) * eased)
    }

    /// Who is talking at time `t`: the card at the pointer, and its tint. The
    /// request card gets its "Open in Terminal" line once it parks.
    private static func talk(at t: Double) -> (card: String?, tint: PointerTint) {
        if t >= Timeline.ask, t < Timeline.answered { return (t < Timeline.park ? "ask" : "parked", .needsYou) }
        if t >= Timeline.tell, t < Timeline.tellEnd - 0.5 { return ("tell", .info) }
        if t >= Timeline.warn, t < Timeline.warnEnd - 0.5 { return ("warn", .problem) }
        return (nil, .system)
    }

    private static let captions: [(Double, Double, String)] = [
        (0.3, 3.4, "Five agents are working for you."),
        (3.6, 6.4, "One finished 10 minutes ago. One has waited 18 minutes for a yes."),
        (6.6, 8.0, "You only find out when you go looking."),
        (8.3, 9.5, "Moonlet: a tiny companion brings their news to your pointer."),
        (9.6, 11.3, "Asks you something? It holds up a sign."),
        (11.4, 12.8, "Answer it, and it thanks you."),
        (12.9, 15.6, "Shipped? It celebrates."),
        (16.0, 18.6, "Something failed? It's sad with you."),
        (18.9, 22.7, "Draw a small circle to see every agent."),
    ]

    // MARK: - The companion

    /// Where the companion sits at `t`: just below and right of the pointer, a
    /// beat behind it; on the parked card's corner while the request card shows,
    /// and back with the pointer once the card goes.
    private static func companionCenter(at t: Double) -> CGPoint {
        func riding(_ time: Double) -> CGPoint {
            let lagged = pointer(at: max(0, time - 0.1))
            return CGPoint(x: lagged.x + CompanionDirector.pointerOffset.dx * companionZoom, y: lagged.y + CompanionDirector.pointerOffset.dy * companionZoom)
        }
        if t >= Timeline.park, t < Timeline.answered { return riding(Timeline.park) }
        if t >= Timeline.answered, t < Timeline.answered + 0.3 {
            let from = riding(Timeline.park), to = riding(t), p = Ease.inOut((t - Timeline.answered) / 0.3)
            return CGPoint(x: from.x + (to.x - from.x) * p, y: from.y + (to.y - from.y) * p)
        }
        return riding(t)
    }

    /// Where the card's image goes for a companion at `point`: its visible box
    /// starts right of the companion and a little above it, as in the app. The
    /// image has a transparent margin of 10 points, drawn at the card's zoom.
    private static func cardOrigin(companion point: CGPoint) -> CGPoint {
        CGPoint(x: point.x + 22 * companionZoom - 10 * zoom, y: point.y - 20 * companionZoom - 10 * zoom)
    }

    /// The companion's look at `t`, scripted like the app's director plays it:
    /// an entrance, a few moves, and a goodbye.
    private static func companionPose(at t: Double) -> (pose: CompanionPose, grow: CGFloat, alpha: CGFloat)? {
        let pi = Double.pi
        var pose = CompanionPose()
        let at = pointer(at: t), center = companionCenter(at: t)
        let dx = at.x - center.x, dy = at.y - center.y, d = max(1, hypot(dx, dy))
        pose.look = CGVector(dx: dx / d, dy: dy / d)
        pose.lid = (t.truncatingRemainder(dividingBy: 3.1) < 0.12) ? 0.12 : 1
        func scene(_ start: Double, _ end: Double) -> (local: Double, grow: CGFloat, alpha: CGFloat) {
            let local = t - start
            let grow = CGFloat(Ease.backOut(local / 0.45))
            let fade = CGFloat(max(0, min(1, (end - t) / 0.3)))
            return (local, local < 0.45 ? grow : fade, min(1, CGFloat(local / 0.25)) * fade)
        }
        if t >= Timeline.ask, t < Timeline.tell {
            let (local, grow, alpha) = scene(Timeline.ask, Timeline.tell)
            pose.expression = .asking
            pose.props = [CompanionProp(kind: .sign("?"), progress: local * 0.25)]
            if local < 0.9 { pose.armRight = -150 * CGFloat(sin(min(1, local / 0.9 * 1.4) * pi / 2)) }
            // Answered in the terminal while the card showed, within 6 s: heart eyes
            // and a heart, then a wave goodbye.
            if t >= Timeline.answered {
                let thanks = t - Timeline.answered
                if thanks < 1 {
                    pose.expression = .smitten
                    pose.props = [CompanionProp(kind: .heart, progress: thanks)]
                    pose.offset.y -= CGFloat(sin(min(1, thanks / 0.6) * pi) * 5)
                } else {
                    pose.expression = .delighted
                    pose.props = []
                    pose.armRight = -125 + CGFloat(sin(thanks * 30) * 30)
                }
            }
            return (pose, grow, alpha)
        }
        if t >= Timeline.tell, t < Timeline.tellEnd {
            let (local, grow, alpha) = scene(Timeline.tell, Timeline.tellEnd)
            pose.expression = .starry
            pose.props = [CompanionProp(kind: .hat, progress: 0)]
            if local < 1.3 {
                let p = local / 1.3
                pose.rotation = CGFloat(Ease.inOut(p) * 360)
                pose.offset.y -= CGFloat(sin(p * pi) * 7)
                pose.props.append(CompanionProp(kind: .confetti, progress: p))
            } else if local < 2.0 {
                let p = (local - 1.3) / 0.7
                pose.expression = .delighted
                pose.offset.y -= CGFloat(sin(p * pi) * 5)
            } else {
                pose.expression = .delighted
                pose.armRight = -125 + CGFloat(sin(local * 30) * 30)
            }
            return (pose, grow, alpha)
        }
        if t >= Timeline.warn, t < Timeline.warnEnd {
            let (local, grow, alpha) = scene(Timeline.warn, Timeline.warnEnd)
            pose.expression = .teary
            pose.props = [CompanionProp(kind: .tear, progress: (local * 0.55).truncatingRemainder(dividingBy: 1)),
                          CompanionProp(kind: .cloud, progress: (local * 0.25).truncatingRemainder(dividingBy: 1))]
            pose.offset.y += CGFloat(min(1, local * 2) * 1.6)
            pose.squash = 1 - CGFloat(sin(local * pi * 2) * 0.03)
            return (pose, grow, alpha)
        }
        return nil
    }

    private static func drawCompanion(at t: Double) {
        guard let (pose, grow, alpha) = companionPose(at: t), alpha > 0.01,
              let context = NSGraphicsContext.current?.cgContext else { return }
        context.saveGState()
        context.setAlpha(alpha)
        CompanionArt.draw(pose, in: context, center: companionCenter(at: t), scale: CompanionDirector.scale * companionZoom * max(0.01, grow), flipped: true)
        context.restoreGState()
    }

    // MARK: - Desktop

    private static func drawDesktop(t: Double, assets: Assets) {
        let context = NSGraphicsContext.current!.cgContext
        let sky = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB),
                             colors: [CGColor(srgbRed: 0.10, green: 0.13, blue: 0.24, alpha: 1),
                                      CGColor(srgbRed: 0.04, green: 0.05, blue: 0.10, alpha: 1)] as CFArray, locations: [0, 1])!
        context.drawLinearGradient(sky, start: .zero, end: CGPoint(x: 0, y: size.height), options: [])

        let moonletOn = t >= Timeline.moonlet
        drawMenuBar(t: t, showMoon: moonletOn)
        let windows = terminals(at: t)
        for window in windows { drawTerminal(window, dim: moonletOn && !window.focused) }

        // The pain: news that sits unnoticed.
        if t >= 3.6, t < Timeline.moonlet {
            let pulse = 0.55 + 0.45 * sin(t * 5)
            badge("Finished 10 min ago", color: Palette.info, at: CGPoint(x: windows[0].frame.maxX - 16, y: windows[0].frame.minY + 44))
            badge("Waiting 18 min for you", color: Palette.needsYou, at: CGPoint(x: windows[1].frame.maxX - 16, y: windows[1].frame.minY + 44))
            let outline = NSBezierPath(roundedRect: windows[1].frame.insetBy(dx: -3, dy: -3), xRadius: 14, yRadius: 14)
            outline.lineWidth = 3
            Palette.needsYou.withAlphaComponent(pulse).setStroke()
            outline.stroke()
        }
        if t >= 6.4, t < 8.2 { drawNotificationBanner(t: t) }

        // Moonlet: the pointer speaks.
        let at = pointer(at: t)
        if t >= Timeline.summon, t < Timeline.endCard, let summon = assets.summon {
            let alpha = min((t - Timeline.summon) / 0.25, 1)
            let summonZoom: CGFloat = 1.35
            let origin = CGPoint(x: circleCenter.x - assets.summonAnchor.x * summonZoom, y: circleCenter.y - assets.summonAnchor.y * summonZoom)
            drawImage(summon, at: origin, size: CGSize(width: assets.summonSize.width * summonZoom, height: assets.summonSize.height * summonZoom), alpha: alpha)
        }
        if t >= Timeline.circle, t < Timeline.summon {
            let ring = NSBezierPath(ovalIn: CGRect(x: circleCenter.x - circleRadius, y: circleCenter.y - circleRadius,
                                                   width: circleRadius * 2, height: circleRadius * 2))
            NSColor.white.withAlphaComponent(0.18).setStroke()
            ring.lineWidth = 1.5
            ring.stroke()
        }
        let talk = talk(at: t)
        if let key = talk.card, let card = assets.cards[key] {
            let start: Double = key == "ask" || key == "parked" ? Timeline.ask : key == "tell" ? Timeline.tell : Timeline.warn
            let alpha = min((t - start) / 0.18, 1)
            drawImage(card.image, at: cardOrigin(companion: companionCenter(at: t)),
                      size: CGSize(width: card.size.width * zoom, height: card.size.height * zoom), alpha: alpha)
        }
        // The answered request's card fades where it parked.
        if t >= Timeline.answered, t < Timeline.answered + 0.16, let card = assets.cards["parked"] {
            drawImage(card.image, at: cardOrigin(companion: companionCenter(at: Timeline.park)),
                      size: CGSize(width: card.size.width * zoom, height: card.size.height * zoom), alpha: 1 - (t - Timeline.answered) / 0.16)
        }
        drawCompanion(at: t)
        drawPointer(at: at, tint: talk.tint, assets: assets)
        drawCaption(at: t)
    }

    private struct Terminal {
        var frame: CGRect
        var title: String
        var lines: [(String, NSColor)]
        /// The window in front, where the user types.
        var focused = false
    }

    private static func terminals(at t: Double) -> [Terminal] {
        let width: CGFloat = 566, height: CGFloat = 296, left: CGFloat = 60, top: CGFloat = 52, gap: CGFloat = 28
        let frames = [
            CGRect(x: left, y: top, width: width, height: height),
            CGRect(x: left + width + gap, y: top, width: width, height: height),
            CGRect(x: left, y: top + height + gap, width: width, height: height),
            CGRect(x: left + width + gap, y: top + height + gap, width: width, height: height),
        ]
        let text = NSColor.white.withAlphaComponent(0.82), dim = NSColor.white.withAlphaComponent(0.5)
        let ok = NSColor(srgbRed: 0.55, green: 0.85, blue: 0.6, alpha: 1)
        var api: [(String, NSColor)] = [("> Paginate the orders API", dim), ("⏺ Read routes/orders.ts", text),
                                         ("⏺ Update Orders.swift", text), ("  ⎿  Added cursor pagination (+42 −9)", dim),
                                         ("⏺ Bash(swift test)", text)]
        if t >= 1.6 { api.append(("  ⎿  14 passed", ok)) }
        if t >= 2.4 { api.append(("⏺ Done. Pagination shipped, all 14 tests pass.", text)) }

        var landing: [(String, NSColor)] = [("> Build the landing page", dim), ("• Created app/page.tsx", text),
                                             ("• Building the pricing grid", text)]
        // In front while its request shows: the user answers by typing "y" here.
        let typing = t >= Timeline.ask && t < Timeline.tell
        if t < Timeline.answered {
            let caret = typing && Int(t * 2.5) % 2 == 0 ? "▌" : ""
            landing += [("", text), ("Allow command?  npm install", Palette.needsYou), ("  [y] yes   [n] no", dim),
                        ("› " + (t >= Timeline.typed ? "y" : "") + caret, text)]
        } else {
            landing += [("✓ Approved: npm install", ok), ("• Installing packages…", text)]
        }

        var db: [(String, NSColor)] = [("> Move orders to the v2 schema", dim), ("⏺ Bash(npm run migrate)", text),
                                        ("  ⎿  Applying migration 3/4…", dim)]
        if t >= Timeline.warn - 0.2 { db.append(("  ⎿  ECONNREFUSED 10.0.3.14:5432", Palette.problem)) }

        let dots = String(repeating: ".", count: Int(t * 3) % 4)
        let docs: [(String, NSColor)] = [("> Refresh the API docs", dim), ("⏺ Read docs/orders.md", text),
                                          ("✻ Thinking" + dots, NSColor(srgbRed: 0.85, green: 0.6, blue: 0.95, alpha: 1))]
        return [
            Terminal(frame: frames[0], title: "api-refactor — Claude Code", lines: api),
            Terminal(frame: frames[1], title: "landing-page — Codex", lines: landing, focused: typing),
            Terminal(frame: frames[2], title: "db-migration — Claude Code", lines: db),
            Terminal(frame: frames[3], title: "docs-site — Claude Code", lines: docs),
        ]
    }

    private static func drawTerminal(_ terminal: Terminal, dim: Bool) {
        let body = NSBezierPath(roundedRect: terminal.frame, xRadius: 12, yRadius: 12)
        NSColor(srgbRed: 0.11, green: 0.12, blue: 0.15, alpha: dim ? 0.86 : 0.96).setFill()
        body.fill()
        NSColor.white.withAlphaComponent(0.09).setStroke()
        body.lineWidth = 1
        body.stroke()
        for (index, color) in [NSColor.systemRed, .systemYellow, .systemGreen].enumerated() {
            color.withAlphaComponent(dim ? 0.55 : 0.85).setFill()
            NSBezierPath(ovalIn: CGRect(x: terminal.frame.minX + 14 + CGFloat(index) * 18, y: terminal.frame.minY + 11, width: 11, height: 11)).fill()
        }
        let title = NSAttributedString(string: terminal.title, attributes: [
            .font: NSFont.systemFont(ofSize: 12.5, weight: .medium), .foregroundColor: NSColor.white.withAlphaComponent(0.6)])
        title.draw(at: CGPoint(x: terminal.frame.midX - title.size().width / 2, y: terminal.frame.minY + 8))
        var y = terminal.frame.minY + 44
        for (line, color) in terminal.lines {
            NSAttributedString(string: line, attributes: [
                .font: NSFont.monospacedSystemFont(ofSize: 13.5, weight: .regular),
                .foregroundColor: color.withAlphaComponent(dim ? 0.7 : 1)]).draw(at: CGPoint(x: terminal.frame.minX + 20, y: y))
            y += 24
        }
    }

    private static func drawMenuBar(t: Double, showMoon: Bool) {
        NSColor.white.withAlphaComponent(0.07).setFill()
        CGRect(x: 0, y: 0, width: size.width, height: 28).fill()
        let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 13, weight: .medium),
                                                         .foregroundColor: NSColor.white.withAlphaComponent(0.85)]
        NSAttributedString(string: "Terminal     Shell     Edit     View     Window", attributes: attributes).draw(at: CGPoint(x: 22, y: 6))
        NSAttributedString(string: "9:41", attributes: attributes).draw(at: CGPoint(x: size.width - 58, y: 6))
        guard showMoon else { return }
        let alpha = min((t - Timeline.moonlet) / 0.4, 1)
        let moon = NSImage(size: NSSize(width: 18, height: 18), flipped: false) { _ in
            NSColor.white.setFill()
            NSBezierPath(ovalIn: NSRect(x: 2.5, y: 2.5, width: 13, height: 13)).fill()
            NSGraphicsContext.current?.compositingOperation = .destinationOut
            NSBezierPath(ovalIn: NSRect(x: 7, y: 5, width: 11, height: 11)).fill()
            return true
        }
        moon.draw(in: CGRect(x: size.width - 92, y: 5, width: 18, height: 18), from: .zero, operation: .sourceOver,
                  fraction: alpha, respectFlipped: true, hints: nil)
    }

    private static func drawNotificationBanner(t: Double) {
        // A notification lands in the corner while you look elsewhere, then leaves.
        let slide = min((t - 6.4) / 0.3, 1) * (t > 7.7 ? max(1 - (t - 7.7) / 0.3, 0) : 1)
        let frame = CGRect(x: size.width - 16 - 340 * slide, y: 40, width: 324, height: 64)
        let banner = NSBezierPath(roundedRect: frame, xRadius: 14, yRadius: 14)
        NSColor(white: 0.22, alpha: 0.95).setFill()
        banner.fill()
        NSAttributedString(string: "Claude Code", attributes: [.font: NSFont.systemFont(ofSize: 13, weight: .semibold),
                                                               .foregroundColor: NSColor.white]).draw(at: CGPoint(x: frame.minX + 16, y: frame.minY + 12))
        NSAttributedString(string: "Task complete", attributes: [.font: NSFont.systemFont(ofSize: 13),
                                                                 .foregroundColor: NSColor.white.withAlphaComponent(0.75)]).draw(at: CGPoint(x: frame.minX + 16, y: frame.minY + 33))
    }

    private static func badge(_ text: String, color: NSColor, at topRight: CGPoint) {
        let label = NSAttributedString(string: text, attributes: [.font: NSFont.systemFont(ofSize: 12.5, weight: .semibold),
                                                                  .foregroundColor: NSColor.black.withAlphaComponent(0.85)])
        let size = label.size()
        let frame = CGRect(x: topRight.x - size.width - 20, y: topRight.y, width: size.width + 20, height: size.height + 8)
        color.setFill()
        NSBezierPath(roundedRect: frame, xRadius: frame.height / 2, yRadius: frame.height / 2).fill()
        label.draw(at: CGPoint(x: frame.minX + 10, y: frame.minY + 4))
    }

    private static func drawPointer(at point: CGPoint, tint: PointerTint, assets: Assets) {
        if tint == .system {
            // The standard macOS arrow, at its hotspot.
            let arrow = assets.arrow
            guard arrow.image.size != .zero else { drawArrow(at: point); return }
            arrow.image.draw(in: CGRect(x: point.x - arrow.hotSpot.x * zoom, y: point.y - arrow.hotSpot.y * zoom,
                                        width: arrow.image.size.width * zoom, height: arrow.image.size.height * zoom),
                             from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
        } else if let image = assets.pointers[tint] {
            let points: CGFloat = 42 * zoom, unit = points / PointerArtwork.canvas
            drawImage(image, at: CGPoint(x: point.x - PointerArtwork.hotSpot.x * unit, y: point.y - PointerArtwork.hotSpot.y * unit),
                      size: CGSize(width: points, height: points), alpha: 1)
        }
    }

    /// The standard arrow, drawn by hand for when the system's image comes
    /// back empty: black with a white edge, its tip at `point`, about the size
    /// of a real one at the film's zoom.
    private static func drawArrow(at point: CGPoint) {
        let corners: [CGPoint] = [(0, 0), (0, 16.5), (4, 12.7), (6.9, 19.3), (9.6, 18.1), (6.8, 11.7), (11.9, 11.7)]
            .map { CGPoint(x: point.x + $0.0 * zoom, y: point.y + $0.1 * zoom) }
        let arrow = NSBezierPath()
        arrow.move(to: corners[0])
        for corner in corners.dropFirst() { arrow.line(to: corner) }
        arrow.close()
        arrow.lineJoinStyle = .round
        NSGraphicsContext.saveGraphicsState()
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.45)
        shadow.shadowOffset = NSSize(width: 0, height: -1.5)
        shadow.shadowBlurRadius = 3
        shadow.set()
        NSColor.white.setStroke()
        arrow.lineWidth = 1.6 * zoom
        arrow.stroke()
        NSGraphicsContext.restoreGraphicsState()
        NSColor.black.setFill()
        arrow.fill()
    }

    private static func drawCaption(at t: Double) {
        guard let caption = captions.first(where: { t >= $0.0 && t < $0.1 }) else { return }
        let alpha = min(min((t - caption.0) / 0.2, (caption.1 - t) / 0.2), 1)
        let text = NSAttributedString(string: caption.2, attributes: [.font: NSFont.systemFont(ofSize: 26, weight: .semibold),
                                                                      .foregroundColor: NSColor.white.withAlphaComponent(alpha)])
        let textSize = text.size()
        let frame = CGRect(x: (size.width - textSize.width) / 2 - 24, y: size.height - 86, width: textSize.width + 48, height: textSize.height + 20)
        NSColor.black.withAlphaComponent(0.55 * alpha).setFill()
        NSBezierPath(roundedRect: frame, xRadius: frame.height / 2, yRadius: frame.height / 2).fill()
        text.draw(at: CGPoint(x: frame.minX + 24, y: frame.minY + 10))
    }

    // MARK: - End card

    private static func drawEndCard(t: Double, assets: Assets) {
        NSColor(srgbRed: 0.04, green: 0.05, blue: 0.10, alpha: 1).setFill()
        CGRect(origin: .zero, size: size).fill()
        let alpha = min((t - Timeline.endCard) / 0.5, 1)
        if let icon = assets.icon {
            drawImage(icon, at: CGPoint(x: size.width / 2 - 80, y: 170), size: CGSize(width: 160, height: 160), alpha: alpha)
        }
        func centered(_ string: String, size fontSize: CGFloat, weight: NSFont.Weight, y: CGFloat, opacity: CGFloat) {
            let text = NSAttributedString(string: string, attributes: [.font: NSFont.systemFont(ofSize: fontSize, weight: weight),
                                                                       .foregroundColor: NSColor.white.withAlphaComponent(opacity * alpha)])
            text.draw(at: CGPoint(x: (size.width - text.size().width) / 2, y: y))
        }
        centered("Moonlet", size: 56, weight: .bold, y: 352, opacity: 1)
        centered("Your agents report to your pointer.", size: 26, weight: .regular, y: 428, opacity: 0.85)
        let colors: [(PointerTint, String)] = [(.info, "tells"), (.needsYou, "asks"), (.problem, "warns")]
        for (index, entry) in colors.enumerated() {
            let x = size.width / 2 - 150 + CGFloat(index) * 110
            if let image = assets.pointers[entry.0] {
                drawImage(image, at: CGPoint(x: x, y: 486), size: CGSize(width: 42, height: 42), alpha: alpha)
            }
            NSAttributedString(string: entry.1, attributes: [.font: NSFont.systemFont(ofSize: 17, weight: .medium),
                                                              .foregroundColor: NSColor.white.withAlphaComponent(0.75 * alpha)])
                .draw(at: CGPoint(x: x + 48, y: 498))
        }
        centered("Open source  ·  macOS  ·  Claude Code, Codex, and more", size: 17, weight: .regular, y: 580, opacity: 0.6)
    }

    // MARK: - Summon

    /// The summon view at the end of the story: the film's own five agents, all
    /// in Terminal, as the viewer just saw them. landing-page was approved and
    /// works again, web-app deployed, db-migration failed, api-refactor finished
    /// 10 minutes ago, and docs-site is still thinking.
    private static func summon() -> SummonContent {
        let now = Date()
        func ago(_ minutes: Double) -> Date { now.addingTimeInterval(-minutes * 60) }
        func event(_ minutes: Double, _ kind: MomentKind, _ label: String, _ detail: String) -> TimelineEvent {
            TimelineEvent(id: UUID(), at: ago(minutes), kind: kind, mood: CompanionMood.read(kind: kind, detail: detail),
                          label: "\(label) · \(detail)")
        }
        return SummonContent(
            agents: [
                AgentRow(id: "db-migration", label: "db-migration", place: "Terminal", activity: .failed, progress: 0.75,
                         status: "Staging DB refused connection", since: ago(0.2), mood: .teary, isNew: true),
                AgentRow(id: "landing-page", label: "landing-page", place: "Terminal", activity: .working, progress: 0.6,
                         status: "Installing packages", since: ago(1.5), etaMinutes: 2),
                AgentRow(id: "docs-site", label: "docs-site", place: "Terminal", activity: .working, progress: 0.4,
                         status: "Refreshing the API docs", since: ago(6), etaMinutes: 5),
                AgentRow(id: "web-app", label: "web-app", place: "Terminal", activity: .done, progress: 1,
                         status: "Deployed to production", since: ago(1), mood: .celebrate, isNew: true),
                AgentRow(id: "api-refactor", label: "api-refactor", place: "Terminal", activity: .done, progress: 1,
                         status: "Pagination shipped, all 14 tests pass", since: ago(10.3), mood: .celebrate, isNew: true),
            ],
            events: [
                event(20, .needsYou, "landing-page", "Wants to run npm install"),
                event(10.3, .finished, "api-refactor", "Pagination shipped, all 14 tests pass"),
                event(1, .finished, "web-app", "Deployed to production"),
                event(0.2, .failed, "db-migration", "Staging DB refused connection"),
            ])
    }

    // MARK: - Helpers

    private static func drawImage(_ image: CGImage, at origin: CGPoint, size: CGSize, alpha: CGFloat) {
        NSImage(cgImage: image, size: size).draw(in: CGRect(origin: origin, size: size), from: .zero, operation: .sourceOver,
                                                 fraction: alpha, respectFlipped: true, hints: nil)
    }

    /// Everything the film reuses, rendered once from Moonlet's real views.
    private struct Assets {
        var cards: [String: (image: CGImage, size: CGSize)] = [:]
        var summon: CGImage?
        var summonSize = CGSize.zero
        var summonAnchor = CGPoint.zero
        var pointers: [PointerTint: CGImage] = [:]
        var arrow: (image: NSImage, hotSpot: CGPoint)
        var icon: CGImage?

        @MainActor init() {
            arrow = (NSCursor.arrow.image, NSCursor.arrow.hotSpot)
            for tint in [PointerTint.info, .needsYou, .problem] {
                pointers[tint] = tint.color.flatMap { PointerArtwork.image(color: $0, points: 42, scale: 3) }
            }
            let samples: [(String, MomentKind, String, String, String?)] = [
                ("ask", .needsYou, "landing-page", "Wants to run npm install", nil),
                ("parked", .needsYou, "landing-page", "Wants to run npm install", "Open in Terminal"),
                ("tell", .finished, "web-app", "Deployed to production", nil),
                ("warn", .failed, "db-migration", "Staging DB refused connection", nil),
            ]
            let now = Date()
            for (key, kind, label, detail, hint) in samples {
                var engine = AttentionEngine()
                let moment = Moment(agentID: "film:\(label)", agentLabel: label, project: label, kind: kind, detail: detail, createdAt: now)
                for case .show(let card) in engine.receive(moment, presence: PresenceSnapshot(secondsSinceInput: 0.5, secondsSinceKey: 60), now: now) {
                    if let image = Self.snapshot(CardView(card: card, hint: hint)) {
                        cards[key] = (image, CGSize(width: CGFloat(image.width) / 3, height: CGFloat(image.height) / 3))
                    }
                }
            }
            if let image = Self.snapshot(SummonView(content: DemoFilm.summon(), actions: .init())) {
                summon = image
                summonSize = CGSize(width: CGFloat(image.width) / 3, height: CGFloat(image.height) / 3)
                summonAnchor = SummonView.wellCenter
            }
            if let url = Bundle.main.url(forResource: "AppIcon", withExtension: "icns") ?? URL(string: "file://" + FileManager.default.currentDirectoryPath + "/Packaging/AppIcon.icns"),
               let image = NSImage(contentsOf: url) {
                var iconRect = CGRect(x: 0, y: 0, width: 320, height: 320)
                icon = image.cgImage(forProposedRect: &iconRect, context: nil, hints: nil)
            }
        }

        @MainActor static func snapshot(_ view: some View) -> CGImage? {
            let renderer = ImageRenderer(content: view.environment(\.isSnapshot, true).environment(\.colorScheme, .dark))
            renderer.scale = 3
            var result: CGImage?
            NSAppearance(named: .darkAqua)?.performAsCurrentDrawingAppearance { result = renderer.cgImage }
            return result
        }
    }
}
