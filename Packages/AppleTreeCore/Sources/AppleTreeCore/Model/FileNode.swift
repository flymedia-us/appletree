import Foundation
import os

/// A single file or directory discovered during a scan.
///
/// `FileNode` is a reference type so the scanner can append newly-discovered
/// children to an existing directory node in O(1) and have every other holder
/// of that reference (e.g. the UI) observe the update immediately, without
/// copy-on-write propagation up the tree.
///
/// Concurrency invariant: during an active scan, exactly one `Task` owns write
/// access to a given subtree (the worker that is traversing it) — no two tasks
/// ever append to the same node's `children` concurrently. Once a subtree is
/// published via `ScanEvent.subtreeCompleted`, it is treated as read-only by
/// consumers (aside from later, explicitly single-writer operations such as
/// removing a node after a delete). This "single-writer-while-building,
/// read-only-after" discipline is what makes `@unchecked Sendable` safe here.
public final class FileNode: @unchecked Sendable {
    /// Last path component only. The full path is reconstructed by walking
    /// `parent` rather than stored per-node, to avoid an O(n) path string on
    /// every one of potentially hundreds of thousands of nodes.
    public let name: String

    public let isDirectory: Bool

    /// `logicalSize`/`allocatedSize`/`fileCount`/`folderCount`/`isRemoved`
    /// bundled behind one lock so `finalizeAsDirectory()` (and
    /// `markRemoved()`/`unmarkRemoved()`, which call it on an
    /// already-published, concurrently-*read* node — see this type's own
    /// concurrency invariant above) update all four numbers atomically.
    /// Before this, a reader (the treemap layout, the extension breakdown)
    /// could observe a torn mix of old-and-new values for a single node —
    /// e.g. a freshly-updated `allocatedSize` alongside a stale
    /// `fileCount` — mid-write. Confirmed as a real crash: `markRemoved()`
    /// (fired by the external-change watch, well after the initial scan)
    /// racing a live treemap relayout produced a child-group size sum that
    /// exceeded its parent's just-read `totalSize`, underflowing
    /// `TreemapLayout.layoutChildren`'s `totalSize - group1Size` and
    /// trapping. This closes the single-node half of that race; the other
    /// half (a parent's `totalSize`, read once, going stale relative to its
    /// children's sizes summed moments later — inherent to laying out a
    /// tree that's still allowed to change mid-walk) is handled by making
    /// that arithmetic saturate instead of trap (see `TreemapLayout`).
    private struct Aggregate: Sendable {
        var logicalSize: UInt64 = 0
        var allocatedSize: UInt64 = 0
        var fileCount: Int = 0
        var folderCount: Int = 0
        var isRemoved = false
    }
    private let aggregateLock: OSAllocatedUnfairLock<Aggregate>

    /// Every aggregate field at once, for one lock acquisition. Callers that
    /// need more than one of them — `finalizeAsDirectory`'s sort key and sum
    /// loop, which between them touch five per child — would otherwise pay a
    /// separate acquisition per property per child.
    private var aggregateSnapshot: Aggregate { aggregateLock.withLock { $0 } }

    /// Sum of `st_size` for a file; sum of all descendant files' sizes for a
    /// directory. For directories this is only meaningful once the directory's
    /// scan has completed (i.e. after `subtreeCompleted` for it has fired).
    public var logicalSize: UInt64 { aggregateLock.withLock { $0.logicalSize } }

    /// On-disk size (`st_blocks * 512`), accounting for compression/sparse
    /// files. This is WizTree's "Allocated" column.
    public var allocatedSize: UInt64 { aggregateLock.withLock { $0.allocatedSize } }

    public var fileCount: Int { aggregateLock.withLock { $0.fileCount } }
    public var folderCount: Int { aggregateLock.withLock { $0.folderCount } }

    /// Empty for files. For directories, populated incrementally by the
    /// scanner and sorted descending by `displaySize` once the directory's
    /// scan completes (this ordering is relied on by both the Tree View's
    /// default sort and the treemap layout algorithm).
    ///
    /// Lock-protected rather than a plain stored property: unlike the scalar
    /// aggregate fields below, this is a `[FileNode]`, and readers (the tree
    /// view, treemap layout, extension breakdown) are explicitly allowed to
    /// walk it mid-scan, concurrently with the scanner's own `addChild`
    /// appends on other tasks. A plain `Array` races when one side appends
    /// while another iterates — this crashed for real (out-of-bounds
    /// subscript / corrupted `Dictionary` storage inside
    /// `ExtensionBreakdown.compute`, ~15 threads deep in the same recursive
    /// walk while `DirectoryScanner` was still appending to the very
    /// subtrees being walked). Vending a copy under the lock is enough to
    /// fix it: once a reader holds that second reference, the writer's next
    /// `append` finds the buffer not uniquely referenced and copies instead
    /// of mutating storage the reader might be iterating.
    public var children: [FileNode] {
        childrenLock?.withLock { $0 } ?? []
    }

    /// Allocated only for directories. A file is always a leaf, so it would
    /// never hold anything but an empty array — and `OSAllocatedUnfairLock`
    /// is its own heap allocation, so on a file-dominated tree (the common
    /// case: a whole-disk scan is overwhelmingly files) skipping it for every
    /// file roughly halves the scanner's total lock allocations. `nil` reads
    /// as "no children" everywhere below.
    private let childrenLock: OSAllocatedUnfairLock<[FileNode]>?

    public internal(set) var category: FileCategory

    /// Last-modified time from `stat`'s `st_mtimespec` — the file's own for a
    /// file, or the directory's own (not an aggregate of its contents) for a
    /// directory, matching Finder's "Date Modified" column convention.
    public internal(set) var modificationDate: Date?

    /// Set only on a scan's root node — the absolute path the scan started
    /// from. `name` alone is just that path's *last* component (see `name`'s
    /// doc comment), which isn't enough to reconstruct a real filesystem
    /// path for the root, since nothing above it is modeled in the tree.
    /// Every other node leaves this `nil` and reconstructs via `parent`.
    public internal(set) var rootPath: String?

    public weak var parent: FileNode?

    /// Set once this node is confirmed gone (moved to Trash in-app, or found
    /// missing by the external-change watch) — excluded from every ancestor's
    /// aggregate size/count and from the extension breakdown/treemap from
    /// that point on, without waiting for a rescan. Left in `children` (not
    /// removed from the array) so the Tree View can still show it, struck
    /// through, at its last-known position; only the roll-up math and other
    /// views' rendering skip it. See `markRemoved()`.
    public var isRemoved: Bool { aggregateLock.withLock { $0.isRemoved } }

    public init(
        name: String,
        isDirectory: Bool,
        logicalSize: UInt64 = 0,
        allocatedSize: UInt64 = 0,
        fileCount: Int = 0,
        folderCount: Int = 0,
        category: FileCategory = .noExtension,
        modificationDate: Date? = nil,
        rootPath: String? = nil,
        parent: FileNode? = nil
    ) {
        self.name = name
        self.isDirectory = isDirectory
        self.childrenLock = isDirectory ? OSAllocatedUnfairLock(initialState: []) : nil
        self.aggregateLock = OSAllocatedUnfairLock(initialState: Aggregate(
            logicalSize: logicalSize,
            allocatedSize: allocatedSize,
            fileCount: fileCount,
            folderCount: folderCount
        ))
        self.category = category
        self.modificationDate = modificationDate
        self.rootPath = rootPath
        self.parent = parent
    }

    /// Full filesystem path, reconstructed by walking `parent`. The
    /// top-most ancestor's `name` is replaced with its `rootPath` (when
    /// set) rather than joined as-is, since a root's `name` is only its
    /// last path component.
    public var path: String {
        var components: [String] = [name]
        var root = self
        var current = parent
        while let node = current {
            components.append(node.name)
            root = node
            current = node.parent
        }
        var ordered = Array(components.reversed())
        if let rootPath = root.rootPath {
            ordered[0] = rootPath
        }
        return ordered.joined(separator: "/")
    }

    /// The size that drives sorting, treemap area, and the Tree View's Size
    /// column — `allocatedSize` (actual on-disk footprint), not
    /// `logicalSize` (apparent/claimed size). This matters on modern macOS:
    /// cloud-placeholder files (iCloud Optimized Storage, Google Drive's
    /// File Provider integration) report their full cloud `st_size` while
    /// occupying near-zero local blocks, which makes `logicalSize` alone
    /// wildly overstate real disk usage — confirmed on a real machine where
    /// a `du`-measured 3.3GB-on-disk Google Drive folder reported many times
    /// that in claimed logical size. `allocatedSize` reflects what's
    /// actually using local disk space, which is the whole point of a disk
    /// usage analyzer.
    public var displaySize: UInt64 { allocatedSize }

    /// Fraction of the parent's `displaySize` this node occupies, in [0, 1].
    /// `1.0` for the root (no parent). `0.0` when the parent exists but its
    /// size is still zero — typical mid-scan, before `finalizeAsDirectory()`
    /// has run — so the "% of Parent" column shows 0% rather than a
    /// misleading 100% bar while totals are still settling.
    public var fractionOfParent: Double {
        guard let parent else { return 1.0 }
        guard parent.displaySize > 0 else { return 0.0 }
        return Double(displaySize) / Double(parent.displaySize)
    }

    /// Resolves an absolute path to the node representing it within this
    /// subtree, by descending through `children` by name at each path
    /// component — not a precomputed path index, so it needs no invalidation
    /// as the scanner mutates the tree, and stays correct across renames of
    /// the index-building kind that never happened. Intended for the rare
    /// external-change-detection lookup (one path at a time), not a hot path.
    ///
    /// `nil` if `path` isn't `self.path` or a descendant of it, or if any
    /// component along the way no longer matches a child's name (e.g. it was
    /// itself renamed/deleted since the scan).
    public func descendant(atPath path: String) -> FileNode? {
        let base = self.path
        if path == base { return self }

        // A volume-root scan's `path` is already "/" — appending another
        // "/" would require every real path to start with "//", which none
        // do, silently failing to resolve *any* path under a whole-volume
        // scan. Only append the separator when `base` doesn't already end
        // in one.
        let prefix = base.hasSuffix("/") ? base : base + "/"
        guard path.hasPrefix(prefix) else { return nil }

        var current = self
        for component in path.dropFirst(prefix.count).split(separator: "/") {
            guard let next = current.child(named: component) else { return nil }
            current = next
        }
        return current
    }

    /// An immediate child by name, searched *inside* the children lock rather
    /// than through the `children` getter — that getter deliberately vends a
    /// copy (see its doc comment), so a `children.first(where:)` lookup
    /// allocates an array and retains/releases every sibling just to read one
    /// of them. Resolving a path of depth d did that d times, per path; the
    /// external-change watch resolves thousands of paths when a bulk delete
    /// lands, which made those copies a real cost rather than a theoretical
    /// one.
    /// `Sendable` in the bound, not decoration: `withLock`'s closure is
    /// `@Sendable` (see `children`), so the name has to be able to cross it —
    /// which both `String` and the `Substring` that path-component splitting
    /// produces already are.
    public func child(named name: some StringProtocol & Sendable) -> FileNode? {
        childrenLock?.withLock { children in
            children.first { $0.name == name }
        }
    }
}

extension FileNode: Identifiable {
    /// Reference identity is already stable and free for a class — no need to
    /// mint/store a UUID per node.
    public var id: ObjectIdentifier { ObjectIdentifier(self) }
}

extension FileNode {
    /// Depth-first lookup by reference identity. Used by UI layers that hold
    /// a `FileNode.ID` (selection, accessibility) and need the live node.
    public func descendant(withID id: FileNode.ID) -> FileNode? {
        if self.id == id { return self }
        for child in children {
            if let found = child.descendant(withID: id) { return found }
        }
        return nil
    }

    /// Appends a child (scanner-internal mutation; see the type-level
    /// concurrency invariant). Does not update `logicalSize`/`allocatedSize`/
    /// counts on `self` — callers finalize those once all children are known.
    func addChild(_ child: FileNode) {
        child.parent = self
        // `childrenLock` is non-nil for every directory, and only directories
        // are ever `addChild`ed into (the scanner's `currentParent` is always
        // a directory); the `?.` is just belt-and-suspenders for the leaf case.
        childrenLock?.withLock { $0.append(child) }
        aggregateLock.withLock { state in
            if child.isDirectory {
                state.folderCount += 1
            } else {
                state.fileCount += 1
            }
        }
    }

    /// Recomputes `logicalSize`/`allocatedSize`/`fileCount`/`folderCount` from
    /// `children` and sorts `children` descending by `displaySize`. Called
    /// once a directory's immediate scan work is done, and again by
    /// `markRemoved()`/`unmarkRemoved()` to reflect a post-scan removal.
    /// Children flagged `isRemoved` keep their place in the sorted array
    /// (for the Tree View's strikethrough row) but contribute nothing to
    /// the sums.
    func finalizeAsDirectory() {
        // A file has no `childrenLock` and nothing to finalize — its aggregate
        // was set once at init. (Callers only invoke this on directories; this
        // guard makes the leaf case a safe no-op rather than a trap.)
        guard let childrenLock else { return }

        // Snapshot each child's aggregate exactly once, then sort and sum off
        // those numbers. The comparator used to read `displaySize` — a lock
        // acquisition — twice per comparison, and the sum loop read four more
        // locked properties per child, so this function's cost was dominated
        // by `2·n·log n + 4n` lock round-trips rather than the work itself.
        // On a directory with tens of thousands of children, recomputed once
        // per affected ancestor per external-change batch, that is the whole
        // expense.
        //
        // Snapshotting also makes the ordering self-consistent: re-reading a
        // size that a scan worker or `markRemoved()` can change *during* the
        // sort is a comparator that doesn't define a strict weak ordering,
        // the same class of hazard `TreemapLayout.layoutChildren` already
        // snapshots its way out of.
        let sortedChildren = childrenLock.withLock { state -> [(node: FileNode, aggregate: Aggregate)] in
            var decorated = state.map { (node: $0, aggregate: $0.aggregateSnapshot) }
            decorated.sort { $0.aggregate.allocatedSize > $1.aggregate.allocatedSize }
            state = decorated.map(\.node)
            return decorated
        }

        var logical: UInt64 = 0
        var allocated: UInt64 = 0
        var files = 0
        var folders = 0
        for child in sortedChildren where !child.aggregate.isRemoved {
            logical += child.aggregate.logicalSize
            allocated += child.aggregate.allocatedSize
            if child.node.isDirectory {
                folders += 1 + child.aggregate.folderCount
                files += child.aggregate.fileCount
            } else {
                files += 1
            }
        }
        // `withLock`'s closure is `@Sendable`, so it can't capture the loop's
        // own `var` accumulators directly (Swift 6 strict concurrency flags
        // that even though `withLock` runs it synchronously, right here) —
        // rebind to `let`s first.
        let (finalLogical, finalAllocated, finalFiles, finalFolders) = (logical, allocated, files, folders)
        aggregateLock.withLock { state in
            state.logicalSize = finalLogical
            state.allocatedSize = finalAllocated
            state.fileCount = finalFiles
            state.folderCount = finalFolders
        }
    }

    /// Distance from the scan root: `0` for a root node, `1` for its
    /// children, and so on. Walked rather than stored — nothing else needs
    /// it, and `refinalizeAncestors(of:)` reads it once per affected
    /// directory, not per node.
    private var depthFromRoot: Int {
        var depth = 0
        var ancestor = parent
        while let node = ancestor {
            depth += 1
            ancestor = node.parent
        }
        return depth
    }
}

extension FileNode {
    /// Recomputes the aggregates of every directory above `nodes`, visiting
    /// each affected directory exactly once. The shared step both
    /// `markRemoved()` and `unmarkRemoved()` need — either one changes what
    /// its parent's (and *its* parent's, ...) sums should add up to — and the
    /// step that makes a *bulk* removal affordable.
    ///
    /// Doing this one node at a time is what made a large external delete
    /// unusable: `n` files vanishing from the same directory re-sorted and
    /// re-summed that directory `n` times, and every directory above it `n`
    /// times too, for `O(n · depth · siblings log siblings)` main-thread work
    /// where the tree only actually changed in `depth` places. Collecting the
    /// distinct ancestors first collapses that to
    /// `O(n + affected directories × their children)`.
    public static func refinalizeAncestors(of nodes: [FileNode]) {
        var affected: [(depth: Int, node: FileNode)] = []
        var seen: Set<FileNode.ID> = []
        for node in nodes {
            var ancestor = node.parent
            // Stops at the first already-collected ancestor: everything above
            // that point was collected on the walk that first reached it, so
            // continuing would just re-tread a shared prefix once per node —
            // exactly the `× depth` factor this function exists to remove.
            while let current = ancestor, seen.insert(current.id).inserted {
                affected.append((current.depthFromRoot, current))
                ancestor = current.parent
            }
        }

        // Deepest first, so a directory's own aggregate is already final by
        // the time its parent sums it — one pass, no need to iterate to a
        // fixed point.
        affected.sort { $0.depth > $1.depth }
        for entry in affected {
            entry.node.finalizeAsDirectory()
        }
    }
}

extension FileNode {
    /// Marks this node (file or whole subtree) as gone — moved to Trash by
    /// this app, or found missing by the external-change watch — and
    /// immediately recomputes every ancestor's size/count so the Tree
    /// View's parent rows, the treemap, and the extension breakdown all
    /// reflect the removal without waiting for a rescan. See `isRemoved`.
    public func markRemoved() {
        guard setRemovedState(true) else { return }
        Self.refinalizeAncestors(of: [self])
    }

    /// Reverses `markRemoved()` — for the external-change watch's "this path
    /// exists again" case (e.g. a file recreated, or a Trash action undone
    /// outside the app).
    public func unmarkRemoved() {
        guard setRemovedState(false) else { return }
        Self.refinalizeAncestors(of: [self])
    }

    /// Sets the removal flag *without* touching any ancestor, returning
    /// whether it actually changed. Split out from `markRemoved()` so a
    /// caller holding a whole batch of changes — the external-change watch,
    /// which routinely gets thousands at once — can flag them all and then
    /// pay for a single `refinalizeAncestors(of:)` pass, instead of one full
    /// root-ward recompute per node.
    ///
    /// Flagging eagerly (rather than accumulating the intended states and
    /// applying them at the end) is what lets such a caller process a batch
    /// shallowest-path-first and then skip everything under a directory it
    /// already flagged: `isRemovedOrHasRemovedAncestor` sees the decision the
    /// moment it's made.
    public func setRemovedState(_ removed: Bool) -> Bool {
        aggregateLock.withLock { state in
            guard state.isRemoved != removed else { return false }
            state.isRemoved = removed
            return true
        }
    }

    /// True when this node is removed, or sits inside a directory that is.
    ///
    /// A deleted directory's descendants are gone too, but only the
    /// directory's own node carries the flag — deliberately: stamping every
    /// descendant of an `rm -rf`'d folder would be the same per-node cost
    /// this batching exists to avoid, and it buys nothing, since every
    /// aggregate and every visualization already stops at the removed
    /// directory. Presentation code that needs to know whether an individual
    /// row is live asks this instead of `isRemoved`.
    public var isRemovedOrHasRemovedAncestor: Bool {
        var current: FileNode? = self
        while let node = current {
            if node.isRemoved { return true }
            current = node.parent
        }
        return false
    }
}
