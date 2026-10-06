import AppKit

/// The menu bar moon: Moonlet's home. It carries a small dot only when
/// something is new or an agent is waiting on the user.
@MainActor
final class StatusMoon: NSObject, NSMenuDelegate {
    /// Builds the menu fresh each time it opens.
    var buildMenu: ((NSMenu) -> Void)?
    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    private let menu = NSMenu()
    private let dot = NSView(frame: NSRect(x: 0, y: 0, width: 6, height: 6))

    override init() {
        super.init()
        menu.delegate = self
        menu.autoenablesItems = false
        item.menu = menu
        if let button = item.button {
            button.image = Self.crescent
            button.setAccessibilityLabel("Moonlet")
            dot.wantsLayer = true
            dot.layer?.cornerRadius = 3
            dot.isHidden = true
            button.addSubview(dot)
        }
    }

    /// Shows a dot in `color`, or no dot for `nil`.
    func setDot(_ color: NSColor?) {
        guard let button = item.button else { return }
        dot.isHidden = color == nil
        dot.layer?.backgroundColor = color?.cgColor
        dot.setFrameOrigin(NSPoint(x: button.bounds.maxX - 9, y: button.isFlipped ? 3 : button.bounds.maxY - 9))
    }

    /// The moon's position on screen, where departing cards fly.
    var screenLocation: CGPoint? {
        guard let button = item.button, let window = button.window else { return nil }
        let frame = window.convertToScreen(button.convert(button.bounds, to: nil))
        return CGPoint(x: frame.midX, y: frame.midY)
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        buildMenu?(menu)
    }

    /// A crescent template image that follows the menu bar's appearance.
    static let crescent: NSImage = {
        let image = NSImage(size: NSSize(width: 18, height: 18), flipped: false) { _ in
            guard let context = NSGraphicsContext.current else { return false }
            NSColor.black.setFill()
            NSBezierPath(ovalIn: NSRect(x: 2.5, y: 2.5, width: 13, height: 13)).fill()
            context.compositingOperation = .destinationOut
            NSBezierPath(ovalIn: NSRect(x: 7, y: 5, width: 11, height: 11)).fill()
            return true
        }
        image.isTemplate = true
        return image
    }()
}
