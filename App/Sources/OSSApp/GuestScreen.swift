import AppKit
import OSSServer
import SwiftUI

/// What a Linux or Windows VM's Screen window shows: the lease's machine
/// and its QEMU's VNC, on this Mac's loopback (no password there).
struct GuestScreenTarget: Codable, Hashable {
    var name: String
    var host = "127.0.0.1"
    var port: Int
}

/// A Linux or Windows VM's screen, live: QEMU's VNC drawn by OS Server's
/// own viewer (RFBSession), scaled to the window. Clicks, the wheel and keys
/// go to the guest while the window has focus.
struct GuestScreen: View {
    let target: GuestScreenTarget
    /// A VNC server's password (the proof's guest, through its lease's relay).
    var password = ""
    @State private var ended: String?

    var body: some View {
        ZStack {
            Color.black
            if let ended {
                ContentUnavailableView("\(target.name) isn't showing", systemImage: "display.trianglebadge.exclamationmark",
                                       description: Text(ended))
            } else {
                GuestScreenView(target: target, password: password, ended: { ended = $0 })
            }
        }
        .navigationTitle(target.name)
        .frame(minWidth: 640, minHeight: 400)
    }
}

struct GuestScreenView: NSViewRepresentable {
    let target: GuestScreenTarget
    let password: String
    let ended: @MainActor (String) -> Void

    func makeNSView(context: Context) -> RFBView {
        let view = RFBView()
        view.connect(to: target, password: password, ended: ended)
        return view
    }

    func updateNSView(_ view: RFBView, context: Context) {}

    static func dismantleNSView(_ view: RFBView, coordinator: ()) { view.disconnect() }
}

/// The framebuffer as the layer's contents (aspect-fit), and the guest's
/// pointer and keyboard from this view's events.
final class RFBView: NSView {
    private var session: RFBSession?
    private var buttons: UInt8 = 0
    private var modifiers: NSEvent.ModifierFlags = []
    /// Each key down's keysym, by key code: released as it was pressed
    /// (Shift may have gone up first).
    private var pressed: [UInt16: UInt32] = [:]

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.contentsGravity = .resizeAspect
        layer?.backgroundColor = NSColor.black.cgColor
        layer?.magnificationFilter = .linear
    }

    required init?(coder: NSCoder) { fatalError("not from a nib") }

    func connect(to target: GuestScreenTarget, password: String, ended: @escaping @MainActor (String) -> Void) {
        // Connecting waits on the guest's VNC: off the main thread.
        Task.detached { [weak self] in
            do {
                let session = try RFBSession(host: target.host, port: target.port, password: password, frame: { image in
                    DispatchQueue.main.async { self?.layer?.contents = image }
                }, ended: { why in
                    DispatchQueue.main.async { ended(why) }
                })
                await MainActor.run {
                    guard let self else { return session.close() }
                    self.session = session
                    session.start()
                }
            } catch {
                await MainActor.run { ended("\(error)") }
            }
        }
    }

    func disconnect() {
        session?.close()
        session = nil
    }

    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        window?.makeFirstResponder(self)
        window?.acceptsMouseMovedEvents = true
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseMoved, .activeInKeyWindow, .inVisibleRect], owner: self))
    }

    // MARK: Pointer

    /// A point in the view as the guest's pixel, through the aspect fit.
    private func guestPoint(_ event: NSEvent) -> (Int, Int)? {
        guard let session else { return nil }
        let size = session.size
        guard size.width > 0, size.height > 0, bounds.width > 0, bounds.height > 0 else { return nil }
        let scale = min(bounds.width / size.width, bounds.height / size.height)
        let shown = CGSize(width: size.width * scale, height: size.height * scale)
        let origin = CGPoint(x: (bounds.width - shown.width) / 2, y: (bounds.height - shown.height) / 2)
        let point = convert(event.locationInWindow, from: nil)
        let x = (point.x - origin.x) / scale
        let y = (bounds.height - point.y - origin.y) / scale
        return (Int(x.rounded(.down)), Int(y.rounded(.down)))
    }

    private func send(_ event: NSEvent, buttons: UInt8? = nil) {
        if let buttons { self.buttons = buttons }
        guard let (x, y) = guestPoint(event) else { return }
        session?.pointer(x: x, y: y, buttons: self.buttons)
    }

    override func mouseMoved(with event: NSEvent) { send(event) }
    override func mouseDragged(with event: NSEvent) { send(event) }
    override func rightMouseDragged(with event: NSEvent) { send(event) }
    override func otherMouseDragged(with event: NSEvent) { send(event) }
    override func mouseDown(with event: NSEvent) {
        // Control-click is the Mac's right click.
        send(event, buttons: buttons | (event.modifierFlags.contains(.control) ? 4 : 1))
    }
    override func mouseUp(with event: NSEvent) { send(event, buttons: buttons & ~5) }
    override func rightMouseDown(with event: NSEvent) { send(event, buttons: buttons | 4) }
    override func rightMouseUp(with event: NSEvent) { send(event, buttons: buttons & ~4) }
    override func otherMouseDown(with event: NSEvent) { send(event, buttons: buttons | 2) }
    override func otherMouseUp(with event: NSEvent) { send(event, buttons: buttons & ~2) }

    /// A wheel's turn is a press and release of button 4 (up) or 5 (down).
    override func scrollWheel(with event: NSEvent) {
        guard let (x, y) = guestPoint(event), event.scrollingDeltaY != 0 else { return }
        let notch: UInt8 = event.scrollingDeltaY > 0 ? 8 : 16
        let turns = event.hasPreciseScrollingDeltas ? max(1, Int(abs(event.scrollingDeltaY) / 12)) : max(1, Int(abs(event.scrollingDeltaY)))
        for _ in 0..<min(turns, 10) {
            session?.pointer(x: x, y: y, buttons: buttons | notch)
            session?.pointer(x: x, y: y, buttons: buttons)
        }
    }

    // MARK: Keyboard

    /// The Mac's keys that aren't characters, by key code.
    private static let named: [UInt16: UInt32] = [
        36: 0xFF0D, 76: 0xFF0D, 48: 0xFF09, 53: 0xFF1B, 51: 0xFF08, 117: 0xFFFF,
        123: 0xFF51, 126: 0xFF52, 124: 0xFF53, 125: 0xFF54, 116: 0xFF55, 121: 0xFF56, 115: 0xFF50, 119: 0xFF57,
        122: 0xFFBE, 120: 0xFFBF, 99: 0xFFC0, 118: 0xFFC1, 96: 0xFFC2, 97: 0xFFC3,
        98: 0xFFC4, 100: 0xFFC5, 101: 0xFFC6, 109: 0xFFC7, 103: 0xFFC8, 111: 0xFFC9,
    ]

    private func keysym(_ event: NSEvent) -> UInt32? {
        if let named = Self.named[event.keyCode] { return named }
        // The character the key makes with Shift (not Option's or Control's).
        guard let character = event.charactersIgnoringModifiers?.first else { return nil }
        return RFBSession.keysym(for: character)
    }

    override func keyDown(with event: NSEvent) {
        guard let sym = pressed[event.keyCode] ?? keysym(event) else { return }
        pressed[event.keyCode] = sym
        session?.key(sym, down: true)
    }

    override func keyUp(with event: NSEvent) {
        guard let sym = pressed.removeValue(forKey: event.keyCode) else { return }
        session?.key(sym, down: false)
    }

    /// Shift, Control, Option and Command (the guest's Super: the Windows key).
    override func flagsChanged(with event: NSEvent) {
        let now = event.modifierFlags.intersection([.shift, .control, .option, .command])
        for (flag, sym) in [(NSEvent.ModifierFlags.shift, UInt32(0xFFE1)), (.control, 0xFFE3), (.option, 0xFFE9), (.command, 0xFFEB)]
        where now.contains(flag) != modifiers.contains(flag) {
            session?.key(sym, down: now.contains(flag))
        }
        modifiers = now
    }

    /// Command's shortcuts go to the guest, not the app's menus, while it has focus.
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard window?.firstResponder === self, event.modifierFlags.contains(.command) else { return false }
        // Command-W still closes the window.
        if event.charactersIgnoringModifiers == "w" { return false }
        keyDown(with: event)
        keyUp(with: event)
        return true
    }
}
