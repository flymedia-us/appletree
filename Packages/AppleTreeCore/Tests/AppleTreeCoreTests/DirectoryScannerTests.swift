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
