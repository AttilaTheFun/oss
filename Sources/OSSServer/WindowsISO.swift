import Foundation
import OSSClient

#if os(macOS)
/// Windows 11 on Arm's ISO, fetched from Microsoft for the Windows
/// component, as Microsoft's download page fetches it (no account, no key):
/// the page names the edition and lists each language's SHA-256; a session
/// is opened with the page's fraud check (ov-df's script, then the frame it
/// loads); the connector API gives the edition's languages and then a link,
/// good for a day. The ISO is kept in `Machines/images` and checked against
/// the page's hash; one kept there that matches it is used without a link. Microsoft refuses some requests ("Sentinel"): a fresh
/// session is tried twice more, then the component says to install from a
/// file instead.
enum WindowsISO {
    static let page = URL(string: "https://www.microsoft.com/en-us/software-download/windows11arm64")!
    static let connector = "https://www.microsoft.com/software-download-connector/api"
    /// The page's own settings (its script's): the connector's profile and
    /// the fraud check's instance.
    static let profile = "606624d44113"
    static let instance = "560dc9f3-1aa5-4a2f-b63c-9e18f8d0e175"
    static let language = "English"

    /// The ISO, downloaded once (or found already whole) and checked.
    static func download() async throws -> URL {
        let html = try await text(page)
        guard let edition = first(#"<option[^>]*value="(\d+)"[^>]*>\s*Windows 11[^<]*Arm64"#, in: html) else {
            throw ShellError(description: "Microsoft's page names no Windows 11 on Arm edition")
        }
        // The page's table: "English 64-bit <hash>", one row a language.
        let table = html.replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression)
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
        guard let expected = first(#"(?:^| )\#(language) 64-bit ([0-9A-Fa-f]{64})"#, in: table)?.lowercased() else {
            throw ShellError(description: "Microsoft's page lists no SHA-256 for \(language)")
        }
        // One downloaded before (or put there) that is the page's: no link asked for.
        let directory = "\(Paths.machines)/images"
        Paths.ensure(directory)
        for name in (try? FileManager.default.contentsOfDirectory(atPath: directory)) ?? []
        where name.hasPrefix("Windows11_") && name.hasSuffix(".iso") {
            let kept = URL(fileURLWithPath: directory).appendingPathComponent(name)
            if try await LinuxInstaller.sha256(kept) == expected { return kept }
        }
        var refusal = ""
        for attempt in 1...3 {
            if attempt > 1 { try await Task.sleep(for: .seconds(10 * attempt)) }
            let link: Link
            do {
                link = try await self.link(edition: edition)
            } catch let error as Refused {
                refusal = error.message
                log("Microsoft refused the download (try \(attempt) of 3): \(refusal)")
                continue
            }
            let destination = URL(fileURLWithPath: directory).appendingPathComponent(link.uri.lastPathComponent)
            log("downloading \(link.name) from Microsoft")
            try await Downloads.fetch(link.uri, to: destination, what: link.name)
            guard try await LinuxInstaller.sha256(destination) == expected else {
                try? FileManager.default.removeItem(at: destination)
                throw ShellError(description: "\(destination.lastPathComponent) isn't what Microsoft's page says (SHA-256)")
            }
            return destination
        }
        throw ShellError(description: "Microsoft refused the download (\(refusal)): download Windows 11 on Arm's ISO from \(page.absoluteString) and install from the file")
    }

    struct Link { var name: String; var uri: URL }
    struct Refused: Error { var message: String }

    /// A day's link to the edition's ISO in `language`, in a session of its own.
    static func link(edition: String) async throws -> Link {
        let session = UUID().uuidString.lowercased()
        // The fraud check, as the page runs it: its script names a frame to load.
        let script = try await text(URL(string: "https://ov-df.microsoft.com/mdt.js?instanceId=\(instance)&pageId=si&session_id=\(session)")!)
        if let frame = first(#"url:"(https://ov-df\.microsoft\.com/\?[^"]+)""#, in: script),
           let ticks = first(#"rticks="\+(\d+)"#, in: script) {
            _ = try await text(URL(string: "\(frame)&mdt=\(Int(Date().timeIntervalSince1970 * 1000))&rticks=\(ticks)")!)
        }
        struct Skus: Decodable { var Skus: [Sku]?; var Errors: [Problem]? }
        struct Sku: Decodable { var Id: String; var Language: String }
        struct Links: Decodable { var ProductDownloadOptions: [Option]?; var Errors: [Problem]? }
        struct Option: Decodable { var Name: String?; var Uri: String }
        struct Problem: Decodable { var Key: String?; var Value: String? }
        func query(_ action: String, edition: String, sku: String) -> URL {
            URL(string: "\(connector)/\(action)?profile=\(profile)&ProductEditionId=\(edition)&SKU=\(sku)"
                + "&friendlyFileName=undefined&Locale=en-US&sessionID=\(session)")!
        }
        let skus = try JSONDecoder().decode(Skus.self, from: try await data(query("getskuinformationbyproductedition", edition: edition, sku: "undefined")))
        if let problem = skus.Errors?.first { throw Refused(message: problem.Value ?? problem.Key ?? "refused") }
        guard let sku = skus.Skus?.first(where: { $0.Language == language }) else {
            throw ShellError(description: "Microsoft offers no \(language) Windows 11 on Arm")
        }
        let links = try JSONDecoder().decode(Links.self, from: try await data(query("GetProductDownloadLinksBySku", edition: "undefined", sku: sku.Id)))
        if let problem = links.Errors?.first { throw Refused(message: problem.Value ?? problem.Key ?? "refused") }
        guard let option = links.ProductDownloadOptions?.first, let uri = URL(string: option.Uri) else {
            throw ShellError(description: "Microsoft gave no link")
        }
        return Link(name: option.Name ?? uri.lastPathComponent, uri: uri)
    }

    /// A GET as the page's own: with the page as its referrer.
    private static func data(_ url: URL) async throws -> Data {
        var request = URLRequest(url: url)
        request.setValue(page.absoluteString, forHTTPHeaderField: "Referer")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let status = (response as? HTTPURLResponse)?.statusCode, status == 200 else {
            throw ShellError(description: "\(url.host ?? "Microsoft"): \((response as? HTTPURLResponse)?.statusCode ?? 0)")
        }
        return data
    }

    private static func text(_ url: URL) async throws -> String { String(decoding: try await data(url), as: UTF8.self) }

    private static func first(_ pattern: String, in text: String) -> String? {
        guard let expression = try? NSRegularExpression(pattern: pattern),
              let match = expression.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)), match.numberOfRanges > 1,
              let range = Range(match.range(at: match.numberOfRanges - 1), in: text) else { return nil }
        return String(text[range])
    }
}

/// Large downloads, their progress in the log (what a component's row
/// shows) every ten seconds.
enum Downloads {
    /// Fetched to a `.part` beside `destination`, moved there when whole.
    static func fetch(_ url: URL, to destination: URL, what: String) async throws {
        final class Box: @unchecked Sendable { var task: URLSessionDownloadTask? }
        let part = destination.appendingPathExtension("part")
        let box = Box()
        let watcher = Task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(10))
                guard let task = box.task, task.countOfBytesExpectedToReceive > 0 else { continue }
                let format = ByteCountFormatter()
                log("downloading \(what): \(format.string(fromByteCount: task.countOfBytesReceived)) of \(format.string(fromByteCount: task.countOfBytesExpectedToReceive))")
            }
        }
        defer { watcher.cancel() }
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                let task = URLSession.shared.downloadTask(with: url) { location, response, error in
                    // The file goes when this returns: moved first.
                    do {
                        if let error { throw error }
                        guard let location, (response as? HTTPURLResponse)?.statusCode == 200 else {
                            throw ShellError(description: "downloading \(what): \((response as? HTTPURLResponse)?.statusCode ?? 0)")
                        }
                        try? FileManager.default.removeItem(at: part)
                        try FileManager.default.moveItem(at: location, to: part)
                        continuation.resume()
                    } catch {
                        continuation.resume(throwing: error)
                    }
                }
                box.task = task
                task.resume()
            }
        } onCancel: {
            box.task?.cancel()
        }
        try? FileManager.default.removeItem(at: destination)
        try FileManager.default.moveItem(at: part, to: destination)
    }
}
#endif
