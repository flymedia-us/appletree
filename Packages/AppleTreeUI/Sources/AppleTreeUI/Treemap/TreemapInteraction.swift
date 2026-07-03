import AppleTreeCore
import CoreGraphics

/// Hit-testing over a flattened treemap layout.
enum TreemapHitTester {
    /// Returns the node whose box contains `point`, preferring the
    /// deepest/most-specific match. `layout`'s array order already has
    /// children appended after their parent (see `TreemapLayout`), so a
    /// simple reverse scan for the first containing rect naturally finds the
    /// deepest match without needing a spatial index at this scale.
    static func hitTest(_ point: CGPoint, in layout: [TreemapNode]) -> FileNode? {
        for node in layout.reversed() where node.rect.contains(point) {
            return node.source
        }
        return nil
    }
}
