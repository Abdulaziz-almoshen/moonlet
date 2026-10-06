import CoreGraphics
import Darwin
import Foundation

/// The few private window-server calls Moonlet needs, resolved at runtime so a
/// missing symbol degrades the pointer skin instead of crashing the app.
enum SkyLight {
    typealias ConnectionID = Int32
    private typealias MainConnectionFn = @convention(c) () -> ConnectionID
    private typealias SetPropertyFn = @convention(c) (ConnectionID, ConnectionID, CFString, CFTypeRef) -> Int32
    private typealias CopyCursorFn = @convention(c) (
        ConnectionID, UnsafePointer<CChar>, UnsafeMutablePointer<CGSize>, UnsafeMutablePointer<CGPoint>,
        UnsafeMutablePointer<Int>, UnsafeMutablePointer<CGFloat>, UnsafeMutablePointer<Unmanaged<CFArray>?>
    ) -> Int32

    private static let libraries: [String] = [
        "/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight",
        "/System/Library/Frameworks/CoreGraphics.framework/CoreGraphics",
    ]
    private nonisolated(unsafe) static let handles: [UnsafeMutableRawPointer] = libraries.compactMap { dlopen($0, RTLD_LAZY) }

    private static func symbol<T>(_ names: [String], as _: T.Type) -> T? {
        for handle in handles {
            for name in names {
                if let pointer = dlsym(handle, name) { return unsafeBitCast(pointer, to: T.self) }
            }
        }
        return nil
    }

    private static let mainConnection = symbol(["CGSMainConnectionID", "SLSMainConnectionID"], as: MainConnectionFn.self)
    private static let setProperty = symbol(["CGSSetConnectionProperty", "SLSSetConnectionProperty"], as: SetPropertyFn.self)
    private static let copyCursor = symbol(["CGSCopyRegisteredCursorImages", "SLSCopyRegisteredCursorImages"], as: CopyCursorFn.self)

    /// Lets this background app hide the system pointer. Returns false when unsupported.
    static func allowCursorControlInBackground() -> Bool {
        guard let mainConnection, let setProperty else { return false }
        let connection = mainConnection()
        return setProperty(connection, connection, "SetsCursorInBackground" as CFString, kCFBooleanTrue) == 0
    }

    /// Size and hotspot of the system arrow as currently registered, which
    /// reflects the user's pointer-size setting.
    static func systemArrow() -> (size: CGSize, hotSpot: CGPoint)? {
        guard let mainConnection, let copyCursor else { return nil }
        var size = CGSize.zero
        var hotSpot = CGPoint.zero
        var frames = 0
        var duration: CGFloat = 0
        var images: Unmanaged<CFArray>?
        let error = "com.apple.coregraphics.Arrow".withCString {
            copyCursor(mainConnection(), $0, &size, &hotSpot, &frames, &duration, &images)
        }
        images?.release()
        guard error == 0, size.width > 0, size.height > 0 else { return nil }
        return (size, hotSpot)
    }
}
