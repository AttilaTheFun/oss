/// What a proof's screens are compared with: the pictures kept at its
/// base (Tests/Proof there), never the commit's own tree's (a pull request
/// replaces the kept picture of each screen it changes, so its own would
/// show every screen it changed as unchanged).
///
/// - a pull request: its base branch, as it is now;
/// - a push: the commit before it on its branch;
/// - a release: the release before it (the highest version tag below its
///   own);
/// - run by hand in CI (workflow_dispatch: proposing a release, or proving
///   an earlier commit to bisect): the release before the commit (the
///   highest version tag among those before it), else the commit before;
/// - run by hand outside CI (no event): main.
///
/// `ref` is what the proof calls it ("main", "v0.12.1"); `revision` what
/// git resolves to its commit, once `fetch` (git fetch's arguments) has
/// brought it into a shallow checkout.
public struct Baseline: Equatable, Sendable {
    public let ref: String
    public let revision: String
    public let fetch: [String]

    public init(ref: String, revision: String, fetch: [String]) {
        self.ref = ref
        self.revision = revision
        self.fetch = fetch
    }

    /// For a workflow's `event` (GITHUB_EVENT_NAME): a pull request's
    /// `baseRef` (GITHUB_BASE_REF), the ref pushed or released (`refName`,
    /// GITHUB_REF_NAME), the commit checked out, and, for a release, the
    /// repository's tags (for a run by hand, those before the commit). Nil where there is none: a release with no
    /// release before it, a pull request that names no base.
    public static func choose(event: String, baseRef: String, refName: String, commit: String, tags: [String] = []) -> Baseline? {
        switch event {
        case "pull_request", "pull_request_target":
            guard !baseRef.isEmpty else { return nil }
            return branch(baseRef)
        case "push":
            return push(commit, named: refName.isEmpty ? "the commit before" : refName)
        case "release":
            guard let before = previousTag(refName, among: tags) else { return nil }
            return tag(before)
        case "workflow_dispatch":
            guard let release = latestTag(among: tags) else { return push(commit, named: "the commit before") }
            return tag(release)
        default:
            return branch("main")
        }
    }

    /// The commit before `commit`.
    static func push(_ commit: String, named name: String) -> Baseline {
        Baseline(ref: name, revision: "\(commit)^", fetch: ["--no-tags", "--depth=2", "origin", commit])
    }

    /// A version tag as it is on origin.
    static func tag(_ name: String) -> Baseline {
        Baseline(ref: name, revision: "refs/tags/\(name)",
                 fetch: ["--no-tags", "--depth=1", "origin", "+refs/tags/\(name):refs/tags/\(name)"])
    }

    /// A branch as it is on origin.
    static func branch(_ name: String) -> Baseline {
        Baseline(ref: name, revision: "refs/remotes/origin/\(name)",
                 fetch: ["--no-tags", "--depth=1", "origin", "+refs/heads/\(name):refs/remotes/origin/\(name)"])
    }

    /// The highest version tag (v1.2.3, as many numbers as it has) below
    /// `tag` among `tags`; others than versions let be.
    public static func previousTag(_ tag: String, among tags: [String]) -> String? {
        guard let current = version(tag) else { return nil }
        return tags.compactMap { other in version(other).map { (other, $0) } }
            .filter { $0.1.lexicographicallyPrecedes(current) }
            .max { $0.1.lexicographicallyPrecedes($1.1) }?.0
    }

    /// The highest version tag among `tags`; others than versions let be.
    public static func latestTag(among tags: [String]) -> String? {
        tags.compactMap { tag in version(tag).map { (tag, $0) } }.max { $0.1.lexicographicallyPrecedes($1.1) }?.0
    }

    /// v1.2.3 as [1, 2, 3]; nil for a tag that is no version.
    static func version(_ tag: String) -> [Int]? {
        guard tag.hasPrefix("v") else { return nil }
        let parts = tag.dropFirst().split(separator: ".", omittingEmptySubsequences: false).map { Int($0) }
        guard !parts.isEmpty, parts.allSatisfy({ $0 != nil }) else { return nil }
        return parts.compactMap { $0 }
    }
}
