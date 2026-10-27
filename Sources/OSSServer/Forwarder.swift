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

    func retarget(_ target: String, _ targetPort: Int) {
        lock.withLock { destination = (target, targetPort) }
    }

    func stop() {
        listener.cancel()
    }
}

/// One client connection and its `nc` to the guest, each fed from the other
/// until either side closes.
private final class Relay: @unchecked Sendable {
    let connection: NWConnection
    let process = Process()
    let toGuest = Pipe()
    let fromGuest = Pipe()
    let queue: DispatchQueue
    let vncPassword: String?
    private var closed = false
    private var clientBuffer = Data()

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

    func start() {
        Relay.lock.lock(); Relay.active[ObjectIdentifier(self)] = self; Relay.lock.unlock()
        process.terminationHandler = { [weak self] _ in self?.queue.async { self?.close() } }
        do { try process.run() } catch { close(); return }
        connection.stateUpdateHandler = { [weak self] state in
            switch state {
            case .failed, .cancelled: self?.queue.async { self?.close() }
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

    /// Each side's bytes to the other until either closes.
    private func pipe() {
        guard !closed else { return }
        if !clientBuffer.isEmpty {
            guard (try? toGuest.fileHandleForWriting.write(contentsOf: clientBuffer)) != nil else { close(); return }
            clientBuffer.removeAll()
        }
        fromGuest.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard let self else { return }
            if data.isEmpty {
                // The guest closed: what was sent goes out first, then the client's side closes.
                handle.readabilityHandler = nil
                self.connection.send(content: nil, contentContext: .finalMessage, isComplete: true,
                                     completion: .contentProcessed { _ in self.queue.async { self.close() } })
                return
            }
            self.connection.send(content: data, completion: .contentProcessed { _ in })
        }
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

    private func receive() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 256 * 1024) { [weak self] data, _, complete, error in
            guard let self else { return }
            if let data, !data.isEmpty {
                // The relay gone (the guest closed its side): the client's side closes too.
                guard (try? self.toGuest.fileHandleForWriting.write(contentsOf: data)) != nil else {
                    self.close()
                    return
                }
            }
            if complete || error != nil {
                self.close()
            } else {
                self.receive()
            }
        }
    }

    private func close() {
        guard !closed else { return }
        closed = true
        try? toGuest.fileHandleForWriting.close()
        if process.isRunning { process.terminate() }
        fromGuest.fileHandleForReading.readabilityHandler = nil
        connection.cancel()
        Relay.lock.lock(); Relay.active[ObjectIdentifier(self)] = nil; Relay.lock.unlock()
    }
}

#endif
