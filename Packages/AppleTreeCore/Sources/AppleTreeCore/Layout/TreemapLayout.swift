import CoreGraphics

/// Pure, deterministic treemap layout: no I/O, no mutation of `FileNode`,
/// same inputs always produce the same output — directly unit-testable
/// against synthetic trees.
///
/// Algorithm: a recursive binary-split "ordered/cushion treemap" — the same
/// family used by classic Mac disk-map utilities (read for algorithm shape,
/// implemented independently here) and visually equivalent to WizTree's clean
/// rectangular blocks (as opposed to the classic Bruls/Huizing/van Wijk
/// "squarified" algorithm's thinner slivers). Children are split into two
/// groups at whichever point makes each group's cumulative size closest to
/// half the total, then each group recurses into its own sub-rect — repeating
/// until every group is a single node.
///
/// Label rendering: whenever a box clears the label-size threshold, a thin
/// strip is reserved at its top for a name+size label, and its children (if
/// any) are laid out in the remaining inset rect. Applied uniformly at every
/// recursion depth, this single rule is what produces WizTree's nested
/// "stack of labels" look for a chain of mostly-one-dominant-child
/// directories — no special-cased breadcrumb logic needed.
public enum TreemapLayout {
    public static func layout(
        node: FileNode,
        in rect: CGRect,
        depth: Int = 0,
        options: TreemapLayoutOptions = TreemapLayoutOptions()
    ) -> [TreemapNode] {
        var result: [TreemapNode] = []
        layoutNode(node, in: rect, depth: depth, options: options, into: &result)
        return result
    }

    private static func layoutNode(
        _ node: FileNode,
        in rect: CGRect,
        depth: Int,
        options: TreemapLayoutOptions,
        into result: inout [TreemapNode]
    ) {
        guard !node.isRemoved else { return }
        guard rect.width >= options.minBoxSize, rect.height >= options.minBoxSize else { return }

        let hasLabel = rect.width > options.labelMinWidth && rect.height > options.labelMinHeight
        let labelRect = hasLabel
            ? CGRect(x: rect.minX, y: rect.minY, width: rect.width, height: options.labelStripHeight)
            : nil

        let nodeIndex = result.count
        result.append(TreemapNode(source: node, rect: rect, labelRect: labelRect, depth: depth))

        // Excludes removed nodes: `node.displaySize` (used as `totalSize`
        // below) already excludes them post-`markRemoved()`, so they must
        // also be absent here — otherwise `layoutChildren` would split the
        // rect using sizes that don't sum to its own `totalSize` parameter.
        let visibleChildren = node.children.filter { !$0.isRemoved }
        guard node.isDirectory, !visibleChildren.isEmpty else { return }
        if let maxDepth = options.maxDepth, depth >= maxDepth { return }

        let contentRect = hasLabel
            ? CGRect(x: rect.minX, y: rect.minY + options.labelStripHeight, width: rect.width, height: rect.height - options.labelStripHeight)
            : rect

        let countBeforeChildren = result.count
        // Snapshot every child's `displaySize` exactly once, here, and thread
        // the snapshot down the whole binary-split recursion below.
        //
        // `splitPoint` used to re-read `FileNode.displaySize` live in its own
        // loop, and `group1Size` read it live again, independently, moments
        // later — two reads of state that keeps changing while a scan is
        // still filling in this subtree, or while `markRemoved()`/
        // `unmarkRemoved()` (external-change watch, in-app delete) fires.
        // When those two live reads disagreed, `splitPoint`'s own bookkeeping
        // invariant (`cumulative` never exceeds `half` before its own bounds
        // check catches it) broke, underflowing its checked `UInt64`
        // subtraction and trapping the process outright — confirmed as a
        // real crash on a live scan, deeper in the recursion than the
        // `totalSize - group1Size` underflow already guarded below.
        //
        // Taking the snapshot once *per directory* rather than once per
        // recursion level (as it was) is both faster and strictly more
        // consistent: `displaySize` is a lock acquisition per child, and
        // re-mapping at every level of a binary split costs `n log n` of them
        // per directory instead of `n`. Every level now works off numbers
        // that agree with each other by construction.
        let sizes = visibleChildren.map(\.displaySize)
        layoutChildren(
            visibleChildren[...],
            sizes: sizes[...],
            totalSize: node.displaySize,
            in: contentRect,
            depth: depth + 1,
            options: options,
            into: &result
        )
        result[nodeIndex].hasVisibleChildren = result.count > countBeforeChildren
    }

    /// `children` must already be sorted descending by size (guaranteed by
    /// `FileNode.finalizeAsDirectory`, relied on rather than re-sorted here —
    /// re-sorting on every layout pass, e.g. every zoom/pan frame, would be
    /// wasted work for data that doesn't change between scans).
    ///
    /// `sizes` is the caller's `displaySize` snapshot, index-aligned with
    /// `children`; both are sliced together as the recursion splits.
    private static func layoutChildren(
        _ children: ArraySlice<FileNode>,
        sizes: ArraySlice<UInt64>,
        totalSize: UInt64,
        in rect: CGRect,
        depth: Int,
        options: TreemapLayoutOptions,
        into result: inout [TreemapNode]
    ) {
        guard !children.isEmpty, totalSize > 0 else { return }

        // Nothing inside a rect this small can ever be drawn, so there is no
        // point subdividing it. Splitting only ever shrinks a rect — both
        // halves inherit one dimension and divide the other — so once either
        // dimension is below `minBoxSize`, every box in this entire subtree
        // is guaranteed to fail `layoutNode`'s identical check on arrival.
        //
        // Without this the split recursion ran to completion regardless,
        // descending through every child of every directory just to discard
        // each one at the leaf: on a 200k-file tree that was most of the
        // layout's total cost, and it also emitted a large tail of
        // 2-pixel boxes for the renderer to draw for no visible benefit.
        guard rect.width >= options.minBoxSize, rect.height >= options.minBoxSize else { return }

        if children.count == 1 {
            layoutNode(children[children.startIndex], in: rect, depth: depth, options: options, into: &result)
            return
        }

        let splitOffset = splitPoint(sizes: sizes)
        let splitIndex = children.index(children.startIndex, offsetBy: splitOffset)
        let sizesSplitIndex = sizes.index(sizes.startIndex, offsetBy: splitOffset)
        let group1 = children[children.startIndex..<splitIndex]
        let group2 = children[splitIndex...]
        let sizes1 = sizes[sizes.startIndex..<sizesSplitIndex]
        let sizes2 = sizes[sizesSplitIndex...]
        let group1Size = sizes1.reduce(UInt64(0), +)
        // `totalSize` was read once by the caller (ultimately from a
        // parent's `displaySize`, at the top of the recursion) — a moment
        // before this call's own `sizes` snapshot above, so it can still be
        // stale relative to `group1Size`'s fresh sum even though the two are
        // now internally consistent with each other. A plain
        // `totalSize - group1Size` underflowed and trapped for real;
        // saturating at 0 instead makes a stale-for-one-frame split
        // harmless — it self-corrects on the next relayout, which the same
        // change that caused the staleness already triggers.
        let group2Size = totalSize > group1Size ? totalSize - group1Size : 0
        let ratio = min(1, CGFloat(Double(group1Size) / Double(totalSize)))

        let rect1: CGRect
        let rect2: CGRect
        if rect.width > rect.height {
            let splitX = rect.minX + rect.width * ratio
            rect1 = CGRect(x: rect.minX, y: rect.minY, width: splitX - rect.minX, height: rect.height)
            rect2 = CGRect(x: splitX, y: rect.minY, width: rect.maxX - splitX, height: rect.height)
        } else {
            let splitY = rect.minY + rect.height * ratio
            rect1 = CGRect(x: rect.minX, y: rect.minY, width: rect.width, height: splitY - rect.minY)
            rect2 = CGRect(x: rect.minX, y: splitY, width: rect.width, height: rect.maxY - splitY)
        }

        layoutChildren(group1, sizes: sizes1, totalSize: group1Size, in: rect1, depth: depth, options: options, into: &result)
        layoutChildren(group2, sizes: sizes2, totalSize: group2Size, in: rect2, depth: depth, options: options, into: &result)
    }

    /// The 0-based offset into `sizes` where cumulative size first reaches
    /// half of `sizes`'s own total, choosing whichever adjacent boundary
    /// lands closer to the true half — this is what makes it an "ordered"
    /// treemap rather than an arbitrary first/rest split. Deliberately halves
    /// `sizes`'s own sum, not the caller's separately-passed `totalSize`
    /// parameter (see `layoutChildren`'s doc comment on why those two can
    /// legitimately differ): `cumulative` and `half` must come from the same
    /// snapshot for this function's own bounds check to be trustworthy.
    /// Always returns an offset strictly between `0` and `sizes.count` so
    /// both groups are non-empty.
    private static func splitPoint(sizes: ArraySlice<UInt64>) -> Int {
        let half = sizes.reduce(UInt64(0), +) / 2
        var cumulative: UInt64 = 0

        // `enumerated()` rather than `indices`: `sizes` is a slice whose
        // indices are offsets into the parent array, while every caller wants
        // a 0-based offset within the slice.
        for (offset, size) in sizes.enumerated() {
            let next = cumulative + size
            if next >= half {
                let distIncluding = next - half
                let distExcluding = half - cumulative
                let boundary = distIncluding < distExcluding ? offset + 1 : offset
                return clampSplitOffset(boundary, count: sizes.count)
            }
            cumulative = next
        }
        return clampSplitOffset(sizes.count - 1, count: sizes.count)
    }

    private static func clampSplitOffset(_ offset: Int, count: Int) -> Int {
        if offset <= 0 { return 1 }
        if offset >= count { return count - 1 }
        return offset
    }
}
