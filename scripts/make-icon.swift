// Draws Moonlet's app icon, a crescent moon keeping the Moonlet pointer
// company, and writes it as an .icns file.
//
//   swift scripts/make-icon.swift Packaging/AppIcon.icns
import AppKit

let output = URL(fileURLWithPath: CommandLine.arguments.dropFirst().first ?? "Packaging/AppIcon.icns")

func drawIcon(size: CGFloat) -> NSBitmapImageRep {
    let pixels = Int(size)
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let context = NSGraphicsContext.current!.cgContext
    context.scaleBy(x: size / 1024, y: size / 1024)

    // macOS icon grid: an 824-point rounded square centered on a 1024 canvas.
    let tile = CGRect(x: 100, y: 100, width: 824, height: 824)
    let shape = CGPath(roundedRect: tile, cornerWidth: 186, cornerHeight: 186, transform: nil)
    context.addPath(shape)
    context.clip()
    let sky = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB),
                         colors: [CGColor(srgbRed: 0.13, green: 0.20, blue: 0.36, alpha: 1),
                                  CGColor(srgbRed: 0.04, green: 0.07, blue: 0.14, alpha: 1)] as CFArray,
                         locations: [0, 1])!
    context.drawLinearGradient(sky, start: CGPoint(x: 512, y: 924), end: CGPoint(x: 512, y: 100), options: [])

    for (x, y, r, a) in [(250.0, 760.0, 6.0, 0.8), (720, 820, 5, 0.6), (820, 640, 4, 0.5), (300, 380, 4, 0.45),
                         (640, 700, 3, 0.5), (180, 560, 3, 0.4), (860, 300, 4, 0.35)] {
        context.setFillColor(CGColor(gray: 1, alpha: a))
        context.fillEllipse(in: CGRect(x: x - r, y: y - r, width: 2 * r, height: 2 * r))
    }

    // The crescent: a disc with a bite taken out of it.
    context.saveGState()
    context.beginTransparencyLayer(auxiliaryInfo: nil)
    context.setFillColor(CGColor(srgbRed: 0.97, green: 0.95, blue: 0.88, alpha: 1))
    context.fillEllipse(in: CGRect(x: 210, y: 470, width: 380, height: 380))
    context.setBlendMode(.clear)
    context.fillEllipse(in: CGRect(x: 330, y: 540, width: 340, height: 340))
    context.endTransparencyLayer()
    context.restoreGState()

    // The Moonlet pointer, from Cua's cua.default cursor (MIT), with its glow.
    let pointer = CGMutablePath()
    pointer.move(to: CGPoint(x: 55, y: 30))
    pointer.addCurve(to: CGPoint(x: 43, y: 41), control1: CGPoint(x: 48, y: 28), control2: CGPoint(x: 42, y: 33))
    pointer.addLine(to: CGPoint(x: 64, y: 98))
    pointer.addCurve(to: CGPoint(x: 77, y: 99), control1: CGPoint(x: 67, y: 106), control2: CGPoint(x: 73, y: 106))
    pointer.addLine(to: CGPoint(x: 86, y: 79))
    pointer.addCurve(to: CGPoint(x: 95, y: 70), control1: CGPoint(x: 88, y: 75), control2: CGPoint(x: 91, y: 72))
    pointer.addLine(to: CGPoint(x: 108, y: 63))
    pointer.addCurve(to: CGPoint(x: 107, y: 50), control1: CGPoint(x: 115, y: 59), control2: CGPoint(x: 114, y: 53))
    pointer.closeSubpath()
    context.saveGState()
    context.translateBy(x: 330, y: 680)
    context.scaleBy(x: 4.2, y: -4.2)
    context.setLineJoin(.round)
    let blue = CGColor(srgbRed: 94 / 255, green: 192 / 255, blue: 232 / 255, alpha: 1)
    for (width, alpha) in [(44.0, 0.05), (36, 0.06), (29, 0.07), (23, 0.08), (18, 0.10), (14, 0.12), (10, 0.15), (7, 0.18)] {
        context.addPath(pointer)
        context.setStrokeColor(blue.copy(alpha: alpha)!)
        context.setLineWidth(width)
        context.strokePath()
    }
    context.addPath(pointer)
    context.setFillColor(blue)
    context.fillPath()
    context.addPath(pointer)
    context.setStrokeColor(.white)
    context.setLineWidth(5)
    context.strokePath()
    context.restoreGState()

    NSGraphicsContext.restoreGraphicsState()
    return rep
}

let iconset = FileManager.default.temporaryDirectory.appendingPathComponent("Moonlet-\(UUID().uuidString).iconset")
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
for points in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let name = scale == 1 ? "icon_\(points)x\(points).png" : "icon_\(points)x\(points)@2x.png"
        let png = drawIcon(size: CGFloat(points * scale)).representation(using: .png, properties: [:])!
        try png.write(to: iconset.appendingPathComponent(name))
    }
}
let iconutil = Process()
iconutil.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
iconutil.arguments = ["-c", "icns", iconset.path, "-o", output.path]
try iconutil.run()
iconutil.waitUntilExit()
try? FileManager.default.removeItem(at: iconset)
print(iconutil.terminationStatus == 0 ? "Wrote \(output.path)" : "iconutil failed")
