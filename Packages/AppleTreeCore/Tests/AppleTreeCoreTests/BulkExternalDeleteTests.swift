import Foundation
import Testing
@testable import AppleTreeCore

/// End-to-end cover for the reported bug: scan a folder, leave the watch
/// running, then delete a large number of files from outside the app. This
/// drives the real pipeline — `DirectoryScanner` → `ExternalChangeWatcher`
/// (real FSEvents) → `ExternalChangeApplier` — against a real temp tree,
/// rather than any of the three in isolation.
@Suite("Bulk external delete")
struct BulkExternalDeleteTests {
    /// See `ExternalChangeWatcherTests`'s identical helper: `realpath(3)` is
    /// required because FSEvents reports canonical paths and the temp
    /// directory sits behind the `/var` -> `/private/var` symlink, which
    /// `URL.resolvingSymlinksInPath()` does not resolve on this OS.
    private func makeTempDirectory() throws -> URL {
        let unresolved = FileManager.default.temporaryDirectory
            .appendingPathComponent("appletree-bulk-delete-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: unresolved, withIntermediateDirectories: true)

        var buffer = [CChar](repeating: 0, count: Int(PATH_MAX))
        guard realpath(unresolved.path, &buffer) != nil else { return unresolved }
        let bytes = buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }
        return URL(fileURLWithPath: String(decoding: bytes, as: UTF8.self), isDirectory: true)
    }

    private func scan(_ root: URL) async throws -> FileNode {
        var rootNode: FileNode?
        for try await event in await DirectoryScanner().scan(root: root) {
            if case .rootCreated(let node) = event { rootNode = node }
        }
        return try #require(rootNode)
    }

    @Test("deleting thousands of files externally settles quickly and leaves correct aggregates")
    func bulkDeleteStaysResponsive() async throws {
        let fileCount = 3_000
        let root = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        // One `keep` file outside the doomed folder, so the assertions can
        // tell "the delete was applied" apart from "the whole tree was
        // zeroed by something else".
        try Data(repeating: 7, count: 512).write(to: root.appendingPathComponent("keep.bin"))
        let bulk = root.appendingPathComponent("bulk", isDirectory: true)
        try FileManager.default.createDirectory(at: bulk, withIntermediateDirectories: true)
        let payload = Data(repeating: 1, count: 1024)
        for index in 0..<fileCount {
            try payload.write(to: bulk.appendingPathComponent("file-\(index).bin"))
        }

        let rootNode = try await scan(root)
        let sizeAfterScan = rootNode.displaySize
        #expect(rootNode.fileCount == fileCount + 1)
        #expect(sizeAfterScan > 0)

        let (stream, watcher) = ExternalChangeWatcher.watch(root: root)
        defer { watcher.stop() }
        // FSEventStreamStart wires its callback up asynchronously; give it a
        // moment so the delete isn't missed by a watch that hasn't started.
        try await Task.sleep(for: .milliseconds(300))

        try FileManager.default.removeItem(at: bulk)

        var applier = ExternalChangeApplier(root: rootNode)
        var timeInsideApply = Duration.zero
        var batches = 0

        // Consume in this task rather than a child one, so the applier and
        // the counters stay local state and never cross a concurrency
        // boundary. The deadline is enforced from outside instead: stopping
        // the watcher finishes the continuation, which ends the loop below —
        // needed because a live watch never finishes on its own.
        let watchdog = Task {
            try? await Task.sleep(for: .seconds(8))
            watcher.stop()
        }
        defer { watchdog.cancel() }

        for await changes in stream {
            let mapped = changes.map {
                ExternalChangeApplier.Change(path: $0.path, stillExists: $0.stillExists)
            }
            let started = ContinuousClock.now
            applier.apply(mapped)
            timeInsideApply += ContinuousClock.now - started
            batches += 1
            // Everything the delete can possibly account for has landed —
            // no reason to sit out the rest of the watchdog.
            if rootNode.fileCount <= 1 { break }
        }

        #expect(batches > 0, "the watch reported nothing at all — FSEvents never delivered")

        // The event stream on its own does NOT reliably get the tree all the
        // way there, which is the whole reason `SubtreeResync` exists. Runs
        // of this very test have seen 2,917 of the 3,000 file paths arrive,
        // and separately seen every file arrive but never the enclosing
        // directory — with `kFSEventStreamEventFlagMustScanSubDirs` not set
        // in either case, so the flag alone would not have saved it. Asserting
        // exact convergence *here* would be asserting a property of FSEvents
        // that measurement says is false.
        #expect(rootNode.displaySize < sizeAfterScan, "the events that did arrive should have been applied")

        // What the app actually promises: once the burst goes quiet it checks
        // the touched directories against disk. This is the same call
        // `AppState.resyncTouchedDirectories` makes, and after it the tree
        // must be exactly right no matter which events FSEvents chose to skip.
        let decisions = SubtreeResync.survey(rootNode)
        SubtreeResync.apply(decisions)

        #expect(rootNode.child(named: "bulk")?.isRemoved == true)
        #expect(rootNode.fileCount == 1, "only keep.bin should remain")
        #expect(rootNode.displaySize > 0, "keep.bin was never deleted and must still count")
        #expect(rootNode.displaySize < sizeAfterScan)

        // The regression guard. Before batching, 3,000 sibling deletions
        // re-sorted and re-summed the same directory 3,000 times — tens of
        // seconds of blocked main thread, which is what made the window
        // unusable. The bound is loose enough not to depend on machine speed
        // and still orders of magnitude below that.
        #expect(timeInsideApply < .seconds(2))
    }
}
