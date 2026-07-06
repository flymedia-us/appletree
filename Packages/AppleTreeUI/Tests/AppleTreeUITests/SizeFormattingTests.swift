import Foundation
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

    @Test("formats counts with a grouping separator")
    func formatsCounts() {
        #expect(SizeFormatting.countString(for: 1_000) == "1,000")
        #expect(SizeFormatting.countString(for: 42) == "42")
    }

    @Test("nil modification dates render as an em dash, not an empty string")
    func nilDateRendersAsEmDash() {
        #expect(SizeFormatting.dateString(for: nil) == "—")
        #expect(!SizeFormatting.dateString(for: Date()).isEmpty)
    }
}
