import Testing
@testable import AppleTreeCore

@Suite("FileCategorizer")
struct FileCategorizerTests {
    @Test("recognized extensions map to their category, case-insensitively")
    func recognizedExtensions() {
        #expect(FileCategorizer.category(forFileName: "movie.mp4") == .video)
        #expect(FileCategorizer.category(forFileName: "MOVIE.MP4") == .video)
        #expect(FileCategorizer.category(forFileName: "photo.JPG") == .image)
        #expect(FileCategorizer.category(forFileName: "song.mp3") == .audio)
        #expect(FileCategorizer.category(forFileName: "main.swift") == .codeOrDeveloper)
        #expect(FileCategorizer.category(forFileName: "archive.zip") == .archive)
        #expect(FileCategorizer.category(forFileName: "Installer.pkg") == .archive) // .pkg/.dmg are container formats, grouped with .archive
        #expect(FileCategorizer.category(forFileName: "MyApp.app") == .application)
        #expect(FileCategorizer.category(forFileName: "Info.plist") == .system)
        #expect(FileCategorizer.category(forFileName: "report.pdf") == .document)
    }

    @Test("last extension wins for multi-dot names")
    func lastExtensionWins() {
        #expect(FileCategorizer.category(forFileName: "archive.tar.gz") == .archive)
    }

    @Test("unrecognized but present extension categorizes as other, never noExtension")
    func unrecognizedExtensionIsOther() {
        #expect(FileCategorizer.category(forFileName: "file.xyzabc123") == .other)
    }

    @Test(
        "files with genuinely no extension always categorize as noExtension, never other",
        arguments: ["README", "Makefile", "no_dot_here", ""]
    )
    func noExtensionFiles(name: String) {
        #expect(FileCategorizer.category(forFileName: name) == .noExtension)
    }

    @Test(
        "dotfiles (leading dot only) are treated as having no extension, not an extension named after the dotfile",
        arguments: [".gitignore", ".env", ".DS_Store", ".bashrc"]
    )
    func dotfilesAreNoExtension(name: String) {
        #expect(FileCategorizer.category(forFileName: name) == .noExtension)
    }

    @Test("trailing dot with empty suffix is treated as no extension")
    func trailingDotIsNoExtension() {
        #expect(FileCategorizer.category(forFileName: "name.") == .noExtension)
    }
}
