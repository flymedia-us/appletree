import Testing
@testable import AppleTreeCore

@Suite("ExternalChangeApplier")
struct ExternalChangeApplierTests {
    /// ```
    /// /scan            (root)
    ///   keep.txt        100
    ///   docs/
    ///     a.txt         200
    ///     b.txt         300
    ///     nested/
    ///       deep.txt    400
    /// ```
    /// Sizes are `allocatedSize`, which is what `displaySize` and every
    /// aggregate assertion below read.
    private func makeTree(rootPath: String = "/scan") -> FileNode {
        let root = FileNode(name: "scan", isDirectory: true, rootPath: rootPath)
        let keep = FileNode(name: "keep.txt", isDirectory: false, allocatedSize: 100)
        let docs = FileNode(name: "docs", isDirectory: true)
        let a = FileNode(name: "a.txt", isDirectory: false, allocatedSize: 200)
        let b = FileNode(name: "b.txt", isDirectory: false, allocatedSize: 300)
        let nested = FileNode(name: "nested", isDirectory: true)
        let deep = FileNode(name: "deep.txt", isDirectory: false, allocatedSize: 400)

        root.addChild(keep)
        root.addChild(docs)
        docs.addChild(a)
        docs.addChild(b)
        docs.addChild(nested)
        nested.addChild(deep)

        nested.finalizeAsDirectory()
        docs.finalizeAsDirectory()
        root.finalizeAsDirectory()
        return root
    }

    private func gone(_ paths: String...) -> [ExternalChangeApplier.Change] {
        paths.map { ExternalChangeApplier.Change(path: $0, stillExists: false) }
    }

    @Test("a deleted file drops out of every ancestor's aggregate")
    func removesFileFromAncestors() {
        let root = makeTree()
        var applier = ExternalChangeApplier(root: root)

        #expect(root.allocatedSize == 1000)
        let changed = applier.apply(gone("/scan/docs/nested/deep.txt"))

        #expect(changed.count == 1)
        #expect(changed.first?.name == "deep.txt")
        #expect(root.allocatedSize == 600)
        #expect(root.fileCount == 3)
        #expect(root.child(named: "docs")?.allocatedSize == 500)
    }

    @Test("a deleted directory's own descendant events are skipped, not re-applied")
    func deletedDirectoryShortCircuitsItsContents() {
        let root = makeTree()
        var applier = ExternalChangeApplier(root: root)

        // Exactly what `rm -rf /scan/docs` reports, in the order FSEvents is
        // *least* helpful about: descendants listed before their parent. The
        // applier sorts by path length, so the directory is handled first and
        // everything under it becomes a no-op.
        let changed = applier.apply(gone(
            "/scan/docs/nested/deep.txt",
            "/scan/docs/a.txt",
            "/scan/docs/nested",
            "/scan/docs/b.txt",
            "/scan/docs"
        ))

        // Only the directory itself is flagged — the whole point of the
        // short-circuit, since marking each descendant is per-node work that
        // changes no aggregate.
        #expect(changed.count == 1)
        #expect(changed.first?.name == "docs")
        #expect(root.allocatedSize == 100)
        #expect(root.fileCount == 1)
        #expect(root.folderCount == 0)

        // ...but a descendant still reads as gone, which is what the Tree
        // View strikes rows through on.
        let deep = root.descendant(atPath: "/scan/docs/nested/deep.txt")
        #expect(deep?.isRemovedOrHasRemovedAncestor == true)
    }

    @Test("a recreated path is restored to every ancestor's aggregate")
    func recreatedPathIsRestored() {
        let root = makeTree()
        var applier = ExternalChangeApplier(root: root)

        applier.apply(gone("/scan/docs/a.txt"))
        #expect(root.allocatedSize == 800)

        let restored = applier.apply([.init(path: "/scan/docs/a.txt", stillExists: true)])
        #expect(restored.count == 1)
        #expect(root.allocatedSize == 1000)
        #expect(root.fileCount == 4)
    }

    @Test("a batch that changes nothing reports no changes, so nothing re-renders")
    func redundantBatchReportsNoChanges() {
        let root = makeTree()
        var applier = ExternalChangeApplier(root: root)

        #expect(applier.apply(gone("/scan/keep.txt")).count == 1)
        // Same path again, and a path that was never in the tree.
        #expect(applier.apply(gone("/scan/keep.txt")).isEmpty)
        #expect(applier.apply(gone("/scan/never-scanned.txt")).isEmpty)
        #expect(applier.apply(gone("/somewhere/else/entirely.txt")).isEmpty)
        #expect(root.allocatedSize == 900)
    }

    @Test("the cached directory index stays correct across successive batches")
    func cachesStayCorrectAcrossBatches() {
        let root = makeTree()
        var applier = ExternalChangeApplier(root: root)

        // Three separate batches all resolving through the same parent — the
        // second and third hit the cached `docs` node and its cached
        // name index rather than re-walking from the root.
        applier.apply(gone("/scan/docs/a.txt"))
        applier.apply(gone("/scan/docs/b.txt"))
        applier.apply(gone("/scan/docs/nested/deep.txt"))

        #expect(root.allocatedSize == 100)
        #expect(root.fileCount == 1)
        let docs = root.child(named: "docs")
        #expect(docs?.allocatedSize == 0)
        #expect(docs?.fileCount == 0)
    }

    @Test("resolves paths under a whole-volume scan, whose root path is already a slash")
    func resolvesUnderVolumeRoot() {
        // A "/" root is the case `descendant(atPath:)` has its own guard for:
        // naive prefix-joining would require every real path to start "//".
        let root = FileNode(name: "/", isDirectory: true, rootPath: "/")
        let users = FileNode(name: "Users", isDirectory: true)
        let file = FileNode(name: "big.dmg", isDirectory: false, allocatedSize: 5000)
        root.addChild(users)
        users.addChild(file)
        users.finalizeAsDirectory()
        root.finalizeAsDirectory()
        #expect(root.allocatedSize == 5000)

        var applier = ExternalChangeApplier(root: root)
        let changed = applier.apply(gone("/Users/big.dmg"))

        #expect(changed.count == 1)
        #expect(root.allocatedSize == 0)
    }

    @Test("the scan root vanishing is applied to the root node itself")
    func rootPathItself() {
        let root = makeTree()
        var applier = ExternalChangeApplier(root: root)

        let changed = applier.apply(gone("/scan"))

        #expect(changed.count == 1)
        #expect(changed.first === root)
        #expect(root.isRemoved)
    }

    @Test("applying one merged batch matches applying the same changes one batch at a time")
    func mergedBatchMatchesIncremental() {
        let paths = ["/scan/keep.txt", "/scan/docs/a.txt", "/scan/docs/nested/deep.txt"]

        let merged = makeTree()
        var mergedApplier = ExternalChangeApplier(root: merged)
        mergedApplier.apply(paths.map { .init(path: $0, stillExists: false) })

        let incremental = makeTree()
        var incrementalApplier = ExternalChangeApplier(root: incremental)
        for path in paths {
            incrementalApplier.apply([.init(path: path, stillExists: false)])
        }

        // Coalescing watcher batches must be purely a performance decision —
        // it must never change what the tree ends up saying.
        #expect(merged.allocatedSize == incremental.allocatedSize)
        #expect(merged.fileCount == incremental.fileCount)
        #expect(merged.folderCount == incremental.folderCount)
        #expect(merged.allocatedSize == 300)
    }
}
