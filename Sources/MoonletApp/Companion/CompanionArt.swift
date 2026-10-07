import AppKit
import CoreGraphics
import MoonletBrain

/// Draws the companion: a tiny moon with a face. Flat fills and a dark outline,
/// so it reads at 24 points on light and dark desktops.
enum CompanionArt {
    /// Draws `pose` centered on `center` (in the context's coordinates, which may
    /// have y up or down: `flipped` says y grows downward), at `scale` points per
    /// rig unit. At actual size the scale is about 1.15, a body 23 points across.
    static func draw(_ pose: CompanionPose, in context: CGContext, center: CGPoint, scale: CGFloat, flipped: Bool) {
        context.saveGState()
        defer { context.restoreGState() }
        context.translateBy(x: center.x, y: center.y)
        context.scaleBy(x: scale, y: flipped ? scale : -scale)
        context.addEllipse(in: CGRect(x: -10, y: -10, width: 20, height: 20))
        context.setFillColor(CGColor(srgbRed: 0.98, green: 0.96, blue: 0.87, alpha: 1))
        context.fillPath()
    }
}
