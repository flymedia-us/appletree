import AppleTreeCore
import Foundation

/// Throwaway CLI harness for manually verifying/benchmarking `DirectoryScanner`
/// against real folders. Not part of the app; not covered by unit tests.
/// Usage: swift run scanbench [path]   (defaults to the home directory)

let targetPath = CommandLine.arguments.count > 1
    ? CommandLine.arguments[1]
    : FileManager.default.homeDirectoryForCurrentUser.path
let root = URL(fileURLWithPath: targetPath)

print("Scanning \(root.path) ...")

let scanner = DirectoryScanner()
var totalFiles = 0
var totalSkipped = 0
var totalBytes: UInt64 = 0
var rootNode: FileNode?

for try await event in await scanner.scan(root: root) {
    switch event {
    case .rootCreated(let node):
        rootNode = node
    case .progress(let files, let bytes, let path):
        print("  ...\(files) files, \(ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)) (\(path ?? ""))")
    case .folderSkipped(let path, let reason):
        totalSkipped += 1
        print("  skipped: \(path) (\(reason))")
    case .finished(let duration, let filesScanned, let foldersSkipped):
        totalFiles = filesScanned
        totalSkipped = foldersSkipped
        print("Done in \(duration).")
    case .subtreeCompleted, .failed:
        break
    }
}

if let node = rootNode {
    totalBytes = node.logicalSize
    print("""
    Root: \(node.path)
    Total size: \(ByteCountFormatter.string(fromByteCount: Int64(totalBytes), countStyle: .file))
    Files scanned: \(totalFiles)
    Folders skipped: \(totalSkipped)
    Top-level children: \(node.children.count)
    """)
}
