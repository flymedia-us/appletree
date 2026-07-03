/// Maps a lowercased file extension (without the leading dot) to the
/// `FileCategory` it should be colored as. Curated by hand — a treemap
/// colored with hundreds of distinct hues would be illegible, so many
/// extensions intentionally share a category/color.
enum ExtensionCategoryMap {
    static let table: [String: FileCategory] = {
        var map: [String: FileCategory] = [:]
        func add(_ category: FileCategory, _ extensions: [String]) {
            for ext in extensions { map[ext] = category }
        }

        add(.video, [
            "mp4", "mov", "m4v", "avi", "mkv", "wmv", "flv", "webm", "mpg", "mpeg",
            "3gp", "3g2", "m2ts", "mts", "vob", "ogv", "rm", "asf", "divx"
        ])

        add(.image, [
            "jpg", "jpeg", "png", "gif", "bmp", "tiff", "tif", "heic", "heif",
            "webp", "raw", "cr2", "cr3", "nef", "arw", "dng", "orf", "rw2",
            "psd", "ai", "eps", "svg", "ico", "icns", "avif", "jxl"
        ])

        add(.audio, [
            "mp3", "wav", "aac", "flac", "m4a", "wma", "ogg", "opus", "aiff",
            "aif", "alac", "mid", "midi", "amr", "caf"
        ])

        add(.codeOrDeveloper, [
            "swift", "m", "mm", "h", "hpp", "c", "cpp", "cc", "cxx",
            "py", "pyc", "pyo", "pyd", "rb", "js", "jsx", "ts", "tsx", "mjs", "cjs",
            "java", "kt", "kts", "go", "rs", "cs", "php", "pl", "lua", "sh", "bash",
            "zsh", "fish", "sql", "r", "scala", "clj", "hs", "erl", "ex", "exs",
            "html", "htm", "css", "scss", "sass", "less", "json", "xml", "yaml",
            "yml", "toml", "ini", "cfg", "conf", "gradle", "cmake", "makefile",
            "vue", "svelte", "proto", "graphql", "ipynb", "xcconfig", "xcworkspacedata",
            "pbxproj", "storyboard", "xib", "nib", "playground", "podspec"
        ])

        add(.archive, [
            "zip", "tar", "gz", "tgz", "bz2", "xz", "7z", "rar", "dmg", "pkg",
            "iso", "cab", "lz", "lzma", "z", "cpio", "sit", "sitx", "zst"
        ])

        add(.application, [
            "app", "exe", "msi", "deb", "rpm", "apk", "ipa", "appx", "command",
            "workflow", "action", "prefpane", "plugin", "bundle", "framework",
            "kext", "component", "qlgenerator", "saver", "wdgt"
        ])

        add(.system, [
            "plist", "log", "cache", "tmp", "temp", "lock", "pid", "sqlite",
            "sqlite3", "db", "db-shm", "db-wal", "dat", "bin", "sys", "dylib",
            "so", "a", "o", "dSYM", "crash", "spin", "diag", "keychain",
            "swiftmodule", "swiftdoc", "modulemap"
        ])

        add(.document, [
            "pdf", "doc", "docx", "rtf", "txt", "md", "markdown", "pages",
            "xls", "xlsx", "numbers", "csv", "tsv", "ppt", "pptx", "keynote",
            "key", "epub", "odt", "ods", "odp", "tex", "rtfd"
        ])

        return map
    }()
}
