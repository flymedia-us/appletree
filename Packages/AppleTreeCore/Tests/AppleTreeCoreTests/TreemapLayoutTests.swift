import CoreGraphics
import Testing
@testable import AppleTreeCore

@Suite("TreemapLayout")
struct TreemapLayoutTests {
    private func makeDirectory(name: String, children: [FileNode]) -> FileNode {
        let dir = FileNode(name: name, isDirectory: true)
        for child in children { dir.addChild(child) }
        dir.finalizeAsDirectory()
        return dir
    }

    @Test("a single leaf file occupies exactly the given rect")
    func leafOccupiesGivenRect() {
        let file = FileNode(name: "a.txt", isDirectory: false, logicalSize: 100, allocatedSize: 100)
        let rect = CGRect(x: 0, y: 0, width: 200, height: 200)

        let result = TreemapLayout.layout(node: file, in: rect)

        #expect(result.count == 1)
        #expect(result[0].rect == rect)
        #expect(result[0].depth == 0)
    }

    @Test("rect below minBoxSize produces no layout at all")
    func tinyRectProducesNothing() {
        let file = FileNode(name: "a.txt", isDirectory: false, logicalSize: 100, allocatedSize: 100)
        let rect = CGRect(x: 0, y: 0, width: 1, height: 1)

        let result = TreemapLayout.layout(node: file, in: rect, options: TreemapLayoutOptions(minBoxSize: 2))

        #expect(result.isEmpty)
    }

    @Test("two children split proportionally to their size along the longer axis")
    func twoChildrenSplitProportionally() {
        let big = FileNode(name: "big", isDirectory: false, logicalSize: 700, allocatedSize: 700)
        let small = FileNode(name: "small", isDirectory: false, logicalSize: 300, allocatedSize: 300)
        let root = makeDirectory(name: "root", children: [big, small])

        // Wide rect (width > height): split should be vertical (along X).
        let rect = CGRect(x: 0, y: 0, width: 1000, height: 100)
        // No label reserved (rect exactly at threshold boundaries would need a directory
        // label strip too — use a directory rect comfortably above thresholds to isolate
        // the split-proportion behavior from label-inset behavior).
        let options = TreemapLayoutOptions(labelMinWidth: 10_000, labelMinHeight: 10_000)

        let result = TreemapLayout.layout(node: root, in: rect, options: options)
        let childRects = Dictionary(uniqueKeysWithValues: result.compactMap { node in
            node.source === big || node.source === small ? (node.source.name, node.rect) : nil
        })

        let bigRect = try! #require(childRects["big"])
        let smallRect = try! #require(childRects["small"])

        #expect(abs(bigRect.width - 700) < 0.001)
        #expect(abs(smallRect.width - 300) < 0.001)
        #expect(bigRect.height == rect.height)
        #expect(smallRect.height == rect.height)
        #expect(bigRect.minX == rect.minX) // larger child (sorted first) gets the leading portion
    }

    @Test("label gating is strictly greater-than the configured thresholds")
    func labelGatingBoundary() {
        let file = FileNode(name: "a.txt", isDirectory: false, logicalSize: 100, allocatedSize: 100)
        let options = TreemapLayoutOptions(labelMinWidth: 60, labelMinHeight: 14, labelStripHeight: 14)

        let atThreshold = TreemapLayout.layout(
            node: file,
            in: CGRect(x: 0, y: 0, width: 60, height: 14),
            options: options
        )
        #expect(atThreshold[0].labelRect == nil)

        let justAboveThreshold = TreemapLayout.layout(
            node: file,
            in: CGRect(x: 0, y: 0, width: 61, height: 15),
            options: options
        )
        let labelRect = try! #require(justAboveThreshold[0].labelRect)
        #expect(labelRect.height == 14)
        #expect(labelRect.width == 61)
    }

    @Test("a directory's children are laid out inset below its reserved label strip")
    func childrenInsetBelowLabelStrip() {
        let child = FileNode(name: "child", isDirectory: false, logicalSize: 100, allocatedSize: 100)
        let root = makeDirectory(name: "root", children: [child])
        let rect = CGRect(x: 0, y: 0, width: 200, height: 200)
        let options = TreemapLayoutOptions(labelMinWidth: 60, labelMinHeight: 14, labelStripHeight: 14)

        let result = TreemapLayout.layout(node: root, in: rect, options: options)

        let rootNode = result.first { $0.source === root }!
        let childNode = result.first { $0.source === child }!

        #expect(rootNode.labelRect != nil)
        #expect(childNode.rect.minY == rect.minY + 14) // inset below the label strip
        #expect(childNode.rect.height == rect.height - 14)
    }

    @Test("a directory box too small for a label gives its children the full rect, no wasted inset")
    func tinyDirectoryGivesChildrenFullRect() {
        let child = FileNode(name: "child", isDirectory: false, logicalSize: 100, allocatedSize: 100)
        let root = makeDirectory(name: "root", children: [child])
        let rect = CGRect(x: 0, y: 0, width: 10, height: 10) // below label thresholds, above minBoxSize
        let options = TreemapLayoutOptions(minBoxSize: 2, labelMinWidth: 60, labelMinHeight: 14, labelStripHeight: 14)

        let result = TreemapLayout.layout(node: root, in: rect, options: options)

        let rootNode = result.first { $0.source === root }!
        let childNode = result.first { $0.source === child }!

        #expect(rootNode.labelRect == nil)
        #expect(childNode.rect == rect) // no inset applied
    }

    @Test("layout is a pure function: identical inputs produce identical output")
    func layoutIsDeterministic() {
        let a = FileNode(name: "a", isDirectory: false, logicalSize: 500, allocatedSize: 500)
        let b = FileNode(name: "b", isDirectory: false, logicalSize: 300, allocatedSize: 300)
        let c = FileNode(name: "c", isDirectory: false, logicalSize: 200, allocatedSize: 200)
        let root = makeDirectory(name: "root", children: [a, b, c])
        let rect = CGRect(x: 0, y: 0, width: 400, height: 300)

        let first = TreemapLayout.layout(node: root, in: rect)
        let second = TreemapLayout.layout(node: root, in: rect)

        #expect(first.map(\.rect) == second.map(\.rect))
        #expect(first.map(\.depth) == second.map(\.depth))
    }

    @Test("a directory whose children are all individually sub-pixel is flagged hasVisibleChildren=false, not silently empty")
    func manyTinyChildrenFlagsNoVisibleChildren() {
        // 500 tiny files sharing a small rect: each child's slice is far
        // below minBoxSize, so none should be individually laid out, but
        // the directory itself must still report it has real (dropped)
        // content rather than looking indistinguishable from an empty dir.
        let tinyFiles = (0..<500).map { FileNode(name: "f\($0)", isDirectory: false, logicalSize: 10, allocatedSize: 10) }
        let root = makeDirectory(name: "root", children: tinyFiles)
        let rect = CGRect(x: 0, y: 0, width: 50, height: 50)

        let result = TreemapLayout.layout(node: root, in: rect, options: TreemapLayoutOptions(minBoxSize: 2))

        #expect(result.count == 1) // only the directory itself, no visible children
        #expect(result[0].source === root)
        #expect(result[0].hasVisibleChildren == false)
        #expect(root.logicalSize == 5000) // confirms the dropped content was real, not actually empty
    }

    @Test("a directory whose children DO render is flagged hasVisibleChildren=true")
    func visibleChildrenFlagsTrue() {
        let child = FileNode(name: "child", isDirectory: false, logicalSize: 100, allocatedSize: 100)
        let root = makeDirectory(name: "root", children: [child])
        let rect = CGRect(x: 0, y: 0, width: 200, height: 200)

        let result = TreemapLayout.layout(node: root, in: rect)

        let rootNode = result.first { $0.source === root }!
        #expect(rootNode.hasVisibleChildren)
    }

    @Test("respects maxDepth by stopping recursion without dropping the boundary node itself")
    func respectsMaxDepth() {
        let leaf = FileNode(name: "leaf", isDirectory: false, logicalSize: 100, allocatedSize: 100)
        let mid = makeDirectory(name: "mid", children: [leaf])
        let root = makeDirectory(name: "root", children: [mid])
        let rect = CGRect(x: 0, y: 0, width: 200, height: 200)

        let result = TreemapLayout.layout(node: root, in: rect, options: TreemapLayoutOptions(maxDepth: 1))

        #expect(result.contains { $0.source === root })
        #expect(result.contains { $0.source === mid })
        #expect(!result.contains { $0.source === leaf })
    }

    @Test("a totalSize gone stale below the children's actual sum saturates instead of crashing")
    func staleTotalSizeDoesNotCrash() {
        // Regression test for a real crash: `FileNode`'s aggregate fields
        // aren't frozen once a tree is "published" — `markRemoved()`/
        // `unmarkRemoved()` (external-change watch, in-app delete) can
        // recompute a node's own `displaySize` concurrently with a treemap
        // relayout already in flight elsewhere in the tree, so a parent's
        // `totalSize` (read once, at the top of the recursion) can go
        // stale relative to its children's sizes summed moments later.
        // Reproduced here deterministically (no real concurrency needed):
        // `addChild` deliberately never updates a parent's own size, so
        // constructing `root` with an `allocatedSize` smaller than even
        // one child's own gives `layoutChildren` exactly the "totalSize
        // less than a child group's actual sum" shape that used to
        // underflow `totalSize - group1Size` and trap.
        let child1 = FileNode(name: "a", isDirectory: false, logicalSize: 700, allocatedSize: 700)
        let child2 = FileNode(name: "b", isDirectory: false, logicalSize: 700, allocatedSize: 700)
        let root = FileNode(name: "root", isDirectory: true, logicalSize: 500, allocatedSize: 500)
        root.addChild(child1)
        root.addChild(child2)

        let result = TreemapLayout.layout(node: root, in: CGRect(x: 0, y: 0, width: 200, height: 200))

        // The point of this test is that this doesn't crash. `child1` alone
        // already exceeds the (stale) `totalSize`, so its ratio saturates to
        // 1 and `child2` is correctly left with no space at all — same as
        // any box that doesn't clear `minBoxSize`, not a bug to assert
        // against here.
        #expect(result.contains { $0.source === child1 })
        for node in result {
            #expect(node.rect.width >= 0)
            #expect(node.rect.height >= 0)
        }
    }

    @Test("a node marked removed gets no box of its own and doesn't skew its siblings' proportions")
    func removedNodeIsExcludedFromLayout() {
        let doomed = FileNode(name: "doomed", isDirectory: false, logicalSize: 900, allocatedSize: 900)
        let survivor = FileNode(name: "survivor", isDirectory: false, logicalSize: 100, allocatedSize: 100)
        let root = makeDirectory(name: "root", children: [doomed, survivor])
        let rect = CGRect(x: 0, y: 0, width: 200, height: 200)
        // No label reserved, to isolate the exclusion behavior from the
        // label-inset behavior already covered elsewhere in this file.
        let options = TreemapLayoutOptions(labelMinWidth: 10_000, labelMinHeight: 10_000)

        doomed.markRemoved()
        let result = TreemapLayout.layout(node: root, in: rect, options: options)

        #expect(!result.contains { $0.source === doomed })
        let survivorNode = try! #require(result.first { $0.source === survivor })
        // With `doomed` excluded, `root.displaySize` is `survivor`'s alone,
        // so `survivor` should claim the whole content rect rather than
        // some fraction of it sized against a total that includes a box
        // that's no longer drawn.
        #expect(survivorNode.rect.width == rect.width)
        #expect(survivorNode.rect.height == rect.height)
    }
}
