import Foundation

/// Options for a single scan. Traversal always stays on one device
/// (`FTS_XDEV`) and never follows symlinks (`FTS_PHYSICAL`) — these are not
/// configurable, they're correctness requirements for a disk-usage scan.
public struct ScanOptions: Sendable {
    /// Caps the number of concurrent subdirectory-scanning tasks. `nil` uses
    /// the default derived from `ProcessInfo.processInfo.activeProcessorCount`,
    /// itself capped at 16 — past that, more workers compete for scheduler
    /// time and file descriptors without measurably increasing throughput,
    /// since the workload is I/O-bound and SSD/NVMe queue depth saturates
    /// well before 16 concurrent `fts` sessions on real hardware. This
    /// matters more as core counts grow (a 24-core Mac Studio would
    /// otherwise default to 48 concurrent `fts_open` sessions for no
    /// measured benefit).
    public var maxConcurrentWorkers: Int?

    /// How often (in files scanned) to emit a `.progress` event at minimum.
    /// The scanner also throttles by wall-clock time; this is a secondary cap
    /// so a scan of very few, very large files still reports progress.
    public var progressFileInterval: Int

    /// When `true`, worker threads mark their own disk I/O as throttleable
    /// (`setiopolicy_np(IOPOL_TYPE_DISK, IOPOL_SCOPE_THREAD, IOPOL_THROTTLE)`)
    /// so the kernel's I/O scheduler backs this scan off under contention
    /// from foreground disk activity — the same mechanism Spotlight/Time
    /// Machine use for bulk background I/O. Defaults to `false`: a scan the
    /// user explicitly started and is watching a progress bar for should run
    /// at normal priority, not be artificially slowed down to protect other
    /// apps. Intended for a future non-interactive/background rescan use
    /// case, not today's default interactive scan.
    public var ioThrottled: Bool

    public init(maxConcurrentWorkers: Int? = nil, progressFileInterval: Int = 2000, ioThrottled: Bool = false) {
        self.maxConcurrentWorkers = maxConcurrentWorkers
        self.progressFileInterval = progressFileInterval
        self.ioThrottled = ioThrottled
    }
}
