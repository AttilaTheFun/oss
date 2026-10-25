import Foundation
import OSSClient

/// Taps, swipes, text and keys on a lease's screen, in its screenshot's
/// pixels: `adb input` on an emulator; AXe on a simulator (idb's HID client,
/// which `simctl` has no command for; points, so pixels are divided by the
/// screen's scale); VNC's pointer and key events on a VM (its framebuffer's
/// pixels, the screenshot's).
enum MachineInput {
    static func check(_ request: InputRequest) throws {
        switch request.action {
        case .tap:
            guard request.x != nil, request.y != nil else { throw APIError(error: "a tap needs x and y") }
        case .swipe:
            guard request.x != nil, request.y != nil, request.toX != nil, request.toY != nil else {
                throw APIError(error: "a swipe needs x, y, toX and toY")
            }
        case .type:
            guard let text = request.text, !text.isEmpty else { throw APIError(error: "type needs text") }
        case .key:
            guard let key = request.key, !key.isEmpty else { throw APIError(error: "key needs a key") }
        }
    }

    static func milliseconds(_ request: InputRequest) -> Int { max(50, min(10_000, request.milliseconds ?? 300)) }

    // MARK: Android

    static let androidKeys: [String: Int] = [
        "return": 66, "enter": 66, "tab": 61, "escape": 111, "backspace": 67, "delete": 112, "space": 62,
        "up": 19, "down": 20, "left": 21, "right": 22, "pageup": 92, "pagedown": 93, "home": 3, "back": 4,
    ]

    static func android(_ request: InputRequest, port: Int) async throws {
        func px(_ value: Double?) -> String { String(Int((value ?? 0).rounded())) }
        let arguments: [String]
        switch request.action {
        case .tap:
            arguments = ["input", "tap", px(request.x), px(request.y)]
        case .swipe:
            arguments = ["input", "swipe", px(request.x), px(request.y), px(request.toX), px(request.toY), String(milliseconds(request))]
        case .type:
            // One argument to the device's shell: single-quoted, its spaces
            // as `input text` spells them (%s).
            let text = (request.text ?? "").replacingOccurrences(of: " ", with: "%s")
            arguments = ["input", "text", "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'"]
        case .key:
            let name = (request.key ?? "").lowercased()
            guard let code = androidKeys[name] ?? Int(name) else {
                throw APIError(error: "no Android key \(name) (names: \(androidKeys.keys.sorted().joined(separator: ", ")), or a keycode)")
            }
            arguments = ["input", "keyevent", String(code)]
        }
        let result = try await Emulators.adb(ServerConfig.load(), ["-s", "emulator-\(port)", "shell"] + arguments, timeout: 60)
        guard result.ok else { throw APIError(error: "adb input: \(result.error)\(result.output)") }
    }

    // MARK: iOS simulators (AXe)

    /// AXe (github.com/cameroncooke/AXe, MIT; `brew install cameroncooke/axe/axe`).
    static var axe: String? {
        let candidates = [ServerConfig.load().axePath, "/opt/homebrew/bin/axe", "/usr/local/bin/axe"].compactMap { $0 }
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    /// HID usages (the keyboard page) for the named keys.
    static let iosKeys: [String: Int] = [
        "return": 40, "enter": 40, "escape": 41, "backspace": 42, "tab": 43, "space": 44, "delete": 76,
        "right": 79, "left": 80, "down": 81, "up": 82, "pageup": 75, "pagedown": 78,
    ]

    static func simulator(_ request: InputRequest, udid: String) async throws {
        guard let axe else {
            throw APIError(error: "simulator input needs AXe on the server's Mac: brew install cameroncooke/axe/axe (or axePath in server.json)")
        }
        let scale = try await Simulators.screenScale(udid: udid)
        func pt(_ value: Double?) -> String { String(format: "%.1f", (value ?? 0) / scale) }
        let arguments: [String]
        switch request.action {
        case .tap:
            arguments = ["tap", "-x", pt(request.x), "-y", pt(request.y)]
        case .swipe:
            arguments = ["swipe", "--start-x", pt(request.x), "--start-y", pt(request.y), "--end-x", pt(request.toX),
                         "--end-y", pt(request.toY), "--duration", String(format: "%.2f", Double(milliseconds(request)) / 1000)]
        case .type:
            arguments = ["type", request.text ?? ""]
        case .key:
            let name = (request.key ?? "").lowercased()
            if name == "home" {
                arguments = ["button", "home"]
            } else {
                guard let code = iosKeys[name] ?? Int(name) else {
                    throw APIError(error: "no iOS key \(name) (names: home, \(iosKeys.keys.sorted().joined(separator: ", ")), or a HID usage)")
                }
                arguments = ["key", String(code)]
            }
        }
        let result = try await Shell.run(axe, arguments + ["--udid", udid], timeout: 60)
        guard result.ok else { throw APIError(error: "axe \(arguments[0]): \(result.error)\(result.output)") }
    }

    // MARK: VMs (VNC)

    #if canImport(CommonCrypto)

    static let keysyms: [String: UInt32] = [
        "return": 0xFF0D, "enter": 0xFF0D, "tab": 0xFF09, "escape": 0xFF1B, "backspace": 0xFF08, "delete": 0xFFFF,
        "space": 0x20, "up": 0xFF52, "down": 0xFF54, "left": 0xFF51, "right": 0xFF53, "pageup": 0xFF55,
        "pagedown": 0xFF56, "home": 0xFF50, "end": 0xFF57,
        "f1": 0xFFBE, "f2": 0xFFBF, "f3": 0xFFC0, "f4": 0xFFC1, "f5": 0xFFC2, "f6": 0xFFC3,
        "f7": 0xFFC4, "f8": 0xFFC5, "f9": 0xFFC6, "f10": 0xFFC7, "f11": 0xFFC8, "f12": 0xFFC9,
    ]
    /// Modifiers, as `cmd+a`: on a Mac's Screen Sharing Super is Command; on
    /// Windows it is the Windows key.
    static let modifiers: [String: UInt32] = [
        "shift": 0xFFE1, "ctrl": 0xFFE3, "control": 0xFFE3, "alt": 0xFFE9, "option": 0xFFE9,
        "cmd": 0xFFEB, "command": 0xFFEB, "super": 0xFFEB, "win": 0xFFEB, "meta": 0xFFEB,
    ]
    /// US keyboard: the characters typed with Shift.
    static let shifted = Set("~!@#$%^&*()_+{}|:\"<>?ABCDEFGHIJKLMNOPQRSTUVWXYZ")

    static func keysym(for character: Character) -> UInt32 {
        guard let scalar = character.unicodeScalars.first else { return 0 }
        switch scalar.value {
        case 0x0A, 0x0D: return 0xFF0D
        case 0x09: return 0xFF09
        case 0x20...0x7E, 0xA0...0xFF: return scalar.value
        default: return 0x0100_0000 | scalar.value
        }
    }

    static func vnc(_ request: InputRequest, host: String, port: Int, password: String) throws {
        let connection = try RFBConnection(host: host, port: port, password: password)
        defer {
            // A moment for the server to act before the connection closes.
            Thread.sleep(forTimeInterval: 0.15)
            connection.close()
        }
        func px(_ value: Double?) -> Int { Int((value ?? 0).rounded()) }
        switch request.action {
        case .tap:
            connection.pointer(x: px(request.x), y: px(request.y), buttons: 0)
            Thread.sleep(forTimeInterval: 0.05)
            connection.pointer(x: px(request.x), y: px(request.y), buttons: 1)
            Thread.sleep(forTimeInterval: 0.08)
            connection.pointer(x: px(request.x), y: px(request.y), buttons: 0)
        case .swipe:
            let steps = max(5, milliseconds(request) / 16)
            let (x0, y0, x1, y1) = (request.x ?? 0, request.y ?? 0, request.toX ?? 0, request.toY ?? 0)
            connection.pointer(x: px(x0), y: px(y0), buttons: 0)
            connection.pointer(x: px(x0), y: px(y0), buttons: 1)
            for step in 1...steps {
                let t = Double(step) / Double(steps)
                Thread.sleep(forTimeInterval: Double(milliseconds(request)) / 1000 / Double(steps))
                connection.pointer(x: px(x0 + (x1 - x0) * t), y: px(y0 + (y1 - y0) * t), buttons: 1)
            }
            connection.pointer(x: px(x1), y: px(y1), buttons: 0)
        case .type:
            for character in request.text ?? "" {
                let shift = shifted.contains(character)
                if shift { connection.key(0xFFE1, down: true) }
                let sym = keysym(for: character)
                connection.key(sym, down: true)
                connection.key(sym, down: false)
                if shift { connection.key(0xFFE1, down: false) }
                Thread.sleep(forTimeInterval: 0.01)
            }
        case .key:
            let parts = (request.key ?? "").lowercased().split(separator: "+").map(String.init)
            guard let last = parts.last else { throw APIError(error: "key needs a key") }
            var held: [UInt32] = []
            for name in parts.dropLast() {
                guard let sym = modifiers[name] else { throw APIError(error: "no modifier \(name) (\(modifiers.keys.sorted().joined(separator: ", ")))") }
                held.append(sym)
            }
            let sym: UInt32
            if let named = keysyms[last] {
                sym = named
            } else if last.hasPrefix("0x"), let value = UInt32(last.dropFirst(2), radix: 16) {
                sym = value
            } else if last.count == 1, let character = last.first {
                sym = keysym(for: character)
            } else {
                throw APIError(error: "no key \(last) (names: \(keysyms.keys.sorted().joined(separator: ", ")), a character, or a keysym as 0x…)")
            }
            for modifier in held { connection.key(modifier, down: true) }
            connection.key(sym, down: true)
            connection.key(sym, down: false)
            for modifier in held.reversed() { connection.key(modifier, down: false) }
        }
    }
    #endif
}
