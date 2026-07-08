import AppKit
import AppleTreeCore
import SwiftUI

/// WizTree-style Extension List: a flat, scrollable breakdown of every file
/// extension across the whole scan (independent of Tree View position) —
/// color swatch, Extension, File Type, Percent, Size, Files. Backed by
/// `NSTableView` for the same reasons `FileTreeView` uses `NSOutlineView`:
/// cheap per-row recycling at real scan row counts.
public struct ExtensionSummaryView: NSViewRepresentable {
    public let rootNode: FileNode?
    /// See `FileTreeView.treeVersion`'s doc comment — same rationale applies
    /// here: this view must observe a genuinely-changing value to notice
    /// in-place mutations of the (class-typed) `rootNode` tree.
    public var treeVersion: Int
    /// Called once this view's extension breakdown has fully settled for a
    /// given `treeVersion`, passing back the version that just finished —
    /// see `TreemapView.onRelayoutFinished`'s doc comment for the identical
    /// rationale (this recompute is just as debounced/backgrounded, and can
    /// finish well after `treeVersion` itself changes).
    public var onRecomputeFinished: ((Int) -> Void)?

    public init(rootNode: FileNode?, treeVersion: Int, onRecomputeFinished: ((Int) -> Void)? = nil) {
        self.rootNode = rootNode
        self.treeVersion = treeVersion
        self.onRecomputeFinished = onRecomputeFinished
    }

    /// Extension rows are ranked by size and only this many get a distinct
    /// color; the rest share `ExtensionColor.unrankedColor` so the color
    /// column stays legible instead of assigning hundreds of poorly
    /// separated hues.
    static let topColoredCount = 12

    public func makeNSView(context: Context) -> NSScrollView {
        let tableView = NSTableView()
        tableView.dataSource = context.coordinator
        tableView.delegate = context.coordinator
        tableView.usesAlternatingRowBackgroundColors = true
        tableView.rowHeight = 20
        tableView.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        tableView.allowsColumnResizing = true

        let colorColumn = NSTableColumn(identifier: .colorColumn)
        colorColumn.title = ""
        colorColumn.minWidth = 20
        colorColumn.width = 24
        colorColumn.maxWidth = 28
        colorColumn.resizingMask = []
        tableView.addTableColumn(colorColumn)

        let extensionColumn = NSTableColumn(identifier: .extensionColumn)
        extensionColumn.title = "Extension"
        extensionColumn.minWidth = 60
        extensionColumn.width = 80
        extensionColumn.sortDescriptorPrototype = NSSortDescriptor(key: SortKey.extensionName.rawValue, ascending: true)
        tableView.addTableColumn(extensionColumn)

        let fileTypeColumn = NSTableColumn(identifier: .fileTypeColumn)
        fileTypeColumn.title = "File Type"
        fileTypeColumn.minWidth = 100
        fileTypeColumn.width = 150
        fileTypeColumn.sortDescriptorPrototype = NSSortDescriptor(key: SortKey.fileType.rawValue, ascending: true)
        tableView.addTableColumn(fileTypeColumn)

        let percentColumn = NSTableColumn(identifier: .percentColumn)
        percentColumn.title = "Percent"
        percentColumn.minWidth = 130
        percentColumn.width = 150
        percentColumn.maxWidth = 180
        percentColumn.sortDescriptorPrototype = NSSortDescriptor(key: SortKey.percent.rawValue, ascending: false)
        tableView.addTableColumn(percentColumn)

        let sizeColumn = NSTableColumn(identifier: .sizeColumn)
        sizeColumn.title = "Size"
        sizeColumn.minWidth = 70
        sizeColumn.width = 90
        sizeColumn.sortDescriptorPrototype = NSSortDescriptor(key: SortKey.size.rawValue, ascending: false)
        tableView.addTableColumn(sizeColumn)

        let filesColumn = NSTableColumn(identifier: .filesColumn)
        filesColumn.title = "Files"
        filesColumn.minWidth = 50
        filesColumn.width = 60
        filesColumn.sortDescriptorPrototype = NSSortDescriptor(key: SortKey.files.rawValue, ascending: false)
        tableView.addTableColumn(filesColumn)

        // Default sort (Size descending) matches the Tree View's default and
        // gives the Size column a header indicator from the start, rather
        // than the table appearing unsorted until the user clicks a header.
        // AppKit's own header comment for `sortDescriptors` only promises
        // its setter "may" call the delegate back, so the callback is
        // invoked directly rather than assuming that side effect fires.
        tableView.sortDescriptors = [sizeColumn.sortDescriptorPrototype!]
        context.coordinator.tableView(tableView, sortDescriptorsDidChange: [])

        let scrollView = NSScrollView()
        scrollView.documentView = tableView
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.autohidesScrollers = true

        context.coordinator.tableView = tableView
        return scrollView
    }

    public func updateNSView(_ scrollView: NSScrollView, context: Context) {
        let coordinator = context.coordinator
        guard let tableView = coordinator.tableView else { return }

        coordinator.onRecomputeFinished = onRecomputeFinished

        let isNewRoot = coordinator.rootNode !== rootNode
        coordinator.rootNode = rootNode

        guard isNewRoot || coordinator.lastTreeVersion != treeVersion else { return }
        coordinator.lastTreeVersion = treeVersion
        coordinator.scheduleRecompute(tableView: tableView)
    }

    public func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    /// Which field drives the table's current sort — defaults to `.size`
    /// descending, matching the Tree View's default and the row order
    /// `ExtensionBreakdown.compute` already returns.
    enum SortKey: String {
        case extensionName, fileType, percent, size, files
    }

    @MainActor
    public final class Coordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate {
        var rootNode: FileNode?
        var lastTreeVersion = -1
        weak var tableView: NSTableView?
        var onRecomputeFinished: ((Int) -> Void)?

        private var rows: [ExtensionSummary] = []
        private var totalSize: UInt64 = 0
        private var recomputeTask: Task<Void, Never>?
        /// Set when `scheduleRecompute` is called while a walk is already in
        /// flight — guarantees one more pass runs once the current one
        /// finishes, instead of dropping the trigger (which could otherwise
        /// leave the view stuck showing pre-final data if the scan's very
        /// last `treeVersion` bump lands while a walk is still running).
        private var recomputeAgainAfter = false

        private var sortKey: SortKey = .size
        private var sortAscending = false

        /// Mirrors `TreemapView.relayout`'s pattern: debounce a burst of
        /// scan-progress `treeVersion` bumps, then walk the whole tree
        /// off-main so a large scan's extension breakdown never blocks the
        /// UI thread.
        ///
        /// Coalesces to at most one walk in flight at a time. `Task.cancel()`
        /// on the previous `recomputeTask` alone doesn't stop wasted work —
        /// `ExtensionBreakdown.compute` is a plain synchronous recursive
        /// function with no cooperative cancellation checks, so a cancelled
        /// `Task.detached` keeps running to completion regardless. During an
        /// active scan `treeVersion` bumps roughly every 100ms, so without
        /// this the previous (buggy) version could pile up hundreds of
        /// overlapping full-tree walks over a long scan — a real, measured
        /// cause of a live scan running dramatically slower than the scanner
        /// itself, since every one of those walks competes with the
        /// scanner's own worker threads for the same CPU cores.
        func scheduleRecompute(tableView: NSTableView) {
            guard rootNode != nil else {
                rows = []
                totalSize = 0
                tableView.reloadData()
                return
            }
            guard recomputeTask == nil else {
                recomputeAgainAfter = true
                return
            }
            runRecompute(tableView: tableView)
        }

        private func runRecompute(tableView: NSTableView) {
            recomputeTask = Task { [weak self] in
                try? await Task.sleep(for: .milliseconds(80))
                if !Task.isCancelled, let self, let rootNode = self.rootNode {
                    let computed = await Task.detached(priority: .userInitiated) {
                        ExtensionBreakdown.compute(for: rootNode)
                    }.value
                    if !Task.isCancelled {
                        self.rows = self.sorted(computed)
                        self.totalSize = rootNode.displaySize
                        tableView.reloadData()
                    }
                }
                guard let self else { return }
                self.recomputeTask = nil
                if self.recomputeAgainAfter {
                    self.recomputeAgainAfter = false
                    self.runRecompute(tableView: tableView)
                } else if !Task.isCancelled {
                    self.onRecomputeFinished?(self.lastTreeVersion)
                }
            }
        }

        public func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

        public func tableView(_ tableView: NSTableView, sortDescriptorsDidChange oldDescriptors: [NSSortDescriptor]) {
            guard let descriptor = tableView.sortDescriptors.first, let key = descriptor.key.flatMap(SortKey.init) else {
                return
            }
            sortKey = key
            sortAscending = descriptor.ascending
            rows = sorted(rows)
            updateSortIndicators(tableView)
            tableView.reloadData()
        }

        // MARK: Sorting

        private func sorted(_ input: [ExtensionSummary]) -> [ExtensionSummary] {
            let ascending = sortAscending
            let key = sortKey
            return input.sorted { a, b in
                let primary = Self.compare(a, b, key: key)
                if primary != .orderedSame {
                    return ascending ? primary == .orderedAscending : primary == .orderedDescending
                }
                return (a.fileExtension ?? "").localizedStandardCompare(b.fileExtension ?? "") == .orderedAscending
            }
        }

        private static func compare(_ a: ExtensionSummary, _ b: ExtensionSummary, key: SortKey) -> ComparisonResult {
            switch key {
            case .extensionName: return (a.fileExtension ?? "").localizedStandardCompare(b.fileExtension ?? "")
            case .fileType: return a.fileTypeName.localizedStandardCompare(b.fileTypeName)
            // Percent is total size divided by a shared constant, so it sorts identically to Size.
            case .percent, .size: return numericCompare(a.totalSize, b.totalSize)
            case .files: return numericCompare(a.fileCount, b.fileCount)
            }
        }

        private static func numericCompare<T: Comparable>(_ a: T, _ b: T) -> ComparisonResult {
            if a < b { return .orderedAscending }
            if a > b { return .orderedDescending }
            return .orderedSame
        }

        /// Draws the ascending/descending arrow on whichever column drives
        /// the current sort (`NSTableView` toggles `sortDescriptors` on
        /// header clicks by itself, but leaves indicator-image/highlight
        /// bookkeeping to the delegate).
        private func updateSortIndicators(_ tableView: NSTableView) {
            for column in tableView.tableColumns {
                tableView.setIndicatorImage(nil, in: column)
            }
            let identifierForKey: [SortKey: NSUserInterfaceItemIdentifier] = [
                .extensionName: .extensionColumn, .fileType: .fileTypeColumn,
                .percent: .percentColumn, .size: .sizeColumn, .files: .filesColumn
            ]
            guard let identifier = identifierForKey[sortKey],
                  let column = tableView.tableColumns.first(where: { $0.identifier == identifier }) else { return }
            let imageName = sortAscending ? "NSAscendingSortIndicator" : "NSDescendingSortIndicator"
            tableView.setIndicatorImage(NSImage(named: imageName), in: column)
            tableView.highlightedTableColumn = column
        }

        public func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
            guard let columnID = tableColumn?.identifier, row < rows.count else { return nil }
            let summary = rows[row]
            let fraction = totalSize > 0 ? Double(summary.totalSize) / Double(totalSize) : 0

            switch columnID {
            case .colorColumn:
                let color = row < ExtensionSummaryView.topColoredCount
                    ? ExtensionColor.solidColor(forExtension: summary.fileExtension)
                    : ExtensionColor.unrankedColor
                return ColorSwatchCellView.makeOrReuse(in: tableView, color: color)
            case .extensionColumn:
                return TextCellView.makeOrReuse(
                    in: tableView,
                    identifier: .extensionColumn,
                    text: summary.fileExtension.map { ".\($0)" } ?? "",
                    alignment: .left
                )
            case .fileTypeColumn:
                return TextCellView.makeOrReuse(
                    in: tableView,
                    identifier: .fileTypeColumn,
                    text: summary.fileTypeName,
                    alignment: .left
                )
            case .percentColumn:
                return PercentOfParentCellView.makeOrReuse(in: tableView, fraction: fraction)
            case .sizeColumn:
                return TextCellView.makeOrReuse(
                    in: tableView,
                    identifier: .sizeColumn,
                    text: SizeFormatting.string(for: summary.totalSize),
                    alignment: .right
                )
            case .filesColumn:
                return TextCellView.makeOrReuse(
                    in: tableView,
                    identifier: .filesColumn,
                    text: SizeFormatting.countString(for: summary.fileCount),
                    alignment: .right
                )
            default:
                return nil
            }
        }
    }
}

private extension NSUserInterfaceItemIdentifier {
    static let colorColumn = NSUserInterfaceItemIdentifier("color")
    static let extensionColumn = NSUserInterfaceItemIdentifier("extension")
    static let fileTypeColumn = NSUserInterfaceItemIdentifier("fileType")
    static let percentColumn = NSUserInterfaceItemIdentifier("percent")
    static let sizeColumn = NSUserInterfaceItemIdentifier("size")
    static let filesColumn = NSUserInterfaceItemIdentifier("files")
}
