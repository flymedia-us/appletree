import Foundation
import os

/// Shared running totals for an in-progress scan (files/bytes scanned,
/// folders skipped) plus progress-emission throttling state.
///
/// Lock-based rather than actor-based: `addFile` is called once per file
/// across every concurrent worker task, which at hundreds of thousands of
/// files per scan makes it the hottest coordination point in the scanner.
/// An actor hop per call was measured to bottleneck the scan to roughly one
/// core's worth of throughput regardless of worker count (fixed by this
/// change — see M1 notes); a plain `OSAllocatedUnfairLock` has no task-
/// scheduling overhead and is cheap even in the uncontended-fast-path case.
final class ScanCounters: @unchecked Sendable {
    struct Snapshot: Sendable {
        let filesScanned: Int
        let bytesScanned: UInt64
        let foldersSkipped: Int
    }

    private struct State {
        var filesScanned = 0
        var bytesScanned: UInt64 = 0
        var foldersSkipped = 0
        var lastProgressEmit: ContinuousClock.Instant = .now
    }

    private let lock = OSAllocatedUnfairLock(initialState: State())
    private let progressInterval: Int

    init(progressFileInterval: Int) {
        self.progressInterval = max(1, progressFileInterval)
    }

    /// Records one newly-scanned file. Returns a snapshot to emit as a
    /// `.progress` event if the file-count or time threshold was just
    /// crossed, else `nil`.
    func addFile(bytes: UInt64) -> Snapshot? {
        lock.withLock { state in
            state.filesScanned += 1
            state.bytesScanned += bytes

            let now = ContinuousClock.now
            let dueByCount = state.filesScanned.isMultiple(of: progressInterval)
            let dueByTime = (now - state.lastProgressEmit) > .milliseconds(150)
            guard dueByCount || dueByTime else { return nil }

            state.lastProgressEmit = now
            return Snapshot(
                filesScanned: state.filesScanned,
                bytesScanned: state.bytesScanned,
                foldersSkipped: state.foldersSkipped
            )
        }
    }

    func addFolderSkipped() {
        lock.withLock { state in state.foldersSkipped += 1 }
    }

    func snapshot() -> Snapshot {
        lock.withLock { state in
            Snapshot(
                filesScanned: state.filesScanned,
                bytesScanned: state.bytesScanned,
                foldersSkipped: state.foldersSkipped
            )
        }
    }
}
