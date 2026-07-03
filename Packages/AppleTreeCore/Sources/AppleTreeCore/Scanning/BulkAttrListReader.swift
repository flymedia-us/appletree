import Darwin

/// Prototype `getattrlistbulk`-based directory reader, evaluated as a
/// possible secondary optimization inside each `DirectoryScanner` worker
/// (per the project's research doc: `fts` is already the fastest local-
/// traversal primitive on APFS/HFS+, so this is specifically testing
/// whether batching name+type+size into one buffered syscall beats fts's
/// per-entry `lstat`-equivalent work — not testing traversal/recursion,
/// which stays fts's job either way).
///
/// Not wired into `DirectoryScanner` — this exists for the benchmark in
/// `ScanBench` (`swift run scanbench --bulkbench <dir> [iterations]`) to
/// produce a real adopt/keep-fts-only decision, per the implementation
/// plan's M6 milestone.
///
/// **Decision: keep fts-only for v1, do not adopt.** Benchmarked on this
/// machine (single-directory, non-recursive listing, 30-50 iterations):
///   - A directory of 1014 subdirectories (Swift index-store `records/`):
///     getattrlistbulk was **3.26x** faster than fts.
///   - A directory of 2220 real-world files (`~/Downloads`): getattrlistbulk
///     was only **1.13x** faster than fts — a marginal win.
/// The large win is specific to directory-heavy fan-out (fts pays extra
/// per-subdirectory overhead FTS doesn't need for plain files); the common
/// case for real scan targets (Downloads, Documents, home directories) is
/// file-heavy, where the win shrinks to barely-measurable. That's not
/// enough to justify the risk this file already demonstrated firsthand:
/// building it surfaced two real bugs in this one prototype — a misaligned-
/// pointer crash (the kernel's packed buffer format doesn't respect Swift's
/// alignment assumptions, fixed by switching every field read to
/// `loadUnaligned`) and a benchmark-side double-counting bug from not
/// distinguishing FTS_D/FTS_DP. Hand-parsing a kernel-defined packed binary
/// format is exactly the kind of code where a subtle bug silently
/// corrupts size totals rather than crashing loudly — an unattractive
/// trade for a ~13% average-case speedup on top of a scanner that M1
/// already benchmarked as competitive with bare `find`. Revisit only if a
/// specific real-world workload shows fts-per-worker throughput becoming
/// the actual bottleneck (per the original research doc's framing:
/// parallelism, not syscall choice, is the lever that mattered for M1's
/// real speedup).
public enum BulkAttrListReader {
    public struct Entry {
        public let name: String
        public let isDirectory: Bool
        public let totalSize: UInt64
        public let allocSize: UInt64
    }

    public enum ReadError: Error {
        case cannotOpenDirectory(errno: Int32)
        case bulkCallFailed(errno: Int32)
    }

    /// Reads every immediate entry of the directory at `path` in one
    /// `open()` + repeated `getattrlistbulk()` loop. Non-recursive — mirrors
    /// what a single `fts_children`-style listing would give a worker for
    /// one directory level, which is the operation being compared.
    public static func readEntries(at path: String) throws -> [Entry] {
        let fd = open(path, O_RDONLY)
        guard fd >= 0 else { throw ReadError.cannotOpenDirectory(errno: errno) }
        defer { close(fd) }

        var attrList = attrlist()
        attrList.bitmapcount = u_short(ATTR_BIT_MAP_COUNT)
        attrList.commonattr = ATTR_CMN_RETURNED_ATTRS | UInt32(ATTR_CMN_NAME) | UInt32(ATTR_CMN_OBJTYPE)
        attrList.fileattr = UInt32(ATTR_FILE_TOTALSIZE) | UInt32(ATTR_FILE_ALLOCSIZE)

        var entries: [Entry] = []
        let bufferSize = 64 * 1024
        var buffer = [UInt8](repeating: 0, count: bufferSize)

        while true {
            let count = buffer.withUnsafeMutableBytes { rawBuffer -> Int32 in
                withUnsafeMutablePointer(to: &attrList) { attrListPtr in
                    Int32(getattrlistbulk(fd, attrListPtr, rawBuffer.baseAddress, bufferSize, 0))
                }
            }
            if count < 0 { throw ReadError.bulkCallFailed(errno: errno) }
            if count == 0 { break }

            buffer.withUnsafeMutableBytes { rawBuffer in
                var offset = 0
                for _ in 0..<count {
                    // The kernel packs these entries tightly with no padding
                    // for Swift's natural alignment rules, so every field
                    // must be read with `loadUnaligned` — `load(as:)` traps
                    // ("misaligned raw pointer") the moment a multi-byte
                    // field lands on a non-naturally-aligned offset, which
                    // happens routinely here (e.g. a 4-byte OBJTYPE field
                    // pushes the following 8-byte size field off would-be
                    // 8-byte alignment).
                    let entryBase = rawBuffer.baseAddress!.advanced(by: offset)
                    let length = entryBase.loadUnaligned(as: UInt32.self)
                    var cursor = entryBase.advanced(by: MemoryLayout<UInt32>.size)

                    let returned = cursor.loadUnaligned(as: attribute_set_t.self)
                    cursor = cursor.advanced(by: MemoryLayout<attribute_set_t>.size)

                    var name = ""
                    if returned.commonattr & UInt32(ATTR_CMN_NAME) != 0 {
                        let refBase = cursor
                        let refOffset = cursor.loadUnaligned(as: Int32.self)
                        let refLength = cursor.loadUnaligned(fromByteOffset: 4, as: UInt32.self)
                        let nameStart = refBase.advanced(by: Int(refOffset))
                        // refLength includes the trailing NUL.
                        let nameBytes = UnsafeRawBufferPointer(start: nameStart, count: max(0, Int(refLength) - 1))
                        name = String(decoding: nameBytes, as: UTF8.self)
                        cursor = cursor.advanced(by: MemoryLayout<attrreference_t>.size)
                    }

                    var isDirectory = false
                    if returned.commonattr & UInt32(ATTR_CMN_OBJTYPE) != 0 {
                        let objType = cursor.loadUnaligned(as: UInt32.self)
                        isDirectory = objType == VDIR.rawValue
                        cursor = cursor.advanced(by: MemoryLayout<UInt32>.size)
                    }

                    var totalSize: UInt64 = 0
                    if returned.fileattr & UInt32(ATTR_FILE_TOTALSIZE) != 0 {
                        totalSize = UInt64(cursor.loadUnaligned(as: Int64.self))
                        cursor = cursor.advanced(by: MemoryLayout<Int64>.size)
                    }

                    var allocSize: UInt64 = 0
                    if returned.fileattr & UInt32(ATTR_FILE_ALLOCSIZE) != 0 {
                        allocSize = UInt64(cursor.loadUnaligned(as: Int64.self))
                        cursor = cursor.advanced(by: MemoryLayout<Int64>.size)
                    }

                    entries.append(Entry(name: name, isDirectory: isDirectory, totalSize: totalSize, allocSize: allocSize))
                    offset += Int(length)
                }
            }
        }

        return entries
    }
}
