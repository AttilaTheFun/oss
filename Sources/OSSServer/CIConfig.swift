import Foundation
import OSSClient

// CI in containers (0.14): OS Server finds a repository's queued GitHub
// Actions jobs that ask for a label it serves and runs each with a
// just-in-time runner in a container of its own (CIService). It needs a
// GitHub App of the owner's (its id and private key, CIAppFiles) and
// server.json's `ci`, which names the repositories it serves for now.

/// server.json's `"ci"`: which repositories OS Server runs jobs for, by
/// which label, and in what. Without it (or without the App's files), CI
/// is off.
struct CISettings: Codable, Sendable, Equatable {
    /// `owner/name`, each a repository whose jobs it runs.
    var repositories: [String] = []
    /// The label a repository's jobs ask for (with `self-hosted`), by
    /// repository: `<name>-ci` where none is given.
    var labels: [String: String] = [:]
    /// The image each job's container runs: Visor's agent image (what CI's
    /// scripts build in) unless given.
    var image: String?
    /// How many jobs at once, across repositories: the App's file's, else
    /// from the Mac's cores and memory (CIDefaults.concurrency).
    var maxConcurrent: Int?
    /// Each job's container's CPUs and memory.
    var cpus: Int?
    var memoryGigabytes: Int?
    /// A repository's own, where its jobs build in their container (a
    /// Bazel build wants more than a job that only leases machines), by
    /// repository: `{"owner/name": {"cpus": 6, "memoryGigabytes": 16}}`.
    var sizes: [String: RunnerSize] = [:]
    /// A repository's job that fills the Bazel cache, on main alone:
    /// `{"owner/name": "populate"}` (the job's name). Its container writes
    /// the cache; every other job's reads it.
    var populate: [String: String] = [:]
    /// Seconds between two looks at a repository's queued jobs.
    var pollSeconds: Int?
    /// Minutes a runner waits for a job before it's given up (GitHub gave
    /// the job to another runner).
    var unclaimedMinutes: Int?
    /// The server as a job's container reaches it (its grant's URL), where
    /// the default (the containers' network's gateway, then the Mac's
    /// other addresses) won't do.
    var serverURL: String?

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        repositories = try c.decodeIfPresent([String].self, forKey: .repositories) ?? []
        labels = try c.decodeIfPresent([String: String].self, forKey: .labels) ?? [:]
        image = try c.decodeIfPresent(String.self, forKey: .image)
        maxConcurrent = try c.decodeIfPresent(Int.self, forKey: .maxConcurrent)
        cpus = try c.decodeIfPresent(Int.self, forKey: .cpus)
        memoryGigabytes = try c.decodeIfPresent(Int.self, forKey: .memoryGigabytes)
        sizes = try c.decodeIfPresent([String: RunnerSize].self, forKey: .sizes) ?? [:]
        populate = try c.decodeIfPresent([String: String].self, forKey: .populate) ?? [:]
        pollSeconds = try c.decodeIfPresent(Int.self, forKey: .pollSeconds)
        unclaimedMinutes = try c.decodeIfPresent(Int.self, forKey: .unclaimedMinutes)
        serverURL = try c.decodeIfPresent(String.self, forKey: .serverURL)
    }

    /// The label `repository`'s jobs ask for.
    func label(_ repository: String) -> String {
        labels[repository] ?? "\(repository.split(separator: "/").last.map(String.init) ?? repository)-ci"
    }
}

/// A repository's job containers' CPUs and memory (CISettings.sizes); what
/// it leaves out is the default's.
struct RunnerSize: Codable, Sendable, Equatable, Hashable {
    var cpus: Int?
    var memoryGigabytes: Int?
}

/// The GitHub App OS Server runs CI as (`~/.config/oss/ci-github-app.json`,
/// `{"appId": N}`, and its private key beside it, `ci-github-app.pem`; both
/// its owner's alone). The App needs Actions read, Administration read and
/// write (a just-in-time runner is a repository's runner) and Metadata
/// read, and no webhook; installed on the repositories it runs jobs for.
struct CIAppConfig: Codable, Sendable, Equatable {
    var appId: Int
    /// The repositories it may serve, where it doesn't serve every one it is
    /// installed on: server.json's are served only if listed here too.
    var repositories: [String]?
    var maxConcurrent: Int?
}

/// The App's two files, read with their permissions checked: neither
/// there is CI off (nil); one without the other, or either readable by
/// anyone but their owner, is refused, saying why.
enum CIAppFiles {
    static let configName = "ci-github-app.json"
    static let keyName = "ci-github-app.pem"

    struct Loaded: Sendable {
        var config: CIAppConfig
        /// The private key's PEM, never logged.
        var pem: String
    }

    static func load(directory: String = Paths.clientDirectory) throws -> Loaded? {
        let configPath = "\(directory)/\(configName)", keyPath = "\(directory)/\(keyName)"
        let manager = FileManager.default
        let hasConfig = manager.fileExists(atPath: configPath), hasKey = manager.fileExists(atPath: keyPath)
        guard hasConfig || hasKey else { return nil }
        guard hasConfig else { throw APIError(error: "\(keyPath) without \(configName) beside it (its App's id: {\"appId\": N})") }
        guard hasKey else { throw APIError(error: "\(configPath) without \(keyName) beside it (its App's private key)") }
        for path in [configPath, keyPath] { try ownerOnly(path) }
        guard let data = manager.contents(atPath: configPath) else { throw APIError(error: "\(configPath) can't be read") }
        let config: CIAppConfig
        do {
            config = try JSONDecoder().decode(CIAppConfig.self, from: data)
        } catch {
            throw APIError(error: "\(configPath) isn't {\"appId\": N, \"repositories\"?: [...], \"maxConcurrent\"?: N}")
        }
        guard config.appId > 0 else { throw APIError(error: "\(configPath): appId is the App's id, a number") }
        guard let key = manager.contents(atPath: keyPath), let pem = String(data: key, encoding: .utf8),
              pem.contains("PRIVATE KEY-----") else { throw APIError(error: "\(keyPath) isn't a PEM private key") }
        return Loaded(config: config, pem: pem)
    }

    /// Refused if anyone but its owner may read or write it (mode 600 or 400).
    static func ownerOnly(_ path: String) throws {
        let attributes = try FileManager.default.attributesOfItem(atPath: path)
        let value = attributes[.posixPermissions]
        guard let mode = (value as? NSNumber)?.intValue ?? (value as? Int) else { throw APIError(error: "\(path)'s mode can't be read") }
        guard mode & 0o077 == 0 else {
            throw APIError(error: "\(path) is mode \(String(mode & 0o777, radix: 8)): its owner's alone, chmod 600 it")
        }
    }
}

/// What CI runs when nothing says otherwise.
enum CIDefaults {
    /// Visor's agent image (Ubuntu, Swift, Bazel's needs, Rosetta's
    /// x86_64 glibc): what CI's scripts build in already.
    static let image = "ghcr.io/attilathefun/visor-agent:0.41.2"
    /// GitHub's runner for Linux on arm64, pinned and checked: downloaded
    /// once to OS Server's folder and put in each job's container.
    static let runnerVersion = "2.338.2"
    static let runnerSHA256 = "670adb2f268fe21dcbb58b3db0e0aa9d5b3bddfe2c651481336e561ff86de945"
    static var runnerURL: URL {
        URL(string: "https://github.com/actions/runner/releases/download/v\(runnerVersion)/actions-runner-linux-arm64-\(runnerVersion).tar.gz")!
    }
    static let cpus = 4
    /// A job's container: its runner and what the job runs in it (a
    /// Linux build, scripts that lease machines). 4 GB: a job holds it while
    /// it waits for those machines, and the budget is shared.
    static let memoryGigabytes = 4
    static let pollSeconds = 5
    static let unclaimedMinutes = 10

    /// Jobs at once where nothing says: one for every 8 cores and every
    /// 32 GB (a job's container takes 4 and 8, and its machines more), at
    /// most half the containers the server lends (a job may lease one
    /// beneath it), at least one.
    static func concurrency(cores: Int, memoryBytes: UInt64, containerCapacity: Int) -> Int {
        max(1, min(cores / 8, Int(memoryBytes / (32 << 30)), containerCapacity / 2))
    }
}

/// CI as this server runs it: its settings and the App's, put together.
struct CIPlan: Sendable, Equatable {
    struct Repository: Sendable, Equatable, Hashable {
        var name: String
        var label: String
        /// Its jobs' containers, where it has a size of its own.
        var cpus: Int?
        var memoryGigabytes: Int?
        /// Its job (by name) that writes the Bazel cache, on main.
        var populate: String?

        /// Whether `job` is the one that fills the cache: its name, on main.
        func populates(_ job: CIJob) -> Bool { populate != nil && job.name == populate && job.branch == "main" }
    }

    var appID: Int
    var repositories: [Repository]
    var maxConcurrent: Int
    var image: String
    var cpus: Int
    var memoryGigabytes: Int
    var poll: Duration
    var unclaimed: Duration
    var serverURL: String?

    /// Nil (with why) when CI is off: no `ci` in server.json, no
    /// repository named there (or none the App's file allows).
    static func make(settings: CISettings?, app: CIAppConfig, cores: Int = ProcessInfo.processInfo.activeProcessorCount,
                     memoryBytes: UInt64 = ProcessInfo.processInfo.physicalMemory, containerCapacity: Int) -> (CIPlan?, String?) {
        guard let settings else { return (nil, "server.json has no \"ci\" naming its repositories") }
        let named = settings.repositories.filter { name in
            let parts = name.split(separator: "/")
            return parts.count == 2 && parts.allSatisfy { !$0.isEmpty }
        }
        let allowed = app.repositories.map { list in named.filter { name in list.contains { $0.lowercased() == name.lowercased() } } } ?? named
        guard !allowed.isEmpty else {
            return (nil, named.isEmpty ? "server.json's ci names no repository (owner/name)"
                                       : "none of server.json's ci repositories is among the App's file's")
        }
        var seen = Set<String>()
        let repositories = allowed.filter { seen.insert($0.lowercased()).inserted }.map { name in
            let size = settings.sizes[name] ?? settings.sizes.first { $0.key.lowercased() == name.lowercased() }?.value
            let populate = settings.populate[name] ?? settings.populate.first { $0.key.lowercased() == name.lowercased() }?.value
            return Repository(name: name, label: settings.label(name), cpus: size?.cpus.map { max(1, $0) },
                              memoryGigabytes: size?.memoryGigabytes.map { max(1, $0) }, populate: populate)
        }
        let concurrent = settings.maxConcurrent ?? app.maxConcurrent
            ?? CIDefaults.concurrency(cores: cores, memoryBytes: memoryBytes, containerCapacity: containerCapacity)
        return (CIPlan(appID: app.appId, repositories: repositories, maxConcurrent: max(1, concurrent),
                       image: settings.image ?? CIDefaults.image, cpus: max(1, settings.cpus ?? CIDefaults.cpus),
                       memoryGigabytes: max(1, settings.memoryGigabytes ?? CIDefaults.memoryGigabytes),
                       poll: .seconds(max(2, settings.pollSeconds ?? CIDefaults.pollSeconds)),
                       unclaimed: .seconds(60 * max(1, settings.unclaimedMinutes ?? CIDefaults.unclaimedMinutes)),
                       serverURL: settings.serverURL), nil)
    }
}

/// The names a job's leases go by.
enum CINames {
    /// A job's name as a holder's part: letters, digits, `.`, `_` and `-`,
    /// at most 60 of them.
    static func slug(_ name: String) -> String {
        var slug = ""
        for character in name.lowercased() {
            if character.isASCII && (character.isLetter || character.isNumber || "._".contains(character)) {
                slug.append(character)
            } else if !slug.hasSuffix("-") {
                slug.append("-")
            }
        }
        slug = String(slug.trimmingCharacters(in: CharacterSet(charactersIn: "-")).prefix(60))
        return slug.isEmpty ? "job" : slug
    }

    /// Whom the job's own leases and objects are for: `<job>-<run>@ci`, the
    /// job's name as GitHub gives it (its id in the workflow unless it has a
    /// `name:`), as a workflow's `OSS_CLIENT_ID` with the `ci` key makes them.
    static func holder(_ job: CIJob) -> String { "\(slug(job.name))-\(job.runID)@ci" }

    /// Whom its runner's container is for: beside the job's, not one of them
    /// (the job doesn't release its own runner).
    static func runnerHolder(_ job: CIJob) -> String { "\(slug(job.name))-\(job.runID)-runner@ci" }

    /// Whether a job is one this server runs for `label`: it asks for
    /// `self-hosted` and the label, and nothing else (any case).
    static func matches(_ labels: [String], label: String) -> Bool {
        Set(labels.map { $0.lowercased() }) == ["self-hosted", label.lowercased()]
    }

    /// The labels on a runner's lease, by which OS Server finds what a
    /// server before it left running.
    static let runnerLabel = "oss.ci.runner"
    static let holderLabel = "oss.ci.holder"
}
