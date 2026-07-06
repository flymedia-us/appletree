import AppleTreeCore
import SwiftUI

/// Assigns a stable color per (normalized) file extension. Unlike
/// `FileCategory`'s ~10 coarse buckets (which intentionally lump e.g. every
/// image format into one "image" color), this gives each distinct extension
/// its own hue — so a treemap can show png and jpg as different colors —
/// while still treating obvious same-format spelling variants (jpg/jpeg,
/// tif/tiff, ...) as one color.
enum ExtensionColor {
    /// Same-format extensions that should share one key. Not exhaustive —
    /// just the pairs a user would recognize as literally the same format.
    private static let aliases: [String: String] = [
        "jpeg": "jpg",
        "jfif": "jpg",
        "tiff": "tif",
        "htm": "html",
        "yml": "yaml",
        "mpeg": "mpg",
        "aiff": "aif",
        "markdown": "md",
        "midi": "mid",
    ]

    private static let noExtensionKey = "\u{0}noExtension"

    /// Hand-picked hues for common extensions, so frequently-seen file types
    /// get a stable, well-separated color rather than whatever a hash
    /// happens to produce. Anything not listed falls back to `hashHue`.
    private static let curatedHue: [String: Double] = [
        noExtensionKey: 0.0,

        "jpg": 0.08, "png": 0.55, "gif": 0.83, "heic": 0.02, "webp": 0.62,
        "bmp": 0.16, "svg": 0.38, "psd": 0.70, "ai": 0.73, "raw": 0.05,

        "mp4": 0.75, "mov": 0.78, "avi": 0.72, "mkv": 0.80, "webm": 0.68,

        "mp3": 0.11, "wav": 0.13, "flac": 0.09, "aac": 0.14, "aif": 0.12,

        "pdf": 0.98, "doc": 0.60, "docx": 0.60, "rtf": 0.59, "txt": 0.0,
        "md": 0.16, "pages": 0.61,
        "xls": 0.33, "xlsx": 0.33, "numbers": 0.34, "csv": 0.30, "tsv": 0.30,
        "ppt": 0.04, "pptx": 0.04, "key": 0.05,

        "zip": 0.13, "dmg": 0.13, "tar": 0.13, "gz": 0.13, "rar": 0.13,
        "7z": 0.13, "pkg": 0.13, "iso": 0.13,

        "app": 0.0, "exe": 0.0,

        "swift": 0.04, "py": 0.55, "js": 0.15, "jsx": 0.15, "ts": 0.58,
        "tsx": 0.58, "json": 0.5, "html": 0.03, "css": 0.58, "java": 0.05,

        "plist": 0.6, "log": 0.6, "sqlite": 0.6,
    ]

    static func key(forFileName name: String) -> String {
        key(forExtension: FileCategorizer.fileExtension(forFileName: name))
    }

    /// Same alias-normalized key as `key(forFileName:)`, but starting from an
    /// already-extracted extension (or `nil` for extensionless) — used by
    /// presentation code (e.g. the extension summary table) that already has
    /// a `FileNode`-independent extension string rather than a raw file name.
    static func key(forExtension ext: String?) -> String {
        guard let ext else { return noExtensionKey }
        return aliases[ext] ?? ext
    }

    /// A top/bottom color pair for a subtle vertical gradient fill — the
    /// same hue at slightly different brightness, rather than a flat color.
    static func gradient(forFileName name: String) -> (top: Color, bottom: Color) {
        let key = key(forFileName: name)
        let hue = curatedHue[key] ?? hashHue(key)
        let saturation = 0.55
        let top = Color(hue: hue, saturation: saturation * 0.85, brightness: 0.88)
        let bottom = Color(hue: hue, saturation: min(1, saturation * 1.15), brightness: 0.60)
        return (top, bottom)
    }

    /// A single flat swatch color for the given extension — the same hue
    /// `gradient(forFileName:)` would use for that extension's treemap
    /// boxes, so the extension summary table's color column visually matches
    /// the treemap below it.
    static func solidColor(forExtension ext: String?) -> Color {
        let key = key(forExtension: ext)
        let hue = curatedHue[key] ?? hashHue(key)
        return Color(hue: hue, saturation: 0.6, brightness: 0.78)
    }

    /// Fallback swatch for every file type outside the top-N by size in the
    /// extension summary table — keeps the color column legible instead of
    /// giving every long-tail extension its own (likely hash-derived, poorly
    /// separated) hue.
    static let unrankedColor = Color(white: 0.35)

    /// Deterministic FNV-1a hash of the extension, mapped to a hue — stable
    /// across launches/scans without needing every extension curated by hand.
    private static func hashHue(_ key: String) -> Double {
        var hash: UInt64 = 1469598103934665603
        for byte in key.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 1099511628211
        }
        return Double(hash % 360) / 360.0
    }
}
