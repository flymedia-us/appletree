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
    /// scanner and sorted descending by `displaySize` once the directory's
    /// scan completes (this ordering is relied on by both the Tree View's
    /// default sort and the treemap layout algorithm).
    public internal(set) var children: [FileNode]

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

    public init(
        name: String,
        isDirectory: Bool,
        logicalSize: UInt64 = 0,
        allocatedSize: UInt64 = 0,
        fileCount: Int = 0,
        folderCount: Int = 0,
        children: [FileNode] = [],
        category: FileCategory = .noExtension,
        modificationDate: Date? = nil,
        rootPath: String? = nil,
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
    /// `1.0` for the root (no parent) or when the parent's size is zero.
    public var fractionOfParent: Double {
        guard let parent, parent.displaySize > 0 else { return 1.0 }
        return Double(displaySize) / Double(parent.displaySize)
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
    /// `children` and sorts `children` descending by `displaySize`. Called
    /// once a directory's immediate scan work is done.
    func finalizeAsDirectory() {
        children.sort { $0.displaySize > $1.displaySize }

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
