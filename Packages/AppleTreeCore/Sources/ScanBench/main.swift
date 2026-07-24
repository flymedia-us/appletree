import AppleTreeCore
import Darwin
import Foundation

/// Throwaway CLI harness for manually verifying/benchmarking `DirectoryScanner`
/// against real folders, and for the M6 getattrlistbulk-vs-fts evaluation.
/// Not part of the app; not covered by unit tests.
///
/// Usage:
///   swift run scanbench [path] [--workers N] [--iterations N] [--quiet]
///       — full recursive scan, replicating AppState.startScan's exact
///         operations (default: home directory, 1 iteration)
///   swift run scanbench --bulkbench <dir> [iters]
///       — single-directory fts vs getattrlistbulk benchmark

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
    var iterations = 1
    var quiet = false
    var args = Array(CommandLine.arguments.dropFirst())[...]
    while let arg = args.first {
        args = args.dropFirst()
        switch arg {
        case "--workers":
            guard let value = args.first else { break }
            workers = Int(value)
            args = args.dropFirst()
        case "--iterations":
            guard let value = args.first else { break }
            iterations = max(1, Int(value) ?? 1)
            args = args.dropFirst()
        case "--quiet":
            quiet = true
        default:
            if path == nil { path = arg }
        }
    }
    await runFullScan(path: path, workers: workers, iterations: iterations, quiet: quiet)
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

struct ScanResult {
    let duration: Duration
    let filesScanned: Int
    let foldersSkipped: Int
    let tccDeniedFolders: Int
    let allocatedBytes: UInt64
    let logicalBytes: UInt64
    let topLevelChildren: Int
    let treeAggregateMatchesLiveCounter: Bool
}

/// Runs exactly one scan — the same `DirectoryScanner.scan(root:options:)`
/// call and event handling `AppState.startScan`/`handle(_:)` performs in the
/// GUI app (progress/skip bookkeeping, `.finished` totals). `VolumeInfo` is
/// deliberately *not* read here even though `AppState.startScan` reads it
/// first thing — it's a single `statfs`-backed call outside the scan proper,
/// so it's read once in `runFullScan` instead of once per iteration.
func runOneScan(root: URL, options: ScanOptions, verbose: Bool) async -> ScanResult? {
    let scanner = DirectoryScanner()
    var totalFiles = 0
    var totalSkipped = 0
    var totalTccDenied = 0
    var rootNode: FileNode?
    var duration: Duration?

    do {
        for try await event in await scanner.scan(root: root, options: options) {
            switch event {
            case .rootCreated(let node):
                rootNode = node
            case .progress(let files, let folders, let bytes, let path):
                if verbose {
                    print("  ...\(files) files, \(folders) folders, \(ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)) (\(path ?? ""))")
                }
            case .folderSkipped(let path, let reason):
                if verbose { print("  skipped: \(path) (\(reason))") }
            case .finished(let d, let filesScanned, let foldersSkipped, let tccDeniedFolders):
                totalFiles = filesScanned
                totalSkipped = foldersSkipped
                totalTccDenied = tccDeniedFolders
                duration = d
            case .cancelled(let d, let filesScanned, let foldersSkipped, let tccDeniedFolders):
                // ScanBench shouldn't cancel, but treat it like a finished
                // partial result so the exhaustive switch stays honest.
                totalFiles = filesScanned
                totalSkipped = foldersSkipped
                totalTccDenied = tccDeniedFolders
                duration = d
            case .subtreeCompleted:
                break
            case .failed(let error):
                print("scan failed: \(error)")
                return nil
            }
        }
    } catch {
        print("scan failed: \(error)")
        return nil
    }

    guard let node = rootNode, let duration else { return nil }
    return ScanResult(
        duration: duration,
        filesScanned: totalFiles,
        foldersSkipped: totalSkipped,
        tccDeniedFolders: totalTccDenied,
        allocatedBytes: node.displaySize,
        logicalBytes: node.logicalSize,
        topLevelChildren: node.children.count,
        // Sanity check: the tree's own aggregate should always match the
        // live running counter — any divergence means some subtree's
        // finalize never ran (or ran against an incomplete children list),
        // which is exactly the shape of bug this project has hit twice.
        treeAggregateMatchesLiveCounter: node.fileCount == totalFiles
    )
}

func runFullScan(path: String? = nil, workers: Int? = nil, iterations: Int = 1, quiet: Bool = false) async {
    let targetPath = path ?? FileManager.default.homeDirectoryForCurrentUser.path
    let root = URL(fileURLWithPath: targetPath)
    let options = ScanOptions(maxConcurrentWorkers: workers)
    let verbose = !quiet && iterations == 1

    print("Scanning \(root.path)\(workers.map { " (maxConcurrentWorkers: \($0))" } ?? " (default worker count)")\(iterations > 1 ? ", \(iterations) iterations" : "") ...")

    // Matches AppState.startScan's own first real operation, so a CLI run's
    // preamble mirrors the GUI's exactly.
    if let volumeInfo = VolumeInfo.forVolume(containing: root) {
        print("Volume: \(volumeInfo.volumeName) — \(ByteCountFormatter.string(fromByteCount: Int64(volumeInfo.totalBytes), countStyle: .file)) total, \(ByteCountFormatter.string(fromByteCount: Int64(volumeInfo.freeBytes), countStyle: .file)) free")
    }

    var results: [ScanResult] = []
    for i in 1...iterations {
        if iterations > 1 { print("\n--- iteration \(i)/\(iterations) ---") }
        guard let result = await runOneScan(root: root, options: options, verbose: verbose) else { continue }
        results.append(result)
        print("Done in \(result.duration). Files scanned: \(result.filesScanned)")
        if !result.treeAggregateMatchesLiveCounter {
            print("[WARNING] tree aggregate fileCount != live counter (\(result.filesScanned)) — scanner undercount bug likely present")
        }
    }

    guard let last = results.last else {
        print("no successful scan to report")
        return
    }

    print("""

        Root: \(root.path)
        Total size (allocated): \(ByteCountFormatter.string(fromByteCount: Int64(last.allocatedBytes), countStyle: .file))
        Total size (logical): \(ByteCountFormatter.string(fromByteCount: Int64(last.logicalBytes), countStyle: .file))
        Files scanned: \(last.filesScanned)
        Folders skipped: \(last.foldersSkipped) (\(last.tccDeniedFolders) blocked by Full Disk Access / TCC)
        Top-level children: \(last.topLevelChildren)
        """)

    if results.count > 1 {
        printTimingStatistics(results)
    }
}

private func seconds(_ d: Duration) -> Double {
    Double(d.components.seconds) + Double(d.components.attoseconds) / 1e18
}

/// Worth having built in rather than eyeballing printed durations: real
/// runs on the same machine/target swung as much as 2x between successive
/// scans in ad hoc testing (disk cache warmth, background system load), so
/// a single-run number is not trustworthy for comparing two adjustments —
/// min/median/max across several iterations is.
private func printTimingStatistics(_ results: [ScanResult]) {
    let sorted = results.map(\.duration).map(seconds).sorted()
    let min = sorted.first!
    let max = sorted.last!
    let median = sorted.count.isMultiple(of: 2)
        ? (sorted[sorted.count / 2 - 1] + sorted[sorted.count / 2]) / 2
        : sorted[sorted.count / 2]
    let mean = sorted.reduce(0, +) / Double(sorted.count)

    print(String(format: """

    Timing across %d iterations:
      min:    %.3fs
      median: %.3fs
      mean:   %.3fs
      max:    %.3fs
    """, sorted.count, min, median, mean, max))
}
