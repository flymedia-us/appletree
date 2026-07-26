import Foundation
import Testing
@testable import AppleTreeCore

@Suite("ExternalChangeWatcher")
struct ExternalChangeWatcherTests {
    /// `realpath(3)` matters here: `NSTemporaryDirectory()` is itself a
    /// symlink (`/var` -> `/private/var` on macOS), and FSEvents reports its
    /// canonical, fully-resolved form regardless of what path you passed to
    /// `FSEventStreamCreate` — comparing against the unresolved form would
    /// make every assertion below flaky. `URL.resolvingSymlinksInPath()`
    /// does *not* do this (confirmed empirically: it left `/var/folders/...`
    /// unresolved on this OS version), so this goes straight to `realpath`.
    private func makeTempDirectory() throws -> URL {
        let unresolved = FileManager.default.temporaryDirectory
            .appendingPathComponent("appletree-watcher-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: unresolved, withIntermediateDirectories: true)

        var buffer = [CChar](repeating: 0, count: Int(PATH_MAX))
        guard realpath(unresolved.path, &buffer) != nil else { return unresolved }
        let bytes = buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }
        return URL(fileURLWithPath: String(decoding: bytes, as: UTF8.self), isDirectory: true)
    }

    /// Races "the stream reports a change at `path` satisfying `matching`"
    /// against a generous timeout, so a genuine detection failure fails the
    /// test in bounded time instead of hanging.
    ///
    /// Matching on the *state* rather than just the path is load-bearing, not
    /// defensive: `ExternalChangeWatcher` deliberately reports a fresh `stat`
    /// per event instead of trusting FSEvents' flag bits (see its doc
    /// comment), so one path legitimately produces several changes — including
    /// one for the fixture file's own creation, which FSEvents still delivers
    /// even though it happened before `FSEventStreamStart`. Taking the first
    /// batch that merely *mentions* the path made these tests fail
    /// deterministically in isolation and pass only when earlier suites
    /// happened to advance the FSEvents watermark first.
    private func awaitChange(
        for path: String,
        matching: @escaping @Sendable (ExternalChangeWatcher.PathChange) -> Bool = { _ in true },
        in stream: AsyncStream<[ExternalChangeWatcher.PathChange]>,
        timeoutSeconds: Double = 5
    ) async -> ExternalChangeWatcher.PathChange? {
        await withTaskGroup(of: ExternalChangeWatcher.PathChange?.self) { group in
            group.addTask {
                for await batch in stream {
                    if let match = batch.first(where: { $0.path == path && matching($0) }) {
                        return match
                    }
                }
                return nil
            }
            group.addTask {
                try? await Task.sleep(for: .seconds(timeoutSeconds))
                return nil
            }
            let result = await group.next() ?? nil
            group.cancelAll()
            return result
        }
    }

    @Test("detects a file deleted from outside the app via a live FSEvents watch")
    func detectsExternalDeletion() async throws {
        let root = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let file = root.appendingPathComponent("doomed.txt")
        try Data("hello".utf8).write(to: file)

        let (stream, watcher) = ExternalChangeWatcher.watch(root: root)
        defer { watcher.stop() }

        // FSEventStreamStart wires up its callback asynchronously on
        // watchQueue; give it a moment before mutating the filesystem so
        // the delete isn't missed by a watch that hasn't started yet.
        try await Task.sleep(for: .milliseconds(300))
        try FileManager.default.removeItem(at: file)

        let change = try #require(
            await awaitChange(for: file.path, matching: { !$0.stillExists }, in: stream)
        )
        #expect(change.stillExists == false)
    }

    @Test("reports a recreated path as existing again, not stuck deleted")
    func detectsRecreationAfterDeletion() async throws {
        let root = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let file = root.appendingPathComponent("phoenix.txt")
        try Data("hello".utf8).write(to: file)

        let (stream, watcher) = ExternalChangeWatcher.watch(root: root)
        defer { watcher.stop() }

        try await Task.sleep(for: .milliseconds(300))
        try FileManager.default.removeItem(at: file)
        let deleted = try #require(
            await awaitChange(for: file.path, matching: { !$0.stillExists }, in: stream)
        )
        #expect(deleted.stillExists == false)

        try Data("reborn".utf8).write(to: file)
        let recreated = try #require(
            await awaitChange(for: file.path, matching: { $0.stillExists }, in: stream)
        )
        #expect(recreated.stillExists == true)
    }
}
