import CoreServices
import Foundation
import os

/// Watches a previously-scanned root for filesystem changes made outside the
/// app (Finder, Terminal, another process) so paths that vanish after the
/// scan completed can be flagged in the UI without requiring a full rescan.
///
/// Built on `FSEventStream` with `kFSEventStreamCreateFlagFileEvents`, which
/// (since macOS 10.13) reports individual file-level paths rather than just
/// "something changed in this directory" — precise enough to resolve
/// straight to a `FileNode` via `descendant(atPath:)` without diffing a
/// directory listing ourselves.
///
/// Deliberately does *not* trust the event's "what happened" flag bits
/// (`.itemRemoved` vs. `.itemRenamed` vs. ...) to decide what happened:
/// FSEvents can coalesce or, after a buffer overflow, drop individual events
/// entirely. The only thing worth trusting is a fresh `lstat` of the reported
/// path at the moment the callback fires — self-correcting regardless of
/// exactly which events did or didn't make it through.
///
/// The one class of flag it *does* read is the "I couldn't describe this
/// precisely" family — `MustScanSubDirs`, `RootChanged` — which isn't a claim
/// about a path so much as an instruction to go and look. Those surface as
/// `PathChange.needsSubtreeRescan`.
///
/// None of that makes the stream complete, and callers must not assume it is:
/// events have been measured going missing with no flag set at all. See
/// `SubtreeResync`, which is what actually reconciles the tree with disk.
private let log = Logger(subsystem: "com.FlyMedia.AppleTree", category: "ExternalChangeWatcher")

public final class ExternalChangeWatcher: @unchecked Sendable {
    public struct PathChange: Sendable {
        public let path: String
        public let stillExists: Bool
        /// FSEvents told us it couldn't describe this path's subtree
        /// precisely — it coalesced events, or the kernel/user event queue
        /// overflowed and events were discarded
        /// (`kFSEventStreamEventFlagMustScanSubDirs`, and the root-moved case
        /// `kFSEventStreamEventFlagRootChanged`). The documented contract is
        /// that the client must go and look for itself, which is what
        /// `SubtreeResync` is for.
        ///
        /// Worth knowing: this being `false` is *not* a promise that the
        /// batch is complete. See `SubtreeResync`'s doc comment for measured
        /// cases of events going missing with no flag set at all — which is
        /// why the app reconciles after every burst rather than only when
        /// this is set.
        public internal(set) var needsSubtreeRescan: Bool
    }

    /// `handleEvents` runs on `watchQueue` (an FSEventStream callback,
    /// scheduled there via `FSEventStreamSetDispatchQueue`) while `stop()`
    /// is expected to be called from whatever actor owns this watcher (the
    /// main actor, in practice) — two different threads touching the same
    /// mutable state, the exact shape of bug this fixes elsewhere in the
    /// scanner (see `FileNode.children`'s doc comment). A lock is cheap
    /// insurance since neither side is hot (one stat-batch per FSEvents
    /// callback, one stop per scan).
    /// `FSEventStreamRef` (an `OpaquePointer`) has no `Sendable` conformance
    /// at all — this box exists purely so it can be stored in `State` and
    /// cross the lock's closure boundary without the compiler rejecting the
    /// capture outright. Safety comes from the lock, not this wrapper.
    private struct StreamBox: @unchecked Sendable {
        let ref: FSEventStreamRef
    }

    private struct State: @unchecked Sendable {
        var stream: StreamBox?
        var continuation: AsyncStream<[PathChange]>.Continuation?
    }

    private let watchQueue = DispatchQueue(label: "com.FlyMedia.AppleTree.ExternalChangeWatcher")
    private let state: OSAllocatedUnfairLock<State>

    /// Starts watching `root` immediately and returns a stream of change
    /// batches alongside the watcher controlling it. Call `stop()` (or drop
    /// every reference and let `deinit` do it) once the caller no longer
    /// needs live updates — e.g. because a new scan is about to replace the
    /// tree this watcher's paths resolve against.
    public static func watch(root: URL) -> (AsyncStream<[PathChange]>, ExternalChangeWatcher) {
        var continuation: AsyncStream<[PathChange]>.Continuation!
        // Bounded rather than the default `.unbounded`: this watcher runs
        // continuously for as long as the app has a scanned tree open, so an
        // consumer that ever stalls (a long synchronous UI recompute, a
        // debugger pause) while the watched root keeps seeing ordinary
        // filesystem churn would otherwise queue every FSEvents batch
        // forever, growing memory without bound. `.bufferingNewest` keeps
        // the consumer on the freshest available state once it catches up
        // rather than replaying a long-stale backlog — each `PathChange`
        // already carries a `stillExists` snapshot taken at callback time
        // (see this type's own doc comment), so a newer batch for the same
        // path is strictly more current than an older, dropped one.
        let stream = AsyncStream<[PathChange]>(bufferingPolicy: .bufferingNewest(256)) { continuation = $0 }
        let watcher = ExternalChangeWatcher(root: root, continuation: continuation)
        return (stream, watcher)
    }

    private init(root: URL, continuation: AsyncStream<[PathChange]>.Continuation) {
        state = OSAllocatedUnfairLock(initialState: State(stream: nil, continuation: continuation))
        start(root: root)
    }

    deinit {
        stop()
    }

    private func start(root: URL) {
        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil,
            release: nil,
            copyDescription: nil
        )

        let callback: FSEventStreamCallback = { _, clientCallBackInfo, numEvents, eventPaths, eventFlags, _ in
            guard let clientCallBackInfo else { return }
            let watcher = Unmanaged<ExternalChangeWatcher>.fromOpaque(clientCallBackInfo).takeUnretainedValue()
            watcher.handleEvents(numEvents: numEvents, eventPaths: eventPaths, eventFlags: eventFlags)
        }

        guard let stream = FSEventStreamCreate(
            kCFAllocatorDefault,
            callback,
            &context,
            [root.path] as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            0.35, // latency: coalesces a burst (e.g. deleting a whole folder) into one batch
            FSEventStreamCreateFlags(
                kFSEventStreamCreateFlagUseCFTypes | kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagNoDefer
            )
        ) else {
            // The post-scan live watch simply won't run — externally deleted
            // paths won't be flagged until the next scan. Not fatal, but
            // silent-until-now: log it so a "changes aren't reflected" report
            // is diagnosable. `root.path` is the user's own selected path
            // (public-facing by nature), so it's safe to log unredacted.
            log.error("FSEventStreamCreate failed for \(root.path, privacy: .public); external-change watch disabled")
            return
        }

        let box = StreamBox(ref: stream)
        state.withLock { $0.stream = box }
        FSEventStreamSetDispatchQueue(stream, watchQueue)
        FSEventStreamStart(stream)
    }

    /// Runs on `watchQueue` — off the main actor, since it does one `stat`
    /// per changed path.
    private func handleEvents(
        numEvents: Int,
        eventPaths: UnsafeMutableRawPointer,
        eventFlags: UnsafePointer<FSEventStreamEventFlags>
    ) {
        guard let paths = unsafeBitCast(eventPaths, to: NSArray.self) as? [String] else { return }
        // `numEvents` is FSEvents' own count for all three parallel arrays;
        // clamping to what the bridged path array actually produced keeps a
        // disagreement between them from reading past the flags buffer.
        let flags = UnsafeBufferPointer(start: eventFlags, count: min(numEvents, paths.count))

        // One existence check per *distinct* path. FSEvents routinely reports
        // the same path several times in a single callback (a write, a rename
        // and an attribute change on one file all coalesce into the same
        // batch), and a bulk delete makes a batch thousands of paths long —
        // deduplicating here saves both the syscalls and the downstream
        // per-path work, and the answer for a repeated path is identical
        // anyway since every one of them would be checked at the same moment.
        // Flags, though, are OR-ed across the duplicates rather than taken
        // from whichever copy happened to come first: a rescan demand on any
        // one of them is a rescan demand for the path.
        var indexByPath = [String: Int](minimumCapacity: paths.count)
        var changes: [PathChange] = []
        changes.reserveCapacity(paths.count)

        for (offset, path) in paths.enumerated() {
            let rescan = offset < flags.count && Self.demandsSubtreeRescan(flags[offset])
            if let existing = indexByPath[path] {
                if rescan { changes[existing].needsSubtreeRescan = true }
                continue
            }
            indexByPath[path] = changes.count
            changes.append(PathChange(
                path: path,
                stillExists: FileSystemProbe.exists(atPath: path),
                needsSubtreeRescan: rescan
            ))
        }

        guard !changes.isEmpty else { return }
        state.withLock { $0.continuation }?.yield(changes)
    }

    /// Whether FSEvents is telling us this path's subtree has to be inspected
    /// directly rather than trusted to the event stream. `MustScanSubDirs` is
    /// the coalesced/dropped case (the `UserDropped`/`KernelDropped` bits
    /// accompany it to say *where* it overflowed, which changes nothing about
    /// the response). `RootChanged` means the watched root itself was moved
    /// or replaced, so nothing below it can be taken on trust either.
    private static func demandsSubtreeRescan(_ flags: FSEventStreamEventFlags) -> Bool {
        let demanding = FSEventStreamEventFlags(
            kFSEventStreamEventFlagMustScanSubDirs | kFSEventStreamEventFlagRootChanged
        )
        return flags & demanding != 0
    }

    public func stop() {
        let (box, continuation) = state.withLock { state -> (StreamBox?, AsyncStream<[PathChange]>.Continuation?) in
            defer {
                state.stream = nil
                state.continuation = nil
            }
            return (state.stream, state.continuation)
        }
        guard let box else { return }
        FSEventStreamStop(box.ref)
        FSEventStreamInvalidate(box.ref)
        FSEventStreamRelease(box.ref)
        continuation?.finish()
    }
}
