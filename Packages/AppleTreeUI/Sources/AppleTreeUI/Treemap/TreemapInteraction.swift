import AppleTreeCore
import CoreGraphics

/// Hit-testing over a flattened treemap layout.
enum TreemapHitTester {
    /// Returns the box (node + its rect) containing `point`, preferring the
    /// deepest/most-specific match. `layout`'s array order already has
    /// children appended after their parent (see `TreemapLayout`), so a
    /// simple reverse scan for the first containing rect naturally finds the
    /// deepest match without needing a spatial index at this scale. Returns
    /// the rect alongside the node so hover-tracking callers can cache it and
    /// cheaply detect "still inside the same box" without re-scanning.
    static func hitTest(_ point: CGPoint, in layout: [TreemapNode]) -> TreemapNode? {
        for node in layout.reversed() where node.rect.contains(point) {
            return node
        }
        return nil
    }
}
