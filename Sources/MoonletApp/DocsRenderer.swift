import AppKit
import MoonletBrain
import SwiftUI

/// Renders the real interface to PNGs for the documentation:
///
///     swift run MoonletApp --render-docs docs/images
///
/// Cards come from `AttentionEngine` itself, so the pictures always match
/// what the app shows.
@MainActor
enum DocsRenderer {
    static func render(to directory: URL) {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for dark in [false, true] {
            let suffix = dark ? "dark" : "light"
            NSAppearance(named: dark ? .darkAqua : .aqua)?.performAsCurrentDrawingAppearance {
                write(cardsSheet(dark: dark), to: directory.appendingPathComponent("cards-\(suffix).png"))
                write(summonSheet(dark: dark), to: directory.appendingPathComponent("summon-\(suffix).png"))
            }
        }
        write(pointerSheet(), to: directory.appendingPathComponent("pointer-states.png"))
        print("Rendered documentation images to \(directory.path)")
    }

    // MARK: - Sample content

    static func sampleCards() -> [Card] {
        let now = Date()
        let active = PresenceSnapshot(secondsSinceInput: 0.5, secondsSinceKey: 60)
        func card(_ moments: [Moment], presence: PresenceSnapshot = active) -> Card? {
            var engine = AttentionEngine()
            var shown: Card?
            for moment in moments {
                for case .show(let card) in engine.receive(moment, presence: presence, now: now) { shown = card }
            }
            for case .show(let card) in engine.tick(presence: active, now: now.addingTimeInterval(1)) { shown = card }
            return shown
        }
        func moment(_ label: String, _ kind: MomentKind, _ detail: String) -> Moment {
            Moment(agentID: "demo:\(label)", agentLabel: label, project: label, kind: kind, detail: detail, createdAt: now)
        }
        let away = PresenceSnapshot(secondsSinceInput: 600, secondsSinceKey: 600)
        return [
            card([moment("landing-page", .needsYou, "Wants to run npm install")]),
            card([moment("api-refactor", .finished, "Pagination shipped, 14 tests pass")]),
            card([moment("docs-site", .finished, "Changelog published"),
                  moment("db-migration", .failed, "Staging DB refused connection"),
                  moment("web-app", .needsYou, "Plan ready for review")], presence: away),
        ].compactMap { $0 }
    }

    static func sampleSummon() -> SummonContent {
        let now = Date()
        return SummonContent(
            agents: [
                AgentRow(id: "a", label: "landing-page", place: "Claude", activity: .waiting, progress: nil,
                         status: "Needs permission to run npm install", since: now.addingTimeInterval(-240)),
                AgentRow(id: "b", label: "db-migration", place: "Terminal", activity: .failed, progress: nil,
                         status: "Staging DB refused connection", since: now.addingTimeInterval(-60)),
                AgentRow(id: "c", label: "api-refactor", place: "iTerm", activity: .working, progress: 0.6,
                         status: "Running tests", since: now.addingTimeInterval(-900)),
                AgentRow(id: "d", label: "docs-site", place: "VS Code", activity: .done, progress: 1,
                         status: "Changelog published", since: now.addingTimeInterval(-420)),
            ],
            earlier: [Moment(agentID: "e", agentLabel: "search-index", project: "search-index", kind: .finished,
                             detail: "Reindexed 48k documents", createdAt: now.addingTimeInterval(-1800))])
    }

    // MARK: - Sheets

    private static func cardsSheet(dark: Bool) -> CGImage? {
        // Each card next to the pointer in that card's color, as on screen.
        let cards = sampleCards().compactMap { card in
            snapshot(CardView(card: card), dark: dark).map { (image: $0, pointer: PointerArtwork.image(color: Palette.color(for: card.tone), points: 42, scale: 2)) }
        }
        let columnWidth: CGFloat = 320
        let size = CGSize(width: columnWidth * CGFloat(cards.count) + 40, height: 190)
        return sheet(size: size, dark: dark) { context in
            for (index, entry) in cards.enumerated() {
                let card = entry.image
                let tip = CGPoint(x: 40 + CGFloat(index) * columnWidth, y: 40)
                // Cards sit 22 points right of and 30 points below the pointer's tip, like on screen.
                let cardSize = CGSize(width: CGFloat(card.width) / 2, height: CGFloat(card.height) / 2)
                draw(card, in: CGRect(origin: CGPoint(x: tip.x + 22 - 10, y: tip.y + 30 - 10), size: cardSize), on: context)
                if let pointer = entry.pointer {
                    let unit = 42 / PointerArtwork.canvas
                    let origin = CGPoint(x: tip.x - PointerArtwork.hotSpot.x * unit, y: tip.y - PointerArtwork.hotSpot.y * unit)
                    draw(pointer, in: CGRect(origin: origin, size: CGSize(width: 42, height: 42)), on: context)
                }
            }
        }
    }

    /// The three talking colors on a light row and a dark row: blue tells, yellow asks, red warns.
    private static func pointerSheet() -> CGImage? {
        let colors = [Palette.info, Palette.needsYou, Palette.problem]
        let cell: CGFloat = 84
        let size = CGSize(width: cell * CGFloat(colors.count) + 24, height: cell * 2 + 24)
        guard let context = CGContext(data: nil, width: Int(size.width * 2), height: Int(size.height * 2), bitsPerComponent: 8,
                                      bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.scaleBy(x: 2, y: 2)
        context.setFillColor(CGColor(gray: 0.12, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: size.width, height: cell + 12))
        context.setFillColor(CGColor(gray: 0.97, alpha: 1))
        context.fill(CGRect(x: 0, y: cell + 12, width: size.width, height: cell + 12))
        for (index, color) in colors.enumerated() {
            guard let image = PointerArtwork.image(color: color, points: 64, scale: 2) else { continue }
            for row in 0..<2 {
                let origin = CGPoint(x: 12 + CGFloat(index) * cell + 10, y: 12 + CGFloat(row) * (cell + 12) + 10)
                context.draw(image, in: CGRect(origin: origin, size: CGSize(width: 64, height: 64)))
            }
        }
        return context.makeImage()
    }

    private static func summonSheet(dark: Bool) -> CGImage? {
        guard let summon = snapshot(SummonView(content: sampleSummon(), actions: .init()), dark: dark) else { return nil }
        let summonSize = CGSize(width: CGFloat(summon.width) / 2, height: CGFloat(summon.height) / 2)
        return sheet(size: CGSize(width: summonSize.width + 40, height: summonSize.height + 40), dark: dark) { context in
            draw(summon, in: CGRect(origin: CGPoint(x: 20, y: 20), size: summonSize), on: context)
        }
    }

    // MARK: - Drawing

    private static func snapshot(_ view: some View, dark: Bool) -> CGImage? {
        let renderer = ImageRenderer(content: view
            .environment(\.isSnapshot, true)
            .environment(\.colorScheme, dark ? .dark : .light))
        renderer.scale = 2
        return renderer.cgImage
    }

    /// A 2× bitmap of `size` points with a soft desktop-like background, drawn top-down.
    private static func sheet(size: CGSize, dark: Bool, draw content: (CGContext) -> Void) -> CGImage? {
        guard let context = CGContext(data: nil, width: Int(size.width * 2), height: Int(size.height * 2), bitsPerComponent: 8,
                                      bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.scaleBy(x: 2, y: 2)
        let colors = dark
            ? [CGColor(srgbRed: 0.14, green: 0.16, blue: 0.22, alpha: 1), CGColor(srgbRed: 0.08, green: 0.09, blue: 0.13, alpha: 1)]
            : [CGColor(srgbRed: 0.94, green: 0.95, blue: 0.97, alpha: 1), CGColor(srgbRed: 0.87, green: 0.90, blue: 0.94, alpha: 1)]
        let gradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: colors as CFArray, locations: [0, 1])!
        context.drawLinearGradient(gradient, start: CGPoint(x: 0, y: size.height), end: .zero, options: [])
        context.translateBy(x: 0, y: size.height)
        context.scaleBy(x: 1, y: -1)
        content(context)
        return context.makeImage()
    }

    /// Draws an image into a top-down context without flipping it.
    private static func draw(_ image: CGImage, in rect: CGRect, on context: CGContext) {
        context.saveGState()
        context.translateBy(x: rect.minX, y: rect.maxY)
        context.scaleBy(x: 1, y: -1)
        context.draw(image, in: CGRect(origin: .zero, size: rect.size))
        context.restoreGState()
    }

    private static func write(_ image: CGImage?, to url: URL) {
        guard let image, let data = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else { return }
        try? data.write(to: url)
    }
}
