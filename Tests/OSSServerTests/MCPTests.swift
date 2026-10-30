#if canImport(Network)
import Foundation
import Testing
import OSSClient
@testable import OSSServer

// The MCP port (API 12): JSON-RPC POSTed with an application's key; each
// tool call made through the server's own API with that key, acting for the
// caller's CLIENT_ID. Here the API is the test's, reached in-process.

/// The server's API in this process: what a client sends is routed as
/// the server would route it, and the headers it carried are kept.
private struct InProcess: OSSTransport {
    let api: API
    let sent = Sent()

    final class Sent: @unchecked Sendable {
        private let lock = NSLock()
        private var headers: [[String: String]] = []
        func add(_ value: [String: String]) { lock.withLock { headers.append(value) } }
        var all: [[String: String]] { lock.withLock { headers } }
    }

    func send(_ request: OSSHTTPRequest) async throws -> OSSHTTPResponse {
        let headers = Dictionary(request.headers.map { ($0.key.lowercased(), $0.value) }, uniquingKeysWith: { $1 })
        sent.add(headers)
        var path = request.url.path
        if let query = request.url.query { path += "?" + query }
        let answer = await Server.route(HTTPRequest(method: request.method, path: path, headers: headers, body: request.body ?? Data(),
                                                    remoteAddress: "127.0.0.1"), api: api)
        return OSSHTTPResponse(status: answer.status, headers: ["content-type": answer.contentType], body: answer.body)
    }
}

private func keyed() throws -> (api: API, key: String) {
    var api = makeAPI(makeStore())
    api.keys = APIKeys(path: NSTemporaryDirectory() + "oss-mcp-test-\(UUID().uuidString)/keys.json")
    return (api, try api.keys.make("mac-mini-visor"))
}

private func post(_ message: [String: Any], headers: [String: String], api: API) async throws -> HTTPResponse {
    let body = try JSONSerialization.data(withJSONObject: message)
    return await Server.mcpRoute(HTTPRequest(method: "POST", path: "/", headers: headers, body: body, remoteAddress: "127.0.0.1"),
                                 api: api, apiPort: 1)
}

@Test func theMCPPortTakesAKeyAndListsTheTools() async throws {
    let (api, key) = try keyed()
    let list: [String: Any] = ["jsonrpc": "2.0", "id": 1, "method": "tools/list"]
    #expect(try await post(list, headers: [:], api: api).status == 401, "no key, no tools")
    #expect(try await post(list, headers: ["api_key": "oss_wrong"], api: api).status == 401)
    let get = await Server.mcpRoute(HTTPRequest(method: "GET", path: "/", headers: ["api_key": key], body: Data()), api: api, apiPort: 1)
    #expect(get.status == 405, "no stream of its own")

    let listed = try await post(list, headers: ["api_key": key], api: api)
    #expect(listed.status == 200)
    let tools = (try JSONSerialization.jsonObject(with: listed.body) as? [String: Any])?["result"] as? [String: Any]
    let names = (tools?["tools"] as? [[String: Any]] ?? []).compactMap { $0["name"] as? String }
    #expect(names.contains("oss_lease") && names.contains("oss_container_lease") && names.contains("oss_exec") && names.contains("oss_grant"))
    // A notification needs no answer.
    let noted = try await post(["jsonrpc": "2.0", "method": "notifications/initialized"], headers: ["api_key": key], api: api)
    #expect(noted.status == 202 && noted.body.isEmpty)
}

@Test func aToolCallIsMadeWithTheCallersKeyForItsClient() async throws {
    let (api, key) = try keyed()
    let transport = InProcess(api: api)
    var client = OSSClient(server: URL(string: "http://127.0.0.1:7480")!, token: key, transport: transport)
    client.clientID = "S1"
    let context = MCPServer.Context(client: client, holder: "S1", sshPublicKey: nil, sshIdentity: nil, localFiles: false)

    let status = await MCPServer.call("oss_status", [:], context: context)
    let said = ((status["content"] as? [[String: Any]])?.first?["text"] as? String) ?? ""
    #expect(status["isError"] as? Bool == false, "\(said)")
    #expect(said.contains("you hold no machines"))
    let stored = await MCPServer.call("oss_storage", [:], context: context)
    #expect(((stored["content"] as? [[String: Any]])?.first?["text"] as? String) == "you keep nothing in storage")

    let headers = try #require(transport.sent.all.last)
    #expect(headers["authorization"] == "Bearer \(key)", "the caller's own key")
    #expect(headers["client_id"] == "S1")
    // A lease of the caller's application, by its client, is the caller's.
    #expect(MCPServer.isMine("S1@mac-mini-visor", context: context))
    #expect(!MCPServer.isMine("S2@mac-mini-visor", context: context))
}

@Test func theAPIIsReachedAtTheHostTheCallerUsed() {
    func host(_ header: String?) -> String? {
        Server.calledHost(HTTPRequest(method: "POST", path: "/", headers: header.map { ["host": $0] } ?? [:], body: Data()))
    }
    #expect(host("mini.example.ts.net:7481") == "mini.example.ts.net")
    #expect(host("100.64.0.9:7481") == "100.64.0.9")
    #expect(host("[fd7a::1]:7481") == "[fd7a::1]")
    #expect(host(nil) == nil)
    #expect(host("evil.example/path") == nil)
}

@Test func aContainerCommandIsStoppedAfterItsTime() async throws {
    await #expect(throws: MCPServer.Failure.self) {
        try await MCPServer.withTimeout(0.05) {
            try await Task.sleep(for: .seconds(5))
            return 0
        }
    }
    #expect(try await MCPServer.withTimeout(5) { 7 } == 7)
}
#endif
