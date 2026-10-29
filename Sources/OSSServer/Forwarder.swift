import Foundation
import OSSClient

#if canImport(Network)
import Network

/// A port on the server's Mac (every interface: this Mac, the LAN, the
/// tailnet) relayed to a port on a guest. Each connection is carried to the
/// guest by Apple's `/usr/bin/nc`: macOS's local network privacy refuses
/// connections to UTM's network from binaries that aren't Apple's.
///
/// With `vncPassword`, the target is a VNC server that asks for none (QEMU's,
/// on this Mac's loopback: UTM's QEMU has no DES for VNC passwords), and the
/// relay asks the client for the password itself, as a VNC server would,
/// before joining it to the target.
final class Forwarder: @unchecked Sendable {
    let port: Int
    let vncPassword: String?
    private let listener: NWListener
    private let queue: DispatchQueue
    /// Where new connections go: changed in place (a machine started again
    /// at another address), its port kept.
    private let lock = NSLock()
    private var destination: (host: String, port: Int)

    init(port: Int, target: String, targetPort: Int, vncPassword: String? = nil) throws {
        self.port = port
        destination = (target, targetPort)
        self.vncPassword = vncPassword
        let parameters = NWParameters.listening
        listener = try NWListener(using: parameters, on: NWEndpoint.Port(rawValue: UInt16(port))!)
        queue = DispatchQueue(label: "oss.forward.\(port)")
    }

    func start() {
        listener.newConnectionHandler = { [self] connection in
            let (target, targetPort) = lock.withLock { destination }
            Relay(connection: connection, target: target, port: targetPort, vncPassword: vncPassword, queue: queue).start()
        }
        listener.start(queue: queue)
    }

    /// The port it listens on, once it does (`port` 0: one the system chose).
    var boundPort: Int? { listener.port.map { Int($0.rawValue) }.flatMap { $0 == 0 ? nil : $0 } }

    func retarget(_ target: String, _ targetPort: Int) {
        lock.withLock { destination = (target, targetPort) }
    }

    func stop() {
        listener.cancel()
    }
}

/// One client connection and its `nc` to the guest. Each direction is
/// carried until its sender ends it, and its end passed on rather than
/// cutting the other short: the client's end of input closes nc's stdin, so
/// nc shuts its connection to the guest for writing and goes on reading the
/// guest's answer; the guest's end is nc's output read to its end (nc may
/// have exited by then: what it wrote is still in the pipe), sent to the
/// client after everything before it as the end of the stream. Once both
/// have ended the relay closes (a client that keeps its side open after the
/// guest's end is given `linger` to close it); either side failing closes it
/// at once. Each direction reads no more until the other side has taken what
/// it has, so a slow reader holds back its sender, not this process's memory.
private final class Relay: @unchecked Sendable {
    let connection: NWConnection
    let process = Process()
    let toGuest = Pipe()
    let fromGuest = Pipe()
    /// The connection's events, nc's output and the relay's state, in order.
    let queue: DispatchQueue
    /// nc's stdin written: a write waits while nc can't take more.
    private let writes = DispatchQueue(label: "oss.relay.write")
    let vncPassword: String?
    private var closed = false
    private var clientBuffer = Data()
    /// Each direction's end: the client's reached nc's stdin; the guest's
    /// sent to the client, after all it sent.
    private var clientEnded = false
    private var guestEnded = false
    /// nc's output as it comes, paused while the client takes the last of it.
    private var guestReads: DispatchSourceRead?
    private var guestPaused = false
    /// On `writes`: nc's stdin closed (the client's end, or nc gone, after
    /// which what the client sends has nowhere to go).
    private var stdinClosed = false

    /// How long a client keeps its side once the guest has ended theirs and
    /// it has had all the guest sent: what it sends meanwhile goes nowhere.
    static let linger: DispatchTimeInterval = .seconds(30)

    /// Relays held until they close (their handlers hold them only weakly).
    private nonisolated(unsafe) static var active: [ObjectIdentifier: Relay] = [:]
    private static let lock = NSLock()

    init(connection: NWConnection, target: String, port: Int, vncPassword: String?, queue: DispatchQueue) {
        self.connection = connection
        self.queue = queue
        self.vncPassword = vncPassword
        process.executableURL = URL(fileURLWithPath: "/usr/bin/nc")
        process.arguments = [target, String(port)]
        process.standardInput = toGuest
        process.standardOutput = fromGuest
        process.standardError = FileHandle.nullDevice
    }

    /// On `queue` (the forwarder's, whose listener hands the connection over).
    func start() {
        Relay.lock.lock(); Relay.active[ObjectIdentifier(self)] = self; Relay.lock.unlock()
        // nc's exit ends nothing by itself: its output is read to its end, and that is the guest's end.
        do { try process.run() } catch { close(); return }
        connection.stateUpdateHandler = { [weak self] state in
            switch state {
            case .failed, .cancelled: self?.close()
            default: break
            }
        }
        connection.start(queue: queue)
        if let password = vncPassword {
            // The handshake reads both sides as it goes: on a thread of its own.
            DispatchQueue.global().async {
                let joined = self.vncHandshake(password: password)
                self.queue.async { joined ? self.pipe() : self.close() }
            }
        } else {
            pipe()
        }
    }

    /// Each side's bytes to the other, on `queue`.
    private func pipe() {
        guard !closed else { return }
        if !clientBuffer.isEmpty {
            let early = clientBuffer
            clientBuffer.removeAll()
            writes.async { self.writeGuest(early) }
        }
        carryGuest()
        receive()
    }

    // MARK: VNC's password, asked of the client here

    private func readClient(_ count: Int) -> [UInt8]? {
        while clientBuffer.count < count {
            let done = DispatchSemaphore(value: 0)
            var chunk: Data?
            var ended = false
            connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { data, _, complete, error in
                chunk = data
                ended = complete || error != nil
                done.signal()
            }
            guard done.wait(timeout: .now() + 30) == .success else { return nil }
            if let chunk { clientBuffer.append(chunk) }
            if ended && clientBuffer.count < count { return nil }
        }
        let bytes = [UInt8](clientBuffer.prefix(count))
        clientBuffer.removeFirst(count)
        return bytes
    }

    private func readGuest(_ count: Int) -> [UInt8]? {
        var bytes = [UInt8]()
        while bytes.count < count {
            let chunk = fromGuest.fileHandleForReading.readData(ofLength: count - bytes.count)
            if chunk.isEmpty { return nil }
            bytes.append(contentsOf: chunk)
        }
        return bytes
    }

    private func sendClient(_ bytes: [UInt8]) { connection.send(content: Data(bytes), completion: .contentProcessed { _ in }) }
    private func sendGuest(_ bytes: [UInt8]) { try? toGuest.fileHandleForWriting.write(contentsOf: Data(bytes)) }

    /// RFB 3.8 with both sides: the guest's server offers no authentication,
    /// the client is offered VNC's (a DES challenge) and must answer it with
    /// the lease's password before anything of the guest reaches it.
    private func vncHandshake(password: String) -> Bool {
        guard readGuest(12) != nil else { return false }
        sendGuest(Array("RFB 003.008\n".utf8))
        sendClient(Array("RFB 003.008\n".utf8))
        guard readClient(12) != nil,
              let count = readGuest(1), let types = readGuest(Int(count[0])), types.contains(1) else { return false }
        sendClient([1, 2])
        guard let choice = readClient(1), choice[0] == 2 else { return false }
        let challenge = Random.bytes(16)
        sendClient(challenge)
        guard let answer = readClient(16), let expected = try? RFBScreenshot.vncResponse(challenge: challenge, password: password),
              answer == expected else {
            let reason = Array("Authentication failed".utf8)
            sendClient([0, 0, 0, 1, 0, 0, 0, UInt8(reason.count)] + reason)
            return false
        }
        sendGuest([1])
        guard let result = readGuest(4), result == [0, 0, 0, 0] else { return false }
        sendClient([0, 0, 0, 0])
        return true
    }

    // MARK: The client to the guest

    /// The client's next bytes to nc's stdin, and only then the next read;
    /// its end of input, nc's stdin closed.
    private func receive() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 256 * 1024) { [weak self] data, _, complete, error in
            guard let self, !self.closed else { return }
            if error != nil {
                self.close()
                return
            }
            self.writes.async {
                if let data, !data.isEmpty { self.writeGuest(data) }
                // nc then shuts its connection to the guest for writing, and the guest's answer still comes.
                if complete { self.closeStdin() }
                self.queue.async {
                    guard !self.closed else { return }
                    if complete {
                        self.clientEnded = true
                        self.finishIfEnded()
                    } else {
                        self.receive()
                    }
                }
            }
        }
    }

    /// On `writes`. A write that fails is nc gone (the guest closed): the
    /// client's bytes from then on are dropped.
    private func writeGuest(_ data: Data) {
        guard !stdinClosed else { return }
        if (try? toGuest.fileHandleForWriting.write(contentsOf: data)) == nil { closeStdin() }
    }

    /// On `writes`.
    private func closeStdin() {
        guard !stdinClosed else { return }
        stdinClosed = true
        try? toGuest.fileHandleForWriting.close()
    }

    // MARK: The guest to the client

    /// nc's output to the client as it comes, each piece taken by the
    /// connection before the next is read; at its end (nc gone, all of it
    /// read), the end of the stream, sent after it.
    private func carryGuest() {
        let descriptor = fromGuest.fileHandleForReading.fileDescriptor
        // An event with nothing to read (or a read racing one) waits for the next, not blocking the queue.
        _ = fcntl(descriptor, F_SETFL, fcntl(descriptor, F_GETFL) | O_NONBLOCK)
        let source = DispatchSource.makeReadSource(fileDescriptor: descriptor, queue: queue)
        source.setEventHandler { [weak self] in
            guard let self, !self.closed else { return }
            var buffer = [UInt8](repeating: 0, count: 64 * 1024)
            let count = Darwin.read(descriptor, &buffer, buffer.count)
            if count < 0, errno == EAGAIN || errno == EINTR { return }
            if count <= 0 {
                self.stopGuestReads()
                self.connection.send(content: nil, contentContext: .finalMessage, isComplete: true,
                                     completion: .contentProcessed { [weak self] error in
                    guard let self, !self.closed else { return }
                    if error != nil {
                        self.close()
                        return
                    }
                    self.guestEnded = true
                    self.finishIfEnded()
                })
                return
            }
            self.pauseGuestReads()
            self.connection.send(content: Data(buffer[0..<count]), completion: .contentProcessed { [weak self] error in
                guard let self, !self.closed else { return }
                if error != nil {
                    self.close()
                    return
                }
                self.resumeGuestReads()
            })
        }
        // Its descriptor open until the source has let it go (the pipe closes it when released).
        let handle = fromGuest.fileHandleForReading
        source.setCancelHandler { withExtendedLifetime(handle) {} }
        guestReads = source
        source.resume()
    }

    private func pauseGuestReads() {
        guard let guestReads, !guestPaused else { return }
        guestPaused = true
        guestReads.suspend()
    }

    private func resumeGuestReads() {
        guard let guestReads, guestPaused else { return }
        guestPaused = false
        guestReads.resume()
    }

    /// (A source is resumed before it's cancelled: one released suspended traps.)
    private func stopGuestReads() {
        resumeGuestReads()
        guestReads?.cancel()
        guestReads = nil
    }

    // MARK: The end

    /// Both directions ended: closed. The guest's alone: the client has all
    /// it sent and is given `linger` to close its side.
    private func finishIfEnded() {
        if clientEnded && guestEnded {
            close()
        } else if guestEnded {
            queue.asyncAfter(deadline: .now() + Self.linger) { [weak self] in self?.close() }
        }
    }

    /// On `queue`: nc ended (a write waiting on its stdin returns), the
    /// connection cancelled.
    private func close() {
        guard !closed else { return }
        closed = true
        stopGuestReads()
        if process.isRunning { process.terminate() }
        writes.async { self.closeStdin() }
        connection.cancel()
        Relay.lock.lock(); Relay.active[ObjectIdentifier(self)] = nil; Relay.lock.unlock()
    }
}

#endif
