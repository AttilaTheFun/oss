import Foundation
import Testing
import OSSClient
@testable import OSSServer

// Who a lease is for (API 8): what `oss` says in a GitHub Actions job, what
// the server takes a lease that says nothing for, and what it keeps.

/// What a GitHub Actions runner sets for a job.
let actionsEnvironment = [
    "GITHUB_ACTIONS": "true", "GITHUB_REPOSITORY": "example/app", "GITHUB_RUN_ID": "18342034123", "GITHUB_RUN_ATTEMPT": "1",
    "GITHUB_WORKFLOW": "CI", "GITHUB_JOB": "test", "GITHUB_SERVER_URL": "https://github.com",
]

@Test func gitHubActionsFillsInACIJob() throws {
    var request = LeaseRequest(platform: .linux, holder: "runner@ci")
    describeOrigin(&request, Arguments(["machine", "lease", "linux"], valued: []), environment: actionsEnvironment)
    #expect(request.kind == .ci)
    #expect(request.label == "example/app · CI #18342034123 · test")
    #expect(request.link == URL(string: "https://github.com/example/app/actions/runs/18342034123"))

    // What's given wins: a label of its own, a link of its own.
    var given = LeaseRequest(platform: .linux)
    describeOrigin(&given, Arguments(["machine", "lease", "linux", "--label=nightly", "--link", "https://example.com/n"],
                                     valued: ["link"]), environment: actionsEnvironment)
    #expect(given.kind == .ci)
    #expect(given.label == "nightly")
    #expect(given.link == URL(string: "https://example.com/n"))

    // Another kind given: nothing of the job's.
    var agent = LeaseRequest(platform: .linux)
    describeOrigin(&agent, Arguments(["machine", "lease", "linux", "--kind=agent"], valued: []), environment: actionsEnvironment)
    #expect(agent.kind == .agent)
    #expect(agent.label == nil && agent.link == nil)
}

@Test func noGitHubActionsNoKind() {
    // Outside Actions, or with any of its variables missing: no kind sent, the server's to take.
    var missing = actionsEnvironment
    missing["GITHUB_RUN_ID"] = nil
    for environment in [[:], missing, actionsEnvironment.merging(["GITHUB_ACTIONS": "false"]) { $1 }] {
        #expect(GitHubActionsJob(environment: environment) == nil)
        var request = LeaseRequest(platform: .macos)
        describeOrigin(&request, Arguments(["machine", "lease", "macos"], valued: []), environment: environment)
        #expect(request.kind == nil && request.label == nil && request.link == nil)
    }
    // A GitHub Enterprise server's address, with its slash.
    var enterprise = actionsEnvironment
    enterprise["GITHUB_SERVER_URL"] = "https://git.example.com/"
    #expect(GitHubActionsJob(environment: enterprise)?.link == URL(string: "https://git.example.com/example/app/actions/runs/18342034123"))
}

@Test func visorHoldersAreSessionsAndAgents() throws {
    #expect(LeaseOrigin.kind(holder: "visor:session-a", platform: .container) == .session)
    for platform in Platform.allCases where platform != .container {
        #expect(LeaseOrigin.kind(holder: "visor:session-a", platform: platform) == .agent)
    }
    #expect(LeaseOrigin.kind(holder: "someone@workstation", platform: .container) == .manual)
    #expect(LeaseOrigin.kind(holder: "someone@workstation", platform: .macos) == .manual)
    #expect(LeaseOrigin.kind(holder: "my-visor:x", platform: .container) == .manual)

    // A kind given is kept, whoever holds it.
    #expect(try LeaseOrigin(LeaseRequest(platform: .container, holder: "visor:s", kind: .agent)).kind == .agent)
    #expect(try LeaseOrigin(LeaseRequest(platform: .ios, holder: "visor:s")).kind == .agent)
    #expect(try LeaseOrigin(LeaseRequest(platform: .container, holder: "visor:s")).kind == .session)
    #expect(try LeaseOrigin(LeaseRequest(platform: .linux)).kind == .manual)
}

@Test func anOldClientsLeaseHasNoFields() throws {
    // A request from a client before API 8: no kind, label or link.
    let body = Data(#"{"platform": "container", "holder": "visor:session-c", "minutes": 0, "container": {"image": "alpine:3.20"}}"#.utf8)
    let request = try JSONDecoder.oss.decode(LeaseRequest.self, from: body)
    #expect(request.kind == nil && request.label == nil && request.link == nil)
    let origin = try LeaseOrigin(request)
    #expect(origin.kind == .session && origin.label == nil && origin.link == nil)

    // A lease from a server before API 8 reads with none.
    let lease = try JSONDecoder.oss.decode(Lease.self, from: Data(#"""
        {"id": "1", "platform": "ios", "config": "iphone", "name": "oss-lease-ios-1", "holder": "h", "state": "ready",
         "created": "2026-11-01T09:00:00Z", "expires": "2026-11-01T10:00:00Z"}
        """#.utf8))
    #expect(lease.kind == nil && lease.label == nil && lease.link == nil)

    // A kind from a newer server reads as manual, not as a status that can't be read.
    let newer = try JSONDecoder.oss.decode(Lease.self, from: Data(#"""
        {"id": "2", "platform": "ios", "config": "iphone", "name": "oss-lease-ios-2", "holder": "h", "state": "ready",
         "created": "2026-11-01T09:00:00Z", "expires": "2026-11-01T10:00:00Z", "kind": "something-new"}
        """#.utf8))
    #expect(newer.kind == .manual)
}

@Test func labelsAndLinksAreChecked() throws {
    let long = String(repeating: "x", count: 300)
    let origin = try LeaseOrigin(LeaseRequest(platform: .linux, label: "  two\nlines\t\(long)  "))
    #expect(origin.label?.hasPrefix("two lines x") == true)
    #expect(origin.label?.count == LeaseOrigin.maxLabel)
    #expect(try LeaseOrigin(LeaseRequest(platform: .linux, label: " \n ")).label == nil)
    for link in ["file:///etc/hosts", "javascript:alert(1)", "https:no-host"] {
        #expect(throws: APIError.self) { try LeaseOrigin(LeaseRequest(platform: .linux, link: URL(string: link)!)) }
    }
    #expect(try LeaseOrigin(LeaseRequest(platform: .linux, link: URL(string: "https://example.com/run/1")!)).link != nil)
}

@Test func kindsLastAcrossARestart() throws {
    let path = NSTemporaryDirectory() + "oss-leases-test-\(UUID().uuidString)/leases.json"
    defer { try? FileManager.default.removeItem(atPath: (path as NSString).deletingLastPathComponent) }
    let now = Date(timeIntervalSince1970: 1_793_534_400)
    var ci = Lease(id: "a1", platform: .linux, config: "dev", name: "oss-lease-linux-a1", holder: "runner@ci", state: .ready,
                   created: now, expires: now.addingTimeInterval(3600))
    ci.take(try LeaseOrigin(LeaseRequest(platform: .linux, holder: "runner@ci", kind: .ci, label: "example/app · CI #1 · test",
                                         link: URL(string: "https://github.com/example/app/actions/runs/1"))))
    var session = Lease(id: "b2", platform: .container, config: "linux", name: "oss-lease-container-b2", holder: "visor:s",
                        state: .ready, created: now, expires: .distantFuture)
    session.take(try LeaseOrigin(LeaseRequest(platform: .container, holder: "visor:s", label: "Release notes")))
    LeaseFile.write([ci, session], to: path)

    let read = Dictionary(uniqueKeysWithValues: LeaseFile.read(path).map { ($0.id, $0) })
    #expect(read["a1"]?.kind == .ci)
    #expect(read["a1"]?.label == "example/app · CI #1 · test")
    #expect(read["a1"]?.link == URL(string: "https://github.com/example/app/actions/runs/1"))
    #expect(read["b2"]?.kind == .session)
    #expect(read["b2"]?.label == "Release notes")
    #expect(read["b2"]?.link == nil)

    // A file a server before API 8 wrote: its leases take their holders' kinds.
    let old = #"""
        [{"id": "c3", "platform": "macos", "config": "dev", "name": "oss-lease-macos-c3", "holder": "visor:s", "state": "ready",
          "created": "2026-11-01T09:00:00Z", "expires": "2026-11-01T10:00:00Z"},
         {"id": "d4", "platform": "android", "config": "phone", "name": "oss-lease-android-d4", "holder": "someone@workstation",
          "state": "ready", "created": "2026-11-01T09:00:00Z", "expires": "2026-11-01T10:00:00Z"}]
        """#
    FileManager.default.createFile(atPath: path, contents: Data(old.utf8))
    let upgraded = Dictionary(uniqueKeysWithValues: LeaseFile.read(path).map { ($0.id, $0.kind) })
    #expect(upgraded == ["c3": .agent, "d4": .manual])
}
