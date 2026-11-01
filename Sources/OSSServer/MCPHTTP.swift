import Foundation
import OSSClient

#if canImport(Network)
extension Server {
    /// The MCP port's one route (API 12): JSON-RPC POSTed and answered as
    /// JSON (Streamable HTTP with no stream of its own: no session, no
    /// GET). Every message needs an application's key (`API_KEY`, or as the
    /// bearer) or the server's token; each tool call is made with it through
    /// this server's own API, acting for the caller's `CLIENT_ID` (its
    /// leases `<CLIENT_ID>@<application>`'s), a VM reached with the
    /// server's own key. Files the caller has come by storage and grants.
    static func mcpRoute(_ request: HTTPRequest, api: API, apiPort: Int) async -> HTTPResponse {
        guard request.method == "POST" else {
            return .error("POST JSON-RPC messages here (this server opens no stream)", status: 405)
        }
        let access = Self.access(request, ["v1", "mcp"], api: api)
        if case .refused(let response) = access { return response }
        guard let application = access.application else {
            return .error("an application's key, or the server's token", status: 403)
        }
        guard let message = (try? JSONSerialization.jsonObject(with: request.body)) as? [String: Any] else {
            return .error("a JSON-RPC message", status: 400)
        }
        let secret = request.header(OSSHeaders.apiKey) ?? request.header("authorization")?.replacingOccurrences(of: "Bearer ", with: "") ?? ""
        let clientID = request.header(OSSHeaders.clientID).flatMap { $0.isEmpty ? nil : $0 }
        // This server's own API over loopback (App Transport Security in
        // the app refuses plain HTTP to its tailnet or LAN name, and loopback
        // needs neither), told the host the caller reached this port at, so
        // the URLs it gives (a grant's, forwarded ports) are ones the caller
        // can reach.
        let host = calledHost(request)
        let context = { () async throws -> MCPServer.Context in
            var client = OSSClient(server: URL(string: "http://127.0.0.1:\(apiPort)")!, token: secret)
            client.clientID = clientID
            client.reachedHost = host
            let config = ServerConfig.load()
            let publicKey = FileManager.default.contents(atPath: config.managementKey + ".pub")
                .map { String(decoding: $0, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines) }
            return MCPServer.Context(client: client, holder: clientID ?? application, sshPublicKey: publicKey,
                                     sshIdentity: config.managementKey, localFiles: false)
        }
        guard let answer = await MCPServer.answer(message, context: context) else {
            return HTTPResponse(status: 202, body: Data(), contentType: "application/json")
        }
        return HTTPResponse(status: 200, body: (try? JSONSerialization.data(withJSONObject: answer)) ?? Data(), contentType: "application/json")
    }

    /// The host a request's `Host` header names, without its port: a name,
    /// an IPv4 address or a bracketed IPv6 one; nil for anything else.
    static func calledHost(_ request: HTTPRequest) -> String? {
        guard let given = request.header("host"), !given.isEmpty else { return nil }
        let host: Substring
        if given.hasPrefix("["), let end = given.firstIndex(of: "]") {
            host = given[...end]
        } else {
            host = given.split(separator: ":", maxSplits: 1).first ?? ""
        }
        guard !host.isEmpty, host.allSatisfy({ $0.isLetter || $0.isNumber || ".-:[]".contains($0) }) else { return nil }
        return String(host)
    }
}
#endif
