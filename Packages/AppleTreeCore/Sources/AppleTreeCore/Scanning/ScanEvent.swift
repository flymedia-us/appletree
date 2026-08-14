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
/// with Full Disk Access genuinely granted and working (verified:
/// previously-blocked folders like `~/Library/Application
/// Support/MobileSync` became readable). Two rounds of live diagnosis
/// turned up EPERM paths that FDA does NOT unlock, in growing variety:
/// root-owned system daemon state (`/private/var/db/*` — Spotlight
/// internals, syslog, `lockdown`), top-level system caches
/// (`/Library/Caches/com.apple.*`), SIP-protected OS content
/// (`/System/Library/AssetsV2/*`), and Keychain database files
/// (`~/Library/Keychains/*` — excluded from FDA's scope by Apple's own
/// design; those need the Keychain Services API, not raw file access).
/// Chasing each new system prefix individually doesn't converge, so this
/// classifies by an allowlist instead: EPERM inside a user's privacy-protected
/// home folders is Full Disk Access territory (any user, since FDA's own
/// description says "for all users on this Mac"). This includes `Library`
/// (Keychains excepted) plus Desktop, Documents, Downloads, Pictures, Music,
/// and Movies. These matter when scanning a user-selected home folder or
/// volume: Apple requires the app not to declare unnecessary programmatic
/// folder-access entitlements, and mandatory privacy controls may still deny
/// content even though the Open Panel's sandbox extension recursively covers
/// the selected root. Everything else that returns EPERM is `.systemProtected`,
/// structurally unfixable by FDA.
public enum FolderSkipReason: Sendable, Equatable {
    /// Blocked by TCC privacy protection — granting Full Disk Access may
    /// resolve this on a rescan.
    case tccDenied
    /// `EPERM` outside a user's own `~/Library` (or inside `Keychains`) —
    /// structurally unfixable by any permission grant, FDA included.
    case systemProtected
    /// A plain Unix permission bit denied the read (e.g. another user's
    /// files) — Full Disk Access does not change this.
    case accessDenied
    /// Any other errno (stale mount, I/O error, etc).
    case other(errno: Int32)

    public init(errno: Int32, path: String) {
        switch errno {
        case EPERM: self = Self.isFullDiskAccessRelevantPath(path) ? .tccDenied : .systemProtected
        case EACCES: self = .accessDenied
        default: self = .other(errno: errno)
        }
    }

    /// Matches privacy-protected folders in `/Users/<anyone>` while excluding
    /// `~/Library/Keychains`, which FDA intentionally doesn't make readable.
    private static func isFullDiskAccessRelevantPath(_ path: String) -> Bool {
        let components = path.split(separator: "/", omittingEmptySubsequences: true)
        guard components.count >= 3, components[0] == "Users" else {
            return false
        }

        switch components[2] {
        case "Desktop", "Documents", "Downloads", "Pictures", "Music", "Movies":
            return true
        case "Library":
            return components.count < 4 || components[3] != "Keychains"
        default:
            return false
        }
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
    /// Emitted instead of `.finished` when the consuming task cancelled the
    /// scan mid-walk. Counters reflect whatever was observed before cancel.
    case cancelled(duration: Duration, filesScanned: Int, foldersSkipped: Int, tccDeniedFolders: Int)
    case failed(any Error)
}
