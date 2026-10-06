import AppKit
import CoreGraphics

/// Moonlet's pointer: the rounded arrowhead from Cua's `cua.default` cursor
/// theme (MIT, github.com/trycua/cua), a colored body with a white outline over
/// a soft glow of the same color.
enum PointerArtwork {
    /// The artwork is authored on a 128-unit canvas.
    static let canvas: CGFloat = 128
    /// Where the arrow's tip sits on the canvas: the outermost point of its rounded
    /// tip, so clicks land exactly where the pointer appears to point. (Cua's own theme
    /// puts the hotspot at (55, 30), a few points along the top edge, which suits an
    /// agent's cursor but not a person's.)
    static let hotSpot = CGPoint(x: 45, y: 31)

    /// The arrowhead outline in canvas units (y grows downward).
    /// Immutable once built, so sharing it across threads is safe.
    nonisolated(unsafe) static let path: CGPath = {
        let p = CGMutablePath()
        p.move(to: CGPoint(x: 55, y: 30))
        p.addCurve(to: CGPoint(x: 43, y: 41), control1: CGPoint(x: 48, y: 28), control2: CGPoint(x: 42, y: 33))
        p.addLine(to: CGPoint(x: 64, y: 98))
        p.addCurve(to: CGPoint(x: 77, y: 99), control1: CGPoint(x: 67, y: 106), control2: CGPoint(x: 73, y: 106))
        p.addLine(to: CGPoint(x: 86, y: 79))
        p.addCurve(to: CGPoint(x: 95, y: 70), control1: CGPoint(x: 88, y: 75), control2: CGPoint(x: 91, y: 72))
        p.addLine(to: CGPoint(x: 108, y: 63))
        p.addCurve(to: CGPoint(x: 107, y: 50), control1: CGPoint(x: 115, y: 59), control2: CGPoint(x: 114, y: 53))
        p.closeSubpath()
        return p
    }()

    /// Glow layers as (stroke width, opacity), widest first, matching the original theme.
    static let glow: [(CGFloat, CGFloat)] = [
        (44, 0.020), (36, 0.024), (29, 0.030), (23, 0.038), (18, 0.048), (14, 0.060), (10, 0.075), (7, 0.095),
    ]

    /// Renders the pointer at `points` × `points` and `scale` pixels per point.
    static func image(color: NSColor, points: CGFloat, scale: CGFloat) -> CGImage? {
        let pixels = Int((points * scale).rounded())
        guard pixels > 0,
              let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: pixels, height: pixels, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
              let rgb = color.usingColorSpace(.sRGB)
        else { return nil }
        let unit = CGFloat(pixels) / canvas
        context.translateBy(x: 0, y: CGFloat(pixels))
        context.scaleBy(x: unit, y: -unit)
        context.setLineJoin(.round)
        context.setLineCap(.round)
        for (width, opacity) in glow {
            context.addPath(path)
            context.setStrokeColor(rgb.withAlphaComponent(opacity).cgColor)
            context.setLineWidth(width)
            context.strokePath()
        }
        context.addPath(path)
        context.setFillColor(rgb.cgColor)
        context.fillPath()
        context.addPath(path)
        context.setStrokeColor(NSColor.white.cgColor)
        context.setLineWidth(5)
        context.strokePath()
        return context.makeImage()
    }
}
