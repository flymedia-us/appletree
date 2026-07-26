import Testing
@testable import AppleTreeCore

@Suite("FileNode")
struct FileNodeTests {
    @Test("finalizeAsDirectory sums sizes and counts from children, sorted descending by displaySize (allocatedSize)")
    func finalizeAsDirectorySumsChildren() {
        let root = FileNode(name: "root", isDirectory: true)

        // logicalSize and allocatedSize deliberately diverge (and their
        // descending orders differ) so this test actually exercises that
        // sorting/display is driven by displaySize (allocatedSize), not
        // logicalSize — matching the product decision that on-disk
        // footprint, not cloud-inflatable apparent size, drives the UI.
        let small = FileNode(name: "small.txt", isDirectory: false, logicalSize: 10, allocatedSize: 300)
        let big = FileNode(name: "big.txt", isDirectory: false, logicalSize: 1000, allocatedSize: 2000)
        let subdir = FileNode(name: "sub", isDirectory: true, logicalSize: 500, allocatedSize: 900, fileCount: 3, folderCount: 0)

        root.addChild(small)
        root.addChild(big)
        root.addChild(subdir)
        root.finalizeAsDirectory()

        #expect(root.logicalSize == 10 + 1000 + 500)
        #expect(root.allocatedSize == 300 + 2000 + 900)
        #expect(root.fileCount == 2 + 3) // small + big directly, plus sub's 3 files
        #expect(root.folderCount == 1) // sub itself
        #expect(root.children.map(\.name) == ["big.txt", "sub", "small.txt"]) // sorted descending by allocatedSize: 2000, 900, 300
    }

    @Test("fractionOfParent is based on displaySize (allocatedSize), not logicalSize")
    func fractionOfParent() {
        let root = FileNode(name: "root", isDirectory: true, logicalSize: 999_000, allocatedSize: 1000)
        let child = FileNode(name: "child", isDirectory: false, logicalSize: 1, allocatedSize: 250)
        root.addChild(child)

        #expect(child.fractionOfParent == 0.25) // 250/1000, ignoring the wildly different logicalSize values
        #expect(root.fractionOfParent == 1.0) // no parent
    }

    @Test("fractionOfParent is 0 when the parent exists but has not yet been sized (mid-scan)")
    func fractionOfParentZeroParentSize() {
        let root = FileNode(name: "root", isDirectory: true, allocatedSize: 0)
        let child = FileNode(name: "child", isDirectory: false, allocatedSize: 250)
        root.addChild(child)

        #expect(child.fractionOfParent == 0.0)
        #expect(root.fractionOfParent == 1.0) // root itself still has no parent
    }

    @Test("path is reconstructed by walking parent chain")
    func pathReconstruction() {
        let root = FileNode(name: "root", isDirectory: true)
        let mid = FileNode(name: "mid", isDirectory: true)
        let leaf = FileNode(name: "leaf.txt", isDirectory: false)

        root.addChild(mid)
        mid.addChild(leaf)

        #expect(leaf.path == "root/mid/leaf.txt")
    }

    @Test("path uses rootPath (the real absolute path) in place of the root's name, which is only its last path component")
    func pathUsesRootPath() {
        let root = FileNode(name: "apple-tree", isDirectory: true, rootPath: "/Users/sam/code/apple-tree")
        let mid = FileNode(name: "mid", isDirectory: true)
        let leaf = FileNode(name: "leaf.txt", isDirectory: false)

        root.addChild(mid)
        mid.addChild(leaf)

        #expect(root.path == "/Users/sam/code/apple-tree")
        #expect(leaf.path == "/Users/sam/code/apple-tree/mid/leaf.txt")
    }

    @Test("id is stable reference identity, distinct per node")
    func identityIsStable() {
        let a = FileNode(name: "a", isDirectory: false)
        let b = FileNode(name: "a", isDirectory: false) // same name, different instance
        #expect(a.id == a.id)
        #expect(a.id != b.id)
    }

    @Test("descendant(atPath:) resolves the root itself, a nested child, and rejects unrelated/unknown paths")
    func descendantAtPath() {
        let root = FileNode(name: "root", isDirectory: true, rootPath: "/scan/root")
        let mid = FileNode(name: "mid", isDirectory: true)
        let leaf = FileNode(name: "leaf.txt", isDirectory: false)
        root.addChild(mid)
        mid.addChild(leaf)

        #expect(root.descendant(atPath: "/scan/root") === root)
        #expect(root.descendant(atPath: "/scan/root/mid") === mid)
        #expect(root.descendant(atPath: "/scan/root/mid/leaf.txt") === leaf)

        // A sibling prefix that merely starts the same isn't actually under
        // the root (e.g. "/scan/root-backup" must not match "/scan/root").
        #expect(root.descendant(atPath: "/scan/root-backup/mid") == nil)
        // A path that never existed in the tree.
        #expect(root.descendant(atPath: "/scan/root/mid/nonexistent.txt") == nil)
        #expect(root.descendant(atPath: "/somewhere/else") == nil)
    }

    @Test("descendant(atPath:) resolves paths under a volume-root scan, whose own path is already \"/\"")
    func descendantAtPathForVolumeRootScan() {
        // Regression test: a whole-volume scan's root node has `path == "/"`
        // — naively appending a separator before matching produces "//",
        // which no real absolute path starts with, so *every* lookup failed
        // silently. Confirmed live: AppleTree never flagged an externally
        // deleted file when the scan root was "Macintosh HD" (i.e. "/"),
        // only reproduced once the scan root was the actual volume root
        // rather than a subfolder.
        let root = FileNode(name: "Macintosh HD", isDirectory: true, rootPath: "/")
        let users = FileNode(name: "Users", isDirectory: true)
        let home = FileNode(name: "samfriedman", isDirectory: true)
        let downloads = FileNode(name: "Downloads", isDirectory: true)
        let file = FileNode(name: "Untitled copy.rtf", isDirectory: false)
        root.addChild(users)
        users.addChild(home)
        home.addChild(downloads)
        downloads.addChild(file)

        #expect(root.path == "/")
        #expect(root.descendant(atPath: "/Users/samfriedman/Downloads/Untitled copy.rtf") === file)
        #expect(root.descendant(atPath: "/Users/samfriedman/Downloads") === downloads)
    }

    @Test("markRemoved excludes a node from every ancestor's aggregate, immediately, without a rescan")
    func markRemovedRecomputesAncestors() {
        let root = FileNode(name: "root", isDirectory: true)
        let sub = FileNode(name: "sub", isDirectory: true)
        let keep = FileNode(name: "keep.txt", isDirectory: false, allocatedSize: 100)
        let doomed = FileNode(name: "doomed.txt", isDirectory: false, allocatedSize: 900)

        root.addChild(sub)
        sub.addChild(keep)
        sub.addChild(doomed)
        sub.finalizeAsDirectory()
        root.finalizeAsDirectory()

        #expect(root.allocatedSize == 1000)
        #expect(root.fileCount == 2)

        doomed.markRemoved()

        // Both the immediate parent and its own parent (the root) drop the
        // removed file's contribution — a removal several levels deep must
        // propagate all the way up, not just to its direct parent.
        #expect(sub.allocatedSize == 100)
        #expect(sub.fileCount == 1)
        #expect(root.allocatedSize == 100)
        #expect(root.fileCount == 1)

        // Still present in `children` (so the Tree View can keep showing it,
        // struck through) — just excluded from the sums.
        #expect(sub.children.map(\.name).contains("doomed.txt"))
        #expect(doomed.isRemoved)
    }

    @Test("unmarkRemoved reverses markRemoved, restoring the node's contribution to every ancestor")
    func unmarkRemovedRestoresAncestors() {
        let root = FileNode(name: "root", isDirectory: true)
        let file = FileNode(name: "file.txt", isDirectory: false, allocatedSize: 500)
        root.addChild(file)
        root.finalizeAsDirectory()

        file.markRemoved()
        #expect(root.allocatedSize == 0)

        file.unmarkRemoved()
        #expect(root.allocatedSize == 500)
        #expect(root.fileCount == 1)
        #expect(!file.isRemoved)
    }

    @Test("markRemoved on a directory excludes its whole subtree from ancestor aggregates")
    func markRemovedOnDirectoryExcludesSubtree() {
        let root = FileNode(name: "root", isDirectory: true)
        let doomedDir = FileNode(name: "doomed", isDirectory: true)
        let nested = FileNode(name: "nested.txt", isDirectory: false, allocatedSize: 700)
        let survivor = FileNode(name: "survivor.txt", isDirectory: false, allocatedSize: 50)

        root.addChild(doomedDir)
        root.addChild(survivor)
        doomedDir.addChild(nested)
        doomedDir.finalizeAsDirectory()
        root.finalizeAsDirectory()

        #expect(root.allocatedSize == 750)

        doomedDir.markRemoved()

        #expect(root.allocatedSize == 50)
        #expect(root.fileCount == 1)
        #expect(root.folderCount == 0)
    }

    @Test("child(named:) finds an immediate child and ignores deeper descendants")
    func childByName() {
        let root = FileNode(name: "root", isDirectory: true)
        let sub = FileNode(name: "sub", isDirectory: true)
        let nested = FileNode(name: "nested.txt", isDirectory: false)
        let file = FileNode(name: "file.txt", isDirectory: false)
        root.addChild(sub)
        root.addChild(file)
        sub.addChild(nested)

        #expect(root.child(named: "file.txt") === file)
        #expect(root.child(named: "sub") === sub)
        #expect(root.child(named: "nested.txt") == nil)
        // A file has no children lock at all — must read as "no children"
        // rather than trapping.
        #expect(file.child(named: "anything") == nil)
    }

    @Test("isRemovedOrHasRemovedAncestor reports a live node inside a deleted folder as gone")
    func removedAncestorPropagatesToDescendants() {
        let root = FileNode(name: "root", isDirectory: true)
        let doomedDir = FileNode(name: "doomed", isDirectory: true)
        let nested = FileNode(name: "nested.txt", isDirectory: false, allocatedSize: 700)
        let survivor = FileNode(name: "survivor.txt", isDirectory: false, allocatedSize: 50)
        root.addChild(doomedDir)
        root.addChild(survivor)
        doomedDir.addChild(nested)

        doomedDir.markRemoved()

        // Only the directory itself carries the flag — marking every
        // descendant is exactly the per-node cost a bulk delete can't afford
        // — but a descendant still has to *read* as gone, which is what the
        // Tree View strikes rows through on.
        #expect(!nested.isRemoved)
        #expect(nested.isRemovedOrHasRemovedAncestor)
        #expect(doomedDir.isRemovedOrHasRemovedAncestor)
        #expect(!survivor.isRemovedOrHasRemovedAncestor)
    }

    @Test("a batched removal produces exactly the aggregates one-at-a-time removal would")
    func batchedRemovalMatchesIndividualRemoval() {
        /// Two identical trees, each `depth` levels deep with `breadth`
        /// files per level, so the comparison covers ancestors several
        /// levels above the changed nodes rather than just direct parents.
        func makeTree() -> (root: FileNode, files: [FileNode]) {
            let root = FileNode(name: "root", isDirectory: true, rootPath: "/root")
            var files: [FileNode] = []
            var directories = [root]
            for level in 0..<3 {
                var next: [FileNode] = []
                for directory in directories {
                    for index in 0..<4 {
                        let file = FileNode(
                            name: "f\(level)-\(index).bin",
                            isDirectory: false,
                            logicalSize: UInt64(index + 1) * 10,
                            allocatedSize: UInt64(index + 1) * 100
                        )
                        directory.addChild(file)
                        files.append(file)
                        let sub = FileNode(name: "d\(level)-\(index)", isDirectory: true)
                        directory.addChild(sub)
                        next.append(sub)
                    }
                }
                directories = next
            }
            // Finalize bottom-up so every ancestor sums final child numbers.
            func finalize(_ node: FileNode) {
                for child in node.children where child.isDirectory { finalize(child) }
                node.finalizeAsDirectory()
            }
            finalize(root)
            return (root, files)
        }

        let individual = makeTree()
        let batched = makeTree()
        // Every third file, so the changed set spans many different parents.
        let doomedIndices = stride(from: 0, to: individual.files.count, by: 3)

        for index in doomedIndices {
            individual.files[index].markRemoved()
        }

        var changed: [FileNode] = []
        for index in doomedIndices where batched.files[index].setRemovedState(true) {
            changed.append(batched.files[index])
        }
        FileNode.refinalizeAncestors(of: changed)

        #expect(batched.root.allocatedSize == individual.root.allocatedSize)
        #expect(batched.root.logicalSize == individual.root.logicalSize)
        #expect(batched.root.fileCount == individual.root.fileCount)
        #expect(batched.root.folderCount == individual.root.folderCount)
        #expect(batched.root.allocatedSize > 0)

        // Every intermediate directory too, not just the root — a bottom-up
        // single pass has to leave the middle of the tree correct as well.
        // Keyed by path rather than compared position-by-position: equal-sized
        // siblings (which this fixture is full of, every branch being
        // identical) tie in `finalizeAsDirectory`'s sort, and that sort isn't
        // stable, so their relative order legitimately differs between two
        // runs — as it always has.
        func directories(under node: FileNode) -> [String: FileNode] {
            var result: [String: FileNode] = [:]
            for child in node.children where child.isDirectory {
                result[child.path] = child
                result.merge(directories(under: child)) { current, _ in current }
            }
            return result
        }
        let expected = directories(under: individual.root)
        let actual = directories(under: batched.root)
        #expect(expected.count == actual.count)
        for (path, expectedDirectory) in expected {
            #expect(actual[path]?.allocatedSize == expectedDirectory.allocatedSize)
            #expect(actual[path]?.fileCount == expectedDirectory.fileCount)
            #expect(actual[path]?.folderCount == expectedDirectory.folderCount)
        }
    }

    /// The regression this batching exists for. Removing `count` siblings one
    /// at a time re-sorts and re-sums the whole sibling list `count` times —
    /// quadratic, and at this size several minutes of blocked main thread,
    /// which is precisely what a bulk delete outside the app used to do to
    /// the window. Batched it's one sort and one sum, comfortably
    /// milliseconds. The budget is deliberately enormous relative to that so
    /// this measures the complexity class and not the machine's mood.
    @Test("removing tens of thousands of siblings as one batch stays far off the quadratic path")
    func bulkSiblingRemovalIsNotQuadratic() {
        let count = 20_000
        let root = FileNode(name: "root", isDirectory: true, rootPath: "/root")
        var files: [FileNode] = []
        for index in 0..<count {
            let file = FileNode(name: "f\(index).bin", isDirectory: false, allocatedSize: UInt64(index + 1))
            root.addChild(file)
            files.append(file)
        }
        root.finalizeAsDirectory()

        let started = ContinuousClock.now
        var changed: [FileNode] = []
        for file in files where file.setRemovedState(true) {
            changed.append(file)
        }
        FileNode.refinalizeAncestors(of: changed)
        let elapsed = ContinuousClock.now - started

        #expect(root.allocatedSize == 0)
        #expect(root.fileCount == 0)
        #expect(elapsed < .seconds(5))
    }
}
