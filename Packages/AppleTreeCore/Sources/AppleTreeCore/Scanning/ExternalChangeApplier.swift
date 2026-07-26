/// Applies batches of `ExternalChangeWatcher` results to a scanned tree,
/// reusing across a batch — and across successive batches — every piece of
/// work that consecutive paths have in common.
///
/// This is the whole tree-mutating half of the external-change pipeline,
/// deliberately kept out of the app layer: the app owns *when* changes are
/// applied (coalescing watcher batches, chunking them so the main thread is
/// never held, bumping the render generation), while everything about *what*
/// the changes do to the model lives here, where it's a plain value type over
/// a plain `FileNode` and can be tested directly.
///
/// The naive shape — resolve each path with `FileNode.descendant(atPath:)`,
/// then `markRemoved()` it — is quadratic twice over, which made deleting a
/// large folder outside the app freeze the window for minutes:
///
/// - `descendant(atPath:)` walks from the root doing a linear name search at
///   every level. Right for a one-off lookup, wrong for a bulk delete, which
///   produces thousands of paths that are mostly *siblings* — each re-walking
///   the same prefix and re-scanning the same (possibly enormous) sibling
///   list. Caching the resolved directory per parent path and indexing that
///   directory's children by name once turns `n` siblings under a directory
///   of `k` children from `O(n · k)` into `O(n + k)`.
/// - `markRemoved()` recomputes every ancestor's aggregate on its own, so `n`
///   files vanishing from one directory re-sort and re-sum that directory `n`
///   times. Flagging the whole batch first and then calling
///   `FileNode.refinalizeAncestors(of:)` once collapses that to one recompute
///   per affected directory.
public struct ExternalChangeApplier {
    public struct Change: Sendable {
        public let path: String
        public let stillExists: Bool

        public init(path: String, stillExists: Bool) {
            self.path = path
            self.stillExists = stillExists
        }
    }

    private let root: FileNode
    /// `FileNode.path` rebuilds a string by walking the parent chain on every
    /// read, so the one path compared against every single change is worth
    /// holding onto.
    private let rootPath: String
    private var directories: [String: FileNode] = [:]
    private var childrenByName: [FileNode.ID: [String: FileNode]] = [:]
    private var indexedChildren = 0

    /// Ceiling on how many children the name indexes may hold before they're
    /// dropped and rebuilt on demand. Deleting an entire volume's worth of
    /// files would otherwise let them grow to roughly one entry per node in
    /// the tree — a lot of memory to hold for a cache whose whole value comes
    /// from consecutive paths sharing a directory, which the most recently
    /// indexed ones still do after a reset.
    private static let indexedChildrenCap = 250_000

    /// The caches assume the tree's *shape* is fixed — nodes are flagged, not
    /// added or removed — which is true for the whole life of a scan result.
    /// Make a new applier when a new scan replaces the tree.
    public init(root: FileNode) {
        self.root = root
        self.rootPath = root.path
    }

    /// Applies one batch and returns the nodes whose removal state actually
    /// changed (empty when the batch was entirely redundant, which is the
    /// caller's cue that nothing needs re-rendering).
    @discardableResult
    public mutating func apply(_ changes: [Change]) -> [FileNode] {
        // Shortest path first, which for filesystem paths means every
        // ancestor before any of its descendants. That ordering is what lets
        // the `isRemovedOrHasRemovedAncestor` check below discard a deleted
        // folder's entire contents in O(1) each: the folder's own change is
        // applied by the time its children are looked at, and nothing under
        // an already-excluded directory can change any aggregate.
        let ordered = changes.sorted { $0.path.utf8.count < $1.path.utf8.count }

        var changedNodes: [FileNode] = []
        for change in ordered {
            guard let node = node(atPath: change.path) else { continue }
            if change.stillExists {
                // Mirrors the in-app Trash path (see `FileNode.markRemoved()`)
                // so a file recreated — or a delete undone — outside the app
                // is reflected without a rescan.
                if node.setRemovedState(false) { changedNodes.append(node) }
            } else {
                guard !node.isRemovedOrHasRemovedAncestor else { continue }
                if node.setRemovedState(true) { changedNodes.append(node) }
            }
        }

        guard !changedNodes.isEmpty else { return [] }
        FileNode.refinalizeAncestors(of: changedNodes)
        return changedNodes
    }

    // MARK: Resolution

    private mutating func node(atPath path: String) -> FileNode? {
        if path == rootPath { return root }
        guard let separator = path.lastIndex(of: "/") else { return nil }
        let parentPath = separator == path.startIndex ? "/" : String(path[path.startIndex..<separator])
        let name = String(path[path.index(after: separator)...])
        guard !name.isEmpty, let parent = directory(atPath: parentPath) else { return nil }
        return index(of: parent)[name]
    }

    private mutating func directory(atPath path: String) -> FileNode? {
        if let cached = directories[path] { return cached }
        guard let resolved = root.descendant(atPath: path) else { return nil }
        directories[path] = resolved
        return resolved
    }

    private mutating func index(of directory: FileNode) -> [String: FileNode] {
        if let cached = childrenByName[directory.id] { return cached }
        if indexedChildren > Self.indexedChildrenCap {
            childrenByName.removeAll(keepingCapacity: true)
            indexedChildren = 0
        }
        let children = directory.children
        var index = [String: FileNode](minimumCapacity: children.count)
        for child in children {
            index[child.name] = child
        }
        childrenByName[directory.id] = index
        indexedChildren += children.count
        return index
    }
}
