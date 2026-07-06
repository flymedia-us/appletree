import Foundation

/// Capacity stats for the volume a scanned root lives on — independent of
/// the scan itself (a subfolder scan's tree total is not the disk's total).
public struct VolumeInfo: Sendable, Equatable {
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

    public init(totalBytes: UInt64, freeBytes: UInt64, reservedBytes: UInt64) {
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
            .volumeTotalCapacityKey,
            .volumeAvailableCapacityKey,
            .volumeAvailableCapacityForImportantUsageKey,
        ]) else { return nil }

        guard let total = values.volumeTotalCapacity,
              let available = values.volumeAvailableCapacity else { return nil }

        let availableForImportantUsage = values.volumeAvailableCapacityForImportantUsage ?? Int64(available)
        let reserved = max(0, availableForImportantUsage - Int64(available))

        return VolumeInfo(
            totalBytes: UInt64(total),
            freeBytes: UInt64(available),
            reservedBytes: UInt64(reserved)
        )
    }
}
