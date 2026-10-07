import AppKit
import MoonletBrain

/// Renders every face and mood of the companion to PNGs, for checking the art
/// against the design and for the documentation:
///
///     swift run MoonletApp --render-companion docs/images
@MainActor
enum CompanionSheet {
    /// Points per rig unit: a body 60 points across.
    static let scale: CGFloat = 3

    static func render(to directory: URL) {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for dark in [false, true] {
            let suffix = dark ? "dark" : "light"
            write(expressions(dark: dark), to: directory.appendingPathComponent("companion-expressions-\(suffix).png"))
            write(moods(dark: dark), to: directory.appendingPathComponent("companion-moods-\(suffix).png"))
        }
        print("Rendered the companion to \(directory.path)")
    }

    /// Each mood's face with what it keeps on it, caught mid-animation where
    /// the props read best.
    static func pose(for mood: CompanionMood) -> CompanionPose {
        var pose = CompanionPose(expression: mood.expression)
        func add(_ kind: CompanionProp.Kind, _ progress: Double) { pose.props.append(CompanionProp(kind: kind, progress: progress)) }
        switch mood {
        case .celebrate: add(.hat, 0); add(.confetti, 0.2)
        case .proud, .happy: add(.check, 0.6)
        case .cheeky: break
        case .surprised: add(.sparkle, 0.45)
        case .asking, .curious: add(.sign("?"), 0)
        case .nervous: add(.sign("!"), 0); add(.drop, 0.2)
        case .teary: add(.tear, 0.3); add(.cloud, 0)
        case .worried: add(.drop, 0.2)
        case .sleepy: add(.zzz, 0.125)
        case .grateful: add(.heart, 0.45)
        }
        return pose
    }

    // MARK: - Sheets

    /// Every expression in a grid, each with its name.
    private static func expressions(dark: Bool) -> CGImage? {
        let cell = CGSize(width: 100, height: 108)
        return grid(Expression.allCases.map { (CompanionPose(expression: $0), $0.rawValue) },
                    columns: 6, cell: cell, center: CGPoint(x: 50, y: 46), dark: dark)
    }

    /// Every mood with its face and props, each with its name.
    private static func moods(dark: Bool) -> CGImage? {
        let cell = CGSize(width: 120, height: 150)
        return grid(CompanionMood.allCases.map { (pose(for: $0), $0.rawValue) },
                    columns: 6, cell: cell, center: CGPoint(x: 54, y: 78), dark: dark)
    }

    /// Lays out `items` in rounded cells, the companion at `center` within each cell.
    private static func grid(_ items: [(CompanionPose, String)], columns: Int, cell: CGSize, center: CGPoint, dark: Bool) -> CGImage? {
        let margin: CGFloat = 24, gap: CGFloat = 10
        let rows = (items.count + columns - 1) / columns
        let size = CGSize(width: margin * 2 + CGFloat(columns) * cell.width + CGFloat(columns - 1) * gap,
                          height: margin * 2 + CGFloat(rows) * cell.height + CGFloat(rows - 1) * gap)
        let background = dark ? CGColor(srgbRed: 0.09, green: 0.09, blue: 0.10, alpha: 1) : CGColor(srgbRed: 0.95, green: 0.95, blue: 0.96, alpha: 1)
        let surface = dark ? CGColor(srgbRed: 0.15, green: 0.15, blue: 0.16, alpha: 1) : CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1)
        let text = dark ? NSColor(white: 0.66, alpha: 1) : NSColor(white: 0.40, alpha: 1)
        return bitmap(size: size) { context in
            context.setFillColor(background)
            context.fill(CGRect(origin: .zero, size: size))
            for (index, (pose, name)) in items.enumerated() {
                let origin = CGPoint(x: margin + CGFloat(index % columns) * (cell.width + gap),
                                     y: margin + CGFloat(index / columns) * (cell.height + gap))
                let frame = CGRect(origin: origin, size: cell)
                context.addPath(CGPath(roundedRect: frame, cornerWidth: 14, cornerHeight: 14, transform: nil))
                context.setFillColor(surface)
                context.fillPath()
                CompanionArt.draw(pose, in: context, center: CGPoint(x: origin.x + center.x, y: origin.y + center.y), scale: scale, flipped: true)
                label(name, centeredAt: CGPoint(x: frame.midX, y: frame.maxY - 16), color: text)
            }
        }
    }

    // MARK: - Drawing

    private static func label(_ string: String, centeredAt point: CGPoint, color: NSColor) {
        let text = NSAttributedString(string: string, attributes: [
            .font: NSFont.systemFont(ofSize: 12, weight: .medium),
            .foregroundColor: color,
        ])
        let size = text.size()
        text.draw(at: CGPoint(x: point.x - size.width / 2, y: point.y - size.height / 2))
    }

    /// A 2× bitmap of `size` points, drawn top-down, with AppKit text drawing into it.
    private static func bitmap(size: CGSize, draw content: (CGContext) -> Void) -> CGImage? {
        guard let context = CGContext(data: nil, width: Int(size.width * 2), height: Int(size.height * 2), bitsPerComponent: 8,
                                      bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.translateBy(x: 0, y: size.height * 2)
        context.scaleBy(x: 2, y: -2)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: true)
        content(context)
        NSGraphicsContext.restoreGraphicsState()
        return context.makeImage()
    }

    private static func write(_ image: CGImage?, to url: URL) {
        guard let image, let data = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else { return }
        try? data.write(to: url)
    }
}
