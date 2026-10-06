import Foundation
import MoonletCore

/// Talks to the Moonlet app over its socket. Every call is bounded by a timeout, so it's
/// safe to use from hooks that must return quickly.
public enum MoonletClient {
    /// What happened to a sent event.
    public enum SendResult: Sendable, Equatable {
        /// The app received it.
        case delivered
        /// The app isn't running, so the event was appended to the spool for it to replay.
        case spooled
        /// The app couldn't be reached in time, or the event couldn't be encoded or spooled.
        case failed
    }

    /// The longest status reply accepted, in bytes.
    static let maxReplyLength = 16 * 1024 * 1024

    /// Sends an event. When nothing is listening on the socket, the event is spooled
    /// instead, unless `spoolIfUnavailable` is false. A summary too long for one line is
    /// shortened to fit.
    @discardableResult
    public static func send(
        _ event: MoonletEvent,
        paths: MoonletPaths = MoonletPaths(),
        timeout: TimeInterval = 0.3,
        spoolIfUnavailable: Bool = true
    ) -> SendResult {
        let deadline = Deadline(timeout: timeout)
        guard let (event, line) = try? fitted(event) else { return .failed }
        switch UnixSocket.connect(to: paths.socketURL.path, deadline: deadline) {
        case .success(let fd):
            defer { close(fd) }
            return UnixSocket.send(line, on: fd, deadline: deadline) ? .delivered : .failed
        case .failure(.unavailable) where spoolIfUnavailable:
            do {
                try Spool(url: paths.spoolURL).append(event)
                return .spooled
            } catch {
                return .failed
            }
        case .failure:
            return .failed
        }
    }

    /// Every agent the app knows about, or `nil` if the app can't be reached.
    public static func status(paths: MoonletPaths = MoonletPaths(), timeout: TimeInterval = 1) -> [Agent]? {
        let deadline = Deadline(timeout: timeout)
        guard let request = try? Envelope.statusRequest.encodedLine(),
            case .success(let fd) = UnixSocket.connect(to: paths.socketURL.path, deadline: deadline)
        else { return nil }
        defer { close(fd) }
        guard UnixSocket.send(request, on: fd, deadline: deadline),
            let reply = UnixSocket.receiveLine(on: fd, deadline: deadline, limit: maxReplyLength),
            case .statusReply(let agents)? = try? Envelope(line: reply)
        else { return nil }
        return agents
    }

    /// Asks the app to show its summon view. Returns whether the app received the request.
    @discardableResult
    public static func summon(paths: MoonletPaths = MoonletPaths(), timeout: TimeInterval = 0.3) -> Bool {
        let deadline = Deadline(timeout: timeout)
        guard let request = try? Envelope.summon.encodedLine(),
            case .success(let fd) = UnixSocket.connect(to: paths.socketURL.path, deadline: deadline)
        else { return false }
        defer { close(fd) }
        return UnixSocket.send(request, on: fd, deadline: deadline)
    }

    /// The event and its encoded line, with the summary shortened until the line fits.
    static func fitted(_ event: MoonletEvent) throws -> (MoonletEvent, Data) {
        var event = event
        var line = try Envelope.event(event).encodedLine()
        while line.count - 1 > Envelope.maxLineLength {
            guard let summary = event.summary, !summary.isEmpty else { throw LineTooLong() }
            // A character never encodes to fewer bytes than its UTF-8 form, so dropping
            // `overflow` bytes of text shrinks the line enough.
            let overflow = line.count - 1 - Envelope.maxLineLength
            let utf8 = summary.utf8
            var end = utf8.index(utf8.endIndex, offsetBy: -min(overflow, utf8.count))
            while end > summary.startIndex, end.samePosition(in: summary) == nil {
                end = utf8.index(before: end)
            }
            event.summary = String(summary[..<end])
            line = try Envelope.event(event).encodedLine()
        }
        return (event, line)
    }

    struct LineTooLong: Error {}
}
