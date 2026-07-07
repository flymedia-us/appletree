import Foundation

/// Why a folder was skipped, classified from the syscall's `errno` (and,
/// for `EPERM`, the path itself).
///
/// macOS surfaces a TCC-denied open (a path blocked by a *privacy*
/// protection — Full Disk Access territory, e.g. `~/Library/Mail`) as
/// `EPERM`, distinct from the `EACCES` a plain Unix permission bit (e.g. a
/// stat-only entry in someone else's home directory) would give. The two
/// need different user-facing treatment: the former can be resolved by
/// granting Full Disk Access, the latter cannot — so collapsing them into
/// one "permission denied" bucket would make the app recommend a fix that
/// doesn't apply.
///
/// `EPERM` alone is not sufficient, though — confirmed on a real machine
/// with Full Disk Access genuinely granted and working (verified: previously
/// FDA-blocked folders like `~/Library/Application Support/MobileSync`
/// became readable): every *remaining* `EPERM` was under `/private/var/db/`
/// — root-owned system daemon databases (Spotlight's index internals,
/// syslog, network daemon state, panic dumps, `lockdown`, etc.), not user
/// files. No permission grant, not even Full Disk Access, not even root,
/// unlocks these — so lumping them in with `.tccDenied` made the app nag
/// to grant a permission that was already granted and had already done
/// everything it could.
public enum FolderSkipReason: Sendable, Equatable {
    /// Blocked by TCC privacy protection — granting Full Disk Access may
    /// resolve this on a rescan.
    case tccDenied
    /// `EPERM` under a root-owned system path (`/private/var/db` and
    /// similar) — structurally unfixable by any permission grant.
    case systemProtected
    /// A plain Unix permission bit denied the read (e.g. another user's
    /// files) — Full Disk Access does not change this.
    case accessDenied
    /// Any other errno (stale mount, I/O error, etc).
    case other(errno: Int32)

    public init(errno: Int32, path: String) {
        switch errno {
        case EPERM: self = Self.isSystemProtectedPath(path) ? .systemProtected : .tccDenied
        case EACCES: self = .accessDenied
        default: self = .other(errno: errno)
        }
    }

    private static func isSystemProtectedPath(_ path: String) -> Bool {
        path.hasPrefix("/private/var/") || path.hasPrefix("/var/")
    }
}

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
    case progress(filesScanned: Int, foldersScanned: Int, bytesScanned: UInt64, currentPath: String?)

    /// A folder could not be scanned and was skipped rather than failing
    /// the whole scan.
    case folderSkipped(path: String, reason: FolderSkipReason)

    case finished(duration: Duration, filesScanned: Int, foldersSkipped: Int, tccDeniedFolders: Int)
    case failed(any Error)
}
