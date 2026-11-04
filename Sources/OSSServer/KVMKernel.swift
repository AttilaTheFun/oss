import Foundation
import OSSClient

#if canImport(Network)
import CryptoKit
#if os(macOS)
import Virtualization
#endif

/// The kernel a container with nested virtualization boots (API 22,
/// `ContainerSpec.virtualization`): Apple's own container kernel
/// configuration (apple/containerization's `kernel/config-arm64`, which has
/// KVM), with vhost turned on for a VM's network and vsock (crosvm's, which
/// Cuttlefish runs Android in), built from kernel.org's sources. The
/// containers' usual kernel (Kata Containers', ContainerKernel) has no KVM:
/// `/dev/kvm` is missing in its containers even with nested virtualization.
///
/// OS Server builds it the first time a lease asks, in a container lease of
/// its own (kind `build`, a few minutes), and keeps it in its Containers
/// folder under a name that changes with what goes into it, so a new
/// recipe builds a new one.
public enum KVMKernel {
    static let linuxVersion = "6.18.5"
    static let source = "https://cdn.kernel.org/pub/linux/kernel/v6.x/linux-\(linuxVersion).tar.xz"
    static let sourceSHA256 = "189d1f409cef8d0d234210e04595172df392f8cb297e14b447ed95720e2fd940"
    /// apple/containerization's commit whose configuration it starts from
    /// (its Makefile builds the same Linux version).
    static let configCommit = "2f947e76143c79e94fa5403ac74ff8d9bd9f0319"
    static let config = "https://raw.githubusercontent.com/apple/containerization/\(configCommit)/kernel/config-arm64"
    static let configSHA256 = "dedb03de6d686534efbca3a90bac304721e818bd96bc421b4d2213724a4e260b"
    /// Turned on over Apple's configuration.
    static let enabled = ["VHOST_MENU", "VHOST", "VHOST_NET", "VHOST_VSOCK"]
    static let builderImage = "docker.io/library/ubuntu:24.04"
    static let localVersion = "-oss-kvm"

    /// What goes into it, hashed: a change to any of it is another kernel.
    static var recipe: String {
        let parts = [linuxVersion, sourceSHA256, configSHA256, enabled.joined(separator: ","), builderImage, localVersion, script]
        return SHA256.hash(data: Data(parts.joined(separator: "\n").utf8)).map { String(format: "%02x", $0) }.joined()
    }

    /// Where it is kept: the containers' kernel folder (a test's own).
    nonisolated(unsafe) static var folder = "\(Paths.containers)/kernel"
    public static var path: String { "\(folder)/vmlinux-kvm-\(recipe.prefix(12))" }

    /// Whether this Mac runs a VM inside a container's VM (Virtualization's
    /// nested virtualization: an M3 or newer, macOS 15 or later); a test's
    /// own answer in its place.
    nonisolated(unsafe) static var hostNests: @Sendable () -> Bool = {
        #if os(macOS)
        if #available(macOS 15, *) { return VZGenericPlatformConfiguration.isNestedVirtualizationSupported }
        #endif
        return false
    }

    /// Run in the builder as root: the kernel's `Image` on its standard
    /// output, the build's own output on its standard error.
    static var script: String {
        """
        set -e
        export DEBIAN_FRONTEND=noninteractive
        apt-get update -qq >&2
        apt-get install -y -qq build-essential bc bison flex libssl-dev libelf-dev xz-utils curl cpio python3 >&2
        mkdir -p /kbuild && cd /kbuild
        curl -fsSL -o linux.tar.xz '\(source)'
        echo '\(sourceSHA256)  linux.tar.xz' | sha256sum -c - >&2
        curl -fsSL -o config '\(config)'
        echo '\(configSHA256)  config' | sha256sum -c - >&2
        mkdir src && tar -x -f linux.tar.xz -C src --strip-components=1 && cd src
        cp ../config .config
        ./scripts/config \(enabled.map { "-e \($0)" }.joined(separator: " "))
        make ARCH=arm64 olddefconfig >&2
        for option in KVM \(enabled.dropFirst().joined(separator: " ")); do
          grep -q "^CONFIG_$option=y" .config || { echo "CONFIG_$option isn't on" >&2; exit 1; }
        done
        make ARCH=arm64 -j"$(nproc)" LOCALVERSION='\(localVersion)' >&2
        cat arch/arm64/boot/Image
        """
    }
}

extension MachineManager {
    /// The KVM kernel's path, built the first time (one build at a time,
    /// every lease that asks meanwhile waiting on it).
    func kvmKernel() async throws -> String {
        let path = KVMKernel.path
        if FileManager.default.fileExists(atPath: path) { return path }
        if let kvmKernelTask { return try await kvmKernelTask.value }
        let task = Task<String, Error> { try await self.buildKVMKernel(path) }
        kvmKernelTask = task
        defer { kvmKernelTask = nil }
        return try await task.value
    }

    private func buildKVMKernel(_ path: String) async throws -> String {
        guard containers != nil else { throw APIError(error: "no container backend") }
        log("containers: building the KVM kernel (Linux \(KVMKernel.linuxVersion), Apple's configuration with KVM and vhost) for nested virtualization")
        let spec = ContainerSpec(image: KVMKernel.builderImage, cpus: 6, memoryBytes: 8 << 30)
        let request = LeaseRequest(platform: .container, minutes: 30, holder: "oss-build@oss", container: spec, kind: .build,
                                   label: "OS Server: the KVM kernel, for containers with nested virtualization")
        let made = try await lease(request, local: true)
        defer { Task { await self.release(made.id, reason: "the KVM kernel built, or not") } }
        var socket: String?
        let deadline = Date().addingTimeInterval(1800)
        while socket == nil, Date() < deadline {
            guard let now = lease(made.id), now.state != .failed, now.state != .returning else {
                throw APIError(error: "the KVM kernel's builder didn't start: \(lease(made.id)?.error ?? "released")")
            }
            if now.state == .ready { socket = now.execSocket }
            if socket == nil { try await Task.sleep(for: .seconds(1)) }
        }
        guard let socket else { throw APIError(error: "the KVM kernel's builder didn't start in 30 minutes") }
        Paths.ensure((path as NSString).deletingLastPathComponent)
        let partial = "\(path).partial"
        try? FileManager.default.removeItem(atPath: partial)
        defer { try? FileManager.default.removeItem(atPath: partial) }
        _ = FileManager.default.createFile(atPath: partial, contents: nil)
        guard let out = FileHandle(forWritingAtPath: partial) else { throw APIError(error: "\(partial) can't be written") }
        defer { try? out.close() }
        let command = try await ContainerCommand.start(socket, ["/bin/sh", "-c", KVMKernel.script]) { data in
            (try? out.write(contentsOf: data)) != nil
        }
        try await command.write(.closeStdin)
        let result = await command.finish()
        let size = (try? FileManager.default.attributesOfItem(atPath: partial)[.size] as? Int) ?? 0
        guard result.status == 0, size > 1 << 20 else {
            throw APIError(error: "the KVM kernel didn't build (exit \(result.status)): "
                                + result.error.split(separator: "\n").suffix(5).joined(separator: " / "))
        }
        try out.close()
        try FileManager.default.moveItem(atPath: partial, toPath: path)
        log("containers: KVM kernel built: \(path) (\(size >> 20) MB)")
        return path
    }
}
#endif
