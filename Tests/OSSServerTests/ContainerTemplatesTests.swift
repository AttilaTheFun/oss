import Foundation
import Testing
@testable import OSSServer

@Test func templatesUnusedForTheirDaysAndPartialOnesAreDeletedAndTheRestKept() throws {
    let folder = URL(fileURLWithPath: NSTemporaryDirectory() + "oss-templates-test-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    let now = Date()
    func make(_ name: String, usedHoursAgo hours: Double) throws {
        let url = folder.appendingPathComponent(name)
        try Data(repeating: 1, count: 4096).write(to: url)
        try FileManager.default.setAttributes([.modificationDate: now.addingTimeInterval(-hours * 3600)], ofItemAtPath: url.path)
    }
    try make("aaaa-64.ext4", usedHoursAgo: 1)
    try make("bbbb-64.ext4", usedHoursAgo: 47)
    try make("cccc-64.ext4", usedHoursAgo: 49)
    try make("dddd-128.ext4", usedHoursAgo: 24 * 20)
    try make("eeee-64.partial.ext4", usedHoursAgo: 0)

    let (files, bytes) = ContainerTemplates.prune(folder, unusedFor: 2 * 86400, now: now)
    #expect(files == ["cccc-64.ext4", "dddd-128.ext4", "eeee-64.partial.ext4"])
    #expect(bytes > 0)
    #expect(try FileManager.default.contentsOfDirectory(atPath: folder.path).sorted() == ["aaaa-64.ext4", "bbbb-64.ext4"])
    // Nothing left to delete: nothing done.
    #expect(ContainerTemplates.prune(folder, unusedFor: 2 * 86400, now: now).files.isEmpty)
}

@Test func containerTemplateDaysIsTwoUnlessServerJSONSays() throws {
    #expect(ServerConfig().containerTemplateDays == 2)
    let set = try JSONDecoder().decode(ServerConfig.self, from: Data(#"{"containerTemplateDays": 0.5}"#.utf8))
    #expect(set.containerTemplateDays == 0.5)
}
