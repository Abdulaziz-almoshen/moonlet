import Foundation
import MoonletCore

/// Serves the Moonlet protocol on the app's Unix domain socket.
///
/// The handlers are called one at a time, in the order requests arrive, from a single
/// task, so they may be `@MainActor` closures. A status request is answered only after
/// every request that arrived before it has been handled.
///
/// ```swift
/// let server = MoonletServer()
/// server.onEvent = { @MainActor event in model.apply(event) }
/// server.onStatus = { @MainActor in model.agents }
/// server.onSummon = { @MainActor in model.summon() }
/// try server.start()
/// ```
public final class MoonletServer: @unchecked Sendable {
    public typealias EventHandler = @Sendable (MoonletEvent) async -> Void
    public typealias StatusHandler = @Sendable () async -> [Agent]
    public typealias SummonHandler = @Sendable () async -> Void

    public enum Error: Swift.Error, Equatable, CustomStringConvertible {
        /// Another process already answers on the socket.
        case alreadyRunning

        public var description: String {
            "Another Moonlet process is already listening on the socket."
        }
    }

    public let paths: MoonletPaths

    private let lock = NSLock()
    // Guarded by `lock`.
    private var eventHandler: EventHandler = { _ in }
    private var statusHandler: StatusHandler = { [] }
    private var summonHandler: SummonHandler = {}
    private var running: Running?

    private struct Running {
        let hub: ConnectionHub
        let requests: AsyncStream<Request>.Continuation
        let socketPath: String
        let socketInode: ino_t
    }

    public init(paths: MoonletPaths = MoonletPaths()) {
        self.paths = paths
    }

    deinit {
        stop()
    }

    /// Called for every event.
    public var onEvent: EventHandler {
        get { lock.withLock { eventHandler } }
        set { lock.withLock { eventHandler = newValue } }
    }

    /// Supplies the agents for a status reply.
    public var onStatus: StatusHandler {
        get { lock.withLock { statusHandler } }
        set { lock.withLock { statusHandler = newValue } }
    }

    /// Called when a client asks for the summon view.
    public var onSummon: SummonHandler {
        get { lock.withLock { summonHandler } }
        set { lock.withLock { summonHandler = newValue } }
    }

    public var isRunning: Bool {
        lock.withLock { running != nil }
    }

    /// Creates the support directory and starts listening. A stale socket file left by a
    /// crashed process is replaced; if another process answers, this throws
    /// `Error.alreadyRunning`. Calling `start()` on a running server does nothing.
    public func start() throws {
        try lock.withLock {
            guard running == nil else { return }
            try paths.validateSocketPath()
            try paths.createSupportDirectory()
            let path = paths.socketURL.path
            let listener = try Listener.open(at: path)
            let (stream, requests) = AsyncStream.makeStream(of: Request.self)
            let hub = ConnectionHub(listener: listener, requests: requests)
            hub.start()
            Task { [weak self] in
                for await request in stream {
                    await self?.handle(request)
                }
            }
            running = Running(hub: hub, requests: requests, socketPath: path, socketInode: listener.inode)
        }
    }

    /// Stops listening, closes every connection, and removes the socket file.
    public func stop() {
        let stopped: Running? = lock.withLock {
            defer { running = nil }
            return running
        }
        guard let stopped else { return }
        stopped.requests.finish()
        Listener.remove(at: stopped.socketPath, ifInode: stopped.socketInode)
        stopped.hub.shutdown()
    }

    private func handle(_ request: Request) async {
        switch request {
        case .event(let event):
            await onEvent(event)
        case .summon:
            await onSummon()
        case .status(let reply):
            reply(await onStatus())
        }
    }
}

/// A decoded request waiting for the handlers.
enum Request: Sendable {
    case event(MoonletEvent)
    case summon
    case status(reply: @Sendable ([Agent]) -> Void)
}

/// The listening socket.
struct Listener {
    let fd: Int32
    let inode: ino_t

    /// Binds and listens at `path`, replacing a stale socket file.
    static func open(at path: String) throws -> Listener {
        var info = stat()
        if lstat(path, &info) == 0 {
            if UnixSocket.isAnswering(at: path) {
                throw MoonletServer.Error.alreadyRunning
            }
            unlink(path)
        }
        guard let address = UnixSocket.address(for: path) else {
            throw SystemCallError("bind", code: ENAMETOOLONG)
        }
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw SystemCallError("socket") }
        UnixSocket.configure(fd)
        guard UnixSocket.withSockaddr(address, { bind(fd, $0, $1) }) == 0 else {
            let code = errno
            close(fd)
            if code == EADDRINUSE {
                throw MoonletServer.Error.alreadyRunning
            }
            throw SystemCallError("bind", code: code)
        }
        do {
            guard chmod(path, 0o600) == 0 else { throw SystemCallError("chmod") }
            guard listen(fd, SOMAXCONN) == 0 else { throw SystemCallError("listen") }
            guard UnixSocket.setNonBlocking(fd) else { throw SystemCallError("fcntl") }
            guard lstat(path, &info) == 0 else { throw SystemCallError("lstat") }
            return Listener(fd: fd, inode: info.st_ino)
        } catch {
            close(fd)
            unlink(path)
            throw error
        }
    }

    /// Removes the socket file, unless another server has replaced it since.
    static func remove(at path: String, ifInode inode: ino_t) {
        var info = stat()
        if lstat(path, &info) == 0, info.st_ino == inode {
            unlink(path)
        }
    }
}

/// Closes a descriptor once it has been released and every dispatch source watching it
/// has finished cancelling. Only used on the hub's queue.
final class DescriptorCloser: @unchecked Sendable {
    let fd: Int32
    private var activeSources = 0
    private var released = false
    private var closed = false

    init(_ fd: Int32) {
        self.fd = fd
    }

    func watch(_ source: any DispatchSourceProtocol) {
        activeSources += 1
        source.setCancelHandler { [self] in
            activeSources -= 1
            closeIfDone()
        }
    }

    func release() {
        released = true
        closeIfDone()
    }

    private func closeIfDone() {
        guard released, activeSources == 0, !closed else { return }
        closed = true
        close(fd)
    }
}

/// Owns the listening socket and the client connections. All of its state lives on
/// `queue`; only `start()` and `shutdown()` are called from elsewhere.
final class ConnectionHub: @unchecked Sendable {
    /// Connections quiet for this long, with nothing in flight, are closed.
    static let idleTimeout: UInt64 = 60 * 1_000_000_000
    /// How many reads one wakeup may do, so a chatty client can't starve the others.
    private static let readsPerWakeup = 16

    private let queue = DispatchQueue(label: "dev.moonlet.server")
    private let listener: Listener
    private let listenerDescriptor: DescriptorCloser
    private let requests: AsyncStream<Request>.Continuation
    private var listenSource: (any DispatchSourceRead)?
    private var listenSuspended = false
    private var sweepTimer: (any DispatchSourceTimer)?
    private var connections: [UInt64: Connection] = [:]
    private var lastConnectionID: UInt64 = 0
    private var readBuffer = [UInt8](repeating: 0, count: 64 * 1024)

    init(listener: Listener, requests: AsyncStream<Request>.Continuation) {
        self.listener = listener
        self.listenerDescriptor = DescriptorCloser(listener.fd)
        self.requests = requests
    }

    func start() {
        queue.sync {
            let source = DispatchSource.makeReadSource(fileDescriptor: listener.fd, queue: queue)
            listenerDescriptor.watch(source)
            source.setEventHandler { [weak self] in self?.acceptConnections() }
            listenSource = source

            let timer = DispatchSource.makeTimerSource(queue: queue)
            timer.schedule(deadline: .now() + .seconds(15), repeating: .seconds(15), leeway: .seconds(1))
            timer.setEventHandler { [weak self] in self?.closeIdleConnections() }
            sweepTimer = timer

            source.resume()
            timer.resume()
        }
    }

    func shutdown() {
        queue.async { [self] in
            sweepTimer?.cancel()
            sweepTimer = nil
            if listenSuspended {
                listenSource?.resume()
                listenSuspended = false
            }
            listenSource?.cancel()
            listenSource = nil
            listenerDescriptor.release()
            for connection in Array(connections.values) {
                disconnect(connection)
            }
        }
    }

    // MARK: Connections

    private final class Connection {
        let id: UInt64
        let descriptor: DescriptorCloser
        var readSource: (any DispatchSourceRead)?
        var writeSource: (any DispatchSourceWrite)?
        /// The partial line received so far.
        var inbox = Data()
        /// Set while skipping the rest of a line that grew past the limit.
        var discardingLine = false
        var outbox = Data()
        var pendingReplies = 0
        var inputClosed = false
        var lastActivity: UInt64

        init(id: UInt64, fd: Int32) {
            self.id = id
            self.descriptor = DescriptorCloser(fd)
            self.lastActivity = DispatchTime.now().uptimeNanoseconds
        }

        var fd: Int32 { descriptor.fd }
    }

    private func acceptConnections() {
        while true {
            let fd = accept(listener.fd, nil, nil)
            guard fd >= 0 else {
                switch errno {
                case EINTR:
                    continue
                case EMFILE, ENFILE:
                    // Out of descriptors: back off instead of spinning on the ready listener.
                    pauseAccepting()
                default:
                    break
                }
                return
            }
            UnixSocket.configure(fd)
            guard UnixSocket.setNonBlocking(fd) else {
                Darwin.close(fd)
                continue
            }
            lastConnectionID += 1
            let connection = Connection(id: lastConnectionID, fd: fd)
            let id = connection.id
            let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
            connection.descriptor.watch(source)
            source.setEventHandler { [weak self] in self?.readAvailable(on: id) }
            connection.readSource = source
            connections[id] = connection
            source.resume()
        }
    }

    private func pauseAccepting() {
        guard let source = listenSource, !listenSuspended else { return }
        source.suspend()
        listenSuspended = true
        queue.asyncAfter(deadline: .now() + .milliseconds(100)) { [weak self] in
            guard let self, self.listenSuspended else { return }
            self.listenSuspended = false
            self.listenSource?.resume()
        }
    }

    private func readAvailable(on id: UInt64) {
        guard let connection = connections[id] else { return }
        for _ in 0..<Self.readsPerWakeup {
            let count = read(connection.fd, &readBuffer, readBuffer.count)
            if count > 0 {
                connection.lastActivity = DispatchTime.now().uptimeNanoseconds
                receive(readBuffer[..<count], on: connection)
            } else if count == 0 {
                inputEnded(on: connection)
                return
            } else if errno == EINTR {
                continue
            } else {
                if errno != EAGAIN {
                    disconnect(connection)
                }
                return
            }
        }
    }

    /// Splits incoming bytes into lines. A line longer than `Envelope.maxLineLength` is
    /// dropped up to its newline, and the connection carries on.
    private func receive(_ bytes: ArraySlice<UInt8>, on connection: Connection) {
        var rest = bytes
        while let newline = rest.firstIndex(of: 0x0A) {
            let piece = rest[..<newline]
            if connection.discardingLine {
                connection.discardingLine = false
            } else if connection.inbox.count + piece.count <= Envelope.maxLineLength {
                connection.inbox.append(contentsOf: piece)
                handle(line: connection.inbox, on: connection)
            }
            connection.inbox.removeAll(keepingCapacity: true)
            rest = rest[(newline + 1)...]
        }
        guard !connection.discardingLine else { return }
        if connection.inbox.count + rest.count > Envelope.maxLineLength {
            connection.inbox.removeAll()
            connection.discardingLine = true
        } else {
            connection.inbox.append(contentsOf: rest)
        }
    }

    private func inputEnded(on connection: Connection) {
        if !connection.discardingLine, !connection.inbox.isEmpty {
            handle(line: connection.inbox, on: connection)
        }
        connection.inbox.removeAll()
        connection.inputClosed = true
        connection.readSource?.cancel()
        connection.readSource = nil
        closeIfDone(connection)
    }

    /// Decodes one line and queues it for the handlers. Malformed lines are ignored.
    private func handle(line: Data, on connection: Connection) {
        guard let envelope = try? Envelope(line: line) else { return }
        switch envelope {
        case .event(let event):
            requests.yield(.event(event))
        case .summon:
            requests.yield(.summon)
        case .statusRequest:
            connection.pendingReplies += 1
            let id = connection.id
            requests.yield(
                .status { [weak self] agents in
                    guard let self else { return }
                    self.queue.async { self.deliver(.statusReply(agents), to: id) }
                })
        case .statusReply:
            break
        }
    }

    // MARK: Replies

    private func deliver(_ envelope: Envelope, to id: UInt64) {
        guard let connection = connections[id] else { return }
        connection.pendingReplies -= 1
        if let line = try? envelope.encodedLine() {
            connection.outbox.append(line)
        }
        flush(connection)
    }

    private func flush(_ connection: Connection) {
        while !connection.outbox.isEmpty {
            let written = connection.outbox.withUnsafeBytes { write(connection.fd, $0.baseAddress, $0.count) }
            if written > 0 {
                connection.outbox.removeFirst(written)
                connection.lastActivity = DispatchTime.now().uptimeNanoseconds
            } else if written < 0, errno == EINTR {
                continue
            } else if written < 0, errno == EAGAIN {
                awaitWritable(connection)
                return
            } else {
                disconnect(connection)
                return
            }
        }
        connection.writeSource?.cancel()
        connection.writeSource = nil
        closeIfDone(connection)
    }

    private func awaitWritable(_ connection: Connection) {
        guard connection.writeSource == nil else { return }
        let id = connection.id
        let source = DispatchSource.makeWriteSource(fileDescriptor: connection.fd, queue: queue)
        connection.descriptor.watch(source)
        source.setEventHandler { [weak self] in
            guard let self, let connection = self.connections[id] else { return }
            self.flush(connection)
        }
        connection.writeSource = source
        source.resume()
    }

    // MARK: Closing

    private func closeIfDone(_ connection: Connection) {
        if connection.inputClosed, connection.pendingReplies == 0, connection.outbox.isEmpty {
            disconnect(connection)
        }
    }

    private func disconnect(_ connection: Connection) {
        connections[connection.id] = nil
        connection.readSource?.cancel()
        connection.readSource = nil
        connection.writeSource?.cancel()
        connection.writeSource = nil
        connection.descriptor.release()
    }

    private func closeIdleConnections() {
        let now = DispatchTime.now().uptimeNanoseconds
        for connection in Array(connections.values)
        where connection.pendingReplies == 0 && now - connection.lastActivity > Self.idleTimeout {
            disconnect(connection)
        }
    }
}
