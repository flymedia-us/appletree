import Foundation
import Testing
@testable import AppleTreeCore

@Suite("SubtreeResync")
struct SubtreeResyncTests {
    /// Builds a real on-disk tree and the `FileNode` tree that mirrors it, so
    /// the survey has something genuine to `lstat` against.
    /// ```
    /// <temp>/
    ///   keep.txt
    ///   docs/
    ///     a.txt
    ///     nested/
    ///       deep.txt
    /// ```
    private func makeFixture() throws -> (root: URL, node: FileNode) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("appletree-resync-\(UUID().uuidString)", isDirectory: true)
        let docs = root.appendingPathComponent("docs", isDirectory: true)
        let nested = docs.appendingPathComponent("nested", isDirectory: true)
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)

        let payload = Data(repeating: 9, count: 100)
        try payload.write(to: root.appendingPathComponent("keep.txt"))
        try payload.write(to: docs.appendingPathComponent("a.txt"))
        try payload.write(to: nested.appendingPathComponent("deep.txt"))

        let rootNode = FileNode(name: root.lastPathComponent, isDirectory: true, rootPath: root.path)
        let keepNode = FileNode(name: "keep.txt", isDirectory: false, allocatedSize: 100)
        let docsNode = FileNode(name: "docs", isDirectory: true)
        let aNode = FileNode(name: "a.txt", isDirectory: false, allocatedSize: 100)
        let nestedNode = FileNode(name: "nested", isDirectory: true)
        let deepNode = FileNode(name: "deep.txt", isDirectory: false, allocatedSize: 100)
        rootNode.addChild(keepNode)
        rootNode.addChild(docsNode)
        docsNode.addChild(aNode)
        docsNode.addChild(nestedNode)
        nestedNode.addChild(deepNode)
        nestedNode.finalizeAsDirectory()
        docsNode.finalizeAsDirectory()
        rootNode.finalizeAsDirectory()

        return (root, rootNode)
    }

    @Test("a tree that matches the filesystem produces no decisions at all")
    func cleanTreeProducesNothing() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        #expect(SubtreeResync.survey(fixture.node).isEmpty)
        #expect(fixture.node.allocatedSize == 300)
    }

    @Test("a file deleted with no event delivered is caught by the resync")
    func catchesSilentlyDeletedFile() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        // Deleted behind the tree's back — exactly the situation a dropped
        // FSEvents notification leaves the app in.
        try FileManager.default.removeItem(at: fixture.root.appendingPathComponent("docs/nested/deep.txt"))

        let decisions = SubtreeResync.survey(fixture.node)
        #expect(decisions.count == 1)
        #expect(decisions.first?.node.name == "deep.txt")
        #expect(decisions.first?.exists == false)

        let changed = SubtreeResync.apply(decisions)
        #expect(changed.count == 1)
        #expect(fixture.node.allocatedSize == 200)
        #expect(fixture.node.fileCount == 2)
    }

    @Test("a deleted directory costs one decision, not one per file inside it")
    func deletedDirectoryShortCircuits() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        try FileManager.default.removeItem(at: fixture.root.appendingPathComponent("docs"))

        // `docs` alone — the survey must not descend into a directory it just
        // found missing, which is what keeps reconciling after an `rm -rf`
        // proportional to what survived rather than what was deleted.
        let decisions = SubtreeResync.survey(fixture.node)
        #expect(decisions.count == 1)
        #expect(decisions.first?.node.name == "docs")

        SubtreeResync.apply(decisions)
        #expect(fixture.node.allocatedSize == 100)
        #expect(fixture.node.fileCount == 1)
        #expect(fixture.node.folderCount == 0)
    }

    @Test("a node wrongly marked removed is restored when the resync finds it on disk")
    func restoresFalsePositive() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        // The mirror image of a missed delete: a stale removal the watch
        // never corrected, e.g. a path reported gone during a rename and
        // never reported back.
        let docs = try #require(fixture.node.child(named: "docs"))
        docs.markRemoved()
        #expect(fixture.node.allocatedSize == 100)

        let decisions = SubtreeResync.survey(fixture.node)
        #expect(decisions.contains { $0.node === docs && $0.exists })

        SubtreeResync.apply(decisions)
        #expect(fixture.node.allocatedSize == 300)
        #expect(!docs.isRemoved)
    }

    @Test("applying a stale survey twice changes nothing the second time")
    func applyIsIdempotent() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        try FileManager.default.removeItem(at: fixture.root.appendingPathComponent("keep.txt"))
        let decisions = SubtreeResync.survey(fixture.node)

        #expect(SubtreeResync.apply(decisions).count == 1)
        // The survey runs off the main actor, so by the time its decisions
        // are applied the tree may already have moved on — re-applying must
        // be a no-op rather than double-counting anything.
        #expect(SubtreeResync.apply(decisions).isEmpty)
        #expect(fixture.node.allocatedSize == 200)
    }

    @Test("surveys a subtree in isolation without touching the rest of the tree")
    func surveysOnlyTheGivenSubtree() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        try FileManager.default.removeItem(at: fixture.root.appendingPathComponent("keep.txt"))
        try FileManager.default.removeItem(at: fixture.root.appendingPathComponent("docs/a.txt"))

        // Scoped to `docs`, so the deletion up at the root is out of scope —
        // this is what makes the resync proportional to where the watch was
        // actually active rather than to the whole scan.
        let docs = try #require(fixture.node.child(named: "docs"))
        let decisions = SubtreeResync.survey(docs)

        #expect(decisions.count == 1)
        #expect(decisions.first?.node.name == "a.txt")
    }
}
