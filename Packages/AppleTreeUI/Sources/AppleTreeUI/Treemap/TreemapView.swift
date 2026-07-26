import AppKit
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
    /// Bumped every time `layout` is replaced. `TreemapCanvas` compares on
    /// this instead of the array itself — comparing a hundred thousand
    /// `TreemapNode`s to decide whether to skip a redraw would cost more than
    /// the redraw it's trying to avoid.
    @State private var layoutRevision = 0
    @State private var layoutSize: CGSize = .zero
    @State private var layoutedRootID: FileNode.ID?
    @State private var layoutedVersion: Int = -1
    /// The currently-selected box's rect, kept in step with `layout` and
    /// `selection.selectedNodeID` — see the `onChange` that maintains it.
    @State private var selectedRect: CGRect?
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
    /// The root to use for the guaranteed follow-up pass `relayoutAgainAfter`
    /// promises. Captured explicitly (into `@State`, so it's shared/live
    /// across `TreemapView` struct instances) at the moment a relayout is
    /// deferred, rather than read as `self.rootNode` from inside the pending
    /// `Task` — that closure's `self` is whatever struct instance created it,
    /// and `rootNode` is a plain `let`, not `@State`, so it can go stale if a
    /// new scan replaces the root while the deferred pass is still in
    /// flight. Same hazard `runRelayout`'s own doc comment calls out for
    /// `treeVersion` vs. `layoutedVersion` — missed here for `rootNode`
    /// until this was caught in review.
    @State private var pendingRelayoutRoot: FileNode?
    /// True for the duration of a window-edge drag (`NSWindow`'s own live-
    /// resize, reported by `LiveResizeMonitor` below — SwiftUI's
    /// `GeometryReader` alone can't distinguish "still dragging" from "size
    /// settled"). While true, `relayout` skips the real, expensive
    /// `TreemapLayout.layout` pass entirely in favor of `rescaleLayout`'s
    /// cheap proportional stretch — see `relayout`'s doc comment for why.
    @State private var isLiveResizing = false

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
            // Two layers, deliberately. The base canvas paints every box and
            // is by far the most expensive thing this view does — a real scan
            // produces well over a hundred thousand of them. The highlight
            // layer paints at most two rectangles.
            //
            // They used to be one canvas, which meant every hover tick
            // repainted all hundred-thousand-plus boxes to move a one-pixel
            // outline: the direct cause of hover feeling sluggish on a large
            // scan. Splitting them, and making the base layer `Equatable` on
            // a revision counter that only a real relayout bumps, means a
            // hover now redraws two strokes and nothing else.
            ZStack {
                TreemapCanvas(layout: layout, revision: layoutRevision)
                    .equatable()
                TreemapHighlightLayer(
                    hoveredRect: hoveredBox?.rect,
                    selectedRect: selectedRect
                )
            }
            .onAppear { relayout(size: proxy.size) }
            .onChange(of: proxy.size) { _, newSize in relayout(size: newSize) }
            .onChange(of: treeVersion) { _, _ in relayout(size: proxy.size) }
            .onChange(of: rootNode?.id) { _, _ in relayout(size: proxy.size) }
            // The selected box's rect is cached rather than found while
            // drawing (as it was when the outline lived in the base canvas):
            // the highlight layer needs it every hover tick, and scanning the
            // whole layout that often is exactly the per-hover cost this
            // split exists to remove. Selection changes far more rarely.
            .onChange(of: selection.selectedNodeID) { _, _ in updateSelectedRect() }
            .background(LiveResizeMonitor(onLiveResizeChange: { dragging in
                isLiveResizing = dragging
                // The drag's own in-progress rescales never advance
                // `layoutedVersion`/`layoutSize` as a "real" pass (see
                // `rescaleLayout`), so the instant it ends, `relayout`'s own
                // "did anything actually change" guard would otherwise see
                // `layoutSize` already matching the final size (rescale kept
                // it current throughout) and skip the one accurate pass this
                // whole mechanism exists to still produce. `force` bypasses
                // exactly that guard.
                if !dragging { relayout(size: proxy.size, force: true) }
            }))
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
    static let backgroundColor = Color(red: 0x3A / 255.0, green: 0x39 / 255.0, blue: 0x39 / 255.0)
    static let folderLabelBackground = Color(red: 0x50 / 255.0, green: 0x4F / 255.0, blue: 0x4F / 255.0)
    static let folderStroke = Color.white.opacity(0.18)
    static let selectedOutline = Color.white
    static let hoveredOutline = Color.white.opacity(0.5)

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

    /// `force: true` (only ever passed by the live-resize-end handler above)
    /// bypasses the "did anything actually change" guard below — see that
    /// call site's own comment for why the guard alone can't be trusted to
    /// schedule the accurate pass a resize drag's end requires.
    private func relayout(size: CGSize, force: Bool = false) {
        guard let rootNode, size.width > 0, size.height > 0 else {
            relayoutTask?.cancel()
            setLayout([])
            layoutSize = size
            return
        }

        // A window-edge drag fires this on every intermediate frame, same as
        // any other resize — but unlike a one-off resize, a real
        // `TreemapLayout.layout` pass here is expensive enough (a synchronous
        // walk bounded by canvas-area/minBoxSize², up to ~hundreds of
        // thousands of boxes on a large scan and a big window) that even
        // this function's own 80ms-debounced, backgrounded version of it
        // visibly can't keep up with a continuous drag — confirmed as a real
        // complaint: the treemap redraws sluggishly, lagging behind the
        // cursor, for the drag's whole duration. `rescaleLayout` sidesteps
        // that entirely: no tree walk, just an O(visible boxes) proportional
        // stretch of the rects already on screen, cheap enough to track the
        // cursor every frame. It's a geometric approximation, not a real
        // layout — boxes that would only exist at the *new* size (or
        // disappear below `minBoxSize` at it) don't appear/vanish correctly
        // mid-stretch — which is exactly why `force` above guarantees one
        // real pass the moment the drag ends.
        if isLiveResizing, !force {
            rescaleLayout(to: size)
            return
        }

        // Skip redundant relayout work: only recompute when the data
        // actually changed (treeVersion), the root itself changed, the
        // available canvas size changed, or a real pass was explicitly
        // forced — not on every SwiftUI render pass.
        guard force || layoutedRootID != rootNode.id || layoutedVersion != treeVersion || layoutSize != size else {
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
            pendingRelayoutRoot = rootNode
            return
        }
        runRelayout(rootNode: rootNode, size: size)
    }

    /// Stretches every box in the current `layout` from `layoutSize` (the
    /// size it was last actually computed — or last rescaled — for) to `size`
    /// by a plain per-axis ratio. No tree walk, no `FileNode` access beyond
    /// the reference each `TreemapNode` already holds — just arithmetic over
    /// however many boxes are currently on screen, which is what makes this
    /// cheap enough to run on every frame of a live window-resize drag. Kept
    /// synchronous and on the main actor (unlike `runRelayout`'s
    /// `Task.detached` real pass): there's no tree recursion here to protect
    /// the main thread from, and going through a `Task` would just add
    /// scheduling latency to a path whose entire purpose is tracking the
    /// cursor with no perceptible lag.
    private func rescaleLayout(to size: CGSize) {
        guard layoutSize.width > 0, layoutSize.height > 0, layoutSize != size, !layout.isEmpty else {
            layoutSize = size
            return
        }
        let scaleX = size.width / layoutSize.width
        let scaleY = size.height / layoutSize.height
        setLayout(layout.map { node in
            TreemapNode(
                source: node.source,
                rect: node.rect.scaled(x: scaleX, y: scaleY),
                labelRect: node.labelRect?.scaled(x: scaleX, y: scaleY),
                depth: node.depth,
                hasVisibleChildren: node.hasVisibleChildren
            )
        })
        layoutSize = size
        // Stale the instant the geometry underneath it moved — see
        // `runRelayout`'s identical rationale for clearing this after a real
        // pass; a stretched rect is no exception.
        hoveredBox = nil
    }

    private func runRelayout(rootNode: FileNode, size: CGSize) {
        relayoutTask = Task {
            try? await Task.sleep(for: .milliseconds(80))
            if !Task.isCancelled {
                let computed = await Task.detached(priority: .userInitiated) {
                    TreemapLayout.layout(node: rootNode, in: CGRect(origin: .zero, size: size))
                }.value
                if !Task.isCancelled {
                    self.setLayout(computed)
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
            if self.relayoutAgainAfter, let latestRoot = self.pendingRelayoutRoot {
                self.relayoutAgainAfter = false
                self.pendingRelayoutRoot = nil
                self.runRelayout(rootNode: latestRoot, size: self.layoutSize)
            }
        }
    }

    /// Single point where `layout` is replaced, so the revision counter the
    /// base canvas keys off — and the cached selection rect that depends on
    /// the geometry — can never be left behind by a caller that forgot.
    private func setLayout(_ newLayout: [TreemapNode]) {
        layout = newLayout
        layoutRevision &+= 1
        updateSelectedRect()
    }

    private func updateSelectedRect() {
        guard let selectedID = selection.selectedNodeID else {
            selectedRect = nil
            return
        }
        selectedRect = layout.first { $0.source.id == selectedID }?.rect
    }
}

/// Paints every box in the treemap. Split out from `TreemapView` and made
/// `Equatable` so SwiftUI can skip it entirely when only the hover or
/// selection outline moved — see `TreemapView.body`.
private struct TreemapCanvas: View, Equatable {
    // `nonisolated`, because conforming to `View` infers `@MainActor` on the
    // type while `Equatable` is not actor-isolated — SwiftUI is free to call
    // `==` from wherever it does its diffing. Sound here rather than merely
    // silenced: both are immutable `let`s of `Sendable` type.
    nonisolated let layout: [TreemapNode]
    nonisolated let revision: Int

    /// Compares the revision counter, never the array. Two values with the
    /// same revision are the same layout by construction (`setLayout` is the
    /// only thing that assigns either), and comparing a hundred thousand
    /// boxes would defeat the purpose of skipping the redraw.
    nonisolated static func == (lhs: TreemapCanvas, rhs: TreemapCanvas) -> Bool {
        lhs.revision == rhs.revision
    }

    /// Below this height a vertical gradient across the box is not
    /// distinguishable from its own average color, so the boxes that make up
    /// the overwhelming majority of a real treemap (a 200k-file scan lays out
    /// well over a hundred thousand boxes on a 1600×900 canvas, most of them
    /// a couple of pixels tall) get a flat fill instead. Shading each of
    /// those individually was pure cost for no visible difference.
    private static let gradientMinHeight: CGFloat = 8

    /// Below this, the hairline border between boxes stops separating
    /// anything: at two or three pixels a 0.5pt stroke on all four sides is
    /// most of the box, so the grid reads as mud rather than structure.
    private static let strokeMinSize: CGFloat = 4

    var body: some View {
        Canvas { context, _ in
            for node in layout {
                let rect = node.rect
                guard rect.width >= 1, rect.height >= 1 else { continue }

                if !node.source.isDirectory {
                    let (top, bottom) = ExtensionColor.gradient(forFileName: node.source.name)
                    if rect.height >= Self.gradientMinHeight {
                        context.fill(
                            Path(rect),
                            with: .linearGradient(
                                Gradient(colors: [top, bottom]),
                                startPoint: CGPoint(x: rect.midX, y: rect.minY),
                                endPoint: CGPoint(x: rect.midX, y: rect.maxY)
                            )
                        )
                    } else {
                        context.fill(Path(rect), with: .color(top))
                    }
                } else if node.source.displaySize > 0, !node.hasVisibleChildren {
                    // This directory has real content, but every child was
                    // individually too small to render on its own (a folder of
                    // many tiny files at this canvas size) — a flat neutral
                    // tint distinguishes "content too fine-grained to show
                    // individually" from true empty space, instead of leaving
                    // an unexplained blank hole.
                    context.fill(Path(rect), with: .color(.white.opacity(0.06)))
                }

                if rect.width >= Self.strokeMinSize, rect.height >= Self.strokeMinSize {
                    context.stroke(Path(rect), with: .color(TreemapView.folderStroke), lineWidth: 0.5)
                }

                // Only folders get a name label — labeling every individual
                // file box would be illegible noise at the box counts a real
                // directory tree produces.
                if node.source.isDirectory, let labelRect = node.labelRect {
                    context.fill(Path(labelRect), with: .color(TreemapView.folderLabelBackground))

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
        }
    }
}

/// The hover and selection outlines, on their own layer above the boxes.
///
/// Being a separate layer is also what makes the outlines correct, not just
/// cheap: a selected or hovered *folder*'s box sits behind its own children's
/// boxes and label bands, so an outline drawn inline with the boxes gets
/// painted over by any child that reaches the parent's edge.
private struct TreemapHighlightLayer: View {
    let hoveredRect: CGRect?
    let selectedRect: CGRect?

    var body: some View {
        Canvas { context, _ in
            // Hover first and subtler; selection last and on top, so a box
            // that is both still reads as selected.
            if let hoveredRect {
                context.stroke(
                    Path(hoveredRect.insetBy(dx: 1, dy: 1)),
                    with: .color(TreemapView.hoveredOutline),
                    lineWidth: 1.5
                )
            }
            if let selectedRect {
                context.stroke(
                    Path(selectedRect.insetBy(dx: 1, dy: 1)),
                    with: .color(TreemapView.selectedOutline),
                    lineWidth: 2
                )
            }
        }
        .allowsHitTesting(false)
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

private extension CGRect {
    /// Scales origin and size by independent per-axis factors — used by
    /// `TreemapView.rescaleLayout` to stretch an already-computed layout
    /// proportionally rather than recomputing it.
    func scaled(x: CGFloat, y: CGFloat) -> CGRect {
        CGRect(x: minX * x, y: minY * y, width: width * x, height: height * y)
    }
}

/// Invisible helper that finds its enclosing `NSWindow` and reports the
/// start/end of a live (edge/corner-drag) resize via `onLiveResizeChange`.
/// SwiftUI's `GeometryReader` reports a stream of size changes with no way
/// to tell "still dragging" from "size settled" apart — `NSWindow`'s own
/// `willStartLiveResizeNotification`/`didEndLiveResizeNotification` is the
/// only place that distinction actually exists, and it's AppKit-only, hence
/// this probe (same pattern as `WindowAppearanceApplicator`/
/// `SplitDividerPositioner` elsewhere in this app for reaching into AppKit
/// state SwiftUI doesn't expose). Deliberately scoped to the window itself:
/// an `HSplitView`/`VSplitView` divider drag is internal subview layout, not
/// an `NSWindow` live resize, and does not fire these notifications — so it
/// correctly falls through to this view's normal (already debounced)
/// relayout path rather than the live-resize rescale short-circuit.
private struct LiveResizeMonitor: NSViewRepresentable {
    let onLiveResizeChange: (Bool) -> Void

    func makeNSView(context: Context) -> NSView {
        let probe = ProbeView()
        probe.onLiveResizeChange = onLiveResizeChange
        return probe
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        guard let probe = nsView as? ProbeView else { return }
        probe.onLiveResizeChange = onLiveResizeChange
    }

    private final class ProbeView: NSView {
        var onLiveResizeChange: ((Bool) -> Void)?

        // The block-based `NotificationCenter.addObserver(forName:object:queue:using:)`
        // API takes an `@Sendable` closure and hands back a token this class
        // would need to store and release in `deinit` — but `deinit` runs
        // non-isolated even on a `@MainActor` type (which `NSView` is), so
        // touching a stored (non-`Sendable`) token array there is rejected
        // under this project's `SWIFT_STRICT_CONCURRENCY = complete`. The
        // old target/selector API sidesteps both problems: no `Sendable`
        // closure, and `removeObserver(self)` only ever passes `self` as an
        // opaque token — it never reads an isolated stored property — so
        // it's valid from `deinit` too.
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            NotificationCenter.default.removeObserver(self)
            guard let window else { return }
            NotificationCenter.default.addObserver(
                self, selector: #selector(liveResizeWillStart),
                name: NSWindow.willStartLiveResizeNotification, object: window
            )
            NotificationCenter.default.addObserver(
                self, selector: #selector(liveResizeDidEnd),
                name: NSWindow.didEndLiveResizeNotification, object: window
            )
        }

        @objc private func liveResizeWillStart() {
            onLiveResizeChange?(true)
        }

        @objc private func liveResizeDidEnd() {
            onLiveResizeChange?(false)
        }

        deinit {
            NotificationCenter.default.removeObserver(self)
        }
    }
}
