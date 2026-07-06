import CryptoKit
import Foundation

/// A minimal, flat, per-path record of what a previous scan found — enough
/// to rebuild an equivalent `FileNode` tree without re-`stat`-ing anything
/// that hasn't changed. Deliberately does not store `fileCount`/`folderCount`
/// or a directory's aggregate sizes: those are recomputed bottom-up by
/// `SnapshotTreeBuilder` from children, the same way `FileNode.finalizeAsDirectory()`
/// already does for a live scan, so there is exactly one place that owns
/// aggregation math.
public struct SnapshotEntry: Codable, Sendable, Equatable {
    public var isDirectory: Bool
    public var logicalSize: UInt64
    public var allocatedSize: UInt64
    public var modificationDate: Date?
    public var category: FileCategory

    public init(isDirectory: Bool, logicalSize: UInt64, allocatedSize: UInt64, modificationDate: Date?, category: FileCategory) {
        self.isDirectory = isDirectory
        self.logicalSize = logicalSize
        self.allocatedSize = allocatedSize
        self.modificationDate = modificationDate
        self.category = category
    }
}

/// Persisted result of a scan, keyed by full path, plus the bookkeeping
/// needed to ask FSEvents "what changed since this snapshot was taken" on a
/// later scan of the same root:
///
/// - `volumeUUID` pins the snapshot to the specific volume it was taken on
///   (via `FSEventsCopyUUIDForDevice`, the API FSEvents itself uses to pair
///   event IDs with a device) — an external drive that was reformatted or
///   swapped for a different one at the same mount point must never have its
///   stale event IDs reinterpreted against the new volume.
/// - `eventCursor` is the FSEvents event ID as of this snapshot; a later scan
///   replays history from here forward.
public struct ScanSnapshot: Codable, Sendable {
    public var rootPath: String
    public var volumeUUID: String
    public var eventCursor: UInt64
    public var entries: [String: SnapshotEntry]

    public init(rootPath: String, volumeUUID: String, eventCursor: UInt64, entries: [String: SnapshotEntry]) {
        self.rootPath = rootPath
        self.volumeUUID = volumeUUID
        self.eventCursor = eventCursor
        self.entries = entries
    }
}

/// Persists `ScanSnapshot`s to disk, one file per scanned root path, so a
/// later launch of the app can still delta-rescan a folder it scanned in a
/// previous session.
///
/// Snapshots use `PropertyListEncoder`'s binary format rather than
/// `JSONEncoder`: for a whole-drive scan `entries` can hold millions of keys,
/// and binary-plist encode/decode of a large flat dictionary measurably
/// outperforms JSON for that shape — see `ScanSnapshotStoreTests` for the
/// benchmark this choice is based on. This is a pure serialization swap; both
/// encoders work against the same `Codable` types.
public enum ScanSnapshotStore {
    public static func load(forRootPath rootPath: String) -> ScanSnapshot? {
        guard let url = fileURL(forRootPath: rootPath), let data = try? Data(contentsOf: url) else { return nil }
        return try? PropertyListDecoder().decode(ScanSnapshot.self, from: data)
    }

    public static func save(_ snapshot: ScanSnapshot) {
        guard let url = fileURL(forRootPath: snapshot.rootPath) else { return }
        guard let data = try? PropertyListEncoder().encode(snapshot) else { return }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: url, options: .atomic)
    }

    /// One cache file per root path, named by a hash of the path rather than
    /// the path itself — a whole-volume root ("/") or a deeply nested folder
    /// both need a filename that's short, filesystem-safe, and collision-free.
    static func fileURL(forRootPath rootPath: String) -> URL? {
        guard let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else { return nil }
        let digest = SHA256.hash(data: Data(rootPath.utf8))
        let hex = digest.map { String(format: "%02x", $0) }.joined()
        return base.appendingPathComponent("AppleTree/scan-cache/\(hex).plist")
    }
}
