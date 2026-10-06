import AppKit
import MoonletBrain
import QuartzCore

/// Gives the user's own pointer Moonlet's look while an agent talks to them.
///
/// macOS 26 no longer lets apps replace the system cursor image, so the skin
/// hides the real arrow and draws Moonlet's pointer at the exact mouse position
/// in a click-through window at the accessibility overlay level. Only the arrow
/// is skinned: the moment an app shows a text cursor, a link hand, or a resize
/// cursor, the real one comes back. A watchdog restores the real pointer if the
/// app ever stalls, and macOS restores it by itself if the app quits or crashes.
@MainActor
final class PointerSkin {
    /// The look to show. `.system` hands the pointer back to macOS.
    var tint: PointerTint = .system {
        didSet { if tint != oldValue { refresh() } }
    }

    /// Master switch; off means the standard arrow, always.
    var isEnabled = true {
        didSet { if isEnabled != oldValue { refresh() } }
    }

    private(set) var isAvailable = false
    /// Set when the skin turned itself off because it seemed to block input.
    private(set) var suspendedReason: String?
    private let window: NSPanel
    private let artwork = CALayer()
    /// Keeps the skin in place and checks the system cursor; mouse events move it in between.
    private var timer: Timer?
    /// True while the screen sleeps or the session is locked: nothing may be drawn.
    private var paused = false
    private var observers: [NSObjectProtocol] = []
    private var arrow: (size: CGSize, hotSpot: CGPoint)?
    private var canvasPoints: CGFloat = 42
    private var lastArrowRefresh = Date.distantPast
    private var lastShapeCheck: CFTimeInterval = 0
    private var arrowShowing = true
    private var imageCache: [String: CGImage] = [:]
    private let guardian = PointerGuardian()

    init() {
        window = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 42, height: 42),
                         styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.ignoresMouseEvents = true
        // Never the cursor level: it sits above the screen-shield band, where windows can
        // capture input even when they ignore mouse events.
        window.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.assistiveTechHighWindow)))
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        window.isReleasedWhenClosed = false
        let host = NSView(frame: window.contentLayoutRect)
        host.wantsLayer = true
        host.layer?.addSublayer(artwork)
        window.contentView = host
        isAvailable = SkyLight.allowCursorControlInBackground()
        guardian.start()
        watchSleepAndDisplays()
    }

    /// Whether the skin is drawing right now, with the real arrow hidden.
    var isDrawing: Bool { timer != nil && window.isVisible }

    /// Why the skin isn't drawing right now, or `nil` while it is.
    var whyNotDrawing: String? {
        if isDrawing { return nil }
        if tint == .system { return "no agent is talking to you" }
        if !isEnabled { return "turned off in Settings" }
        if !isAvailable { return "macOS didn't let Moonlet hide the pointer from the background" }
        if let suspendedReason { return "paused: \(suspendedReason)" }
        if paused { return "the screen is asleep or locked" }
        if timer == nil { return "not following the mouse" }
        if !arrowShowing { return "the pointer isn't the plain arrow here, or you're typing" }
        return "its window isn't on screen"
    }

    /// Whether `window` is the skin's own click-through window.
    func owns(_ window: NSWindow?) -> Bool { window === self.window }

    /// Turns the skin off for this session and hands the real arrow back at once.
    func suspend(reason: String) {
        guard suspendedReason == nil else { return }
        suspendedReason = reason
        refresh()
    }

    /// Lets a suspended skin draw again.
    func resume() {
        suspendedReason = nil
        refresh()
    }

    /// Hands the pointer back to macOS and stops drawing. Safe to call repeatedly.
    func shutdown() {
        tint = .system
        stopFollowing()
        guardian.restore()
    }

    // MARK: - State

    private func refresh() {
        guard isEnabled, isAvailable, suspendedReason == nil, let color = tint.color else {
            stopFollowing()
            return
        }
        refreshArrowIfNeeded()
        let scale = NSScreen.screens.map(\.backingScaleFactor).max() ?? 2
        let key = "\(tint.rawValue)@\(scale)x\(canvasPoints)"
        let image = imageCache[key] ?? PointerArtwork.image(color: color, points: canvasPoints, scale: scale)
        imageCache[key] = image
        CATransaction.begin()
        CATransaction.setAnimationDuration(0.25)
        artwork.contents = image
        artwork.contentsScale = scale
        CATransaction.commit()
        startFollowing()
    }

    /// Sizes the skin to the system arrow, which follows the user's pointer-size setting.
    private func refreshArrowIfNeeded() {
        guard Date().timeIntervalSince(lastArrowRefresh) > 5 else { return }
        lastArrowRefresh = Date()
        arrow = SkyLight.systemArrow()
        let points = ((arrow?.size.height ?? 40) * 1.05).rounded()
        if points != canvasPoints {
            canvasPoints = points
            imageCache.removeAll()
        }
        window.setContentSize(NSSize(width: canvasPoints, height: canvasPoints))
        artwork.frame = CGRect(x: 0, y: 0, width: canvasPoints, height: canvasPoints)
    }

    // MARK: - Following the mouse

    /// Follows on two drivers that don't depend on the display's refresh, which pauses
    /// while the screen sleeps: every mouse movement (see `pointerMoved()`), and a 60 Hz
    /// timer that keeps the skin exactly on the mouse and checks the system cursor.
    private func startFollowing() {
        guard timer == nil else { return }
        let timer = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.step() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        lastShapeCheck = 0
        step()
    }

    private func stopFollowing() {
        timer?.invalidate()
        timer = nil
        window.orderOut(nil)
        guardian.restore()
    }

    /// Moves the skin with the mouse between timer ticks.
    func pointerMoved() {
        guard timer != nil, !paused, arrowShowing, window.isVisible else { return }
        place()
    }

    private func step() {
        guardian.heartbeat()
        let now = CACurrentMediaTime()
        // Checking what the system is drawing costs a little, so do it 20 times a second.
        if now - lastShapeCheck > 0.05 {
            lastShapeCheck = now
            arrowShowing = systemShowsArrow() && !hiddenWhileTyping()
        }
        guard arrowShowing, !paused, CGDisplayIsAsleep(CGMainDisplayID()) == 0 else {
            if window.isVisible { window.orderOut(nil) }
            guardian.restore()
            return
        }
        place()
        if !window.isVisible { window.orderFrontRegardless() }
        guardian.conceal()
    }

    /// Puts the artwork's tip exactly on the mouse.
    private func place() {
        let mouse = NSEvent.mouseLocation
        let unit = canvasPoints / PointerArtwork.canvas
        let origin = NSPoint(x: mouse.x - PointerArtwork.hotSpot.x * unit,
                             y: mouse.y - (PointerArtwork.canvas - PointerArtwork.hotSpot.y) * unit)
        if window.frame.origin != origin { window.setFrameOrigin(origin) }
    }

    /// Hides the skin while the screen sleeps or the session is locked, and starts
    /// over cleanly on wake, unlock, or any display change.
    private func watchSleepAndDisplays() {
        let workspace = NSWorkspace.shared.notificationCenter
        let pausing = [NSWorkspace.screensDidSleepNotification, NSWorkspace.willSleepNotification,
                       NSWorkspace.sessionDidResignActiveNotification]
        let resuming = [NSWorkspace.screensDidWakeNotification, NSWorkspace.didWakeNotification,
                        NSWorkspace.sessionDidBecomeActiveNotification]
        for name in pausing {
            observers.append(workspace.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.setPaused(true) }
            })
        }
        for name in resuming {
            observers.append(workspace.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.setPaused(false) }
            })
        }
        observers.append(NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.restartFollowing() }
        })
    }

    private func setPaused(_ value: Bool) {
        paused = value
        if value {
            window.orderOut(nil)
            guardian.restore()
        } else {
            restartFollowing()
        }
    }

    private func restartFollowing() {
        stopFollowing()
        lastArrowRefresh = .distantPast
        refresh()
    }

    /// Whether the app under the pointer is showing the ordinary arrow.
    private func systemShowsArrow() -> Bool {
        guard let arrow, let current = NSCursor.currentSystem else { return false }
        return current.image.size == arrow.size && current.hotSpot == arrow.hotSpot
    }

    /// Mirrors macOS hiding the pointer while you type, until the mouse moves.
    private func hiddenWhileTyping() -> Bool {
        let state = CGEventSourceStateID.combinedSessionState
        let sinceKey = CGEventSource.secondsSinceLastEventType(state, eventType: .keyDown)
        let sinceMove = CGEventSource.secondsSinceLastEventType(state, eventType: .mouseMoved)
        return sinceKey < sinceMove
    }
}

/// Owns the hidden or shown state of the real pointer, and shows it again if
/// the main thread stops beating for a moment, so the user can never lose it.
final class PointerGuardian: @unchecked Sendable {
    private let lock = NSLock()
    private var hidden = false
    private var lastBeat = DispatchTime.now()
    private var timer: DispatchSourceTimer?

    func start() {
        let timer = DispatchSource.makeTimerSource(queue: .global(qos: .userInteractive))
        timer.schedule(deadline: .now(), repeating: .milliseconds(100))
        timer.setEventHandler { [weak self] in self?.check() }
        timer.resume()
        self.timer = timer
    }

    func heartbeat() {
        lock.withLock { lastBeat = .now() }
    }

    /// Hides the real pointer, once.
    func conceal() {
        lock.withLock {
            guard !hidden else { return }
            if CGDisplayHideCursor(CGMainDisplayID()) == .success { hidden = true }
        }
    }

    /// Shows the real pointer, once.
    func restore() {
        lock.withLock {
            guard hidden else { return }
            CGDisplayShowCursor(CGMainDisplayID())
            hidden = false
        }
    }

    private func check() {
        let stalled = lock.withLock { hidden && DispatchTime.now().uptimeNanoseconds - lastBeat.uptimeNanoseconds > 350_000_000 }
        if stalled { restore() }
    }
}

extension PointerTint {
    /// The pointer's fill for each tint; `nil` means the standard macOS arrow.
    var color: NSColor? {
        switch self {
        case .system: nil
        case .info: Palette.info
        case .needsYou: Palette.needsYou
        case .problem: Palette.problem
        }
    }
}
