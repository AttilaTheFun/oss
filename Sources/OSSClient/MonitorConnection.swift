import Foundation

/// How OS Monitor reaches a server: its name, its addresses in the order to
/// try them (this Mac's LAN, the tailnet, its .local name), and the server's
/// monitor token, which reads (`status`, `usage`, `capabilities`, `cache`)
/// and can do nothing else. OS Server's Settings show it as a link,
/// `osmonitor://connect?code=<code>`, the code being this as JSON in
/// base64url.
public struct MonitorConnection: Codable, Sendable, Hashable {
    public var name: String
    public var servers: [URL]
    public var token: String

    public init(name: String, servers: [URL], token: String) {
        self.name = name
        self.servers = servers
        self.token = token
    }

    public var code: String {
        let data = (try? JSONEncoder().encode(self)) ?? Data()
        return data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    public var link: URL {
        var components = URLComponents()
        components.scheme = "osmonitor"
        components.host = "connect"
        components.queryItems = [URLQueryItem(name: "code", value: code)]
        return components.url!
    }

    /// From the link, or the code alone (pasted).
    public init?(_ text: String) {
        var code = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if let components = URLComponents(string: code), components.scheme == "osmonitor",
           let value = components.queryItems?.first(where: { $0.name == "code" })?.value {
            code = value
        }
        var base64 = code.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while base64.count % 4 != 0 { base64 += "=" }
        guard let data = Data(base64Encoded: base64),
              let connection = try? JSONDecoder().decode(MonitorConnection.self, from: data),
              !connection.servers.isEmpty, !connection.token.isEmpty else { return nil }
        self = connection
    }
}
