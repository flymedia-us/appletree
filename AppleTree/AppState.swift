import AppleTreeCore
import AppleTreeUI
import Foundation

@Observable
@MainActor
final class AppState {
    private(set) var rootNode: FileNode?
    private(set) var isScanning = false
    private(set) var filesScanned = 0
    private(set) var bytesScanned: UInt64 = 0
    private(set) var foldersSkipped = 0
    private(set) var lastScanDuration: Duration?
    private(set) var scanStartDate: Date?
    private(set) var currentPath: String?
    private(set) var errorMessage: String?

    /// Bumped whenever the (in-place-mutating) `FileNode` tree changes.
    /// Re-assigning `rootNode` to itself does **not** reliably trigger a
    /// SwiftUI re-render — Observation's dependency tracking doesn't treat a
    /// same-reference write to a class-typed property as a change worth
    /// notifying about, confirmed by instrumenting a real scan: only the
    /// `rootNode`-becomes-non-nil transition produced a render, not any of
    /// the dozens of in-place mutations after. A plain `Int` counter that
    /// genuinely changes value each time is what views should observe
    /// instead (see `FileTreeView`'s `scanGeneration` parameter).
    private(set) var scanGeneration = 0

    let selection = SelectionModel()

    private var scanTask: Task<Void, Never>?
    private var lastGenerationBump: ContinuousClock.Instant = .now

    func startScan(root: URL) {
        scanTask?.cancel()

        rootNode = nil
        isScanning = true
        filesScanned = 0
        bytesScanned = 0
        foldersSkipped = 0
        lastScanDuration = nil
        scanStartDate = Date()
        currentPath = nil
        errorMessage = nil
        selection.selectedNodeID = nil

        let scanner = DirectoryScanner()
        scanTask = Task { [weak self] in
            guard let self else { return }
            do {
                for try await event in await scanner.scan(root: root) {
                    self.handle(event)
                }
            } catch {
                self.handle(.failed(error))
            }
        }
    }

    func cancelScan() {
        scanTask?.cancel()
        isScanning = false
    }

    private func handle(_ event: ScanEvent) {
        switch event {
        case .rootCreated(let node):
            rootNode = node
            bumpGeneration(force: true)

        case .subtreeCompleted:
            // Throttled: a large scan can complete thousands of subtrees;
            // re-rendering the Tree View on every single one would flood the
            // main thread with NSOutlineView.reloadData() calls for no
            // visible benefit between frames.
            bumpGeneration()

        case .progress(let files, let bytes, let path):
            filesScanned = files
            bytesScanned = bytes
            currentPath = path

        case .folderSkipped(_, _):
            foldersSkipped += 1

        case .finished(let duration, let files, let skipped):
            isScanning = false
            filesScanned = files
            foldersSkipped = skipped
            lastScanDuration = duration
            currentPath = nil
            bumpGeneration(force: true)

        case .failed(let error):
            isScanning = false
            errorMessage = error.localizedDescription
        }
    }

    private func bumpGeneration(force: Bool = false) {
        let now = ContinuousClock.now
        guard force || now - lastGenerationBump > .milliseconds(100) else { return }
        lastGenerationBump = now
        scanGeneration += 1
    }
}
