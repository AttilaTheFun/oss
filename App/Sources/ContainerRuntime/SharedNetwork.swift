import Containerization
import ContainerizationExtras
import Foundation
import OSSServer
import Virtualization
import XPC
import vmnet

/// The containers' network (0.14): one shared-mode (NAT) vmnet network,
/// which `oss-machine network <network.json>` (the launchd job
/// `oss.network`, KeepAlive) makes and keeps for its life, and which every
/// container's helper attaches to from its serialization. A container's
/// lease ending then takes down nothing but its own card: until 0.14 each
/// helper made a network of its own and took it down with it, and macOS,
/// taking one network's bridge down, could take another live network's
/// bridge address and route with it.
///
/// What needs no vmnet (the subnet, the addresses, the socket and what it
/// answers) is OSSServer's ContainerNetwork.swift, tested there against a
/// fake network; this is the vmnet side, which `oss-machine network-check`
/// runs for real (CI's macOS VM: vmnet runs there, a container's VM
/// wouldn't).
@available(macOS 26, *)
public enum SharedVmnet {
    /// A shared-mode network on `subnet`, with no DHCP (each container's
    /// address is set by Containerization, as the owner gave it), and its
    /// serialization.
    static func make(_ subnet: ContainerSubnet) throws -> (network: vmnet_network_ref, serialization: xpc_object_t) {
        var status: vmnet_return_t = .VMNET_FAILURE
        guard let configuration = vmnet_network_configuration_create(.VMNET_SHARED_MODE, &status) else {
            throw ContainerNetworkError("vmnet can't make a network configuration (status \(status.rawValue))")
        }
        vmnet_network_configuration_disable_dhcp(configuration)
        // As Containerization and Apple's container give it: the Mac's
        // address on it (the gateway), and the mask.
        var gateway = in_addr()
        var mask = in_addr()
        inet_pton(AF_INET, subnet.gateway, &gateway)
        inet_pton(AF_INET, ContainerSubnet.dotted(subnet.mask), &mask)
        status = vmnet_network_configuration_set_ipv4_subnet(configuration, &gateway, &mask)
        guard status == .VMNET_SUCCESS else {
            throw ContainerNetworkError("vmnet won't take the subnet \(subnet) (status \(status.rawValue))")
        }
        guard let network = vmnet_network_create(configuration, &status), status == .VMNET_SUCCESS else {
            throw ContainerNetworkError("vmnet can't make a network on \(subnet) (status \(status.rawValue))")
        }
        let made = Self.subnet(of: network)
        guard made == subnet.description else {
            throw ContainerNetworkError("vmnet made the network on \(made), not \(subnet)")
        }
        guard let serialization = vmnet_network_copy_serialization(network, &status), status == .VMNET_SUCCESS else {
            throw ContainerNetworkError("vmnet can't serialize the network (status \(status.rawValue))")
        }
        return (network, serialization)
    }

    /// The network as vmnet says it is, `192.168.127.0/24`.
    static func subnet(of network: vmnet_network_ref) -> String {
        var address = in_addr()
        var mask = in_addr()
        vmnet_network_get_ipv4_subnet(network, &address, &mask)
        let maskValue = UInt32(bigEndian: mask.s_addr)
        let base = UInt32(bigEndian: address.s_addr) & maskValue
        return "\(ContainerSubnet.dotted(base))/\(maskValue.nonzeroBitCount)"
    }

    /// The owner's network, in a helper: a reference of the helper's own,
    /// from the serialization the owner gave. The network is the owner's:
    /// this reference going (the helper ending) doesn't take it down.
    public static func attach(_ serialization: Data) throws -> vmnet_network_ref {
        let object = try XPCValue.decode(serialization).object
        var status: vmnet_return_t = .VMNET_SUCCESS
        guard let network = vmnet_network_create_with_serialization(object, &status), status == .VMNET_SUCCESS else {
            throw ContainerNetworkError("vmnet can't attach to the containers' network from its serialization (status \(status.rawValue))")
        }
        return network
    }

    /// A container's card on the network: its address and MAC address as
    /// the owner gave them, the Mac's address as its gateway.
    public static func interface(_ attachment: NetworkAttachment, network: vmnet_network_ref) throws -> VmnetNetwork.Interface {
        VmnetNetwork.Interface(reference: network, ipv4Address: try CIDRv4(attachment.cidr), ipv4Gateway: try IPv4Address(attachment.gateway),
                               macAddress: try MACAddress(attachment.mac))
    }
}

/// An XPC object as bytes, and back: the network's serialization crosses
/// the owner's socket so (a JSON line), not an XPC connection. Only what
/// XPC can say in plain values goes; one that holds anything else (a port,
/// a file descriptor, an endpoint) can't, and making the network says so
/// rather than handing helpers half of it.
indirect enum XPCValue: Codable, Equatable {
    case dictionary([String: XPCValue])
    case array([XPCValue])
    case string(String)
    case data(Data)
    case uuid(Data)
    case int64(Int64)
    case uint64(UInt64)
    case bool(Bool)
    case double(Double)
    case date(Int64)
    case null

    init(_ object: xpc_object_t) throws {
        let type = xpc_get_type(object)
        switch type {
        case XPC_TYPE_DICTIONARY:
            var entries: [String: XPCValue] = [:]
            var failure: Error?
            xpc_dictionary_apply(object) { key, value in
                do { entries[String(cString: key)] = try XPCValue(value) } catch { failure = error; return false }
                return true
            }
            if let failure { throw failure }
            self = .dictionary(entries)
        case XPC_TYPE_ARRAY:
            var items: [XPCValue] = []
            var failure: Error?
            xpc_array_apply(object) { _, value in
                do { items.append(try XPCValue(value)) } catch { failure = error; return false }
                return true
            }
            if let failure { throw failure }
            self = .array(items)
        case XPC_TYPE_STRING:
            self = .string(xpc_string_get_string_ptr(object).map { String(cString: $0) } ?? "")
        case XPC_TYPE_DATA:
            let length = xpc_data_get_length(object)
            self = .data(xpc_data_get_bytes_ptr(object).map { Data(bytes: $0, count: length) } ?? Data())
        case XPC_TYPE_UUID:
            self = .uuid(xpc_uuid_get_bytes(object).map { Data(bytes: $0, count: 16) } ?? Data(count: 16))
        case XPC_TYPE_INT64: self = .int64(xpc_int64_get_value(object))
        case XPC_TYPE_UINT64: self = .uint64(xpc_uint64_get_value(object))
        case XPC_TYPE_BOOL: self = .bool(xpc_bool_get_value(object))
        case XPC_TYPE_DOUBLE: self = .double(xpc_double_get_value(object))
        case XPC_TYPE_DATE: self = .date(xpc_date_get_value(object))
        case XPC_TYPE_NULL: self = .null
        default:
            throw ContainerNetworkError("the network's serialization holds an XPC \(String(cString: xpc_type_get_name(type))), "
                                        + "which can't cross a socket")
        }
    }

    var object: xpc_object_t {
        switch self {
        case .dictionary(let entries):
            let dictionary = xpc_dictionary_create_empty()
            for (key, value) in entries { xpc_dictionary_set_value(dictionary, key, value.object) }
            return dictionary
        case .array(let items):
            let array = xpc_array_create_empty()
            for item in items { xpc_array_append_value(array, item.object) }
            return array
        case .string(let string): return xpc_string_create(string)
        case .data(let data): return data.withUnsafeBytes { xpc_data_create($0.baseAddress, $0.count) }
        case .uuid(let bytes):
            let padded = Array(bytes.prefix(16)) + Array(repeating: 0, count: max(0, 16 - bytes.count))
            return padded.withUnsafeBufferPointer { xpc_uuid_create($0.baseAddress!) }
        case .int64(let value): return xpc_int64_create(value)
        case .uint64(let value): return xpc_uint64_create(value)
        case .bool(let value): return xpc_bool_create(value)
        case .double(let value): return xpc_double_create(value)
        case .date(let value): return xpc_date_create(value)
        case .null: return xpc_null_create()
        }
    }

    static func encode(_ object: xpc_object_t) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        return try encoder.encode(XPCValue(object))
    }

    static func decode(_ data: Data) throws -> XPCValue {
        do { return try JSONDecoder().decode(XPCValue.self, from: data) } catch {
            throw ContainerNetworkError("the network's serialization can't be read (\(error))")
        }
    }

    /// Its shape without its values (`dictionary{mode: uint64, uuid: uuid}`),
    /// for a log: what kinds vmnet put in it.
    var shape: String {
        switch self {
        case .dictionary(let entries):
            "dictionary{" + entries.keys.sorted().map { "\($0): \(entries[$0]!.shape)" }.joined(separator: ", ") + "}"
        case .array(let items): "array[" + items.map(\.shape).joined(separator: ", ") + "]"
        case .string: "string"
        case .data(let data): "data(\(data.count))"
        case .uuid: "uuid"
        case .int64: "int64"
        case .uint64: "uint64"
        case .bool: "bool"
        case .double: "double"
        case .date: "date"
        case .null: "null"
        }
    }
}

/// `oss-machine network <network.json>`: the containers' network's owner.
/// It makes the network, keeps it for its life, and answers helpers on its
/// socket (NetworkOwnerService: the serialization, each container's
/// address, kept in `addresses.json`, and their release). TERM (launchd's
/// bootout, the Mac shutting down) ends it, and the network with it: OS
/// Server never stops it while it lends containers.
@available(macOS 26, *)
public enum NetworkOwnerProcess {
    private enum Kept {
        nonisolated(unsafe) static var network: vmnet_network_ref?
        nonisolated(unsafe) static var sources: [DispatchSourceSignal] = []
        /// Its socket, once it listens: set by the start, read by TERM's handler.
        static let lock = NSLock()
        nonisolated(unsafe) static var listener: LineSocket.Listener?
    }

    public static func main(_ specPath: String) async -> Never {
        guard let data = FileManager.default.contents(atPath: specPath),
              let spec = try? JSONDecoder().decode(ContainerNetworkSpec.self, from: data) else {
            ContainerHelper.say("oss-machine network <network.json>: no spec to run")
            exit(2)
        }
        // TERM handled from the first: one that comes while the network is
        // still being made takes its socket away too.
        for signal in [SIGTERM, SIGINT] {
            Foundation.signal(signal, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: signal, queue: .main)
            source.setEventHandler {
                ContainerHelper.say("containers' network: stopping (its containers lose it)")
                Kept.lock.withLock { Kept.listener?.stop() }
                exit(0)
            }
            source.resume()
            Kept.sources.append(source)
        }
        do {
            try await start(spec)
            while true { try? await Task.sleep(for: .seconds(86400)) }
        } catch {
            ContainerHelper.say("containers' network: \(error)")
            exit(1)
        }
    }

    /// The network made, and its socket answering.
    static func start(_ spec: ContainerNetworkSpec) async throws {
        let subnet = try ContainerSubnet(spec.subnet)
        // One owner a Mac: a second would take the first's socket.
        if LineSocket.isAnswering(spec.socket) {
            throw ContainerNetworkError("another owner answers at \(spec.socket)")
        }
        // A network of this subnet already up (one this job made before
        // launchd started it again, on its way down) collides with a new
        // one: waited for a little, then refused, saying whose it is.
        var deadline = Date().addingTimeInterval(15)
        while let interface = subnet.interfaceOnIt() {
            guard Date() < deadline else {
                throw ContainerNetworkError("this Mac already has \(interface) on \(subnet): give server.json's containerSubnet another")
            }
            try await Task.sleep(for: .milliseconds(500))
        }
        let (network, serialization) = try SharedVmnet.make(subnet)
        let value = try XPCValue(serialization)
        let encoded = try XPCValue.encode(serialization)
        Kept.network = network
        let book = try AddressBook(path: spec.addresses, subnet: subnet)
        let service = NetworkOwnerService(subnet: subnet, serialization: encoded, book: book)
        let listener = try LineSocket.listen(at: spec.socket, handle: service.handle)
        Kept.lock.withLock { Kept.listener = listener }
        // Its bridge, for the log: the interface with the Mac's address on it.
        deadline = Date().addingTimeInterval(5)
        var bridge = subnet.interfaceOnIt()
        while bridge == nil, Date() < deadline {
            try? await Task.sleep(for: .milliseconds(250))
            bridge = subnet.interfaceOnIt()
        }
        ContainerHelper.say("containers' network: \(subnet) (\(bridge ?? "its bridge not up yet")), \(book.all.count) containers' addresses kept, "
                            + "serialization \(value.shape), at \(spec.socket)")
    }
}

/// `oss-machine network-check`: the containers' network for real, in a
/// Mac with no container to run (CI's macOS VM, which has no nested
/// virtualization for a container's VM but runs vmnet): an owner started
/// as a process of its own on a folder of the check's, two containers'
/// addresses asked of it, the network attached to from its serialization
/// in this other process as a helper does, and each container's network
/// card made. Exits 0 when all of it worked.
@available(macOS 26, *)
public enum NetworkCheck {
    public static func main(subnet: String = ContainerNetwork.defaultSubnet) async -> Never {
        let folder = "/tmp/oss-network-check-\(getpid())"
        try? FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
        let spec = ContainerNetworkSpec(subnet: subnet, socket: "\(folder)/network.sock", addresses: "\(folder)/addresses.json")
        let owner = Process()
        do {
            let encoder = JSONEncoder()
            try encoder.encode(spec).write(to: URL(fileURLWithPath: "\(folder)/network.json"))
            owner.executableURL = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath()
            owner.arguments = ["network", "\(folder)/network.json"]
            try owner.run()
            print("network-check: owner pid \(owner.processIdentifier), \(subnet)")
            let a = try await NetworkOwnerClient.attach(name: "check-a", socket: spec.socket, wait: 30)
            let b = try await NetworkOwnerClient.attach(name: "check-b", socket: spec.socket, wait: 5)
            guard a.address != b.address, a.subnet == subnet, b.subnet == subnet else {
                throw ContainerNetworkError("two containers were given \(a.cidr) and \(b.cidr) on \(a.subnet)")
            }
            let again = try await NetworkOwnerClient.attach(name: "check-a", socket: spec.socket, wait: 5)
            guard again == a else { throw ContainerNetworkError("check-a asked again was given \(again.cidr), not \(a.cidr)") }
            print("network-check: check-a \(a.cidr) \(a.mac), check-b \(b.cidr) \(b.mac), gateway \(a.gateway)")
            print("network-check: serialization \(try XPCValue.decode(a.serialization).shape) (\(a.serialization.count) bytes)")
            // As a helper does: its own reference from the serialization, and the container's card.
            for attachment in [a, b] {
                let network = try SharedVmnet.attach(attachment.serialization)
                let seen = SharedVmnet.subnet(of: network)
                guard seen == subnet else { throw ContainerNetworkError("attached, vmnet says the network is \(seen), not \(subnet)") }
                let device = try SharedVmnet.interface(attachment, network: network).device()
                guard device.attachment is VZVmnetNetworkDeviceAttachment,
                      device.macAddress.string.lowercased() == attachment.mac else {
                    throw ContainerNetworkError("\(attachment.cidr)'s card isn't on the network as given (\(device.macAddress.string))")
                }
            }
            print("network-check: attached from the serialization in another process, \(subnet), cards made")
            guard await NetworkOwnerClient.release(name: "check-a", socket: spec.socket),
                  await NetworkOwnerClient.status(socket: spec.socket)?["containers"] == "1" else {
                throw ContainerNetworkError("check-a's address wasn't given back")
            }
            owner.terminate()
            owner.waitUntilExit()
            guard owner.terminationReason == .exit, owner.terminationStatus == 0 else {
                throw ContainerNetworkError("the owner didn't stop on TERM as asked (\(owner.terminationReason == .exit ? "exit" : "signal") "
                                            + "\(owner.terminationStatus))")
            }
            guard !FileManager.default.fileExists(atPath: spec.socket) else { throw ContainerNetworkError("the owner left its socket behind") }
            print("network-check: passed")
            try? FileManager.default.removeItem(atPath: folder)
            exit(0)
        } catch {
            print("network-check: FAILED: \(error)")
            if owner.isRunning { owner.terminate() }
            exit(1)
        }
    }
}
