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
        let maxWorkers = max(1, options.maxConcurrentWorkers ?? ProcessInfo.processInfo.activeProcessorCount * 2)
        let progressInterval = max(1, options.progressFileInterval)

        let (stream, continuation) = AsyncThrowingStream<ScanEvent, Error>.makeStream()
        let scanTask = Task.detached {
            await Self.runScan(
                root: root,
                slots: WorkerSlotPool(max: maxWorkers),
                counters: ScanCounters(progressFileInterval: progressInterval),
                inodeTracker: InodeTracker(),
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
                slots: slots,
                counters: counters,
                inodeTracker: inodeTracker,
                continuation: continuation
            )
            rootNode.finalizeAsDirectory()
        }
        continuation.yield(.subtreeCompleted(parent: rootNode))

        let elapsed = ContinuousClock.now - start
        let final = counters.snapshot()
        continuation.yield(.finished(duration: elapsed, filesScanned: final.filesScanned, foldersSkipped: final.foldersSkipped))
        continuation.finish()
    }

    // MARK: - Traversal (nonisolated: runs concurrently across worker Tasks)

    private static func scanDirectory(
        node: FileNode,
        path: String,
        slots: WorkerSlotPool,
        counters: ScanCounters,
        inodeTracker: InodeTracker,
        continuation: AsyncThrowingStream<ScanEvent, Error>.Continuation
    ) async {
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
                        stack.append(childNode)
                    }

                case FTS_DP:
                    if level == 0 { continue }
                    guard let finished = stack.popLast() else { continue }
                    finished.finalizeAsDirectory()
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
