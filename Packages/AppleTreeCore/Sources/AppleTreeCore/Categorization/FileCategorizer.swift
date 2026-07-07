/// Assigns a `FileCategory` to a file based on its name. Stateless — safe to
/// call from any thread, including the scanner's hot per-file loop.
public enum FileCategorizer {
    public static func category(forFileName name: String) -> FileCategory {
        guard let ext = extractExtension(from: name) else { return .noExtension }
        return ExtensionCategoryMap.table[ext] ?? .other
    }

    /// The lowercased extension (without the leading dot), or `nil` for an
    /// extensionless name. Exposed publicly so presentation layers can build
    /// finer-grained groupings (e.g. per-extension treemap colors) than the
    /// coarse `FileCategory` buckets without duplicating the dot-parsing rules.
    ///
    /// Canonicalizes same-format spelling variants that `extractExtension`'s
    /// plain lowercasing doesn't collapse on its own — currently just
    /// `jpg`/`jpeg` (`.JPG`, `.jpg`, `.JPEG`, and `.jpeg` all become
    /// `"jpeg"`), so the extension breakdown shows one combined row instead
    /// of splitting the same format across two. Deliberately not folded into
    /// `extractExtension` itself: `category(forFileName:)` (the coarse
    /// image/video/audio/... bucket) doesn't need or want this — `jpg` and
    /// `jpeg` already map to the same `.image` category either way, and
    /// keeping `extractExtension` a literal "what's after the last dot"
    /// primitive avoids baking presentation-only aliasing into the one
    /// parsing function every extension consumer shares.
    public static func fileExtension(forFileName name: String) -> String? {
        guard let ext = extractExtension(from: name) else { return nil }
        return extensionAliases[ext] ?? ext
    }

    private static let extensionAliases: [String: String] = ["jpg": "jpeg"]

    /// The substring after the *last* dot, lowercased — but only when that
    /// dot is neither the first character (a dotfile like `.gitignore` has
    /// no extension, it's not an extension literally named "gitignore") nor
    /// the last character (a trailing dot like `"name."` has no extension
    /// either).
    static func extractExtension(from name: String) -> String? {
        guard let lastDot = name.lastIndex(of: "."), lastDot != name.startIndex else {
            return nil
        }
        let extensionStart = name.index(after: lastDot)
        guard extensionStart < name.endIndex else { return nil }
        return name[extensionStart...].lowercased()
    }
}
