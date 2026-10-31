import Foundation
import OSSClient
#if canImport(Security)
import Security
#endif

// GitHub, as CI's App (CIAppFiles): a JWT signed with the App's private
// key (RS256) asks for each installation's token, which the REST calls
// carry. Neither the key, the JWT nor a token is ever logged, nor handed
// to a job: a job's runner gets its just-in-time configuration alone.

/// An RSA private key from a PEM: PKCS #1 (`BEGIN RSA PRIVATE KEY`, what
/// GitHub gives) or PKCS #8 (`BEGIN PRIVATE KEY`).
struct RSAPrivateKey: Sendable {
    /// The key as PKCS #1's DER.
    let pkcs1: Data

    init(pem: String) throws {
        let lines = pem.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }
        guard let begin = lines.firstIndex(where: { $0.hasPrefix("-----BEGIN ") && $0.hasSuffix("PRIVATE KEY-----") }),
              let end = lines[begin...].firstIndex(where: { $0.hasPrefix("-----END ") }) else {
            throw APIError(error: "the App's key isn't a PEM private key")
        }
        guard let der = Data(base64Encoded: lines[(begin + 1)..<end].joined()) else { throw APIError(error: "the App's key's PEM isn't base64") }
        switch lines[begin] {
        case "-----BEGIN RSA PRIVATE KEY-----": pkcs1 = der
        case "-----BEGIN PRIVATE KEY-----": pkcs1 = try Self.unwrapPKCS8(der)
        default: throw APIError(error: "the App's key isn't an RSA private key (\(lines[begin]))")
        }
    }

    /// PKCS #8's PrivateKeyInfo: SEQUENCE { INTEGER version, SEQUENCE {
    /// OID rsaEncryption, NULL }, OCTET STRING <PKCS #1> }.
    static func unwrapPKCS8(_ der: Data) throws -> Data {
        var outer = DER(der)
        var info = DER(try outer.read(tag: 0x30))
        _ = try info.read(tag: 0x02)
        var algorithm = DER(try info.read(tag: 0x30))
        let rsaEncryption = Data([0x2A, 0x86, 0x48, 0x86, 0xF7, 0x0D, 0x01, 0x01, 0x01])
        guard try algorithm.read(tag: 0x06) == rsaEncryption else { throw APIError(error: "the App's key isn't an RSA key") }
        return try info.read(tag: 0x04)
    }

    /// RS256: RSASSA-PKCS1-v1_5 with SHA-256, by Apple's Security framework
    /// (OS Server runs on a Mac; elsewhere there's none to sign with).
    func sign(_ message: Data) throws -> Data {
        #if canImport(Security)
        let attributes: [String: Any] = [kSecAttrKeyType as String: kSecAttrKeyTypeRSA, kSecAttrKeyClass as String: kSecAttrKeyClassPrivate]
        var error: Unmanaged<CFError>?
        guard let key = SecKeyCreateWithData(pkcs1 as CFData, attributes as CFDictionary, &error) else {
            throw APIError(error: "the App's key can't be used: \(error.map { "\($0.takeRetainedValue())" } ?? "unknown")")
        }
        guard let signature = SecKeyCreateSignature(key, .rsaSignatureMessagePKCS1v15SHA256, message as CFData, &error) else {
            throw APIError(error: "signing with the App's key: \(error.map { "\($0.takeRetainedValue())" } ?? "unknown")")
        }
        return signature as Data
        #else
        throw APIError(error: "RS256 is signed with Apple's Security framework: CI's App needs OS Server on a Mac")
        #endif
    }
}

/// Just enough DER to read PKCS #8's wrapping: a tag, its length, its bytes.
struct DER {
    private let bytes: [UInt8]
    private var index = 0

    init(_ data: Data) { bytes = Array(data) }

    mutating func read(tag: UInt8) throws -> Data {
        guard index + 2 <= bytes.count, bytes[index] == tag else { throw APIError(error: "the App's key's DER isn't what PKCS #8 says") }
        index += 1
        var length = Int(bytes[index])
        index += 1
        if length & 0x80 != 0 {
            let count = length & 0x7F
            guard count > 0, count <= 4, index + count <= bytes.count else { throw APIError(error: "the App's key's DER has a bad length") }
            length = bytes[index..<(index + count)].reduce(0) { $0 << 8 | Int($1) }
            index += count
        }
        guard length >= 0, index + length <= bytes.count else { throw APIError(error: "the App's key's DER is cut short") }
        defer { index += length }
        return Data(bytes[index..<(index + length)])
    }
}

/// The App's JWT: RS256, issued a minute ago (clocks drift), good for nine
/// minutes (GitHub takes ten at most), the App's id its issuer.
enum GitHubAppJWT {
    static func make(appID: Int, now: Date, sign: (Data) throws -> Data) throws -> String {
        let issued = Int(now.timeIntervalSince1970) - 60
        let header = Data(#"{"alg":"RS256","typ":"JWT"}"#.utf8).base64URL
        let payload = Data(#"{"iat":\#(issued),"exp":\#(issued + 600),"iss":\#(appID)}"#.utf8).base64URL
        let input = "\(header).\(payload)"
        return "\(input).\(try sign(Data(input.utf8)).base64URL)"
    }
}

/// A refusal from GitHub, or no answer: its status (0 for none), its
/// message, and how long to wait before asking again when it said
/// (a rate limit's reset, `Retry-After`).
struct GitHubError: Error, CustomStringConvertible, Sendable {
    var status: Int
    var message: String
    var retryAfter: TimeInterval?

    var description: String { status == 0 ? message : "GitHub \(status): \(message)" }

    /// From an answer that isn't a success: a rate limit (403 or 429 with
    /// none left, or a `Retry-After`) says when to come back.
    static func from(_ answer: OSSHTTPResponse, now: Date = Date()) -> GitHubError {
        let body = (try? JSONSerialization.jsonObject(with: answer.body) as? [String: Any])?["message"] as? String
        var retry: TimeInterval?
        if let seconds = answer.headers["retry-after"].flatMap(TimeInterval.init) {
            retry = seconds
        } else if [403, 429].contains(answer.status), answer.headers["x-ratelimit-remaining"] == "0",
                  let reset = answer.headers["x-ratelimit-reset"].flatMap(TimeInterval.init) {
            retry = max(1, reset - now.timeIntervalSince1970)
        } else if answer.status == 429 {
            retry = 60
        }
        return GitHubError(status: answer.status, message: body ?? String(decoding: answer.body.prefix(200), as: UTF8.self), retryAfter: retry)
    }
}

/// The App's credentials: its JWT, each repository's installation and
/// each installation's token, kept until five minutes before it expires.
actor GitHubApp {
    let appID: Int
    let api: URL
    private let sign: @Sendable (Data) throws -> Data
    private let transport: any OSSTransport
    private let now: @Sendable () -> Date
    private var installations: [String: Int] = [:]
    private var tokens: [Int: (token: String, expires: Date)] = [:]

    init(appID: Int, sign: @escaping @Sendable (Data) throws -> Data, transport: any OSSTransport,
         api: URL = URL(string: "https://api.github.com")!, now: @escaping @Sendable () -> Date = { Date() }) {
        self.appID = appID
        self.sign = sign
        self.transport = transport
        self.api = api
        self.now = now
    }

    static func headers(_ authorization: String) -> [String: String] {
        ["Authorization": "Bearer \(authorization)", "Accept": "application/vnd.github+json", "X-GitHub-Api-Version": "2022-11-28",
         "User-Agent": "OS-Server/\(OSS.version)"]
    }

    /// A token for `repository`'s installation.
    func token(for repository: String) async throws -> String {
        let installation = try await installation(of: repository)
        if let kept = tokens[installation], kept.expires.timeIntervalSince(now()) > 300 { return kept.token }
        struct Answer: Decodable {
            var token: String
            var expires_at: Date
        }
        let answer: Answer = try await appRequest("POST", "/app/installations/\(installation)/access_tokens")
        tokens[installation] = (answer.token, answer.expires_at)
        return answer.token
    }

    /// Forgotten after a 401 with it: asked for again next time.
    func forget(_ repository: String) {
        if let installation = installations.removeValue(forKey: repository.lowercased()) { tokens[installation] = nil }
    }

    private func installation(of repository: String) async throws -> Int {
        if let known = installations[repository.lowercased()] { return known }
        struct Answer: Decodable { var id: Int }
        do {
            let answer: Answer = try await appRequest("GET", "/repos/\(repository)/installation")
            installations[repository.lowercased()] = answer.id
            return answer.id
        } catch let error as GitHubError where error.status == 404 {
            throw GitHubError(status: 404, message: "the App (\(appID)) isn't installed on \(repository)", retryAfter: 300)
        }
    }

    /// A request as the App itself (its JWT).
    private func appRequest<T: Decodable>(_ method: String, _ path: String) async throws -> T {
        let jwt = try GitHubAppJWT.make(appID: appID, now: now(), sign: sign)
        let request = OSSHTTPRequest(method: method, url: api.appendingPathComponent(path), headers: Self.headers(jwt), timeout: 30)
        let answer: OSSHTTPResponse
        do {
            answer = try await transport.send(request)
        } catch {
            throw GitHubError(status: 0, message: "GitHub didn't answer: \(error)")
        }
        guard (200..<300).contains(answer.status) else { throw GitHubError.from(answer, now: now()) }
        do {
            return try JSONDecoder.oss.decode(T.self, from: answer.body)
        } catch {
            throw GitHubError(status: answer.status, message: "an answer to \(method) \(path) that isn't what it should be")
        }
    }
}

/// What CI asks GitHub for, with a repository's installation token: its
/// queued and running workflow runs and their jobs (each asked again only
/// if it changed: `If-None-Match` with the last answer's ETag, which costs
/// no rate limit when nothing has), a job's state, a just-in-time runner,
/// and a runner deleted.
actor GitHubREST {
    let app: GitHubApp
    private let transport: any OSSTransport
    /// The last answer to each GET, by its URL: its ETag and its body.
    private var kept: [URL: (etag: String, body: Data)] = [:]

    init(app: GitHubApp, transport: any OSSTransport) {
        self.app = app
        self.transport = transport
    }

    struct Run: Decodable, Sendable, Equatable {
        var id: Int
        var name: String?
        var status: String?
        var html_url: URL?
        var head_branch: String?
        var head_sha: String?
        var run_attempt: Int?
    }

    struct Job: Decodable, Sendable, Equatable {
        var id: Int
        var run_id: Int
        var name: String
        var status: String
        var labels: [String]
        var created_at: Date
        var html_url: URL?
        var run_url: URL?
        var workflow_name: String?
        var head_branch: String?
        var head_sha: String?
        var run_attempt: Int?
        var runner_name: String?
    }

    struct JITConfig: Decodable, Sendable {
        struct Runner: Decodable, Sendable { var id: Int }
        var runner: Runner
        var encoded_jit_config: String
    }

    /// `repository`'s runs with this status (`queued`, `in_progress`), newest first.
    func runs(_ repository: String, status: String) async throws -> [Run] {
        struct Answer: Decodable { var workflow_runs: [Run] }
        return try await get(repository, "/repos/\(repository)/actions/runs", query: ["status": status, "per_page": "100"],
                             as: Answer.self).workflow_runs
    }

    /// A run's jobs (its latest attempt's).
    func jobs(_ repository: String, run: Int) async throws -> [Job] {
        struct Answer: Decodable { var jobs: [Job] }
        return try await get(repository, "/repos/\(repository)/actions/runs/\(run)/jobs", query: ["per_page": "100"], as: Answer.self).jobs
    }

    /// One job, as it is now.
    func job(_ repository: String, id: Int) async throws -> Job {
        try await get(repository, "/repos/\(repository)/actions/jobs/\(id)", query: [:], as: Job.self, keep: false)
    }

    /// The kept answers for runs no longer looked at, forgotten.
    func forgetRuns(_ repository: String, keeping: Set<Int>) {
        let prefix = "/repos/\(repository)/actions/runs/"
        kept = kept.filter { url, _ in
            guard url.path.hasPrefix(prefix), let id = Int(url.path.dropFirst(prefix.count).split(separator: "/").first ?? "") else { return true }
            return keeping.contains(id)
        }
    }

    /// A runner for one job (`--jitconfig`), with `labels`, in the
    /// repository's default runner group: its id and its configuration.
    func jitConfig(_ repository: String, name: String, labels: [String]) async throws -> JITConfig {
        let body: [String: Any] = ["name": name, "runner_group_id": 1, "labels": labels, "work_folder": "_work"]
        let answer = try await send(repository, "POST", "/repos/\(repository)/actions/runners/generate-jitconfig", query: [:],
                                    body: try JSONSerialization.data(withJSONObject: body), headers: [:])
        guard (200..<300).contains(answer.status) else { throw GitHubError.from(answer) }
        do {
            return try JSONDecoder.oss.decode(JITConfig.self, from: answer.body)
        } catch {
            throw GitHubError(status: answer.status, message: "a just-in-time configuration that isn't one")
        }
    }

    /// A runner's registration deleted (one whose job never came).
    func deleteRunner(_ repository: String, id: Int) async throws {
        let answer = try await send(repository, "DELETE", "/repos/\(repository)/actions/runners/\(id)", query: [:], body: nil, headers: [:])
        guard (200..<300).contains(answer.status) || answer.status == 404 else { throw GitHubError.from(answer) }
    }

    private func get<T: Decodable>(_ repository: String, _ path: String, query: [String: String], as type: T.Type,
                                   keep: Bool = true) async throws -> T {
        let url = Self.url(app.api, path, query)
        let previous = keep ? kept[url] : nil
        let answer = try await send(repository, "GET", path, query: query, body: nil,
                                    headers: previous.map { ["If-None-Match": $0.etag] } ?? [:])
        let body: Data
        if answer.status == 304, let previous {
            body = previous.body
        } else {
            guard (200..<300).contains(answer.status) else { throw GitHubError.from(answer) }
            body = answer.body
            if keep, let etag = answer.headers["etag"] { kept[url] = (etag, body) }
        }
        do {
            return try JSONDecoder.oss.decode(T.self, from: body)
        } catch {
            throw GitHubError(status: answer.status, message: "an answer to GET \(path) that isn't what it should be")
        }
    }

    /// A request with the repository's installation token; one refused as
    /// unauthorized has the token asked for again next time.
    private func send(_ repository: String, _ method: String, _ path: String, query: [String: String], body: Data?,
                      headers: [String: String]) async throws -> OSSHTTPResponse {
        let token = try await app.token(for: repository)
        var all = GitHubApp.headers(token).merging(headers) { $1 }
        if body != nil { all["Content-Type"] = "application/json" }
        let request = OSSHTTPRequest(method: method, url: Self.url(app.api, path, query), headers: all, body: body, timeout: 30)
        let answer: OSSHTTPResponse
        do {
            answer = try await transport.send(request)
        } catch {
            throw GitHubError(status: 0, message: "GitHub didn't answer: \(error)")
        }
        if answer.status == 401 { await app.forget(repository) }
        return answer
    }

    static func url(_ api: URL, _ path: String, _ query: [String: String]) -> URL {
        var components = URLComponents(url: api.appendingPathComponent(path), resolvingAgainstBaseURL: false)!
        if !query.isEmpty { components.queryItems = query.sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) } }
        return components.url!
    }
}
