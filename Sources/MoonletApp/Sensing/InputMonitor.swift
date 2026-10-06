import AppKit
import Carbon.HIToolbox

/// Watches pointer movement, clicks, and scrolling anywhere on screen. Mouse
/// events need no permission; Moonlet never watches the keyboard's contents.
@MainActor
final class InputMonitor {
    /// Pointer position in screen points, event time, and whether a button is held.
    var onMove: ((CGPoint, TimeInterval, Bool) -> Void)?
    /// A mouse button went down anywhere.
    var onClick: (() -> Void)?
    /// A click or scroll was delivered to one of Moonlet's own windows.
    var onLocalPress: ((NSEvent) -> Void)?
    /// A click or scroll reached any app, Moonlet included.
    var onPress: (() -> Void)?
    /// When a click or scroll last reached any app, in seconds since startup.
    private(set) var lastDeliveredPress: TimeInterval = 0

    private var monitors: [Any] = []

    func start() {
        guard monitors.isEmpty else { return }
        let moves: NSEvent.EventTypeMask = [.mouseMoved, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged]
        let presses: NSEvent.EventTypeMask = [.leftMouseDown, .rightMouseDown, .otherMouseDown, .scrollWheel]
        let move: (NSEvent) -> Void = { [weak self] event in
            MainActor.assumeIsolated {
                self?.onMove?(NSEvent.mouseLocation, event.timestamp, NSEvent.pressedMouseButtons != 0)
            }
        }
        let press: (NSEvent, Bool) -> Void = { [weak self] event, local in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.lastDeliveredPress = max(self.lastDeliveredPress, event.timestamp)
                self.onPress?()
                if local { self.onLocalPress?(event) }
                if event.type != .scrollWheel { self.onClick?() }
            }
        }
        if let monitor = NSEvent.addGlobalMonitorForEvents(matching: moves, handler: move) { monitors.append(monitor) }
        if let monitor = NSEvent.addGlobalMonitorForEvents(matching: presses, handler: { press($0, false) }) { monitors.append(monitor) }
        if let monitor = NSEvent.addLocalMonitorForEvents(matching: moves, handler: { move($0); return $0 }) { monitors.append(monitor) }
        if let monitor = NSEvent.addLocalMonitorForEvents(matching: presses, handler: { press($0, true); return $0 }) { monitors.append(monitor) }
    }

    func stop() {
        monitors.forEach(NSEvent.removeMonitor)
        monitors.removeAll()
    }
}

/// A system-wide keyboard shortcut through the Carbon hot key API, which
/// needs no Accessibility or Input Monitoring permission.
@MainActor
final class Hotkey {
    private static var handlers: [UInt32: () -> Void] = [:]
    private static var nextID: UInt32 = 1
    private static var eventHandler: EventHandlerRef?
    private var reference: EventHotKeyRef?
    private let id: UInt32

    /// Registers `keyCode` with Carbon `modifiers`, such as `controlKey | optionKey`.
    init?(keyCode: Int, modifiers: Int, action: @escaping () -> Void) {
        Self.installHandlerIfNeeded()
        id = Self.nextID
        Self.nextID += 1
        let hotKeyID = EventHotKeyID(signature: OSType(0x4D4E4C54), id: id) // "MNLT"
        var reference: EventHotKeyRef?
        guard RegisterEventHotKey(UInt32(keyCode), UInt32(modifiers), hotKeyID, GetApplicationEventTarget(), 0, &reference) == noErr
        else { return nil }
        self.reference = reference
        Self.handlers[id] = action
    }

    func unregister() {
        if let reference { UnregisterEventHotKey(reference) }
        reference = nil
        Self.handlers[id] = nil
    }

    private static func installHandlerIfNeeded() {
        guard eventHandler == nil else { return }
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ in
            var hotKeyID = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil,
                              MemoryLayout<EventHotKeyID>.size, nil, &hotKeyID)
            let id = hotKeyID.id
            DispatchQueue.main.async { MainActor.assumeIsolated { Hotkey.handlers[id]?() } }
            return noErr
        }, 1, &spec, nil, &eventHandler)
    }
}
