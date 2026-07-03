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
}
