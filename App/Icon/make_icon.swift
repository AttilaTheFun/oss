// Draws the app's icon, every size an .iconset holds:
//   swift App/Icon/make_icon.swift <out.iconset>
// A deep blue rounded square with stacked machines in white.
import AppKit

let out = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "AppIcon.iconset"
try FileManager.default.createDirectory(atPath: out, withIntermediateDirectories: true)

func draw(_ pixels: Int) -> Data {
    let size = CGFloat(pixels)
    let image = NSImage(size: NSSize(width: size, height: size), flipped: false) { rect in
        // macOS's icon grid: the shape inset to 824 of 1024.
        let inset = size * 100 / 1024
        let shape = NSBezierPath(roundedRect: rect.insetBy(dx: inset, dy: inset), xRadius: size * 185 / 1024, yRadius: size * 185 / 1024)
        NSGradient(colors: [NSColor(red: 0.16, green: 0.36, blue: 0.95, alpha: 1), NSColor(red: 0.22, green: 0.12, blue: 0.62, alpha: 1)])?
            .draw(in: shape, angle: -90)
        let configuration = NSImage.SymbolConfiguration(pointSize: size * 0.40, weight: .semibold)
            .applying(NSImage.SymbolConfiguration(paletteColors: [.white]))
        if let symbol = NSImage(systemSymbolName: "square.stack.3d.up.fill", accessibilityDescription: nil)?
            .withSymbolConfiguration(configuration) {
            let s = symbol.size
            symbol.draw(in: NSRect(x: (size - s.width) / 2, y: (size - s.height) / 2, width: s.width, height: s.height))
        }
        return true
    }
    let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels, bitsPerSample: 8,
                                  samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                  bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
    image.draw(in: NSRect(x: 0, y: 0, width: size, height: size))
    NSGraphicsContext.restoreGraphicsState()
    return bitmap.representation(using: .png, properties: [:])!
}

for points in [16, 32, 128, 256, 512] {
    try draw(points).write(to: URL(fileURLWithPath: "\(out)/icon_\(points)x\(points).png"))
    try draw(points * 2).write(to: URL(fileURLWithPath: "\(out)/icon_\(points)x\(points)@2x.png"))
}
