import AppKit
import SwiftUI

/// The extension summary table's color column: a small solid-colored swatch
/// centered in the cell, rather than any text.
final class ColorSwatchCellView: NSTableCellView {
    static let reuseIdentifier = NSUserInterfaceItemIdentifier("ColorSwatchCell")

    private let swatch = NSView()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        identifier = Self.reuseIdentifier

        swatch.wantsLayer = true
        swatch.layer?.cornerRadius = 2
        addSubview(swatch)
        swatch.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            swatch.centerXAnchor.constraint(equalTo: centerXAnchor),
            swatch.centerYAnchor.constraint(equalTo: centerYAnchor),
            swatch.widthAnchor.constraint(equalToConstant: 12),
            swatch.heightAnchor.constraint(equalToConstant: 12)
        ])
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func configure(color: Color) {
        swatch.layer?.backgroundColor = NSColor(color).cgColor
    }

    static func makeOrReuse(in tableView: NSTableView, color: Color) -> ColorSwatchCellView {
        let view = (tableView.makeView(withIdentifier: reuseIdentifier, owner: nil) as? ColorSwatchCellView)
            ?? ColorSwatchCellView(frame: .zero)
        view.configure(color: color)
        return view
    }
}
