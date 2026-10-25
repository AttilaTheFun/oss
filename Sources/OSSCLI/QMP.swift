import Foundation

/// QEMU's machine protocol (QMP) on a QEMU VM's loopback port, a port below
/// its VNC server's (UTM.setQEMUVNC), asked once when a lease is made.
final class QMPConnection {
    struct Failure: Error, CustomStringConvertible { var description: String }

    private let nc = Process()
    private let reader: FileHandle
    private let writer: FileHandle
    private var buffer = Data()

    init(port: Int) throws {
        nc.executableURL = URL(fileURLWithPath: "/usr/bin/nc")
        nc.arguments = ["127.0.0.1", String(port)]
        let input = Pipe(), output = Pipe()
        nc.standardInput = input
        nc.standardOutput = output
        nc.standardError = FileHandle.nullDevice
        try nc.run()
        reader = output.fileHandleForReading
        writer = input.fileHandleForWriting
        // A QEMU that never answers ends the connection, and so a read.
        let process = nc
        DispatchQueue.global().asyncAfter(deadline: .now() + 30) { if process.isRunning { process.terminate() } }
        do {
            _ = try message()   // the greeting
            try execute("qmp_capabilities")
        } catch {
            close()
            throw error
        }
    }

    deinit { close() }

    func close() {
        if nc.isRunning { nc.terminate() }
    }

    /// One message: QEMU writes each on a line of its own.
    private func message() throws -> [String: Any] {
        while true {
            if let newline = buffer.firstIndex(of: 0x0A) {
                let line = buffer[..<newline]
                buffer = Data(buffer[buffer.index(after: newline)...])
                if let object = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any] { return object }
                continue
            }
            let more = reader.availableData
            guard !more.isEmpty else { throw Failure(description: "QMP closed the connection") }
            buffer.append(more)
        }
    }

    /// A command's answer; the events that come meanwhile are passed over.
    @discardableResult
    func execute(_ command: String, _ arguments: [String: Any] = [:]) throws -> Any? {
        var request: [String: Any] = ["execute": command]
        if !arguments.isEmpty { request["arguments"] = arguments }
        writer.write(try JSONSerialization.data(withJSONObject: request) + Data("\n".utf8))
        while true {
            let answer = try message()
            if let error = answer["error"] as? [String: Any] {
                throw Failure(description: "QMP \(command): \(error["desc"] as? String ?? "\(error)")")
            }
            if answer.keys.contains("return") { return answer["return"] }
        }
    }

    /// Takes out the relative USB mice UTM gives a QEMU VM beside its
    /// tablet. The guest's pointer follows whichever of the two it polled
    /// last; while that is the mouse, QEMU's VNC sends only motion, so a
    /// click lands wherever the pointer already was. With the tablet alone,
    /// VNC's pointer is absolute (oss's taps and a person's viewer alike).
    /// How many were taken out.
    func removeRelativeMice() throws -> Int {
        let parent = "/machine/peripheral-anon"
        let children = (try execute("qom-list", ["path": parent]) as? [[String: Any]]) ?? []
        var removed = 0
        for child in children where (child["type"] as? String) == "child<usb-mouse>" {
            guard let name = child["name"] as? String else { continue }
            try execute("device_del", ["id": "\(parent)/\(name)"])
            removed += 1
        }
        return removed
    }
}
