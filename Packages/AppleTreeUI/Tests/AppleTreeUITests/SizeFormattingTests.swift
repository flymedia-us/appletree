import Testing
@testable import AppleTreeUI

@Suite("SizeFormatting")
struct SizeFormattingTests {
    @Test("formats byte counts as human-readable strings")
    func formatsBytes() {
        #expect(SizeFormatting.string(for: 0) == "Zero KB" || SizeFormatting.string(for: 0).contains("0"))
        #expect(!SizeFormatting.string(for: 1_500_000_000).isEmpty)
    }

    @Test("formats fractions as percentage strings")
    func formatsPercent() {
        #expect(SizeFormatting.percentString(for: 0.5) == "50.0%")
        #expect(SizeFormatting.percentString(for: 1.5) == "100.0%") // clamped
        #expect(SizeFormatting.percentString(for: -0.5) == "0.0%") // clamped
    }
}
