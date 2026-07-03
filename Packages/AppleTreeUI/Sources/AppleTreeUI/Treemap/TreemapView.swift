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
                    selection.hoveredNodeID = TreemapHitTester.hitTest(location, in: layout)?.id
                case .ended:
                    selection.hoveredNodeID = nil
                }
            }
            .background(Color(nsColor: .textBackgroundColor))
        }
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

        for node in layout {
            let rect = node.rect
            guard rect.width >= 1, rect.height >= 1 else { continue }

            if !node.source.isDirectory {
                context.fill(Path(rect), with: .color(node.source.category.swiftUIColor))
            } else if node.source.displaySize > 0, !node.hasVisibleChildren {
                // This directory has real content, but every child was
                // individually too small to render on its own (a folder of
                // many tiny files at this canvas size) — a flat neutral
                // tint distinguishes "content too fine-grained to show
                // individually" from true empty space, instead of leaving
                // an unexplained blank hole.
                context.fill(Path(rect), with: .color(.gray.opacity(0.12)))
            }

            context.stroke(Path(rect), with: .color(.black.opacity(0.25)), lineWidth: 0.5)

            if node.source.id == hoveredID {
                context.fill(Path(rect), with: .color(.white.opacity(0.15)))
            }
            if node.source.id == selectedID {
                context.stroke(Path(rect.insetBy(dx: 1, dy: 1)), with: .color(.white), lineWidth: 2)
            }

            if let labelRect = node.labelRect {
                let label = "\(node.source.name)  (\(SizeFormatting.string(for: node.source.displaySize)))"
                let text = Text(label)
                    .font(.system(size: 10))
                    // Directory boxes are unfilled (or only faintly tinted) —
                    // white text there would be invisible against the
                    // light canvas background. File boxes are filled with a
                    // saturated category color, where white reads clearly.
                    .foregroundColor(node.source.isDirectory ? .black : .white)
                context.draw(
                    text,
                    in: CGRect(x: labelRect.minX + 4, y: labelRect.minY, width: max(0, labelRect.width - 6), height: labelRect.height)
                )
            }
        }
    }
}

extension FileCategory {
    var swiftUIColor: Color {
        Color(red: color.red, green: color.green, blue: color.blue)
    }
}
