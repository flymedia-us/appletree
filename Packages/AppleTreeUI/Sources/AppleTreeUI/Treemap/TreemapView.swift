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

    @State private var layout: [TreemapNode] = []
    @State private var layoutSize: CGSize = .zero
    @State private var layoutedRootID: FileNode.ID?
    @State private var layoutedVersion: Int = -1
    @State private var hoveredFolder: FileNode?
    @State private var hoverPoint: CGPoint = .zero

    public init(rootNode: FileNode?, selection: SelectionModel, treeVersion: Int) {
        self.rootNode = rootNode
        self.selection = selection
        self.treeVersion = treeVersion
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
                    selection.selectedNodeID = TreemapHitTester.hitTest(value.location, in: layout)?.id
                }
            )
            .onContinuousHover { phase in
                switch phase {
                case .active(let location):
                    let folder = TreemapHitTester.hitTestFolderLabel(location, in: layout)
                    hoveredFolder = folder
                    hoverPoint = location
                    selection.hoveredNodeID = folder?.id
                case .ended:
                    hoveredFolder = nil
                    selection.hoveredNodeID = nil
                }
            }
            .background(Self.backgroundColor)
            .overlay(alignment: .topLeading) {
                if let hoveredFolder {
                    FolderHoverTooltip(node: hoveredFolder)
                        .fixedSize()
                        .offset(tooltipOffset(in: proxy.size))
                        .allowsHitTesting(false)
                }
            }
        }
    }

    /// Dark neutral background the colored file boxes and folder label bands
    /// sit on top of — matches the reference treemap styling (#3A3939).
    private static let backgroundColor = Color(red: 0x3A / 255.0, green: 0x39 / 255.0, blue: 0x39 / 255.0)
    private static let folderLabelBackground = Color(red: 0x50 / 255.0, green: 0x4F / 255.0, blue: 0x4F / 255.0)
    private static let folderStroke = Color.white.opacity(0.18)
    private static let selectedOutline = Color.white
    private static let hoveredOutline = Color.white.opacity(0.5)

    /// Keeps the tooltip from running off the far edge of the canvas by
    /// flipping which side of the cursor it renders on, using a rough
    /// estimate of the tooltip's own footprint (its real size isn't known
    /// until SwiftUI lays it out).
    private func tooltipOffset(in containerSize: CGSize) -> CGSize {
        let estimatedWidth: CGFloat = 260
        let estimatedHeight: CGFloat = 40
        let margin: CGFloat = 14
        let flipX = hoverPoint.x + margin + estimatedWidth > containerSize.width
        let flipY = hoverPoint.y + margin + estimatedHeight > containerSize.height
        let x = flipX ? hoverPoint.x - margin - estimatedWidth : hoverPoint.x + margin
        let y = flipY ? hoverPoint.y - margin - estimatedHeight : hoverPoint.y + margin
        return CGSize(width: x, height: y)
    }

    private func relayout(size: CGSize) {
        guard let rootNode, size.width > 0, size.height > 0 else {
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
        layout = TreemapLayout.layout(node: rootNode, in: CGRect(origin: .zero, size: size))
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

/// Small path+size callout that follows the cursor while hovering a folder's
/// name in the treemap.
private struct FolderHoverTooltip: View {
    let node: FileNode

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(node.path)
                .font(.system(size: 11, weight: .medium))
                .lineLimit(1)
                .truncationMode(.middle)
            Text(SizeFormatting.string(for: node.displaySize))
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
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
