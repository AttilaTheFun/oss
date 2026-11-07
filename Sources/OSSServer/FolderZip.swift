import Foundation
import OSSClient

/// A folder (an .app or .xctest bundle) zipped with its folder at the
/// archive's top, as rules_apple's zips hold one: ditto on a Mac, Info-ZIP's
/// zip elsewhere (a Linux client, CI's runners), symlinks kept as links.
enum FolderZip {
    static func make(_ folder: String, to zip: String, timeout: TimeInterval) async throws {
        let result: ProcessResult
        #if os(macOS)
        result = try await Shell.run("/usr/bin/ditto", ["-c", "-k", "--keepParent", folder, zip], timeout: timeout)
        #else
        let url = URL(fileURLWithPath: folder).standardizedFileURL
        let parent = url.deletingLastPathComponent().path, name = url.lastPathComponent
        result = try await Shell.run("/bin/sh", ["-c", "cd \"$1\" && exec zip -qry \"$2\" \"$3\"", "sh", parent, zip, name],
                                     timeout: timeout)
        #endif
        guard result.ok else { throw OSSError(status: 0, message: "zipping \(folder): \(result.error)") }
    }
}
