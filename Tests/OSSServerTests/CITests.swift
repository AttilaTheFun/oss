import Foundation
import Testing
import OSSClient
@testable import OSSServer

// CI in containers (0.14): the App's JWT, its files' checks, which jobs are
// the server's, the conditional polls, the queue's order and its limit, and
// a runner no job came to; against a fake GitHub and a fake container host
// (no real GitHub, no real containers).

// MARK: The App's key and its JWT

/// A throwaway RSA key made for these tests (openssl genrsa 2048), as
/// PKCS #1 and PKCS #8 DER, and the JWT openssl signs with it for app 12345
/// at 1,700,000,000 (`openssl dgst -sha256 -sign`): RSASSA-PKCS1-v1_5 is
/// deterministic, so Security's signature must be the same.
private let testKeyPKCS1 = """
    MIIEowIBAAKCAQEA0GfrERXXnRZOLnHbojjvRNSa5DCtQ08m+xBQXg4yBJlhekNAUqCmlDBs4HjKyEI6IGYYToHdpS6aEuYTh+kA
    8Sezy9O6w+ncH007oxd0W000wc0dlfyUAUV6R+PZM9KXFz2wt1qD+03psbI+xanmN040fAWBdGJpbBIqFjhhcyOL7gEnW+BfD1UM
    nPe5gBvVvaOVxxYf4Q+iQpIWf6cJXbjPgYNrWBjVlej74M1Kj/mMRfua4TOvbySTFbS4DZ7MbSE1c4XewRx3UV8pZm9Ne9Kf/V2V
    Ekp8IcDrFQUcrhIThAxLae0h7roGR9buN3/B+SRQORkYySgqGa89e8DmKwIDAQABAoIBAB047ROkueqLdaP6kB8Dl71RiHSFxM3C
    3AbpRzOhDu9pKGtx4aOUZjcyQRoKpfiFnMvtNOxRNmiSi8UpoMR2bgzikcn7Yt1UvepftISOZeDlhwfDwKnG1GQHP3m0H8Et/sSi
    AFT9arNCvgmOIlIqHB9WJnLbfMb6g6jFNUSPXE6+BPqwR8t9SGINCWToJtQVmpolsIw6kR4hzJz6sigy3kTeQU4RU5Uv6h59BZcm
    mWin3anpGf4T3RhH++51SFZc987MmIMX42gwEkcc+l0Xk8AtuSDusdOE/41EcDKeJf57aCJI2dhrt/+IBfpU8YQ5E3t2d1aU48Uj
    gP/X4LWc9nUCgYEA50IULSHoHqJ6GuQ1kLWmKi3lI9+x9nZET2ImC0WQvDncCsq9ZuaLVqwo2G1Gx1q+YAMHOrYIJeUobxhuo0gg
    mpm57EHJb06kaxqVzm7+O8N/TfyOx+80w2o7BUAAG1fqKABPcu59fhf26xFdjejIyGaoYSeHlcoFTqiCYjfM6G8CgYEA5rPxB/6h
    WkENDFPbHQrMn5NbeXETXUFQ7+5+3zpy1QnF1ihuFGtwIAEFmZPrOyV72Zl5Sc7E/NMmxWnYCMZK1Xgvfej5XErwb769ZBocyiHP
    YHiS4r+xXI486T4+OOGrxKIzYJaU8acnBLGYHyEb20MBy+kgV9ufqBqxoC3bZAUCgYEAuftYgpt8M/bzQGE7+u87fTx/xYQHeXDP
    qxACDJqbteTKZBt8ix7p/IBkMPphK7580HZfAAaZMvDCveXmRIajQfJTpf+aYlvauxAcXnLBH4sv/KYapgxoYKg0Yxp/e34OoLDv
    ND08y4W2XIIQvSnzH8f/rnK+Beb8sa+vfBHoRx0CgYBO7R634ngnHXwuTH346JnqugogePvr+o2LGCfVjPR+R9KkGr7WQ49fk5nr
    2bwvRvqhDi19f7zK1h48iaJ8FgLCF1UAGXU+CvFI+ZNnrLtOt9Rvp7Bw3K38ATl7fmzhHuuZ4Pf8wmeAaPQjWfK2K6iREdKKhV4o
    UJ3FcCR2rVmSVQKBgDNEuFpBOvJ7pWI1nsjx65ADt0B4WiyzNTRfUMT1lOr2jSDzexBAcsrgYIopVdxiEtfk5csbee91uESkYMGm
    2+7xM77M/JaP1WCH7rUNW15mA0uBVj/pzTdsll4OM8ysBv4rhrd+kNXXtM0qThUqXgYQiRlLRAqJmLhuk5tcrFYy
    """.filter { !$0.isWhitespace }
private let testKeyPKCS8 = """
    MIIEvQIBADANBgkqhkiG9w0BAQEFAASCBKcwggSjAgEAAoIBAQDQZ+sRFdedFk4ucduiOO9E1JrkMK1DTyb7EFBeDjIEmWF6Q0BS
    oKaUMGzgeMrIQjogZhhOgd2lLpoS5hOH6QDxJ7PL07rD6dwfTTujF3RbTTTBzR2V/JQBRXpH49kz0pcXPbC3WoP7Temxsj7FqeY3
    TjR8BYF0YmlsEioWOGFzI4vuASdb4F8PVQyc97mAG9W9o5XHFh/hD6JCkhZ/pwlduM+Bg2tYGNWV6PvgzUqP+YxF+5rhM69vJJMV
    tLgNnsxtITVzhd7BHHdRXylmb0170p/9XZUSSnwhwOsVBRyuEhOEDEtp7SHuugZH1u43f8H5JFA5GRjJKCoZrz17wOYrAgMBAAEC
    ggEAHTjtE6S56ot1o/qQHwOXvVGIdIXEzcLcBulHM6EO72koa3Hho5RmNzJBGgql+IWcy+007FE2aJKLxSmgxHZuDOKRyfti3VS9
    6l+0hI5l4OWHB8PAqcbUZAc/ebQfwS3+xKIAVP1qs0K+CY4iUiocH1Ymctt8xvqDqMU1RI9cTr4E+rBHy31IYg0JZOgm1BWamiWw
    jDqRHiHMnPqyKDLeRN5BThFTlS/qHn0FlyaZaKfdqekZ/hPdGEf77nVIVlz3zsyYgxfjaDASRxz6XReTwC25IO6x04T/jURwMp4l
    /ntoIkjZ2Gu3/4gF+lTxhDkTe3Z3VpTjxSOA/9fgtZz2dQKBgQDnQhQtIegeonoa5DWQtaYqLeUj37H2dkRPYiYLRZC8OdwKyr1m
    5otWrCjYbUbHWr5gAwc6tggl5ShvGG6jSCCambnsQclvTqRrGpXObv47w39N/I7H7zTDajsFQAAbV+ooAE9y7n1+F/brEV2N6MjI
    ZqhhJ4eVygVOqIJiN8zobwKBgQDms/EH/qFaQQ0MU9sdCsyfk1t5cRNdQVDv7n7fOnLVCcXWKG4Ua3AgAQWZk+s7JXvZmXlJzsT8
    0ybFadgIxkrVeC996PlcSvBvvr1kGhzKIc9geJLiv7FcjjzpPj444avEojNglpTxpycEsZgfIRvbQwHL6SBX25+oGrGgLdtkBQKB
    gQC5+1iCm3wz9vNAYTv67zt9PH/FhAd5cM+rEAIMmpu15MpkG3yLHun8gGQw+mErvnzQdl8ABpky8MK95eZEhqNB8lOl/5piW9q7
    EBxecsEfiy/8phqmDGhgqDRjGn97fg6gsO80PTzLhbZcghC9KfMfx/+ucr4F5vyxr698EehHHQKBgE7tHrfieCcdfC5Mffjomeq6
    CiB4++v6jYsYJ9WM9H5H0qQavtZDj1+TmevZvC9G+qEOLX1/vMrWHjyJonwWAsIXVQAZdT4K8Uj5k2esu0631G+nsHDcrfwBOXt+
    bOEe65ng9/zCZ4Bo9CNZ8rYrqJER0oqFXihQncVwJHatWZJVAoGAM0S4WkE68nulYjWeyPHrkAO3QHhaLLM1NF9QxPWU6vaNIPN7
    EEByyuBgiilV3GIS1+Tlyxt573W4RKRgwabb7vEzvsz8lo/VYIfutQ1bXmYDS4FWP+nNN2yWXg4zzKwG/iuGt36Q1de0zSpOFSpe
    BhCJGUtEComYuG6Tm1ysVjI=
    """.filter { !$0.isWhitespace }
private let expectedJWT = "eyJhbGciOiJSUzI1NiIsInR5cCI6IkpXVCJ9.eyJpYXQiOjE2OTk5OTk5NDAsImV4cCI6MTcwMDAwMDU0MCwiaXNzIjoxMjM0NX0.Cg9lv7BmL20Pq9q2VzENvNK9y5dngDwnElxCGYK5ZF4UNDz1lg8jY-ztErJFQfJq1NDu2c6_sZ2qJHphggcA9IP6L-DzlhyY-sk0JmBMDyeuu1SOkK8vc-63oOGHgPJbgqzDBRa-zmerFA6jTb97dGZoVu1tz3L9f7rIhCd0kG3tbXJksFX6pWTrQF_BzKvDGixHI_-jYXj9yDoOnX7jvjW-BBf7KiSSZGohySE8crwrzxOL2hl06oocz6hJJdjaa9lp5HSLs1fmv3AX80FvFWfF89gb5lHVZ9jxqAEBglcWCugW9pyougAMEWxbEgSZU35J62aebAUXnSmzDBaBSw"

/// A PEM of the test key's DER (its armour put together here, not written out).
private func pem(_ base64: String, _ kind: String) -> String {
    let lines = stride(from: 0, to: base64.count, by: 64).map { start in
        String(base64.dropFirst(start).prefix(64))
    }
    return (["-----BEGIN \(kind)-----"] + lines + ["-----END \(kind)-----"]).joined(separator: "\n") + "\n"
}

@Test func theAppsKeyIsReadAsPKCS1OrPKCS8() throws {
    let pkcs1 = try RSAPrivateKey(pem: pem(testKeyPKCS1, "RSA " + "PRIVATE KEY"))
    let pkcs8 = try RSAPrivateKey(pem: pem(testKeyPKCS8, "PRIVATE " + "KEY"))
    #expect(pkcs1.pkcs1 == Data(base64Encoded: testKeyPKCS1))
    #expect(pkcs8.pkcs1 == pkcs1.pkcs1)
    #expect(throws: (any Error).self) { try RSAPrivateKey(pem: "not a key") }
    #expect(throws: (any Error).self) { try RSAPrivateKey(pem: pem(testKeyPKCS1, "EC " + "PRIVATE KEY")) }
}

@Test func theJWTSaysTheAppAndItsMinutes() throws {
    var signed = Data()
    let jwt = try GitHubAppJWT.make(appID: 12345, now: Date(timeIntervalSince1970: 1_700_000_000)) { input in
        signed = input
        return Data([1, 2, 3])
    }
    let parts = jwt.split(separator: ".").map(String.init)
    #expect(parts.count == 3)
    #expect(Data(base64URL: parts[0]) == Data(#"{"alg":"RS256","typ":"JWT"}"#.utf8))
    // Issued a minute back (clocks drift), good for ten minutes from then.
    #expect(Data(base64URL: parts[1]) == Data(#"{"iat":1699999940,"exp":1700000540,"iss":12345}"#.utf8))
    #expect(signed == Data("\(parts[0]).\(parts[1])".utf8))
    #expect(parts[2] == Data([1, 2, 3]).base64URL)
    #expect(jwt.hasPrefix(expectedJWT.split(separator: ".").prefix(2).joined(separator: ".")))
}

#if canImport(Security)
@Test func theJWTIsSignedAsOpenSSLSignsIt() throws {
    for key in [try RSAPrivateKey(pem: pem(testKeyPKCS1, "RSA " + "PRIVATE KEY")), try RSAPrivateKey(pem: pem(testKeyPKCS8, "PRIVATE " + "KEY"))] {
        let jwt = try GitHubAppJWT.make(appID: 12345, now: Date(timeIntervalSince1970: 1_700_000_000)) { try key.sign($0) }
        #expect(jwt == expectedJWT)
    }
}
#endif

// MARK: The App's files

private func appFolder(config: String?, key: String?, configMode: Int = 0o600, keyMode: Int = 0o600) -> String {
    let folder = NSTemporaryDirectory() + "oss-ci-app-\(UUID().uuidString)"
    try? FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
    if let config {
        _ = FileManager.default.createFile(atPath: "\(folder)/\(CIAppFiles.configName)", contents: Data(config.utf8), attributes: [.posixPermissions: configMode])
    }
    if let key {
        _ = FileManager.default.createFile(atPath: "\(folder)/\(CIAppFiles.keyName)", contents: Data(key.utf8), attributes: [.posixPermissions: keyMode])
    }
    return folder
}

@Test func theAppsFilesAreTheirOwnersAlone() throws {
    let key = pem(testKeyPKCS1, "RSA " + "PRIVATE KEY")
    // Neither: CI is off, nothing said.
    #expect(try CIAppFiles.load(directory: appFolder(config: nil, key: nil)) == nil)
    // Both, mode 600: read.
    let loaded = try CIAppFiles.load(directory: appFolder(config: #"{"appId": 42, "maxConcurrent": 3}"#, key: key))
    #expect(loaded?.config == CIAppConfig(appId: 42, repositories: nil, maxConcurrent: 3))
    // 400 is its owner's alone too.
    #expect(try CIAppFiles.load(directory: appFolder(config: #"{"appId": 42}"#, key: key, keyMode: 0o400)) != nil)
    // Readable by others, either of them: refused.
    #expect(throws: (any Error).self) { try CIAppFiles.load(directory: appFolder(config: #"{"appId": 42}"#, key: key, configMode: 0o644)) }
    #expect(throws: (any Error).self) { try CIAppFiles.load(directory: appFolder(config: #"{"appId": 42}"#, key: key, keyMode: 0o640)) }
    // One without the other, or not what it should be: refused.
    #expect(throws: (any Error).self) { try CIAppFiles.load(directory: appFolder(config: #"{"appId": 42}"#, key: nil)) }
    #expect(throws: (any Error).self) { try CIAppFiles.load(directory: appFolder(config: nil, key: key)) }
    #expect(throws: (any Error).self) { try CIAppFiles.load(directory: appFolder(config: #"{"id": 42}"#, key: key)) }
    #expect(throws: (any Error).self) { try CIAppFiles.load(directory: appFolder(config: #"{"appId": 42}"#, key: "not a key")) }
}

@Test func serverJSONsCINamesTheRepositoriesAndTheirLabels() throws {
    let settings = try JSONDecoder().decode(CISettings.self, from: Data("""
        {"repositories": ["owner/gh_mcp", "owner/other", "not a repository"], "labels": {"owner/gh_mcp": "gh_mcp-oss"}}
        """.utf8))
    let (plan, why) = CIPlan.make(settings: settings, app: CIAppConfig(appId: 1), cores: 32, memoryBytes: 256 << 30, containerCapacity: 4)
    #expect(why == nil)
    #expect(plan?.repositories == [.init(name: "owner/gh_mcp", label: "gh_mcp-oss"), .init(name: "owner/other", label: "other-ci")])
    // From the cores and memory, at most half the containers.
    #expect(plan?.maxConcurrent == 2)
    #expect(plan?.image == CIDefaults.image)
    // The App's file narrows them, and its maxConcurrent stands where server.json says none.
    let narrowed = CIPlan.make(settings: settings, app: CIAppConfig(appId: 1, repositories: ["OWNER/other"], maxConcurrent: 5),
                               containerCapacity: 4).0
    #expect(narrowed?.repositories.map(\.name) == ["owner/other"])
    #expect(narrowed?.maxConcurrent == 5)
    // Off, saying why.
    #expect(CIPlan.make(settings: nil, app: CIAppConfig(appId: 1), containerCapacity: 4).0 == nil)
    #expect(CIPlan.make(settings: CISettings(), app: CIAppConfig(appId: 1), containerCapacity: 4).1 != nil)
    // A small Mac runs one.
    #expect(CIDefaults.concurrency(cores: 10, memoryBytes: 16 << 30, containerCapacity: 4) == 1)
    #expect(CIDefaults.concurrency(cores: 32, memoryBytes: 512 << 30, containerCapacity: 16) == 4)
}

// MARK: Which jobs are the server's

@Test func aJobIsTheServersWhenItAsksForSelfHostedAndItsLabelAlone() {
    #expect(CINames.matches(["self-hosted", "gh_mcp-oss"], label: "gh_mcp-oss"))
    #expect(CINames.matches(["gh_mcp-OSS", "Self-Hosted"], label: "gh_mcp-oss"))
    // The old runner's label, another platform's, a GitHub-hosted job's, or one more label: not this server's.
    #expect(!CINames.matches(["self-hosted", "gh_mcp-ci"], label: "gh_mcp-oss"))
    #expect(!CINames.matches(["self-hosted", "gh_mcp-oss", "macOS"], label: "gh_mcp-oss"))
    #expect(!CINames.matches(["ubuntu-latest"], label: "gh_mcp-oss"))
    #expect(!CINames.matches(["gh_mcp-oss"], label: "gh_mcp-oss"))
}

@Test func aJobsLeasesGoByItsNameAndRun() {
    let job = CIJob(id: 7, repository: "o/r", name: "Build & test (macOS)", runID: 99, labels: [], queued: Date())
    #expect(CINames.holder(job) == "build-test-macos-99@ci")
    #expect(CINames.runnerHolder(job) == "build-test-macos-99-runner@ci")
    #expect(CINames.slug("***") == "job")
}

@Test func aJobsGrantOpensWhatItsScriptsDoAndNothingElse() {
    func allows(_ method: String, _ path: String) -> Bool { JobGrantRoutes.allows(method, path.split(separator: "/").map(String.init)) }
    #expect(allows("POST", "/v1/machines"))
    #expect(allows("GET", "/v1/machines"))
    #expect(allows("DELETE", "/v1/machines/ab12"))
    #expect(allows("POST", "/v1/machines/ab12/renew"))
    #expect(allows("POST", "/v1/machines/ab12/exec"))
    #expect(allows("PUT", "/v1/machines/ab12/files"))
    #expect(allows("GET", "/v1/machines/ab12/xctest/run1/junit"))
    #expect(allows("PUT", "/v1/storage/objects"))
    #expect(allows("GET", "/v1/storage/leases"))
    #expect(allows("GET", "/v1/cache"))
    #expect(!allows("POST", "/v1/grants"))
    #expect(!allows("GET", "/v1/keys"))
    #expect(!allows("GET", "/v1/status"))
    #expect(!allows("DELETE", "/v1/volumes/x"))
    #expect(!allows("GET", "/v1/ci/jobs"))
}

@Test func aJobsContainerFindsItsServerAndHolderInItsGrant() {
    let claims = GrantClaims(verb: "ci.job", resource: "machines/ab12", holder: "build-99@ci", expires: 2_000_000_000)
    let token = (try! JSONEncoder().encode(claims)).base64URL + ".c2ln"
    let environment = ["OSS_GRANT": "http://192.168.64.1:7480/v1/machines?grant=\(token)"]
    #expect(JobGrantEnvironment.token(environment) == token)
    #expect(JobGrantEnvironment.server(environment) == "http://192.168.64.1:7480")
    #expect(JobGrantEnvironment.holder(environment) == "build-99@ci")
    #expect(JobGrantEnvironment.token([:]) == nil)
    #expect(JobGrantEnvironment.token(["OSS_GRANT": "http://h:1/v1/machines"]) == nil)
}

// MARK: A fake GitHub

/// GitHub's API as a test answers it: each request kept, each answered by
/// `answer` (404 where it says nothing).
final class FakeGitHub: OSSTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var kept: [OSSHTTPRequest] = []
    var answer: @Sendable (OSSHTTPRequest) -> OSSHTTPResponse? = { _ in nil }
    private var status = "queued"
    /// What GitHub says of a job asked for alone (queueGitHub's).
    var jobStatus: String {
        get { lock.withLock { status } }
        set { lock.withLock { status = newValue } }
    }

    var requests: [OSSHTTPRequest] { lock.withLock { kept } }

    func send(_ request: OSSHTTPRequest) async throws -> OSSHTTPResponse {
        lock.withLock { kept.append(request) }
        return answer(request) ?? OSSHTTPResponse(status: 404, headers: [:], body: Data(#"{"message":"Not Found"}"#.utf8))
    }

    static func json(_ text: String, status: Int = 200, headers: [String: String] = [:]) -> OSSHTTPResponse {
        OSSHTTPResponse(status: status, headers: headers, body: Data(text.utf8))
    }

    /// The App's own answers: the installation and its token.
    static func app(_ request: OSSHTTPRequest) -> OSSHTTPResponse? {
        if request.url.path.hasSuffix("/installation") { return json(#"{"id": 5}"#) }
        if request.url.path == "/app/installations/5/access_tokens" {
            return json(#"{"token": "installation-token", "expires_at": "2099-01-01T00:00:00Z"}"#, status: 201)
        }
        return nil
    }
}

private func job(_ id: Int, run: Int = 10, labels: [String] = ["self-hosted", "gh_mcp-oss"], status: String = "queued",
                 created: String = "2026-10-31T10:00:00Z") -> String {
    #"{"id": \#(id), "run_id": \#(run), "name": "job \#(id)", "status": "\#(status)", "labels": [\#(labels.map { "\"\($0)\"" }.joined(separator: ", "))],"#
        + #" "created_at": "\#(created)", "workflow_name": "CI", "head_branch": "main", "head_sha": "abc"}"#
}

private func makeREST(_ github: FakeGitHub) -> GitHubREST {
    GitHubREST(app: GitHubApp(appID: 1, sign: { _ in Data([1]) }, transport: github, api: URL(string: "https://api.github.test")!),
               transport: github)
}

private let repository = CIPlan.Repository(name: "owner/gh_mcp", label: "gh_mcp-oss")

private func plan(max: Int = 2, unclaimed: Duration = .seconds(60)) -> CIPlan {
    CIPlan(appID: 1, repositories: [repository], maxConcurrent: max, image: "image", cpus: 1, memoryGigabytes: 1, poll: .seconds(5),
           unclaimed: unclaimed, serverURL: nil)
}

// MARK: A fake container host

/// Runners that run until a test ends them, or until they're released.
final class FakeRunnerHost: CIRunnerHost, @unchecked Sendable {
    private let lock = NSLock()
    private var startedJobs: [Int] = []
    private var releasedLeases: [String] = []
    private var running: [String: CheckedContinuation<Int32, Never>] = [:]
    private var listeners: [String: @Sendable (String) -> Void] = [:]
    /// Starts refused as busy before the next succeeds.
    var busy = 0

    var started: [Int] { lock.withLock { startedJobs } }
    var released: [String] { lock.withLock { releasedLeases } }
    var runningLeases: [String] { lock.withLock { Array(running.keys).sorted() } }

    func releaseLeftovers() async {}

    func start(_ job: CIJob, holder: String, runnerHolder: String) async throws -> String {
        try lock.withLock {
            if busy > 0 {
                busy -= 1
                throw CIBusy(description: "busy: 4 of 4 container machines are leased")
            }
            startedJobs.append(job.id)
        }
        return "lease\(job.id)"
    }

    func environment(lease: String, holder: String) async throws -> [String: String] { ["OSS_GRANT": "http://h/v1/machines?grant=g"] }

    func run(lease: String, jitConfig: String, environment: [String: String],
             line: @escaping @Sendable (String) -> Void) async throws -> Int32 {
        await withCheckedContinuation { continuation in
            lock.withLock {
                running[lease] = continuation
                listeners[lease] = line
            }
        }
    }

    func release(lease: String, holder: String) async {
        let continuation = lock.withLock {
            releasedLeases.append(lease)
            return running.removeValue(forKey: lease)
        }
        continuation?.resume(returning: -1)
    }

    /// The runner says `lines`, then exits with `status`.
    func finish(_ lease: String, lines: [String], status: Int32 = 0) {
        let (continuation, listener) = lock.withLock { (running.removeValue(forKey: lease), listeners[lease]) }
        lines.forEach { listener?($0) }
        continuation?.resume(returning: status)
    }
}

/// Waits (up to five seconds) until `condition` holds.
private func eventually(_ condition: @Sendable () async -> Bool) async -> Bool {
    for _ in 0..<500 {
        if await condition() { return true }
        try? await Task.sleep(for: .milliseconds(10))
    }
    return false
}

/// GitHub as the queue's tests need it: every job still queued, runners
/// configured and deleted.
private func queueGitHub() -> FakeGitHub {
    let github = FakeGitHub()
    github.answer = { [weak github] request in
        if let app = FakeGitHub.app(request) { return app }
        let path = request.url.path
        if path.hasPrefix("/repos/owner/gh_mcp/actions/jobs/") {
            return FakeGitHub.json(job(Int(path.split(separator: "/").last!)!, status: github?.jobStatus ?? "queued"))
        }
        if path.hasSuffix("/actions/runners/generate-jitconfig") {
            let body = (try? JSONSerialization.jsonObject(with: request.body ?? Data()) as? [String: Any]) ?? [:]
            return FakeGitHub.json(#"{"runner": {"id": 900}, "encoded_jit_config": "config-for-\#(body["name"] as? String ?? "")"}"#, status: 201)
        }
        if request.method == "DELETE", path.hasPrefix("/repos/owner/gh_mcp/actions/runners/") { return FakeGitHub.json("", status: 204) }
        return nil
    }
    return github
}

private func decodedJobs(_ list: [String]) throws -> [GitHubREST.Job] {
    try list.map { try JSONDecoder.oss.decode(GitHubREST.Job.self, from: Data($0.utf8)) }
}

// MARK: Polling

@Test func aPollTakesTheQueuedJobsOfItsLabelAndAsksAgainOnlyIfChanged() async throws {
    let github = FakeGitHub()
    github.answer = { request in
        if let app = FakeGitHub.app(request) { return app }
        let path = request.url.path, query = request.url.query ?? ""
        // An unchanged answer is 304, with no body.
        if request.headers["If-None-Match"] == "\"runs\"" || request.headers["If-None-Match"] == "\"jobs\"" {
            return FakeGitHub.json("", status: 304)
        }
        if path == "/repos/owner/gh_mcp/actions/runs", query.contains("status=queued") {
            return FakeGitHub.json(#"{"total_count": 1, "workflow_runs": [{"id": 10, "status": "queued"}]}"#, headers: ["etag": "\"runs\""])
        }
        if path == "/repos/owner/gh_mcp/actions/runs", query.contains("status=in_progress") {
            return FakeGitHub.json(#"{"total_count": 1, "workflow_runs": [{"id": 11, "status": "in_progress"}]}"#)
        }
        if path == "/repos/owner/gh_mcp/actions/runs/10/jobs" {
            return FakeGitHub.json(#"{"jobs": [\#(job(1)), \#(job(2, labels: ["self-hosted", "gh_mcp-ci"])), \#(job(3, labels: ["ubuntu-latest"]))]}"#,
                                   headers: ["etag": "\"jobs\""])
        }
        if path == "/repos/owner/gh_mcp/actions/runs/11/jobs" {
            // A running run whose later job is queued now (it `needs` the first).
            return FakeGitHub.json(#"{"jobs": [\#(job(4, run: 11, status: "in_progress")), \#(job(5, run: 11))]}"#)
        }
        if path.hasPrefix("/repos/owner/gh_mcp/actions/jobs/") { return FakeGitHub.json(job(1)) }
        return nil
    }
    let host = FakeRunnerHost()
    let service = CIService(plan: plan(max: 0), github: makeREST(github), host: host)
    try await service.poll(repository)
    #expect(await service.list().map(\.id).sorted() == [1, 5])
    try await service.poll(repository)
    // Seen once, asked for with the last answer's ETag, its kept body used.
    #expect(await service.list().map(\.id).sorted() == [1, 5])
    let runs = github.requests.filter { $0.url.path == "/repos/owner/gh_mcp/actions/runs" && ($0.url.query ?? "").contains("queued") }
    #expect(runs.count == 2)
    #expect(runs.first?.headers["If-None-Match"] == nil)
    #expect(runs.last?.headers["If-None-Match"] == "\"runs\"")
    #expect(runs.allSatisfy { $0.headers["Authorization"] == "Bearer installation-token" })
    // The installation's token was asked for once, with the App's JWT.
    #expect(github.requests.filter { $0.url.path == "/app/installations/5/access_tokens" }.count == 1)
    let job1 = try #require(await service.list().first { $0.id == 1 })
    #expect(job1.labels == ["self-hosted", "gh_mcp-oss"])
    #expect(job1.runURL?.absoluteString == "https://github.com/owner/gh_mcp/actions/runs/10")
    #expect(job1.state == .queued)
}

@Test func aRunnersOutputIsReadALineAtATime() {
    let lines = LineBuffer()
    #expect(lines.add(Data("√ Connected to GitHub\r\nListen".utf8)) == ["√ Connected to GitHub"])
    #expect(lines.add(Data("ing for Jobs\nRunning job: build\n".utf8)) == ["Listening for Jobs", "Running job: build"])
    #expect(lines.add(Data("Job build completed".utf8)).isEmpty)
    #expect(lines.rest() == "Job build completed")
    #expect(lines.rest() == nil)
}

@Test func aRateLimitSaysWhenToAskAgain() {
    let now = Date(timeIntervalSince1970: 1_000)
    let limited = GitHubError.from(OSSHTTPResponse(status: 403, headers: ["x-ratelimit-remaining": "0", "x-ratelimit-reset": "1120"],
                                                   body: Data(#"{"message": "API rate limit exceeded"}"#.utf8)), now: now)
    #expect(limited.retryAfter == 120)
    #expect(limited.message == "API rate limit exceeded")
    let later = GitHubError.from(OSSHTTPResponse(status: 429, headers: ["retry-after": "30"], body: Data()), now: now)
    #expect(later.retryAfter == 30)
    // Else twice as long each time, up to five minutes.
    let plain = GitHubError(status: 502, message: "bad gateway")
    #expect(CIBackoff.next(after: limited, previous: nil, base: .seconds(5)) == .seconds(120))
    #expect(CIBackoff.next(after: plain, previous: nil, base: .seconds(5)) == .seconds(10))
    #expect(CIBackoff.next(after: plain, previous: .seconds(10), base: .seconds(5)) == .seconds(20))
    #expect(CIBackoff.next(after: plain, previous: .seconds(200), base: .seconds(5)) == .seconds(300))
}

// MARK: The queue

@Test func jobsRunInGitHubsOrderAtMostSoManyAtOnce() async throws {
    let github = queueGitHub()
    let host = FakeRunnerHost()
    let service = CIService(plan: plan(max: 2), github: makeREST(github), host: host)
    // Offered out of order: run in the order GitHub queued them.
    await service.offer(try decodedJobs([job(3, created: "2026-10-31T10:03:00Z"), job(1, created: "2026-10-31T10:01:00Z"),
                                         job(2, created: "2026-10-31T10:02:00Z")]), repository: "owner/gh_mcp")
    #expect(await eventually { host.runningLeases.count == 2 })
    #expect(host.started == [1, 2])
    #expect(await service.list().first { $0.id == 3 }?.state == .queued)
    // Each runner's configuration is named for its lease, with the job's labels.
    let configs = github.requests.filter { $0.url.path.hasSuffix("generate-jitconfig") }
    let first = try #require(configs.first.flatMap { try JSONSerialization.jsonObject(with: $0.body ?? Data()) as? [String: Any] })
    #expect(["oss-lease1", "oss-lease2"].contains(first["name"] as? String ?? ""))
    #expect(first["labels"] as? [String] == ["self-hosted", "gh_mcp-oss"])
    #expect(first["runner_group_id"] as? Int == 1)
    // One ends: the third takes its place.
    host.finish("lease1", lines: ["√ Connected to GitHub", "Listening for Jobs", "Running job: job 1", "Job job 1 completed with result: Succeeded"])
    #expect(await eventually { host.started == [1, 2, 3] })
    #expect(await eventually { await service.list().first { $0.id == 1 }?.state == .completed })
    let done = try #require(await service.list().first { $0.id == 1 })
    #expect(done.result == "Succeeded")
    #expect(done.started != nil && done.ended != nil && done.ran != nil)
    #expect(done.lease == "lease1")
    #expect(done.runner == "oss-lease1")
    #expect(host.released.contains("lease1"))
    // A runner that ran a job isn't deleted (GitHub deletes it).
    #expect(!github.requests.contains { $0.method == "DELETE" })
    // Newest first.
    #expect(await service.list().map(\.id) == [3, 2, 1])
}

@Test func aJobWaitsWhenThereIsNoRoomAndTakesItsPlaceAgain() async throws {
    let github = queueGitHub()
    let host = FakeRunnerHost()
    host.busy = 1
    let service = CIService(plan: plan(max: 1), github: makeREST(github), host: host, busyRetry: .milliseconds(20))
    await service.offer(try decodedJobs([job(1)]), repository: "owner/gh_mcp")
    #expect(await eventually { host.started == [1] })
    let state = await service.list().first?.state
    #expect(state == .starting || state == .listening)
}

@Test func aJobNoLongerQueuedWhenItsTurnComesIsSkipped() async throws {
    let github = FakeGitHub()
    github.answer = { request in
        if let app = FakeGitHub.app(request) { return app }
        if request.url.path.hasPrefix("/repos/owner/gh_mcp/actions/jobs/") { return FakeGitHub.json(job(1, status: "in_progress")) }
        return nil
    }
    let host = FakeRunnerHost()
    let service = CIService(plan: plan(), github: makeREST(github), host: host)
    await service.offer(try decodedJobs([job(1)]), repository: "owner/gh_mcp")
    #expect(await eventually { await service.list().first?.state == .skipped })
    #expect(host.started.isEmpty)
}

@Test func aRunnerNoJobCameToIsGivenUpAndItsRegistrationDeleted() async throws {
    let github = queueGitHub()
    let host = FakeRunnerHost()
    let service = CIService(plan: plan(unclaimed: .milliseconds(100)), github: makeREST(github), host: host)
    await service.offer(try decodedJobs([job(1)]), repository: "owner/gh_mcp")
    #expect(await eventually { host.runningLeases == ["lease1"] })
    // GitHub gives the job to another runner: no job comes to this one.
    github.jobStatus = "in_progress"
    // Its container is released, which ends it.
    #expect(await eventually { await service.list().first?.state == .unclaimed })
    #expect(await eventually { host.released.contains("lease1") && host.runningLeases.isEmpty })
    #expect(await eventually { github.requests.contains { $0.method == "DELETE" && $0.url.path == "/repos/owner/gh_mcp/actions/runners/900" } })
    let given = try #require(await service.list().first)
    #expect(given.started == nil)
    #expect(given.error?.contains("no job came") == true)
}

@Test func aRunnerThatExitsBeforeItsJobFailsAndIsDeleted() async throws {
    let github = queueGitHub()
    let host = FakeRunnerHost()
    let service = CIService(plan: plan(), github: makeREST(github), host: host)
    await service.offer(try decodedJobs([job(1)]), repository: "owner/gh_mcp")
    #expect(await eventually { host.runningLeases == ["lease1"] })
    github.jobStatus = "completed"
    host.finish("lease1", lines: ["An error occurred: not configured"], status: 1)
    #expect(await eventually { await service.list().first?.state == .failed })
    #expect(await eventually { github.requests.contains { $0.method == "DELETE" } })
    #expect(host.released == ["lease1"])
}

@Test func aJobStillQueuedAfterItsRunnerFailedIsOfferedAgainAFewTimes() async throws {
    let github = queueGitHub()
    let host = FakeRunnerHost()
    let service = CIService(plan: plan(), github: makeREST(github), host: host)
    for attempt in 1...CIService.attempts {
        await service.offer(try decodedJobs([job(1)]), repository: "owner/gh_mcp")
        #expect(await eventually { host.runningLeases == ["lease1"] && host.started.count == attempt })
        host.finish("lease1", lines: [], status: 1)
        if attempt < CIService.attempts {
            // Still queued on GitHub: forgotten, so the next poll offers it again.
            #expect(await eventually { await service.list().isEmpty })
        }
    }
    // The last time it stays failed.
    #expect(await eventually { await service.list().first?.state == .failed })
    await service.offer(try decodedJobs([job(1)]), repository: "owner/gh_mcp")
    try await Task.sleep(for: .milliseconds(50))
    #expect(host.started.count == CIService.attempts)
}

#if canImport(Network)
// MARK: A job's grant, at the API

@Test func aJobsGrantActsForTheJobAloneWhileItsRunnerLasts() async throws {
    let root = NSTemporaryDirectory() + "oss-ci-grant-\(UUID().uuidString)"
    var api = makeAPI(makeStore())
    api = API(machines: MachineManager(config: ServerConfig(), leasesPath: "\(root)/leases.json"), token: "server-token", cache: nil,
              storage: api.storage, grants: api.grants)
    let url = try api.grants.issueJob(holder: "build-99@ci", runner: "runner1", base: "http://192.168.64.1:7480", live: api.jobGrants)
    #expect(url.absoluteString.hasPrefix("http://192.168.64.1:7480/v1/machines?grant="))
    let grant = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "grant" }?.value)
    let later = Date().addingTimeInterval(600)
    await api.machines.adopt(Lease(id: "mine", platform: .linux, config: "vanilla", name: "oss-lease-linux-mine", holder: "build-99@ci",
                                   state: .ready, created: Date(), expires: later))
    await api.machines.adopt(Lease(id: "theirs", platform: .linux, config: "vanilla", name: "oss-lease-linux-theirs", holder: "other-1@ci",
                                   state: .ready, created: Date(), expires: later))
    // As its bearer: the job's leases alone, whatever holder it names.
    let listed = await Server.route(request("GET", "/v1/machines", holder: "other-1@ci", token: grant), api: api)
    #expect(listed.status == 200)
    #expect(try decoded([Lease].self, listed).map(\.id) == ["mine"])
    #expect(await Server.route(request("GET", "/v1/machines/mine", holder: nil, token: grant), api: api).status == 200)
    #expect(await Server.route(request("GET", "/v1/machines/theirs", holder: nil, token: grant), api: api).status == 404)
    #expect(await Server.route(request("POST", "/v1/machines/theirs/renew", holder: nil, token: grant), api: api).status == 404)
    // As the URL's own grant, the same.
    #expect(await Server.route(request("GET", "/v1/machines/mine?grant=\(grant)", holder: nil, token: nil), api: api).status == 200)
    // Stored objects are the job's.
    let stored = await put(api, Data("artifact".utf8), holder: "alice", token: grant)
    #expect(stored.status == 201)
    #expect(try decoded(StoragePut.self, stored).lease.holder == "build-99@ci")
    // Not what it doesn't open: a grant of its own, the keys, the server's status, CI's jobs.
    for (method, path) in [("POST", "/v1/grants"), ("GET", "/v1/keys"), ("GET", "/v1/status"), ("GET", "/v1/ci/jobs")] {
        #expect(await Server.route(request(method, path, holder: nil, token: grant), api: api).status == 403)
    }
    // Its runner gone: nothing.
    api.jobGrants.close("runner1")
    #expect(await Server.route(request("GET", "/v1/machines", holder: nil, token: grant), api: api).status == 401)
    #expect(await Server.route(request("GET", "/v1/machines/mine?grant=\(grant)", holder: nil, token: nil), api: api).status == 403)
    // Another server's grant (another key) is nothing too.
    let other = GrantKey(key: Data(repeating: 9, count: 32))
    let forged = try other.issueJob(holder: "build-99@ci", runner: "runner2", base: "http://h:1", live: api.jobGrants)
    let forgedGrant = try #require(URLComponents(url: forged, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "grant" }?.value)
    #expect(await Server.route(request("GET", "/v1/machines", holder: nil, token: forgedGrant), api: api).status == 401)
}

@Test func ciJobsAreReadWithTheTokenAndSayWhyWhenOff() async throws {
    var api = makeAPI(makeStore())
    api.ciOff = "no GitHub App"
    let off = await Server.route(request("GET", "/v1/ci/jobs", holder: nil), api: api)
    #expect(off.status == 404)
    #expect(try decoded(APIError.self, off).code == "noCI")
}
#endif
