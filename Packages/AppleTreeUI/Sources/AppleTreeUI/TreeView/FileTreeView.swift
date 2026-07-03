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

    public init(rootNode: FileNode?, selection: SelectionModel, treeVersion: Int) {
        self.rootNode = rootNode
        self.selection = selection
        self.treeVersion = treeVersion
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
        folderColumn.width = 320
        outlineView.addTableColumn(folderColumn)
        outlineView.outlineTableColumn = folderColumn

        let percentColumn = NSTableColumn(identifier: .percentColumn)
        percentColumn.title = "% of Parent"
        percentColumn.minWidth = 130
        percentColumn.width = 150
        percentColumn.maxWidth = 180
        outlineView.addTableColumn(percentColumn)

        let sizeColumn = NSTableColumn(identifier: .sizeColumn)
        sizeColumn.title = "Size"
        sizeColumn.minWidth = 70
        sizeColumn.width = 90
        outlineView.addTableColumn(sizeColumn)

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

        if isNewRoot || coordinator.lastTreeVersion != treeVersion {
            coordinator.lastTreeVersion = treeVersion
            // A full reload is the simplest correct behavior for v1; targeted
            // reloadItem calls are a fast-follow if this proves too slow on
            // very large in-progress scans.
            outlineView.reloadData()
            if isNewRoot, let rootNode {
                outlineView.expandItem(rootNode)
            }
        }

        coordinator.syncSelectionFromModel()
    }

    public func makeCoordinator() -> Coordinator {
        Coordinator(selection: selection)
    }

    @MainActor
    public final class Coordinator: NSObject, NSOutlineViewDataSource, NSOutlineViewDelegate {
        var rootNode: FileNode?
        var lastTreeVersion = -1
        weak var outlineView: NSOutlineView?
        let selection: SelectionModel
        private var isSyncingSelection = false

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
            return node?.children[index] as Any
        }

        public func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
            guard let node = item as? FileNode else { return false }
            return node.isDirectory && !node.children.isEmpty
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
                    text: SizeFormatting.string(for: node.logicalSize),
                    alignment: .right
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
}
