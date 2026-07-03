import AppleTreeCore
import Observation

/// Currently-selected/hovered node, shared between the Tree View and the
/// treemap so a click in either pane can drive the other.
@Observable
@MainActor
public final class SelectionModel {
    public var selectedNodeID: FileNode.ID?
    public var hoveredNodeID: FileNode.ID?

    public init() {}
}
