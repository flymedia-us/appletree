import AppKit

/// WizTree's "% of Parent" column: a proportional fill bar and a percentage
/// number combined in a single cell. Drawn directly in `draw(_:)` rather than
/// composed from subviews — `NSOutlineView` recycles this view per row on
/// scroll, and a draw-based cell avoids per-row subview layout cost.
final class PercentOfParentCellView: NSView {
    static let reuseIdentifier = NSUserInterfaceItemIdentifier("PercentOfParentCell")

    var fraction: Double = 0 {
        didSet { needsDisplay = true }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        identifier = Self.reuseIdentifier
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)

        let barWidth: CGFloat = 70
        let barHeight: CGFloat = 10
        let barRect = NSRect(
            x: 4,
            y: (bounds.height - barHeight) / 2,
            width: barWidth,
            height: barHeight
        )

        let track = NSBezierPath(roundedRect: barRect, xRadius: 2, yRadius: 2)
        NSColor.tertiaryLabelColor.withAlphaComponent(0.35).setFill()
        track.fill()

        let clampedFraction = max(0, min(1, fraction))
        if clampedFraction > 0 {
            NSGraphicsContext.current?.saveGraphicsState()
            NSBezierPath(roundedRect: barRect, xRadius: 2, yRadius: 2).addClip()
            let fillRect = NSRect(x: barRect.minX, y: barRect.minY, width: barRect.width * clampedFraction, height: barRect.height)
            NSColor.controlAccentColor.setFill()
            fillRect.fill()
            NSGraphicsContext.current?.restoreGraphicsState()
        }

        let percentText = SizeFormatting.percentString(for: clampedFraction)
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 11),
            .foregroundColor: NSColor.secondaryLabelColor
        ]
        let textSize = percentText.size(withAttributes: attributes)
        let textRect = NSRect(
            x: barRect.maxX + 6,
            y: (bounds.height - textSize.height) / 2,
            width: textSize.width,
            height: textSize.height
        )
        percentText.draw(in: textRect, withAttributes: attributes)
    }

    static func makeOrReuse(in outlineView: NSOutlineView, fraction: Double) -> PercentOfParentCellView {
        let view = (outlineView.makeView(withIdentifier: reuseIdentifier, owner: nil) as? PercentOfParentCellView)
            ?? PercentOfParentCellView(frame: .zero)
        view.fraction = fraction
        return view
    }
}
