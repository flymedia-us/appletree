import Foundation
import Testing
@testable import AppleTreeCore

@Suite("ScanSnapshotStore")
struct ScanSnapshotStoreTests {
    @Test("round-trips a snapshot through disk unchanged")
    func roundTripsThroughDisk() throws {
        let root = "/tmp/scan-snapshot-test-\(UUID().uuidString)"
        let snapshot = ScanSnapshot(
            rootPath: root,
            volumeUUID: "TEST-UUID",
            eventCursor: 12345,
            entries: [
                root: SnapshotEntry(isDirectory: true, logicalSize: 0, allocatedSize: 0, modificationDate: Date(), category: .noExtension),
                "\(root)/file.txt": SnapshotEntry(isDirectory: false, logicalSize: 100, allocatedSize: 4096, modificationDate: Date(), category: .document)
            ]
        )
        defer {
            if let url = ScanSnapshotStore.fileURL(forRootPath: root) {
                try? FileManager.default.removeItem(at: url)
            }
        }

        ScanSnapshotStore.save(snapshot)
        let loaded = try #require(ScanSnapshotStore.load(forRootPath: root))

        #expect(loaded.rootPath == snapshot.rootPath)
        #expect(loaded.volumeUUID == snapshot.volumeUUID)
        #expect(loaded.eventCursor == snapshot.eventCursor)
        #expect(loaded.entries.count == snapshot.entries.count)
        #expect(loaded.entries[root]?.isDirectory == true)
        #expect(loaded.entries["\(root)/file.txt"]?.logicalSize == 100)
    }

    @Test("returns nil for a root path that was never saved")
    func returnsNilWhenNotCached() {
        #expect(ScanSnapshotStore.load(forRootPath: "/nonexistent/\(UUID().uuidString)") == nil)
    }
}

@Suite("SnapshotTreeBuilder")
struct SnapshotTreeBuilderTests {
    @Test("flattening a tree then rebuilding it reproduces the same aggregates")
    func roundTripsTreeAggregates() throws {
        let root = FileNode(name: "root", isDirectory: true, rootPath: "/root")
        let subdir = FileNode(name: "subdir", isDirectory: true)
        let file1 = FileNode(name: "file1.txt", isDirectory: false, logicalSize: 100, allocatedSize: 4096, category: .document)
        let file2 = FileNode(name: "file2.txt", isDirectory: false, logicalSize: 200, allocatedSize: 8192, category: .image)
        root.addChild(subdir)
        root.addChild(file1)
        subdir.addChild(file2)
        subdir.finalizeAsDirectory()
        root.finalizeAsDirectory()

        let entries = SnapshotTreeBuilder.entries(from: root)
        #expect(entries.count == 4) // root, subdir, file1, file2

        let rebuilt = try #require(SnapshotTreeBuilder.buildTree(rootPath: "/root", entries: entries))
        #expect(rebuilt.logicalSize == root.logicalSize)
        #expect(rebuilt.allocatedSize == root.allocatedSize)
        #expect(rebuilt.fileCount == root.fileCount)
        #expect(rebuilt.folderCount == root.folderCount)
        #expect(rebuilt.children.count == 2)

        let rebuiltSubdir = rebuilt.children.first { $0.name == "subdir" }
        #expect(rebuiltSubdir?.logicalSize == 200)
        #expect(rebuiltSubdir?.fileCount == 1)
    }

    @Test("returns nil when the root path itself has no entry")
    func nilWhenRootMissing() {
        #expect(SnapshotTreeBuilder.buildTree(rootPath: "/root", entries: ["/root/child": SnapshotEntry(isDirectory: false, logicalSize: 1, allocatedSize: 1, modificationDate: nil, category: .other)]) == nil)
    }
}

@Suite("SnapshotDeltaMerge")
struct SnapshotDeltaMergeTests {
    private func makeFixture() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("appletree-delta-merge-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data(repeating: 0, count: 50).write(to: root.appendingPathComponent("keep.txt"))
        try Data(repeating: 0, count: 50).write(to: root.appendingPathComponent("toRemove.txt"))
        return root
    }

    @Test("upserts a newly-created file's entry")
    func upsertsNewFile() throws {
        let root = try makeFixture()
        defer { try? FileManager.default.removeItem(at: root) }
        var entries: [String: SnapshotEntry] = [:]

        let newFile = root.appendingPathComponent("newFile.txt")
        try Data(repeating: 1, count: 999).write(to: newFile)

        SnapshotDeltaMerge.apply(changedPaths: [newFile.path], to: &entries)

        let entry = try #require(entries[newFile.path])
        #expect(entry.isDirectory == false)
        #expect(entry.logicalSize == 999)
    }

    @Test("removes an entry (and its subtree) for a deleted path")
    func removesDeletedPath() throws {
        let root = try makeFixture()
        defer { try? FileManager.default.removeItem(at: root) }

        let subdir = root.appendingPathComponent("sub", isDirectory: true)
        try FileManager.default.createDirectory(at: subdir, withIntermediateDirectories: true)
        let nested = subdir.appendingPathComponent("nested.txt")
        try Data(repeating: 0, count: 10).write(to: nested)

        var entries: [String: SnapshotEntry] = [
            subdir.path: SnapshotEntry(isDirectory: true, logicalSize: 0, allocatedSize: 0, modificationDate: nil, category: .noExtension),
            nested.path: SnapshotEntry(isDirectory: false, logicalSize: 10, allocatedSize: 4096, modificationDate: nil, category: .other)
        ]

        try FileManager.default.removeItem(at: subdir)
        SnapshotDeltaMerge.apply(changedPaths: [subdir.path], to: &entries)

        #expect(entries[subdir.path] == nil)
        #expect(entries[nested.path] == nil)
    }

    @Test("refreshes an existing file's size after in-place modification")
    func refreshesModifiedFile() throws {
        let root = try makeFixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("keep.txt")

        var entries: [String: SnapshotEntry] = [
            file.path: SnapshotEntry(isDirectory: false, logicalSize: 50, allocatedSize: 4096, modificationDate: nil, category: .other)
        ]

        try Data(repeating: 0, count: 12345).write(to: file)
        SnapshotDeltaMerge.apply(changedPaths: [file.path], to: &entries)

        #expect(entries[file.path]?.logicalSize == 12345)
    }

    @Test("a directory-level change discovers a new grandchild via child reconciliation, not just the reported path")
    func discoversNewSubtreeViaDirectoryReconciliation() throws {
        let root = try makeFixture()
        defer { try? FileManager.default.removeItem(at: root) }

        var entries: [String: SnapshotEntry] = [
            root.path: SnapshotEntry(isDirectory: true, logicalSize: 0, allocatedSize: 0, modificationDate: nil, category: .noExtension)
        ]

        // Simulate a folder copied in wholesale — only the top directory
        // itself is "new" from FSEvents' perspective; its pre-existing
        // contents never generated their own events.
        let droppedIn = root.appendingPathComponent("dropped", isDirectory: true)
        try FileManager.default.createDirectory(at: droppedIn, withIntermediateDirectories: true)
        try Data(repeating: 0, count: 777).write(to: droppedIn.appendingPathComponent("a.txt"))
        try Data(repeating: 0, count: 333).write(to: droppedIn.appendingPathComponent("b.txt"))

        // Only the root is reported as changed, exactly like the coarse
        // historical-replay case this is defending against.
        SnapshotDeltaMerge.apply(changedPaths: [root.path], to: &entries)

        #expect(entries[droppedIn.path]?.isDirectory == true)
        #expect(entries["\(droppedIn.path)/a.txt"]?.logicalSize == 777)
        #expect(entries["\(droppedIn.path)/b.txt"]?.logicalSize == 333)
    }
}
