import AppKit
import AppleTreeCore
import UniformTypeIdentifiers

/// The "Folder" column's cell: disclosure-triangle-adjacent icon + name.
/// `NSOutlineView` supplies the disclosure triangle itself; this view is
/// just the icon+text content next to it.
final class FolderCellView: NSTableCellView {
    static let reuseIdentifier = NSUserInterfaceItemIdentifier("FolderCell")

    private let nameField = NSTextField(labelWithString: "")

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        identifier = Self.reuseIdentifier

        let icon = NSImageView()
        imageView = icon
        nameField.lineBreakMode = .byTruncatingMiddle
        textField = nameField

        addSubview(icon)
        addSubview(nameField)

        icon.translatesAutoresizingMaskIntoConstraints = false
        nameField.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 2),
            icon.centerYAnchor.constraint(equalTo: centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 16),
            icon.heightAnchor.constraint(equalToConstant: 16),

            nameField.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 4),
            nameField.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4),
            nameField.centerYAnchor.constraint(equalTo: centerYAnchor)
        ])
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func configure(node: FileNode) {
        nameField.stringValue = node.name
        if node.isDirectory {
            imageView?.image = NSWorkspace.shared.icon(for: .folder)
        } else {
            let ext = (node.name as NSString).pathExtension
            let type = ext.isEmpty ? UTType.data : (UTType(filenameExtension: ext) ?? .data)
            imageView?.image = NSWorkspace.shared.icon(for: type)
        }
    }

    static func makeOrReuse(in outlineView: NSOutlineView, node: FileNode) -> FolderCellView {
        let view = (outlineView.makeView(withIdentifier: reuseIdentifier, owner: nil) as? FolderCellView)
            ?? FolderCellView(frame: .zero)
        view.configure(node: node)
        return view
    }
}

/// A simple, reusable single-line text cell (used for the Size column).
final class TextCellView: NSTableCellView {
    private let field = NSTextField(labelWithString: "")

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        addSubview(field)
        textField = field
        field.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            field.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4),
            field.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4),
            field.centerYAnchor.constraint(equalTo: centerYAnchor)
        ])
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func configure(text: String, alignment: NSTextAlignment) {
        field.stringValue = text
        field.alignment = alignment
    }

    static func makeOrReuse(
        in outlineView: NSOutlineView,
        identifier: NSUserInterfaceItemIdentifier,
        text: String,
        alignment: NSTextAlignment
    ) -> TextCellView {
        let view: TextCellView
        if let reused = outlineView.makeView(withIdentifier: identifier, owner: nil) as? TextCellView {
            view = reused
        } else {
            view = TextCellView(frame: .zero)
            view.identifier = identifier
        }
        view.configure(text: text, alignment: alignment)
        return view
    }
}
