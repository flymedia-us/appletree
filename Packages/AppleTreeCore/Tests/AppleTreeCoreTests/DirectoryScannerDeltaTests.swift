import Foundation
import Testing
@testable import AppleTreeCore

/// End-to-end verification of the FSEvents-based delta rescan: scan a real
/// fixture, mutate it on disk, rescan the same root, and confirm both that
/// the fast path actually ran (`DirectoryScanner.lastScanTookDeltaPath`) and
/// that its result exactly matches a from-scratch full scan of the mutated
/// tree — accuracy is the whole point, a fast wrong answer is worse than a
/// slow right one.
@Suite("DirectoryScanner delta rescan", .serialized)
struct DirectoryScannerDeltaTests {
    private func makeFixture() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("appletree-delta-e2e-\(UUID().uuidString)", isDirectory: true)
        let subdir = root.appendingPathComponent("subdir", isDirectory: true)
        try FileManager.default.createDirectory(at: subdir, withIntermediateDirectories: true)
        try Data(repeating: 0, count: 1000).write(to: root.appendingPathComponent("keep.txt"))
        try Data(repeating: 0, count: 2000).write(to: root.appendingPathComponent("willDelete.txt"))
        try Data(repeating: 0, count: 500).write(to: subdir.appendingPathComponent("nested.txt"))
        return root
    }

    private func runScan(root: URL) async throws -> (node: FileNode, finished: Bool) {
        let scanner = DirectoryScanner()
        var rootNode: FileNode?
        var finished = false
        for try await event in await scanner.scan(root: root) {
            switch event {
            case .rootCreated(let node): rootNode = node
            case .finished: finished = true
            case .failed(let error): Issue.record("scan failed: \(error)")
            default: break
            }
        }
        return (try #require(rootNode), finished)
    }

    /// Cache files are keyed by a hash of the scanner's own canonicalized
    /// root path, which this test has no independent way to reproduce
    /// exactly (and shouldn't need to — that's an implementation detail).
    /// Wiping the whole cache directory sidesteps needing to reconstruct
    /// that key just to force "no snapshot" for the ground-truth scan.
    private func clearAllScanCaches() {
        guard let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else { return }
        try? FileManager.default.removeItem(at: base.appendingPathComponent("AppleTree/scan-cache"))
    }

    @Test("delta rescan after real mutations matches a ground-truth full scan")
    func deltaRescanMatchesGroundTruth() async throws {
        let root = try makeFixture()
        defer { try? FileManager.default.removeItem(at: root) }
        defer { clearAllScanCaches() }

        // Baseline full scan — establishes the cached snapshot.
        let (baseline, baselineFinished) = try await runScan(root: root)
        #expect(baselineFinished)
        #expect(DirectoryScanner.lastScanTookDeltaPath == false, "first-ever scan of a root must not claim a delta path")
        #expect(baseline.fileCount == 3)

        // Mutate: delete a file, modify a file in place, add a new file,
        // and drop in a brand-new subdirectory with pre-existing content
        // (the case that most stresses child-reconciliation, per the
        // FSEvents spike this design is based on).
        try FileManager.default.removeItem(at: root.appendingPathComponent("willDelete.txt"))
        try Data(repeating: 1, count: 9000).write(to: root.appendingPathComponent("keep.txt"))
        try Data(repeating: 1, count: 42).write(to: root.appendingPathComponent("brandNew.txt"))
        let droppedIn = root.appendingPathComponent("droppedIn", isDirectory: true)
        try FileManager.default.createDirectory(at: droppedIn, withIntermediateDirectories: true)
        try Data(repeating: 1, count: 111).write(to: droppedIn.appendingPathComponent("a.txt"))
        try Data(repeating: 1, count: 222).write(to: droppedIn.appendingPathComponent("b.txt"))

        // Real settle time for FSEvents' historical log to flush the
        // mutations above — verified empirically to matter (see
        // `FSEventsDelta`'s doc comment); this is not a flaky arbitrary
        // sleep, it reflects genuine OS-side event-log latency.
        try await Task.sleep(for: .seconds(2))

        let (deltaResult, deltaFinished) = try await runScan(root: root)
        #expect(deltaFinished)
        #expect(DirectoryScanner.lastScanTookDeltaPath == true, "rescan of an unchanged-location root with a valid cache must take the delta path")

        // Ground truth: an independent full scan of the same (now-mutated)
        // tree, from a snapshot-free perspective.
        clearAllScanCaches()
        let (groundTruth, groundTruthFinished) = try await runScan(root: root)
        #expect(groundTruthFinished)
        #expect(DirectoryScanner.lastScanTookDeltaPath == false, "cache was deleted, this must be a full scan")

        #expect(deltaResult.logicalSize == groundTruth.logicalSize)
        #expect(deltaResult.allocatedSize == groundTruth.allocatedSize)
        #expect(deltaResult.fileCount == groundTruth.fileCount)
        #expect(deltaResult.folderCount == groundTruth.folderCount)
        #expect(deltaResult.fileCount == 5) // keep, brandNew, droppedIn/a, droppedIn/b, subdir/nested (willDelete removed)

        let deltaNames = Set(flattenNames(deltaResult))
        let groundTruthNames = Set(flattenNames(groundTruth))
        #expect(deltaNames == groundTruthNames)
        #expect(!deltaNames.contains("willDelete.txt"))
        #expect(deltaNames.contains("brandNew.txt"))
        #expect(deltaNames.contains("droppedIn"))
    }

    private func flattenNames(_ node: FileNode) -> [String] {
        [node.name] + node.children.flatMap { flattenNames($0) }
    }
}
