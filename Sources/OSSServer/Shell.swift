import Foundation
import OSSClient

/// A finished process: its status and what it wrote.
struct ProcessResult: Sendable {
    var status: Int32
    var output: String
    var error: String
    /// The output as bytes (a tarball, a screenshot).
    var data = Data()

    var ok: Bool { status == 0 }
}

struct ShellError: Error, CustomStringConvertible {
    var description: String
}

enum Shell {
    /// Runs a program to completion, its output read as it is written (so a
    /// full pipe never stalls it). `timeout` ends it with SIGTERM.
    ///
    /// Each pipe is read on a thread of its own, its chunks appended in the
    /// order they came; the result waits for the exit and then for both
    /// readers to reach the pipes' ends (at most a couple of seconds: a
    /// child left running in the background may hold them open). Not a
    /// readability handler: one still running when the program exited could
    /// append its chunk after the rest, and an answer longer than a pipe's
    /// buffer (curl's, 32 KiB and up) came back out of order.
    static func run(_ executable: String, _ arguments: [String], input: Data? = nil,
                    environment: [String: String]? = nil, timeout: TimeInterval? = nil) async throws -> ProcessResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        if let environment { process.environment = environment }
        let outPipe = Pipe(), errPipe = Pipe(), inPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe
        process.standardInput = input == nil ? FileHandle.nullDevice : inPipe
        let output = DataBox(), error = DataBox()
        let exited = DispatchGroup(), drained = DispatchGroup()
        return try await withCheckedThrowingContinuation { continuation in
            exited.enter()
            process.terminationHandler = { _ in exited.leave() }
            do {
                try process.run()
            } catch {
                continuation.resume(throwing: ShellError(description: "\(executable): \(error)"))
                return
            }
            for (pipe, box) in [(outPipe, output), (errPipe, error)] {
                drained.enter()
                Thread.detachNewThread {
                    let handle = pipe.fileHandleForReading
                    while case let chunk = handle.availableData, !chunk.isEmpty { box.append(chunk) }
                    drained.leave()
                }
            }
            exited.notify(queue: .global()) {
                _ = drained.wait(timeout: .now() + 2)
                continuation.resume(returning: ProcessResult(status: process.terminationStatus,
                                                             output: output.string, error: error.string, data: output.bytes))
            }
            if let input {
                // A command that exits before reading it all: its exit status says so.
                try? inPipe.fileHandleForWriting.write(contentsOf: input)
                try? inPipe.fileHandleForWriting.close()
            }
            if let timeout {
                DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
                    if process.isRunning { process.terminate() }
                }
            }
        }
    }

    /// Runs a program with this process's terminal: its output goes straight
    /// to ours (`oss ssh`, `oss run`'s command).
    static func passthrough(_ executable: String, _ arguments: [String], environment: [String: String]? = nil) throws -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        if let environment { process.environment = environment }
        try process.run()
        process.waitUntilExit()
        return process.terminationStatus
    }
}

/// Bytes collected from a pipe's handler thread.
final class DataBox: @unchecked Sendable {
    private var data = Data()
    private let lock = NSLock()

    func append(_ more: Data) {
        guard !more.isEmpty else { return }
        lock.lock(); data.append(more); lock.unlock()
    }

    var string: String { String(decoding: bytes, as: UTF8.self) }

    var bytes: Data {
        lock.lock(); defer { lock.unlock() }
        return data
    }
}
