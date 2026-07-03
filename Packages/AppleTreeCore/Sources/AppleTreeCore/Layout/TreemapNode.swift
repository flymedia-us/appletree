import CoreGraphics

/// One rendered box in a treemap layout: a `FileNode` plus the rect it was
/// assigned. `labelRect` is `nil` when the box was too small to reserve a
/// label strip — the renderer draws it as a flat, unlabeled color cell.
public struct TreemapNode: Sendable {
    public let source: FileNode
    public let rect: CGRect
    public let labelRect: CGRect?
    public let depth: Int

    public init(source: FileNode, rect: CGRect, labelRect: CGRect?, depth: Int) {
        self.source = source
        self.rect = rect
        self.labelRect = labelRect
        self.depth = depth
    }
}

public struct TreemapLayoutOptions: Sendable {
    /// Boxes below this in either dimension are dropped entirely (not laid
    /// out, not drawn) — matches GrandPerspective's "must enclose a pixel
    /// center" early-out, generalized.
    public var minBoxSize: CGFloat
    public var labelMinWidth: CGFloat
    public var labelMinHeight: CGFloat
    public var labelStripHeight: CGFloat
    /// Optional cap on recursion depth (relative to the root passed to
    /// `layout`), e.g. for a "flatten below depth N" performance mode.
    public var maxDepth: Int?

    public init(
        minBoxSize: CGFloat = 2,
        labelMinWidth: CGFloat = 60,
        labelMinHeight: CGFloat = 14,
        labelStripHeight: CGFloat = 14,
        maxDepth: Int? = nil
    ) {
        self.minBoxSize = minBoxSize
        self.labelMinWidth = labelMinWidth
        self.labelMinHeight = labelMinHeight
        self.labelStripHeight = labelStripHeight
        self.maxDepth = maxDepth
    }
}
