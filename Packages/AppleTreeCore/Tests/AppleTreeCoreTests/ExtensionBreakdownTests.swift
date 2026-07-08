import Testing
@testable import AppleTreeCore

@Suite("ExtensionBreakdown")
struct ExtensionBreakdownTests {
    private func makeDirectory(name: String, children: [FileNode]) -> FileNode {
        let dir = FileNode(name: name, isDirectory: true)
        for child in children { dir.addChild(child) }
        dir.finalizeAsDirectory()
        return dir
    }

    private func makeFile(name: String, size: UInt64) -> FileNode {
        FileNode(name: name, isDirectory: false, logicalSize: size, allocatedSize: size)
    }

    @Test("aggregates size and count per extension across the whole tree, sorted by size descending")
    func aggregatesAcrossTree() {
        let subfolder = makeDirectory(name: "sub", children: [
            makeFile(name: "clip1.mp4", size: 100),
            makeFile(name: "clip2.mp4", size: 50)
        ])
        let root = makeDirectory(name: "root", children: [
            subfolder,
            makeFile(name: "photo.jpg", size: 10),
            makeFile(name: "notes.txt", size: 5)
        ])

        let summaries = ExtensionBreakdown.compute(for: root)

        #expect(summaries.count == 3)
        #expect(summaries[0].fileExtension == "mp4")
        #expect(summaries[0].totalSize == 150)
        #expect(summaries[0].fileCount == 2)
        #expect(summaries[0].fileTypeName == "MP4 File")
        // "photo.jpg" canonicalizes to the "jpeg" bucket — see
        // `jpgAndJpegFilesShareOneRow` below.
        #expect(summaries[1].fileExtension == "jpeg")
        #expect(summaries[2].fileExtension == "txt")
    }

    @Test("jpg, JPG, jpeg, and JPEG files all aggregate into one combined \"jpeg\" row, not split across two")
    func jpgAndJpegFilesShareOneRow() {
        let root = makeDirectory(name: "root", children: [
            makeFile(name: "a.jpg", size: 100),
            makeFile(name: "b.JPG", size: 50),
            makeFile(name: "c.jpeg", size: 20),
            makeFile(name: "d.JPEG", size: 10)
        ])

        let summaries = ExtensionBreakdown.compute(for: root)

        #expect(summaries.count == 1)
        #expect(summaries[0].fileExtension == "jpeg")
        #expect(summaries[0].fileTypeName == "JPEG Image")
        #expect(summaries[0].totalSize == 180)
        #expect(summaries[0].fileCount == 4)
    }

    @Test("extensionless files are grouped under a nil-extension (No Extension) row, not dropped")
    func noExtensionIsFirstClass() {
        let root = makeDirectory(name: "root", children: [
            makeFile(name: "README", size: 20),
            makeFile(name: "Makefile", size: 10)
        ])

        let summaries = ExtensionBreakdown.compute(for: root)

        #expect(summaries.count == 1)
        #expect(summaries[0].fileExtension == nil)
        #expect(summaries[0].fileTypeName == FileTypeNaming.noExtensionLabel)
        #expect(summaries[0].totalSize == 30)
        #expect(summaries[0].fileCount == 2)
    }

    @Test("an extension with no curated name falls back to a generic '<EXT> File' description")
    func uncuratedExtensionFallsBack() {
        #expect(FileTypeNaming.displayName(forExtension: "xyzabc") == "XYZABC File")
    }

    @Test("a node marked removed (moved to Trash, or found gone externally) is excluded from the breakdown")
    func removedNodeIsExcluded() {
        let doomed = makeFile(name: "clip.mp4", size: 100)
        let root = makeDirectory(name: "root", children: [
            doomed,
            makeFile(name: "photo.jpg", size: 10)
        ])

        doomed.markRemoved()
        let summaries = ExtensionBreakdown.compute(for: root)

        #expect(summaries.count == 1)
        #expect(summaries[0].fileExtension == "jpeg")
    }
}
