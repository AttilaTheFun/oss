// A Mac window's picture cut from a VM's screenshot, for CI's proof
// (tools/ci/proof.sh builds this file with swiftc on the runner), as
// tools/proof.py cuts OS Server's:
//
//   window_shot <screen.png> <x> <y> <width> <height> <window.png>
//
// The window's frame in the screenshot's pixels (tools/window_rect.swift,
// in the guest's session), its outer pixel and the curve of its corners
// made transparent: there its edge blends with its shadow and whatever is
// behind it, which differs from run to run while the window's own pixels
// don't.
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// A window's corners in a VM's screenshots (macOS 27, at 1x): the curve is
/// 14 pixels in from its outer pixel; two more for a darker shadow.
let cornerRadius = 16.0

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("window_shot: \(message)\n".utf8))
    exit(1)
}

let arguments = CommandLine.arguments
guard arguments.count == 7, let x = Int(arguments[2]), let y = Int(arguments[3]), let width = Int(arguments[4]),
      let height = Int(arguments[5]), width > 2, height > 2 else {
    fail("usage: window_shot <screen.png> <x> <y> <width> <height> <window.png>")
}
guard let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: arguments[1]) as CFURL, nil),
      let screen = CGImageSourceCreateImageAtIndex(source, 0, nil) else { fail("can't read \(arguments[1])") }
// The frame less its outer pixel, within the screen.
let frame = CGRect(x: x + 1, y: y + 1, width: width - 2, height: height - 2)
    .intersection(CGRect(x: 0, y: 0, width: screen.width, height: screen.height))
guard !frame.isEmpty, let window = screen.cropping(to: frame) else { fail("the frame \(x) \(y) \(width) \(height) is off the screen") }

guard let context = CGContext(data: nil, width: window.width, height: window.height, bitsPerComponent: 8, bytesPerRow: 0,
                              space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
    fail("no context to draw in")
}
let bounds = CGRect(x: 0, y: 0, width: window.width, height: window.height)
context.addPath(CGPath(roundedRect: bounds, cornerWidth: cornerRadius, cornerHeight: cornerRadius, transform: nil))
context.clip()
context.draw(window, in: bounds)
guard let picture = context.makeImage(),
      let destination = CGImageDestinationCreateWithURL(URL(fileURLWithPath: arguments[6]) as CFURL, UTType.png.identifier as CFString, 1, nil)
else { fail("can't make \(arguments[6])") }
CGImageDestinationAddImage(destination, picture, nil)
guard CGImageDestinationFinalize(destination) else { fail("can't write \(arguments[6])") }
