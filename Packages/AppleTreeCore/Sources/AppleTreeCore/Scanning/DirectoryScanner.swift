import Darwin
import Foundation

/// Parallel, cancellable directory scanner.
///
/// Traversal uses BSD `fts()` (the fastest local-volume traversal primitive
/// per the project's own research — see `docs/wiztree-research.md`), one
/// `fts_open` session per worker. A single root-level `fts` walk descends
/// depth-first; whenever it encounters a subdirectory and a concurrency slot
/// is free, that subdirectory is handed off to a *new* worker `Task` (its own
/// `fts_open` rooted there) and the current walk is told to skip it
/// (`fts_set(..., FTS_SKIP)`) so it isn't scanned twice. Once the concurrency
/// cap is reached, further subdirectories are simply walked inline by the
/// existing `fts` session instead of spawning — this bounds task/file-
/// descriptor fan-out on deep or wide trees while still parallelizing the
/// common case (many sibling subdirectories) up to the cap.
///
/// Each worker's `fts_open` call blocks its `Task` on synchronous syscalls
/// for the duration of that subtree's traversal. This is intentional here —
/// the workload is I/O-bound, the number of concurrent workers is bounded by
/// `maxWorkers`, and Dispatch's global concurrent executor grows its thread
/// pool under sustained blocking rather than deadlocking.
///
/// Shared coordination state (worker-slot accounting, file/byte counters,
/// hardlink dedup) is deliberately *not* actor-isolated — it lives in
/// `WorkerSlotPool`/`ScanCounters`/`InodeTracker`, each backed by a plain
/// lock. An earlier version routed every one of these through this type's
/// own actor isolation; at ~900K files that serialized nearly all traversal
/// work onto a single actor and capped measured CPU utilization at roughly
/// one core regardless of worker count. Locks with no task-scheduling
/// overhead fixed it. `DirectoryScanner` itself stays an actor purely as the
/// entry point — nothing on its hot path touches actor-isolated state.
public actor DirectoryScanner {
    /// Test-only observability: whether the most recently *started* scan
    /// resolved via `attemptDeltaScan` rather than falling back to a full
    /// `fts` walk. Not part of the public API surface (no snapshot/event-
    /// count heuristic is otherwise reliable for a tiny fixture tree, where
    /// a full scan and a delta scan can emit an identical-looking event
    /// sequence) — tests need a direct way to assert which path actually ran.
    nonisolated(unsafe) static var lastScanTookDeltaPath = false

    public init() {}

    /// Starts a scan and returns immediately with a stream of `ScanEvent`s.
    /// Cancelling the `Task` consuming the stream cancels the underlying scan.
    public func scan(root: URL, options: ScanOptions = ScanOptions()) -> AsyncThrowingStream<ScanEvent, Error> {
        let defaultWorkers = min(ProcessInfo.processInfo.activeProcessorCount * 2, 16)
        let maxWorkers = max(1, options.maxConcurrentWorkers ?? defaultWorkers)
        let progressInterval = max(1, options.progressFileInterval)
        let ioThrottled = options.ioThrottled

        let (stream, continuation) = AsyncThrowingStream<ScanEvent, Error>.makeStream()
        let scanTask = Task.detached {
            await Self.runScan(
                root: root,
                slots: WorkerSlotPool(max: maxWorkers),
                counters: ScanCounters(progressFileInterval: progressInterval),
                inodeTracker: InodeTracker(),
                ioThrottled: ioThrottled,
                continuation: continuation
            )
        }
        continuation.onTermination = { _ in scanTask.cancel() }
        return stream
    }

    private static func runScan(
        root: URL,
        slots: WorkerSlotPool,
        counters: ScanCounters,
        inodeTracker: InodeTracker,
        ioThrottled: Bool,
        continuation: AsyncThrowingStream<ScanEvent, Error>.Continuation
    ) async {
        let start = ContinuousClock.now
        // Canonicalized (symlinks resolved, no trailing slash): FSEvents
        // always reports paths this way (e.g. `/var/...` is reported as the
        // real `/private/var/...`), so this exact string doubles as both the
        // `fts` root and the snapshot/delta-merge dictionary key — anything
        // less canonical here would silently desync the two the moment a
        // scanned root sits under a BSD alias like `/tmp` or `/var`.
        let path = canonicalPath(for: root.path(percentEncoded: false))

        lastScanTookDeltaPath = false
        if await attemptDeltaScan(rootPath: path, start: start, continuation: continuation) {
            return
        }

        var rootStat = stat()
        guard lstat(path, &rootStat) == 0 else {
            continuation.yield(.failed(POSIXError(POSIXErrorCode(rawValue: errno) ?? .ENOENT)))
            continuation.finish()
            return
        }

        let rootName = (path as NSString).lastPathComponent
        let isRootDirectory = (rootStat.st_mode & S_IFMT) == S_IFDIR

        let rootNode = FileNode(
            name: rootName.isEmpty ? path : rootName,
            isDirectory: isRootDirectory,
            logicalSize: isRootDirectory ? 0 : UInt64(rootStat.st_size),
            allocatedSize: isRootDirectory ? 0 : UInt64(rootStat.st_blocks) * 512,
            modificationDate: date(from: rootStat.st_mtimespec),
            rootPath: path
        )
        continuation.yield(.rootCreated(rootNode))

        if isRootDirectory {
            await scanDirectory(
                node: rootNode,
                path: path,
                slots: slots,
                counters: counters,
                inodeTracker: inodeTracker,
                ioThrottled: ioThrottled,
                continuation: continuation
            )
            rootNode.finalizeAsDirectory()
        }
        continuation.yield(.subtreeCompleted(parent: rootNode))

        // Save before signaling completion: a caller that finishes draining
        // the stream must be able to rely on the snapshot already being on
        // disk (e.g. to immediately rescan the same root) rather than racing
        // a background write that hasn't landed yet.
        saveSnapshot(rootPath: path, rootNode: rootNode)

        let elapsed = ContinuousClock.now - start
        let final = counters.snapshot()
        continuation.yield(.finished(duration: elapsed, filesScanned: final.filesScanned, foldersSkipped: final.foldersSkipped))
        continuation.finish()
    }

    /// Persists a fresh `ScanSnapshot` so a later scan of this same root can
    /// delta-rescan via `attemptDeltaScan` instead of doing a full walk.
    private static func saveSnapshot(rootPath: String, rootNode: FileNode) {
        guard let volumeUUID = FSEventsDelta.volumeUUID(forPath: rootPath) else { return }
        let entries = SnapshotTreeBuilder.entries(from: rootNode)
        let cursor = FSEventsDelta.currentEventId()
        ScanSnapshotStore.save(ScanSnapshot(rootPath: rootPath, volumeUUID: volumeUUID, eventCursor: cursor, entries: entries))
    }

    /// Tries to satisfy this scan from a previous `ScanSnapshot` plus
    /// whatever changed since it was taken, entirely skipping the `fts`
    /// walk. Returns `true` if it succeeded and already emitted the full
    /// event sequence (`rootCreated` → `subtreeCompleted` → `finished`) and
    /// saved a refreshed snapshot; `false` means the caller must fall back
    /// to a full scan (no snapshot yet, volume swapped, or FSEvents history
    /// no longer covers the gap since the snapshot).
    private static func attemptDeltaScan(
        rootPath: String,
        start: ContinuousClock.Instant,
        continuation: AsyncThrowingStream<ScanEvent, Error>.Continuation
    ) async -> Bool {
        let debug = ProcessInfo.processInfo.environment["APPLETREE_DEBUG_DELTA"] != nil
        guard let snapshot = ScanSnapshotStore.load(forRootPath: rootPath) else {
            if debug { FileHandle.standardError.write("DEBUG no snapshot\n".data(using: .utf8)!) }
            return false
        }
        guard let currentVolumeUUID = FSEventsDelta.volumeUUID(forPath: rootPath) else {
            if debug { FileHandle.standardError.write("DEBUG no current volume uuid\n".data(using: .utf8)!) }
            return false
        }
        guard currentVolumeUUID == snapshot.volumeUUID else {
            if debug { FileHandle.standardError.write("DEBUG volume mismatch: current=\(currentVolumeUUID) snapshot=\(snapshot.volumeUUID)\n".data(using: .utf8)!) }
            return false
        }

        if debug { FileHandle.standardError.write("DEBUG requesting changes since \(snapshot.eventCursor)\n".data(using: .utf8)!) }
        let result = await FSEventsDelta.changesSince(eventId: snapshot.eventCursor, rootPath: rootPath)
        guard case .changed(let changedPaths, let newCursor) = result else {
            if debug { FileHandle.standardError.write("DEBUG invalidated\n".data(using: .utf8)!) }
            return false
        }
        if debug { FileHandle.standardError.write("DEBUG changed count=\(changedPaths.count) newCursor=\(newCursor)\n".data(using: .utf8)!) }

        var entries = snapshot.entries
        SnapshotDeltaMerge.apply(changedPaths: changedPaths, to: &entries)
        guard let rebuiltRoot = SnapshotTreeBuilder.buildTree(rootPath: rootPath, entries: entries) else {
            if debug { FileHandle.standardError.write("DEBUG buildTree returned nil, entries.count=\(entries.count), rootPath=\(rootPath), hasRootEntry=\(entries[rootPath] != nil)\n".data(using: .utf8)!) }
            return false
        }
        if debug { FileHandle.standardError.write("DEBUG buildTree ok, children=\(rebuiltRoot.children.count), fileCount=\(rebuiltRoot.fileCount)\n".data(using: .utf8)!) }

        // Flag flip and snapshot save both happen before yielding `.finished`
        // /`finish()` — see the full-scan path's identical ordering note.
        // Consumers (including tests asserting on `lastScanTookDeltaPath`)
        // must never observe "stream finished" before these side effects
        // have actually landed.
        lastScanTookDeltaPath = true
        ScanSnapshotStore.save(ScanSnapshot(rootPath: rootPath, volumeUUID: currentVolumeUUID, eventCursor: newCursor, entries: entries))

        continuation.yield(.rootCreated(rebuiltRoot))
        continuation.yield(.subtreeCompleted(parent: rebuiltRoot))
        let elapsed = ContinuousClock.now - start
        continuation.yield(.finished(duration: elapsed, filesScanned: rebuiltRoot.fileCount, foldersSkipped: 0))
        continuation.finish()
        return true
    }

    // MARK: - Traversal (nonisolated: runs concurrently across worker Tasks)

    private static func scanDirectory(
        node: FileNode,
        path: String,
        slots: WorkerSlotPool,
        counters: ScanCounters,
        inodeTracker: InodeTracker,
        ioThrottled: Bool,
        continuation: AsyncThrowingStream<ScanEvent, Error>.Continuation
    ) async {
        // Every worker `Task` that reaches here may land on a fresh OS
        // thread (per this type's own doc comment on blocking-thread
        // growth), so the throttle policy — thread-scoped, not inherited —
        // needs setting on each one, not just once globally.
        if ioThrottled {
            setiopolicy_np(IOPOL_TYPE_DISK, IOPOL_SCOPE_THREAD, IOPOL_THROTTLE)
        }

        guard let ftsp = openFTS(at: path) else {
            counters.addFolderSkipped()
            continuation.yield(.folderSkipped(path: path, reason: "unable to open directory (errno \(errno))"))
            return
        }
        defer { fts_close(ftsp) }

        // Directories descended into inline (concurrency cap reached), awaiting
        // their FTS_DP close within *this* fts session. `node` (this call's own
        // root) is intentionally never pushed/popped here — its own FTS_D/FTS_DP
        // are the level-0 self-entries, and its finalization happens in the
        // caller once this whole function (and any tasks it spawned) returns.
        var stack: [FileNode] = []

        // Every inline directory that gets an eager `finalizeAsDirectory()`
        // at its FTS_DP (below), in the order that happens — which, being
        // FTS's own post-order, is already children-before-parents.
        //
        // That eager finalize is necessary for timely `.subtreeCompleted`
        // progress events, but it can be WRONG: if one of this inline
        // directory's own descendants got carved out to a spawned `Task`
        // (a concurrency slot freed up while we were "inside" it), that
        // task is only guaranteed complete once `withTaskGroup` itself
        // returns below — not synchronously at the FTS_DP moment, which
        // happens *inside* the loop, mid-group. Finalizing early can sum a
        // still-in-flight spawned child's aggregate fields at their
        // zero-initialized default, silently undercounting. Confirmed on a
        // real ~40K-file/~10K-directory tree (a copied Xcode SDK): this
        // undercounted `fileCount` by roughly 20% before the corrective
        // re-finalize pass below was added — small test fixtures never
        // have enough concurrent directories to hit the race.
        //
        // The fix: re-run `finalizeAsDirectory()` on every inline node once
        // more after `withTaskGroup` returns (so every spawned descendant,
        // however deeply nested, is now guaranteed actually done).
        // `finalizeAsDirectory()` is a pure function of current `children`,
        // so redoing it is idempotent when nothing was wrong and corrective
        // when something was.
        var inlineFinalizedInOrder: [FileNode] = []

        await withTaskGroup(of: Void.self) { group in
            while let entp = fts_read(ftsp) {
                if Task.isCancelled { break }

                let info = Int32(entp.pointee.fts_info)
                let level = entp.pointee.fts_level
                let currentParent = stack.last ?? node

                switch info {
                case FTS_D:
                    if level == 0 { continue }

                    // Directory-level dedup: macOS composes the visible
                    // filesystem from multiple APFS volumes joined by
                    // firmlinks (e.g. /Users is a firmlink into the same
                    // underlying volume as /System/Volumes/Data/Users).
                    // Firmlinked directories share device+inode with their
                    // target but do NOT bump st_nlink the way a true
                    // hardlink would, so unlike the file-level check below,
                    // this one can't be gated on nlink > 1 — every directory
                    // needs the check, or a whole-volume scan starting at
                    // "/" double-counts the entire Data volume (confirmed
                    // via a real scan: ~4TB counted twice, once under
                    // /System and again under /Users et al). Skip both the
                    // node creation and the descent for a repeat.
                    let statp = entp.pointee.fts_statp
                    if let statp {
                        let isFirstVisit = inodeTracker.markSeenReturningIsFirst(
                            device: statp.pointee.st_dev,
                            inode: UInt64(statp.pointee.st_ino)
                        )
                        if !isFirstVisit {
                            markSkipped(entp)
                            fts_set(ftsp, entp, FTS_SKIP)
                            continue
                        }
                    }

                    let fullPath = String(cString: entp.pointee.fts_path)
                    let name = (fullPath as NSString).lastPathComponent
                    let childNode = FileNode(
                        name: name,
                        isDirectory: true,
                        modificationDate: statp.map { date(from: $0.pointee.st_mtimespec) }
                    )
                    currentParent.addChild(childNode)

                    if slots.tryAcquire() {
                        group.addTask {
                            await scanDirectory(
                                node: childNode,
                                path: fullPath,
                                slots: slots,
                                counters: counters,
                                inodeTracker: inodeTracker,
                                ioThrottled: ioThrottled,
                                continuation: continuation
                            )
                            childNode.finalizeAsDirectory()
                            if counters.shouldEmitSubtreeCompleted() {
                                continuation.yield(.subtreeCompleted(parent: childNode))
                            }
                            slots.release()
                        }
                        markSkipped(entp)
                        fts_set(ftsp, entp, FTS_SKIP)
                    } else {
                        stack.append(childNode)
                    }

                case FTS_DP:
                    if level == 0 { continue }
                    // `fts_read` emits a post-order FTS_DP for a directory
                    // even after it was `FTS_SKIP`'d at its own FTS_D —
                    // confirmed empirically (BSD fts's man page doesn't
                    // document this either way). Every FTS_SKIP call above
                    // sets `fts_number` via `markSkipped` specifically so
                    // this phantom close can be told apart from a real one:
                    // treating it as real would pop `stack` for a directory
                    // that was never pushed, silently misattributing every
                    // subsequent sibling/child in this fts session to the
                    // wrong (shallower) ancestor. Confirmed against a real
                    // ~40K-file SDK tree, where this corrupted several
                    // frameworks' header trees by 2-3 levels.
                    if entp.pointee.fts_number == 1 { continue }
                    guard let finished = stack.popLast() else { continue }
                    finished.finalizeAsDirectory()
                    inlineFinalizedInOrder.append(finished)
                    if counters.shouldEmitSubtreeCompleted() {
                        continuation.yield(.subtreeCompleted(parent: finished))
                    }

                case FTS_F, FTS_DEFAULT, FTS_SL, FTS_SLNONE:
                    guard let statp = entp.pointee.fts_statp else { continue }
                    let fullPath = String(cString: entp.pointee.fts_path)
                    let name = (fullPath as NSString).lastPathComponent
                    let size = UInt64(statp.pointee.st_size)
                    let allocated = UInt64(statp.pointee.st_blocks) * 512

                    var countThisFile = true
                    if statp.pointee.st_nlink > 1 {
                        countThisFile = inodeTracker.markSeenReturningIsFirst(
                            device: statp.pointee.st_dev,
                            inode: UInt64(statp.pointee.st_ino)
                        )
                    }

                    let fileNode = FileNode(
                        name: name,
                        isDirectory: false,
                        logicalSize: countThisFile ? size : 0,
                        allocatedSize: countThisFile ? allocated : 0,
                        category: FileCategorizer.category(forFileName: name),
                        modificationDate: date(from: statp.pointee.st_mtimespec)
                    )
                    currentParent.addChild(fileNode)

                    if let progress = counters.addFile(bytes: countThisFile ? size : 0) {
                        continuation.yield(.progress(
                            filesScanned: progress.filesScanned,
                            bytesScanned: progress.bytesScanned,
                            currentPath: fullPath
                        ))
                    }

                case FTS_DNR, FTS_ERR, FTS_NS:
                    let fullPath = String(cString: entp.pointee.fts_path)
                    counters.addFolderSkipped()
                    continuation.yield(.folderSkipped(path: fullPath, reason: "errno \(entp.pointee.fts_errno)"))

                default:
                    break
                }
            }
        }

        // Corrective pass: every spawned task reachable from this fts
        // session (at any depth) is now guaranteed complete, so redoing
        // each inline node's finalize (children-before-parents, matching
        // the order they were first finalized in) fixes any aggregate that
        // was summed too early. See the comment on `inlineFinalizedInOrder`.
        for finished in inlineFinalizedInOrder {
            finished.finalizeAsDirectory()
        }
    }

    /// Tags an `FTS_SKIP`'d directory entry via `fts_number` (a scratch
    /// field BSD's `fts` reserves for exactly this kind of caller
    /// bookkeeping) so the `FTS_DP` handler can recognize and ignore the
    /// phantom post-order event `fts_read` still emits for it.
    private static func markSkipped(_ entp: UnsafeMutablePointer<FTSENT>) {
        entp.pointee.fts_number = 1
    }

    private static func date(from ts: timespec) -> Date {
        Date(timeIntervalSince1970: Double(ts.tv_sec) + Double(ts.tv_nsec) / 1_000_000_000)
    }

    /// Resolves symlinks and trailing slashes so the result matches exactly
    /// what FSEvents reports for the same location (e.g. `/tmp/x` and
    /// `/var/folders/.../x/` both canonicalize to `/private/var/.../x`).
    /// Falls back to a trailing-slash-stripped version of the input if
    /// `realpath` fails (e.g. the path doesn't exist) rather than crashing —
    /// the subsequent `lstat` in the normal scan path surfaces that error
    /// properly.
    private static func canonicalPath(for path: String) -> String {
        var buffer = [CChar](repeating: 0, count: Int(PATH_MAX))
        if realpath(path, &buffer) != nil {
            return buffer.withUnsafeBufferPointer { String(cString: $0.baseAddress!) }
        }
        return path.hasSuffix("/") && path.count > 1 ? String(path.dropLast()) : path
    }

    private static func openFTS(at path: String) -> UnsafeMutablePointer<FTS>? {
        guard let cPath = strdup(path) else { return nil }
        defer { free(cPath) }
        var argv: [UnsafeMutablePointer<CChar>?] = [cPath, nil]
        return argv.withUnsafeMutableBufferPointer { buf in
            fts_open(buf.baseAddress, FTS_PHYSICAL | FTS_XDEV | FTS_NOCHDIR, nil)
        }
    }
}
