import AppKit
import CoreImage.CIFilterBuiltins
import OSSClient
import OSSServer
import SwiftUI

/// Settings › OS Monitor: the code that connects OS Monitor (on an iPhone,
/// an iPad, another Mac) to this server, as a QR code and to copy. It
/// carries this Mac's addresses and the monitor token, which reads what the
/// server is doing and nothing else. A new code makes a new token: every
/// Monitor given the old one stops until it's given this one.
struct MonitorSection: View {
    @State private var connection = MonitorAccess.connection()
    @State private var copied = false
    @State private var confirmingNew = false

    var body: some View {
        Section {
            HStack(alignment: .top, spacing: 16) {
                if let image = Self.qrCode(connection.link.absoluteString) {
                    Image(nsImage: image).interpolation(.none).resizable().frame(width: 132, height: 132)
                }
                VStack(alignment: .leading, spacing: 8) {
                    Text("Scan it with an iPhone's or iPad's camera (it opens OS Monitor), or copy the code and paste it into OS Monitor's Add Server.")
                        .font(.callout)
                    Text(connection.servers.compactMap(\.host).joined(separator: ", "))
                        .font(.caption.monospaced()).foregroundStyle(.secondary)
                    HStack {
                        Button(copied ? "Copied" : "Copy Code") {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(connection.link.absoluteString, forType: .string)
                            copied = true
                        }
                        Button("New Code…") { confirmingNew = true }
                    }
                }
            }
        } header: {
            Text("OS Monitor")
        } footer: {
            Text("The code reads what this server is doing (its machines, CPU, memory and disk) and can do nothing else.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .confirmationDialog("Make a new code?", isPresented: $confirmingNew) {
            Button("New Code", role: .destructive) {
                connection = MonitorAccess.connection(newToken: true)
                copied = false
            }
        } message: {
            Text("Every OS Monitor given the current code stops reading this server until it's given the new one.")
        }
    }

    static func qrCode(_ text: String) -> NSImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(text.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage else { return nil }
        let scaled = output.transformed(by: CGAffineTransform(scaleX: 8, y: 8))
        let representation = NSCIImageRep(ciImage: scaled)
        let image = NSImage(size: representation.size)
        image.addRepresentation(representation)
        return image
    }
}
