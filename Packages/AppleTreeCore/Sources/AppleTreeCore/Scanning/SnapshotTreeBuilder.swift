import Darwin
import Foundation

/// Converts between a live `FileNode` tree and the flat, path-keyed
/// `[String: SnapshotEntry]` map that gets persisted and delta-merged.
/// Keeping this conversion in one pure, synchronous place means the delta
/// path never has to mutate a live (possibly UI-observed) `FileNode` graph
/// in place — it only ever edits a plain dictionary, then rebuilds a fresh
/// tree from it the same way a full scan would have produced one.
enum SnapshotTreeBuilder {
    /// Flattens a completed scan's tree into a path-keyed map, ready to
    /// persist as a `ScanSnapshot`.
    static func entries(from rootNode: FileNode) -> [String: SnapshotEntry] {
        var result: [String: SnapshotEntry] = [:]
        func visit(_ node: FileNode) {
            result[node.path] = SnapshotEntry(
                isDirectory: node.isDirectory,
                logicalSize: node.isDirectory ? 0 : node.logicalSize,
                allocatedSize: node.isDirectory ? 0 : node.allocatedSize,
                modificationDate: node.modificationDate,
                category: node.category
            )
            for child in node.children {
                visit(child)
            }
        }
        visit(rootNode)
        return result
    }

    /// Rebuilds a `FileNode` tree from a flat entries map. `rootPath` must
    /// have an entry in `entries` (its own path) — every other key is
    /// expected to be `rootPath` plus a `/`-joined suffix of path components.
    /// Directory aggregates (`logicalSize`/`allocatedSize`/`fileCount`/
    /// `folderCount`) are recomputed bottom-up via the same
    /// `finalizeAsDirectory()` a live scan uses, not read from `entries` —
    /// those fields are meaningless/stale for directories in the flat map.
    ///
    /// Construction and finalization both proceed one BFS level at a time,
    /// with every node *within* a level built/finalized concurrently via
    /// `DispatchQueue.concurrentPerform` — the same "spread across cores"
    /// principle `DirectoryScanner` itself uses for `fts`, applied here to
    /// the in-memory rebuild. This isn't a nice-to-have: a real ~635K-entry
    /// `~/Library` snapshot took as long to rebuild *sequentially* as a
    /// fresh *parallel* `fts` walk of that same directory took to begin
    /// with, erasing almost the entire point of skipping that walk.
    /// Safety: each concurrent iteration within a level owns exactly one
    /// parent `FileNode` and writes only to that parent's own `children`
    /// array and its own slot of a pre-sized results array (written via
    /// `withUnsafeMutableBufferPointer`, the documented-safe pattern for
    /// concurrent disjoint-index writes) — no two iterations ever touch the
    /// same memory.
    static func buildTree(rootPath: String, entries: [String: SnapshotEntry]) -> FileNode? {
        guard let rootEntry = entries[rootPath] else { return nil }

        // Group every other path by its immediate parent path once, up
        // front (O(n)) — this is what lets construction proceed level by
        // level instead of needing a global depth-sorted order.
        var childPathsByParent: [String: [String]] = [:]
        childPathsByParent.reserveCapacity(entries.count)
        for path in entries.keys where path != rootPath {
            childPathsByParent[parentPath(of: path, rootPath: rootPath), default: []].append(path)
        }

        let rootName = (rootPath as NSString).lastPathComponent
        let root = FileNode(
            name: rootName.isEmpty ? rootPath : rootName,
            isDirectory: rootEntry.isDirectory,
            logicalSize: rootEntry.isDirectory ? 0 : rootEntry.logicalSize,
            allocatedSize: rootEntry.isDirectory ? 0 : rootEntry.allocatedSize,
            category: rootEntry.category,
            modificationDate: rootEntry.modificationDate,
            rootPath: rootPath
        )

        // `levels[0]` is `[root]`; `levels[n]` holds every *directory* node
        // discovered at BFS depth `n` (file nodes are created and attached
        // to their parent but never carried forward, since they have no
        // children of their own to process).
        var levels: [[FileNode]] = [[root]]
        var currentLevel: [(path: String, node: FileNode)] = [(rootPath, root)]

        while !currentLevel.isEmpty {
            let work = currentLevel.compactMap { path, node -> (parent: FileNode, childPaths: [String])? in
                guard let childPaths = childPathsByParent[path], !childPaths.isEmpty else { return nil }
                return (node, childPaths)
            }
            guard !work.isEmpty else { break }

            var nextLevelBuckets: [[(String, FileNode)]] = Array(repeating: [], count: work.count)
            nextLevelBuckets.withUnsafeMutableBufferPointer { buffer in
                // `buffer` (and the raw pointer pulled out of it below) is
                // provably safe here — every concurrent iteration writes to
                // its own disjoint index `i` and never touches any other —
                // but the compiler can't verify that on its own, hence the
                // explicit `nonisolated(unsafe)` opt-out rather than a
                // silently-ignored warning.
                nonisolated(unsafe) let base = buffer.baseAddress!
                DispatchQueue.concurrentPerform(iterations: work.count) { i in
                    let (parent, childPaths) = work[i]
                    var bucket: [(String, FileNode)] = []
                    bucket.reserveCapacity(childPaths.count)
                    for path in childPaths {
                        guard let entry = entries[path] else { continue }
                        let name = (path as NSString).lastPathComponent
                        let node = FileNode(
                            name: name,
                            isDirectory: entry.isDirectory,
                            logicalSize: entry.isDirectory ? 0 : entry.logicalSize,
                            allocatedSize: entry.isDirectory ? 0 : entry.allocatedSize,
                            category: entry.category,
                            modificationDate: entry.modificationDate
                        )
                        parent.addChild(node)
                        if entry.isDirectory {
                            bucket.append((path, node))
                        }
                    }
                    base[i] = bucket
                }
            }

            let nextLevel = nextLevelBuckets.flatMap { $0 }
            levels.append(nextLevel.map(\.1))
            currentLevel = nextLevel
        }

        // Finalize deepest-level-first — the reverse of construction order,
        // and (within a level) parallel for the same safety reason: each
        // directory's finalize reads only its own already-finalized
        // children and writes only to itself.
        for level in levels.reversed() {
            DispatchQueue.concurrentPerform(iterations: level.count) { i in
                level[i].finalizeAsDirectory()
            }
        }

        return root
    }

    private static func parentPath(of path: String, rootPath: String) -> String {
        let parent = (path as NSString).deletingLastPathComponent
        return parent.isEmpty ? rootPath : parent
    }
}

/// Applies a set of FSEvents-reported changed paths to a flat entries map in
/// place, so the map stays an accurate reflection of what's on disk without
/// re-`stat`-ing anything outside the changed set.
///
/// Every reported path is treated uniformly, regardless of which FSEvents
/// flag came with it: `lstat` it, and either upsert or remove its entry.
/// When the path is (still) a directory, its *immediate children* are also
/// reconciled against what the map currently thinks they are — this is
/// deliberately redundant with per-file events in the common case, but it's
/// what makes coarse, directory-level-only historical events (verified to
/// happen — see `FSEventsDelta`'s doc comment) still correct: a directory
/// event with no accompanying per-child event still gets its adds/removes
/// discovered here.
enum SnapshotDeltaMerge {
    static func apply(changedPaths: Set<String>, to entries: inout [String: SnapshotEntry]) {
        for path in changedPaths {
            reconcile(path: path, entries: &entries)
        }
    }

    private static func reconcile(path: String, entries: inout [String: SnapshotEntry]) {
        var st = stat()
        guard lstat(path, &st) == 0 else {
            removeSubtree(rootedAt: path, from: &entries)
            return
        }

        let isDirectory = (st.st_mode & S_IFMT) == S_IFDIR
        let name = (path as NSString).lastPathComponent
        entries[path] = SnapshotEntry(
            isDirectory: isDirectory,
            logicalSize: isDirectory ? 0 : UInt64(st.st_size),
            allocatedSize: isDirectory ? 0 : UInt64(st.st_blocks) * 512,
            modificationDate: Date(timeIntervalSince1970: Double(st.st_mtimespec.tv_sec) + Double(st.st_mtimespec.tv_nsec) / 1_000_000_000),
            category: isDirectory ? .noExtension : FileCategorizer.category(forFileName: name)
        )

        if isDirectory {
            reconcileChildren(ofDirectory: path, entries: &entries)
        }
    }

    private static func reconcileChildren(ofDirectory dir: String, entries: inout [String: SnapshotEntry]) {
        guard let liveNames = try? FileManager.default.contentsOfDirectory(atPath: dir) else { return }
        let livePaths = Set(liveNames.map { dir + "/" + $0 })

        let dirPrefix = dir + "/"
        let knownChildPaths = entries.keys.filter { key in
            guard key.hasPrefix(dirPrefix) else { return false }
            return !key[key.index(key.startIndex, offsetBy: dirPrefix.count)...].contains("/")
        }

        for known in knownChildPaths where !livePaths.contains(known) {
            removeSubtree(rootedAt: known, from: &entries)
        }
        for childPath in livePaths where entries[childPath] == nil {
            insertFullSubtree(rootedAt: childPath, into: &entries)
        }
    }

    /// A brand-new directory (e.g. a folder dropped in with existing
    /// content) only gets a single change event for itself, never one per
    /// pre-existing descendant — those descendants predate our watching, so
    /// nothing "changed" about them individually. This walks the whole new
    /// subtree with `fts`, the same traversal primitive `DirectoryScanner`
    /// uses, to populate every entry beneath it in one pass.
    private static func insertFullSubtree(rootedAt path: String, into entries: inout [String: SnapshotEntry]) {
        var rootStat = stat()
        guard lstat(path, &rootStat) == 0 else { return }
        let isDirectory = (rootStat.st_mode & S_IFMT) == S_IFDIR
        let name = (path as NSString).lastPathComponent
        entries[path] = SnapshotEntry(
            isDirectory: isDirectory,
            logicalSize: isDirectory ? 0 : UInt64(rootStat.st_size),
            allocatedSize: isDirectory ? 0 : UInt64(rootStat.st_blocks) * 512,
            modificationDate: Date(timeIntervalSince1970: Double(rootStat.st_mtimespec.tv_sec) + Double(rootStat.st_mtimespec.tv_nsec) / 1_000_000_000),
            category: isDirectory ? .noExtension : FileCategorizer.category(forFileName: name)
        )
        guard isDirectory else { return }

        guard let cPath = strdup(path) else { return }
        defer { free(cPath) }
        var argv: [UnsafeMutablePointer<CChar>?] = [cPath, nil]
        guard let ftsp = argv.withUnsafeMutableBufferPointer({ buf in
            fts_open(buf.baseAddress, FTS_PHYSICAL | FTS_XDEV | FTS_NOCHDIR, nil)
        }) else { return }
        defer { fts_close(ftsp) }

        while let entp = fts_read(ftsp) {
            let info = Int32(entp.pointee.fts_info)
            guard entp.pointee.fts_level > 0 else { continue }
            switch info {
            case FTS_D, FTS_F, FTS_DEFAULT, FTS_SL, FTS_SLNONE:
                guard let statp = entp.pointee.fts_statp else { continue }
                let fullPath = String(cString: entp.pointee.fts_path)
                let entryName = (fullPath as NSString).lastPathComponent
                let entryIsDirectory = info == FTS_D
                entries[fullPath] = SnapshotEntry(
                    isDirectory: entryIsDirectory,
                    logicalSize: entryIsDirectory ? 0 : UInt64(statp.pointee.st_size),
                    allocatedSize: entryIsDirectory ? 0 : UInt64(statp.pointee.st_blocks) * 512,
                    modificationDate: Date(timeIntervalSince1970: Double(statp.pointee.st_mtimespec.tv_sec) + Double(statp.pointee.st_mtimespec.tv_nsec) / 1_000_000_000),
                    category: entryIsDirectory ? .noExtension : FileCategorizer.category(forFileName: entryName)
                )
            default:
                break
            }
        }
    }

    private static func removeSubtree(rootedAt path: String, from entries: inout [String: SnapshotEntry]) {
        entries.removeValue(forKey: path)
        let prefix = path + "/"
        // Materialize the matching keys before removing: mutating `entries`
        // while directly iterating its live `.keys` view is asking for
        // trouble even though Dictionary's COW happens to make it work today.
        let toRemove = entries.keys.filter { $0.hasPrefix(prefix) }
        for key in toRemove {
            entries.removeValue(forKey: key)
        }
    }
}
