/// Assigns a `FileCategory` to a file based on its name. Stateless — safe to
/// call from any thread, including the scanner's hot per-file loop.
public enum FileCategorizer {
    public static func category(forFileName name: String) -> FileCategory {
        guard let ext = extractExtension(from: name) else { return .noExtension }
        return ExtensionCategoryMap.table[ext] ?? .other
    }

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
