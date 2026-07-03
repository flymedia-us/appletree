import Foundation

/// Volume/device metadata captured once at scan start, independent of the
/// (much larger, incrementally-built) `FileNode` tree itself.
public struct ScanRoot: Sendable {
    public let url: URL
    public let deviceID: Int32
    public let volumeTotalCapacity: UInt64?
    public let volumeAvailableCapacity: UInt64?

    public init(
        url: URL,
        deviceID: Int32,
        volumeTotalCapacity: UInt64?,
        volumeAvailableCapacity: UInt64?
    ) {
        self.url = url
        self.deviceID = deviceID
        self.volumeTotalCapacity = volumeTotalCapacity
        self.volumeAvailableCapacity = volumeAvailableCapacity
    }
}
