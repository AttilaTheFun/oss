import Foundation
import Observation
import OSSClient
import OSSMonitorKit
import Security

/// The servers this Monitor watches: each one's name and addresses in the
/// app's defaults, its monitor token in the Keychain. Added from OS Server's
/// connection code (pasted, or its `osmonitor://` link opened), removed
/// here; each watched while the app is in front.
@MainActor @Observable
final class MonitorStore {
    private(set) var monitors: [ServerMonitor] = []
    var selection: String?
    var problem: String?
    /// Canned servers (`-fixture YES`): the proof's screens.
    let isFixture: Bool

    private static let listKey = "servers"

    init() {
        isFixture = UserDefaults.standard.bool(forKey: "fixture")
        if isFixture {
            monitors = [MonitorFixture.monitor(name: "Mac Studio"), MonitorFixture.monitor(name: "MacBook Pro")]
            if UserDefaults.standard.bool(forKey: "fixture.open") { selection = monitors.first?.id }
            return
        }
        monitors = Self.load().map(ServerMonitor.init)
    }

    /// From a code or link; false when it isn't one.
    @discardableResult
    func add(_ text: String) -> Bool {
        guard let connection = MonitorConnection(text) else {
            problem = "That isn't an OS Server connection code."
            return false
        }
        // The same server again (a new code): replaced.
        monitors.removeAll { $0.connection.name == connection.name }
        let monitor = ServerMonitor(connection: connection)
        monitors.append(monitor)
        selection = monitor.id
        problem = nil
        save()
        return true
    }

    func remove(_ monitor: ServerMonitor) {
        monitors.removeAll { $0.id == monitor.id }
        Keychain.delete(account: monitor.connection.name)
        if selection == monitor.id { selection = nil }
        save()
    }

    // MARK: Keeping them

    private struct Kept: Codable {
        var name: String
        var servers: [URL]
    }

    private func save() {
        guard !isFixture else { return }
        let kept = monitors.map { Kept(name: $0.connection.name, servers: $0.connection.servers) }
        UserDefaults.standard.set(try? JSONEncoder().encode(kept), forKey: Self.listKey)
        for monitor in monitors { Keychain.set(monitor.connection.token, account: monitor.connection.name) }
    }

    private static func load() -> [MonitorConnection] {
        guard let data = UserDefaults.standard.data(forKey: listKey),
              let kept = try? JSONDecoder().decode([Kept].self, from: data) else { return [] }
        return kept.compactMap { item in
            Keychain.get(account: item.name).map { MonitorConnection(name: item.name, servers: item.servers, token: $0) }
        }
    }
}

/// The monitor tokens, one generic password a server, this device only.
enum Keychain {
    private static let service = "com.LoganShire.OSMonitor"

    static func set(_ value: String, account: String) {
        delete(account: account)
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                    kSecAttrAccount as String: account, kSecValueData as String: Data(value.utf8),
                                    kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly]
        SecItemAdd(query as CFDictionary, nil)
    }

    static func get(account: String) -> String? {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                    kSecAttrAccount as String: account, kSecReturnData as String: true]
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess, let data = result as? Data else { return nil }
        return String(decoding: data, as: UTF8.self)
    }

    static func delete(account: String) {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                    kSecAttrAccount as String: account]
        SecItemDelete(query as CFDictionary)
    }
}
