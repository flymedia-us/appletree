/// One row of the whole-scan "flat breakdown of every file extension" pane
/// (WizTree's Extension List) — aggregated across every file in the tree,
/// independent of Tree View position or selection.
public struct ExtensionSummary: Identifiable, Sendable {
    /// Lowercased extension without the leading dot, or `nil` for files with
    /// no extension — `(No Extension)` is a first-class row, not folded into
    /// a catch-all (see `FileTypeNaming`'s doc comment).
    public let fileExtension: String?
    public let fileTypeName: String
    public let totalSize: UInt64
    public let fileCount: Int

    public var id: String { fileExtension ?? "" }

    public init(fileExtension: String?, fileTypeName: String, totalSize: UInt64, fileCount: Int) {
        self.fileExtension = fileExtension
        self.fileTypeName = fileTypeName
        self.totalSize = totalSize
        self.fileCount = fileCount
    }
}

public enum ExtensionBreakdown {
    /// Aggregates every file (not directory) under `root` by extension,
    /// sorted descending by total size. Safe to call off the main actor —
    /// only reads already-scanned (or scanned-so-far) `FileNode` state.
    public static func compute(for root: FileNode) -> [ExtensionSummary] {
        var sizeByExtension: [String: UInt64] = [:]
        var countByExtension: [String: Int] = [:]

        func walk(_ node: FileNode) {
            if node.isDirectory {
                for child in node.children { walk(child) }
                return
            }
            let key = FileCategorizer.fileExtension(forFileName: node.name) ?? ""
            sizeByExtension[key, default: 0] += node.displaySize
            countByExtension[key, default: 0] += 1
        }
        walk(root)

        return sizeByExtension.map { key, size in
            let ext = key.isEmpty ? nil : key
            return ExtensionSummary(
                fileExtension: ext,
                fileTypeName: FileTypeNaming.displayName(forExtension: ext),
                totalSize: size,
                fileCount: countByExtension[key] ?? 0
            )
        }
        .sorted { $0.totalSize > $1.totalSize }
    }
}
