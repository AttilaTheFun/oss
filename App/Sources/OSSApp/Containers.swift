import ContainerRuntime
import Containerization
import ContainerizationArchive
import ContainerizationEXT4
import ContainerizationOCI
import CryptoKit
import Foundation
import OSSClient
import OSSServer
import SystemPackage
import Virtualization

/// OS Server's containers. Each runs in a helper of its own
/// (`Contents/Helpers/oss-machine container`, a launchd job: ContainerHelper), so a
/// container and its commands go on while OS Server quits, restarts or is
/// updated; OS Server finds them again when it starts, and starts again
/// from its disk one the Mac's restart stopped. Everything is in the
/// server's Containers folder:
///
///   kernel/vmlinux          the Linux kernel (downloaded once)
///   initfs.ext4, content/   Containerization's init filesystem and the images it pulled
///   templates/<digest>-<GiB>.ext4   an image's root filesystem, unpacked once, cloned for each container
///   containers/<name>/      a container: rootfs.ext4 (the clone), helper.json, its launchd job, logs
///   volumes/<name>.ext4     named volumes (and <name>.json, the size asked for)
///
/// Its commands' sockets are in the user's temporary folder (`oss/`): a
/// Unix socket's path has at most 104 bytes.
@available(macOS 26, *)
actor ContainerEngine: ContainerBackend {
    /// Containerization's guest init, the version of the package built in.
    static let initfs = "ghcr.io/apple/containerization/vminit:0.33.3"

    private let root = URL(fileURLWithPath: ServerHost.containersDirectory)
    private let helper: String
    /// The image store and the init filesystem (no network: each helper has its own).
    private var store: ContainerManager?
    private var busy = false
    private var waiting: [CheckedContinuation<Void, Never>] = []

    init(helper: String = Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/oss-machine").path) {
        self.helper = helper
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

    /// The store, made the first time a container is asked for: the kernel
    /// fetched if this Mac hasn't it, the init filesystem pulled.
    private func prepared() async throws -> ContainerManager {
        try await exclusively {
            if let store { return store }
            _ = try await ContainerKernel.ensure(in: root)
            let made = try await ContainerManager(kernel: Kernel(path: kernelPath, platform: .linuxArm), initfsReference: Self.initfs,
                                                  root: root, network: nil)
            store = made
            return made
        }
    }

    private var kernelPath: URL { root.appendingPathComponent("kernel/vmlinux") }
    private func folder(_ name: String) -> URL { root.appendingPathComponent("containers").appendingPathComponent(name) }
    private nonisolated func label(_ name: String) -> String { "oss.container.\(name)" }
    private nonisolated func socket(_ name: String) -> String { HelperSocket.path(name) }

    // MARK: ContainerBackend

    func start(name: String, spec: ContainerSpec) async throws -> String {
        if spec.rosetta, VZLinuxRosettaDirectoryShare.availability != .installed {
            throw APIError(error: "Rosetta isn't installed on this Mac (softwareupdate --install-rosetta)")
        }
        let manager = try await prepared()
        let reference = try Self.qualified(spec.image)
        ServerLog.write("container \(name): \(reference)")
        let image = try await manager.imageStore.get(reference: reference, pull: true)
        let config = try await image.config(for: .current).config
        let template = try await self.template(image, sizeBytes: UInt64(spec.diskBytes ?? ContainerDefaults.diskBytes))
        let directory = folder(name)
        try? FileManager.default.removeItem(at: directory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        // A clone (APFS): instant, and only what the container writes takes room.
        let rootfs = directory.appendingPathComponent("rootfs.ext4")
        try FileManager.default.copyItem(at: template, to: rootfs)
        let volumes = try spec.volumes.map { try volume($0) }
        let helperSpec = HelperSpec(name: name, kernel: kernelPath.path, initfs: root.appendingPathComponent("initfs.ext4").path,
                                    rootfs: rootfs.path, socket: socket(name), cpus: spec.cpus ?? ContainerDefaults.cpus,
                                    memoryBytes: spec.memoryBytes ?? ContainerDefaults.memoryBytes, rosetta: spec.rosetta,
                                    mounts: spec.mounts, volumes: volumes, image: config, environment: spec.environment,
                                    workingDirectory: spec.workingDirectory, command: spec.command)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(helperSpec).write(to: directory.appendingPathComponent("helper.json"))
        return try await launch(name)
    }

    func reattach(name: String, spec: ContainerSpec) async -> String? {
        if isAnswering(name) { return socket(name) }
        let directory = folder(name)
        guard FileManager.default.fileExists(atPath: directory.appendingPathComponent("helper.json").path),
              FileManager.default.fileExists(atPath: directory.appendingPathComponent("rootfs.ext4").path) else { return nil }
        // Started again from its disk: the Mac restarted, or its helper ended.
        do { return try await launch(name) } catch {
            ServerLog.write("container \(name): starting it again failed: \(error)")
            return nil
        }
    }

    func isRunning(name: String) async -> Bool { isAnswering(name) }

    func stop(name: String, spec: ContainerSpec?) async {
        await bootout(name)
        try? FileManager.default.removeItem(at: folder(name))
        try? FileManager.default.removeItem(atPath: socket(name))
        for volume in spec?.volumes ?? [] where !volume.keep {
            try? deleteVolumeFiles(volume.name)
        }
    }

    func prune(keeping: Set<String>) async {
        let containers = root.appendingPathComponent("containers")
        for name in (try? FileManager.default.contentsOfDirectory(atPath: containers.path)) ?? [] where !keeping.contains(name) {
            ServerLog.write("deleting container \(name): no lease holds it")
            await bootout(name)
            try? FileManager.default.removeItem(at: containers.appendingPathComponent(name))
            try? FileManager.default.removeItem(atPath: socket(name))
        }
        // Unpacked images no container was made from in two weeks (a container's clone doesn't need its template).
        let templates = root.appendingPathComponent("templates")
        for file in (try? FileManager.default.contentsOfDirectory(atPath: templates.path)) ?? [] {
            let url = templates.appendingPathComponent(file)
            let used = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
            if Date().timeIntervalSince(used) > 14 * 86400 || file.contains(".partial.") {
                ServerLog.write("containers: deleting \(file), unused since \(used)")
                try? FileManager.default.removeItem(at: url)
            }
        }
    }

    nonisolated func directory(name: String) -> String? {
        URL(fileURLWithPath: ServerHost.containersDirectory).appendingPathComponent("containers").appendingPathComponent(name).path
    }

    func volumes() async -> [VolumeInfo] {
        let folder = root.appendingPathComponent("volumes")
        return ((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []).filter { $0.hasSuffix(".ext4") }.sorted().map { file in
            let name = String(file.dropLast(5))
            let url = folder.appendingPathComponent(file)
            let allocated = (try? url.resourceValues(forKeys: [.totalFileAllocatedSizeKey]))?.totalFileAllocatedSize ?? 0
            return VolumeInfo(name: name, sizeBytes: volumeSize(name) ?? 0, allocatedBytes: Int64(allocated))
        }
    }

    func deleteVolume(name: String) async throws {
        guard FileManager.default.fileExists(atPath: volumePath(name).path) else { throw APIError(error: "no volume \(name)") }
        try deleteVolumeFiles(name)
    }

    func prepare() async throws { _ = try await prepared() }

    func isPrepared() async -> Bool {
        FileManager.default.fileExists(atPath: kernelPath.path)
            && FileManager.default.fileExists(atPath: root.appendingPathComponent("initfs.ext4").path)
    }

    func removeEverything() async {
        await prune(keeping: [])
        store = nil
        try? FileManager.default.removeItem(at: root)
    }

    // MARK: Images, volumes, helpers

    /// An image's root filesystem at a size, unpacked once (a big image takes
    /// a while) and kept by its digest.
    private func template(_ image: Containerization.Image, sizeBytes: UInt64) async throws -> URL {
        let digest = image.digest.replacingOccurrences(of: "sha256:", with: "")
        let gibibytes = (sizeBytes + (1 << 30) - 1) >> 30
        let templates = root.appendingPathComponent("templates")
        let template = templates.appendingPathComponent("\(digest)-\(gibibytes).ext4")
        return try await exclusively {
            if FileManager.default.fileExists(atPath: template.path) {
                // Its last use, for pruning: an image no container has been made from in two weeks goes.
                try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: template.path)
                return template
            }
            try FileManager.default.createDirectory(at: templates, withIntermediateDirectories: true)
            let partial = templates.appendingPathComponent("\(digest)-\(gibibytes).partial.ext4")
            try? FileManager.default.removeItem(at: partial)
            ServerLog.write("containers: unpacking \(image.reference) (\(gibibytes) GiB)")
            _ = try await EXT4Unpacker(blockSizeInBytes: gibibytes << 30).unpack(image, for: .current, at: partial)
            try FileManager.default.moveItem(at: partial, to: template)
            return template
        }
    }

    private func volumePath(_ name: String) -> URL { root.appendingPathComponent("volumes/\(name).ext4") }
    private func volumeSidecar(_ name: String) -> URL { root.appendingPathComponent("volumes/\(name).json") }

    private func volumeSize(_ name: String) -> Int64? {
        FileManager.default.contents(atPath: volumeSidecar(name).path)
            .flatMap { try? JSONDecoder().decode([String: Int64].self, from: $0)["sizeBytes"] }
    }

    /// A volume of that size: the one there, or made (empty) when there's
    /// none or it was another size.
    private func volume(_ volume: ContainerVolume) throws -> HelperSpec.Volume {
        let path = volumePath(volume.name)
        if FileManager.default.fileExists(atPath: path.path), volumeSize(volume.name) == volume.sizeBytes {
            return HelperSpec.Volume(path: path.path, destination: volume.destination)
        }
        try? deleteVolumeFiles(volume.name)
        try FileManager.default.createDirectory(at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
        let formatter = try EXT4.Formatter(FilePath(path.path), minDiskSize: UInt64(volume.sizeBytes))
        try formatter.close()
        try JSONEncoder().encode(["sizeBytes": volume.sizeBytes]).write(to: volumeSidecar(volume.name))
        ServerLog.write("containers: volume \(volume.name), \(volume.sizeBytes >> 30) GiB")
        return HelperSpec.Volume(path: path.path, destination: volume.destination)
    }

    private func deleteVolumeFiles(_ name: String) throws {
        try FileManager.default.removeItem(at: volumePath(name))
        try? FileManager.default.removeItem(at: volumeSidecar(name))
    }

    /// Its helper started as a launchd job of this user's (not this
    /// process's child: it outlives OS Server); its socket once it answers.
    private func launch(_ name: String) async throws -> String {
        let directory = folder(name)
        try? FileManager.default.removeItem(atPath: socket(name))
        do {
            try await LaunchdJobs.start(label: label(name), plist: directory.appendingPathComponent("launchd.plist").path,
                                        program: [helper, "container", directory.appendingPathComponent("helper.json").path],
                                        log: directory.appendingPathComponent("helper.log").path)
        } catch {
            throw APIError(error: "\(error)")
        }
        // Booting takes a few seconds; a helper that ends meanwhile says why in its log.
        let deadline = Date().addingTimeInterval(180)
        while Date() < deadline {
            if isAnswering(name) { return socket(name) }
            if !(await LaunchdJobs.isRunning(label: label(name))) {
                let log = (try? String(contentsOf: directory.appendingPathComponent("helper.log"), encoding: .utf8)) ?? ""
                await bootout(name)
                throw APIError(error: "its container didn't start: \(log.split(separator: "\n").suffix(3).joined(separator: " / "))")
            }
            try await Task.sleep(for: .milliseconds(250))
        }
        await bootout(name)
        throw APIError(error: "its container didn't start in 3 minutes")
    }

    /// Its helper's job ended (TERM: the container is stopped first) and removed.
    private func bootout(_ name: String) async { await LaunchdJobs.stop(label: label(name)) }

    /// Whether its helper takes connections on its socket.
    private nonisolated func isAnswering(_ name: String) -> Bool { HelperSocket.isAnswering(socket(name)) }

    /// `alpine:3.20` as `docker.io/library/alpine:3.20`, as Docker reads it.
    static func qualified(_ image: String) throws -> String {
        let first = image.split(separator: "/").first.map(String.init) ?? image
        let hasDomain = image.contains("/") && (first.contains(".") || first.contains(":") || first == "localhost")
        let reference = try Reference.parse(hasDomain ? image : "docker.io/\(image)")
        reference.normalize()
        return reference.description
    }
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
