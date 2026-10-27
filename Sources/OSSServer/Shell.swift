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
        outPipe.fileHandleForReading.readabilityHandler = { handle in output.append(handle.availableData) }
        errPipe.fileHandleForReading.readabilityHandler = { handle in error.append(handle.availableData) }
        return try await withCheckedThrowingContinuation { continuation in
            process.terminationHandler = { process in
                outPipe.fileHandleForReading.readabilityHandler = nil
                errPipe.fileHandleForReading.readabilityHandler = nil
                output.append(outPipe.fileHandleForReading.readDataToEndOfFile())
                error.append(errPipe.fileHandleForReading.readDataToEndOfFile())
                continuation.resume(returning: ProcessResult(status: process.terminationStatus,
                                                             output: output.string, error: error.string, data: output.bytes))
            }
            do {
                try process.run()
            } catch {
                continuation.resume(throwing: ShellError(description: "\(executable): \(error)"))
                return
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
