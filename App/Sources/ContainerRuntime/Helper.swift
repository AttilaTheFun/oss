import Containerization
import ContainerizationOS
import Foundation
import Network
import OSSClient
import OSSServer
import vmnet

/// A container's helper (`oss-machine container <helper.json>`): it boots the
/// container's VM (Apple's Containerization, in this process), runs its
/// commands as they come on its Unix socket, and stops it on TERM. A launchd
/// job of OS Server's, not OS Server's child: the container and its
/// commands go on while OS Server quits, restarts or is updated.
@available(macOS 26, *)
public enum ContainerHelper {
    public static func main(_ arguments: [String]) async -> Never {
        guard arguments.count == 2, let data = FileManager.default.contents(atPath: arguments[1]),
              let spec = try? JSONDecoder().decode(HelperSpec.self, from: data) else {
            say("oss-machine container <helper.json>: no spec to run")
            exit(2)
        }
        let directory = URL(fileURLWithPath: arguments[1]).deletingLastPathComponent()
        do {
            let running = try await boot(spec, directory: directory)
            say("\(spec.name): running")
            let server = try ExecServer(running: running, socket: spec.socket)
            server.start()
            // TERM (launchd's bootout, the Mac shutting down): stopped, then gone.
            for signal in [SIGTERM, SIGINT] {
                Foundation.signal(signal, SIG_IGN)
                let source = DispatchSource.makeSignalSource(signal: signal, queue: .main)
                source.setEventHandler {
                    Task {
                        say("\(spec.name): stopping")
                        try? await running.container.stop()
                        exit(0)
                    }
                }
                source.resume()
                Sources.kept.append(source)
            }
            let status = try await running.container.wait()
            say("\(spec.name): its main process ended (\(status.exitCode))")
            try? await running.container.stop()
            exit(0)
        } catch {
            say("\(spec.name): \(error)")
            exit(1)
        }
    }

    private enum Sources { nonisolated(unsafe) static var kept: [DispatchSourceSignal] = [] }

    static func say(_ message: String) {
        let stamp = ISO8601DateFormatter().string(from: Date())
        FileHandle.standardError.write(Data("\(stamp) \(message)\n".utf8))
    }

    /// The container made and started, from its root filesystem as it is
    /// (the image's, cloned, or what it was left as before a restart).
    static func boot(_ spec: HelperSpec, directory: URL) async throws -> RunningContainer {
        let vmm = VZVirtualMachineManager(kernel: Kernel(path: URL(fileURLWithPath: spec.kernel), platform: .linuxArm),
                                          initialFilesystem: .block(format: "ext4", source: spec.initfs, destination: "/", options: ["ro"]),
                                          rosetta: spec.rosetta)
        // On OS Server's one containers' network (shared, NAT, with the
        // Mac's), from its owner: the container's address and card, kept
        // for it across restarts, and the network's serialization. Never
        // a network of the helper's own (made and taken down with each
        // container, as before 0.14, those broke their neighbours'
        // bridges): with no owner answering, the container doesn't start.
        let attachment = try await NetworkOwnerClient.attach(name: spec.name, socket: spec.network ?? ContainerNetwork.socket)
        let network = try SharedVmnet.attach(attachment.serialization)
        let interface = try SharedVmnet.interface(attachment, network: network)
        var config = LinuxContainer.Configuration()
        if let image = spec.image { config.process = LinuxProcessConfiguration(from: image) }
        // Its address, for OS Server to forward the lease's ports to: written
        // before its socket answers, written again each time it starts.
        let addressFile = directory.appendingPathComponent(HelperSpec.addressFile)
        try? FileManager.default.removeItem(at: addressFile)
        config.interfaces = [interface]
        // vmnet's DNS proxy, on the Mac's address.
        config.dns = DNS(nameservers: [attachment.gateway])
        try? Data(attachment.address.utf8).write(to: addressFile, options: .atomic)
        say("\(spec.name): \(attachment.cidr) on the containers' network \(attachment.subnet)")
        config.cpus = spec.cpus
        config.memoryInBytes = UInt64(spec.memoryBytes)
        config.hostname = spec.name
        // Signals forwarded, zombies reaped: what runs in it may start many processes.
        config.useInit = true
        for mount in spec.mounts {
            config.mounts.append(.share(source: mount.source, destination: mount.destination, options: mount.readOnly ? ["ro"] : []))
        }
        for volume in spec.volumes {
            config.mounts.append(.block(format: "ext4", source: volume.path, destination: volume.destination))
        }
        config.process.environmentVariables = HelperSpec.merged(config.process.environmentVariables, spec.environment)
        if let directory = spec.workingDirectory { config.process.workingDirectory = directory }
        config.process.arguments = spec.command ?? HelperSpec.waits
        config.bootLog = .file(path: directory.appendingPathComponent("boot.log"), append: false)
        let container = try LinuxContainer(spec.name, rootfs: .block(format: "ext4", source: spec.rootfs, destination: "/"),
                                           vmm: vmm, configuration: config)
        try await container.create()
        try await container.start()
        return RunningContainer(container: container, process: config.process, network: network)
    }
}

/// A running container, and its main process's settings, which each
/// command starts from (the image's environment and the lease's, its
/// working directory).
@available(macOS 26, *)
struct RunningContainer: Sendable {
    let container: LinuxContainer
    let process: LinuxProcessConfiguration
    /// Kept for the container's life: its reference to the containers'
    /// network (the owner's; this one going takes nothing down).
    nonisolated(unsafe) let network: vmnet_network_ref
}

/// The container's commands: one a connection, its `ExecFrame`s both ways.
/// A connection that closes before its command ends ends it: TERM, then
/// KILL ten seconds on.
@available(macOS 26, *)
final class ExecServer: Sendable {
    private let listener: NWListener
    private let running: RunningContainer
    private let queue = DispatchQueue(label: "oss-container.exec")

    init(running: RunningContainer, socket: String) throws {
        self.running = running
        let folder = (socket as NSString).deletingLastPathComponent
        try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try? FileManager.default.removeItem(atPath: socket)
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .unix(path: socket)
        listener = try NWListener(using: parameters)
    }

    func start() {
        listener.newConnectionHandler = { [self] connection in
            connection.start(queue: queue)
            Task { await serve(FrameConnection(connection)) }
        }
        listener.start(queue: queue)
    }

    private func serve(_ connection: FrameConnection) async {
        defer { connection.close() }
        // Its first frame says what to run (a connection that only checks the socket says nothing).
        guard case .start(let request)? = await connection.next() else { return }
        var config = running.process
        config.arguments = request.arguments
        var environment = request.environment
        // A terminal's size reaches it just after it starts (Containerization starts
        // it before a resize can): what reads it at once reads these.
        if request.tty, let columns = request.columns, let rows = request.rows {
            environment["COLUMNS"] = environment["COLUMNS"] ?? "\(columns)"
            environment["LINES"] = environment["LINES"] ?? "\(rows)"
        }
        config.environmentVariables = HelperSpec.merged(config.environmentVariables, environment)
        if let directory = request.workingDirectory { config.workingDirectory = directory }
        config.terminal = request.tty
        let stdin = StdinStream()
        config.stdin = stdin
        // Each write waits until the client has taken it: a slow reader holds
        // the command's writes back (its pipe fills), nothing is dropped.
        config.stdout = FrameWriter { connection.sendWaiting(.stdout($0)) }
        // A terminal's output is one stream.
        config.stderr = request.tty ? nil : FrameWriter { connection.sendWaiting(.stderr($0)) }
        let process: LinuxProcess
        do {
            process = try await running.container.exec("exec-\(UUID().uuidString.prefix(8).lowercased())", configuration: config)
            try await process.start()
        } catch {
            connection.send(.stderr(Data("oss: \(error)\n".utf8)))
            connection.send(.exit(126))
            return
        }
        if request.tty, let columns = request.columns, let rows = request.rows {
            try? await process.resize(to: Terminal.Size(width: UInt16(clamping: columns), height: UInt16(clamping: rows)))
        }
        // The client's side: stdin, its end, a terminal's new size, signals; or its going.
        let pump = Task {
            while let frame = await connection.next() {
                switch frame {
                case .stdin(let data): stdin.continuation.yield(data)
                case .closeStdin: stdin.continuation.finish()
                case .resize(let columns, let rows):
                    try? await process.resize(to: Terminal.Size(width: UInt16(clamping: columns), height: UInt16(clamping: rows)))
                case .signal(let number): try? await process.kill(Signal(rawValue: number))
                default: break
                }
            }
            guard !Task.isCancelled else { return }
            stdin.continuation.finish()
            try? await process.kill(.term)
            try? await Task.sleep(for: .seconds(10))
            guard !Task.isCancelled else { return }
            try? await process.kill(.kill)
        }
        let status = (try? await process.wait())?.exitCode ?? 137
        pump.cancel()
        stdin.continuation.finish()
        await connection.sendAndWait(.exit(status))
        try? await process.delete()
    }
}

/// A connection's frames, awaited, and frames sent in order.
final class FrameConnection: @unchecked Sendable {
    private let connection: NWConnection
    private var buffer = Data()
    private var pending: [ExecFrame] = []

    init(_ connection: NWConnection) { self.connection = connection }

    /// The next frame from the client; nil once it has gone.
    func next() async -> ExecFrame? {
        while pending.isEmpty {
            guard let data = await receive() else { return nil }
            buffer.append(data)
            pending += ExecFrame.decode(&buffer)
        }
        return pending.removeFirst()
    }

    private func receive() async -> Data? {
        await withCheckedContinuation { continuation in
            connection.receive(minimumIncompleteLength: 1, maximumLength: 1 << 20) { data, _, complete, error in
                if let data, !data.isEmpty { continuation.resume(returning: data) }
                else if complete || error != nil { continuation.resume(returning: nil) }
                else { continuation.resume(returning: Data()) }
            }
        }
    }

    func send(_ frame: ExecFrame) {
        connection.send(content: frame.encoded, completion: .idempotent)
    }

    /// Sent, and returns once the connection has taken it (or gone): on
    /// the output relay's own queue, where waiting holds the command back.
    func sendWaiting(_ frame: ExecFrame) {
        let sent = DispatchSemaphore(value: 0)
        connection.send(content: frame.encoded, completion: .contentProcessed { _ in sent.signal() })
        sent.wait()
    }

    func sendAndWait(_ frame: ExecFrame) async {
        await withCheckedContinuation { continuation in
            connection.send(content: frame.encoded, completion: .contentProcessed { _ in continuation.resume() })
        }
    }

    func close() { connection.cancel() }
}

/// A command's stdin: what the client sends, as it comes.
final class StdinStream: ReaderStream {
    let (input, continuation) = AsyncStream<Data>.makeStream()
    func stream() -> AsyncStream<Data> { input }
}

final class FrameWriter: Writer {
    let write: @Sendable (Data) -> Void
    init(_ write: @escaping @Sendable (Data) -> Void) { self.write = write }
    func write(_ data: Data) throws { write(data) }
    func close() throws {}
}
