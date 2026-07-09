import AppleTreeCore
import SwiftUI

/// WizTree-style treemap: boxes sized by disk usage, colored by file type,
/// with on-box name+size labels. Rendered on a single `Canvas` rather than
/// one SwiftUI view per box — necessary at the box counts a real directory
/// tree produces (see `TreemapLayout`'s own doc comment for the algorithm).
public struct TreemapView: View {
    public let rootNode: FileNode?
    public var selection: SelectionModel
    public var treeVersion: Int
    /// Called once this view's relayout has fully settled for a given
    /// `treeVersion` — i.e. what's on screen now actually reflects that
    /// version's data — passing back the version that just finished.
    /// Distinct from `treeVersion` simply changing: that only means a
    /// relayout was *requested*; the actual (80ms-debounced, backgrounded)
    /// computation can finish well after that. Lets `AppState` know
    /// precisely when its "Loading tree" status can flip to "Scan
    /// completed", instead of guessing at a fixed delay that a large tree's
    /// relayout can easily outlast.
    public var onRelayoutFinished: ((Int) -> Void)?

    @State private var layout: [TreemapNode] = []
    @State private var layoutSize: CGSize = .zero
    @State private var layoutedRootID: FileNode.ID?
    @State private var layoutedVersion: Int = -1
    /// The last-hit box. Doubles as both the hover cache (a tick still
    /// "inside" it can skip `TreemapHitTester.hitTest`'s O(n) scan entirely)
    /// and the tooltip's anchor — see `body`'s doc comments for both.
    @State private var hoveredBox: TreemapNode?
    @State private var relayoutTask: Task<Void, Never>?
    /// See `ExtensionSummaryView.Coordinator`'s identical `recomputeAgainAfter`
    /// for the full rationale — coalesces triggers that arrive while a
    /// layout is already in flight into exactly one guaranteed follow-up
    /// pass, instead of spawning an overlapping (and, since `TreemapLayout.layout`
    /// has no cooperative cancellation checks, effectively uncancellable)
    /// duplicate walk per trigger.
    @State private var relayoutAgainAfter = false

    public init(
        rootNode: FileNode?,
        selection: SelectionModel,
        treeVersion: Int,
        onRelayoutFinished: ((Int) -> Void)? = nil
    ) {
        self.rootNode = rootNode
        self.selection = selection
        self.treeVersion = treeVersion
        self.onRelayoutFinished = onRelayoutFinished
    }

    public var body: some View {
        GeometryReader { proxy in
            Canvas { context, size in
                draw(in: &context)
            }
            .onAppear { relayout(size: proxy.size) }
            .onChange(of: proxy.size) { _, newSize in relayout(size: newSize) }
            .onChange(of: treeVersion) { _, _ in relayout(size: proxy.size) }
            .onChange(of: rootNode?.id) { _, _ in relayout(size: proxy.size) }
            .gesture(
                SpatialTapGesture().onEnded { value in
                    selection.selectedNode = TreemapHitTester.hitTest(value.location, in: layout)?.source
                }
            )
            .onContinuousHover { phase in
                switch phase {
                case .active(let location):
                    // Safe to skip the O(n) re-scan only when nothing else
                    // in `layout` could possibly be nested inside the
                    // cached box's rect: true for a file (always a leaf),
                    // and true for a directory only when none of its
                    // children got their own individually-rendered box.
                    // Otherwise a child's rect is a geometric *subset* of
                    // its parent's — caching the parent's (larger) rect
                    // would make every point inside it, including points
                    // over its own children, wrongly "still match", so the
                    // hover would get stuck on that parent forever.
                    if let hoveredBox,
                       !(hoveredBox.source.isDirectory && hoveredBox.hasVisibleChildren),
                       hoveredBox.rect.contains(location) {
                        return
                    }
                    let hit = TreemapHitTester.hitTest(location, in: layout)
                    hoveredBox = hit
                    selection.hoveredNode = hit?.source
                case .ended:
                    hoveredBox = nil
                    selection.hoveredNode = nil
                }
            }
            .background(Self.backgroundColor)
            .overlay(alignment: .topLeading) {
                if let hoveredBox {
                    NodeHoverTooltip(node: hoveredBox.source)
                        .fixedSize()
                        .offset(tooltipOffset(for: hoveredBox.rect, in: proxy.size))
                        .allowsHitTesting(false)
                }
            }
        }
    }

    /// Dark neutral background the colored file boxes and folder label bands
    /// sit on top of — matches WizTree's treemap styling (#3A3939) by design,
    /// independent of the rest of the app's light/dark appearance.
    private static let backgroundColor = Color(red: 0x3A / 255.0, green: 0x39 / 255.0, blue: 0x39 / 255.0)
    private static let folderLabelBackground = Color(red: 0x50 / 255.0, green: 0x4F / 255.0, blue: 0x4F / 255.0)
    private static let folderStroke = Color.white.opacity(0.18)
    private static let selectedOutline = Color.white
    private static let hoveredOutline = Color.white.opacity(0.5)

    /// Pins the tooltip near the hovered box's top-left corner rather than
    /// the live cursor position — deliberately, not just for simplicity: it
    /// means the tooltip only needs to move (and the view only needs to
    /// re-render) when the hovered box itself changes, not on every pixel
    /// the mouse crosses while still inside the same box. Flips to whichever
    /// side keeps it fully inside the canvas.
    private func tooltipOffset(for rect: CGRect, in containerSize: CGSize) -> CGSize {
        let estimatedWidth: CGFloat = 260
        let estimatedHeight: CGFloat = 40
        let margin: CGFloat = 8
        let flipX = rect.minX + margin + estimatedWidth > containerSize.width
        let flipY = rect.minY + margin + estimatedHeight > containerSize.height
        let x = flipX ? max(0, rect.maxX - estimatedWidth) : rect.minX + margin
        let y = flipY ? max(0, rect.minY - estimatedHeight - margin) : rect.minY + margin
        return CGSize(width: x, height: y)
    }

    private func relayout(size: CGSize) {
        guard let rootNode, size.width > 0, size.height > 0 else {
            relayoutTask?.cancel()
            layout = []
            return
        }
        // Skip redundant relayout work: only recompute when the data
        // actually changed (treeVersion), the root itself changed, or the
        // available canvas size changed — not on every SwiftUI render pass.
        guard layoutedRootID != rootNode.id || layoutedVersion != treeVersion || layoutSize != size else {
            return
        }
        layoutedRootID = rootNode.id
        layoutedVersion = treeVersion
        layoutSize = size

        // A live window-resize drag can fire this several times a second,
        // and a real scan's tree is large enough that recomputing its whole
        // layout synchronously on every one of those was what made resizing
        // "comically slow" — it blocked the same main thread driving the
        // resize's own tracking loop. Debouncing collapses a fast flurry
        // into one relayout of the final size, and running that one on a
        // detached task keeps even it off the main thread; only the final
        // `self.layout = computed` assignment hops back.
        //
        // Coalesces to at most one layout in flight at a time — during an
        // active scan `treeVersion` bumps roughly every 100ms, and without
        // this, cancelling `relayoutTask` alone doesn't stop the wasted
        // work: `TreemapLayout.layout` is a plain synchronous recursive
        // function with no cooperative cancellation checks, so a cancelled
        // `Task.detached` keeps running to completion regardless. Confirmed
        // as a real, measured contributor to a live scan running dramatically
        // slower than the scanner itself — hundreds of overlapping full-tree
        // layouts piling up and competing with the scanner's own worker
        // threads for the same CPU cores.
        guard relayoutTask == nil else {
            relayoutAgainAfter = true
            return
        }
        runRelayout(rootNode: rootNode, size: size)
    }

    private func runRelayout(rootNode: FileNode, size: CGSize) {
        relayoutTask = Task {
            try? await Task.sleep(for: .milliseconds(80))
            if !Task.isCancelled {
                let computed = await Task.detached(priority: .userInitiated) {
                    TreemapLayout.layout(node: rootNode, in: CGRect(origin: .zero, size: size))
                }.value
                if !Task.isCancelled {
                    self.layout = computed
                    // The cached hover box may no longer correspond to
                    // anything at its old screen position under the new
                    // layout — drop it so the next hover tick (even a tiny
                    // one) re-hit-tests instead of trusting stale geometry.
                    self.hoveredBox = nil
                    // Reports every settled pass, not just a final,
                    // nothing-else-queued one. `rootNode` is a live
                    // reference mutated in place, so whichever pass's
                    // `Task.detached` actually runs reads the tree as it
                    // stands *at that moment* — if this pass was already
                    // in flight when a newer `treeVersion` arrived
                    // (coalesced via `relayoutAgainAfter` below), its own
                    // result can already be fully current, making the
                    // "guaranteed one more pass" that follows pure
                    // redundant work. Waiting for that redundant pass
                    // before reporting is exactly what made "Loading
                    // tree…" visibly outlast the treemap already being on
                    // screen, correct. Read `layoutedVersion` (a `@State`
                    // var) rather than `self.treeVersion` (a plain,
                    // non-`@State` property) — `self` here is whatever
                    // `TreemapView` value this Task closure originally
                    // captured, and only `@State`-backed reads are
                    // guaranteed to see the latest value through a
                    // possibly-stale struct snapshot.
                    self.onRelayoutFinished?(self.layoutedVersion)
                }
            }
            self.relayoutTask = nil
            if self.relayoutAgainAfter, let latestRoot = self.rootNode {
                self.relayoutAgainAfter = false
                self.runRelayout(rootNode: latestRoot, size: self.layoutSize)
            }
        }
    }

    private func draw(in context: inout GraphicsContext) {
        let selectedID = selection.selectedNodeID
        let hoveredID = selection.hoveredNodeID
        // A selected/hovered folder's box is behind its own children's boxes
        // and label bands in draw order (they're nested inside it), so its
        // outline has to be drawn in a final pass over everything else —
        // drawn inline, a child painted right up to the parent's edge would
        // paint over the outline there.
        var hoveredRect: CGRect?
        var selectedRect: CGRect?

        for node in layout {
            let rect = node.rect
            guard rect.width >= 1, rect.height >= 1 else { continue }

            if !node.source.isDirectory {
                let (top, bottom) = ExtensionColor.gradient(forFileName: node.source.name)
                context.fill(
                    Path(rect),
                    with: .linearGradient(
                        Gradient(colors: [top, bottom]),
                        startPoint: CGPoint(x: rect.midX, y: rect.minY),
                        endPoint: CGPoint(x: rect.midX, y: rect.maxY)
                    )
                )
            } else if node.source.displaySize > 0, !node.hasVisibleChildren {
                // This directory has real content, but every child was
                // individually too small to render on its own (a folder of
                // many tiny files at this canvas size) — a flat neutral
                // tint distinguishes "content too fine-grained to show
                // individually" from true empty space, instead of leaving
                // an unexplained blank hole.
                context.fill(Path(rect), with: .color(.white.opacity(0.06)))
            }

            context.stroke(Path(rect), with: .color(Self.folderStroke), lineWidth: 0.5)

            if node.source.id == hoveredID {
                hoveredRect = rect
            }
            if node.source.id == selectedID {
                selectedRect = rect
            }

            // Only folders get a name label — labeling every individual file
            // box would be illegible noise at the box counts a real
            // directory tree produces.
            if node.source.isDirectory, let labelRect = node.labelRect {
                context.fill(Path(labelRect), with: .color(Self.folderLabelBackground))

                let label = "\(node.source.name)  (\(SizeFormatting.string(for: node.source.displaySize)))"
                let text = Text(label)
                    .font(.system(size: 10))
                    .foregroundColor(.white.opacity(0.92))
                context.draw(
                    text,
                    in: CGRect(x: labelRect.minX + 4, y: labelRect.minY, width: max(0, labelRect.width - 6), height: labelRect.height)
                )
            }
        }

        // Hover drawn first, subtler; selection drawn last/on top so a
        // simultaneously selected+hovered folder still reads as selected.
        if let hoveredRect {
            context.stroke(Path(hoveredRect.insetBy(dx: 1, dy: 1)), with: .color(Self.hoveredOutline), lineWidth: 1.5)
        }
        if let selectedRect {
            context.stroke(Path(selectedRect.insetBy(dx: 1, dy: 1)), with: .color(Self.selectedOutline), lineWidth: 2)
        }
    }
}

/// Small path+size callout that follows the cursor while hovering any box
/// (file or folder) in the treemap.
private struct NodeHoverTooltip: View {
    let node: FileNode

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(node.path)
                .font(.body.weight(.medium))
                .lineLimit(1)
                .truncationMode(.middle)
            Text(SizeFormatting.string(for: node.displaySize))
                .font(.body)
        }
        .foregroundColor(.white)
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(Color.black.opacity(0.85))
        )
        .frame(maxWidth: 320, alignment: .leading)
    }
}
