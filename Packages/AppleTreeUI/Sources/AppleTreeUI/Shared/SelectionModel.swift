import AppleTreeCore
import Observation

/// Currently-selected/hovered node, shared between the Tree View and the
/// treemap so a click in either pane can drive the other.
///
/// Stores the resolved `FileNode` itself, not just its `ID`. Every producer
/// (a treemap hit-test, an outline-row selection) already holds the node when
/// it makes the selection, and every consumer works on the *same* shared
/// `FileNode` object graph — so keeping the reference lets both panes and the
/// accessibility layer read the selection in O(1) instead of re-resolving an
/// `ID` with a full-tree walk (`FileNode.descendant(withID:)`) on every
/// treemap tap and every SwiftUI render. `…ID` accessors remain for
/// call sites that only need identity comparison.
@Observable
@MainActor
public final class SelectionModel {
    public var selectedNode: FileNode?
    public var hoveredNode: FileNode?

    public var selectedNodeID: FileNode.ID? { selectedNode?.id }
    public var hoveredNodeID: FileNode.ID? { hoveredNode?.id }

    public init() {}
}
