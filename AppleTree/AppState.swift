import AppKit
import AppleTreeCore
import AppleTreeUI
import Foundation
import os

private let log = Logger(subsystem: "com.FlyMedia.AppleTree", category: "AppState")

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
    /// True when the most recent scan ended because the user cancelled it
    /// (partial tree may still be on screen). Cleared on the next scan start.
    private(set) var scanWasCancelled = false
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

    /// True for the window between the scanner finishing its filesystem walk
    /// (`.finished`) and the Treemap/Extension Summary panes actually
    /// finishing their own (debounced, backgrounded) relayout/recompute of
    /// that result — see `awaitedVisualizationComponents`. The Tree View
    /// itself doesn't need to report in here: `NSOutlineView.reloadData()`/
    /// `reloadItem()` are synchronous, so its rows are already current by
    /// the time this flips.
    private(set) var isLoadingTree = false

    /// Which of the two async-settling panes (see `TreemapView`'s and
    /// `ExtensionSummaryView`'s `onRelayoutFinished`/`onRecomputeFinished`)
    /// haven't yet confirmed they've rendered the scan that just finished.
    /// `isLoadingTree` flips false only once this drains empty — real
    /// completion signals rather than a fixed delay, since a large tree's
    /// relayout/recompute can easily outlast any one guessed timeout.
    private enum VisualizationComponent: Hashable {
        case treemap
        case extensionSummary
    }
    private var awaitedVisualizationComponents: Set<VisualizationComponent> = []

    /// The `scanGeneration` value in effect when the current load began
    /// (`.finished`). A pane reporting it has rendered *this or any newer*
    /// generation is proof its on-screen content is post-`.finished`, which
    /// is what `isLoadingTree` actually waits on — see
    /// `markVisualizationRendered`.
    private var loadingGeneration = 0

    static let fdaNudgeDontAskAgainKey = "com.FlyMedia.AppleTree.fdaNudgeDismissed"
    static let confirmBeforeDeleteKey = "com.FlyMedia.AppleTree.confirmBeforeDelete"
    static let appearancePreferenceKey = "com.FlyMedia.AppleTree.appearancePreference"

    /// Whether Delete / ⌘⌫ should ask before calling `FileManager.trashItem`.
    /// Defaults to `true` when the preference has never been set — safer for
    /// a first public release of a disk utility.
    var confirmBeforeDelete: Bool {
        if UserDefaults.standard.object(forKey: Self.confirmBeforeDeleteKey) == nil {
            return true
        }
        return UserDefaults.standard.bool(forKey: Self.confirmBeforeDeleteKey)
    }

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
    private var pendingGenerationBumpTask: Task<Void, Never>?
    private static let generationBumpInterval = Duration.milliseconds(100)

    private var scanRootURL: URL?
    /// The URL for which `startAccessingSecurityScopedResource()` succeeded.
    /// Kept alive for the whole scan + post-scan watch/delete lifetime so
    /// sandboxed access to the user-selected tree doesn't evaporate mid-use.
    private var securityScopedRootURL: URL?
    private var changeWatcher: ExternalChangeWatcher?
    private var changeWatchTask: Task<Void, Never>?

    /// External changes the watch has reported but that haven't been applied
    /// to the tree yet, keyed by path so repeated reports for one path
    /// collapse to its most recent state. Drained by
    /// `externalChangeDrainTask` — see `enqueueExternalChanges`.
    private var pendingExternalChanges: [String: Bool] = [:]
    private var externalChangeDrainTask: Task<Void, Never>?

    /// How long to let external changes accumulate before applying them. A
    /// bulk delete arrives as a rapid run of watcher batches, and each one
    /// applied on its own re-resolves and re-sums the same few directories;
    /// merging them first turns that run into a single pass.
    private static let externalChangeCoalescingWindow = Duration.milliseconds(200)

    /// The most external changes applied in one main-actor turn. Everything
    /// past this waits for the next turn, so however enormous the delete, the
    /// main thread is never held for more than one chunk's worth of work and
    /// the window keeps drawing throughout.
    private static let externalChangeChunkSize = 5_000

    /// Presents the standard folder picker and starts a scan on the chosen
    /// root. Shared by the toolbar button and File → Open Folder… so both
    /// paths go through the same security-scoped access handshake.
    func presentFolderPickerAndScan() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Scan"
        panel.message = "Choose a folder or volume to scan"

        guard panel.runModal() == .OK, let url = panel.url else { return }
        startScan(root: url)
    }

    /// Starts a scan from a drag-and-drop. Finder drops usually carry a
    /// security-scoped URL; when they don't (sandbox can't retain access),
    /// fall back to an Open Panel pre-pointed at the dropped folder so the
    /// user can grant durable access before scanning/deleting/watching.
    func startScanFromDroppedFolder(_ dropped: URL) {
        if dropped.startAccessingSecurityScopedResource() {
            // Hand the already-acquired scope to `startScan` so we don't
            // double-`startAccessing` (each start needs a matching stop).
            startScan(root: dropped, preAcquiredSecurityScope: true)
            return
        }

        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.directoryURL = dropped
        panel.prompt = "Scan"
        panel.message = "Grant access to “\(dropped.lastPathComponent)” to scan it"

        guard panel.runModal() == .OK, let url = panel.url else { return }
        startScan(root: url)
    }

    func startScan(root: URL, preAcquiredSecurityScope: Bool = false) {
        scanTask?.cancel()
        stopWatchingForExternalChanges()
        releaseSecurityScopedAccess()
        pendingGenerationBumpTask?.cancel()
        pendingGenerationBumpTask = nil

        rootNode = nil
        isScanning = true
        isLoadingTree = false
        awaitedVisualizationComponents = []
        filesScanned = 0
        foldersScanned = 0
        bytesScanned = 0
        foldersSkipped = 0
        tccDeniedFolders = 0
        lastScanDuration = nil
        scanWasCancelled = false
        currentPath = nil
        errorMessage = nil
        isPermissionNudgeDismissed = false
        volumeInfo = VolumeInfo.forVolume(containing: root)
        skippedFolderSample = []
        selection.selectedNode = nil
        selection.hoveredNode = nil

        // Sandboxed apps only retain access to an `NSOpenPanel`-chosen
        // directory for the duration of `startAccessingSecurityScopedResource`
        // — without this, deep scans, FSEvents watches, and Trash deletes
        // under that root can fail intermittently once the panel returns.
        if preAcquiredSecurityScope {
            securityScopedRootURL = root
        } else if root.startAccessingSecurityScopedResource() {
            securityScopedRootURL = root
        } else {
            log.info("No security-scoped access for \(root.path, privacy: .public); scan may be limited to entitlement-covered paths")
        }

        scanRootURL = root
        let scanner = DirectoryScanner()
        scanTask = Task { [weak self] in
            guard let self else { return }
            do {
                for try await event in await scanner.scan(root: root) {
                    try Task.checkCancellation()
                    self.handle(event)
                }
            } catch is CancellationError {
                // Consumer cancelled before/without a `.cancelled` event —
                // still settle UI into the cancelled state.
                self.handleConsumerCancellation()
            } catch {
                self.handle(.failed(error))
            }
        }
    }

    private func releaseSecurityScopedAccess() {
        securityScopedRootURL?.stopAccessingSecurityScopedResource()
        securityScopedRootURL = nil
    }

    /// Surfaces a Trash failure in the toolbar error slot — Delete used to
    /// fail silently, which is unacceptable for a destructive disk utility.
    func reportDeleteFailure(_ error: Error) {
        log.error("Trash failed: \(error.localizedDescription, privacy: .public)")
        errorMessage = "Couldn't move to Trash: \(error.localizedDescription)"
    }

    func clearErrorMessage() {
        errorMessage = nil
    }

    func cancelScan() {
        guard isScanning else { return }
        scanWasCancelled = true
        scanTask?.cancel()
        // `isScanning` flips false when `.cancelled` arrives (or via
        // `handleConsumerCancellation`) so the toolbar doesn't briefly claim
        // "completed" between cancel and the stream settling.
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
                self?.enqueueExternalChanges(changes)
            }
        }
    }

    private func stopWatchingForExternalChanges() {
        changeWatchTask?.cancel()
        changeWatchTask = nil
        changeWatcher?.stop()
        changeWatcher = nil
        externalChangeDrainTask?.cancel()
        externalChangeDrainTask = nil
        pendingExternalChanges = [:]
    }

    /// Merges a watcher batch into `pendingExternalChanges` and makes sure a
    /// drain is scheduled. Deliberately touches no `FileNode` itself: this
    /// runs for every batch the watch produces, and deleting a large folder
    /// outside the app produces a long run of them in quick succession —
    /// mostly siblings of each other. Collapsing them into one merged set
    /// first means the expensive part (resolving paths, re-summing ancestors,
    /// relaying out the treemap) happens once for the whole delete instead of
    /// once per batch.
    private func enqueueExternalChanges(_ changes: [ExternalChangeWatcher.PathChange]) {
        guard rootNode != nil else { return }
        for change in changes {
            pendingExternalChanges[change.path] = change.stillExists
        }
        scheduleExternalChangeDrain()
    }

    private func scheduleExternalChangeDrain() {
        guard externalChangeDrainTask == nil, !pendingExternalChanges.isEmpty else { return }
        externalChangeDrainTask = Task { [weak self] in
            try? await Task.sleep(for: Self.externalChangeCoalescingWindow)
            guard let self, !Task.isCancelled else { return }
            await self.drainPendingExternalChanges()
            // A cancellation means `stopWatchingForExternalChanges` already
            // reset this state — and may already have started a fresh watch
            // with a drain task of its own, which clearing the reference here
            // would orphan.
            guard !Task.isCancelled else { return }
            self.externalChangeDrainTask = nil
            // Anything the watch reported while that drain was running gets
            // its own settle window rather than being applied immediately —
            // a delete still in progress keeps refilling this, and each pass
            // costs a treemap relayout and an extension recompute.
            self.scheduleExternalChangeDrain()
        }
    }

    /// Applies pending changes in bounded chunks, yielding between them.
    /// Even fully batched, a single `rm -rf` can report hundreds of thousands
    /// of paths, and applying all of them in one main-actor turn would freeze
    /// the window for exactly as long as that takes. Chunking caps how long
    /// the main thread is held at a time; the tree just lands in a few
    /// successive passes instead of one.
    private func drainPendingExternalChanges() async {
        guard let rootNode else {
            pendingExternalChanges.removeAll()
            return
        }
        // One applier for the whole drain: its path/name caches are what make
        // a run of sibling deletions cheap, and the paths that share a
        // directory are precisely the ones that arrive together.
        var applier = ExternalChangeApplier(root: rootNode)
        while !pendingExternalChanges.isEmpty, !Task.isCancelled {
            let chunk: [ExternalChangeApplier.Change]
            if pendingExternalChanges.count <= Self.externalChangeChunkSize {
                chunk = pendingExternalChanges.map { .init(path: $0.key, stillExists: $0.value) }
                pendingExternalChanges.removeAll(keepingCapacity: true)
            } else {
                chunk = pendingExternalChanges.prefix(Self.externalChangeChunkSize)
                    .map { .init(path: $0.key, stillExists: $0.value) }
                for change in chunk {
                    pendingExternalChanges.removeValue(forKey: change.path)
                }
            }

            if !applier.apply(chunk).isEmpty {
                bumpGeneration()
            }
            if !pendingExternalChanges.isEmpty {
                await Task.yield()
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
            scanWasCancelled = false
            isLoadingTree = true
            awaitedVisualizationComponents = [.treemap, .extensionSummary]
            filesScanned = files
            foldersSkipped = skipped
            tccDeniedFolders = tccDenied
            lastScanDuration = duration
            currentPath = nil
            bumpGeneration(force: true)
            loadingGeneration = scanGeneration
            startWatchingForExternalChanges()
            // `isLoadingTree` flips back to false once both panes report
            // rendering this generation — see `treemapDidFinishRendering`/
            // `extensionSummaryDidFinishRendering`.

        case .cancelled(let duration, let files, let skipped, let tccDenied):
            settleCancelledScan(
                duration: duration,
                filesScanned: files,
                foldersSkipped: skipped,
                tccDeniedFolders: tccDenied
            )

        case .failed(let error):
            isScanning = false
            log.error("Scan failed: \(error.localizedDescription, privacy: .public)")
            errorMessage = error.localizedDescription
        }
    }

    /// When the consumer Task is cancelled without receiving `.cancelled`
    /// (race with stream teardown), mirror the cancelled settlement so the
    /// toolbar doesn't stick on "Scanning…".
    private func handleConsumerCancellation() {
        guard isScanning || scanWasCancelled else { return }
        settleCancelledScan(
            duration: lastScanDuration,
            filesScanned: filesScanned,
            foldersSkipped: foldersSkipped,
            tccDeniedFolders: tccDeniedFolders
        )
    }

    private func settleCancelledScan(
        duration: Duration?,
        filesScanned: Int,
        foldersSkipped: Int,
        tccDeniedFolders: Int
    ) {
        isScanning = false
        scanWasCancelled = true
        isLoadingTree = false
        awaitedVisualizationComponents = []
        self.filesScanned = filesScanned
        self.foldersSkipped = foldersSkipped
        self.tccDeniedFolders = tccDeniedFolders
        lastScanDuration = duration
        currentPath = nil
        bumpGeneration(force: true)
        // Keep the partial tree useful: watch for further external changes
        // under whatever was scanned before cancel.
        if rootNode != nil {
            startWatchingForExternalChanges()
        }
    }

    func dismissPermissionNudge() {
        isPermissionNudgeDismissed = true
    }

    func dismissPermissionNudgePermanently() {
        UserDefaults.standard.set(true, forKey: Self.fdaNudgeDontAskAgainKey)
        isPermissionNudgeDismissed = true
    }

    /// Signals that the scanned tree was mutated outside the normal scan
    /// pipeline — currently, `FileTreeView`'s own in-app Trash action. Bumps
    /// `scanGeneration` so the Treemap and Extension Summary panes (which
    /// only observe that counter, not `FileTreeView`'s internal state)
    /// recompute and pick up the change too.
    func notifyTreeMutated() {
        bumpGeneration(force: true)
    }

    /// Reported by `TreemapView.onRelayoutFinished` once its relayout has
    /// settled on `version`.
    func treemapDidFinishRendering(forGeneration version: Int) {
        markVisualizationRendered(.treemap, version: version)
    }

    /// Reported by `ExtensionSummaryView.onRecomputeFinished` once its
    /// recompute has settled on `version`.
    func extensionSummaryDidFinishRendering(forGeneration version: Int) {
        markVisualizationRendered(.extensionSummary, version: version)
    }

    /// Ignores a stale report left over from an interim mid-scan relayout
    /// (`isLoadingTree` is false then, since it only becomes true starting at
    /// `.finished`). Accepts any report at or beyond `loadingGeneration`
    /// rather than an exact `scanGeneration` match: a delete or an
    /// external-change bump landing in the load window advances
    /// `scanGeneration` past what the panes are settling on, and an `==`
    /// check would then reject every subsequent report and leave the
    /// "Loading tree…" spinner stuck forever. A pane that has rendered the
    /// load generation *or newer* has, by definition, drawn post-`.finished`
    /// content — which is exactly what this gate exists to confirm.
    private func markVisualizationRendered(_ component: VisualizationComponent, version: Int) {
        guard isLoadingTree, version >= loadingGeneration else { return }
        awaitedVisualizationComponents.remove(component)
        if awaitedVisualizationComponents.isEmpty {
            isLoadingTree = false
        }
    }

    private func bumpGeneration(force: Bool = false) {
        let now = ContinuousClock.now
        guard force || now - lastGenerationBump > Self.generationBumpInterval else {
            scheduleTrailingGenerationBump()
            return
        }
        pendingGenerationBumpTask?.cancel()
        pendingGenerationBumpTask = nil
        lastGenerationBump = now
        scanGeneration += 1
    }

    /// A bump the throttle swallowed isn't the same as one that didn't need
    /// to happen. If the change that asked for it turns out to be the *last*
    /// one — the final batch of an external delete, most obviously, since
    /// nothing bumps again once the filesystem goes quiet — the panes would
    /// keep showing pre-change data indefinitely. This guarantees the last
    /// change always lands, one throttle interval later at worst.
    private func scheduleTrailingGenerationBump() {
        guard pendingGenerationBumpTask == nil else { return }
        pendingGenerationBumpTask = Task { [weak self] in
            try? await Task.sleep(for: Self.generationBumpInterval)
            guard let self, !Task.isCancelled else { return }
            self.pendingGenerationBumpTask = nil
            self.bumpGeneration(force: true)
        }
    }
}
