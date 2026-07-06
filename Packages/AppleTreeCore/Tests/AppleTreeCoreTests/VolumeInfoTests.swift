import Foundation
import Testing
@testable import AppleTreeCore

@Suite("VolumeInfo")
struct VolumeInfoTests {
    @Test("usedBytes is total minus free minus reserved, and all three sum back to total")
    func usedBytesDerivedCorrectly() {
        let info = VolumeInfo(totalBytes: 1000, freeBytes: 400, reservedBytes: 50)
        #expect(info.usedBytes == 550)
        #expect(info.usedBytes + info.freeBytes + info.reservedBytes == info.totalBytes)
    }

    @Test("usedBytes clamps to zero rather than underflowing when free+reserved exceeds total")
    func usedBytesClampsRatherThanUnderflowing() {
        // Free/reserved come from separate OS calls that can disagree slightly;
        // the UInt64 subtraction must never wrap around to a huge number.
        let info = VolumeInfo(totalBytes: 1000, freeBytes: 900, reservedBytes: 200)
        #expect(info.usedBytes == 0)
    }

    @Test("usedFraction and freeFraction are fractions of total, zero when total is zero")
    func fractionsComputedCorrectly() {
        let info = VolumeInfo(totalBytes: 1000, freeBytes: 250, reservedBytes: 0)
        #expect(info.usedFraction == 0.75)
        #expect(info.freeFraction == 0.25)

        let empty = VolumeInfo(totalBytes: 0, freeBytes: 0, reservedBytes: 0)
        #expect(empty.usedFraction == 0)
        #expect(empty.freeFraction == 0)
    }

    @Test("forVolume reads real capacity stats for an existing path")
    func forVolumeReadsRealStats() throws {
        let info = try #require(VolumeInfo.forVolume(containing: FileManager.default.temporaryDirectory))
        #expect(info.totalBytes > 0)
        #expect(info.totalBytes >= info.freeBytes)
    }
}
