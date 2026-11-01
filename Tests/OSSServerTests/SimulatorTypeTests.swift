import Foundation
import Testing
import OSSClient
@testable import OSSServer

// An iOS lease of a device type and runtime of its own (API 11): what
// `--device` and `--runtime` resolve to among simctl's lists, and what's
// refused. The lists are simctl's JSON as Xcode 27.0 prints them, cut down.

let deviceTypesJSON = """
    {"devicetypes": [
      {"name": "iPhone 18 Pro", "identifier": "com.apple.CoreSimulator.SimDeviceType.iPhone-18-Pro", "productFamily": "iPhone"},
      {"name": "iPhone 18 Pro Max", "identifier": "com.apple.CoreSimulator.SimDeviceType.iPhone-18-Pro-Max", "productFamily": "iPhone"},
      {"name": "iPhone 17 Pro", "identifier": "com.apple.CoreSimulator.SimDeviceType.iPhone-17-Pro", "productFamily": "iPhone"},
      {"name": "iPhone Xs", "identifier": "com.apple.CoreSimulator.SimDeviceType.iPhone-XS", "productFamily": "iPhone"},
      {"name": "iPad Pro 13-inch (M5) (16GB)", "identifier": "com.apple.CoreSimulator.SimDeviceType.iPad-Pro-13-inch-M5-16GB", "productFamily": "iPad"},
      {"name": "iPad Pro 13-inch (M5)", "identifier": "com.apple.CoreSimulator.SimDeviceType.iPad-Pro-13-inch-M5-12GB", "productFamily": "iPad"},
      {"name": "iPad Pro 11-inch (M5)", "identifier": "com.apple.CoreSimulator.SimDeviceType.iPad-Pro-11-inch-M5-12GB", "productFamily": "iPad"},
      {"name": "iPad mini (A17 Pro)", "identifier": "com.apple.CoreSimulator.SimDeviceType.iPad-mini-A17-Pro", "productFamily": "iPad"},
      {"name": "Apple Watch Series 11 (46mm)", "identifier": "com.apple.CoreSimulator.SimDeviceType.Apple-Watch-Series-11-46mm", "productFamily": "Apple Watch"}
    ]}
    """

let runtimesJSON = """
    {"runtimes": [
      {"name": "iOS 18.6", "identifier": "com.apple.CoreSimulator.SimRuntime.iOS-18-6", "version": "18.6", "platform": "iOS",
       "isAvailable": true, "supportedDeviceTypes": [
         {"name": "iPhone 17 Pro", "identifier": "com.apple.CoreSimulator.SimDeviceType.iPhone-17-Pro", "productFamily": "iPhone"},
         {"name": "iPhone Xs", "identifier": "com.apple.CoreSimulator.SimDeviceType.iPhone-XS", "productFamily": "iPhone"},
         {"name": "iPad mini (A17 Pro)", "identifier": "com.apple.CoreSimulator.SimDeviceType.iPad-mini-A17-Pro", "productFamily": "iPad"}]},
      {"name": "iOS 27.0", "identifier": "com.apple.CoreSimulator.SimRuntime.iOS-27-0", "version": "27.0", "platform": "iOS",
       "isAvailable": true, "supportedDeviceTypes": [
         {"name": "iPhone 18 Pro", "identifier": "com.apple.CoreSimulator.SimDeviceType.iPhone-18-Pro", "productFamily": "iPhone"},
         {"name": "iPhone 18 Pro Max", "identifier": "com.apple.CoreSimulator.SimDeviceType.iPhone-18-Pro-Max", "productFamily": "iPhone"},
         {"name": "iPhone 17 Pro", "identifier": "com.apple.CoreSimulator.SimDeviceType.iPhone-17-Pro", "productFamily": "iPhone"},
         {"name": "iPad Pro 13-inch (M5) (16GB)", "identifier": "com.apple.CoreSimulator.SimDeviceType.iPad-Pro-13-inch-M5-16GB", "productFamily": "iPad"},
         {"name": "iPad Pro 13-inch (M5)", "identifier": "com.apple.CoreSimulator.SimDeviceType.iPad-Pro-13-inch-M5-12GB", "productFamily": "iPad"},
         {"name": "iPad Pro 11-inch (M5)", "identifier": "com.apple.CoreSimulator.SimDeviceType.iPad-Pro-11-inch-M5-12GB", "productFamily": "iPad"},
         {"name": "iPad mini (A17 Pro)", "identifier": "com.apple.CoreSimulator.SimDeviceType.iPad-mini-A17-Pro", "productFamily": "iPad"}]},
      {"name": "iOS 26.4", "identifier": "com.apple.CoreSimulator.SimRuntime.iOS-26-4", "version": "26.4", "platform": "iOS",
       "isAvailable": false, "supportedDeviceTypes": []},
      {"name": "watchOS 27.0", "identifier": "com.apple.CoreSimulator.SimRuntime.watchOS-27-0", "version": "27.0", "platform": "watchOS",
       "isAvailable": true, "supportedDeviceTypes": [
         {"name": "Apple Watch Series 11 (46mm)", "identifier": "com.apple.CoreSimulator.SimDeviceType.Apple-Watch-Series-11-46mm", "productFamily": "Apple Watch"}]}
    ]}
    """

struct SimctlLists {
    var types: [Simulators.DeviceType]
    var runtimes: [Simulators.Runtime]

    init() throws {
        struct Types: Decodable { var devicetypes: [Simulators.DeviceType] }
        struct Runtimes: Decodable { var runtimes: [Simulators.Runtime] }
        types = try JSONDecoder().decode(Types.self, from: Data(deviceTypesJSON.utf8)).devicetypes
        runtimes = try JSONDecoder().decode(Runtimes.self, from: Data(runtimesJSON.utf8)).runtimes
    }

    func runtime(_ name: String) -> Simulators.Runtime { runtimes.first { $0.name == name }! }

    /// What `pick` makes of a lease's `device` and `runtime` against a base
    /// of an iPhone 17 Pro on iOS 27.0 (the vanilla `iphone` config's).
    func pick(device: String? = nil, runtime: String? = nil, baseRuntime: String? = "com.apple.CoreSimulator.SimRuntime.iOS-27-0")
        throws -> Simulators.Choice {
        try Simulators.pick(device: device, runtime: runtime, baseType: "com.apple.CoreSimulator.SimDeviceType.iPhone-17-Pro",
                            baseRuntime: baseRuntime, types: types, runtimes: runtimes)
    }
}

/// The refusal a lease is answered with, or nil if there was none.
func refusal(_ body: () throws -> Any) -> APIError? {
    do {
        _ = try body()
        return nil
    } catch let error as APIError {
        return error
    } catch {
        return APIError(error: "\(error)")
    }
}

@Test func deviceTypesByNameInAnyCase() throws {
    let lists = try SimctlLists()
    let ios27 = lists.runtime("iOS 27.0")
    for (asked, identifier) in [
        ("iPad Pro 13-inch (M5)", "iPad-Pro-13-inch-M5-12GB"),
        ("ipad pro 13-inch (m5)", "iPad-Pro-13-inch-M5-12GB"),
        ("  IPAD PRO 13-INCH (M5) (16GB) ", "iPad-Pro-13-inch-M5-16GB"),
        ("iPhone  18 Pro", "iPhone-18-Pro"),
        ("iphone 18 pro max", "iPhone-18-Pro-Max"),
    ] {
        let type = try Simulators.resolveDevice(asked, among: lists.types, runtime: ios27)
        #expect(type.identifier == "com.apple.CoreSimulator.SimDeviceType.\(identifier)", "\(asked)")
    }
}

@Test func deviceTypesByIdentifier() throws {
    let lists = try SimctlLists()
    let ios27 = lists.runtime("iOS 27.0")
    for asked in ["com.apple.CoreSimulator.SimDeviceType.iPad-Pro-13-inch-M5-12GB",
                  "COM.APPLE.CORESIMULATOR.SIMDEVICETYPE.IPAD-PRO-13-INCH-M5-12GB",
                  "iPad-Pro-13-inch-M5-12GB", "ipad-pro-13-inch-m5-12gb"] {
        let type = try Simulators.resolveDevice(asked, among: lists.types, runtime: ios27)
        #expect(type.name == "iPad Pro 13-inch (M5)", "\(asked)")
    }
}

@Test func unknownDeviceTypesNameTheCloseOnes() throws {
    let lists = try SimctlLists()
    let ios27 = lists.runtime("iOS 27.0")
    // Every word of it in their names: the close ones, and only those.
    let pro = try #require(refusal { try Simulators.resolveDevice("ipad pro", among: lists.types, runtime: ios27) })
    #expect(pro.code == "noDevice")
    #expect(pro.error.hasPrefix("no device type \"ipad pro\"; close: "))
    #expect(pro.error.contains("iPad Pro 13-inch (M5)") && pro.error.contains("iPad Pro 11-inch (M5)"))
    #expect(!pro.error.contains("iPhone") && !pro.error.contains("mini"))
    let eighteen = try #require(refusal { try Simulators.resolveDevice("iPhone 18", among: lists.types, runtime: ios27) })
    #expect(eighteen.error == "no device type \"iPhone 18\"; close: iPhone 18 Pro, iPhone 18 Pro Max")

    // Nothing close: every iPhone and iPad the runtime runs, and nothing else.
    let duo = try #require(refusal { try Simulators.resolveDevice("iPhone Duo", among: lists.types, runtime: ios27) })
    #expect(duo.code == "noDevice")
    #expect(duo.error == "no device type \"iPhone Duo\"; iOS 27.0 runs: iPhone 18 Pro, iPhone 18 Pro Max, iPhone 17 Pro, "
                       + "iPad Pro 13-inch (M5) (16GB), iPad Pro 13-inch (M5), iPad Pro 11-inch (M5), iPad mini (A17 Pro)")

    // A watch isn't an iOS device, whatever its name.
    let watch = try #require(refusal { try Simulators.resolveDevice("Apple Watch Series 11 (46mm)", among: lists.types, runtime: ios27) })
    #expect(watch.error.hasPrefix("no device type \"Apple Watch Series 11 (46mm)\"; iOS 27.0 runs: "))

    // The close ones are those the runtime runs: iOS 18.6 has no iPad Pro (M5).
    let older = try #require(refusal { try Simulators.resolveDevice("pro", among: lists.types, runtime: lists.runtime("iOS 18.6")) })
    #expect(older.error == "no device type \"pro\"; close: iPhone 17 Pro, iPad mini (A17 Pro)")
}

@Test func aTypeTheRuntimeDoesNotRunIsRefused() throws {
    let lists = try SimctlLists()
    let xs = try #require(refusal { try Simulators.resolveDevice("iPhone Xs", among: lists.types, runtime: lists.runtime("iOS 27.0")) })
    #expect(xs.code == "noDevice")
    #expect(xs.error.hasPrefix("iPhone Xs doesn't run on iOS 27.0; it runs: iPhone 18 Pro, "))
    // On a runtime that runs it, it is the type.
    #expect(try Simulators.resolveDevice("iPhone Xs", among: lists.types, runtime: lists.runtime("iOS 18.6")).name == "iPhone Xs")
}

@Test func runtimesByNameIdentifierOrVersion() throws {
    let lists = try SimctlLists()
    let ios = lists.runtimes.filter { $0.platform == "iOS" && $0.isAvailable != false }
    for asked in ["iOS 27.0", "ios 27.0", "iOS27.0", "27.0", "com.apple.CoreSimulator.SimRuntime.iOS-27-0", "iOS-27-0", "ios-27-0"] {
        #expect(try Simulators.resolveRuntime(asked, among: ios).identifier == "com.apple.CoreSimulator.SimRuntime.iOS-27-0", "\(asked)")
    }
    let missing = try #require(refusal { try Simulators.resolveRuntime("iOS 99.0", among: ios) })
    #expect(missing.code == "noDevice")
    #expect(missing.error == "no iOS runtime \"iOS 99.0\"; there are: iOS 18.6, iOS 27.0")
}

@Test func aVersionsOwnRuntimeOverOneOfADeviceTypes() throws {
    // Xcode 27.2: beside iOS 27.2's runtime, one of that version for one
    // device type, listed first.
    let iPhone = #"{"name": "iPhone 17 Pro", "identifier": "com.apple.CoreSimulator.SimDeviceType.iPhone-17-Pro", "productFamily": "iPhone"}"#
    let iPad = #"{"name": "iPad Pro 13-inch (M5)", "identifier": "com.apple.CoreSimulator.SimDeviceType.iPad-Pro-13-inch-M5-12GB", "productFamily": "iPad"}"#
    let duo = #"{"name": "iPhone Duo", "identifier": "com.apple.CoreSimulator.SimDeviceType.iPhone-Duo", "productFamily": "iPhone"}"#
    let json = """
        [{"name": "iOS 27.2", "identifier": "com.apple.CoreSimulator.SimRuntime.iOS-27-2-iPhone19-4", "version": "27.2", "platform": "iOS",
          "isAvailable": true, "supportedDeviceTypes": [\(duo)]},
         {"name": "iOS 27.2", "identifier": "com.apple.CoreSimulator.SimRuntime.iOS-27-2", "version": "27.2", "platform": "iOS",
          "isAvailable": true, "supportedDeviceTypes": [\(iPhone), \(iPad)]}]
        """
    let runtimes = try JSONDecoder().decode([Simulators.Runtime].self, from: Data(json.utf8))
    for asked in ["iOS 27.2", "27.2", "ios27.2"] {
        #expect(try Simulators.resolveRuntime(asked, among: runtimes).identifier == "com.apple.CoreSimulator.SimRuntime.iOS-27-2", "\(asked)")
    }
    // Asked for by its identifier, the device type's own.
    #expect(try Simulators.resolveRuntime("iOS-27-2-iPhone19-4", among: runtimes).identifier
        == "com.apple.CoreSimulator.SimRuntime.iOS-27-2-iPhone19-4")
}

@Test func whatALeaseIsMadeOf() throws {
    let lists = try SimctlLists()
    // A device type: on the base's runtime.
    let ipad = try lists.pick(device: "iPad Pro 13-inch (M5)")
    #expect(ipad.deviceType.name == "iPad Pro 13-inch (M5)" && ipad.runtime.name == "iOS 27.0")
    // A runtime: the base's device type on it.
    let older = try lists.pick(runtime: "iOS 18.6")
    #expect(older.deviceType.name == "iPhone 17 Pro" && older.runtime.name == "iOS 18.6")
    // Both.
    let both = try lists.pick(device: "iPhone Xs", runtime: "18.6")
    #expect(both.deviceType.name == "iPhone Xs" && both.runtime.name == "iOS 18.6")
    // A watchOS or unavailable runtime isn't one to make an iOS simulator on.
    #expect(refusal { try lists.pick(runtime: "watchOS 27.0") }?.code == "noDevice")
    #expect(refusal { try lists.pick(runtime: "iOS 26.4") }?.code == "noDevice")
    // A base whose runtime is gone (Xcode updated) needs one asked for.
    let gone = try #require(refusal { try lists.pick(device: "iPhone 18 Pro", baseRuntime: "com.apple.CoreSimulator.SimRuntime.iOS-26-0") })
    #expect(gone.error.hasPrefix("the config's base has no iOS runtime this Mac has"))
    #expect(try lists.pick(device: "iPhone 18 Pro", runtime: "iOS 27.0", baseRuntime: nil).deviceType.name == "iPhone 18 Pro")
}

@Test func leaseRequestsAndLeasesCarryTheDevice() throws {
    // Asked for on the command line, sent in the request.
    let request = leaseRequest(Arguments(["machine", "lease", "ios", "--device", "iPad Pro 13-inch (M5)", "--runtime=iOS 27.0"],
                                         valued: ["device", "runtime"]), platformArgument: "ios")
    #expect(request.device == "iPad Pro 13-inch (M5)" && request.runtime == "iOS 27.0")
    let sent = try JSONDecoder.oss.decode(LeaseRequest.self, from: JSONEncoder.oss.encode(request))
    #expect(sent.device == "iPad Pro 13-inch (M5)" && sent.runtime == "iOS 27.0")
    // A client before API 11 sends neither.
    let old = try JSONDecoder.oss.decode(LeaseRequest.self, from: Data(#"{"platform": "ios", "config": "iphone"}"#.utf8))
    #expect(old.device == nil && old.runtime == nil)

    // The lease says what it is, in its JSON and in oss machine list's line.
    var lease = Lease(id: "c44d8a20", platform: .ios, config: "iphone", name: "oss-lease-ios-c44d8a20", holder: "someone@workstation",
                      state: .ready, created: Date(timeIntervalSince1970: 1_800_000_000),
                      expires: Date(timeIntervalSince1970: 1_800_003_600), kind: .manual)
    lease.device = "iPad Pro 13-inch (M5)"
    lease.runtime = "iOS 27.0"
    let json = String(decoding: try JSONEncoder.oss.encode(lease), as: UTF8.self)
    #expect(json.contains(#""device" : "iPad Pro 13-inch (M5)""#) && json.contains(#""runtime" : "iOS 27.0""#))
    #expect(leaseLine(lease).hasPrefix("c44d8a20  ios/iphone (iPad Pro 13-inch (M5))  ready  manual  someone@workstation  until "))
    lease.device = nil
    #expect(leaseLine(lease).hasPrefix("c44d8a20  ios/iphone  ready  "))
}

@Test func theStatusBarsDateIsFixedToo() throws {
    // What status_bar takes for a date (with fractional seconds), 9:41 where the simulator is.
    let stamp = Simulators.stillTime
    #expect(stamp.wholeMatch(of: /2007-01-09T09:41:00\.000(Z|[+-]\d\d:\d\d)/) != nil, "\(stamp)")
    let parser = ISO8601DateFormatter()
    parser.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    let date = try #require(parser.date(from: stamp))
    let local = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: date)
    #expect(local == DateComponents(year: 2007, month: 1, day: 9, hour: 9, minute: 41))
}

// On a Mac with Xcode's simulators (a leased macOS VM's, never the server's
// own: it makes and deletes simulators), with OSS_TEST_SIMCTL=1: the real
// lists resolve, and a simulator made of a device type is that type.
@Test(.enabled(if: ProcessInfo.processInfo.environment["OSS_TEST_SIMCTL"] == "1"))
func realSimulatorsOfADeviceType() async throws {
    let types = try await Simulators.deviceTypes()
    // The newest that runs both: not a runtime of one device type's
    // (Xcode 27.2's iOS-27-2-iPhone19-4 runs the iPhone Duo alone).
    let runtime = try #require(try await Simulators.runtimes().last { runtime in
        runtime.platform == "iOS" && runtime.isAvailable != false
            && ["iPad", "iPhone"].allSatisfy { family in runtime.supportedDeviceTypes?.contains { $0.productFamily == family } ?? true }
    })
    for (asked, family) in [("iPad Pro 13-inch (M5)", "iPad"), ("iphone 17 pro", "iPhone")] {
        let type = try Simulators.resolveDevice(asked, among: types, runtime: runtime)
        #expect(type.productFamily == family)
        let name = "oss-test-\(Random.hex(4))"
        let udid = try await Simulators.create(name: name, choice: Simulators.Choice(deviceType: type, runtime: runtime), config: "none")
        let made = try await Simulators.devices().first { $0.udid == udid }
        await Simulators.release(udid: udid)
        #expect(made?.deviceTypeIdentifier == type.identifier && made?.runtime == runtime.identifier && made?.state == "Booted")
        #expect(try await Simulators.devices().contains { $0.udid == udid } == false)
    }
    #expect(refusal { try Simulators.resolveDevice("iPhone Duo", among: types, runtime: runtime) }?.code == "noDevice")
}
