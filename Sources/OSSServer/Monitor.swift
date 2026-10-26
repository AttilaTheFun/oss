import Foundation
import OSSClient

/// OS Monitor's access: a token of its own, kept beside the server's, that
/// reads what the server is doing (its status, usage and cache) and nothing
/// else. It can lease nothing, release nothing, run nothing; the cache's
/// read token is left out of what it reads. OS Server's Settings show it
/// in a connection code (`MonitorConnection`), with the server's addresses;
/// a new code makes a new token, and every Monitor given the old one stops.
public enum MonitorAccess {
    static var path: String { "\(Paths.config)/monitor-token" }

    static func token() -> String {
        if let data = FileManager.default.contents(atPath: path) {
            let token = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            if !token.isEmpty { return token }
        }
        return rotate()
    }

    @discardableResult
    static func rotate() -> String {
        Paths.ensure(Paths.config)
        let token = Random.hex(32)
        FileManager.default.createFile(atPath: path, contents: Data((token + "\n").utf8), attributes: [.posixPermissions: 0o600])
        return token
    }

    /// What a Monitor may ask with the monitor token.
    static func allows(_ method: String, _ parts: [String]) -> Bool {
        method == "GET" && parts.count == 2 && parts[0] == "v1" && ["status", "usage", "cache"].contains(parts[1])
    }

    /// The code that connects OS Monitor to this server: its name, the
    /// addresses another computer reaches it at, and the monitor token.
    public static func connection(newToken: Bool = false) -> MonitorConnection {
        let token = newToken ? rotate() : token()
        let port = ServerConfig.load().port
        let urls = addresses().compactMap { URL(string: "http://\($0):\(port)") }
        return MonitorConnection(name: computerName, servers: urls, token: token)
    }

    /// The Mac's own name for people, the one Sharing shows; its host name
    /// where there is none (Linux).
    static var computerName: String {
        #if os(macOS)
        if let name = Host.current().localizedName, !name.isEmpty { return name }
        #endif
        return localHostName.replacingOccurrences(of: ".local", with: "")
    }

    /// This Mac's addresses for another computer, nearest first: on its LAN
    /// (a private range on an Ethernet or Wi-Fi interface), on the tailnet
    /// (100.64.0.0/10), then its Bonjour name. Not its VMs' and containers'
    /// networks (bridges), which no other computer reaches.
    static func addresses() -> [String] {
        var list: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&list) == 0, let first = list else { return ["\(localHostName)"] }
        defer { freeifaddrs(list) }
        var lan: [String] = [], tailnet: [String] = []
        for pointer in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let entry = pointer.pointee
            let name = String(cString: entry.ifa_name)
            guard let address = entry.ifa_addr, address.pointee.sa_family == sa_family_t(AF_INET),
                  !name.hasPrefix("bridge"), !name.hasPrefix("lo"), !name.hasPrefix("vmnet") else { continue }
            let value = address.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { UInt32(bigEndian: $0.pointee.sin_addr.s_addr) }
            let dotted = LocalNetworks.dotted(value)
            if value & 0xFFC0_0000 == 0x6440_0000 {
                tailnet.append(dotted)                       // 100.64.0.0/10
            } else if value >> 24 == 10 || value & 0xFFF0_0000 == 0xAC10_0000 || value & 0xFFFF_0000 == 0xC0A8_0000 {
                lan.append(dotted)                           // 10/8, 172.16/12, 192.168/16
            }
        }
        let bonjour = localHostName.hasSuffix(".local") ? localHostName : localHostName + ".local"
        return lan + tailnet + [bonjour]
    }
}
