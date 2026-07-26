import Darwin

/// Reconciles a scanned subtree against what is actually on disk right now,
/// so the tree converges even when the live watch missed something.
///
/// The watch cannot be trusted to be complete, and not only in the way
/// FSEvents documents. `kFSEventStreamEventFlagMustScanSubDirs` announces the
/// coalescing case, but measured against a real bulk delete (3,000 files
/// removed from a watched folder) the flag was never set and events still
/// went missing: one run delivered 2,917 of the 3,000 file paths, another
/// delivered the files but never mentioned the enclosing directory at all.
/// Whatever the kernel's reason, an app that only ever applies the events it
/// is handed will sometimes be left showing sizes that are quietly wrong —
/// unacceptable for a tool whose entire job is reporting sizes.
///
/// So the watch is treated as a *hint* about where to look, and this is what
/// establishes the truth: once a burst of activity goes quiet, `lstat` the
/// directories it touched and fix any disagreement. Bounded by the subtree
/// actually involved rather than the whole scan, and cheap in the case that
/// matters most — a deleted directory answers for its entire subtree in one
/// syscall (see `walk`).
public enum SubtreeResync {
    /// A node whose recorded removal state disagrees with the filesystem.
    public struct Decision: Sendable {
        public let node: FileNode
        /// Whether the path exists on disk right now. `false` means the node
        /// should be marked removed, `true` that it should be restored.
        public let exists: Bool
    }

    /// Walks `subtree`, `lstat`-ing as it goes, and returns only the nodes
    /// that disagree with disk — so the common "nothing actually drifted"
    /// outcome allocates nothing and the caller can skip re-rendering.
    ///
    /// Pure reads plus syscalls, no mutation: safe to run off the main actor,
    /// which is the point — a wide subtree is thousands of `lstat` calls and
    /// has no business happening on the main thread. The tree may of course
    /// move on while this runs; that's fine, since applying a `Decision` is
    /// idempotent and the next resync sees whatever changed after it.
    public static func survey(_ subtree: FileNode) -> [Decision] {
        var decisions: [Decision] = []
        walk(subtree, path: subtree.path, into: &decisions)
        return decisions
    }

    /// Applies `decisions` and recomputes each affected directory once.
    /// Returns the nodes that actually changed — empty when the survey turned
    /// out to be stale, which is the caller's cue that nothing needs
    /// re-rendering.
    @discardableResult
    public static func apply(_ decisions: [Decision]) -> [FileNode] {
        var changed: [FileNode] = []
        for decision in decisions where decision.node.setRemovedState(!decision.exists) {
            changed.append(decision.node)
        }
        guard !changed.isEmpty else { return [] }
        FileNode.refinalizeAncestors(of: changed)
        return changed
    }

    private static func walk(_ node: FileNode, path: String, into decisions: inout [Decision]) {
        let exists = FileSystemProbe.exists(atPath: path)
        if node.isRemoved == exists {
            decisions.append(Decision(node: node, exists: exists))
        }

        // A directory that is gone answers for everything beneath it: its
        // descendants are already excluded from every aggregate through this
        // one node, so there is nothing below worth a syscall. This is what
        // makes reconciling after an `rm -rf` essentially free — the deleted
        // folder costs one `lstat`, not one per file that used to be in it.
        guard exists, node.isDirectory else { return }

        // Built by appending to the parent's path rather than asking each
        // node for its own: `FileNode.path` walks the parent chain and
        // rebuilds the whole string every time, which turns a subtree walk
        // quadratic in depth for no reason.
        let prefix = path.hasSuffix("/") ? path : path + "/"
        for child in node.children {
            walk(child, path: prefix + child.name, into: &decisions)
        }
    }
}

/// Shared by the watch (one call per reported path) and the resync (one per
/// node surveyed).
enum FileSystemProbe {
    /// `lstat` rather than `FileManager.fileExists(atPath:)`: cheaper (no
    /// `FileManager` bookkeeping or path bridging per call, and both callers
    /// make thousands of these), and more accurate for the question being
    /// asked. `fileExists` follows symlinks, so a symlink whose *target* was
    /// deleted would read as gone even though the directory entry the scan
    /// recorded — and sized — is still on disk.
    static func exists(atPath path: String) -> Bool {
        var info = stat()
        return lstat(path, &info) == 0
    }
}
