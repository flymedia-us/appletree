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
    private(set) var tccDeniedFolders = 0
    private(set) var lastScanDuration: Duration?
    private(set) var scanStartDate: Date?
    private(set) var currentPath: String?
    private(set) var errorMessage: String?
    private(set) var isPermissionNudgeDismissed = false

    private static let fdaNudgeDontAskAgainKey = "com.samfriedman.AppleTree.fdaNudgeDismissed"

    /// Whether to show the "grant Full Disk Access" banner. Driven entirely
    /// by what the just-completed scan actually hit (see `FolderSkipReason`)
    /// rather than a synthetic pre-scan probe: this app is sandboxed, so a
    /// probe attempted before the user has selected any root has nothing to
    /// test against — every path is unreachable regardless of FDA, making
    /// such a check unable to distinguish "FDA not granted" from "sandboxed
    /// and no folder chosen yet." Real skip evidence from a real scan has no
    /// such ambiguity.
    var shouldShowPermissionNudge: Bool {
        tccDeniedFolders > 0
            && !isPermissionNudgeDismissed
            && !UserDefaults.standard.bool(forKey: Self.fdaNudgeDontAskAgainKey)
    }

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
        tccDeniedFolders = 0
        lastScanDuration = nil
        scanStartDate = Date()
        currentPath = nil
        errorMessage = nil
        isPermissionNudgeDismissed = false
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

        case .folderSkipped(_, let reason):
            foldersSkipped += 1
            if reason == .tccDenied { tccDeniedFolders += 1 }

        case .finished(let duration, let files, let skipped, let tccDenied):
            isScanning = false
            filesScanned = files
            foldersSkipped = skipped
            tccDeniedFolders = tccDenied
            lastScanDuration = duration
            currentPath = nil
            bumpGeneration(force: true)

        case .failed(let error):
            isScanning = false
            errorMessage = error.localizedDescription
        }
    }

    func dismissPermissionNudge() {
        isPermissionNudgeDismissed = true
    }

    func dismissPermissionNudgePermanently() {
        UserDefaults.standard.set(true, forKey: Self.fdaNudgeDontAskAgainKey)
        isPermissionNudgeDismissed = true
    }

    private func bumpGeneration(force: Bool = false) {
        let now = ContinuousClock.now
        guard force || now - lastGenerationBump > .milliseconds(100) else { return }
        lastGenerationBump = now
        scanGeneration += 1
    }
}
