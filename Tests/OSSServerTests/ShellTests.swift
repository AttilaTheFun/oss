import Foundation
import Testing
@testable import OSSServer

// A program's output, whole and in order, however long: curl's answer of
// 32 KiB and more once came back with a chunk out of place (a pipe's
// readability handler appending after the read at its exit), which a JSON
// decoder took for corrupt data.

@Test func longOutputComesBackWholeAndInOrder() async throws {
    let expected = (1...200_000).map(String.init).joined(separator: "\n") + "\n"
    for _ in 0..<20 {
        let clock = ContinuousClock(), start = clock.now
        let result = try await Shell.run("/bin/sh", ["-c", "seq 1 200000; echo done >&2"])
        #expect(result.ok)
        #expect(result.output == expected)
        #expect(result.error == "done\n")
        // The pipes reach their ends with the program, not by the wait's limit.
        #expect(clock.now - start < .seconds(2))
    }
}
