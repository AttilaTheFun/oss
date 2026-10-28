import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

// iOS tests on a lease's simulator (API 10): what rules_apple's
// ios_unit_test and ios_ui_test leave (the test bundle's `.zip`, the test
// host's `.ipa`), built on a Mac or on Linux, run by the server as
// rules_apple's runner runs them on a Mac: an .xctestrun, a UI test's
// XCTRunner app, `xcodebuild test-without-building` against the lease's
// simulator, the result bundle and its JUnit kept as long as the lease.

/// What `POST /v1/machines/<id>/xctest` runs (its body). The bundles are
/// objects in storage that the lease's holder holds, by SHA-256 or name.
public struct XCTestRequest: Codable, Sendable, Hashable {
    /// The test bundle: rules_apple's `<name>.zip`, holding `<name>.xctest`,
    /// or a `.xctest` folder zipped.
    public var tests: String
    /// The test host: an `.ipa` (`Payload/<App>.app`) or a zipped `.app`.
    /// None for a logic test; a hosted unit test and a UI test need one.
    public var host: String?
    /// A UI test (an ios_ui_test's bundle): run from an XCTRunner app, the
    /// host its target.
    public var ui: Bool
    /// Only these tests (xcodebuild's `-only-testing`): `Class`,
    /// `Class/method` (Swift Testing's `Suite/function()`), with or without
    /// the bundle's name before them.
    public var onlyTesting: [String]?

    public init(tests: String, host: String? = nil, ui: Bool = false, onlyTesting: [String]? = nil) {
        self.tests = tests
        self.host = host
        self.ui = ui
        self.onlyTesting = onlyTesting
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        tests = try c.decode(String.self, forKey: .tests)
        host = try c.decodeIfPresent(String.self, forKey: .host)
        ui = try c.decodeIfPresent(Bool.self, forKey: .ui) ?? false
        onlyTesting = try c.decodeIfPresent([String].self, forKey: .onlyTesting)
    }
}

/// A run's end: its id (what its JUnit and result bundle are read by, as
/// long as the lease lasts) and xcodebuild's exit status (0 passed, 65 a
/// test failed; 127 xcodebuild couldn't be started).
public struct XCTestRun: Codable, Sendable, Hashable {
    public var id: String
    public var status: Int32

    public init(id: String, status: Int32) {
        self.id = id
        self.status = status
    }
}

/// An xctest's connection: the request, the server's `101` with its run's
/// id, then frames (`stdout`: xcodebuild's output; `stderr`: the server's
/// own notes) until `exit`, xcodebuild's status.
enum OSSXCTestUpgrade {
    static func run(over stream: any OSSByteStream, url: URL, headers: [String: String], _ request: XCTestRequest,
                    output: @escaping @Sendable (ExecFrame) -> Void) async throws -> XCTestRun {
        defer { stream.close() }
        // Ending the task ends the run: the connection closes, and the server kills xcodebuild.
        return try await withTaskCancellationHandler {
            let (fields, rest) = try await OSSUpgrade.open(stream, url: url, headers: headers, body: try JSONEncoder().encode(request),
                                                           what: "xctest")
            guard let run = fields[OSSHeaders.xctestRun.lowercased()], !run.isEmpty else {
                throw OSSError(status: 0, message: "\(url.host ?? ""): no run in the xctest's answer")
            }
            var buffer = rest
            while true {
                for frame in ExecFrame.decode(&buffer) {
                    if case .exit(let code) = frame { return XCTestRun(id: run, status: code) }
                    output(frame)
                }
                guard let more = try await stream.read() else {
                    throw OSSError(status: 0, message: "the server closed the connection before run \(run) ended")
                }
                buffer.append(more)
            }
        } onCancel: {
            stream.close()
        }
    }
}

extension OSSClient {
    /// Tests run on an iOS lease of `holder`'s simulator (API 10): `POST
    /// /v1/machines/<id>/xctest`, its connection upgraded to `oss-exec`.
    /// `output` hears xcodebuild's output (`.stdout`) and the server's
    /// notes (`.stderr`) as they come. Ending the task ends the run
    /// (xcodebuild killed). One run at a time a lease: another while one
    /// runs is refused (409, `busy`).
    public func xctest(_ id: String, holder: String, _ request: XCTestRequest,
                       output: @escaping @Sendable (ExecFrame) -> Void) async throws -> XCTestRun {
        let target = url("/v1/machines/\(Self.encode(id))/xctest")
        let stream = try await transport.connect(host: server.host ?? "127.0.0.1", port: server.port ?? 80)
        let headers = try await authorization().merging([OSSHeaders.holder: holder]) { $1 }
        return try await OSSXCTestUpgrade.run(over: stream, url: target, headers: headers, request, output: output)
    }

    /// A run's JUnit (XML), from its result bundle.
    public func xctestJUnit(_ id: String, holder: String, run: String) async throws -> Data {
        try await send("GET", "/v1/machines/\(Self.encode(id))/xctest/\(Self.encode(run))/junit", headers: [OSSHeaders.holder: holder]).body
    }

    /// A run's result bundle, zipped (`result.xcresult` inside), written to `file` as it comes.
    public func downloadXCTestResult(_ id: String, holder: String, run: String, to file: URL) async throws {
        _ = try await send("GET", "/v1/machines/\(Self.encode(id))/xctest/\(Self.encode(run))/result", headers: [OSSHeaders.holder: holder],
                           responseFile: file, timeout: Self.transferTimeout)
    }
}

extension OSSGrantClient {
    /// `machine.xctest`: tests run on the grant's iOS lease, with no token.
    public func xctest(_ request: XCTestRequest, output: @escaping @Sendable (ExecFrame) -> Void) async throws -> XCTestRun {
        let stream = try await transport.connect(host: url.host ?? "127.0.0.1", port: url.port ?? 80)
        return try await OSSXCTestUpgrade.run(over: stream, url: url, headers: ["OSS-API": "\(OSS.apiLevel)"], request, output: output)
    }

    /// `machine.xctest`: a run's JUnit, by the same grant.
    public func xctestJUnit(run: String) async throws -> Data {
        try await send("GET", below: "\(run)/junit").body
    }

    /// `machine.xctest`: a run's result bundle, zipped, written to `file` as it comes.
    public func downloadXCTestResult(run: String, to file: URL) async throws {
        _ = try await send("GET", below: "\(run)/result", responseFile: file)
    }
}
