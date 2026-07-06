import CoreServices
import Foundation
import os

/// Wraps FSEvents' historical-replay mode to answer "what changed under this
/// path since event ID X" without re-walking the whole tree.
///
/// Empirically verified (see `docs/wiztree-research.md` and the scratch spike
/// this was built from) rather than assumed from the header docs alone:
/// - `kFSEventStreamEventFlagHistoryDone` reliably fires even when nothing
///   changed, as long as `sinceWhen` is a real past event ID (never
///   `kFSEventStreamEventIdSinceNow`) — this is what lets `changesSince`
///   resolve deterministically instead of guessing a timeout.
/// - There is no `kFSEventStreamCreateFlagUseHistory` flag — historical
///   replay is simply what happens when `sinceWhen` isn't "since now".
/// - With `kFSEventStreamCreateFlagFileEvents`, a *settled* history (the
///   underlying fsevents log has had a little time to flush) reports
///   precise per-file paths. A history queried too soon after the triggering
///   change can instead report only a directory-level path — so callers must
///   treat every reported path as "recheck this, and if it's a directory,
///   also reconcile its children" rather than trusting path-level precision.
///   `DirectoryScanner`'s delta-merge does exactly that.
public enum FSEventsDelta {
    public enum Result: Sendable {
        case changed(paths: Set<String>, newCursor: UInt64)
        /// History unavailable (log rolled over), or a coarse-invalidation
        /// flag fired (dropped events, must-rescan, root changed). Callers
        /// must fall back to a full walk.
        case invalidated
    }

    /// Stable per-volume identifier tied to FSEvents' own event numbering —
    /// the API FSEvents itself recommends for pairing a saved cursor with the
    /// specific volume it came from, so a reformatted/swapped external drive
    /// at the same mount point is never misread against stale event IDs.
    public static func volumeUUID(forPath path: String) -> String? {
        var st = stat()
        guard lstat(path, &st) == 0 else { return nil }
        guard let uuid = FSEventsCopyUUIDForDevice(st.st_dev) else { return nil }
        return CFUUIDCreateString(nil, uuid) as String?
    }

    public static func currentEventId() -> UInt64 {
        FSEventsGetCurrentEventId()
    }

    /// Replays history for `rootPath` since `eventId` and resolves once the
    /// OS signals replay is complete (or, defensively, after `timeout` if it
    /// never does — this should not happen given the verified behavior
    /// above, but a hung stream must never hang a scan).
    public static func changesSince(eventId: UInt64, rootPath: String, timeout: Duration = .seconds(10)) async -> Result {
        await withCheckedContinuation { continuation in
            // Seeded with the requested cursor, not 0: when nothing changed,
            // no per-event id ever updates `latestEventId`, and the saved
            // snapshot must still advance to (at least) what was asked for —
            // reporting back 0 would make the *next* scan replay the entire
            // historical log, which is certain to be long gone.
            let box = Box(continuation: continuation, initialEventId: eventId)
            let unmanagedBox = Unmanaged.passRetained(box)

            var context = FSEventStreamContext(
                version: 0,
                info: unmanagedBox.toOpaque(),
                retain: nil,
                release: nil,
                copyDescription: nil
            )

            guard let stream = FSEventStreamCreate(
                kCFAllocatorDefault,
                fsEventsDeltaCallback,
                &context,
                [rootPath] as CFArray,
                FSEventStreamEventId(eventId),
                0,
                UInt32(kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagNoDefer)
            ) else {
                unmanagedBox.release()
                continuation.resume(returning: .invalidated)
                return
            }

            box.stream = stream
            let queue = DispatchQueue(label: "com.appletree.fsevents-delta")
            FSEventStreamSetDispatchQueue(stream, queue)
            guard FSEventStreamStart(stream) else {
                FSEventStreamInvalidate(stream)
                FSEventStreamRelease(stream)
                unmanagedBox.release()
                continuation.resume(returning: .invalidated)
                return
            }

            queue.asyncAfter(deadline: .now() + timeout.timeInterval) {
                guard box.finish() else { return }
                unmanagedBox.release()
            }
        }
    }

    /// Bridges the C callback (which cannot capture Swift state) to the
    /// async caller via a retained `Box` passed through `info`. Holds the
    /// stream itself (rather than passing it around as a closure capture) so
    /// every access to shared, mutable state goes through `lock` and the
    /// type can honestly claim `@unchecked Sendable` — the same pattern
    /// `InodeTracker`/`WorkerSlotPool` use for their hot-path locks.
    final class Box: @unchecked Sendable {
        private let lock = OSAllocatedUnfairLock<Void>()
        private var changedPaths = Set<String>()
        private var invalidated = false
        private var latestEventId: UInt64
        private var resumed = false
        private let continuation: CheckedContinuation<Result, Never>
        fileprivate var stream: FSEventStreamRef?

        init(continuation: CheckedContinuation<Result, Never>, initialEventId: UInt64) {
            self.continuation = continuation
            self.latestEventId = initialEventId
        }

        func record(paths: [String], flags: [UInt32], eventIds: [UInt64]) -> Bool {
            lock.lock()
            defer { lock.unlock() }
            var sawHistoryDone = false
            for i in 0..<paths.count {
                let flag = flags[i]
                if flag & UInt32(kFSEventStreamEventFlagHistoryDone) != 0 {
                    sawHistoryDone = true
                    continue
                }
                if flag & UInt32(kFSEventStreamEventFlagMustScanSubDirs) != 0
                    || flag & UInt32(kFSEventStreamEventFlagRootChanged) != 0
                    || flag & UInt32(kFSEventStreamEventFlagKernelDropped) != 0
                    || flag & UInt32(kFSEventStreamEventFlagUserDropped) != 0 {
                    invalidated = true
                }
                changedPaths.insert(paths[i])
                latestEventId = max(latestEventId, eventIds[i])
            }
            return sawHistoryDone
        }

        /// Resolves the continuation exactly once, whether triggered by
        /// `kFSEventStreamEventFlagHistoryDone` or the defensive timeout.
        /// Returns `true` if this call is the one that actually finished
        /// (so the caller knows whether it, uniquely, owns releasing the
        /// `Unmanaged` box reference).
        @discardableResult
        func finish() -> Bool {
            lock.lock()
            guard !resumed, let stream else {
                lock.unlock()
                return false
            }
            resumed = true
            let paths = changedPaths
            let invalid = invalidated
            let cursor = latestEventId
            lock.unlock()

            FSEventStreamStop(stream)
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
            continuation.resume(returning: invalid ? .invalidated : .changed(paths: paths, newCursor: cursor))
            return true
        }
    }
}

private func fsEventsDeltaCallback(
    streamRef: ConstFSEventStreamRef,
    clientCallBackInfo: UnsafeMutableRawPointer?,
    numEvents: Int,
    eventPaths: UnsafeMutableRawPointer,
    eventFlags: UnsafePointer<FSEventStreamEventFlags>,
    eventIds: UnsafePointer<FSEventStreamEventId>
) {
    guard let clientCallBackInfo else { return }
    let box = Unmanaged<FSEventsDelta.Box>.fromOpaque(clientCallBackInfo).takeUnretainedValue()

    let cPaths = eventPaths.assumingMemoryBound(to: UnsafeMutablePointer<CChar>.self)
    var paths: [String] = []
    var flags: [UInt32] = []
    var ids: [UInt64] = []
    paths.reserveCapacity(numEvents)
    flags.reserveCapacity(numEvents)
    ids.reserveCapacity(numEvents)
    for i in 0..<numEvents {
        paths.append(String(cString: cPaths[i]))
        flags.append(eventFlags[i])
        ids.append(eventIds[i])
    }

    let historyDone = box.record(paths: paths, flags: flags, eventIds: ids)
    if historyDone {
        if box.finish() {
            Unmanaged<FSEventsDelta.Box>.fromOpaque(clientCallBackInfo).release()
        }
    }
}

private extension Duration {
    var timeInterval: TimeInterval {
        Double(components.seconds) + Double(components.attoseconds) / 1e18
    }
}
