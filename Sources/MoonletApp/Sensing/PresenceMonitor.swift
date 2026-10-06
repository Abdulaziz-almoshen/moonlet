import AppKit
import CoreAudio
import CoreMediaIO
import MoonletBrain

/// Reads the user's presence from public macOS APIs. None of them prompts
/// for a permission, and none of them sees what the user types or says.
@MainActor
final class PresenceMonitor {
    /// A microphone in use this long counts as a call; shorter use is usually dictation.
    var microphoneCallThreshold: TimeInterval = 45
    /// Set to false to never hold cards for calls.
    var detectsCalls = true

    private var lastDeviceCheck = Date.distantPast
    private var cameraOn = false
    private var microphoneOnSince: Date?

    func snapshot(now: Date = Date()) -> PresenceSnapshot {
        let state = CGEventSourceStateID.combinedSessionState
        func since(_ type: CGEventType) -> TimeInterval {
            CGEventSource.secondsSinceLastEventType(state, eventType: type)
        }
        let key = since(.keyDown)
        let input = [key, since(.mouseMoved), since(.leftMouseDown), since(.rightMouseDown),
                     since(.scrollWheel), since(.leftMouseDragged)].min() ?? key
        return PresenceSnapshot(secondsSinceInput: input, secondsSinceKey: key, inCall: inCall(now: now),
                                frontmostBundleID: NSWorkspace.shared.frontmostApplication?.bundleIdentifier)
    }

    private func inCall(now: Date) -> Bool {
        guard detectsCalls else { return false }
        if now.timeIntervalSince(lastDeviceCheck) >= 2 {
            lastDeviceCheck = now
            cameraOn = Self.cameraInUse()
            if Self.microphoneInUse() {
                if microphoneOnSince == nil { microphoneOnSince = now }
            } else {
                microphoneOnSince = nil
            }
        }
        let longMicrophone = microphoneOnSince.map { now.timeIntervalSince($0) >= microphoneCallThreshold } ?? false
        return cameraOn || longMicrophone
    }

    /// Whether any app is capturing from the default input device.
    static func microphoneInUse() -> Bool {
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultInputDevice,
                                                 mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        var device = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &device) == noErr
        else { return false }
        address.mSelector = kAudioDevicePropertyDeviceIsRunningSomewhere
        var running: UInt32 = 0
        size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &running) == noErr else { return false }
        return running != 0
    }

    /// Whether any app is capturing from any camera.
    static func cameraInUse() -> Bool {
        var address = CMIOObjectPropertyAddress(mSelector: CMIOObjectPropertySelector(kCMIOHardwarePropertyDevices),
                                                mScope: CMIOObjectPropertyScope(kCMIOObjectPropertyScopeGlobal),
                                                mElement: CMIOObjectPropertyElement(kCMIOObjectPropertyElementMain))
        var size: UInt32 = 0
        guard CMIOObjectGetPropertyDataSize(CMIOObjectID(kCMIOObjectSystemObject), &address, 0, nil, &size) == 0 else { return false }
        var devices = [CMIOObjectID](repeating: 0, count: Int(size) / MemoryLayout<CMIOObjectID>.size)
        var used: UInt32 = 0
        guard CMIOObjectGetPropertyData(CMIOObjectID(kCMIOObjectSystemObject), &address, 0, nil, size, &used, &devices) == 0
        else { return false }
        return devices.contains { device in
            var running = CMIOObjectPropertyAddress(
                mSelector: CMIOObjectPropertySelector(kCMIODevicePropertyDeviceIsRunningSomewhere),
                mScope: CMIOObjectPropertyScope(kCMIOObjectPropertyScopeWildcard),
                mElement: CMIOObjectPropertyElement(kCMIOObjectPropertyElementWildcard))
            var value: UInt32 = 0
            var valueSize: UInt32 = 0
            return CMIOObjectGetPropertyData(device, &running, 0, nil, UInt32(MemoryLayout<UInt32>.size), &valueSize, &value) == 0
                && value != 0
        }
    }
}
