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
#endif
