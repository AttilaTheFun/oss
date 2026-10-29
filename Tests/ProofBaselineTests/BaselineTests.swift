import ProofBaseline
import Testing

// What a proof's screens are compared with (tools/ci/proof_baseline), for
// each kind of run: a pull request's base branch, a push's commit before,
// a release's release before, main by hand; and the release before among
// a repository's tags.

private let commit = "3b86b9c0aa1c2b3d4e5f60718293a4b5c6d7e8f9"

@Test func aPullRequestIsComparedWithItsBaseBranch() {
    #expect(Baseline.choose(event: "pull_request", baseRef: "main", refName: "46/merge", commit: commit)
        == Baseline(ref: "main", revision: "refs/remotes/origin/main",
                    fetch: ["--no-tags", "--depth=1", "origin", "+refs/heads/main:refs/remotes/origin/main"]))
    #expect(Baseline.choose(event: "pull_request", baseRef: "oss-0.10", refName: "46/merge", commit: commit)?.ref == "oss-0.10")
    #expect(Baseline.choose(event: "pull_request", baseRef: "", refName: "46/merge", commit: commit) == nil)
}

@Test func aPushIsComparedWithTheCommitBefore() {
    #expect(Baseline.choose(event: "push", baseRef: "", refName: "main", commit: commit)
        == Baseline(ref: "main", revision: commit + "^", fetch: ["--no-tags", "--depth=2", "origin", commit]))
}

@Test func aReleaseIsComparedWithTheReleaseBefore() {
    let tags = ["v0.9.2", "v0.10.1", "v0.9.10", "inbox", "v0.10.0", "v1.0", "v0.11.0", "vnext"]
    #expect(Baseline.choose(event: "release", baseRef: "", refName: "v0.10.1", commit: commit, tags: tags)
        == Baseline(ref: "v0.10.0", revision: "refs/tags/v0.10.0",
                    fetch: ["--no-tags", "--depth=1", "origin", "+refs/tags/v0.10.0:refs/tags/v0.10.0"]))
    #expect(Baseline.previousTag("v0.10.0", among: tags) == "v0.9.10", "by number, not by letter")
    #expect(Baseline.previousTag("v1.0.0", among: tags) == "v1.0")
    #expect(Baseline.previousTag("v0.9.2", among: tags) == nil, "the first release has none before it")
    #expect(Baseline.choose(event: "release", baseRef: "", refName: "v0.9.2", commit: commit, tags: tags) == nil)
    #expect(Baseline.previousTag("latest", among: tags) == nil)
}

@Test func byHandItIsMain() {
    #expect(Baseline.choose(event: "", baseRef: "", refName: "", commit: commit)?.revision == "refs/remotes/origin/main")
}
