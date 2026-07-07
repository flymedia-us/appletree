import AppleTreeCore
import AppleTreeUI
import Foundation

struct SkippedFolder: Identifiable {
    let id = UUID()
    let path: String
    let reason: FolderSkipReason
}

@Observable
@MainActor
final class AppState {
    private(set) var rootNode: FileNode?
    private(set) var isScanning = false
    private(set) var filesScanned = 0
    private(set) var foldersScanned = 0
    private(set) var bytesScanned: UInt64 = 0
    private(set) var foldersSkipped = 0
    private(set) var tccDeniedFolders = 0
    private(set) var lastScanDuration: Duration?
    private(set) var currentPath: String?
    private(set) var errorMessage: String?
    private(set) var isPermissionNudgeDismissed = false
    private(set) var volumeInfo: VolumeInfo?

    /// A bounded sample of folders skipped specifically for `.tccDenied` —
    /// i.e. the ones Full Disk Access could plausibly fix — for diagnosing
    /// exactly what's still inaccessible. Capped so a scan with thousands
    /// of skips doesn't grow this array unboundedly.
    private(set) var skippedFolderSample: [SkippedFolder] = []
    private static let skippedFolderSampleCap = 200

    /// Paths scanned into the current tree that a live filesystem watch has
    /// since found gone (deleted, or moved out from under their scanned
    /// path — e.g. dragged to the Trash — from Finder, Terminal, or any
    /// other process, not this app's own Delete action). Watching starts
    /// once a scan finishes — see `startWatchingForExternalChanges` — so
    /// this stays empty for the scan's own duration and resets on the next
    /// scan. Kept separate from `FileTreeView`'s own `deletedNodeIDs` (which
    /// tracks in-app Trash actions): this is core scan state, that's
    /// UI-only presentation bookkeeping.
    private(set) var externallyDeletedNodeIDs: Set<FileNode.ID> = []

    /// True for the brief window between the scanner finishing its
    /// filesystem walk (`.finished`) and the Tree View/treemap actually
    /// rendering that result — approximated as "one main-thread run-loop
    /// tick", since that's long enough for `NSOutlineView.reloadData()` to
    /// run. Not pixel-perfect for an extremely large tree whose treemap
    /// relayout is still debouncing, but good enough to bridge the visible
    /// gap without wiring real completion callbacks through `FileTreeView`/
    /// `TreemapView`'s `NSViewRepresentable`/`Canvas` internals.
    private(set) var isLoadingTree = false

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

    private var scanRootURL: URL?
    private var changeWatcher: ExternalChangeWatcher?
    private var changeWatchTask: Task<Void, Never>?

    func startScan(root: URL) {
        scanTask?.cancel()
        stopWatchingForExternalChanges()

        rootNode = nil
        isScanning = true
        isLoadingTree = false
        filesScanned = 0
        foldersScanned = 0
        bytesScanned = 0
        foldersSkipped = 0
        tccDeniedFolders = 0
        lastScanDuration = nil
        currentPath = nil
        errorMessage = nil
        isPermissionNudgeDismissed = false
        volumeInfo = VolumeInfo.forVolume(containing: root)
        skippedFolderSample = []
        externallyDeletedNodeIDs = []
        selection.selectedNodeID = nil

        scanRootURL = root
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

    /// Starts (or restarts) a live watch for changes made to the just-scanned
    /// tree from outside the app. Called once the scan finishes — watching
    /// mid-scan would just be racing the scanner's own writes, and every
    /// path it would report is already covered by the scan itself.
    private func startWatchingForExternalChanges() {
        stopWatchingForExternalChanges()
        guard let scanRootURL else { return }

        let (stream, watcher) = ExternalChangeWatcher.watch(root: scanRootURL)
        changeWatcher = watcher
        changeWatchTask = Task { [weak self] in
            for await changes in stream {
                self?.applyExternalChanges(changes)
            }
        }
    }

    private func stopWatchingForExternalChanges() {
        changeWatchTask?.cancel()
        changeWatchTask = nil
        changeWatcher?.stop()
        changeWatcher = nil
    }

    private func applyExternalChanges(_ changes: [ExternalChangeWatcher.PathChange]) {
        guard let rootNode else { return }
        for change in changes {
            guard let node = rootNode.descendant(atPath: change.path) else { continue }
            if change.stillExists {
                externallyDeletedNodeIDs.remove(node.id)
            } else {
                externallyDeletedNodeIDs.insert(node.id)
            }
        }
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

        case .progress(let files, let folders, let bytes, let path):
            filesScanned = files
            foldersScanned = folders
            bytesScanned = bytes
            currentPath = path

        case .folderSkipped(let path, let reason):
            foldersSkipped += 1
            // Only `.tccDenied` samples are kept — this list exists purely
            // to answer "would Full Disk Access fix this?", and a real
            // whole-disk scan can hit *thousands* of `.accessDenied` system
            // files (mail queues, cups spool, network daemon state, each
            // owned by its own service account) before ever reaching a
            // user's `~/Library/Mail`. A single shared cap filled with
            // those crowds out the one category this list is actually for.
            if reason == .tccDenied {
                tccDeniedFolders += 1
                if skippedFolderSample.count < Self.skippedFolderSampleCap {
                    skippedFolderSample.append(SkippedFolder(path: path, reason: reason))
                }
            }

        case .finished(let duration, let files, let skipped, let tccDenied):
            isScanning = false
            isLoadingTree = true
            filesScanned = files
            foldersSkipped = skipped
            tccDeniedFolders = tccDenied
            lastScanDuration = duration
            currentPath = nil
            bumpGeneration(force: true)
            startWatchingForExternalChanges()
            // Schedules the flip back to "Scan completed" for the run loop
            // tick right after this one — see `isLoadingTree`'s doc comment.
            DispatchQueue.main.async { [weak self] in
                self?.isLoadingTree = false
            }

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
