import AppKit
import AppleTreeCore
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

    public init(rootNode: FileNode?, selection: SelectionModel, treeVersion: Int, isScanning: Bool) {
        self.rootNode = rootNode
        self.selection = selection
        self.treeVersion = treeVersion
        self.isScanning = isScanning
    }

    public func makeNSView(context: Context) -> NSScrollView {
        let outlineView = NSOutlineView()
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

        let isNewRoot = coordinator.rootNode !== rootNode
        if isNewRoot {
            coordinator.rootNode = rootNode
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
                if let rootNode {
                    outlineView.expandItem(rootNode)
                }
            } else if let rootNode {
                if justFinishedScanning {
                    outlineView.reloadData()
                } else {
                    // An in-progress scan bumps `treeVersion` roughly every
                    // 100ms; `reloadData()` on every one of those was disruptive
                    // enough (a live scan of a large tree fires this dozens of
                    // times) to interfere with the user's own disclosure-triangle
                    // clicks. `reloadItem(reloadChildren:)` targets just the
                    // subtree that changed and, per AppKit's documented behavior,
                    // preserves each item's expansion/selection state by
                    // identity — `FileNode` instances are mutated in place and
                    // never recreated, so identity is stable across reloads.
                    outlineView.reloadItem(rootNode, reloadChildren: true)
                }
            } else {
                outlineView.reloadData()
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
    public final class Coordinator: NSObject, NSOutlineViewDataSource, NSOutlineViewDelegate {
        var rootNode: FileNode?
        var lastTreeVersion = -1
        var lastIsScanning = false
        weak var outlineView: NSOutlineView?
        let selection: SelectionModel
        private var isSyncingSelection = false

        private var sortKey: SortKey?
        private var sortAscending = false
        private var sortedChildrenCache: [ObjectIdentifier: [FileNode]] = [:]

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

            switch columnID {
            case .folderColumn:
                return FolderCellView.makeOrReuse(in: outlineView, node: node)
            case .percentColumn:
                return PercentOfParentCellView.makeOrReuse(in: outlineView, fraction: node.fractionOfParent)
            case .sizeColumn:
                return TextCellView.makeOrReuse(
                    in: outlineView,
                    identifier: .sizeColumn,
                    text: SizeFormatting.string(for: node.displaySize),
                    alignment: .right
                )
            case .logicalSizeColumn:
                return TextCellView.makeOrReuse(
                    in: outlineView,
                    identifier: .logicalSizeColumn,
                    text: SizeFormatting.string(for: node.logicalSize),
                    alignment: .right
                )
            case .filesColumn:
                return TextCellView.makeOrReuse(
                    in: outlineView,
                    identifier: .filesColumn,
                    text: SizeFormatting.countString(for: node.fileCount),
                    alignment: .right
                )
            case .foldersColumn:
                return TextCellView.makeOrReuse(
                    in: outlineView,
                    identifier: .foldersColumn,
                    text: SizeFormatting.countString(for: node.folderCount),
                    alignment: .right
                )
            case .modifiedColumn:
                return TextCellView.makeOrReuse(
                    in: outlineView,
                    identifier: .modifiedColumn,
                    text: SizeFormatting.dateString(for: node.modificationDate),
                    alignment: .left
                )
            default:
                return nil
            }
        }

        public func outlineViewSelectionDidChange(_ notification: Notification) {
            guard !isSyncingSelection, let outlineView else { return }
            let row = outlineView.selectedRow
            let node = row >= 0 ? outlineView.item(atRow: row) as? FileNode : nil
            selection.selectedNodeID = node?.id
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

        // MARK: Context menu (Explore Folder / Copy Path)

        func makeContextMenu() -> NSMenu {
            let menu = NSMenu()

            let explore = NSMenuItem(title: "Explore Folder", action: #selector(exploreFolder(_:)), keyEquivalent: "")
            explore.target = self
            menu.addItem(explore)

            let copyPath = NSMenuItem(title: "Copy Path", action: #selector(copyPath(_:)), keyEquivalent: "")
            copyPath.target = self
            menu.addItem(copyPath)

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
            let targetID = selection.selectedNodeID
            let currentRow = outlineView.selectedRow
            let currentID = currentRow >= 0 ? (outlineView.item(atRow: currentRow) as? FileNode)?.id : nil
            guard currentID != targetID else { return }
            guard let targetID, let target = findNode(withID: targetID, in: rootNode) else { return }

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

        private func findNode(withID id: FileNode.ID, in node: FileNode?) -> FileNode? {
            guard let node else { return nil }
            if node.id == id { return node }
            for child in node.children {
                if let found = findNode(withID: id, in: child) { return found }
            }
            return nil
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
