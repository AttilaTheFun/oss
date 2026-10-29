// What a proof's screens are compared with (Baseline), for
// tools/ci/proof.sh, which builds this folder's two files with swiftc on
// the runner (the package's ProofBaseline is Baseline.swift alone, tested
// by Tests/ProofBaselineTests):
//
//   proof_baseline <event> <base ref> <ref name> <commit> [<tag>…]
//
// Prints three lines: the ref the proof names, the revision git resolves
// to its commit, and git fetch's arguments that bring it into a shallow
// checkout. Fails where there is none.
import Foundation

let arguments = Array(CommandLine.arguments.dropFirst())
guard arguments.count >= 4 else {
    FileHandle.standardError.write(Data("usage: proof_baseline <event> <base ref> <ref name> <commit> [<tag>…]\n".utf8))
    exit(2)
}
guard let baseline = Baseline.choose(event: arguments[0], baseRef: arguments[1], refName: arguments[2], commit: arguments[3],
                                     tags: Array(arguments.dropFirst(4))) else {
    FileHandle.standardError.write(Data("proof_baseline: nothing to compare \(arguments[0]) \(arguments[2]) with\n".utf8))
    exit(1)
}
print(baseline.ref)
print(baseline.revision)
print(baseline.fetch.joined(separator: " "))
