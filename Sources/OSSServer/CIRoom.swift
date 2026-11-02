import OSSClient

/// Whether a CI runner's container may start now. A runner that builds holds
/// its container (16 GB, say) while its job waits for the machines it leases
/// (a 16 GB macOS VM): four such runners started at once took the memory
/// their own jobs' VMs needed, and none could finish (2026-11-02). So a
/// runner starts only when nothing waits ahead of it (a job's machine
/// first: no stall escape for a runner) and the memory left beside it still
/// holds one macOS VM, so at least one job can always get its VM, end, and
/// give back both.
enum CIRoom {
    /// Why a runner of `runner` bytes waits, or nil if it may start.
    /// `headroom`: what a macOS VM takes (0 where the server lends none).
    ///
    /// `atCap`: the types whose cap is reached (macOS's two): a lease of one
    /// waits for one of them to be released, whose memory it then takes, so a
    /// runner doesn't hold it back, and no room is kept for one (the caller
    /// passes no headroom when macOS is at its cap).
    static func refusal(runner: Int64, budget: LeaseBudget, headroom: Int64, atCap: Set<Platform> = []) -> String? {
        if let first = budget.waiting.first(where: { !atCap.contains($0.platform) }) {
            return "a lease waits ahead (\(first.holder)'s \(first.platform.rawValue), since \(first.since.formatted(.iso8601)))"
        }
        let free = budget.memoryBytes - budget.leasedMemoryBytes - budget.outsideMemoryBytes
        guard free - runner >= headroom else {
            return "keeping room for a macOS VM its jobs may lease: \(gigabytes(free)) GB free, a runner takes \(gigabytes(runner)) GB and a VM \(gigabytes(headroom)) GB"
        }
        return nil
    }

    private static func gigabytes(_ bytes: Int64) -> String {
        String(format: "%.1f", Double(max(0, bytes)) / Double(1 << 30))
    }
}
