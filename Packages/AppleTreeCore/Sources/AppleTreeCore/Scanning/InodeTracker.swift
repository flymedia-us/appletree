import os

/// Identifies a file uniquely for hardlink/APFS-clone dedup purposes. Inode
/// numbers are only unique per-device, so both are needed even though a scan
/// never crosses devices (`FTS_XDEV`) — defensive correctness costs nothing.
struct InodeKey: Hashable, Sendable {
    let device: Int32
    let inode: UInt64
}

/// Tracks which (device, inode) pairs have already been counted during a
/// scan, so hardlinked files and APFS clones sharing the same underlying data
/// aren't double-counted toward total size. Also used for directories — not
/// for hardlink dedup (APFS doesn't support directory hardlinks), but
/// because macOS composes the visible filesystem from multiple volumes
/// joined by firmlinks (e.g. `/Users` and `/System/Volumes/Data/Users` are
/// the same underlying directory reachable two ways); without this check a
/// whole-volume scan starting at `/` double-counts everything on the Data
/// volume.
///
/// Backed by `OSAllocatedUnfairLock`, not an actor: this is called from deep
/// inside the hot per-file traversal loop across many concurrent worker
/// tasks, and a plain uncontended-fast-path mutex is dramatically cheaper
/// there than an actor hop (which pulls in Swift concurrency's task
/// scheduling machinery for every call).
final class InodeTracker: @unchecked Sendable {
    private let lock = OSAllocatedUnfairLock(initialState: Set<InodeKey>())

    /// Returns `true` if this is the first time this (device, inode) pair has
    /// been seen (i.e. the caller should count it), `false` if it's a
    /// duplicate that should be skipped.
    func markSeenReturningIsFirst(device: Int32, inode: UInt64) -> Bool {
        lock.withLock { seen in
            seen.insert(InodeKey(device: device, inode: inode)).inserted
        }
    }
}
