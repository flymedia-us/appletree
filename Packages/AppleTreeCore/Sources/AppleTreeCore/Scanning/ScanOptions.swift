import Foundation

/// Options for a single scan. Traversal always stays on one device
/// (`FTS_XDEV`) and never follows symlinks (`FTS_PHYSICAL`) — these are not
/// configurable, they're correctness requirements for a disk-usage scan.
public struct ScanOptions: Sendable {
    /// Caps the number of concurrent subdirectory-scanning tasks. `nil` uses
    /// the default derived from `ProcessInfo.processInfo.activeProcessorCount`.
    public var maxConcurrentWorkers: Int?

    /// How often (in files scanned) to emit a `.progress` event at minimum.
    /// The scanner also throttles by wall-clock time; this is a secondary cap
    /// so a scan of very few, very large files still reports progress.
    public var progressFileInterval: Int

    public init(maxConcurrentWorkers: Int? = nil, progressFileInterval: Int = 2000) {
        self.maxConcurrentWorkers = maxConcurrentWorkers
        self.progressFileInterval = progressFileInterval
    }
}
