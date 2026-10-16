import Foundation

/// Trash containers and their contents cannot themselves be moved to Trash.
/// Match known locations, rather than permanently deleting any folder that
/// happens to be named `.Trashes` elsewhere in a scan.
enum DeleteOperation: Sendable {
    case moveToTrash
    case permanentlyDelete
    case emptyTrash

    static func forItem(at url: URL, deletePermanently: Bool = false) -> Self {
        let fileManager = FileManager.default
        let home = fileManager.homeDirectory(forUser: NSUserName())
            ?? fileManager.homeDirectoryForCurrentUser
        let volume = try? url.resourceValues(forKeys: [.volumeURLKey]).volume
        let operation = forItem(at: url, volumeRoot: volume, homeDirectory: home)
        // A link at a container's path must be removed as a link, not emptied.
        if operation == .emptyTrash,
           (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true {
            return deletePermanently ? .permanentlyDelete : .moveToTrash
        }
        return deletePermanently && operation == .moveToTrash ? .permanentlyDelete : operation
    }

    static func forItem(at url: URL, volumeRoot: URL?, homeDirectory: URL) -> Self {
        var roots = [
            homeDirectory.appendingPathComponent(".Trash"),
            homeDirectory.resolvingSymlinksInPath().appendingPathComponent(".Trash"),
            URL(fileURLWithPath: "/.Trashes")
        ]
        if let volumeRoot {
            roots.append(volumeRoot.appendingPathComponent(".Trashes"))
        }
        // Do not resolve the item's symlinks: deleting a link must operate on
        // the link itself, never turn a link to Trash into a permanent delete.
        let path = url.standardizedFileURL.path
        for root in roots {
            let trashPath = root.standardizedFileURL.path
            if path == trashPath { return .emptyTrash }
            if path.hasPrefix(trashPath + "/") { return .permanentlyDelete }
        }
        return .moveToTrash
    }

    var menuTitle: String {
        switch self {
        case .moveToTrash: "Move to Trash"
        case .permanentlyDelete: "Delete Permanently…"
        case .emptyTrash: "Empty Trash…"
        }
    }

    var buttonTitle: String {
        switch self {
        case .moveToTrash: "Move to Trash"
        case .permanentlyDelete: "Delete Permanently"
        case .emptyTrash: "Empty Trash"
        }
    }

    var recoveryNote: String {
        switch self {
        case .moveToTrash: "You can restore it from the Trash later."
        case .permanentlyDelete: "This item will be permanently deleted and cannot be restored from Trash."
        case .emptyTrash: "Your Trash contents here will be permanently deleted and cannot be restored from Trash. The Trash folder and other users' items will be kept."
        }
    }

    func requiresConfirmation(preference: Bool) -> Bool {
        self != .moveToTrash || preference
    }

    /// Returns the paths actually removed so an emptied, retained container
    /// stays visible and only its deleted contents drop out of scan totals.
    @discardableResult
    func perform(at url: URL, fileManager: FileManager = .default) throws -> [URL] {
        var removedURLs: [URL] = []
        do {
            switch self {
            case .moveToTrash:
                try fileManager.trashItem(at: url, resultingItemURL: nil)
                removedURLs.append(url)
            case .permanentlyDelete:
                try fileManager.removeItem(at: url)
                removedURLs.append(url)
            case .emptyTrash:
                let isShared = url.lastPathComponent == ".Trashes"
                let contentsURL = isShared ? url.appendingPathComponent(String(getuid())) : url
                // Refuse to traverse a container replaced by a symlink since
                // confirmation, including a shared Trash's user directory.
                for container in [url, contentsURL] {
                    if (try? container.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true {
                        throw CocoaError(.fileReadInvalidFileName)
                    }
                }
                let contents: [URL]
                do {
                    contents = try fileManager.contentsOfDirectory(at: contentsURL, includingPropertiesForKeys: nil)
                } catch let error as CocoaError where isShared && error.code == .fileReadNoSuchFile {
                    return [] // This user has no Trash on this volume.
                }
                for entry in contents {
                    // Foundation may canonicalize /var to /private/var in
                    // returned URLs. Preserve the selected path's spelling
                    // so scan-node lookup can apply the removed paths.
                    let item = contentsURL.appendingPathComponent(entry.lastPathComponent)
                    try fileManager.removeItem(at: item)
                    removedURLs.append(item)
                }
            }
            return removedURLs
        } catch {
            throw Failure(operation: self, underlyingError: error, removedURLs: removedURLs)
        }
    }

    struct Failure: LocalizedError {
        let operation: DeleteOperation
        let underlyingError: Error
        let removedURLs: [URL]

        var errorDescription: String? {
            let prefix = switch operation {
            case .moveToTrash: "Couldn't move to Trash"
            case .permanentlyDelete: "Couldn't delete permanently"
            case .emptyTrash: "Couldn't empty Trash"
            }
            return "\(prefix): \(underlyingError.localizedDescription)"
        }
    }
}
