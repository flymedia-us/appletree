import Foundation
import Testing
@testable import AppleTreeCore

@Suite("DirectoryScanner")
struct DirectoryScannerTests {
    /// Builds a small fixture tree:
    ///   root/file1.txt        (100 bytes)
    ///   root/hardlink.txt     (hardlink to file1.txt — same inode, must not double-count)
    ///   root/subdir/file2.txt (200 bytes)
    ///   root/subdir2/         (empty directory)
    private func makeFixture() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("appletree-scanner-test-\(UUID().uuidString)", isDirectory: true)
        let subdir = root.appendingPathComponent("subdir", isDirectory: true)
        let subdir2 = root.appendingPathComponent("subdir2", isDirectory: true)

        try FileManager.default.createDirectory(at: subdir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: subdir2, withIntermediateDirectories: true)

        let file1 = root.appendingPathComponent("file1.txt")
        let file2 = subdir.appendingPathComponent("file2.txt")
        try Data(repeating: 0, count: 100).write(to: file1)
        try Data(repeating: 0, count: 200).write(to: file2)

        let hardlink = root.appendingPathComponent("hardlink.txt")
        try FileManager.default.linkItem(at: file1, to: hardlink)

        return root
    }

    @Test("scans real fixture tree, reports correct total size and dedups hardlinks")
    func scansFixtureTree() async throws {
        let root = try makeFixture()
        defer { try? FileManager.default.removeItem(at: root) }

        let scanner = DirectoryScanner()
        var rootNode: FileNode?
        var finished = false
        var foldersSkipped = -1
        var filesScanned = -1

        for try await event in await scanner.scan(root: root) {
            switch event {
            case .rootCreated(let node):
                rootNode = node
            case .finished(_, let scannedCount, let skipped, _):
                finished = true
                filesScanned = scannedCount
                foldersSkipped = skipped
            case .failed(let error):
                Issue.record("scan failed: \(error)")
            default:
                break
            }
        }

        #expect(finished)
        #expect(foldersSkipped == 0)
        // file1.txt + hardlink.txt (shared inode, counted once) + file2.txt
        #expect(filesScanned == 3)

        let node = try #require(rootNode)
        #expect(node.logicalSize == 300) // 100 + 200, hardlink NOT double-counted
        #expect(node.fileCount == 3)
        #expect(node.folderCount == 2)
    }

    /// Regression test for a real bug found while stress-testing against a
    /// ~40K-file SDK tree: `fts_read` emits a phantom post-order `FTS_DP`
    /// even for a directory that was `FTS_SKIP`'d at its pre-order `FTS_D`
    /// (confirmed empirically — undocumented either way in BSD's `fts` man
    /// page). Every directory promoted to a spawned `Task` gets
    /// `fts_set(..., FTS_SKIP)`'d in the *current* fts session, so without
    /// tagging skipped entries via `fts_number` and checking it in the
    /// `FTS_DP` case, that phantom close pops `stack` for a directory that
    /// was never pushed — silently misattributing every subsequent inline
    /// sibling/descendant to the wrong (shallower) ancestor. With
    /// `maxConcurrentWorkers: 1`, the first sibling `fts` encounters always
    /// wins the sole slot (a synchronous, lock-based `tryAcquire`) and gets
    /// spawned+skipped, forcing every other sibling inline — deterministically
    /// reproducing the interleaving that triggered the bug.
    @Test("a spawned-and-skipped sibling directory never corrupts inline siblings' parenting")
    func skippedSiblingDoesNotCorruptInlineSiblings() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("appletree-fts-skip-test-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let siblingCount = 20
        for i in 0..<siblingCount {
            let nested = root.appendingPathComponent("sibling\(i)/nested", isDirectory: true)
            try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
            try Data(repeating: 0, count: 10).write(to: nested.appendingPathComponent("leaf.txt"))
        }

        let scanner = DirectoryScanner()
        var rootNode: FileNode?
        for try await event in await scanner.scan(root: root, options: ScanOptions(maxConcurrentWorkers: 1)) {
            if case .rootCreated(let node) = event { rootNode = node }
        }

        let node = try #require(rootNode)
        #expect(node.fileCount == siblingCount, "every sibling's nested leaf.txt must be counted")
        #expect(node.folderCount == siblingCount * 2, "each sibling contributes itself + its own 'nested' subdirectory")
        #expect(node.children.count == siblingCount, "every sibling must be a DIRECT child of root, not misattributed elsewhere")

        for child in node.children {
            #expect(child.children.count == 1, "sibling \(child.name) must have exactly its own 'nested' subdirectory as a child")
            guard let nestedChild = child.children.first else { continue }
            #expect(nestedChild.name == "nested")
            #expect(nestedChild.children.count == 1, "'nested' must contain exactly its own leaf.txt")
            #expect(nestedChild.children.first?.name == "leaf.txt")
        }
    }

    /// Regression test for the most severe bug found in this project: a
    /// real whole-drive scan reported ~67GB instead of the true ~556GB.
    /// Root cause — `fts` visits an unreadable (permission-denied)
    /// directory as `FTS_D` (it can stat the entry) immediately followed by
    /// `FTS_DNR` (it can't read the contents), and confirmed empirically:
    /// NO `FTS_DP` ever follows for it. An inline (stack-pushed) directory
    /// that turns out to be unreadable therefore became a permanent orphan
    /// on top of the stack — every real ancestor above it failed its own
    /// path-match check forever, undercounting the entire chain up to the
    /// scan root. `maxConcurrentWorkers: 1` forces every sibling after the
    /// first to go inline (see the sibling-corruption test above for why),
    /// so the unreadable directory here is guaranteed to be inline, not
    /// spawned-and-skipped — the exact shape that triggered the real bug.
    @Test("an unreadable (permission-denied) inline directory doesn't orphan the stack and undercount its ancestors")
    func unreadableInlineDirectoryDoesNotOrphanStack() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("appletree-fts-dnr-test-\(UUID().uuidString)", isDirectory: true)
        let blocked = root.appendingPathComponent("blocked", isDirectory: true)
        let after = root.appendingPathComponent("after", isDirectory: true)
        try FileManager.default.createDirectory(at: blocked, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: after, withIntermediateDirectories: true)
        try Data(repeating: 0, count: 10).write(to: after.appendingPathComponent("f1.txt"))
        try Data(repeating: 0, count: 10).write(to: after.appendingPathComponent("f2.txt"))
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: blocked.path)
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: blocked.path)
            try? FileManager.default.removeItem(at: root)
        }

        let scanner = DirectoryScanner()
        var rootNode: FileNode?
        var foldersSkipped = -1
        var skipReason: FolderSkipReason?
        for try await event in await scanner.scan(root: root, options: ScanOptions(maxConcurrentWorkers: 1)) {
            switch event {
            case .rootCreated(let node): rootNode = node
            case .finished(_, _, let skipped, _): foldersSkipped = skipped
            case .folderSkipped(_, let reason): skipReason = reason
            default: break
            }
        }

        let node = try #require(rootNode)
        #expect(foldersSkipped == 1, "the unreadable directory must be reported as skipped, not silently swallowed")
        #expect(node.fileCount == 2, "content in 'after' (a sibling processed later in the SAME inline chain) must still be counted, not lost because 'blocked' orphaned the stack")
        #expect(node.folderCount == 2, "'blocked' and 'after' both count as real (sub)directories even though one is unreadable")
        #expect(skipReason == .accessDenied, "a directory this process's own chmod blocked is a plain Unix permission denial (EACCES), not TCC (EPERM) — must not be misclassified as Full-Disk-Access-recoverable")
    }

    /// Runs `hdiutil` synchronously, throwing on a nonzero exit — used to
    /// create/attach/detach a small disposable disk image as a stand-in for
    /// "a genuinely separate mounted volume reachable under the scan root."
    /// A `.dmg` is just a loopback-backed file, distinct from any of the
    /// user's actual external disks — safe to create, mount, and destroy
    /// entirely within this test.
    private func runHdiutil(_ arguments: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/hdiutil")
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let output = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            struct HdiutilFailed: Error, CustomStringConvertible { let description: String }
            throw HdiutilFailed(description: "hdiutil \(arguments.joined(separator: " ")) failed: \(output)")
        }
    }

    /// Regression test for a real bug found live: scanning "Macintosh HD"
    /// also scanned an entirely unrelated external Plex HDD mounted under
    /// /Volumes. Root cause — every subdirectory promoted to a spawned
    /// worker opens its *own* `fts_open` session, which resets `FTS_XDEV`'s
    /// "stay on one device" baseline to wherever that subtree happens to
    /// live, silently defeating it for any real device boundary crossed
    /// that way. A real external drive is impractical (and per the task,
    /// off-limits) to touch in an automated test, so this mounts a small
    /// disposable disk image *inside* the scan root instead — a genuinely
    /// different `st_dev`, the exact mechanism the bug hinges on, without
    /// touching any of the user's actual external disks.
    @Test("a genuinely different volume mounted inside the scan root is not descended into")
    func doesNotCrossOntoADifferentMountedVolume() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("appletree-xdev-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        // A same-device file, to prove the fix isn't overzealous — it must
        // still be counted normally.
        try Data(repeating: 0, count: 10).write(to: root.appendingPathComponent("local.txt"))

        let dmgPath = root.deletingLastPathComponent()
            .appendingPathComponent("appletree-xdev-test-\(UUID().uuidString).dmg").path
        let mountPoint = root.appendingPathComponent("other-volume", isDirectory: true)
        try FileManager.default.createDirectory(at: mountPoint, withIntermediateDirectories: true)

        try runHdiutil(["create", "-size", "5m", "-fs", "APFS", "-volname", "AppleTreeXDevTest", dmgPath])
        defer { try? FileManager.default.removeItem(atPath: dmgPath) }
        try runHdiutil(["attach", dmgPath, "-mountpoint", mountPoint.path, "-nobrowse"])
        defer { try? runHdiutil(["detach", mountPoint.path, "-force"]) }

        try Data(repeating: 0, count: 999).write(to: mountPoint.appendingPathComponent("should-not-be-scanned.bin"))

        let scanner = DirectoryScanner()
        var rootNode: FileNode?
        for try await event in await scanner.scan(root: root) {
            if case .rootCreated(let node) = event { rootNode = node }
        }

        let node = try #require(rootNode)
        #expect(node.fileCount == 1, "only local.txt should be counted — the mounted volume's content must be excluded")
        #expect(node.folderCount == 0, "the mount point itself doesn't count as a folder either — it's excluded outright, not shown empty")
        #expect(node.logicalSize == 10, "the mounted volume's 999-byte file must not contribute to the scan's size")
        #expect(
            node.children.first { $0.name == "other-volume" } == nil,
            "the mount point for a different device is excluded outright, not shown as an empty entry — a whole separate disk reading as \"an empty folder\" would be its own kind of confusing"
        )
    }

    /// Regression test for a correctness risk introduced by reading names
    /// straight out of `fts_path`'s raw bytes (via `fts_pathlen`/
    /// `fts_namelen`) instead of `NSString.lastPathComponent`, as a
    /// performance fix for the per-entry hot path: `fts_namelen` is a
    /// *byte* count, and slicing a Swift `String` by anything other than
    /// byte count (e.g. `String.suffix(_:)`, which counts grapheme
    /// clusters) would silently mis-slice any multi-byte name — so the
    /// actual fix reads the name from the raw C buffer via `String(cString:)`
    /// instead, which decodes UTF-8 correctly regardless. Covers emoji
    /// (multi-scalar grapheme clusters), accented Latin (APFS may store
    /// these NFD-normalized on disk, different bytes than written — Swift's
    /// `String ==` is canonically-equivalence-aware, so this doesn't need
    /// special-casing), and CJK (every byte is part of a multi-byte
    /// sequence, no ASCII fallback to accidentally paper over a bug).
    @Test("names with multi-byte UTF-8 characters (emoji, accents, CJK) are read correctly for both files and directories")
    func nonASCIINamesReadCorrectly() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("appletree-utf8-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let names = ["🎉party.txt", "café.txt", "日本語ファイル.txt", "Ünïcödé Dir"]
        for name in names {
            let url = root.appendingPathComponent(name, isDirectory: name.hasSuffix("Dir"))
            if name.hasSuffix("Dir") {
                try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            } else {
                try Data([0x01]).write(to: url)
            }
        }

        let scanner = DirectoryScanner()
        var rootNode: FileNode?
        for try await event in await scanner.scan(root: root) {
            if case .rootCreated(let node) = event { rootNode = node }
        }

        let node = try #require(rootNode)
        let scannedNames = Set(node.children.map(\.name))
        #expect(scannedNames == Set(names), "every multi-byte name must round-trip exactly, not just its ASCII portion")
    }

    @Test("FolderSkipReason classifies errno (and, for EPERM, path) correctly", arguments: [
        (EPERM, "/Users/sam/Library/Mail", FolderSkipReason.tccDenied, "a user's own ~/Library is FDA territory"),
        (EPERM, "/Users/sam/Library/Application Support/MobileSync", FolderSkipReason.tccDenied, "iOS backups live under ~/Library too"),
        (EPERM, "/Users/otheruser/Library/Messages", FolderSkipReason.tccDenied, "FDA's own description covers all users on the Mac, not just the current one"),
        (EPERM, "/Users/sam/Desktop", FolderSkipReason.tccDenied, "Desktop is protected by Files and Folders privacy"),
        (EPERM, "/Users/sam/Documents/Taxes", FolderSkipReason.tccDenied, "Documents is protected by Files and Folders privacy"),
        (EPERM, "/Users/sam/Downloads", FolderSkipReason.tccDenied, "the exact Downloads root can require FDA during a broader user-selected scan"),
        (EPERM, "/Users/sam/Downloads/archive", FolderSkipReason.tccDenied, "Downloads descendants can require FDA without the folder-specific entitlement"),
        (EPERM, "/Users/sam/Pictures/Photos Library.photoslibrary", FolderSkipReason.tccDenied, "Pictures is privacy protected"),
        (EPERM, "/Users/sam/Music/Music", FolderSkipReason.tccDenied, "Music is privacy protected"),
        (EPERM, "/Users/sam/Movies/Home Videos", FolderSkipReason.tccDenied, "Movies is privacy protected"),
        (EPERM, "/Users/sam/Library/Keychains/576FDE0F-6E6F-55B1", FolderSkipReason.systemProtected, "Keychains are excluded from FDA's scope even though they live under ~/Library"),
        (EPERM, "/private/var/db/Spotlight-V100", FolderSkipReason.systemProtected, "root-owned system daemon state"),
        (EPERM, "/var/db/lockdown", FolderSkipReason.systemProtected, "root-owned system daemon state, /var form"),
        (EPERM, "/Library/Caches/com.apple.aneuserd", FolderSkipReason.systemProtected, "top-level /Library is root-owned system data, not a user's ~/Library"),
        (EPERM, "/System/Library/AssetsV2/com_apple_MobileAsset_UAF_FM_Visual", FolderSkipReason.systemProtected, "SIP-protected OS content"),
        (EACCES, "/Users/other/Documents", FolderSkipReason.accessDenied, "plain Unix permission bit, not TCC"),
        (ENOENT, "/some/path", FolderSkipReason.other(errno: ENOENT), "unrelated errno falls through to .other"),
    ])
    func folderSkipReasonClassifiesErrno(errno: Int32, path: String, expected: FolderSkipReason, comment: String) {
        #expect(FolderSkipReason(errno: errno, path: path) == expected, "\(comment)")
    }

    @Test("ioThrottled option still produces a correct scan")
    func ioThrottledOptionScansCorrectly() async throws {
        let root = try makeFixture()
        defer { try? FileManager.default.removeItem(at: root) }

        let scanner = DirectoryScanner()
        var rootNode: FileNode?
        for try await event in await scanner.scan(root: root, options: ScanOptions(ioThrottled: true)) {
            if case .rootCreated(let node) = event { rootNode = node }
        }

        let node = try #require(rootNode)
        #expect(node.fileCount == 3)
        #expect(node.logicalSize == 300)
    }

    @Test("cancelling the consuming task stops the scan without hanging")
    func cancellationStopsScan() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("appletree-scanner-cancel-test-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        // Enough nested work that cancellation has something to interrupt.
        for i in 0..<20 {
            let dir = root.appendingPathComponent("dir\(i)", isDirectory: true)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            for j in 0..<20 {
                try Data(repeating: 0, count: 16).write(to: dir.appendingPathComponent("file\(j).txt"))
            }
        }

        let scanner = DirectoryScanner()
        let consumer = Task { () -> Int in
            var count = 0
            for try await _ in await scanner.scan(root: root) {
                count += 1
            }
            return count
        }
        consumer.cancel()

        // Must not hang: bound the wait and accept whatever partial result we get.
        let didFinish = await withTaskGroup(of: Bool.self) { group in
            group.addTask {
                _ = try? await consumer.value
                return true
            }
            group.addTask {
                try? await Task.sleep(for: .seconds(5))
                return false
            }
            let first = await group.next() ?? false
            group.cancelAll()
            return first
        }

        #expect(didFinish, "scan did not stop within the timeout after cancellation")
    }

    @Test("a naturally completed scan emits .finished, not .cancelled")
    func completedScanEmitsFinished() async throws {
        let root = try makeFixture()
        defer { try? FileManager.default.removeItem(at: root) }

        let scanner = DirectoryScanner()
        var sawFinished = false
        var sawCancelled = false
        for try await event in await scanner.scan(root: root) {
            switch event {
            case .finished: sawFinished = true
            case .cancelled: sawCancelled = true
            default: break
            }
        }
        #expect(sawFinished)
        #expect(!sawCancelled)
    }
}
