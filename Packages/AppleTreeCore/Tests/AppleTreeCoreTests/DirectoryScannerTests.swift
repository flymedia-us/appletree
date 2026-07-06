import Foundation
import Testing
@testable import AppleTreeCore

@Suite("DirectoryScanner")
struct DirectoryScannerTests {
    /// Builds a small fixture tree:
    ///   root/file1.txt        (100 bytes)
    ///   root/hardlink.txt     (hardlink to file1.txt — same inode, must not double-count)
    ///   root/subdir/file2.txt (200 bytes)
    ///   root/subdir2/         (empty directory)
    private func makeFixture() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("appletree-scanner-test-\(UUID().uuidString)", isDirectory: true)
        let subdir = root.appendingPathComponent("subdir", isDirectory: true)
        let subdir2 = root.appendingPathComponent("subdir2", isDirectory: true)

        try FileManager.default.createDirectory(at: subdir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: subdir2, withIntermediateDirectories: true)

        let file1 = root.appendingPathComponent("file1.txt")
        let file2 = subdir.appendingPathComponent("file2.txt")
        try Data(repeating: 0, count: 100).write(to: file1)
        try Data(repeating: 0, count: 200).write(to: file2)

        let hardlink = root.appendingPathComponent("hardlink.txt")
        try FileManager.default.linkItem(at: file1, to: hardlink)

        return root
    }

    @Test("scans real fixture tree, reports correct total size and dedups hardlinks")
    func scansFixtureTree() async throws {
        let root = try makeFixture()
        defer { try? FileManager.default.removeItem(at: root) }

        let scanner = DirectoryScanner()
        var rootNode: FileNode?
        var finished = false
        var foldersSkipped = -1
        var filesScanned = -1

        for try await event in await scanner.scan(root: root) {
            switch event {
            case .rootCreated(let node):
                rootNode = node
            case .finished(_, let scannedCount, let skipped):
                finished = true
                filesScanned = scannedCount
                foldersSkipped = skipped
            case .failed(let error):
                Issue.record("scan failed: \(error)")
            default:
                break
            }
        }

        #expect(finished)
        #expect(foldersSkipped == 0)
        // file1.txt + hardlink.txt (shared inode, counted once) + file2.txt
        #expect(filesScanned == 3)

        let node = try #require(rootNode)
        #expect(node.logicalSize == 300) // 100 + 200, hardlink NOT double-counted
        #expect(node.fileCount == 3)
        #expect(node.folderCount == 2)
    }

    /// Regression test for a real bug found while stress-testing against a
    /// ~40K-file SDK tree: `fts_read` emits a phantom post-order `FTS_DP`
    /// even for a directory that was `FTS_SKIP`'d at its pre-order `FTS_D`
    /// (confirmed empirically — undocumented either way in BSD's `fts` man
    /// page). Every directory promoted to a spawned `Task` gets
    /// `fts_set(..., FTS_SKIP)`'d in the *current* fts session, so without
    /// tagging skipped entries via `fts_number` and checking it in the
    /// `FTS_DP` case, that phantom close pops `stack` for a directory that
    /// was never pushed — silently misattributing every subsequent inline
    /// sibling/descendant to the wrong (shallower) ancestor. With
    /// `maxConcurrentWorkers: 1`, the first sibling `fts` encounters always
    /// wins the sole slot (a synchronous, lock-based `tryAcquire`) and gets
    /// spawned+skipped, forcing every other sibling inline — deterministically
    /// reproducing the interleaving that triggered the bug.
    @Test("a spawned-and-skipped sibling directory never corrupts inline siblings' parenting")
    func skippedSiblingDoesNotCorruptInlineSiblings() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("appletree-fts-skip-test-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let siblingCount = 20
        for i in 0..<siblingCount {
            let nested = root.appendingPathComponent("sibling\(i)/nested", isDirectory: true)
            try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
            try Data(repeating: 0, count: 10).write(to: nested.appendingPathComponent("leaf.txt"))
        }

        let scanner = DirectoryScanner()
        var rootNode: FileNode?
        for try await event in await scanner.scan(root: root, options: ScanOptions(maxConcurrentWorkers: 1)) {
            if case .rootCreated(let node) = event { rootNode = node }
        }

        let node = try #require(rootNode)
        #expect(node.fileCount == siblingCount, "every sibling's nested leaf.txt must be counted")
        #expect(node.folderCount == siblingCount * 2, "each sibling contributes itself + its own 'nested' subdirectory")
        #expect(node.children.count == siblingCount, "every sibling must be a DIRECT child of root, not misattributed elsewhere")

        for child in node.children {
            #expect(child.children.count == 1, "sibling \(child.name) must have exactly its own 'nested' subdirectory as a child")
            guard let nestedChild = child.children.first else { continue }
            #expect(nestedChild.name == "nested")
            #expect(nestedChild.children.count == 1, "'nested' must contain exactly its own leaf.txt")
            #expect(nestedChild.children.first?.name == "leaf.txt")
        }
    }

    /// Regression test for the most severe bug found in this project: a
    /// real whole-drive scan reported ~67GB instead of the true ~556GB.
    /// Root cause — `fts` visits an unreadable (permission-denied)
    /// directory as `FTS_D` (it can stat the entry) immediately followed by
    /// `FTS_DNR` (it can't read the contents), and confirmed empirically:
    /// NO `FTS_DP` ever follows for it. An inline (stack-pushed) directory
    /// that turns out to be unreadable therefore became a permanent orphan
    /// on top of the stack — every real ancestor above it failed its own
    /// path-match check forever, undercounting the entire chain up to the
    /// scan root. `maxConcurrentWorkers: 1` forces every sibling after the
    /// first to go inline (see the sibling-corruption test above for why),
    /// so the unreadable directory here is guaranteed to be inline, not
    /// spawned-and-skipped — the exact shape that triggered the real bug.
    @Test("an unreadable (permission-denied) inline directory doesn't orphan the stack and undercount its ancestors")
    func unreadableInlineDirectoryDoesNotOrphanStack() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("appletree-fts-dnr-test-\(UUID().uuidString)", isDirectory: true)
        let blocked = root.appendingPathComponent("blocked", isDirectory: true)
        let after = root.appendingPathComponent("after", isDirectory: true)
        try FileManager.default.createDirectory(at: blocked, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: after, withIntermediateDirectories: true)
        try Data(repeating: 0, count: 10).write(to: after.appendingPathComponent("f1.txt"))
        try Data(repeating: 0, count: 10).write(to: after.appendingPathComponent("f2.txt"))
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: blocked.path)
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: blocked.path)
            try? FileManager.default.removeItem(at: root)
        }

        let scanner = DirectoryScanner()
        var rootNode: FileNode?
        var foldersSkipped = -1
        for try await event in await scanner.scan(root: root, options: ScanOptions(maxConcurrentWorkers: 1)) {
            switch event {
            case .rootCreated(let node): rootNode = node
            case .finished(_, _, let skipped): foldersSkipped = skipped
            default: break
            }
        }

        let node = try #require(rootNode)
        #expect(foldersSkipped == 1, "the unreadable directory must be reported as skipped, not silently swallowed")
        #expect(node.fileCount == 2, "content in 'after' (a sibling processed later in the SAME inline chain) must still be counted, not lost because 'blocked' orphaned the stack")
        #expect(node.folderCount == 2, "'blocked' and 'after' both count as real (sub)directories even though one is unreadable")
    }

    @Test("ioThrottled option still produces a correct scan")
    func ioThrottledOptionScansCorrectly() async throws {
        let root = try makeFixture()
        defer { try? FileManager.default.removeItem(at: root) }

        let scanner = DirectoryScanner()
        var rootNode: FileNode?
        for try await event in await scanner.scan(root: root, options: ScanOptions(ioThrottled: true)) {
            if case .rootCreated(let node) = event { rootNode = node }
        }

        let node = try #require(rootNode)
        #expect(node.fileCount == 3)
        #expect(node.logicalSize == 300)
    }

    @Test("cancelling the consuming task stops the scan without hanging")
    func cancellationStopsScan() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("appletree-scanner-cancel-test-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        // Enough nested work that cancellation has something to interrupt.
        for i in 0..<20 {
            let dir = root.appendingPathComponent("dir\(i)", isDirectory: true)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            for j in 0..<20 {
                try Data(repeating: 0, count: 16).write(to: dir.appendingPathComponent("file\(j).txt"))
            }
        }

        let scanner = DirectoryScanner()
        let consumer = Task { () -> Int in
            var count = 0
            for try await _ in await scanner.scan(root: root) {
                count += 1
            }
            return count
        }
        consumer.cancel()

        // Must not hang: bound the wait and accept whatever partial result we get.
        let didFinish = await withTaskGroup(of: Bool.self) { group in
            group.addTask {
                _ = try? await consumer.value
                return true
            }
            group.addTask {
                try? await Task.sleep(for: .seconds(5))
                return false
            }
            let first = await group.next() ?? false
            group.cancelAll()
            return first
        }

        #expect(didFinish, "scan did not stop within the timeout after cancellation")
    }
}
