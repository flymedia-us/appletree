import Foundation
import Testing
@testable import AppleTree

@Suite("App scan lifecycle", .serialized)
@MainActor
struct AppStateTests {
    @Test("replacing an active scan ignores cancellation from the old scan")
    func replacesActiveScan() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture) }
        let state = AppState()
        // Give the first task an opportunity to start, then replace it
        // while it can still have events or cancellation to deliver.
        state.startScan(root: fixture.appendingPathComponent("first"))
        await Task.yield()
        state.startScan(root: fixture.appendingPathComponent("second"))
        let deadline = ContinuousClock.now + .seconds(10)
        while state.isScanning && ContinuousClock.now < deadline {
            await Task.yield()
            #expect(!state.scanWasCancelled, "A superseded scan must not cancel the replacement's UI")
        }
        #expect(!state.isScanning)
        #expect(!state.scanWasCancelled)
        #expect(state.rootNode?.name == "second")
        #expect(state.filesScanned == 100)
    }

    @Test("user cancellation settles without claiming a completed scan")
    func cancelsScan() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture) }
        let state = AppState()
        state.startScan(root: fixture)
        state.cancelScan()
        try await waitUntilSettled(state)
        #expect(state.scanWasCancelled)
        #expect(!state.isLoadingTree)
    }

    @Test("a failed scan settles and a subsequent successful scan clears the error")
    func recoversFromFailure() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture) }
        let state = AppState()
        state.startScan(root: fixture.appendingPathComponent("missing"))
        try await waitUntilSettled(state)
        #expect(state.errorMessage != nil)
        state.startScan(root: fixture.appendingPathComponent("second"))
        try await waitUntilSettled(state)
        #expect(state.errorMessage == nil)
        #expect(state.filesScanned == 100)
        #expect(!state.scanWasCancelled)
        #expect(state.isLoadingTree)
        state.treemapDidFinishRendering(forGeneration: state.scanGeneration)
        #expect(state.isLoadingTree)
        state.extensionSummaryDidFinishRendering(forGeneration: state.scanGeneration)
        #expect(!state.isLoadingTree)
    }

    private func waitUntilSettled(_ state: AppState) async throws {
        let deadline = ContinuousClock.now + .seconds(10)
        while state.isScanning && ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(1))
        }
        #expect(!state.isScanning, "Scan must settle within ten seconds")
    }

    private func makeFixture() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("appletree-app-state-\(UUID())")
        for directory in ["first", "second"] {
            let folder = root.appendingPathComponent(directory)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            for index in 0..<100 {
                try Data("fixture".utf8).write(to: folder.appendingPathComponent("\(index).txt"))
            }
        }
        return root
    }
}
