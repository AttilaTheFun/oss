#if canImport(Network)
import Foundation
import Testing
@testable import OSSServer

// `/v1/hello` is answered by the listener at once, without a task, so a
// client finding its server never waits behind the server's work; every
// other request still goes to the handler.

@Test func helloIsAnsweredAtOnce() throws {
    for path in ["/v1/hello", "/v1/hello/", "/v1/hello?probe=1"] {
        let answer = try #require(Server.immediate(HTTPRequest(method: "GET", path: path, headers: [:], body: Data())))
        #expect(answer.status == 200)
        let hello = try JSONDecoder().decode([String: String].self, from: answer.body)
        #expect(hello["server"] == "oss")
        #expect(hello["host"] == localHostName)
    }
}

@Test func otherRequestsGoToTheHandler() {
    for path in ["/v1/status", "/v1/machines", "/v1/hellos", "/"] {
        #expect(Server.immediate(HTTPRequest(method: "GET", path: path, headers: [:], body: Data())) == nil)
    }
}

// The MCP port calls this server's own API over loopback, naming the host
// its caller reached; that name is honoured from loopback alone.
@Test func reachedHostFromLoopbackOnly() {
    func request(from address: String?, forwarded: String?) -> HTTPRequest {
        var headers = ["host": "127.0.0.1:7480"]
        if let forwarded { headers["oss-reached-host"] = forwarded }
        var request = HTTPRequest(method: "GET", path: "/v1/status", headers: headers, body: Data())
        request.remoteAddress = address
        return request
    }
    #expect(Server.reachedHost(request(from: "127.0.0.1", forwarded: "mac.example.ts.net")) == "mac.example.ts.net")
    #expect(Server.reachedHost(request(from: "::1", forwarded: "mac.example.ts.net")) == "mac.example.ts.net")
    #expect(Server.reachedHost(request(from: "100.64.0.9", forwarded: "evil.example")) == "127.0.0.1")
    #expect(Server.reachedHost(request(from: "127.0.0.1", forwarded: nil)) == "127.0.0.1")
    #expect(Server.reachedHost(request(from: "127.0.0.1", forwarded: "bad host/../")) == "127.0.0.1")
}
#endif
