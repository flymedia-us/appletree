import AppKit
import AppleTreeCore
import QuickLookUI
import SwiftUI

/// WizTree-style Tree View: an expandable, multi-column outline of the scan
/// result. Backed by `NSOutlineView` rather than SwiftUI's `List`/
/// `OutlineGroup` — see the project's implementation plan for why (lazy
/// per-row materialization matters at the row counts real directory trees
/// produce, and a first-class sortable multi-column outline has no SwiftUI
/// equivalent).
public struct FileTreeView: NSViewRepresentable {
    public let rootNode: FileNode?
    public var selection: SelectionModel
    /// A counter that changes whenever the (in-place-mutating) `rootNode`
    /// tree has new data. `FileNode` is a class, so simply passing the same
    /// `rootNode` reference again after mutating it doesn't reliably cause
    /// SwiftUI to notice a change — this value must come from a genuinely
    /// changing source (e.g. an `@Observable` counter incremented by the
    /// scan pipeline) so that constructing this view with a new value here
    /// is what actually drives `updateNSView` to re-run and reload.
    public var treeVersion: Int
    /// Whether a scan is currently in progress. Used only to detect the
    /// scanning→idle transition — see `updateNSView`'s doc comment on why
    /// that moment (and only that moment) needs a full reload.
    public var isScanning: Bool
    /// Called after this view's own Delete action marks a node removed
    /// (`FileNode.markRemoved()`) and updates its own rows. The Treemap and
    /// Extension Summary panes don't observe this view's internal state —
    /// they only react to `treeVersion` — so the app layer needs this signal
    /// to bump that counter and bring them back in sync too.
    public var onTreeMutated: (() -> Void)?
    /// When `true` (the public-release default), Delete / ⌘⌫ presents an
    /// `NSAlert` before calling `FileManager.trashItem`.
    public var confirmBeforeDelete: Bool
    /// Surfaces Trash failures to the app chrome — Delete used to fail
    /// silently, leaving the row unchanged with no explanation.
    public var onDeleteFailed: ((Error) -> Void)?
    /// Resolved light/dark scheme. AppKit outline views don't reliably
    /// redraw alternating rows / headers when SwiftUI's color scheme flips,
    /// so a change here triggers an appearance sync + `reloadData()`.
    public var colorScheme: ColorScheme

    public init(
        rootNode: FileNode?,
        selection: SelectionModel,
        treeVersion: Int,
        isScanning: Bool,
        confirmBeforeDelete: Bool = true,
        colorScheme: ColorScheme = .light,
        onTreeMutated: (() -> Void)? = nil,
        onDeleteFailed: ((Error) -> Void)? = nil
    ) {
        self.rootNode = rootNode
        self.selection = selection
        self.treeVersion = treeVersion
        self.isScanning = isScanning
        self.confirmBeforeDelete = confirmBeforeDelete
        self.colorScheme = colorScheme
        self.onTreeMutated = onTreeMutated
        self.onDeleteFailed = onDeleteFailed
    }

    public func makeNSView(context: Context) -> NSScrollView {
        let outlineView = DeletingOutlineView()
        outlineView.onDeleteShortcut = { [weak coordinator = context.coordinator] in
            coordinator?.deleteSelectedItem()
        }
        outlineView.onSpacebarPressed = { [weak coordinator = context.coordinator] in
            coordinator?.togglePreviewPanel()
        }
        outlineView.dataSource = context.coordinator
        outlineView.delegate = context.coordinator
        outlineView.usesAlternatingRowBackgroundColors = true
        outlineView.selectionHighlightStyle = .regular
        outlineView.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        outlineView.allowsColumnResizing = true
        outlineView.rowHeight = 20

        let folderColumn = NSTableColumn(identifier: .folderColumn)
        folderColumn.title = "Folder"
        folderColumn.minWidth = 160
        folderColumn.width = 260
        folderColumn.sortDescriptorPrototype = NSSortDescriptor(key: SortKey.name.rawValue, ascending: true)
        outlineView.addTableColumn(folderColumn)
        outlineView.outlineTableColumn = folderColumn

        let percentColumn = NSTableColumn(identifier: .percentColumn)
        percentColumn.title = "% of Parent"
        percentColumn.minWidth = 130
        percentColumn.width = 150
        percentColumn.maxWidth = 180
        percentColumn.sortDescriptorPrototype = NSSortDescriptor(key: SortKey.percentOfParent.rawValue, ascending: false)
        outlineView.addTableColumn(percentColumn)

        let sizeColumn = NSTableColumn(identifier: .sizeColumn)
        sizeColumn.title = "Size"
        sizeColumn.minWidth = 70
        sizeColumn.width = 90
        sizeColumn.sortDescriptorPrototype = NSSortDescriptor(key: SortKey.size.rawValue, ascending: false)
        outlineView.addTableColumn(sizeColumn)

        let logicalSizeColumn = NSTableColumn(identifier: .logicalSizeColumn)
        logicalSizeColumn.title = "Logical Size"
        logicalSizeColumn.minWidth = 80
        logicalSizeColumn.width = 100
        logicalSizeColumn.sortDescriptorPrototype = NSSortDescriptor(key: SortKey.logicalSize.rawValue, ascending: false)
        outlineView.addTableColumn(logicalSizeColumn)

        let filesColumn = NSTableColumn(identifier: .filesColumn)
        filesColumn.title = "Files"
        filesColumn.minWidth = 60
        filesColumn.width = 70
        filesColumn.sortDescriptorPrototype = NSSortDescriptor(key: SortKey.files.rawValue, ascending: false)
        outlineView.addTableColumn(filesColumn)

        let foldersColumn = NSTableColumn(identifier: .foldersColumn)
        foldersColumn.title = "Folders"
        foldersColumn.minWidth = 60
        foldersColumn.width = 70
        foldersColumn.sortDescriptorPrototype = NSSortDescriptor(key: SortKey.folders.rawValue, ascending: false)
        outlineView.addTableColumn(foldersColumn)

        let modifiedColumn = NSTableColumn(identifier: .modifiedColumn)
        modifiedColumn.title = "Modified"
        modifiedColumn.minWidth = 130
        modifiedColumn.width = 170
        modifiedColumn.sortDescriptorPrototype = NSSortDescriptor(key: SortKey.modified.rawValue, ascending: false)
        outlineView.addTableColumn(modifiedColumn)

        // Explicit default sort (Size descending) rather than relying on the
        // implicit "natural" scan order — this is what lets the Size column
        // show its header sort indicator from the start instead of no column
        // appearing active until the user clicks one. AppKit's own header
        // comment for `sortDescriptors` only promises its setter "may" call
        // the delegate back (confirmed unreliable in practice: the initial
        // sort silently didn't take effect until the user manually toggled
        // the Size column), so the delegate callback is invoked directly
        // instead of assuming the property setter's side effect fires.
        let defaultSort = sizeColumn.sortDescriptorPrototype!
        outlineView.sortDescriptors = [defaultSort]
        context.coordinator.outlineView(outlineView, sortDescriptorsDidChange: [])

        outlineView.target = context.coordinator
        outlineView.doubleAction = #selector(Coordinator.handleDoubleClick(_:))
        outlineView.menu = context.coordinator.makeContextMenu()

        let scrollView = NSScrollView()
        scrollView.documentView = outlineView
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.autohidesScrollers = true

        context.coordinator.outlineView = outlineView
        return scrollView
    }

    public func updateNSView(_ scrollView: NSScrollView, context: Context) {
        let coordinator = context.coordinator
        guard let outlineView = coordinator.outlineView else { return }

        coordinator.onTreeMutated = onTreeMutated
        coordinator.onDeleteFailed = onDeleteFailed
        coordinator.confirmBeforeDelete = confirmBeforeDelete

        let appearanceChanged = coordinator.lastColorScheme != colorScheme
        if appearanceChanged {
            coordinator.lastColorScheme = colorScheme
            let appearance = NSAppearance(named: colorScheme == .dark ? .darkAqua : .aqua)
            scrollView.appearance = appearance
            outlineView.appearance = appearance
            // Alternating-row backgrounds, headers, and recycled cells keep
            // resolving `NSColor` against the previous appearance until a
            // full reload forces them to redraw under the new one.
            outlineView.reloadData()
            if let rootNode, outlineView.numberOfRows > 0 {
                outlineView.expandItem(rootNode)
            }
        }

        // Externally-deleted rows need no bookkeeping of their own here: the
        // watch marks the node itself (`FileNode.markRemoved()`), row
        // rendering reads that flag directly, and the same change bumps
        // `treeVersion`, whose `reloadItem(rootNode, reloadChildren: true)`
        // below repaints every materialized row.
        //
        // This used to mirror the app's whole set of externally-deleted node
        // IDs, diff it against the previous set, and `reloadItem` each
        // difference — with the node behind each ID found by a *full
        // depth-first walk of the tree*. Deleting a large folder outside the
        // app made that walk run once per deleted file, over a set growing
        // to that same size, comparing and copying the set on every SwiftUI
        // update in between: the single largest contributor to the app
        // locking up for minutes afterwards.
        let isNewRoot = coordinator.rootNode !== rootNode
        if isNewRoot {
            coordinator.rootNode = rootNode
            coordinator.deletedNodeIDs.removeAll()
        }

        // A directory's size is only final once *its own* `finalizeAsDirectory()`
        // has run (during an active scan it reads 0/partial), so a sort by
        // Size only reflects real values once scanning ends. `reloadItem`
        // below doesn't reliably re-order already-materialized rows whose
        // child *count* hasn't changed since the last reload (only their
        // now-final sizes have) — only `reloadData()` is guaranteed to pick
        // up the corrected order, which is exactly what a manual header
        // re-click was doing. So: cheap incremental reloads while scanning,
        // one guaranteed full reload right when it finishes.
        let justFinishedScanning = coordinator.lastIsScanning && !isScanning
        coordinator.lastIsScanning = isScanning

        if isNewRoot || coordinator.lastTreeVersion != treeVersion {
            coordinator.lastTreeVersion = treeVersion
            coordinator.invalidateSortCache()
            if isNewRoot {
                // A brand new tree invalidates row/parent-child bookkeeping
                // wholesale, so a full reload is the only correct option here.
                outlineView.reloadData()
                coordinator.lastFullResort = .now
                if let rootNode {
                    outlineView.expandItem(rootNode)
                }
            } else if let rootNode {
                if justFinishedScanning {
                    outlineView.reloadData()
                    coordinator.lastFullResort = .now
                } else if isScanning, ContinuousClock.now - coordinator.lastFullResort > .seconds(1) {
                    // Periodically re-sort during an active scan too, not just
                    // once at the end. A directory's size (and so its place in
                    // the default size-descending order) keeps changing as the
                    // scan progresses, but `reloadItem` below never re-orders
                    // already-materialized rows — only their cell values —
                    // so without this the Tree View's ordering would visibly
                    // stall for the scan's entire duration while the Extension
                    // Summary pane (which recomputes and re-sorts fresh every
                    // pass) keeps reflecting reality. Throttled to once a
                    // second rather than every ~100ms `treeVersion` bump —
                    // that was tried and was disruptive enough to interfere
                    // with the user's own disclosure-triangle clicks (see the
                    // `reloadItem` branch below).
                    outlineView.reloadData()
                    coordinator.lastFullResort = .now
                } else if !appearanceChanged {
                    // An in-progress scan bumps `treeVersion` roughly every
                    // 100ms; `reloadData()` on every one of those was disruptive
                    // enough (a live scan of a large tree fires this dozens of
                    // times) to interfere with the user's own disclosure-triangle
                    // clicks. `reloadItem(reloadChildren:)` targets just the
                    // subtree that changed and, per AppKit's documented behavior,
                    // preserves each item's expansion/selection state by
                    // identity — `FileNode` instances are mutated in place and
                    // never recreated, so identity is stable across reloads.
                    // Skip when we already did a full reload for an appearance
                    // flip above — a second pass the same update is redundant.
                    outlineView.reloadItem(rootNode, reloadChildren: true)
                }
            } else {
                outlineView.reloadData()
                coordinator.lastFullResort = .now
            }
        }

        coordinator.syncSelectionFromModel()
    }

    public func makeCoordinator() -> Coordinator {
        Coordinator(selection: selection)
    }

    /// Which field drives the outline's current sort. `nil` means the
    /// natural scan order (children pre-sorted descending by `displaySize`
    /// in `FileNode.finalizeAsDirectory`) — the default, matching the
    /// treemap's own ordering.
    enum SortKey: String {
        case name, percentOfParent, size, logicalSize, files, folders, modified
    }

    @MainActor
    // `@preconcurrency` on the QuickLook conformances: `QLPreviewPanelDataSource`/
    // `QLPreviewPanelDelegate` are old Objective-C protocols imported without
    // actor isolation, so adopting them on this `@MainActor` class is flagged
    // as a potential data race under strict concurrency — this is the
    // documented escape hatch for that exact "isolated class adopting a
    // legacy unisolated protocol" situation.
    public final class Coordinator: NSObject, NSOutlineViewDataSource, NSOutlineViewDelegate,
        @preconcurrency QLPreviewPanelDataSource, @preconcurrency QLPreviewPanelDelegate {
        var rootNode: FileNode?
        var lastTreeVersion = -1
        var lastIsScanning = false
        var lastColorScheme: ColorScheme?
        /// Throttle for the periodic full re-sort during an active scan —
        /// see `updateNSView`'s doc comment on why this exists alongside
        /// the far more frequent `reloadItem` path.
        var lastFullResort: ContinuousClock.Instant = .now
        weak var outlineView: NSOutlineView?
        let selection: SelectionModel
        var onTreeMutated: (() -> Void)?
        var onDeleteFailed: ((Error) -> Void)?
        var confirmBeforeDelete = true
        private var isSyncingSelection = false

        private var sortKey: SortKey?
        private var sortAscending = false
        private var sortedChildrenCache: [ObjectIdentifier: [FileNode]] = [:]

        /// Items moved to the Trash this session — tracked here (not on
        /// `FileNode` itself) purely for the strikethrough presentation;
        /// `FileNode` stays a framework-free data model. Reset whenever the
        /// root changes (a fresh scan has nothing to mark deleted).
        var deletedNodeIDs: Set<FileNode.ID> = []

        init(selection: SelectionModel) {
            self.selection = selection
        }

        // MARK: NSOutlineViewDataSource

        public func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
            let node = (item as? FileNode) ?? rootNode
            return node?.children.count ?? 0
        }

        public func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
            let node = (item as? FileNode) ?? rootNode
            return node.map { sortedChildren(of: $0)[index] } as Any
        }

        public func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
            guard let node = item as? FileNode else { return false }
            return node.isDirectory && !node.children.isEmpty
        }

        public func outlineView(_ outlineView: NSOutlineView, sortDescriptorsDidChange oldDescriptors: [NSSortDescriptor]) {
            if let descriptor = outlineView.sortDescriptors.first, let key = descriptor.key.flatMap(SortKey.init) {
                sortKey = key
                sortAscending = descriptor.ascending
            } else {
                sortKey = nil
            }
            updateSortIndicators(outlineView)
            invalidateSortCache()
            outlineView.reloadData()
        }

        // MARK: NSOutlineViewDelegate

        public func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
            guard let node = item as? FileNode, let columnID = tableColumn?.identifier else { return nil }
            // `isRemovedOrHasRemovedAncestor` covers both sources of removal
            // — this view's own Trash action and the external-change watch,
            // which both set the model flag — and, unlike a flat set of node
            // IDs, correctly strikes through the contents of a deleted folder
            // the user expands into. Only the handful of rows actually being
            // rendered pay for its walk up the parent chain.
            let isDeleted = deletedNodeIDs.contains(node.id) || node.isRemovedOrHasRemovedAncestor

            switch columnID {
            case .folderColumn:
                return FolderCellView.makeOrReuse(in: outlineView, node: node, isDeleted: isDeleted)
            case .percentColumn:
                return PercentOfParentCellView.makeOrReuse(in: outlineView, fraction: node.fractionOfParent, isDeleted: isDeleted)
            case .sizeColumn:
                return TextCellView.makeOrReuse(
                    in: outlineView,
                    identifier: .sizeColumn,
                    text: SizeFormatting.string(for: node.displaySize),
                    alignment: .right,
                    isDeleted: isDeleted
                )
            case .logicalSizeColumn:
                return TextCellView.makeOrReuse(
                    in: outlineView,
                    identifier: .logicalSizeColumn,
                    text: SizeFormatting.string(for: node.logicalSize),
                    alignment: .right,
                    isDeleted: isDeleted
                )
            case .filesColumn:
                return TextCellView.makeOrReuse(
                    in: outlineView,
                    identifier: .filesColumn,
                    // A file has no children to count — 0 there would read
                    // as real data ("this file contains 0 files") rather
                    // than "not applicable", so leave it blank.
                    text: node.isDirectory ? SizeFormatting.countString(for: node.fileCount) : "",
                    alignment: .right,
                    isDeleted: isDeleted
                )
            case .foldersColumn:
                return TextCellView.makeOrReuse(
                    in: outlineView,
                    identifier: .foldersColumn,
                    text: node.isDirectory ? SizeFormatting.countString(for: node.folderCount) : "",
                    alignment: .right,
                    isDeleted: isDeleted
                )
            case .modifiedColumn:
                return TextCellView.makeOrReuse(
                    in: outlineView,
                    identifier: .modifiedColumn,
                    text: SizeFormatting.dateString(for: node.modificationDate),
                    alignment: .left,
                    isDeleted: isDeleted
                )
            default:
                return nil
            }
        }

        public func outlineViewSelectionDidChange(_ notification: Notification) {
            guard !isSyncingSelection, let outlineView else { return }
            let row = outlineView.selectedRow
            let node = row >= 0 ? outlineView.item(atRow: row) as? FileNode : nil
            selection.selectedNode = node

            // Mirrors Finder: while Quick Look is open, arrowing to a new
            // selection updates the preview in place rather than requiring
            // the user to close and reopen it.
            if QLPreviewPanel.sharedPreviewPanelExists(), let panel = QLPreviewPanel.shared(), panel.isVisible {
                panel.reloadData()
            }
        }

        // MARK: Double-click (open file / toggle folder)

        @objc func handleDoubleClick(_ sender: NSOutlineView) {
            let row = sender.clickedRow
            guard row >= 0, let node = sender.item(atRow: row) as? FileNode else { return }
            if node.isDirectory {
                if sender.isItemExpanded(node) {
                    sender.collapseItem(node)
                } else {
                    sender.expandItem(node)
                }
            } else {
                NSWorkspace.shared.open(URL(fileURLWithPath: node.path))
            }
        }

        // MARK: Quick Look (Space bar)

        /// Toggles the shared Quick Look panel for the current selection, the
        /// same Space-bar behavior Finder's list view has. `QLPreviewPanel`
        /// normally finds its controller by searching the responder chain,
        /// but since we drive it directly from our own key-event handling
        /// rather than the standard `toggleQuickLookPanel:` action message,
        /// wiring `dataSource`/`delegate` ourselves here is sufficient — no
        /// need to also implement the `acceptsPreviewPanelControl` family.
        func togglePreviewPanel() {
            guard let outlineView, outlineView.selectedRow >= 0 else { return }
            if QLPreviewPanel.sharedPreviewPanelExists(), let visiblePanel = QLPreviewPanel.shared(), visiblePanel.isVisible {
                visiblePanel.orderOut(nil)
                return
            }
            guard let panel = QLPreviewPanel.shared() else { return }
            panel.dataSource = self
            panel.delegate = self
            panel.makeKeyAndOrderFront(nil)
        }

        public func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int {
            guard let outlineView, outlineView.selectedRow >= 0 else { return 0 }
            return 1
        }

        public func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> QLPreviewItem! {
            guard let outlineView, outlineView.selectedRow >= 0,
                  let node = outlineView.item(atRow: outlineView.selectedRow) as? FileNode else { return nil }
            return NSURL(fileURLWithPath: node.path)
        }

        /// Gives the panel a rect to zoom from/into (matching Finder's
        /// animation) instead of a plain fade.
        public func previewPanel(_ panel: QLPreviewPanel!, sourceFrameOnScreenFor item: QLPreviewItem!) -> NSRect {
            guard let outlineView, outlineView.selectedRow >= 0, let window = outlineView.window else { return .zero }
            let rowRectInWindow = outlineView.convert(outlineView.rect(ofRow: outlineView.selectedRow), to: nil)
            return window.convertToScreen(rowRectInWindow)
        }

        // MARK: Context menu (Explore Folder / Copy Path / Delete)

        func makeContextMenu() -> NSMenu {
            let menu = NSMenu()

            let explore = NSMenuItem(title: "Explore Folder", action: #selector(exploreFolder(_:)), keyEquivalent: "")
            explore.target = self
            menu.addItem(explore)

            let copyPath = NSMenuItem(title: "Copy Path", action: #selector(copyPath(_:)), keyEquivalent: "")
            copyPath.target = self
            menu.addItem(copyPath)

            menu.addItem(.separator())

            let delete = NSMenuItem(title: "Delete", action: #selector(deleteFromContextMenu(_:)), keyEquivalent: "")
            delete.target = self
            menu.addItem(delete)

            return menu
        }

        /// The row a contextual-menu click landed on — valid while the menu
        /// built by `makeContextMenu()` is open/being validated, per
        /// `NSTableView.clickedRow`'s documented behavior.
        private func contextMenuNode() -> FileNode? {
            guard let outlineView, outlineView.clickedRow >= 0 else { return nil }
            return outlineView.item(atRow: outlineView.clickedRow) as? FileNode
        }

        @objc private func exploreFolder(_ sender: NSMenuItem) {
            guard let node = contextMenuNode() else { return }
            let folderURL = node.isDirectory
                ? URL(fileURLWithPath: node.path)
                : URL(fileURLWithPath: node.path).deletingLastPathComponent()
            NSWorkspace.shared.open(folderURL)
        }

        @objc private func copyPath(_ sender: NSMenuItem) {
            guard let node = contextMenuNode() else { return }
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(node.path, forType: .string)
        }

        // MARK: Delete (move to Trash)

        @objc private func deleteFromContextMenu(_ sender: NSMenuItem) {
            guard let node = contextMenuNode() else { return }
            delete(node)
        }

        /// Entry point for the Cmd+Backspace / Delete-key shortcut — acts on
        /// the current selection rather than whatever was last right-clicked.
        func deleteSelectedItem() {
            guard let outlineView, outlineView.selectedRow >= 0,
                  let node = outlineView.item(atRow: outlineView.selectedRow) as? FileNode else { return }
            delete(node)
        }

        private func delete(_ node: FileNode) {
            guard !deletedNodeIDs.contains(node.id) else { return }
            if confirmBeforeDelete, !confirmDelete(of: node) { return }

            let path = node.path
            // Must hop back to the main actor for outline updates and the
            // app-chrome error callback — Trash itself runs off-main.
            Task { @MainActor in
                do {
                    // `FileManager.trashItem` is a blocking syscall — usually
                    // a fast rename, but can involve a real copy for a large
                    // item on a different volume than the Trash, so it's run
                    // off the main actor rather than freezing the UI for it.
                    try await Task.detached(priority: .userInitiated) {
                        try FileManager.default.trashItem(at: URL(fileURLWithPath: path), resultingItemURL: nil)
                    }.value
                    markDeleted(node)
                } catch {
                    // Left unmarked/un-struck-through on failure (e.g.
                    // permission denied, already moved externally) — the row
                    // stays as it was, and the app chrome shows why.
                    onDeleteFailed?(error)
                }
            }
        }

        /// Finder-style confirmation before a destructive Trash move. Returns
        /// `true` only when the user explicitly confirms.
        private func confirmDelete(of node: FileNode) -> Bool {
            let alert = NSAlert()
            alert.messageText = "Move “\(node.name)” to the Trash?"
            alert.informativeText = Self.deleteConfirmationDetail(for: node)
            alert.alertStyle = .warning
            alert.addButton(withTitle: "Move to Trash")
            alert.addButton(withTitle: "Cancel")
            return alert.runModal() == .alertFirstButtonReturn
        }

        /// Spells out *how much* is about to be trashed, not just what it's
        /// called. The whole point of this app is finding large folders to
        /// remove, so the number that actually informs the decision — total
        /// size, and how many files are inside a directory — belongs in the
        /// confirmation rather than a bare "this folder will be moved."
        private static func deleteConfirmationDetail(for node: FileNode) -> String {
            let size = SizeFormatting.string(for: node.displaySize)
            let restoreNote = "You can restore it from the Trash later."

            guard node.isDirectory else {
                return "This file is \(size). \(restoreNote)"
            }

            let files = node.fileCount
            let folders = node.folderCount
            var contents = "\(SizeFormatting.countString(for: files)) file\(files == 1 ? "" : "s")"
            if folders > 0 {
                contents += " in \(SizeFormatting.countString(for: folders)) folder\(folders == 1 ? "" : "s")"
            }
            return "This folder contains \(contents), totaling \(size). \(restoreNote)"
        }

        private func markDeleted(_ node: FileNode) {
            deletedNodeIDs.insert(node.id)
            guard let outlineView else { return }
            // Recomputes every ancestor's size/count so the Tree View's own
            // parent rows, the treemap, and the extension breakdown all
            // reflect the removal immediately rather than only after a
            // rescan — see `FileNode.markRemoved()`.
            node.markRemoved()
            outlineView.reloadItem(node)
            // `reloadItem` above only repaints `node`'s own row; every
            // ancestor's Size/% of Parent/Files/Folders cells just changed
            // too (that's what `markRemoved()` recomputed) and need their
            // own repaint, or they'd keep showing pre-removal totals until
            // some unrelated reload happened to touch them.
            var ancestor = node.parent
            while let current = ancestor {
                outlineView.reloadItem(current)
                ancestor = current.parent
            }
            onTreeMutated?()
        }

        // MARK: Sorting

        func invalidateSortCache() {
            sortedChildrenCache.removeAll()
        }

        /// Draws the ascending/descending arrow on whichever column drives
        /// the current sort (`NSTableView` toggles `sortDescriptors` on
        /// header clicks by itself, but leaves indicator-image/highlight
        /// bookkeeping to the delegate).
        private func updateSortIndicators(_ outlineView: NSOutlineView) {
            for column in outlineView.tableColumns {
                outlineView.setIndicatorImage(nil, in: column)
            }
            guard let sortKey else {
                outlineView.highlightedTableColumn = nil
                return
            }
            let identifierForKey: [SortKey: NSUserInterfaceItemIdentifier] = [
                .name: .folderColumn, .percentOfParent: .percentColumn, .size: .sizeColumn,
                .logicalSize: .logicalSizeColumn, .files: .filesColumn, .folders: .foldersColumn,
                .modified: .modifiedColumn
            ]
            guard let identifier = identifierForKey[sortKey],
                  let column = outlineView.tableColumns.first(where: { $0.identifier == identifier }) else { return }
            let imageName = sortAscending ? "NSAscendingSortIndicator" : "NSDescendingSortIndicator"
            outlineView.setIndicatorImage(NSImage(named: imageName), in: column)
            outlineView.highlightedTableColumn = column
        }

        /// `node.children` in the outline's current display order: the
        /// natural (displaySize-descending) scan order by default, or a
        /// column-driven sort once the user has clicked a header. Memoized
        /// per node for the lifetime of the current sort/tree generation —
        /// `NSOutlineView` queries `child:ofItem:` once per row, and
        /// re-sorting a large sibling array on every single index query
        /// would be O(n² log n) over a full expansion.
        private func sortedChildren(of node: FileNode) -> [FileNode] {
            guard let sortKey else { return node.children }
            if let cached = sortedChildrenCache[node.id] { return cached }

            let ascending = sortAscending
            let sorted = node.children.sorted { a, b in
                let primary = Self.compare(a, b, key: sortKey)
                if primary != .orderedSame {
                    return ascending ? primary == .orderedAscending : primary == .orderedDescending
                }
                return a.name.localizedStandardCompare(b.name) == .orderedAscending
            }
            sortedChildrenCache[node.id] = sorted
            return sorted
        }

        private static func compare(_ a: FileNode, _ b: FileNode, key: SortKey) -> ComparisonResult {
            switch key {
            case .name: return a.name.localizedStandardCompare(b.name)
            case .percentOfParent: return numericCompare(a.fractionOfParent, b.fractionOfParent)
            case .size: return numericCompare(a.displaySize, b.displaySize)
            case .logicalSize: return numericCompare(a.logicalSize, b.logicalSize)
            case .files: return numericCompare(a.fileCount, b.fileCount)
            case .folders: return numericCompare(a.folderCount, b.folderCount)
            case .modified:
                return numericCompare(a.modificationDate ?? .distantPast, b.modificationDate ?? .distantPast)
            }
        }

        private static func numericCompare<T: Comparable>(_ a: T, _ b: T) -> ComparisonResult {
            if a < b { return .orderedAscending }
            if a > b { return .orderedDescending }
            return .orderedSame
        }

        // MARK: Selection sync (treemap -> tree)

        func syncSelectionFromModel() {
            guard let outlineView else { return }
            // The model stores the resolved node directly, so the tree can
            // pick it up by reference — no by-ID full-tree walk needed on
            // every treemap tap (the nodes are shared across panes).
            let target = selection.selectedNode
            let currentRow = outlineView.selectedRow
            let currentSelection = currentRow >= 0 ? outlineView.item(atRow: currentRow) as? FileNode : nil
            guard currentSelection !== target else { return }
            guard let target else { return }

            isSyncingSelection = true
            defer { isSyncingSelection = false }

            var ancestors: [FileNode] = []
            var current = target.parent
            while let node = current {
                ancestors.append(node)
                current = node.parent
            }
            for ancestor in ancestors.reversed() {
                outlineView.expandItem(ancestor)
            }

            let row = outlineView.row(forItem: target)
            guard row >= 0 else { return }
            outlineView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
            outlineView.scrollRowToVisible(row)
        }
    }
}

private extension NSUserInterfaceItemIdentifier {
    static let folderColumn = NSUserInterfaceItemIdentifier("folder")
    static let percentColumn = NSUserInterfaceItemIdentifier("percentOfParent")
    static let sizeColumn = NSUserInterfaceItemIdentifier("size")
    static let logicalSizeColumn = NSUserInterfaceItemIdentifier("logicalSize")
    static let filesColumn = NSUserInterfaceItemIdentifier("files")
    static let foldersColumn = NSUserInterfaceItemIdentifier("folders")
    static let modifiedColumn = NSUserInterfaceItemIdentifier("modified")
}

/// Adds Cmd+Backspace / Delete-key handling for "move to Trash", and Space
/// for "toggle Quick Look" — Finder's two standard file-list shortcuts.
/// Plain `NSOutlineView` has neither built in (nor does an `NSMenuItem`
/// `keyEquivalent`, which only fires via the menu bar/a window's main menu,
/// not a context menu that isn't currently open), so both key events are
/// intercepted directly instead.
private final class DeletingOutlineView: NSOutlineView {
    var onDeleteShortcut: (() -> Void)?
    var onSpacebarPressed: (() -> Void)?

    override func keyDown(with event: NSEvent) {
        if Self.isDeleteShortcut(event) {
            onDeleteShortcut?()
            return
        }
        if event.keyCode == 49, event.charactersIgnoringModifiers == " " { // Space
            onSpacebarPressed?()
            return
        }
        super.keyDown(with: event)
    }

    private static func isDeleteShortcut(_ event: NSEvent) -> Bool {
        switch event.keyCode {
        case 51: // Backspace/Delete key
            return event.modifierFlags.contains(.command)
        case 117: // Forward Delete (labeled "Delete" on keyboards that have both)
            return true
        default:
            return false
        }
    }
}
