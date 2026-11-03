import Foundation
import OSSClient
#if canImport(CryptoKit)
import CryptoKit
#endif

// The primary VMs (docs/primary-vms.md): the owner (2026-10-31, 2026-11-01,
// 2026-11-02) wants the host Mac to run no tests or simulators of its own,
// apps and tests to run in primary VMs that OS Server keeps running, and CI
// to lease a slot on one rather than a whole GUI VM. This is the first of
// them, the macOS one: a lease of OS Server's own (kind `primary`, holder
// `primary@oss`), its memory held from the budget, made at start and kept:
// checked every minute, released and made again when it stops answering or
// its settings change. Its slots (`mac` leases) come next.

/// server.json's `primary`: the primary VMs to keep.
struct PrimarySettings: Codable, Equatable, Sendable {
    /// The macOS one, if any: `{"macos": {}}` keeps one of the defaults.
    var macos: PrimaryMacSettings?

    init(macos: PrimaryMacSettings? = nil) {
        self.macos = macos
    }
}

/// The primary macOS VM: the base it is cloned from, its size and how
/// many slots it lends. One of the two macOS VMs Apple allows.
struct PrimaryMacSettings: Codable, Equatable, Sendable {
    /// Its base's config: Xcode's, for tests.
    var config = "xcode_27_2"
    var cpus = 8
    var memoryGigabytes = 24
    /// Slots (`mac` leases) at once.
    var slots = 4
    /// What the primary needs that its base lacks, as shell lines run by
    /// its guest user (an administrator: Homebrew's owner) once it's ready
    /// and before it lends a slot, again after each of the server's starts
    /// and whenever they change: so each must be safe to run again
    /// (`command -v qemu-system-aarch64 || brew install qemu`).
    var setup: [String] = []

    init(config: String = "xcode_27_2", cpus: Int = 8, memoryGigabytes: Int = 24, slots: Int = 4, setup: [String] = []) {
        self.config = config
        self.cpus = cpus
        self.memoryGigabytes = memoryGigabytes
        self.slots = slots
        self.setup = setup
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = PrimaryMacSettings()
        config = try c.decodeIfPresent(String.self, forKey: .config) ?? d.config
        cpus = max(1, try c.decodeIfPresent(Int.self, forKey: .cpus) ?? d.cpus)
        memoryGigabytes = max(4, try c.decodeIfPresent(Int.self, forKey: .memoryGigabytes) ?? d.memoryGigabytes)
        slots = max(0, try c.decodeIfPresent(Int.self, forKey: .slots) ?? d.slots)
        setup = try c.decodeIfPresent([String].self, forKey: .setup) ?? []
    }

    /// The setup as one script for the guest's shell (Guest.run: on its
    /// standard input), Homebrew on the PATH, stopping at the first line
    /// that fails; nil when there is none.
    var setupScript: String? {
        guard !setup.isEmpty else { return nil }
        return (["set -e", "export PATH=\"/opt/homebrew/bin:$PATH\" HOMEBREW_NO_AUTO_UPDATE=1"] + setup).joined(separator: "\n")
    }

    /// What it holds of the budget, and its VM's CPUs and memory.
    var size: LeaseSize { LeaseSize(cpus: cpus, memoryBytes: Int64(memoryGigabytes) << 30) }
}

/// What keeping the primary asks for now.
enum PrimaryStep: Equatable {
    /// Nothing: none is wanted and none is held, or a restart is pending.
    case none
    /// None is held: make it.
    case make
    /// It is being made: wait.
    case wait
    /// It is ready: see that it answers.
    case check(String)
    /// Released: it is no longer wanted (server.json has none), or no longer
    /// as server.json says (its config or size changed), and the next step
    /// makes it again.
    case release(String, because: String)
}

enum PrimaryPlan {
    /// Whom the primary's lease is for.
    static let holder = "primary@oss"
    /// Checks in a row it doesn't answer before it is made again.
    static let misses = 3

    /// The macOS primary of the leases held, if any: the one kept when
    /// there are more (primaryOrder).
    static func macos(_ held: [Lease]) -> Lease? {
        primaryOrder(held).first
    }

    /// The macOS primaries held, the one to keep first: one with slots held,
    /// then the oldest (then by id, so the order is the same every time).
    static func primaryOrder(_ held: [Lease]) -> [Lease] {
        let primaries = held.filter { $0.kind == .primary && $0.platform == .macos && $0.state != .returning && $0.state != .failed }
        func slotCount(_ lease: Lease) -> Int { slots(of: lease.id, held).filter { $0.state != .returning && $0.state != .failed }.count }
        return primaries.sorted { a, b in
            let (sa, sb) = (slotCount(a), slotCount(b))
            if sa != sb { return sa > sb }
            if a.created != b.created { return a.created < b.created }
            return a.id < b.id
        }
    }

    /// Primaries beyond the one kept, without slots: released.
    static func extras(_ held: [Lease]) -> [Lease] {
        primaryOrder(held).dropFirst().filter { slots(of: $0.id, held).allSatisfy { $0.state == .returning || $0.state == .failed } }
    }

    /// The next step for the macOS primary: wanted where server.json has one
    /// and the server lends macOS; never begun while a restart is pending.
    static func step(_ settings: PrimaryMacSettings?, lendsMacOS: Bool, restartPending: Bool, held: [Lease]) -> PrimaryStep {
        // Only one is kept: any other (a second one made by mistake) goes,
        // the oldest and those with slots kept first.
        if let extra = extras(held).first {
            return .release(extra.id, because: "a second primary macOS VM: \(primaryOrder(held).first?.id ?? "") is kept")
        }
        let lease = macos(held)
        guard let settings, lendsMacOS else {
            // Released once no slot of its is held: a test running in one isn't ended for it.
            guard let lease else { return .none }
            if slots(of: lease.id, held).contains(where: { $0.state != .returning && $0.state != .failed }) { return .none }
            return .release(lease.id, because: "server.json keeps no primary macOS VM")
        }
        guard let lease else { return restartPending ? .none : .make }
        if lease.state == .creating { return .wait }
        // Replaced for new settings only once no slot of its is held: a
        // test running in one isn't ended for it.
        if slots(of: lease.id, held).contains(where: { $0.state != .returning && $0.state != .failed }) { return .check(lease.id) }
        if lease.config != settings.config {
            return .release(lease.id, because: "its base is now \(settings.config), not \(lease.config)")
        }
        if let size = lease.size, size != settings.size {
            return .release(lease.id, because: "its size is now \(settings.cpus) CPUs and \(settings.memoryGigabytes) GB")
        }
        return .check(lease.id)
    }
}

extension PrimaryPlan {
    /// The slots (`mac` leases) on a primary.
    static func slots(of primary: String, _ held: [Lease]) -> [Lease] {
        held.filter { $0.platform == .mac && $0.primary == primary }
    }

    /// Slots whose primary is gone or going: released with it.
    static func orphans(_ held: [Lease]) -> [Lease] {
        let primaries = Set(held.filter { $0.kind == .primary && $0.state != .returning && $0.state != .failed }.map(\.id))
        return held.filter { $0.platform == .mac && $0.state != .returning && $0.state != .failed && !primaries.contains($0.primary ?? "") }
    }
}

/// A slot's user on the primary (docs/primary-vms.md): `oss-<lease>`, made
/// at lease with a home and a login keychain of its own (a user that never
/// logs in has none, and tests that keep a token need one), deleted with its
/// files at release. Its scripts run on the primary as its guest user, who
/// has sudo, through Guest.run: read from standard input, so the passwords
/// in them are on no command line of the server's.
enum SlotUser {
    static func name(_ lease: String) -> String { "oss-\(lease)" }

    static func keychain(_ lease: String) -> String { "/Users/\(name(lease))/Library/Keychains/login.keychain-db" }

    /// The user made, its home, its keychain made, its default and unlocked
    /// (no locking on sleep or idle). `password` is the server's for the
    /// slot: the user's own (it never logs in) and its keychain's, as
    /// `sysadminctl -addUser` makes the user's login keychain with its
    /// password. A keychain that won't unlock with it (one left by an
    /// earlier user of the name) is made again. The keychain's commands run
    /// in the user's own bootstrap (`launchctl asuser`), which securityd
    /// wants of a user with no login session, and can't fail the slot: a
    /// test that keeps no token needs none, and one that does says so; what
    /// went wrong is in the script's standard error, for the server's log.
    static func makeScript(lease: String, password: String) -> String {
        let user = name(lease)
        let keychain = keychain(lease)
        return """
            set -euo pipefail
            user=\(user)
            if ! id "$user" >/dev/null 2>&1; then
                sudo sysadminctl -addUser "$user" -fullName "OS Server slot \(lease)" -password '\(password)' -home "/Users/$user" >/dev/null 2>&1
            fi
            sudo createhomedir -c -u "$user" >/dev/null
            sudo -u "$user" -H mkdir -p "/Users/$user/Library/Keychains"
            uid=$(id -u "$user")
            as_user() { sudo launchctl asuser "$uid" sudo -u "$user" -H "$@"; }
            # In a function, chained by &&: errexit is off in an if's condition.
            make_keychain() {
                as_user security unlock-keychain -p '\(password)' '\(keychain)' 2>/dev/null || {
                    as_user rm -f '\(keychain)' &&
                    as_user security create-keychain -p '\(password)' '\(keychain)' &&
                    as_user security unlock-keychain -p '\(password)' '\(keychain)'
                } || return 1
                as_user security list-keychains -d user -s '\(keychain)' &&
                as_user security default-keychain -d user -s '\(keychain)' &&
                as_user security set-keychain-settings '\(keychain)'
            }
            make_keychain || echo "oss: slot \(lease): its keychain wasn't made; the slot has none" >&2
            id "$user"
            """
    }

    /// The slot's keychain unlocked (before a run or a command), in the
    /// user's own bootstrap.
    static func unlockScript(lease: String, password: String) -> String {
        let user = name(lease)
        return "sudo launchctl asuser \"$(id -u \(user))\" sudo -u \(user) -H security unlock-keychain -p '\(password)' '\(keychain(lease))'"
    }

    /// The user's processes ended, the user deleted, its home with it (and
    /// its commands' pid files).
    static func deleteScript(lease: String) -> String {
        let user = name(lease)
        return """
            user=\(user)
            sudo pkill -9 -u "$user" 2>/dev/null || true
            sudo rm -f /tmp/oss-exec-\(lease)-*.pid
            if id "$user" >/dev/null 2>&1; then
                sudo sysadminctl -deleteUser "$user" >/dev/null 2>&1 || sudo dscl . -delete "/Users/$user" || true
            fi
            sudo rm -rf "/Users/$user"
            """
    }
}

/// A slot's keychain password: derived from the server's management key and
/// the lease (so it is kept nowhere, and shown to no one), the same each
/// time it's asked, to unlock the keychain before a run.
enum SlotSecrets {
    static func keychainPassword(_ lease: String, key: String) -> String {
        let secret = FileManager.default.contents(atPath: key) ?? Data(key.utf8)
        #if canImport(CryptoKit)
        let mac = HMAC<SHA256>.authenticationCode(for: Data("oss slot keychain \(lease)".utf8), using: SymmetricKey(data: secret))
        return mac.map { String(format: "%02x", $0) }.joined()
        #else
        // FNV-1a over the key and the lease: steady (a hashValue isn't from
        // one process to the next). No slot runs off a Mac.
        var hash: UInt64 = 0xcbf29ce484222325
        for byte in secret + Data("oss slot keychain \(lease)".utf8) { hash = (hash ^ UInt64(byte)) &* 0x100000001b3 }
        return String(hash, radix: 16)
        #endif
    }
}

extension LeaseBudget {
    /// The budget as a client sees it: its waiting line without the leases
    /// of platforms the client can't read (a slot's, below API 17).
    func visible(_ isVisible: (Platform) -> Bool) -> LeaseBudget {
        var budget = self
        budget.waiting = waiting.filter { isVisible($0.platform) }
        return budget
    }
}
