import Foundation
import Testing
@testable import OSSServer

// The containers' network (0.14): one vmnet network, kept by its owner
// (`oss-machine network`), every container's helper attached to it. What
// needs no vmnet is tested here: the subnet, the addresses (kept on disk,
// taken in turn, given back), and the owner's socket, against a network
// that is only its serialization's bytes. The vmnet calls themselves are
// `oss-machine network-check`'s, in CI's macOS VM.

/// A folder of the test's own, short enough for a socket's path.
private func scratch() -> String {
    let folder = "/tmp/oss-net-\(UUID().uuidString.prefix(8).lowercased())"
    try? FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
    return folder
}

private func book(_ folder: String, _ subnet: String = "192.168.127.0/24") throws -> AddressBook {
    try AddressBook(path: "\(folder)/addresses.json", subnet: ContainerSubnet(subnet))
}

// MARK: The subnet

@Test func theDefaultSubnetIsAPrivateSlash24AwayFromVmnetsOwnPicks() throws {
    let subnet = try ContainerSubnet(ContainerNetwork.defaultSubnet)
    #expect(subnet.description == "192.168.127.0/24")
    #expect(subnet.gateway == "192.168.127.1")
    #expect(subnet.hosts == ContainerSubnet.parse("192.168.127.2")!...ContainerSubnet.parse("192.168.127.254")!)
    // Apple's container's default, and vmnet's next picks after it.
    for taken in ["192.168.64.1", "192.168.65.1", "192.168.66.1"] {
        #expect(!subnet.contains(ContainerSubnet.parse(taken)!))
    }
    #expect(ServerConfig().containerSubnet == ContainerNetwork.defaultSubnet)
}

@Test func aSubnetMustBePrivateAndItsNetworksOwnAddress() throws {
    #expect(try ContainerSubnet("10.20.0.0/16").gateway == "10.20.0.1")
    #expect(try ContainerSubnet("172.31.5.0/24").hosts.count == 253)
    for bad in ["192.168.127.5/24", "8.8.8.0/24", "172.32.0.0/24", "192.168.127.0/30", "192.168.0.0/8", "192.168.127/24",
                "192.168.127.0", "192.168.300.0/24", ""] {
        #expect(throws: ContainerNetworkError.self, "\(bad)") { try ContainerSubnet(bad) }
    }
}

@Test func serverJSONNamesTheSubnet() throws {
    let config = try JSONDecoder().decode(ServerConfig.self, from: Data(#"{"containerSubnet": "10.77.0.0/24"}"#.utf8))
    #expect(config.containerSubnet == "10.77.0.0/24")
    #expect(try JSONDecoder().decode(ServerConfig.self, from: Data("{}".utf8)).containerSubnet == "192.168.127.0/24")
}

// MARK: The addresses

@Test func eachContainerKeepsItsAddressAndMACAcrossTheOwnersRestart() throws {
    let folder = scratch()
    defer { try? FileManager.default.removeItem(atPath: folder) }
    let first = try book(folder)
    let a = try first.allocate("oss-lease-container-a")
    let b = try first.allocate("oss-lease-container-b")
    #expect(a.address == "192.168.127.2" && b.address == "192.168.127.3")
    #expect(try first.allocate("oss-lease-container-a") == a, "asked again, the same")
    // Locally administered, unicast, and each its own.
    for mac in [a.mac, b.mac] {
        let octet = UInt8(mac.prefix(2), radix: 16)!
        #expect(octet & 0x03 == 0x02 && mac.split(separator: ":").count == 6)
    }
    #expect(a.mac != b.mac)
    // The owner started again (launchd, the Mac's restart): the same, from its file.
    let again = try book(folder)
    #expect(again.all == ["oss-lease-container-a": a, "oss-lease-container-b": b])
    #expect(try again.allocate("oss-lease-container-b") == b)
    #expect(try again.allocate("oss-lease-container-c").address == "192.168.127.4", "and the turn goes on where it was")
    let mode = try FileManager.default.attributesOfItem(atPath: "\(folder)/addresses.json")[.posixPermissions] as? Int
    #expect(mode == 0o600)
}

@Test func anAddressGivenBackGoesToAnotherOnlyOnceTheRestHaveBeenUsed() throws {
    let folder = scratch()
    defer { try? FileManager.default.removeItem(atPath: folder) }
    // A /28: .2 to .14, 13 containers.
    let addresses = try book(folder, "10.9.8.0/28")
    #expect(try addresses.allocate("a").address == "10.9.8.2")
    #expect(try addresses.release("a"))
    #expect(try !addresses.release("a"), "given back once")
    #expect(try addresses.allocate("b").address == "10.9.8.3", "not .2 again at once")
    for index in 0..<11 { _ = try addresses.allocate("filler-\(index)") }
    #expect(addresses.all.values.map(\.address).contains("10.9.8.14"))
    // Around the subnet: .2 is the one free.
    #expect(try addresses.allocate("c").address == "10.9.8.2")
}

@Test func aFullSubnetRefusesTheNextContainer() throws {
    let folder = scratch()
    defer { try? FileManager.default.removeItem(atPath: folder) }
    let addresses = try book(folder, "10.9.8.0/28")
    for index in 0..<13 { _ = try addresses.allocate("c\(index)") }
    #expect(throws: ContainerNetworkError.self) { try addresses.allocate("one-too-many") }
    #expect(try addresses.allocate("c4").address == "10.9.8.6", "those holding one still get theirs")
    try addresses.release("c7")
    #expect(try addresses.allocate("one-too-many").address == "10.9.8.9")
}

@Test func keepGivesBackEveryAddressButThoseOfTheContainersNamed() throws {
    let folder = scratch()
    defer { try? FileManager.default.removeItem(atPath: folder) }
    let addresses = try book(folder)
    for name in ["a", "b", "c"] { _ = try addresses.allocate(name) }
    #expect(try addresses.keep(["b", "z"]) == ["a", "c"])
    #expect(Set(addresses.all.keys) == ["b"])
    #expect(try addresses.keep(["b"]).isEmpty)
    #expect(Set(try book(folder).all.keys) == ["b"], "kept on disk")
}

@Test func anotherSubnetsAddressesAreDropped() throws {
    let folder = scratch()
    defer { try? FileManager.default.removeItem(atPath: folder) }
    _ = try book(folder).allocate("a")
    let moved = try book(folder, "10.1.2.0/24")
    #expect(moved.all.isEmpty)
    #expect(try moved.allocate("a").address == "10.1.2.2")
}

@Test func anUnreadableAddressFileSaysSoRatherThanStartingAgain() throws {
    let folder = scratch()
    defer { try? FileManager.default.removeItem(atPath: folder) }
    try Data("not json".utf8).write(to: URL(fileURLWithPath: "\(folder)/addresses.json"))
    #expect(throws: ContainerNetworkError.self) { try book(folder) }
}

// MARK: The owner's socket

/// An owner of a network that is only its serialization's bytes, on a socket of the test's own.
private func owner(_ folder: String, serialization: Data = Data("a vmnet network".utf8)) throws -> (NetworkOwnerService, LineSocket.Listener) {
    let service = NetworkOwnerService(subnet: try ContainerSubnet("192.168.127.0/24"), serialization: serialization, book: try book(folder))
    let listener = try LineSocket.listen(at: "\(folder)/network.sock", handle: service.handle)
    return (service, listener)
}

@Test func aHelperGetsItsAddressAndTheNetworksSerializationFromTheOwner() async throws {
    let folder = scratch()
    defer { try? FileManager.default.removeItem(atPath: folder) }
    // Bigger than a read: the real serialization's size isn't known ahead.
    let serialization = Data((0..<200_000).map { UInt8($0 % 251) })
    let (_, listener) = try owner(folder, serialization: serialization)
    defer { listener.stop() }
    let socket = "\(folder)/network.sock"
    let a = try await NetworkOwnerClient.attach(name: "oss-lease-container-a", socket: socket, wait: 2)
    #expect(a.cidr == "192.168.127.2/24" && a.gateway == "192.168.127.1" && a.subnet == "192.168.127.0/24")
    #expect(a.serialization == serialization)
    // Helpers starting at once each get their own.
    let others = try await withThrowingTaskGroup(of: NetworkAttachment.self) { group in
        for index in 0..<8 { group.addTask { try await NetworkOwnerClient.attach(name: "c\(index)", socket: socket, wait: 2) } }
        return try await group.reduce(into: []) { $0.append($1) }
    }
    #expect(Set(others.map(\.address)).count == 8 && !others.map(\.address).contains(a.address))
    // Its helper started again: the same address and card.
    let again = try await NetworkOwnerClient.attach(name: "oss-lease-container-a", socket: socket, wait: 2)
    #expect(again == a)
    let status = try #require(await NetworkOwnerClient.status(socket: socket))
    #expect(status["containers"] == "9" && status["subnet"] == "192.168.127.0/24" && status["pid"] == String(getpid()))
}

@Test func releaseAndKeepGoThroughTheSocket() async throws {
    let folder = scratch()
    defer { try? FileManager.default.removeItem(atPath: folder) }
    let (service, listener) = try owner(folder)
    defer { listener.stop() }
    let socket = "\(folder)/network.sock"
    for name in ["a", "b", "c"] { _ = try await NetworkOwnerClient.attach(name: name, socket: socket, wait: 2) }
    #expect(await NetworkOwnerClient.release(name: "a", socket: socket))
    #expect(await !NetworkOwnerClient.release(name: "a", socket: socket), "a lease from before 0.14 had none")
    #expect(await NetworkOwnerClient.keep(["b"], socket: socket) == ["c"])
    #expect(Set(service.book.all.keys) == ["b"])
}

@Test func theOwnerAnswersWhatItCantDoWithAnError() async throws {
    let folder = scratch()
    defer { try? FileManager.default.removeItem(atPath: folder) }
    let (_, listener) = try owner(folder)
    defer { listener.stop() }
    let socket = "\(folder)/network.sock"
    #expect(await LineSocket.request(socket, ["op": "allocate"])?["error"] != nil)
    #expect(await LineSocket.request(socket, ["op": "allocate", "name": "a\nb"])?["error"] != nil)
    #expect(await LineSocket.request(socket, ["op": "reboot"])?["error"] == "no such op reboot")
    let network = try #require(await LineSocket.request(socket, ["op": "network"]))
    #expect(network["serialization"].flatMap { Data(base64Encoded: $0) } == Data("a vmnet network".utf8))
    // A connection that says nothing holds no one else up.
    let idle = try #require(rawConnect(socket))
    defer { close(idle) }
    #expect(await NetworkOwnerClient.status(socket: socket) != nil)
    // Nor does one that sends what isn't JSON.
    let junk = try #require(rawConnect(socket))
    _ = "{nope\n".withCString { write(junk, $0, 6) }
    close(junk)
    #expect(await NetworkOwnerClient.status(socket: socket) != nil)
}

@Test func withNoOwnerAHelperWaitsBrieflyThenFailsAndMakesNoNetworkOfItsOwn() async throws {
    let folder = scratch()
    defer { try? FileManager.default.removeItem(atPath: folder) }
    let started = Date()
    await #expect {
        _ = try await NetworkOwnerClient.attach(name: "a", socket: "\(folder)/network.sock", wait: 1)
    } throws: { error in
        "\(error)".contains(ContainerNetwork.label) && "\(error)".contains("didn't answer")
    }
    #expect(Date().timeIntervalSince(started) >= 1)
}

@Test func aHelperWaitsForAnOwnerThatIsStarting() async throws {
    let folder = scratch()
    defer { try? FileManager.default.removeItem(atPath: folder) }
    let attaching = Task { try await NetworkOwnerClient.attach(name: "a", socket: "\(folder)/network.sock", wait: 10) }
    try await Task.sleep(for: .milliseconds(700))
    let (_, listener) = try owner(folder)
    defer { listener.stop() }
    #expect(try await attaching.value.address == "192.168.127.2")
}

@Test func aStoppedOwnersSocketIsGone() async throws {
    let folder = scratch()
    defer { try? FileManager.default.removeItem(atPath: folder) }
    let (_, listener) = try owner(folder)
    #expect(LineSocket.isAnswering(listener.path))
    listener.stop()
    #expect(!FileManager.default.fileExists(atPath: listener.path))
    #expect(await NetworkOwnerClient.status(socket: listener.path) == nil)
}

@Test func theSocketIsInOSServersFolderUnlessThatPathIsTooLong() {
    #expect(ContainerNetwork.socket.utf8.count < 104)
    #expect(ContainerNetwork.socket.hasPrefix(ContainerNetwork.folder) || ContainerNetwork.folder.utf8.count >= 87)
}

/// A connection of the test's own, which says what the test makes it say.
private func rawConnect(_ path: String) -> Int32? {
    #if canImport(Glibc)
    let descriptor = socket(AF_UNIX, Int32(SOCK_STREAM.rawValue), 0)
    #else
    let descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
    #endif
    var address = sockaddr_un()
    address.sun_family = sa_family_t(AF_UNIX)
    let bytes = Array(path.utf8)
    withUnsafeMutableBytes(of: &address.sun_path) { buffer in
        buffer.copyBytes(from: bytes)
        buffer[bytes.count] = 0
    }
    let connected = withUnsafePointer(to: &address) { pointer in
        pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) == 0 }
    }
    guard connected else { close(descriptor); return nil }
    return descriptor
}
