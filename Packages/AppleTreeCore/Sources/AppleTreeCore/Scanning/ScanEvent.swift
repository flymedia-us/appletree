import Foundation

/// Incremental output of a `DirectoryScanner.scan(...)` call. The scanner
/// streams these rather than returning a single result so the UI can start
/// rendering a large scan well before it fully completes.
public enum ScanEvent: Sendable {
    /// Emitted once, immediately, so the UI can show the root row right away.
    case rootCreated(FileNode)

    /// Emitted whenever a worker task finishes scanning a subdirectory and
    /// appends its results to the shared tree. Batched per completed
    /// subdirectory (not per-file, which would be far too chatty at scale).
    case subtreeCompleted(parent: FileNode)

    /// Throttled progress ticks (by file count and/or wall-clock time).
    case progress(filesScanned: Int, bytesScanned: UInt64, currentPath: String?)

    /// A folder could not be scanned (permission denied, e.g. a
    /// TCC-protected path under the sandboxed model) and was skipped rather
    /// than failing the whole scan.
    case folderSkipped(path: String, reason: String)

    case finished(duration: Duration, filesScanned: Int, foldersSkipped: Int)
    case failed(any Error)
}
