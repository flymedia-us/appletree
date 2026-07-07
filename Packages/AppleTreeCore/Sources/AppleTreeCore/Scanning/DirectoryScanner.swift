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
        let path = root.path(percentEncoded: false)

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
                rootDevice: rootStat.st_dev,
                slots: slots,
                counters: counters,
                inodeTracker: inodeTracker,
                ioThrottled: ioThrottled,
                continuation: continuation
            )
            rootNode.finalizeAsDirectory()
        }
        continuation.yield(.subtreeCompleted(parent: rootNode))

        let elapsed = ContinuousClock.now - start
        let final = counters.snapshot()
        continuation.yield(.finished(
            duration: elapsed,
            filesScanned: final.filesScanned,
            foldersSkipped: final.foldersSkipped,
            tccDeniedFolders: final.tccDeniedFolders
        ))
        continuation.finish()
    }

    // MARK: - Traversal (nonisolated: runs concurrently across worker Tasks)

    private static func scanDirectory(
        node: FileNode,
        path: String,
        rootDevice: dev_t,
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
            let reason = FolderSkipReason(errno: errno, path: path)
            counters.addFolderSkipped(reason: reason)
            continuation.yield(.folderSkipped(path: path, reason: reason))
            return
        }
        defer { fts_close(ftsp) }

        // Directories descended into inline (concurrency cap reached), awaiting
        // their FTS_DP close within *this* fts session. `node` (this call's own
        // root) is intentionally never pushed/popped here — its own FTS_D/FTS_DP
        // are the level-0 self-entries, and its finalization happens in the
        // caller once this whole function (and any tasks it spawned) returns.
        //
        // Paired with each pushed node's own full path: `fts_read` emits a
        // post-order FTS_DP for a directory even after it was `FTS_SKIP`'d at
        // its own FTS_D (confirmed empirically — undocumented either way in
        // BSD's `fts` man page), so a naive "pop whatever's on top" at every
        // FTS_DP pops for phantom closes too, corrupting the stack for every
        // subsequent sibling/descendant. An earlier version of this fix used
        // `fts_number` (a scratch field on the FTSENT) to tag skipped entries
        // instead of a path — that broke down on a real, very large scan
        // (`/Users`, ~940K files): `fts` reuses/reallocates its internal
        // FTSENT buffers as a long traversal proceeds, and nothing guarantees
        // a caller-owned scratch field survives that reuse. Comparing the
        // FTS_DP event's own path against what's actually on top of the
        // stack needs no such assumption — `fts_path` is always valid for
        // the *current* entry, reused buffer or not.
        var stack: [(path: String, node: FileNode)] = []

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
                let currentParent = stack.last?.node ?? node

                switch info {
                case FTS_D:
                    if level == 0 { continue }

                    let statp = entp.pointee.fts_statp

                    // Stay on the volume the scan started on. `FTS_XDEV`
                    // (passed to every `fts_open` below) can't enforce this
                    // by itself: each spawned worker opens its *own* fts
                    // session, which resets FTS_XDEV's "starting device" to
                    // wherever that subtree happens to live. That reset is
                    // actually load-bearing — a modern Mac's System and Data
                    // volumes are joined by firmlinks but share one
                    // synthesized `st_dev` (confirmed empirically: `stat("/")`
                    // and `stat("/System/Volumes/Data")` return the identical
                    // device), so without it a "Macintosh HD" scan could
                    // never reach /Users, /Applications, or anything else
                    // living on the Data volume. But it also means any
                    // *genuinely* different device mounted anywhere in the
                    // tree — an external drive under /Volumes, a
                    // CoreSimulator disk image, /System/Volumes/VM — gets
                    // scanned right along with it once handed to its own
                    // worker. Confirmed live: scanning "Macintosh HD" also
                    // scanned an entirely separate external Plex HDD mounted
                    // at /Volumes/Plex Drive. Comparing every directory's own
                    // `st_dev` against the *scan root's* device (captured
                    // once, threaded through every recursive/spawned call
                    // rather than re-derived per fts session) is the actual
                    // "stays on one device" guarantee `ScanOptions` documents.
                    if let statp, statp.pointee.st_dev != rootDevice {
                        fts_set(ftsp, entp, FTS_SKIP)
                        continue
                    }

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
                    if let statp {
                        let isFirstVisit = inodeTracker.markSeenReturningIsFirst(
                            device: statp.pointee.st_dev,
                            inode: UInt64(statp.pointee.st_ino)
                        )
                        if !isFirstVisit {
                            fts_set(ftsp, entp, FTS_SKIP)
                            continue
                        }
                    }

                    let fullPath = String(cString: entp.pointee.fts_path)
                    let name = entryName(entp)
                    let childNode = FileNode(
                        name: name,
                        isDirectory: true,
                        modificationDate: statp.map { date(from: $0.pointee.st_mtimespec) }
                    )
                    currentParent.addChild(childNode)
                    counters.addFolder()

                    if slots.tryAcquire() {
                        group.addTask {
                            await scanDirectory(
                                node: childNode,
                                path: fullPath,
                                rootDevice: rootDevice,
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
                        fts_set(ftsp, entp, FTS_SKIP)
                    } else {
                        stack.append((fullPath, childNode))
                    }

                case FTS_DP:
                    if level == 0 { continue }
                    // See the doc comment on `stack`: only pop when this
                    // FTS_DP's own path actually matches the top of the
                    // stack — a phantom close for a skipped entry (whether
                    // concurrency- or dedup-driven) must never touch it.
                    let closingPath = String(cString: entp.pointee.fts_path)
                    guard stack.last?.path == closingPath else { continue }
                    let finished = stack.removeLast().node
                    finished.finalizeAsDirectory()
                    inlineFinalizedInOrder.append(finished)
                    if counters.shouldEmitSubtreeCompleted() {
                        continuation.yield(.subtreeCompleted(parent: finished))
                    }

                case FTS_F, FTS_DEFAULT, FTS_SL, FTS_SLNONE:
                    guard let statp = entp.pointee.fts_statp else { continue }
                    let fullPath = String(cString: entp.pointee.fts_path)
                    let name = entryName(entp)
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
                            foldersScanned: progress.foldersScanned,
                            bytesScanned: progress.bytesScanned,
                            currentPath: fullPath
                        ))
                    }

                case FTS_DNR, FTS_ERR, FTS_NS:
                    let fullPath = String(cString: entp.pointee.fts_path)
                    let reason = FolderSkipReason(errno: entp.pointee.fts_errno, path: fullPath)
                    counters.addFolderSkipped(reason: reason)
                    continuation.yield(.folderSkipped(path: fullPath, reason: reason))

                    // `fts` visits an unreadable directory (permission
                    // denied — root-owned caches, other users' files, stale
                    // lock directories from dev tools, all routine on any
                    // real whole-drive or home-directory scan) as FTS_D
                    // (it CAN stat the entry) followed by FTS_DNR (it can't
                    // actually read the contents) — and, confirmed
                    // empirically, NO FTS_DP ever follows for it. If this
                    // directory was inline (pushed to `stack`, not spawned —
                    // a spawned one was already `FTS_SKIP`'d before fts
                    // could attempt the read that fails), it's now a
                    // permanent orphan on top of `stack` with no closing
                    // event ever coming: every ancestor above it fails its
                    // own path-match check forever, undercounting the
                    // entire chain up to the root. This was a severe real
                    // regression — a whole-drive scan came back reporting
                    // ~67GB instead of ~556GB. Treat FTS_DNR as this
                    // directory's close, same as a real FTS_DP would.
                    if stack.last?.path == fullPath {
                        let finished = stack.removeLast().node
                        finished.finalizeAsDirectory()
                        inlineFinalizedInOrder.append(finished)
                        if counters.shouldEmitSubtreeCompleted() {
                            continuation.yield(.subtreeCompleted(parent: finished))
                        }
                    }

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

    /// The current fts entry's own file/directory name — the last
    /// `fts_namelen` bytes of `fts_path`, exactly what BSD `fts`'s own
    /// `fts_name` field holds (a flexible array member, awkward to address
    /// directly from Swift, so this reads the identical bytes out of the
    /// already-materialized `fts_path` buffer instead — `fts_path` is
    /// always the root path with every path component including this
    /// entry's own name appended, so its tail *is* the name). Avoids
    /// re-deriving the name via `NSString.lastPathComponent` — an
    /// Objective-C bridge plus a fresh scan for the last "/" — on what's
    /// the hottest loop in the entire scan (once per file and directory).
    private static func entryName(_ entp: UnsafeMutablePointer<FTSENT>) -> String {
        let namelen = Int(entp.pointee.fts_namelen)
        let pathlen = Int(entp.pointee.fts_pathlen)
        return String(cString: entp.pointee.fts_path.advanced(by: pathlen - namelen))
    }

    private static func date(from ts: timespec) -> Date {
        Date(timeIntervalSince1970: Double(ts.tv_sec) + Double(ts.tv_nsec) / 1_000_000_000)
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
