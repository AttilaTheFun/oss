#if canImport(CommonCrypto)
import CommonCrypto
import CoreGraphics
import Foundation
import OSSClient
import ImageIO
import UniformTypeIdentifiers

/// Just enough of VNC's protocol (RFB 3.8, VNC password authentication)
/// to see a guest's screen and use its pointer and keyboard. The
/// connection goes through Apple's `/usr/bin/nc`, which macOS's local
/// network privacy allows.
final class RFBConnection: @unchecked Sendable {
    struct Failure: Error, CustomStringConvertible { var description: String }

    /// The framebuffer's size (changed by a DesktopSize update).
    var width = 0
    var height = 0
    private let nc: Process
    private let reader: FileHandle
    private let writer: FileHandle
    /// Writes come from the reading thread (requests) and the viewer's (input).
    private let writing = NSLock()

    /// A connection lasts at most `seconds`: a server that stops answering
    /// (a guest with no screen sends no frame) ends a read then, not never.
    /// A live view's (nil) lasts until it's closed.
    init(host: String, port: Int, password: String, seconds: Double? = 60) throws {
        nc = Process()
        nc.executableURL = URL(fileURLWithPath: "/usr/bin/nc")
        nc.arguments = [host, String(port)]
        let input = Pipe(), output = Pipe()
        nc.standardInput = input
        nc.standardOutput = output
        nc.standardError = FileHandle.nullDevice
        try nc.run()
        reader = output.fileHandleForReading
        writer = input.fileHandleForWriting
        let process = nc
        if let seconds {
            DispatchQueue.global().asyncAfter(deadline: .now() + seconds) { if process.isRunning { process.terminate() } }
        }
        do {
            // Version: whatever the server says (Apple's is 3.889), 3.8 back.
            _ = try read(12)
            write(Array("RFB 003.008\n".utf8))
            let count = Int(try read(1)[0])
            if count == 0 {
                let length = Self.u32(try read(4), 0)
                throw Failure(description: "VNC refused: \(String(decoding: try read(length), as: UTF8.self))")
            }
            // macOS's Screen Sharing offers Apple's own authentication (30)
            // first; VNC's password (2) is asked for by name.
            let types = try read(count)
            if types.contains(2) && !password.isEmpty {
                write([2])
                let challenge = try read(16)
                write(try RFBScreenshot.vncResponse(challenge: challenge, password: password))
            } else if types.contains(1) {
                write([1])   // a server that asks for nothing (QEMU's, on loopback)
            } else {
                throw Failure(description: "the VNC server offers no authentication this client knows (types \(types))")
            }
            guard Self.u32(try read(4), 0) == 0 else { throw Failure(description: "VNC authentication failed") }
            write([1])   // ClientInit: share the desktop.
            let serverInit = try read(24)
            width = Self.u16(serverInit, 0)
            height = Self.u16(serverInit, 2)
            _ = try read(Self.u32(serverInit, 20))   // the desktop's name
        } catch {
            if nc.isRunning { nc.terminate() }
            throw error
        }
    }

    deinit { close() }

    func close() {
        if nc.isRunning { nc.terminate() }
    }

    func read(_ count: Int) throws -> [UInt8] {
        var bytes = [UInt8]()
        bytes.reserveCapacity(count)
        while bytes.count < count {
            let chunk = reader.readData(ofLength: count - bytes.count)
            if chunk.isEmpty { throw Failure(description: "the VNC server closed the connection") }
            bytes.append(contentsOf: chunk)
        }
        return bytes
    }

    func write(_ bytes: [UInt8]) {
        writing.withLock { _ = try? writer.write(contentsOf: Data(bytes)) }
    }

    static func u16(_ b: [UInt8], _ i: Int) -> Int { Int(b[i]) << 8 | Int(b[i + 1]) }
    static func u32(_ b: [UInt8], _ i: Int) -> Int { Int(b[i]) << 24 | Int(b[i + 1]) << 16 | Int(b[i + 2]) << 8 | Int(b[i + 3]) }

    /// PointerEvent: the pointer at (x, y) in the framebuffer's pixels,
    /// with these buttons down (1 the left).
    func pointer(x: Int, y: Int, buttons: UInt8) {
        let x = max(0, min(width - 1, x)), y = max(0, min(height - 1, y))
        write([5, buttons, UInt8(x >> 8), UInt8(x & 255), UInt8(y >> 8), UInt8(y & 255)])
    }

    /// KeyEvent: an X keysym, down or up.
    func key(_ keysym: UInt32, down: Bool) {
        write([4, down ? 1 : 0, 0, 0, UInt8(keysym >> 24), UInt8(keysym >> 16 & 255), UInt8(keysym >> 8 & 255), UInt8(keysym & 255)])
    }
}

/// A guest's screen, live (OS Server's Screen window for its Linux and
/// Windows VMs): each change drawn into a framebuffer of its own as it comes
/// (raw and CopyRect rectangles, the desktop's size when it changes), a
/// frame handed on after each update, and the guest's pointer and keyboard.
public final class RFBSession: @unchecked Sendable {
    private let connection: RFBConnection
    private let lock = NSLock()
    private var context: CGContext?
    private var closed = false
    private let frame: @Sendable (CGImage) -> Void
    private let ended: @Sendable (String) -> Void

    /// Connected (VNC's handshake done) before it returns; `frame` and
    /// `ended` are called on its reading thread.
    public init(host: String, port: Int, password: String = "",
                frame: @escaping @Sendable (CGImage) -> Void, ended: @escaping @Sendable (String) -> Void) throws {
        connection = try RFBConnection(host: host, port: port, password: password, seconds: nil)
        self.frame = frame
        self.ended = ended
    }

    public var size: CGSize { lock.withLock { CGSize(width: connection.width, height: connection.height) } }

    public func start() {
        Thread.detachNewThread { [self] in
            do {
                try run()
            } catch {
                let quiet = lock.withLock { closed }
                if !quiet { ended("\(error)") }
            }
        }
    }

    public func close() {
        lock.withLock { closed = true }
        connection.close()
    }

    /// The pointer at (x, y) in the guest's pixels, these buttons down
    /// (1 left, 2 middle, 4 right; 8 and 16 a wheel's turn up and down).
    public func pointer(x: Int, y: Int, buttons: UInt8) { connection.pointer(x: x, y: y, buttons: buttons) }

    /// An X keysym, down or up (`keysym(for:)` for a character's).
    public func key(_ keysym: UInt32, down: Bool) { connection.key(keysym, down: down) }

    public static func keysym(for character: Character) -> UInt32 { MachineInput.keysym(for: character) }

    private func run() throws {
        let u16 = RFBConnection.u16, u32 = RFBConnection.u32
        // 32 bits a pixel, little-endian, 8 bits a channel: blue, green, red, unused.
        connection.write([0, 0, 0, 0, 32, 24, 0, 1, 0, 255, 0, 255, 0, 255, 16, 8, 0, 0, 0, 0])
        // SetEncodings: raw, CopyRect, DesktopSize (-223).
        connection.write([2, 0, 0, 3, 0, 0, 0, 0, 0, 0, 0, 1, 0xFF, 0xFF, 0xFF, 0x21])
        resize(width: connection.width, height: connection.height)
        request(incremental: false)
        while true {
            let type = try connection.read(1)[0]
            switch type {
            case 0:   // FramebufferUpdate
                var resized = false
                for _ in 0..<u16(try connection.read(3), 1) {
                    let r = try connection.read(12)
                    let x = u16(r, 0), y = u16(r, 2), w = u16(r, 4), h = u16(r, 6)
                    let encoding = Int32(bitPattern: UInt32(u32(r, 8)))
                    switch encoding {
                    case 0:
                        let data = try connection.read(w * h * 4)
                        lock.withLock { draw(data, x: x, y: y, w: w, h: h) }
                    case 1:
                        let source = try connection.read(4)
                        lock.withLock { copy(from: (u16(source, 0), u16(source, 2)), to: (x, y), w: w, h: h) }
                    case -223:
                        resize(width: w, height: h)
                        resized = true
                    default:
                        throw RFBConnection.Failure(description: "the VNC server sent encoding \(encoding)")
                    }
                }
                if let image = lock.withLock({ context?.makeImage() }) { frame(image) }
                request(incremental: !resized)
            case 1:   // SetColourMapEntries
                let head = try connection.read(5)
                _ = try connection.read(u16(head, 3) * 6)
            case 2:   // Bell
                break
            case 3:   // ServerCutText
                let head = try connection.read(7)
                _ = try connection.read(u32(head, 3))
            default:
                throw RFBConnection.Failure(description: "unexpected VNC message \(type)")
            }
        }
    }

    private func request(incremental: Bool) {
        let width = connection.width, height = connection.height
        connection.write([3, incremental ? 1 : 0, 0, 0, 0, 0, UInt8(width >> 8), UInt8(width & 255), UInt8(height >> 8), UInt8(height & 255)])
    }

    private func resize(width: Int, height: Int) {
        lock.withLock {
            connection.width = width
            connection.height = height
            let info = CGImageAlphaInfo.noneSkipFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
            context = CGContext(data: nil, width: max(width, 1), height: max(height, 1), bitsPerComponent: 8, bytesPerRow: max(width, 1) * 4,
                                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: info)
        }
    }

    /// Raw pixels into the framebuffer (rows top down, as RFB's are).
    private func draw(_ data: [UInt8], x: Int, y: Int, w: Int, h: Int) {
        guard let context, let base = context.data?.assumingMemoryBound(to: UInt8.self) else { return }
        let stride = context.bytesPerRow, width = context.width, height = context.height
        let span = max(0, min(w, width - x)) * 4
        guard span > 0 else { return }
        data.withUnsafeBufferPointer { source in
            for row in 0..<h where y + row < height {
                (base + (y + row) * stride + x * 4).update(from: source.baseAddress! + row * w * 4, count: span)
            }
        }
    }

    /// A rectangle moved within the framebuffer (it may overlap its source).
    private func copy(from source: (Int, Int), to target: (Int, Int), w: Int, h: Int) {
        guard let context, let base = context.data?.assumingMemoryBound(to: UInt8.self) else { return }
        let stride = context.bytesPerRow, width = context.width, height = context.height
        let span = max(0, min(w, width - source.0, width - target.0)) * 4
        guard span > 0 else { return }
        var rows = [UInt8](repeating: 0, count: span * h)
        for row in 0..<h where source.1 + row < height {
            rows.withUnsafeMutableBufferPointer { ($0.baseAddress! + row * span).update(from: base + (source.1 + row) * stride + source.0 * 4, count: span) }
        }
        for row in 0..<h where target.1 + row < height {
            rows.withUnsafeBufferPointer { (base + (target.1 + row) * stride + target.0 * 4).update(from: $0.baseAddress! + row * span, count: span) }
        }
    }
}

/// One frame of a guest's screen, saved as a PNG (raw pixels).
struct RFBScreenshot {
    var host: String
    var port: Int
    var password: String

    typealias Failure = RFBConnection.Failure

    func capture(to path: String) throws {
        let connection = try RFBConnection(host: host, port: port, password: password)
        defer { connection.close() }
        let width = connection.width, height = connection.height
        let u16 = RFBConnection.u16, u32 = RFBConnection.u32
        func read(_ count: Int) throws -> [UInt8] { try connection.read(count) }
        func write(_ bytes: [UInt8]) { connection.write(bytes) }

        // 32 bits a pixel, little-endian, 8 bits a channel: blue, green, red, unused.
        write([0, 0, 0, 0, 32, 24, 0, 1, 0, 255, 0, 255, 0, 255, 16, 8, 0, 0, 0, 0])
        write([2, 0, 0, 1, 0, 0, 0, 0])   // SetEncodings: raw only
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        var painted = 0
        var requests = 0
        // Apple's server answers the first request with a blank frame: a
        // few whole-screen requests, and the last frame kept.
        let rounds = 3
        while (painted < width * height || requests < rounds) && requests < rounds + 4 {
            if requests > 0 { Thread.sleep(forTimeInterval: 0.7) }
            requests += 1
            write([3, 0, 0, 0, 0, 0, UInt8(width >> 8), UInt8(width & 255), UInt8(height >> 8), UInt8(height & 255)])
            var updated = false
            while !updated {
                let type = try read(1)[0]
                switch type {
                case 0:   // FramebufferUpdate
                    let rects = u16(try read(3), 1)
                    for _ in 0..<rects {
                        let r = try read(12)
                        let x = u16(r, 0), y = u16(r, 2), w = u16(r, 4), h = u16(r, 6)
                        guard r[8] == 0, r[9] == 0, r[10] == 0, r[11] == 0 else {
                            throw Failure(description: "the VNC server sent an encoding other than raw")
                        }
                        let data = try read(w * h * 4)
                        for row in 0..<h where y + row < height {
                            let source = row * w * 4, target = ((y + row) * width + x) * 4
                            let span = min(w, width - x) * 4
                            pixels.replaceSubrange(target..<(target + span), with: data[source..<(source + span)])
                        }
                        painted += w * h
                    }
                    updated = true
                case 1:   // SetColourMapEntries
                    let head = try read(5)
                    _ = try read(u16(head, 3) * 6)
                case 2:   // Bell
                    break
                case 3:   // ServerCutText
                    let head = try read(7)
                    _ = try read(u32(head, 3))
                default:
                    throw Failure(description: "unexpected VNC message \(type)")
                }
            }
        }
        try Self.writePNG(pixels: pixels, width: width, height: height, to: path)
    }

    /// VNC's challenge answered with DES, keyed by the password with each
    /// byte's bits reversed (as VNC has always done).
    static func vncResponse(challenge: [UInt8], password: String) throws -> [UInt8] {
        var key = [UInt8](repeating: 0, count: 8)
        for (i, byte) in password.utf8.prefix(8).enumerated() {
            var reversed: UInt8 = 0
            for bit in 0..<8 where byte & (1 << bit) != 0 { reversed |= 1 << (7 - bit) }
            key[i] = reversed
        }
        var out = [UInt8](repeating: 0, count: 16)
        var moved = 0
        let status = CCCrypt(CCOperation(kCCEncrypt), CCAlgorithm(kCCAlgorithmDES), CCOptions(kCCOptionECBMode),
                             key, 8, nil, challenge, 16, &out, 16, &moved)
        guard status == kCCSuccess else { throw Failure(description: "DES failed (\(status))") }
        return out
    }

    static func writePNG(pixels: [UInt8], width: Int, height: Int, to path: String) throws {
        let info = CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
        guard let provider = CGDataProvider(data: Data(pixels) as CFData),
              let image = CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
                                  space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: info, provider: provider,
                                  decode: nil, shouldInterpolate: false, intent: .defaultIntent),
              let destination = CGImageDestinationCreateWithURL(URL(fileURLWithPath: path) as CFURL,
                                                                UTType.png.identifier as CFString, 1, nil) else {
            throw Failure(description: "could not make the PNG")
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { throw Failure(description: "could not write \(path)") }
    }
}

#endif
