#if canImport(Network)
import CryptoKit
import Foundation
import Testing
import OSSClient
@testable import OSSServer

// Storage and grants, through the API's own functions (no listener): each
// test's store is a folder of its own, its server's token "server-token".

/// A body that has all come.
struct DataBody: RequestBody {
    var data: Data
    /// Set when the server reads it (a put refused first never does).
    let wasRead = Flag()

    final class Flag: @unchecked Sendable {
        var value = false
    }

    func proceed() async -> Bool { true }

    func read(_ sink: (Data) throws -> Void) async throws -> Bool {
        wasRead.value = true
        try sink(data)
        return true
    }
}

func hex(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }

/// A store in a folder of its own, its caps in bytes.
func makeStore(maxBytes: Int64 = 100_000_000_000, perHolder: Int64 = 20_000_000_000) -> StorageStore {
    let root = NSTemporaryDirectory() + "oss-storage-test-\(UUID().uuidString)"
    var config = StorageConfig()
    config.maxGigabytes = Double(maxBytes) / 1_000_000_000
    config.maxGigabytesPerHolder = Double(perHolder) / 1_000_000_000
    return StorageStore(directory: "\(root)/sha256", incoming: "\(root)/incoming", statePath: "\(root)/storage-leases.json", config: config)
}

/// The API around a store: no machines lent, no cache, a grant key of its own.
func makeAPI(_ store: StorageStore) -> API {
    API(machines: MachineManager(config: ServerConfig()), token: "server-token", cache: nil, storage: store,
        grants: GrantKey(key: Data(repeating: 7, count: 32)))
}

func request(_ method: String, _ path: String, holder: String? = "alice", token: String? = "server-token",
             headers: [String: String] = [:]) -> HTTPRequest {
    var all = headers
    if let token { all["authorization"] = "Bearer \(token)" }
    if let holder { all["oss-holder"] = holder }
    return HTTPRequest(method: method, path: path, headers: all, body: Data())
}

/// A put, its body streamed as the server reads one.
func put(_ api: API, _ data: Data, path: String = "/v1/storage/objects", holder: String? = "alice", token: String? = "server-token",
         headers: [String: String] = [:], body: DataBody? = nil) async -> HTTPResponse {
    var headers = headers
    headers["content-length"] = String(data.count)
    let answer = await Server.streamed(request("PUT", path, holder: holder, token: token, headers: headers),
                                       body: body ?? DataBody(data: data), api: api)
    guard case .response(let response) = answer else { return .error("a put answered with bytes", status: 0) }
    return response
}

/// A get's answer: its status, and (when it's the object) closed again.
func get(_ api: API, _ path: String, holder: String? = "alice", token: String? = "server-token") async -> Int {
    switch await Server.streamed(request("GET", path, holder: holder, token: token), body: DataBody(data: Data()), api: api) {
    case .response(let response): return response.status
    case .object(let hash, _, _):
        await api.storage.close(hash)
        return 200
    }
}

func decoded<T: Decodable>(_ type: T.Type, _ response: HTTPResponse) throws -> T {
    try JSONDecoder.oss.decode(T.self, from: response.body)
}

func grantToken(_ grant: Grant) -> String {
    URLComponents(string: grant.path)?.queryItems?.first { $0.name == "grant" }?.value ?? ""
}

@Test func putKeepsBytesOnceAndHeadSaysWhetherTheyreThere() async throws {
    let store = makeStore()
    let api = makeAPI(store)
    let data = Data("an app's bytes".utf8)
    let firstAnswer = await put(api, data)
    #expect(firstAnswer.status == 201)
    let first = try decoded(StoragePut.self, firstAnswer)
    #expect(first.object == StorageObject(sha256: hex(data), size: Int64(data.count)))
    #expect(!first.existed)
    #expect(first.lease.holder == "alice")

    // Put again (by another holder): a lease of its own, the bytes kept once.
    let second = try decoded(StoragePut.self, await put(api, data, holder: "bob"))
    #expect(second.existed)
    #expect(second.lease.id != first.lease.id)
    let files = try FileManager.default.contentsOfDirectory(atPath: store.directory).filter(ServedFiles.isHash)
    #expect(files == [hex(data)])

    // HEAD says it's there, and its size; then a put by its hash alone needs no bytes.
    let head = await Server.route(request("HEAD", "/v1/storage/objects/\(hex(data))"), api: api)
    #expect(head.status == 200)
    #expect(head.length == Int64(data.count))
    let skipped = DataBody(data: Data())
    let byHash = await put(api, Data(), holder: "carol", headers: ["oss-sha256": hex(data)], body: skipped)
    #expect(byHash.status == 201)
    #expect(try decoded(StoragePut.self, byHash).existed)
    #expect(!skipped.wasRead.value)

    // An object it hasn't got: HEAD 404, and a put by its hash alone noObject.
    let missing = hex(Data("never put".utf8))
    #expect(await Server.route(request("HEAD", "/v1/storage/objects/\(missing)"), api: api).status == 404)
    let refused = await put(api, Data(), headers: ["oss-sha256": missing])
    #expect(refused.status == 404)
    #expect(try decoded(APIError.self, refused).code == "noObject")

    // Bytes that aren't the hash given: refused, nothing kept.
    let wrong = await put(api, Data("other bytes".utf8), headers: ["oss-sha256": hex(data)])
    #expect(wrong.status == 400)
    #expect(try FileManager.default.contentsOfDirectory(atPath: store.directory).filter(ServedFiles.isHash) == [hex(data)])
    #expect(try FileManager.default.contentsOfDirectory(atPath: store.incomingDirectory).isEmpty)
}

@Test func aNameMovesToTheNewObject() async throws {
    let store = makeStore()
    let api = makeAPI(store)
    let v1 = Data("build 1".utf8), v2 = Data("build 2".utf8)
    let first = try decoded(StoragePut.self, await put(api, v1, path: "/v1/storage/objects?name=app.ipa"))
    let second = try decoded(StoragePut.self, await put(api, v2, path: "/v1/storage/objects?name=app.ipa"))
    #expect(first.lease.name == "app.ipa")
    #expect(second.lease.name == "app.ipa")

    // The name is on the new object; the old lease is gone, and so (swept) are its bytes.
    let mine = await store.leases(of: "alice")
    #expect(mine.map(\.id) == [second.lease.id])
    #expect(try await store.resolve("app.ipa", holder: "alice") == hex(v2))
    await store.sweep()
    #expect(store.size(hex(v1)) == nil)
    #expect(store.size(hex(v2)) != nil)

    // Another holder's name is its own.
    _ = await put(api, v1, path: "/v1/storage/objects?name=app.ipa", holder: "bob")
    #expect(try await store.resolve("app.ipa", holder: "alice") == hex(v2))
    #expect(try await store.resolve("app.ipa", holder: "bob") == hex(v1))
}

@Test func leasesRenewReleaseAndExpire() async throws {
    let store = makeStore()
    let api = makeAPI(store)
    let a = Data("a".utf8), b = Data("b".utf8), c = Data("c".utf8)
    let leaseA = try decoded(StoragePut.self, await put(api, a, path: "/v1/storage/objects?ttl=1h")).lease
    let leaseB = try decoded(StoragePut.self, await put(api, b, path: "/v1/storage/objects?ttl=2h")).lease
    let leaseC = try decoded(StoragePut.self, await put(api, c)).lease
    #expect(abs(leaseA.expires.timeIntervalSinceNow - 3600) < 60)
    #expect(abs(leaseC.expires.timeIntervalSinceNow - 86400) < 60)

    // Renewed: its time set again, and held to seven days at most.
    let renewed = try decoded(StorageLease.self, await Server.route(request("POST", "/v1/storage/leases/\(leaseA.id)/renew?ttl=3d"), api: api))
    #expect(abs(renewed.expires.timeIntervalSinceNow - 3 * 86400) < 60)
    let held = try decoded(StorageLease.self, await Server.route(request("POST", "/v1/storage/leases/\(leaseA.id)/renew?ttl=30d"), api: api))
    #expect(held.expires.timeIntervalSinceNow <= 7 * 86400 + 1)

    // Released: gone from the holder's leases, and its object at the next sweep.
    #expect(await Server.route(request("DELETE", "/v1/storage/leases/\(leaseB.id)"), api: api).status == 200)
    let listed = try decoded([StorageLease].self, await Server.route(request("GET", "/v1/storage/leases"), api: api))
    #expect(Set(listed.map(\.id)) == [leaseA.id, leaseC.id])
    let swept = await store.sweep()
    #expect(swept.objects == 1)
    #expect(store.size(hex(b)) == nil)
    #expect(store.size(hex(a)) != nil && store.size(hex(c)) != nil)

    // An object being read is kept until it's done.
    #expect(await store.open(hex(c)) != nil)
    // Every lease out of time (eight days on): released, and the objects no lease holds deleted.
    let later = await store.sweep(now: Date().addingTimeInterval(8 * 86400))
    #expect(later.leases == 2)
    #expect(store.size(hex(a)) == nil)
    #expect(store.size(hex(c)) != nil)
    await store.close(hex(c))
    await store.sweep()
    #expect(store.size(hex(c)) == nil)
}

@Test func aServedFileIsNeverSwept() async throws {
    let store = makeStore()
    let api = makeAPI(store)
    let source = NSTemporaryDirectory() + "oss-served-\(UUID().uuidString).tar.gz"
    let bytes = Data("an SDK archive".utf8)
    try bytes.write(to: URL(fileURLWithPath: source))
    defer { try? FileManager.default.removeItem(atPath: source) }
    let entry = try ServedFiles.add(source, into: store.directory)
    #expect(entry.sha256 == hex(bytes))

    // Its lease is the server's: no holder's list has it, and no time ends it.
    #expect(await store.leases(of: "alice").isEmpty)
    await store.sweep(now: Date().addingTimeInterval(365 * 86400))
    #expect(store.size(entry.sha256) != nil)
    #expect(ServedFiles.list(in: store.directory).map(\.sha256) == [entry.sha256])

    // A holder's lease on the same bytes comes and goes: the file stays.
    let held = try decoded(StoragePut.self, await put(api, bytes))
    #expect(held.existed)
    #expect(await Server.route(request("DELETE", "/v1/storage/leases/\(held.lease.id)"), api: api).status == 200)
    await store.sweep()
    #expect(store.size(entry.sha256) != nil)
    // Served files aren't the store's objects in its use, nor does a holder's object show as served.
    let info = await store.info()
    #expect(info.objects == 0 && info.servedFiles == 1)

    // No longer served: the sweep takes it.
    try ServedFiles.remove(entry.sha256, in: store.directory)
    await store.sweep()
    #expect(store.size(entry.sha256) == nil)
}

@Test func filesServedBeforeStorageKeepTheirPlace() async throws {
    // A folder from before storage: a file with no entry (and no leases file) is a served one.
    let root = NSTemporaryDirectory() + "oss-storage-test-\(UUID().uuidString)"
    let bytes = Data("served before".utf8)
    Paths.ensure("\(root)/sha256")
    try bytes.write(to: URL(fileURLWithPath: "\(root)/sha256/\(hex(bytes))"))
    let store = StorageStore(directory: "\(root)/sha256", incoming: "\(root)/incoming", statePath: "\(root)/storage-leases.json")
    #expect(store.isServed(hex(bytes)))
    await store.sweep()
    #expect(store.size(hex(bytes)) != nil)
}

@Test func capsRefuseWhatWouldPassThem() async throws {
    // 20 bytes a holder, 30 in all.
    let store = makeStore(maxBytes: 30, perHolder: 20)
    let api = makeAPI(store)
    let fifteen = Data(repeating: 1, count: 15), ten = Data(repeating: 2, count: 10)
    #expect(await put(api, fifteen).status == 201)

    // Past the holder's cap: refused by its length, before its body is read.
    let unread = DataBody(data: ten)
    let refused = await put(api, ten, body: unread)
    #expect(refused.status == 413)
    #expect(try decoded(APIError.self, refused).code == "quota")
    #expect(!unread.wasRead.value)
    #expect(store.size(hex(ten)) == nil)

    // The same object again takes nothing more (said by its hash: without
    // one, a put's length counts as new bytes until they're read).
    #expect(await put(api, fifteen, path: "/v1/storage/objects?name=again", headers: ["oss-sha256": hex(fifteen)]).status == 201)
    #expect(await put(api, fifteen, path: "/v1/storage/objects?name=unsaid").status == 413)

    // Another holder within its own cap, until the store's is passed.
    #expect(await put(api, ten, holder: "bob").status == 201)
    let full = await put(api, Data(repeating: 3, count: 10), holder: "carol")
    #expect(full.status == 413)
    #expect(try decoded(APIError.self, full).error.contains("the store"))
}

@Test func anotherHoldersLeasesAreNotFound() async throws {
    let store = makeStore()
    let api = makeAPI(store)
    let data = Data("alice's".utf8)
    let lease = try decoded(StoragePut.self, await put(api, data)).lease
    #expect(await Server.route(request("POST", "/v1/storage/leases/\(lease.id)/renew", holder: "bob"), api: api).status == 404)
    #expect(await Server.route(request("DELETE", "/v1/storage/leases/\(lease.id)", holder: "bob"), api: api).status == 404)
    #expect(try decoded([StorageLease].self, await Server.route(request("GET", "/v1/storage/leases", holder: "bob"), api: api)).isEmpty)
    #expect(await get(api, "/v1/storage/objects/\(hex(data))", holder: "bob") == 404)
    // Alice's are still hers.
    #expect(await get(api, "/v1/storage/objects/\(hex(data))") == 200)
    #expect(await store.leases(of: "alice").map(\.id) == [lease.id])
    // A request names its holder.
    #expect(await Server.route(request("GET", "/v1/storage/leases", holder: nil), api: api).status == 400)
}

@Test func installTakesOnlyAnObjectTheLeasesHolderHolds() async throws {
    let store = makeStore()
    let api = makeAPI(store)
    // A zip's first bytes, as an .ipa's; put by bob, not by the lease's holder.
    let ipa = Data([0x50, 0x4B, 0x03, 0x04]) + Data("Payload/".utf8)
    _ = await put(api, ipa, path: "/v1/storage/objects?name=app.ipa", holder: "bob")
    var lease = Lease(id: "l1", platform: .ios, config: "iphone", name: "oss-lease-ios-l1", holder: "alice", state: .ready,
                      created: Date(), expires: Date().addingTimeInterval(3600))
    lease.udid = "00000000-0000-0000-0000-000000000000"
    for object in [hex(ipa), "app.ipa"] {
        await #expect(throws: APIError.self) { try await Installs.install(on: lease, object: object, holder: nil, storage: store) }
    }
    // Nor with a grant's holder that isn't the lease's.
    _ = await put(api, ipa, holder: "alice")
    await #expect(throws: APIError.self) { try await Installs.install(on: lease, object: hex(ipa), holder: "bob", storage: store) }
    // An Android lease takes adb.
    lease.platform = .android
    await #expect(throws: APIError.self) { try await Installs.install(on: lease, object: hex(ipa), holder: nil, storage: store) }
}

@Test func aPutGrantWorksWithoutTheToken() async throws {
    let store = makeStore()
    let api = makeAPI(store)
    let grant = try await api.grants.issue(GrantRequest(verb: "storage.put", name: "build.ipa", objectTTL: "2h"), holder: "visor:s1",
                                           lease: nil, storage: store, readsServedFiles: false, base: "http://127.0.0.1:7480")
    #expect(grant.path.hasPrefix("/v1/storage/objects?grant="))
    #expect(grant.url.absoluteString == "http://127.0.0.1:7480" + grant.path)
    #expect(abs(grant.expires.timeIntervalSinceNow - 300) < 60)

    let data = Data("from an agent's container".utf8)
    let answer = await put(api, data, path: grant.path, holder: nil, token: nil)
    #expect(answer.status == 201)
    let stored = try decoded(StoragePut.self, answer)
    #expect(stored.lease.holder == "visor:s1")
    #expect(stored.lease.name == "build.ipa")
    #expect(abs(stored.lease.expires.timeIntervalSinceNow - 7200) < 60)

    // Used again, until it expires; the URL's own query changes nothing the grant gives.
    let again = try decoded(StoragePut.self, await put(api, Data("another".utf8), path: grant.path + "&name=other&ttl=7d", holder: "mallory", token: nil))
    #expect(again.lease.holder == "visor:s1")
    #expect(again.lease.name == "build.ipa")
    #expect(await store.leases(of: "visor:s1").map(\.id) == [again.lease.id])
}

@Test func aGrantIsGoodForItsOneUseAndNoOther() async throws {
    let store = makeStore()
    let api = makeAPI(store)
    let a = Data("object a".utf8), b = Data("object b".utf8)
    _ = await put(api, a)
    _ = await put(api, b)
    let grant = try await api.grants.issue(GrantRequest(verb: "storage.get", object: hex(a)), holder: "alice", lease: nil, storage: store,
                                           readsServedFiles: false, base: "http://127.0.0.1:7480")
    let token = grantToken(grant)
    #expect(grant.path == "/v1/storage/objects/\(hex(a))?grant=\(token)")
    // Its own use: no token needed.
    #expect(await get(api, grant.path, holder: nil, token: nil) == 200)
    #expect(await Server.route(request("HEAD", grant.path, holder: nil, token: nil), api: api).status == 200)

    // Another verb, another resource, another route: 403, the same answer every time.
    let wrongVerb = await put(api, Data("x".utf8), path: "/v1/storage/objects?grant=\(token)", holder: nil, token: nil)
    #expect(wrongVerb.status == 403)
    #expect(await get(api, "/v1/storage/objects/\(hex(b))?grant=\(token)", holder: nil, token: nil) == 403)
    let otherRoute = await Server.route(request("GET", "/v1/storage/leases?grant=\(token)", holder: nil, token: nil), api: api)
    #expect(otherRoute.status == 403)
    #expect(otherRoute.body == wrongVerb.body)

    // Expired.
    let expired = api.grants.token(GrantClaims(verb: "storage.get", resource: "storage/objects/\(hex(a))", holder: "alice",
                                               expires: Int(Date().timeIntervalSince1970) - 1))
    #expect(await get(api, "/v1/storage/objects/\(hex(a))?grant=\(expired)", holder: nil, token: nil) == 403)
    #expect(api.grants.verify(expired, verb: "storage.get", resource: "storage/objects/\(hex(a))") == nil)
    // Unexpired by its own clock, it was good.
    #expect(api.grants.verify(expired, verb: "storage.get", resource: "storage/objects/\(hex(a))",
                              now: Date().addingTimeInterval(-60)) != nil)
}

@Test func aTamperedGrantIsRefused() async throws {
    let store = makeStore()
    let api = makeAPI(store)
    let a = Data("object a".utf8), b = Data("object b".utf8)
    _ = await put(api, a)
    _ = await put(api, b)
    let grant = try await api.grants.issue(GrantRequest(verb: "storage.get", object: hex(a)), holder: "alice", lease: nil, storage: store,
                                           readsServedFiles: false, base: "http://127.0.0.1:7480")
    let token = grantToken(grant)
    let parts = token.split(separator: ".").map(String.init)

    // Its signature changed.
    // Its first character: the last one's low bits are padding.
    let flipped = parts[1].first == "A" ? "B" : "A"
    let badSignature = parts[0] + "." + flipped + parts[1].dropFirst()
    #expect(await get(api, "/v1/storage/objects/\(hex(a))?grant=\(badSignature)", holder: nil, token: nil) == 403)
    // Its claims changed (another object), the signature kept.
    var claims = try JSONDecoder().decode(GrantClaims.self, from: Data(base64URL: parts[0])!)
    claims.resource = "storage/objects/\(hex(b))"
    let rewritten = try JSONEncoder().encode(claims).base64URL + "." + parts[1]
    #expect(await get(api, "/v1/storage/objects/\(hex(b))?grant=\(rewritten)", holder: nil, token: nil) == 403)
    // Signed by another server's key.
    let other = GrantKey(key: Data(repeating: 9, count: 32)).token(claims)
    #expect(await get(api, "/v1/storage/objects/\(hex(b))?grant=\(other)", holder: nil, token: nil) == 403)
    // Not a grant at all.
    #expect(await get(api, "/v1/storage/objects/\(hex(a))?grant=nonsense", holder: nil, token: nil) == 403)
}

@Test func aGrantIsIssuedOnlyForTheHoldersOwn() async throws {
    let store = makeStore()
    let api = makeAPI(store)
    var lease = Lease(id: "l1", platform: .ios, config: "iphone", name: "oss-lease-ios-l1", holder: "visor:other", state: .ready,
                      created: Date(), expires: Date().addingTimeInterval(3600))
    func issue(_ request: GrantRequest, as holder: String) async throws -> Grant {
        try await api.grants.issue(request, holder: holder, lease: lease, storage: store, readsServedFiles: false, base: "http://127.0.0.1:7480")
    }
    // Another holder's machine lease.
    await #expect(throws: APIError.self) { try await issue(GrantRequest(verb: "machine.install", lease: "l1"), as: "visor:mine") }
    // Another holder's object.
    let theirs = Data("visor:other's".utf8)
    _ = await put(api, theirs, holder: "visor:other")
    await #expect(throws: APIError.self) { try await issue(GrantRequest(verb: "storage.get", object: hex(theirs)), as: "visor:mine") }
    // Verbs that aren't yet, and none.
    await #expect(throws: APIError.self) { try await issue(GrantRequest(verb: "machine.exec", lease: "l1"), as: "visor:other") }
    await #expect(throws: APIError.self) { try await issue(GrantRequest(verb: "storage.delete"), as: "visor:other") }

    // Its own lease: a grant for that lease's install route.
    let own = try await issue(GrantRequest(verb: "machine.install", lease: "l1"), as: "visor:other")
    #expect(own.path.hasPrefix("/v1/machines/l1/install?grant="))
    #expect(api.grants.verify(grantToken(own), verb: "machine.install", resource: "machines/l1")?.holder == "visor:other")
    // A grant asks for no grant: that takes the API's token.
    let body = try JSONEncoder.oss.encode(GrantRequest(verb: "storage.put"))
    var asked = request("POST", "/v1/grants?grant=\(grantToken(own))", holder: nil, token: nil)
    asked.body = body
    #expect(await Server.route(asked, api: api).status == 403)
    lease.holder = "visor:mine"
    #expect(try await issue(GrantRequest(verb: "machine.install", lease: "l1"), as: "visor:mine").verb == "machine.install")
}
#endif
