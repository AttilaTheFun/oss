#if canImport(Network)
import Foundation
import Testing
import OSSClient
@testable import OSSServer

// API keys (API 12): each an application's, kept as a digest; a request
// carries one as API_KEY or as its bearer, and with CLIENT_ID acts for
// `<CLIENT_ID>@<application>`; the shared token stands for `user`. Keys are
// managed on the server's own Mac, as user.

/// Keys in a file of their own.
private func makeKeys() -> APIKeys {
    APIKeys(path: NSTemporaryDirectory() + "oss-keys-test-\(UUID().uuidString)/keys.json")
}

private func keyedAPI(_ keys: APIKeys) -> API {
    var api = makeAPI(makeStore())
    api.keys = keys
    return api
}

private func asking(_ headers: [String: String], method: String = "GET", path: String = "/v1/status", from address: String? = nil) -> HTTPRequest {
    HTTPRequest(method: method, path: path, headers: headers, body: Data(), remoteAddress: address)
}

@Test func aKeyIsKeptAsItsDigestAndNamesItsApplication() throws {
    let keys = makeKeys()
    let key = try keys.make("ci")
    #expect(keys.application(for: key) == "ci")
    #expect(keys.application(for: key + "x") == nil)
    #expect(keys.application(for: "") == nil)
    let kept = try String(contentsOfFile: keys.path, encoding: .utf8)
    #expect(!kept.contains(key), "never the key itself")
    let mode = try FileManager.default.attributesOfItem(atPath: keys.path)[.posixPermissions] as? Int
    #expect(mode == 0o600)
    // Made again, the old one stops working; removed, the new one too.
    let again = try keys.make("ci")
    #expect(keys.application(for: key) == nil && keys.application(for: again) == "ci")
    #expect(try keys.remove("ci"))
    #expect(keys.application(for: again) == nil)
    #expect(throws: APIError.self) { try keys.make("Not A Name") }
}

@Test func aRequestCarriesAKeyOrTheToken() throws {
    let keys = makeKeys()
    let key = try keys.make("mac-mini-visor")
    let api = keyedAPI(keys)
    let parts = ["v1", "status"]
    guard case .key(let byHeader) = Server.access(asking(["api_key": key]), parts, api: api) else { Issue.record("no key"); return }
    #expect(byHeader == "mac-mini-visor")
    guard case .key(let byBearer) = Server.access(asking(["authorization": "Bearer \(key)"]), parts, api: api) else { Issue.record("no bearer key"); return }
    #expect(byBearer == "mac-mini-visor")
    guard case .refused = Server.access(asking(["api_key": "oss_wrong"]), parts, api: api) else { Issue.record("a wrong key let in"); return }
    guard case .token = Server.access(asking(["authorization": "Bearer server-token"]), parts, api: api) else { Issue.record("the token"); return }
    #expect(Access.token.application == "user", "the token stands for user")
}

@Test func aKeyedRequestActsForItsClientWithinItsApplication() {
    let key = Access.key("mac-mini-visor")
    #expect(Server.actingHolder(key, asking(["client_id": "S1"]), named: "visor:S1") == "S1@mac-mini-visor")
    #expect(Server.actingHolder(key, asking([:]), named: "visor:S1") == "visor:S1@mac-mini-visor", "the holder it names, in its application")
    #expect(Server.actingHolder(key, asking([:]), named: "S1@mac-mini-visor") == "S1@mac-mini-visor", "not twice")
    #expect(Server.actingHolder(Access.key("ci"), asking([:]), named: nil) == "ci")
    // The token: as before, unless it gives a client id.
    #expect(Server.actingHolder(.token, asking([:]), named: "alice") == "alice")
    #expect(Server.actingHolder(.token, asking(["client_id": "job-7"]), named: "alice") == "job-7@user")
}

@Test func aKeyedHolderSaysItsKind() {
    #expect(LeaseOrigin.kind(holder: "S1@mac-mini-visor", platform: .container) == .session)
    #expect(LeaseOrigin.kind(holder: "S1@mac-mini-visor", platform: .ios) == .agent)
    #expect(LeaseOrigin.kind(holder: "job-7@ci", platform: .macos) == .ci)
    #expect(LeaseOrigin.kind(holder: "me@user", platform: .macos) == .manual)
    #expect(LeaseOrigin.kind(holder: "visor:S1", platform: .container) == .session, "as before keys")
}

@Test func keysAreManagedOnTheServersMacAsUser() throws {
    let keys = makeKeys()
    let api = keyedAPI(keys)
    var request = asking([:], method: "POST", path: "/v1/keys", from: "127.0.0.1")
    request.body = try JSONEncoder.oss.encode(APIKeyRequest(application: "ci"))
    let answer = try Server.keysRoute(request, ["v1", "keys"], access: .token, api: api)
    #expect(answer.status == 201)
    let key = try JSONDecoder.oss.decode(APIKeyMade.self, from: answer.body).key
    #expect(keys.application(for: key) == "ci")
    // Another application's key can't make keys, nor can another computer.
    #expect(try Server.keysRoute(request, ["v1", "keys"], access: .key("ci"), api: api).status == 403)
    var far = request
    far.remoteAddress = "203.0.113.9"
    #expect(try Server.keysRoute(far, ["v1", "keys"], access: .token, api: api).status == 403)
    let listed = try Server.keysRoute(asking([:], path: "/v1/keys", from: "::1"), ["v1", "keys"], access: .key("user"), api: api)
    #expect(try JSONDecoder.oss.decode([APIKeyInfo].self, from: listed.body).map(\.application) == ["ci"])
}
#endif
