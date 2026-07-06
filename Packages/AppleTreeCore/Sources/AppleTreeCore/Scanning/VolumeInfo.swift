import Foundation

/// Capacity stats for the volume a scanned root lives on — independent of
/// the scan itself (a subfolder scan's tree total is not the disk's total).
public struct VolumeInfo: Sendable, Equatable {
    /// The volume's own display name (e.g. "Macintosh HD") — used to label
    /// a scan whose root IS the volume itself, rather than showing its raw
    /// mount path.
    public let volumeName: String

    /// The volume's own mount path (e.g. "/" for the boot volume,
    /// "/Volumes/External" otherwise) — compared against a scan root's own
    /// path to decide whether that root IS the volume (show `volumeName`)
    /// or a subfolder of it (show the subfolder's own full path).
    public let volumeRootPath: String

    public let totalBytes: UInt64

    /// Bytes immediately available for new files right now (matches
    /// Finder's "Available" figure).
    public let freeBytes: UInt64

    /// Space APFS could reclaim under pressure but hasn't yet — chiefly
    /// local Time Machine snapshots — approximated as the gap between
    /// `volumeAvailableCapacityForImportantUsage` (which counts purgeable
    /// space as available) and `volumeAvailableCapacity` (which doesn't).
    /// macOS has no literal "reserved space" stat the way NTFS does; this
    /// is the closest real equivalent — space that's spoken for by the
    /// system rather than a user file, but isn't simply free either.
    public let reservedBytes: UInt64

    public init(volumeName: String, volumeRootPath: String, totalBytes: UInt64, freeBytes: UInt64, reservedBytes: UInt64) {
        self.volumeName = volumeName
        self.volumeRootPath = volumeRootPath
        self.totalBytes = totalBytes
        self.freeBytes = freeBytes
        self.reservedBytes = reservedBytes
    }

    /// Total minus free minus reserved — space actually occupied by files
    /// that isn't reclaimable. Clamped since the three inputs come from
    /// separate OS calls that aren't perfectly consistent with each other.
    public var usedBytes: UInt64 {
        let accountedFor = freeBytes + reservedBytes
        return totalBytes > accountedFor ? totalBytes - accountedFor : 0
    }

    public var usedFraction: Double {
        totalBytes > 0 ? Double(usedBytes) / Double(totalBytes) : 0
    }

    public var freeFraction: Double {
        totalBytes > 0 ? Double(freeBytes) / Double(totalBytes) : 0
    }

    /// Reads the containing volume's capacity for `url` via the standard
    /// `URLResourceValues` volume keys. `nil` if the volume's stats aren't
    /// available (e.g. the path doesn't exist).
    public static func forVolume(containing url: URL) -> VolumeInfo? {
        guard let values = try? url.resourceValues(forKeys: [
            .volumeNameKey,
            .volumeTotalCapacityKey,
            .volumeAvailableCapacityKey,
            .volumeAvailableCapacityForImportantUsageKey,
        ]) else { return nil }

        guard let total = values.volumeTotalCapacity,
              let available = values.volumeAvailableCapacity else { return nil }

        let availableForImportantUsage = values.volumeAvailableCapacityForImportantUsage ?? Int64(available)
        let reserved = max(0, availableForImportantUsage - Int64(available))

        return VolumeInfo(
            volumeName: values.volumeName ?? url.lastPathComponent,
            volumeRootPath: mountedVolumeRootPath(containing: url),
            totalBytes: UInt64(total),
            freeBytes: UInt64(available),
            reservedBytes: UInt64(reserved)
        )
    }

    /// There's no direct `URLResourceKey` for "the mount path of the volume
    /// this URL is on" — the standard technique instead is finding the
    /// longest mounted-volume path that's a prefix of the target path (the
    /// most specific match; `/` matches everything, but `/Volumes/External`
    /// should win for a path actually on that volume).
    private static func mountedVolumeRootPath(containing url: URL) -> String {
        let targetPath = url.resolvingSymlinksInPath().path(percentEncoded: false)
        let mounted = FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: nil, options: [.skipHiddenVolumes]) ?? []
        let candidates = mounted.map { $0.path(percentEncoded: false) }
        let matches = candidates.filter { candidate in
            targetPath == candidate || targetPath.hasPrefix(candidate.hasSuffix("/") ? candidate : candidate + "/")
        }
        return matches.max(by: { $0.count < $1.count }) ?? "/"
    }
}
