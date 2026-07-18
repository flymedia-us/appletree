import Foundation

/// Shared byte-count formatting for both the Tree View's Size column and the
/// treemap's on-box labels — one formatting implementation, not two.
public enum SizeFormatting {
    /// `ByteCountFormatter` isn't `Sendable`, but every caller (Tree View cell
    /// configuration, treemap box labels) runs on the main thread — the
    /// treemap in particular calls this once per visible box on every
    /// `Canvas` redraw, including every hover-tick, so a fresh (locale-aware,
    /// non-trivial to construct) formatter per call was measurable. Reusing
    /// one is safe as long as nothing ever calls this off the main thread.
    nonisolated(unsafe) private static let byteCountFormatter: ByteCountFormatter = {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter
    }()

    public static func string(for bytes: UInt64) -> String {
        byteCountFormatter.string(fromByteCount: Int64(clamping: bytes))
    }

    public static func percentString(for fraction: Double) -> String {
        let clamped = max(0, min(1, fraction))
        return String(format: "%.1f%%", clamped * 100)
    }

    /// Grouped/comma-separated integer (e.g. `1,000` rather than `1000`) —
    /// used by the Files/Folders columns in both tables.
    public static func countString(for count: Int) -> String {
        count.formatted(.number)
    }

    /// `nil` (files/folders with no recorded modification time — the root
    /// of a scan whose `lstat` somehow lacked one) renders as an em dash
    /// rather than an empty cell, so it reads as "no data" not "not loaded".
    private static let mediumDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter
    }()

    public static func dateString(for date: Date?) -> String {
        guard let date else { return "—" }
        return mediumDateFormatter.string(from: date)
    }
}
