import AppleTreeCore
import Darwin
import Foundation

/// Throwaway CLI harness for manually verifying/benchmarking `DirectoryScanner`
/// against real folders, and for the M6 getattrlistbulk-vs-fts evaluation.
/// Not part of the app; not covered by unit tests.
///
/// Usage:
///   swift run scanbench [path] [--workers N]       — full recursive scan (default: home directory)
///   swift run scanbench --bulkbench <dir> [iters]  — single-directory fts vs getattrlistbulk benchmark

if CommandLine.arguments.count > 1, CommandLine.arguments[1] == "--bulkbench" {
    guard CommandLine.arguments.count > 2 else {
        print("usage: scanbench --bulkbench <directory> [iterations]")
        exit(1)
    }
    let path = CommandLine.arguments[2]
    let iterations = CommandLine.arguments.count > 3 ? Int(CommandLine.arguments[3]) ?? 20 : 20
    runBulkBench(path: path, iterations: iterations)
} else {
    var path: String?
    var workers: Int?
    var args = Array(CommandLine.arguments.dropFirst())[...]
    while let arg = args.first {
        args = args.dropFirst()
        if arg == "--workers", let value = args.first {
            workers = Int(value)
            args = args.dropFirst()
        } else if path == nil {
            path = arg
        }
    }
    await runFullScan(path: path, workers: workers)
}

/// Non-recursive single-directory enumeration via `fts`, reading name + type
/// + logical/allocated size for every immediate entry — the same information
/// `BulkAttrListReader` extracts, so the two are a fair apples-to-apples
/// comparison of "list one directory's entries with size info", isolating
/// the syscall-batching question from traversal/recursion (which stays
/// fts's job in `DirectoryScanner` either way).
func ftsListDirectory(at path: String) -> Int {
    guard let cPath = strdup(path) else { return 0 }
    defer { free(cPath) }
    var argv: [UnsafeMutablePointer<CChar>?] = [cPath, nil]
    guard let ftsp = argv.withUnsafeMutableBufferPointer({ buf in
        fts_open(buf.baseAddress, FTS_PHYSICAL | FTS_NOCHDIR, nil)
    }) else { return 0 }
    defer { fts_close(ftsp) }

    var count = 0
    while let entp = fts_read(ftsp) {
        let level = entp.pointee.fts_level
        guard level == 1 else { continue } // immediate children only, non-recursive

        let info = Int32(entp.pointee.fts_info)
        if info == FTS_D {
            // A subdirectory child: don't descend into it (this benchmark is
            // single-level, matching what getattrlistbulk's non-recursive
            // fd-based read does) and don't double-count it — FTS_D (pre-
            // order) and FTS_DP (post-order) are the same directory visited
            // twice; only count the pre-order visit.
            fts_set(ftsp, entp, FTS_SKIP)
            count += 1
            continue
        }
        if info == FTS_DP { continue } // post-order revisit of an already-counted directory

        guard let statp = entp.pointee.fts_statp else { continue }
        _ = statp.pointee.st_size
        _ = statp.pointee.st_blocks
        count += 1
    }
    return count
}

func runBulkBench(path: String, iterations: Int) {
    print("Benchmarking single-directory enumeration at \(path), \(iterations) iterations each.\n")

    let entryCount = (try? BulkAttrListReader.readEntries(at: path))?.count ?? 0
    print("Directory has \(entryCount) entries.\n")

    let ftsStart = ContinuousClock.now
    var ftsTotal = 0
    for _ in 0..<iterations {
        ftsTotal += ftsListDirectory(at: path)
    }
    let ftsElapsed = ContinuousClock.now - ftsStart

    let bulkStart = ContinuousClock.now
    var bulkTotal = 0
    for _ in 0..<iterations {
        bulkTotal += (try? BulkAttrListReader.readEntries(at: path))?.count ?? 0
    }
    let bulkElapsed = ContinuousClock.now - bulkStart

    print("fts:              \(ftsElapsed) total, \(ftsElapsed / iterations) avg/run, \(ftsTotal / iterations) entries/run")
    print("getattrlistbulk:  \(bulkElapsed) total, \(bulkElapsed / iterations) avg/run, \(bulkTotal / iterations) entries/run")

    let ftsSeconds = Double(ftsElapsed.components.seconds) + Double(ftsElapsed.components.attoseconds) / 1e18
    let bulkSeconds = Double(bulkElapsed.components.seconds) + Double(bulkElapsed.components.attoseconds) / 1e18
    if bulkSeconds > 0 {
        let speedup = ftsSeconds / bulkSeconds
        print(String(format: "\ngetattrlistbulk is %.2fx the speed of fts for this workload.", speedup))
    }
}

func runFullScan(path: String? = nil, workers: Int? = nil) async {
    let targetPath = path ?? FileManager.default.homeDirectoryForCurrentUser.path
    let root = URL(fileURLWithPath: targetPath)

    print("Scanning \(root.path)\(workers.map { " (maxConcurrentWorkers: \($0))" } ?? " (default worker count)") ...")

    let scanner = DirectoryScanner()
    let options = ScanOptions(maxConcurrentWorkers: workers)
    var totalFiles = 0
    var totalSkipped = 0
    var totalTccDenied = 0
    var totalBytes: UInt64 = 0
    var rootNode: FileNode?

    do {
        for try await event in await scanner.scan(root: root, options: options) {
            switch event {
            case .rootCreated(let node):
                rootNode = node
            case .progress(let files, let folders, let bytes, let path):
                print("  ...\(files) files, \(folders) folders, \(ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)) (\(path ?? ""))")
            case .folderSkipped(let path, let reason):
                totalSkipped += 1
                print("  skipped: \(path) (\(reason))")
            case .finished(let duration, let filesScanned, let foldersSkipped, let tccDeniedFolders):
                totalFiles = filesScanned
                totalSkipped = foldersSkipped
                totalTccDenied = tccDeniedFolders
                print("Done in \(duration).")
            case .subtreeCompleted, .failed:
                break
            }
        }
    } catch {
        print("scan failed: \(error)")
    }

    if let node = rootNode {
        totalBytes = node.displaySize
        print("""
        Root: \(node.path)
        Total size (allocated): \(ByteCountFormatter.string(fromByteCount: Int64(totalBytes), countStyle: .file))
        Total size (logical): \(ByteCountFormatter.string(fromByteCount: Int64(node.logicalSize), countStyle: .file))
        Files scanned: \(totalFiles)
        Folders skipped: \(totalSkipped) (\(totalTccDenied) blocked by Full Disk Access / TCC)
        Top-level children: \(node.children.count)
        """)
        // Sanity check: the tree's own aggregate should always match the
        // live running counter — any divergence means some subtree's
        // finalize never ran (or ran against an incomplete children list),
        // which is exactly the shape of bug this project has hit twice.
        if node.fileCount != totalFiles {
            print("[WARNING] tree aggregate fileCount (\(node.fileCount)) != live counter (\(totalFiles)) — scanner undercount bug likely present")
        }
    }
}
