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
    /// iOS simulators (`ios` leases) at once in the primary instead of on
    /// the server's Mac (docs/primary-vms.md, "iOS: simulators in the
    /// primary"); 0, the default: the server's Mac's, as before. More than
    /// none, every new `ios` lease is the primary's (one already held on the
    /// Mac stays there until it ends), and the primary's memory grows by
    /// `simulatorGigabytes` each (24 + 4 × 2 = 32 GB).
    var simulators = 0
    /// The device type of an `ios` lease in the primary that asks for none
    /// (`--device`): the server's own iPhone base's until now.
    var simulatorDevice = "iPhone 17 Pro"
    /// What the primary needs that its base lacks, as shell lines run by
    /// its guest user (an administrator: Homebrew's owner) once it's ready
    /// and before it lends a slot, again after each of the server's starts
    /// and whenever they change: so each must be safe to run again
    /// (`command -v qemu-system-aarch64 || brew install qemu`).
    var setup: [String] = []

    /// What each simulator adds to the primary's memory: a booted iOS 27
    /// simulator with its app takes about 2 GB, as the budget's estimate
    /// for one on the server's Mac says.
    static let simulatorGigabytes = 2

    init(config: String = "xcode_27_2", cpus: Int = 8, memoryGigabytes: Int = 24, slots: Int = 4, simulators: Int = 0,
         simulatorDevice: String = "iPhone 17 Pro", setup: [String] = []) {
        self.config = config
        self.cpus = cpus
        self.memoryGigabytes = memoryGigabytes
        self.slots = slots
        self.simulators = simulators
        self.simulatorDevice = simulatorDevice
        self.setup = setup
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = PrimaryMacSettings()
        config = try c.decodeIfPresent(String.self, forKey: .config) ?? d.config
        cpus = max(1, try c.decodeIfPresent(Int.self, forKey: .cpus) ?? d.cpus)
        memoryGigabytes = max(4, try c.decodeIfPresent(Int.self, forKey: .memoryGigabytes) ?? d.memoryGigabytes)
        slots = max(0, try c.decodeIfPresent(Int.self, forKey: .slots) ?? d.slots)
        simulators = max(0, try c.decodeIfPresent(Int.self, forKey: .simulators) ?? d.simulators)
        simulatorDevice = try c.decodeIfPresent(String.self, forKey: .simulatorDevice) ?? d.simulatorDevice
        setup = try c.decodeIfPresent([String].self, forKey: .setup) ?? []
    }

    /// The setup as one script for the guest's shell (Guest.run: on its
    /// standard input), Homebrew on the PATH, stopping at the first line
    /// that fails; nil when there is none.
    var setupScript: String? {
        guard !setup.isEmpty else { return nil }
        return (["set -e", "export PATH=\"/opt/homebrew/bin:$PATH\" HOMEBREW_NO_AUTO_UPDATE=1"] + setup).joined(separator: "\n")
    }

    /// What it holds of the budget, and its VM's CPUs and memory: its own,
    /// and its simulators'.
    var size: LeaseSize { LeaseSize(cpus: cpus, memoryBytes: Int64(vmGigabytes) << 30) }

    /// Its VM's memory: `memoryGigabytes`, and `simulatorGigabytes` for each simulator.
    var vmGigabytes: Int { memoryGigabytes + simulators * Self.simulatorGigabytes }

    /// What its lease is called where everyone sees it.
    var label: String { "Primary macOS VM: \(slots) slots" + (simulators > 0 ? ", \(simulators) simulators" : "") }
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
        func slotCount(_ lease: Lease) -> Int { tenants(of: lease.id, held).filter { $0.state != .returning && $0.state != .failed }.count }
        return primaries.sorted { a, b in
            let (sa, sb) = (slotCount(a), slotCount(b))
            if sa != sb { return sa > sb }
            if a.created != b.created { return a.created < b.created }
            return a.id < b.id
        }
    }

    /// Primaries beyond the one kept, without slots or simulators: released.
    static func extras(_ held: [Lease]) -> [Lease] {
        primaryOrder(held).dropFirst().filter { tenants(of: $0.id, held).allSatisfy { $0.state == .returning || $0.state == .failed } }
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
            // Released once no slot or simulator of its is held: a test running in one isn't ended for it.
            guard let lease else { return .none }
            if tenants(of: lease.id, held).contains(where: { $0.state != .returning && $0.state != .failed }) { return .none }
            return .release(lease.id, because: "server.json keeps no primary macOS VM")
        }
        guard let lease else { return restartPending ? .none : .make }
        if lease.state == .creating { return .wait }
        // Replaced for new settings only once no slot or simulator of its
        // is held: a test running in one isn't ended for it.
        if tenants(of: lease.id, held).contains(where: { $0.state != .returning && $0.state != .failed }) { return .check(lease.id) }
        if let why = outdated(lease, settings) { return .release(lease.id, because: why) }
        return .check(lease.id)
    }

    /// Why a primary isn't as server.json says (its base or its size), or
    /// nil: it is replaced once nothing lives in it, and lends nothing new
    /// meanwhile, so what lives in it drains.
    static func outdated(_ lease: Lease, _ settings: PrimaryMacSettings) -> String? {
        if lease.config != settings.config { return "its base is now \(settings.config), not \(lease.config)" }
        if let size = lease.size, size != settings.size { return "its size is now \(settings.cpus) CPUs and \(settings.vmGigabytes) GB" }
        return nil
    }
}

extension PrimaryPlan {
    /// The slots (`mac` leases) on a primary.
    static func slots(of primary: String, _ held: [Lease]) -> [Lease] {
        held.filter { $0.platform == .mac && $0.primary == primary }
    }

    /// What lives in a primary: its slots, and the `ios` leases whose
    /// simulators run there.
    static func tenants(of primary: String, _ held: [Lease]) -> [Lease] {
        held.filter { isTenant($0) && $0.primary == primary }
    }

    /// A slot, or an `ios` lease whose simulator is a primary's (one on the
    /// server's Mac has no primary).
    static func isTenant(_ lease: Lease) -> Bool {
        lease.platform == .mac || (lease.platform == .ios && lease.primary != nil)
    }

    /// Slots and simulators whose primary is gone or going: released with
    /// it (after a restart too: one whose primary didn't come back).
    static func orphans(_ held: [Lease]) -> [Lease] {
        let primaries = Set(held.filter { $0.kind == .primary && $0.state != .returning && $0.state != .failed }.map(\.id))
        return held.filter { isTenant($0) && $0.state != .returning && $0.state != .failed && !primaries.contains($0.primary ?? "") }
    }

    /// Whether a new `ios` lease's simulator is the primary's: server.json
    /// keeps a primary macOS VM with simulators, and the server lends macOS.
    static func simulatorsInPrimary(_ settings: PrimaryMacSettings?, lendsMacOS: Bool) -> Bool {
        lendsMacOS && (settings?.simulators ?? 0) > 0
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
    /// No crash dialogs on the primary's screen: a new user's first run of
    /// com.apple.datamigrator crashes, and its "quit unexpectedly" dialog
    /// sat over every picture a `--gui` run took. Set for the screen's user
    /// before each slot's user is made (the reports are still written).
    static let noCrashDialogs = #"""
        console=$(stat -f %Su /dev/console)
        if [ -n "$console" ] && [ "$console" != root ]; then sudo -u "$console" -H defaults write com.apple.CrashReporter DialogType -string none || true; fi
        """#

    static func makeScript(lease: String, password: String) -> String {
        let user = name(lease)
        let keychain = keychain(lease)
        return """
            set -euo pipefail
            user=\(user)
            \(noCrashDialogs)
            add_user() { sudo sysadminctl -addUser "$user" -fullName "OS Server slot \(lease)" -password '\(password)' -home "/Users/$user" >/dev/null 2>&1 || true; }
            known() { id "$user" >/dev/null 2>&1 && sudo -u "$user" true 2>/dev/null; }
            if ! id "$user" >/dev/null 2>&1; then add_user; fi
            # sysadminctl can return before the directory service knows the
            # user ("sudo: unknown user"): waited for, and asked for again once.
            tries=0
            until known; do
                tries=$((tries + 1))
                if [ "$tries" -eq 30 ]; then add_user; fi
                if [ "$tries" -ge 60 ]; then echo "oss: slot \(lease): the directory service doesn't know $user after 30 s" >&2; exit 1; fi
                sleep 0.5
            done
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
