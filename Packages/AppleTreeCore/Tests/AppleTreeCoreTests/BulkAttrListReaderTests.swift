import Foundation
import Testing
@testable import AppleTreeCore

@Suite("BulkAttrListReader")
struct BulkAttrListReaderTests {
    @Test("reads correct names, types, and sizes for a real fixture directory")
    func readsFixtureDirectory() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("appletree-bulkattr-test-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("subdir"), withIntermediateDirectories: true)
        try Data(repeating: 0, count: 100).write(to: root.appendingPathComponent("file1.txt"))
        try Data(repeating: 0, count: 250).write(to: root.appendingPathComponent("file2.txt"))

        let entries = try BulkAttrListReader.readEntries(at: root.path)
        let byName = Dictionary(uniqueKeysWithValues: entries.map { ($0.name, $0) })

        #expect(entries.count == 3)
        #expect(byName["subdir"]?.isDirectory == true)
        #expect(byName["file1.txt"]?.isDirectory == false)
        #expect(byName["file1.txt"]?.totalSize == 100)
        #expect(byName["file2.txt"]?.totalSize == 250)
    }

    @Test("throws rather than crashing for a nonexistent path")
    func throwsForMissingPath() {
        #expect(throws: BulkAttrListReader.ReadError.self) {
            try BulkAttrListReader.readEntries(at: "/nonexistent-\(UUID().uuidString)")
        }
    }
}
