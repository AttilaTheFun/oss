import Foundation

// CI's jobs (API 13): OS Server finds a repository's queued GitHub Actions
// jobs that ask for a label it serves, and runs each in a container of its
// own with a just-in-time runner for that job alone. `GET /v1/ci/jobs`
// lists what it has seen, newest first.

/// Where a job OS Server took is.
public enum CIJobState: String, Codable, CaseIterable, Sendable {
    /// Waiting for a place (at most `maxConcurrent` runners at once).
    case queued
    /// Its container being made, its runner registering.
    case starting
    /// Its runner is listening for the job.
    case listening
    /// Its runner took a job and runs it.
    case running
    /// Its runner ran a job and exited (`result`: GitHub's word for how it went).
    case completed
    /// No job came to its runner in time (GitHub gave it to another
    /// runner): its container is gone, its registration deleted.
    case unclaimed
    /// No longer queued when its turn came (cancelled, or taken elsewhere).
    case skipped
    /// OS Server couldn't make its runner (`error` says why).
    case failed

    /// A state this build doesn't know (a newer server's) reads as `failed`.
    public init(from decoder: Decoder) throws {
        self = CIJobState(rawValue: try decoder.singleValueContainer().decode(String.self)) ?? .failed
    }

    /// Whether it is over: its container gone, its place free.
    public var ended: Bool { [.completed, .unclaimed, .skipped, .failed].contains(self) }
}

/// A GitHub Actions job OS Server took, and how it went.
public struct CIJob: Codable, Sendable, Hashable, Identifiable {
    /// GitHub's job id.
    public var id: Int
    /// `owner/name`.
    public var repository: String
    public var workflow: String?
    /// The job's name, as its run's page shows it.
    public var name: String
    public var runID: Int
    public var runAttempt: Int?
    /// The job's page, and its run's.
    public var url: URL?
    public var runURL: URL?
    public var branch: String?
    public var commit: String?
    /// The labels it asked for (`self-hosted` and the one OS Server serves
    /// for its repository), which its runner was given.
    public var labels: [String]
    public var state: CIJobState
    /// When GitHub queued it, when its runner took it, when it ended.
    public var queued: Date
    public var started: Date?
    public var ended: Date?
    /// Seconds it waited (queued to started, or to now) and ran (started
    /// to ended, or to now), as the server counted them when it answered.
    public var waited: TimeInterval?
    public var ran: TimeInterval?
    /// Its container's lease, and its runner's name (`oss-<lease>`).
    public var lease: String?
    public var runner: String?
    /// How its runner said the job went (`Succeeded`, `Failed`, `Canceled`).
    public var result: String?
    public var error: String?

    public init(id: Int, repository: String, workflow: String? = nil, name: String, runID: Int, runAttempt: Int? = nil,
                url: URL? = nil, runURL: URL? = nil, branch: String? = nil, commit: String? = nil, labels: [String],
                state: CIJobState = .queued, queued: Date) {
        self.id = id
        self.repository = repository
        self.workflow = workflow
        self.name = name
        self.runID = runID
        self.runAttempt = runAttempt
        self.url = url
        self.runURL = runURL
        self.branch = branch
        self.commit = commit
        self.labels = labels
        self.state = state
        self.queued = queued
    }

    /// With `waited` and `ran` counted to `now`.
    public func timed(_ now: Date = Date()) -> CIJob {
        var job = self
        job.waited = max(0, (started ?? (state.ended ? ended : nil) ?? now).timeIntervalSince(queued))
        job.ran = started.map { max(0, (ended ?? now).timeIntervalSince($0)) }
        return job
    }
}

extension OSSClient {
    /// The CI jobs the server took (API 13), newest first; 404 `noCI` from
    /// a server that runs none.
    public func ciJobs() async throws -> [CIJob] { try await json("GET", "/v1/ci/jobs") }
}
