/// Human-readable "File Type" description per extension, matching the style
/// of WizTree's extension-list pane (e.g. "MP4 File", "JPEG Image"). Curated
/// for common extensions; anything else falls back to a generic "<EXT> File"
/// description rather than going unnamed.
public enum FileTypeNaming {
    public static let noExtensionLabel = "(No Extension)"

    private static let names: [String: String] = [
        "jpg": "JPEG Image", "jpeg": "JPEG Image", "png": "PNG Image", "gif": "GIF Image",
        "heic": "HEIC Image", "heif": "HEIF Image", "webp": "WebP Image", "bmp": "BMP Image",
        "svg": "SVG Image", "tif": "TIFF Image", "tiff": "TIFF Image", "psd": "Photoshop Document",
        "ai": "Illustrator Document", "raw": "Camera Raw Image", "ico": "Icon Image",

        "mp4": "MP4 File", "mov": "QuickTime Movie", "avi": "AVI Video", "mkv": "MKV Video",
        "webm": "WebM Video", "wmv": "WMV Video", "m4v": "M4V Video", "mpg": "MPEG Video", "mpeg": "MPEG Video",

        "mp3": "MP3 Audio", "wav": "WAV Audio", "flac": "FLAC Audio", "aac": "AAC Audio",
        "aif": "AIFF Audio", "aiff": "AIFF Audio", "m4a": "M4A Audio", "wma": "WMA Audio", "ogg": "Ogg Audio",

        "pdf": "PDF Document", "doc": "Word Document", "docx": "Word Document",
        "rtf": "Rich Text Document", "txt": "Plain Text", "md": "Markdown Document",
        "markdown": "Markdown Document", "pages": "Pages Document",
        "xls": "Excel Spreadsheet", "xlsx": "Excel Spreadsheet", "numbers": "Numbers Spreadsheet",
        "csv": "CSV File", "tsv": "TSV File", "ppt": "PowerPoint Presentation", "pptx": "PowerPoint Presentation",
        "key": "Keynote Presentation", "epub": "EPUB Book",

        "zip": "ZIP Archive", "dmg": "Disk Image", "tar": "TAR Archive", "gz": "GZip Archive",
        "rar": "RAR Archive", "7z": "7-Zip Archive", "pkg": "Installer Package", "iso": "Disk Image",

        "app": "Application", "exe": "Windows Executable",

        "swift": "Swift Source", "py": "Python Source", "js": "JavaScript Source",
        "jsx": "JSX Source", "ts": "TypeScript Source", "tsx": "TSX Source", "json": "JSON File",
        "html": "HTML Document", "htm": "HTML Document", "css": "CSS Stylesheet", "java": "Java Source",

        "plist": "Property List", "log": "Log File", "sqlite": "SQLite Database"
    ]

    /// `ext` is the lowercased extension without its leading dot, or `nil`
    /// for an extensionless file — which gets WizTree's `(No Extension)`
    /// label rather than being silently dropped or lumped into a catch-all.
    public static func displayName(forExtension ext: String?) -> String {
        guard let ext else { return noExtensionLabel }
        return names[ext] ?? "\(ext.uppercased()) File"
    }
}
