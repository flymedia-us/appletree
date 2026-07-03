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

    @Test("path is reconstructed by walking parent chain")
    func pathReconstruction() {
        let root = FileNode(name: "root", isDirectory: true)
        let mid = FileNode(name: "mid", isDirectory: true)
        let leaf = FileNode(name: "leaf.txt", isDirectory: false)

        root.addChild(mid)
        mid.addChild(leaf)

        #expect(leaf.path == "root/mid/leaf.txt")
    }

    @Test("id is stable reference identity, distinct per node")
    func identityIsStable() {
        let a = FileNode(name: "a", isDirectory: false)
        let b = FileNode(name: "a", isDirectory: false) // same name, different instance
        #expect(a.id == a.id)
        #expect(a.id != b.id)
    }
}
