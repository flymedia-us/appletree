import Foundation

/// Shared byte-count formatting for both the Tree View's Size column and the
/// treemap's on-box labels — one formatting implementation, not two.
public enum SizeFormatting {
    public static func string(for bytes: UInt64) -> String {
        // A fresh formatter per call rather than a shared static: ByteCountFormatter
        // isn't Sendable, and this is cheap enough to not be worth synchronizing.
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter.string(fromByteCount: Int64(clamping: bytes))
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
    public static func dateString(for date: Date?) -> String {
        guard let date else { return "—" }
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }
}
