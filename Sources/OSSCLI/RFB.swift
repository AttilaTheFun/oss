#if canImport(CommonCrypto)
import CommonCrypto
import CoreGraphics
import Foundation
import OSSClient
import ImageIO
import UniformTypeIdentifiers

/// Just enough of VNC's protocol (RFB 3.8, VNC password authentication,
/// raw pixels) to save one frame of a guest's screen as a PNG. The
/// connection goes through Apple's `/usr/bin/nc`, which macOS's local
/// network privacy allows.
struct RFBScreenshot {
    var host: String
    var port: Int
    var password: String

    struct Failure: Error, CustomStringConvertible { var description: String }

    func capture(to path: String) throws {
        let nc = Process()
        nc.executableURL = URL(fileURLWithPath: "/usr/bin/nc")
        nc.arguments = [host, String(port)]
        let input = Pipe(), output = Pipe()
        nc.standardInput = input
        nc.standardOutput = output
        nc.standardError = FileHandle.nullDevice
        try nc.run()
        defer { if nc.isRunning { nc.terminate() } }
        let reader = output.fileHandleForReading, writer = input.fileHandleForWriting

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
        func u16(_ b: [UInt8], _ i: Int) -> Int { Int(b[i]) << 8 | Int(b[i + 1]) }
        func u32(_ b: [UInt8], _ i: Int) -> Int { Int(b[i]) << 24 | Int(b[i + 1]) << 16 | Int(b[i + 2]) << 8 | Int(b[i + 3]) }
        func write(_ bytes: [UInt8]) { writer.write(Data(bytes)) }

        // Version: whatever the server says (Apple's is 3.889), 3.8 back.
        _ = try read(12)
        write(Array("RFB 003.008\n".utf8))
        let count = Int(try read(1)[0])
        if count == 0 {
            let length = u32(try read(4), 0)
            throw Failure(description: "VNC refused: \(String(decoding: try read(length), as: UTF8.self))")
        }
        let types = try read(count)
        if types.contains(2) && !password.isEmpty {
            write([2])
            let challenge = try read(16)
            write(try Self.vncResponse(challenge: challenge, password: password))
        } else if types.contains(1) {
            write([1])   // a server that asks for nothing (QEMU's, on loopback)
        } else {
            throw Failure(description: "the VNC server offers no authentication this client knows (types \(types))")
        }
        guard u32(try read(4), 0) == 0 else { throw Failure(description: "VNC authentication failed") }

        write([1])   // ClientInit: share the desktop.
        let serverInit = try read(24)
        let width = u16(serverInit, 0), height = u16(serverInit, 2)
        _ = try read(u32(serverInit, 20))   // the desktop's name

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
