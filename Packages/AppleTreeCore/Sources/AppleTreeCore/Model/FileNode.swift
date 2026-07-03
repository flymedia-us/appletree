import Foundation

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

    /// Sum of `st_size` for a file; sum of all descendant files' sizes for a
    /// directory. For directories this is only meaningful once the directory's
    /// scan has completed (i.e. after `subtreeCompleted` for it has fired).
    public internal(set) var logicalSize: UInt64

    /// On-disk size (`st_blocks * 512`), accounting for compression/sparse
    /// files. This is WizTree's "Allocated" column.
    public internal(set) var allocatedSize: UInt64

    public internal(set) var fileCount: Int
    public internal(set) var folderCount: Int

    /// Empty for files. For directories, populated incrementally by the
    /// scanner and sorted descending by `logicalSize` once the directory's
    /// scan completes (this ordering is relied on by both the Tree View's
    /// default sort and the treemap layout algorithm).
    public internal(set) var children: [FileNode]

    public internal(set) var category: FileCategory

    public weak var parent: FileNode?

    public init(
        name: String,
        isDirectory: Bool,
        logicalSize: UInt64 = 0,
        allocatedSize: UInt64 = 0,
        fileCount: Int = 0,
        folderCount: Int = 0,
        children: [FileNode] = [],
        category: FileCategory = .noExtension,
        parent: FileNode? = nil
    ) {
        self.name = name
        self.isDirectory = isDirectory
        self.logicalSize = logicalSize
        self.allocatedSize = allocatedSize
        self.fileCount = fileCount
        self.folderCount = folderCount
        self.children = children
        self.category = category
        self.parent = parent
    }

    /// Full filesystem path, reconstructed by walking `parent`.
    public var path: String {
        var components: [String] = [name]
        var current = parent
        while let node = current {
            components.append(node.name)
            current = node.parent
        }
        return components.reversed().joined(separator: "/")
    }

    /// Fraction of the parent's `logicalSize` this node occupies, in [0, 1].
    /// `1.0` for the root (no parent) or when the parent's size is zero.
    public var fractionOfParent: Double {
        guard let parent, parent.logicalSize > 0 else { return 1.0 }
        return Double(logicalSize) / Double(parent.logicalSize)
    }
}

extension FileNode: Identifiable {
    /// Reference identity is already stable and free for a class — no need to
    /// mint/store a UUID per node.
    public var id: ObjectIdentifier { ObjectIdentifier(self) }
}

extension FileNode {
    /// Appends a child (scanner-internal mutation; see the type-level
    /// concurrency invariant). Does not update `logicalSize`/`allocatedSize`/
    /// counts on `self` — callers finalize those once all children are known.
    func addChild(_ child: FileNode) {
        child.parent = self
        children.append(child)
        if child.isDirectory {
            folderCount += 1
        } else {
            fileCount += 1
        }
    }

    /// Recomputes `logicalSize`/`allocatedSize`/`fileCount`/`folderCount` from
    /// `children` and sorts `children` descending by `logicalSize`. Called
    /// once a directory's immediate scan work is done.
    func finalizeAsDirectory() {
        children.sort { $0.logicalSize > $1.logicalSize }

        var logical: UInt64 = 0
        var allocated: UInt64 = 0
        var files = 0
        var folders = 0
        for child in children {
            logical += child.logicalSize
            allocated += child.allocatedSize
            if child.isDirectory {
                folders += 1 + child.folderCount
                files += child.fileCount
            } else {
                files += 1
            }
        }
        logicalSize = logical
        allocatedSize = allocated
        fileCount = files
        folderCount = folders
    }
}
