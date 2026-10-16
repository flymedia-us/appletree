import Foundation
@testable import AppleTreeCore
import Testing
@testable import AppleTreeUI

@Suite("Deletion behavior")
struct DeleteOperationTests {
    private let home = URL(fileURLWithPath: "/Users/tester")
    private let card = URL(fileURLWithPath: "/Volumes/Test Card")

    @Test("deletion is unavailable while a scan is building the tree or an ancestor is removed")
    @MainActor
    func deletionAvailability() {
        let coordinator = FileTreeView.Coordinator(selection: SelectionModel())
        let parent = FileNode(name: "folder", isDirectory: true)
        let child = FileNode(name: "file", isDirectory: false)
        parent.addChild(child)
        #expect(coordinator.canDelete(child))
        coordinator.lastIsScanning = true
        #expect(!coordinator.canDelete(child))
        coordinator.lastIsScanning = false
        parent.markRemoved()
        #expect(!coordinator.canDelete(child))
    }

    @Test("default mode permanently deletes native Trash contents", arguments: [
        "/Volumes/Test Card/.Trashes/501",
        "/Volumes/Test Card/.Trashes/501/DCIM/photo.jpg",
        "/Users/tester/.Trash/old-folder/file.txt",
        "/.Trashes/501/file.txt"
    ])
    func nativeTrash(path: String) {
        #expect(DeleteOperation.forItem(
            at: URL(fileURLWithPath: path), volumeRoot: card, homeDirectory: home
        ) == .permanentlyDelete)
    }

    @Test("native Trash containers are emptied rather than removed", arguments: [
        "/Volumes/Test Card/.Trashes", "/Users/tester/.Trash", "/.Trashes"
    ])
    func trashContainer(path: String) {
        #expect(DeleteOperation.forItem(
            at: URL(fileURLWithPath: path), volumeRoot: card, homeDirectory: home
        ) == .emptyTrash)
    }

    @Test("ordinary items and lookalike folder names still go to Trash", arguments: [
        "/Volumes/Test Card/DCIM/photo.jpg",
        "/Volumes/Test Card/projects/.Trashes/file.txt",
        "/Volumes/Test Card/.Trashes-backup/file.txt",
        "/Volumes/Test Card/.Trash/file.txt",
        "/Users/tester/.Trash-backup/file.txt",
        "/Users/tester/projects/.Trash/file.txt",
        "/Users/someone-else/.Trash/file.txt",
        "/Volumes/Another Card/.Trashes/file.txt"
    ])
    func ordinaryItems(path: String) {
        #expect(DeleteOperation.forItem(
            at: URL(fileURLWithPath: path), volumeRoot: card, homeDirectory: home
        ) == .moveToTrash)
    }

    @Test("internal Data volume Trash is recognized")
    func internalDataVolume() {
        #expect(DeleteOperation.forItem(
            at: URL(fileURLWithPath: "/System/Volumes/Data/.Trashes/501/file.txt"),
            volumeRoot: URL(fileURLWithPath: "/System/Volumes/Data"), homeDirectory: home
        ) == .permanentlyDelete)
    }

    @Test("a failed volume lookup never infers permanent deletion from a name")
    func missingVolume() {
        #expect(DeleteOperation.forItem(
            at: card.appendingPathComponent(".Trashes"), volumeRoot: nil, homeDirectory: home
        ) == .moveToTrash)
    }

    @Test("settings opt-in overrides the default for ordinary items")
    func permanentSetting() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture) }
        let item = fixture.appendingPathComponent("keep.txt")
        try Data("ordinary item".utf8).write(to: item)

        #expect(DeleteOperation.forItem(at: item) == .moveToTrash)
        #expect(DeleteOperation.forItem(at: item, deletePermanently: false) == .moveToTrash)
        let operation = DeleteOperation.forItem(at: item, deletePermanently: true)
        try operation.perform(at: item)
        #expect(!FileManager.default.fileExists(atPath: item.path))
    }

    @Test("permanent deletion always requires confirmation, even with Trash confirmations off")
    func mandatoryConfirmation() {
        #expect(DeleteOperation.permanentlyDelete.requiresConfirmation(preference: false))
        #expect(DeleteOperation.permanentlyDelete.requiresConfirmation(preference: true))
        #expect(DeleteOperation.emptyTrash.requiresConfirmation(preference: false))
        #expect(!DeleteOperation.moveToTrash.requiresConfirmation(preference: false))
        #expect(DeleteOperation.moveToTrash.requiresConfirmation(preference: true))
    }

    @Test("recursive removal deletes Trash contents and preserves unrelated siblings and symlink targets")
    func recursiveRemoval() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture) }
        let trash = fixture.appendingPathComponent(".Trashes")
        let contents = trash.appendingPathComponent("501/nested")
        try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
        try Data("trashed".utf8).write(to: contents.appendingPathComponent("old.txt"))
        let keep = fixture.appendingPathComponent("keep.txt")
        try Data("keep".utf8).write(to: keep)
        try FileManager.default.createSymbolicLink(at: contents.appendingPathComponent("link"), withDestinationURL: keep)

        let userTrash = trash.appendingPathComponent("501")
        let operation = DeleteOperation.forItem(at: userTrash, volumeRoot: fixture, homeDirectory: home)
        try operation.perform(at: userTrash)
        #expect(!FileManager.default.fileExists(atPath: userTrash.path))
        #expect(FileManager.default.fileExists(atPath: trash.path))
        #expect(try String(contentsOf: keep, encoding: .utf8) == "keep")
    }

    @Test("a symlink pointing into Trash remains an ordinary item")
    func linkToTrash() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture) }
        let trash = fixture.appendingPathComponent(".Trash")
        try FileManager.default.createDirectory(at: trash, withIntermediateDirectories: true)
        let link = fixture.appendingPathComponent("trash-link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: trash)
        #expect(DeleteOperation.forItem(at: link, volumeRoot: fixture, homeDirectory: fixture) == .moveToTrash)
    }

    @Test("ordinary deletion calls the recoverable Trash API")
    func usesTrashAPI() throws {
        let fileManager = RecordingFileManager()
        let url = URL(fileURLWithPath: "/test/ordinary.txt")
        try DeleteOperation.moveToTrash.perform(at: url, fileManager: fileManager)
        #expect(fileManager.trashed == url)
        #expect(fileManager.removed == nil)
    }

    @Test("permanently deleting a symlink preserves its target")
    func permanentSymlink() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture) }
        let keep = fixture.appendingPathComponent("keep.txt")
        try Data("keep".utf8).write(to: keep)
        let link = fixture.appendingPathComponent("link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: keep)
        try DeleteOperation.permanentlyDelete.perform(at: link)
        #expect(try String(contentsOf: keep, encoding: .utf8) == "keep")
        #expect(!FileManager.default.fileExists(atPath: link.path))
    }

    @Test("emptying Trash refuses a container replaced by a symlink")
    func replacedContainer() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture) }
        let keep = fixture.appendingPathComponent("keep")
        try FileManager.default.createDirectory(at: keep, withIntermediateDirectories: true)
        let file = keep.appendingPathComponent("keep.txt")
        try Data("keep".utf8).write(to: file)
        let trash = fixture.appendingPathComponent(".Trash")
        try FileManager.default.createDirectory(at: trash, withIntermediateDirectories: true)
        // Simulate metadata observed while constructing the confirmation.
        _ = try trash.resourceValues(forKeys: [.isSymbolicLinkKey])
        try FileManager.default.removeItem(at: trash)
        try FileManager.default.createSymbolicLink(at: trash, withDestinationURL: keep)
        #expect(throws: DeleteOperation.Failure.self) {
            try DeleteOperation.emptyTrash.perform(at: trash)
        }
        #expect(FileManager.default.fileExists(atPath: file.path))
    }

    @Test("emptying shared Trash refuses a symlink in the current user's directory")
    func replacedUserContainer() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture) }
        let trash = fixture.appendingPathComponent(".Trashes")
        let keep = fixture.appendingPathComponent("keep")
        try FileManager.default.createDirectory(at: trash, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: keep, withIntermediateDirectories: true)
        let file = keep.appendingPathComponent("keep.txt")
        try Data("keep".utf8).write(to: file)
        try FileManager.default.createSymbolicLink(at: trash.appendingPathComponent(String(getuid())), withDestinationURL: keep)
        #expect(throws: DeleteOperation.Failure.self) {
            try DeleteOperation.emptyTrash.perform(at: trash)
        }
        #expect(FileManager.default.fileExists(atPath: file.path))
    }

    @Test("failed deletion reports the attempted operation without falling back to direct removal")
    func failureMessage() throws {
        let fileManager = RecordingFileManager()
        fileManager.fail = true
        let url = URL(fileURLWithPath: "/test/ordinary.txt")
        do {
            try DeleteOperation.moveToTrash.perform(at: url, fileManager: fileManager)
            Issue.record("Expected Trash failure")
        } catch {
            #expect(error.localizedDescription.hasPrefix("Couldn't move to Trash:"))
            #expect(fileManager.removed == nil)
        }
        do {
            try DeleteOperation.permanentlyDelete.perform(at: url, fileManager: fileManager)
            Issue.record("Expected permanent deletion failure")
        } catch {
            #expect(error.localizedDescription.hasPrefix("Couldn't delete permanently:"))
        }
    }

    @Test("partially emptied Trash reports successes and keeps the failure actionable")
    func partialEmptyFailure() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture) }
        let fileManager = RecordingFileManager()
        let first = fixture.appendingPathComponent("removed.txt")
        let blocked = fixture.appendingPathComponent("blocked.txt")
        fileManager.contents = [first, blocked]
        fileManager.failRemovalOf = blocked
        do {
            try DeleteOperation.emptyTrash.perform(at: fixture, fileManager: fileManager)
            Issue.record("Expected partial failure")
        } catch let failure as DeleteOperation.Failure {
            #expect(failure.removedURLs == [first])
            #expect(failure.localizedDescription.hasPrefix("Couldn't empty Trash:"))
        }
    }

    @Test("emptying shared Trash with no folder for this user is a harmless no-op")
    func noUserTrash() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture) }
        let trash = fixture.appendingPathComponent(".Trashes")
        try FileManager.default.createDirectory(at: trash, withIntermediateDirectories: true)
        #expect(try DeleteOperation.emptyTrash.perform(at: trash).isEmpty)
        #expect(FileManager.default.fileExists(atPath: trash.path))
    }

    @Test("default deletion works on a real mounted volume's Trash")
    func mountedVolumeTrash() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture) }
        let image = fixture.appendingPathComponent("card.dmg")
        let volume = fixture.appendingPathComponent("volume")
        try FileManager.default.createDirectory(at: volume, withIntermediateDirectories: true)
        try hdiutil(["create", "-size", "5m", "-fs", "APFS", "-volname", "AppleTreeTrashTest", image.path])
        try hdiutil(["attach", image.path, "-mountpoint", volume.path, "-nobrowse"])
        defer { try? hdiutil(["detach", volume.path, "-force"]) }

        let ordinary = volume.appendingPathComponent("ordinary.txt")
        try Data("trash me".utf8).write(to: ordinary)
        let normalOperation = DeleteOperation.forItem(at: ordinary)
        #expect(normalOperation == .moveToTrash)
        try normalOperation.perform(at: ordinary)
        #expect(!FileManager.default.fileExists(atPath: ordinary.path))

        let trash = volume.appendingPathComponent(".Trashes")
        let userTrash = trash.appendingPathComponent(String(getuid()))
        let trashedFile = userTrash.appendingPathComponent("ordinary.txt")
        #expect(FileManager.default.fileExists(atPath: trashedFile.path))
        #expect(DeleteOperation.forItem(at: userTrash) == .permanentlyDelete)
        #expect(DeleteOperation.forItem(at: trashedFile) == .permanentlyDelete)
        let trashOperation = DeleteOperation.forItem(at: trash)
        #expect(trashOperation == .emptyTrash)
        #expect(DeleteOperation.forItem(at: trash, deletePermanently: true) == .emptyTrash)
        let otherUser = trash.appendingPathComponent("999999/keep.txt")
        try FileManager.default.createDirectory(at: otherUser.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("other user's trash".utf8).write(to: otherUser)

        let removed = try trashOperation.perform(at: trash)
        #expect(removed.contains(trashedFile))
        #expect(removed.allSatisfy { $0.deletingLastPathComponent() == userTrash })
        #expect(!FileManager.default.fileExists(atPath: trashedFile.path))
        #expect(FileManager.default.fileExists(atPath: trash.path))
        #expect(FileManager.default.fileExists(atPath: userTrash.path))
        #expect(FileManager.default.fileExists(atPath: otherUser.path))

        // The preserved container continues to work for later Trash moves.
        try Data("again".utf8).write(to: ordinary)
        try normalOperation.perform(at: ordinary)
        #expect(FileManager.default.fileExists(atPath: trashedFile.path))
    }

    @Test("emptying a personal Trash retains the container and accounts for removed children")
    @MainActor
    func personalTrashAndTotals() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture) }
        let trash = fixture.appendingPathComponent(".Trash")
        try FileManager.default.createDirectory(at: trash, withIntermediateDirectories: true)
        let file = trash.appendingPathComponent("old.txt")
        try Data("old".utf8).write(to: file)

        let parent = FileNode(name: fixture.lastPathComponent, isDirectory: true, rootPath: fixture.path)
        let container = FileNode(name: ".Trash", isDirectory: true, parent: parent)
        let old = FileNode(name: "old.txt", isDirectory: false, logicalSize: 3, allocatedSize: 3, fileCount: 1, parent: container)
        container.addChild(old)
        container.finalizeAsDirectory()
        parent.addChild(container)
        parent.finalizeAsDirectory()
        #expect(parent.displaySize == 3)

        let operation = DeleteOperation.forItem(at: trash, volumeRoot: fixture, homeDirectory: fixture)
        let removed = try operation.perform(at: trash)
        let coordinator = FileTreeView.Coordinator(selection: SelectionModel())
        var didNotify = false
        coordinator.onTreeMutated = { didNotify = true }
        coordinator.applyDeletions(removed, within: container)
        #expect(didNotify)
        #expect(old.isRemoved)
        #expect(!container.isRemoved)
        #expect(container.displaySize == 0)
        #expect(parent.displaySize == 0)
        #expect(parent.fileCount == 0)
        #expect(FileManager.default.fileExists(atPath: trash.path))
    }

    private func hdiutil(_ arguments: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/hdiutil")
        process.arguments = arguments
        let output = Pipe()
        process.standardOutput = output
        process.standardError = output
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw NSError(domain: "AppleTreeTrashTest", code: Int(process.terminationStatus), userInfo: [
                NSLocalizedDescriptionKey: String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            ])
        }
    }

    private func makeFixture() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("appletree-delete-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}

private final class RecordingFileManager: FileManager, @unchecked Sendable {
    var trashed: URL?
    var removed: URL?
    var fail = false
    var failRemovalOf: URL?
    var contents: [URL] = []

    override func trashItem(at url: URL, resultingItemURL: AutoreleasingUnsafeMutablePointer<NSURL?>?) throws {
        trashed = url
        if fail { throw CocoaError(.fileWriteNoPermission) }
    }

    override func removeItem(at url: URL) throws {
        removed = url
        if fail || url == failRemovalOf { throw CocoaError(.fileWriteNoPermission) }
    }

    override func contentsOfDirectory(at url: URL, includingPropertiesForKeys keys: [URLResourceKey]?, options mask: FileManager.DirectoryEnumerationOptions = []) throws -> [URL] {
        contents
    }
}
