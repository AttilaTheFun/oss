import Foundation
import OSSClient

// CI's jobs, run by OS Server (0.14): every few seconds it asks GitHub for
// each repository's queued and running workflow runs and their queued jobs
// (conditionally, so an unchanged answer costs no rate limit); a job that
// asks for `self-hosted` and the repository's label is its. Each gets a
// just-in-time runner of its own, in a container leased for it (kind `ci`),
// at most `maxConcurrent` at once, the rest waiting in the order GitHub
// queued them. The runner takes one job, runs it and exits; its container
// goes, and with it whatever the job leased. A runner no job came to (GitHub
// gave it to another) is given up after a few minutes.

/// What a job's runner runs in: OS Server's containers (CIContainers), or
/// a test's fake.
protocol CIRunnerHost: Sendable {
    /// Runners' leases a server before this one left (it ended while they
    /// ran): released, with what their jobs held.
    func releaseLeftovers() async
    /// A container leased for `job`'s runner (for `runnerHolder`) and made
    /// ready, GitHub's runner and oss in it: its lease's id. `CIBusy` when
    /// there's no room for it now.
    func start(_ job: CIJob, holder: String, runnerHolder: String) async throws -> String
    /// What the runner runs with: the job's grant (`OSS_GRANT`, opened here,
    /// in `holder`'s name while the lease lasts) and where its server is.
    func environment(lease: String, holder: String) async throws -> [String: String]
    /// `run.sh --jitconfig` in the lease's container until the runner
    /// exits, each line it writes to `line`: its exit status.
    func run(lease: String, jitConfig: String, environment: [String: String],
             line: @escaping @Sendable (String) -> Void) async throws -> Int32
    /// The lease released (its runner, if it still runs, ends with it), the
    /// job's grant closed, and every lease and stored object of `holder`'s
    /// released too. Asked more than once, the same.
    func release(lease: String, holder: String) async
}

/// No room for a runner now (the server's containers are all leased): the
/// job waits its turn again.
struct CIBusy: Error, CustomStringConvertible {
    var description: String
}

/// How long to wait after a failed look at GitHub: what GitHub said (its
/// rate limit's reset, `Retry-After`), else twice the last wait, from the
/// poll's own interval up to five minutes.
enum CIBackoff {
    static let most: Duration = .seconds(300)

    static func next(after error: Error, previous: Duration?, base: Duration) -> Duration {
        if let said = (error as? GitHubError)?.retryAfter { return max(.seconds(said), base) }
        return min((previous ?? base) * 2, most)
    }
}

actor CIService {
    let plan: CIPlan
    let github: GitHubREST
    let host: any CIRunnerHost
    /// A job waiting for room the server hasn't got is tried again so soon.
    let busyRetry: Duration
    /// Every job seen, by GitHub's id; those that ended kept a week, at most `kept`.
    private var jobs: [Int: CIJob] = [:]
    /// Jobs waiting for a place, in GitHub's order (when it queued them).
    private var queue: [Int] = []
    /// Jobs whose runner is being made or runs.
    private var active: Set<Int> = []
    /// Each runner's registration on GitHub, by its job.
    private var runners: [Int: Int] = [:]
    /// How often each job was offered again after its runner failed.
    private var tries: [Int: Int] = [:]
    private var pollers: [Task<Void, Never>] = []
    static let kept = 200
    /// The most runners a job gets.
    static let attempts = 3

    init(plan: CIPlan, github: GitHubREST, host: any CIRunnerHost, busyRetry: Duration = .seconds(15)) {
        self.plan = plan
        self.github = github
        self.host = host
        self.busyRetry = busyRetry
    }

    /// What a server before this one left is released, then each
    /// repository is looked at every few seconds until `stop`.
    func start() async {
        await host.releaseLeftovers()
        log("ci: running GitHub Actions jobs for " + plan.repositories.map { "\($0.name) (self-hosted, \($0.label))" }.joined(separator: ", ")
            + ", at most \(plan.maxConcurrent) at once, in \(plan.image)")
        for repository in plan.repositories {
            pollers.append(Task { await self.pollForever(repository) })
        }
    }

    func stop() {
        pollers.forEach { $0.cancel() }
        pollers = []
    }

    /// Every job seen, newest first, with how long each waited and ran.
    func list(now: Date = Date()) -> [CIJob] {
        let full = active.count >= plan.maxConcurrent
        return jobs.values.sorted { ($0.queued, $0.id) > ($1.queued, $1.id) }.map { job in
            var job = job.timed(now)
            // Waiting for a place, when every runner is in use.
            if job.state == .queued, job.waiting == nil, full { job.waiting = "every runner in use (\(plan.maxConcurrent) at most)" }
            return job
        }
    }

    /// CI as a whole (API 15).
    func status(now: Date = Date()) -> CIStatus {
        CIStatus(maxConcurrent: plan.maxConcurrent, running: active.count,
                 repositories: plan.repositories.map { CIStatus.Repository(name: $0.name, label: $0.label) }, jobs: list(now: now))
    }

    // MARK: Polling

    private func pollForever(_ repository: CIPlan.Repository) async {
        var backoff: Duration?
        while !Task.isCancelled {
            let wait: Duration
            do {
                try await poll(repository)
                if backoff != nil { log("ci: \(repository.name): GitHub answers again") }
                backoff = nil
                wait = plan.poll
            } catch {
                let next = CIBackoff.next(after: error, previous: backoff, base: plan.poll)
                if backoff == nil { log("ci: \(repository.name): \(error); asking again in \(next), and longer while it fails") }
                backoff = next
                wait = next
            }
            try? await Task.sleep(for: wait)
        }
    }

    /// One look at a repository: its queued and running runs, and the
    /// queued jobs among theirs that are this server's. A run already going
    /// may queue a job later (one that `needs` another), so running runs
    /// are looked at too; an unchanged list costs nothing.
    func poll(_ repository: CIPlan.Repository) async throws {
        let runs = try await github.runs(repository.name, status: "queued") + github.runs(repository.name, status: "in_progress")
        var ids: [Int] = []
        for run in runs where !ids.contains(run.id) { ids.append(run.id) }
        var found: [GitHubREST.Job] = []
        for id in ids {
            found += try await github.jobs(repository.name, run: id)
                .filter { $0.status == "queued" && CINames.matches($0.labels, label: repository.label) }
        }
        await github.forgetRuns(repository.name, keeping: Set(ids))
        offer(found, repository: repository.name)
    }

    /// Queued jobs of a repository's: those not seen before wait their
    /// turn, in the order GitHub queued them, among every repository's.
    func offer(_ found: [GitHubREST.Job], repository: String) {
        for job in found where jobs[job.id] == nil {
            jobs[job.id] = CIJob(id: job.id, repository: repository, workflow: job.workflow_name, name: job.name, runID: job.run_id,
                                 runAttempt: job.run_attempt, url: job.html_url,
                                 runURL: URL(string: "https://github.com/\(repository)/actions/runs/\(job.run_id)"),
                                 branch: job.head_branch, commit: job.head_sha, labels: job.labels, queued: job.created_at)
            queue.append(job.id)
            log("ci: \(repository) job \(job.id) (\(job.workflow_name ?? "a workflow"): \(job.name)) queued")
        }
        queue.sort { (jobs[$0]?.queued ?? .distantFuture, $0) < (jobs[$1]?.queued ?? .distantFuture, $1) }
        pump()
    }

    // MARK: Runners

    /// As many waiting jobs started as there's room for.
    private func pump() {
        while active.count < plan.maxConcurrent, !queue.isEmpty {
            let id = queue.removeFirst()
            active.insert(id)
            Task { await self.launch(id) }
        }
    }

    /// A job's runner made, run and ended: its container leased and made
    /// ready, its just-in-time configuration asked for (named for the
    /// lease), run until it exits or no job comes, then everything released.
    private func launch(_ id: Int) async {
        guard let job = jobs[id] else { return finish(id) }
        // Still queued? It may have been cancelled, or run elsewhere, while it waited.
        if let now = try? await github.job(job.repository, id: id), now.status != "queued" {
            jobs[id]?.state = .skipped
            jobs[id]?.ended = Date()
            jobs[id]?.error = "\(now.status.replacingOccurrences(of: "_", with: " ")) when its turn came"
            return finish(id)
        }
        jobs[id]?.state = .starting
        jobs[id]?.waiting = nil
        let holder = CINames.holder(job)
        let lease: String
        do {
            lease = try await host.start(job, holder: holder, runnerHolder: CINames.runnerHolder(job))
        } catch let busy as CIBusy {
            // Back in its place, tried again in a while.
            jobs[id]?.state = .queued
            jobs[id]?.waiting = busy.description
            active.remove(id)
            queue.insert(id, at: 0)
            log("ci: \(job.repository) job \(id) waits: \(busy)")
            let retry = busyRetry
            Task {
                try? await Task.sleep(for: retry)
                self.pump()
            }
            return
        } catch {
            fail(id, "its container: \(error)")
            await offerAgainIfStillQueued(id)
            return finish(id)
        }
        jobs[id]?.lease = lease
        jobs[id]?.runner = "oss-\(lease)"
        do {
            let config = try await github.jitConfig(job.repository, name: "oss-\(lease)", labels: job.labels)
            runners[id] = config.runner.id
            let environment = try await host.environment(lease: lease, holder: holder)
            log("ci: \(job.repository) job \(id): runner oss-\(lease) starting")
            let unclaimed = plan.unclaimed
            let watchdog = Task {
                try? await Task.sleep(for: unclaimed)
                guard !Task.isCancelled else { return }
                await self.giveUp(id)
            }
            let (lines, continuation) = AsyncStream<String>.makeStream()
            let reader = Task { for await line in lines { self.heard(id, line) } }
            let status: Int32
            do {
                status = try await host.run(lease: lease, jitConfig: config.encoded_jit_config, environment: environment) { continuation.yield($0) }
            } catch {
                continuation.finish()
                watchdog.cancel()
                throw error
            }
            continuation.finish()
            await reader.value
            watchdog.cancel()
            switch jobs[id]?.state {
            case .running:
                jobs[id]?.state = .completed
                jobs[id]?.ended = Date()
                if status != 0, jobs[id]?.result == nil { jobs[id]?.error = "its runner exited \(status)" }
            case .starting, .listening:
                fail(id, "its runner exited \(status) before a job came")
            default:
                break
            }
        } catch {
            fail(id, "\(error)")
        }
        await host.release(lease: lease, holder: holder)
        // A registration no job used goes now (GitHub deletes a used one itself).
        if let runner = runners[id], jobs[id]?.started == nil {
            do { try await github.deleteRunner(job.repository, id: runner) } catch { log("ci: deleting runner oss-\(lease): \(error)") }
        }
        log("ci: \(job.repository) job \(id): \(jobs[id]?.state.rawValue ?? "gone")" + (jobs[id]?.result.map { " (\($0))" } ?? "")
            + (jobs[id]?.error.map { ": \($0)" } ?? ""))
        await offerAgainIfStillQueued(id)
        finish(id)
    }

    /// A job whose runner failed, or took no job, while GitHub still has it
    /// queued (the runner never reached GitHub): forgotten, so the next poll
    /// offers it again, at most `attempts` times.
    private func offerAgainIfStillQueued(_ id: Int) async {
        guard let job = jobs[id], [.failed, .unclaimed].contains(job.state), job.started == nil,
              tries[id, default: 0] < Self.attempts - 1,
              (try? await github.job(job.repository, id: id))?.status == "queued" else { return }
        tries[id, default: 0] += 1
        jobs[id] = nil
        log("ci: \(job.repository) job \(id) is still queued: offered again")
    }

    /// No job came to its runner in time: given up, its container released
    /// (which ends the runner).
    private func giveUp(_ id: Int) async {
        guard let job = jobs[id], [.starting, .listening].contains(job.state), let lease = job.lease else { return }
        jobs[id]?.state = .unclaimed
        jobs[id]?.ended = Date()
        jobs[id]?.error = "no job came to its runner in \(plan.unclaimed) (GitHub gave it to another)"
        await host.release(lease: lease, holder: CINames.holder(job))
    }

    /// A line of its runner's: listening, a job taken, how it went.
    private func heard(_ id: Int, _ line: String) {
        guard let state = jobs[id]?.state, !state.ended else { return }
        if line.contains("Listening for Jobs"), state == .starting {
            jobs[id]?.state = .listening
        } else if line.contains("Running job:") {
            jobs[id]?.state = .running
            if jobs[id]?.started == nil { jobs[id]?.started = Date() }
        } else if let range = line.range(of: "completed with result: ") {
            jobs[id]?.result = line[range.upperBound...].trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }

    private func fail(_ id: Int, _ error: String) {
        guard jobs[id]?.state.ended == false else { return }
        jobs[id]?.state = .failed
        jobs[id]?.ended = Date()
        jobs[id]?.error = error
    }

    /// Its place free for the next; the oldest of those ended let go.
    private func finish(_ id: Int) {
        active.remove(id)
        runners[id] = nil
        let weekAgo = Date().addingTimeInterval(-7 * 24 * 3600)
        let ended = jobs.values.filter { $0.state.ended }.sorted { ($0.ended ?? $0.queued) > ($1.ended ?? $1.queued) }
        for (index, job) in ended.enumerated() where index >= Self.kept || (job.ended ?? job.queued) < weekAgo {
            jobs[job.id] = nil
        }
        pump()
    }
}

/// Lines out of a stream of bytes as they come (a runner's output).
final class LineBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var pending = Data()

    /// The lines `data` finished.
    func add(_ data: Data) -> [String] {
        lock.withLock {
            pending.append(data)
            var lines: [String] = []
            while let end = pending.firstIndex(of: 0x0A) {
                lines.append(String(decoding: pending[pending.startIndex..<end], as: UTF8.self).trimmingCharacters(in: .newlines))
                pending.removeSubrange(pending.startIndex...end)
            }
            return lines
        }
    }

    /// What's left after the last newline, if anything.
    func rest() -> String? {
        lock.withLock {
            defer { pending = Data() }
            return pending.isEmpty ? nil : String(decoding: pending, as: UTF8.self)
        }
    }
}
