import Foundation
import Testing
@testable import AppleTreeCore

@Suite("VolumeInfo")
struct VolumeInfoTests {
    private static func makeInfo(totalBytes: UInt64, freeBytes: UInt64, reservedBytes: UInt64) -> VolumeInfo {
        VolumeInfo(volumeName: "Test Volume", volumeRootPath: "/", totalBytes: totalBytes, freeBytes: freeBytes, reservedBytes: reservedBytes)
    }

    @Test("usedBytes is total minus free minus reserved, and all three sum back to total")
    func usedBytesDerivedCorrectly() {
        let info = Self.makeInfo(totalBytes: 1000, freeBytes: 400, reservedBytes: 50)
        #expect(info.usedBytes == 550)
        #expect(info.usedBytes + info.freeBytes + info.reservedBytes == info.totalBytes)
    }

    @Test("usedBytes clamps to zero rather than underflowing when free+reserved exceeds total")
    func usedBytesClampsRatherThanUnderflowing() {
        // Free/reserved come from separate OS calls that can disagree slightly;
        // the UInt64 subtraction must never wrap around to a huge number.
        let info = Self.makeInfo(totalBytes: 1000, freeBytes: 900, reservedBytes: 200)
        #expect(info.usedBytes == 0)
    }

    @Test("usedFraction and freeFraction are fractions of total, zero when total is zero")
    func fractionsComputedCorrectly() {
        let info = Self.makeInfo(totalBytes: 1000, freeBytes: 250, reservedBytes: 0)
        #expect(info.usedFraction == 0.75)
        #expect(info.freeFraction == 0.25)

        let empty = Self.makeInfo(totalBytes: 0, freeBytes: 0, reservedBytes: 0)
        #expect(empty.usedFraction == 0)
        #expect(empty.freeFraction == 0)
    }

    @Test("forVolume reads real capacity stats for an existing path")
    func forVolumeReadsRealStats() throws {
        let info = try #require(VolumeInfo.forVolume(containing: FileManager.default.temporaryDirectory))
        #expect(info.totalBytes > 0)
        #expect(info.totalBytes >= info.freeBytes)
        #expect(!info.volumeName.isEmpty)
        #expect(info.volumeRootPath.hasPrefix("/"))
    }

    @Test("forVolume's volumeRootPath is a prefix of the queried path")
    func forVolumeRootPathIsAPrefixOfTheQueriedPath() throws {
        let path = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().path(percentEncoded: false)
        let info = try #require(VolumeInfo.forVolume(containing: FileManager.default.temporaryDirectory))
        #expect(path == info.volumeRootPath || path.hasPrefix(info.volumeRootPath.hasSuffix("/") ? info.volumeRootPath : info.volumeRootPath + "/"))
    }
}
