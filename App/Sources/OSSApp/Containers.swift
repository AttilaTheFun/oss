import Containerization
import ContainerizationArchive
import ContainerizationOCI
import ContainerizationOS
import CryptoKit
import Foundation
import OSSClient
import OSSServer

/// OS Server's containers: Linux, each in a lightweight VM of its own, on
/// Apple's Containerization, run in this process (so quitting the app ends
/// them, as it ends its macOS VMs). Everything is in the server's
/// Containers folder: the kernel (downloaded once), the init filesystem and
/// the images it pulls, and each container's root filesystem while it runs.
@available(macOS 26, *)
actor ContainerEngine: ContainerBackend {
    /// Containerization's guest init, the version of the package built in.
    static let initfs = "ghcr.io/apple/containerization/vminit:0.33.3"
    /// What a container runs when its lease names nothing: a process that
    /// waits, so commands are run in it with exec.
    static let waits = ["/bin/sh", "-c", "trap 'exit 0' TERM INT; while :; do sleep 86400 & wait $!; done"]

    private let root = URL(fileURLWithPath: ServerHost.containersDirectory)
    private var manager: ContainerManager?
    private var running: [String: Running] = [:]
    /// Starts and stops one at a time: the manager is a value (its network's
    /// addresses), changed by each.
    private var busy = false
    private var waiting: [CheckedContinuation<Void, Never>] = []

    private struct Running {
        let container: LinuxContainer
        /// Its main process's, which each exec starts from (the image's
        /// environment and the lease's, its working directory).
        let process: LinuxProcessConfiguration
    }

    private func exclusively<T: Sendable>(_ work: () async throws -> T) async throws -> T {
        while busy { await withCheckedContinuation { waiting.append($0) } }
        busy = true
        defer {
            busy = false
            if !waiting.isEmpty { waiting.removeFirst().resume() }
        }
        return try await work()
    }

    /// The manager, made the first time a container is asked for: the
    /// kernel fetched if this Mac hasn't it, the init filesystem pulled.
    private func ready() async throws -> ContainerManager {
        if let manager { return manager }
        let kernel = try await ContainerKernel.ensure(in: root)
        let made = try await ContainerManager(kernel: Kernel(path: kernel, platform: .linuxArm), initfsReference: Self.initfs,
                                              root: root, network: try VmnetNetwork())
        manager = made
        return made
    }

    func start(name: String, spec: ContainerSpec) async throws {
        try await exclusively {
            var manager = try await ready()
            let reference = try Self.qualified(spec.image)
            ServerLog.write("container \(name): \(reference)")
            let image = try await manager.imageStore.get(reference: reference, pull: true)
            let captured = Captured()
            let container = try await manager.create(name, image: image,
                                                     rootfsSizeInBytes: UInt64(spec.diskBytes ?? ContainerDefaults.diskBytes)) { config in
                config.cpus = spec.cpus ?? ContainerDefaults.cpus
                config.memoryInBytes = UInt64(spec.memoryBytes ?? ContainerDefaults.memoryBytes)
                config.hostname = name
                // Signals forwarded, zombies reaped: what runs in it may start many processes.
                config.useInit = true
                for mount in spec.mounts {
                    config.mounts.append(.share(source: mount.source, destination: mount.destination, options: mount.readOnly ? ["ro"] : []))
                }
                config.process.environmentVariables = Self.merged(config.process.environmentVariables, spec.environment)
                if let directory = spec.workingDirectory { config.process.workingDirectory = directory }
                config.process.arguments = spec.command ?? Self.waits
                captured.process = config.process
            }
            self.manager = manager
            do {
                try await container.create()
                try await container.start()
            } catch {
                try? await container.stop()
                try? self.manager?.delete(name)
                throw error
            }
            running[name] = Running(container: container, process: captured.process)
        }
    }

    func exec(name: String, request: ExecRequest, session: ExecSession) async throws -> Int32 {
        guard let running = running[name] else { throw APIError(error: "no container \(name)") }
        var config = running.process
        config.arguments = request.arguments
        var environment = request.environment
        // The terminal's size reaches it just after it starts (Containerization
        // starts it before a resize can): what reads it at once reads these.
        if request.tty, let columns = request.columns, let rows = request.rows {
            environment["COLUMNS"] = environment["COLUMNS"] ?? "\(columns)"
            environment["LINES"] = environment["LINES"] ?? "\(rows)"
        }
        config.environmentVariables = Self.merged(config.environmentVariables, environment)
        if let directory = request.workingDirectory { config.workingDirectory = directory }
        config.terminal = request.tty
        let stdin = SessionStdin()
        config.stdin = stdin
        config.stdout = SessionWriter { session.stdout($0) }
        // A terminal's output is one stream.
        config.stderr = request.tty ? nil : SessionWriter { session.stderr($0) }
        let process = try await running.container.exec("exec-\(Random.id())", configuration: config)
        try await process.start()
        if request.tty, let columns = request.columns, let rows = request.rows {
            try? await process.resize(to: Terminal.Size(width: UInt16(clamping: columns), height: UInt16(clamping: rows)))
        }
        // The client's side: stdin, its end, a terminal's new size.
        let pump = Task {
            for await frame in session.input {
                switch frame {
                case .stdin(let data): stdin.continuation.yield(data)
                case .closeStdin: stdin.continuation.finish()
                case .resize(let columns, let rows):
                    try? await process.resize(to: Terminal.Size(width: UInt16(clamping: columns), height: UInt16(clamping: rows)))
                default: break
                }
            }
            stdin.continuation.finish()
        }
        let status = try await process.wait()
        pump.cancel()
        stdin.continuation.finish()
        try? await process.delete()
        return status.exitCode
    }

    func stop(name: String) async {
        _ = try? await exclusively {
            if let running = running.removeValue(forKey: name) {
                do { try await running.container.stop() } catch { ServerLog.write("container \(name): stopping: \(error)") }
            }
            do {
                try manager?.delete(name)
            } catch {
                // Its folder, though the manager never knew it (a container from before a restart).
                try? FileManager.default.removeItem(atPath: directory(name: name) ?? "")
            }
        }
    }

    func removeAll() async {
        let containers = root.appendingPathComponent("containers")
        for name in (try? FileManager.default.contentsOfDirectory(atPath: containers.path)) ?? [] where running[name] == nil {
            ServerLog.write("deleting container \(name): no lease holds it")
            try? FileManager.default.removeItem(at: containers.appendingPathComponent(name))
        }
    }

    nonisolated func directory(name: String) -> String? {
        root.appendingPathComponent("containers").appendingPathComponent(name).path
    }

    /// `alpine:3.20` as `docker.io/library/alpine:3.20`, as Docker reads it.
    static func qualified(_ image: String) throws -> String {
        let first = image.split(separator: "/").first.map(String.init) ?? image
        let hasDomain = image.contains("/") && (first.contains(".") || first.contains(":") || first == "localhost")
        let reference = try Reference.parse(hasDomain ? image : "docker.io/\(image)")
        reference.normalize()
        return reference.description
    }

    /// `NAME=VALUE`s with `extra` set over them.
    static func merged(_ list: [String], _ extra: [String: String]) -> [String] {
        guard !extra.isEmpty else { return list }
        let kept = list.filter { entry in !extra.keys.contains(String(entry.split(separator: "=", maxSplits: 1).first ?? "")) }
        return kept + extra.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }
    }
}

/// The configuration's process as made, out of its closure.
private final class Captured: @unchecked Sendable {
    var process = LinuxProcessConfiguration()
}

/// An exec's stdin: what the client sends, as it comes.
private final class SessionStdin: ReaderStream {
    let (input, continuation) = AsyncStream<Data>.makeStream()
    func stream() -> AsyncStream<Data> { input }
}

private final class SessionWriter: Writer {
    let write: @Sendable (Data) -> Void
    init(_ write: @escaping @Sendable (Data) -> Void) { self.write = write }
    func write(_ data: Data) throws { write(data) }
    func close() throws {}
}

private enum Random {
    static func id() -> String { String(UUID().uuidString.prefix(8)).lowercased() }
}

/// The Linux kernel containers boot: Kata Containers' build for arm64, as
/// Apple's `container` uses, fetched from its release once and kept in the
/// Containers folder (`kernel/vmlinux`).
enum ContainerKernel {
    static let release = URL(string: "https://github.com/kata-containers/kata-containers/releases/download/3.32.0/kata-static-3.32.0-arm64.tar.zst")!
    static let digest = "8736c054d9223974735394f822000823baef509e1c33405ec798240fa9b6e4b5"
    static let member = "opt/kata/share/kata-containers/vmlinux-6.18.35-197-debug"

    static func ensure(in root: URL) async throws -> URL {
        let kernel = root.appendingPathComponent("kernel/vmlinux")
        if FileManager.default.fileExists(atPath: kernel.path) { return kernel }
        ServerLog.write("containers: fetching the Linux kernel (Kata Containers 3.32.0)")
        let (download, _) = try await URLSession.shared.download(from: release)
        defer { try? FileManager.default.removeItem(at: download) }
        let handle = try FileHandle(forReadingFrom: download)
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 1 << 22), !chunk.isEmpty { hasher.update(data: chunk) }
        try handle.close()
        let found = hasher.finalize().map { String(format: "%02x", $0) }.joined()
        guard found == digest else { throw APIError(error: "the kernel's archive isn't the one expected (sha256 \(found))") }
        let reader = try ArchiveReader(file: download)
        var data: Data?
        for path in [member, "./" + member] where data == nil { data = try? reader.extractFile(path: path).1 }
        guard let data else { throw APIError(error: "no \(member) in the kernel's archive") }
        try FileManager.default.createDirectory(at: kernel.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: kernel, options: .atomic)
        ServerLog.write("containers: kernel at \(kernel.path)")
        return kernel
    }
}
