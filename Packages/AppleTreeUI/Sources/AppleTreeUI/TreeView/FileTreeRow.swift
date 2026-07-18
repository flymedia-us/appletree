import AppKit
import AppleTreeCore
import UniformTypeIdentifiers

/// The "Folder" column's cell: disclosure-triangle-adjacent icon + name.
/// `NSOutlineView` supplies the disclosure triangle itself; this view is
/// just the icon+text content next to it.
final class FolderCellView: NSTableCellView {
    static let reuseIdentifier = NSUserInterfaceItemIdentifier("FolderCell")

    /// Cache of `NSWorkspace.shared.icon(for:)` results keyed by file
    /// extension (folders use `folderIconCacheKey`, a sentinel that can't
    /// collide with a real `pathExtension`). `configure(node:isDeleted:)`
    /// runs on every row reuse — including every `reloadItem` during an
    /// active scan — so re-resolving the same handful of extensions' system
    /// icons over and over was wasted work. `nonisolated(unsafe)`: only ever
    /// touched from the main thread (`NSOutlineView` cell configuration).
    nonisolated(unsafe) private static var iconCache: [String: NSImage] = [:]
    private static let folderIconCacheKey = "/"

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

    func configure(node: FileNode, isDeleted: Bool) {
        if isDeleted {
            nameField.attributedStringValue = NSAttributedString(string: node.name, attributes: DeletedItemStyle.attributes())
        } else {
            nameField.stringValue = node.name
            nameField.textColor = .labelColor
        }
        if node.isDirectory {
            imageView?.image = Self.icon(forKey: Self.folderIconCacheKey) {
                NSWorkspace.shared.icon(for: .folder)
            }
        } else {
            let ext = (node.name as NSString).pathExtension
            imageView?.image = Self.icon(forKey: ext) {
                let type = ext.isEmpty ? UTType.data : (UTType(filenameExtension: ext) ?? .data)
                return NSWorkspace.shared.icon(for: type)
            }
        }
    }

    private static func icon(forKey key: String, resolve: () -> NSImage) -> NSImage {
        if let cached = iconCache[key] { return cached }
        let icon = resolve()
        iconCache[key] = icon
        return icon
    }

    static func makeOrReuse(in outlineView: NSOutlineView, node: FileNode, isDeleted: Bool) -> FolderCellView {
        let view = (outlineView.makeView(withIdentifier: reuseIdentifier, owner: nil) as? FolderCellView)
            ?? FolderCellView(frame: .zero)
        view.configure(node: node, isDeleted: isDeleted)
        return view
    }
}

/// Shared red-strikethrough styling for an item moved to the Trash — applied
/// consistently across every text-bearing cell type in the Tree View (name,
/// size, dates, ...) so a deleted row reads as struck-through end to end,
/// not just its name.
enum DeletedItemStyle {
    static func attributes(alignment: NSTextAlignment = .natural) -> [NSAttributedString.Key: Any] {
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = alignment
        return [
            .foregroundColor: NSColor.systemRed,
            .strikethroughStyle: NSUnderlineStyle.single.rawValue,
            .paragraphStyle: paragraph
        ]
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

    func configure(text: String, alignment: NSTextAlignment, isDeleted: Bool = false) {
        field.alignment = alignment
        if isDeleted {
            field.attributedStringValue = NSAttributedString(string: text, attributes: DeletedItemStyle.attributes(alignment: alignment))
        } else {
            field.stringValue = text
            field.textColor = .labelColor
        }
    }

    static func makeOrReuse(
        in tableView: NSTableView,
        identifier: NSUserInterfaceItemIdentifier,
        text: String,
        alignment: NSTextAlignment,
        isDeleted: Bool = false
    ) -> TextCellView {
        let view: TextCellView
        if let reused = tableView.makeView(withIdentifier: identifier, owner: nil) as? TextCellView {
            view = reused
        } else {
            view = TextCellView(frame: .zero)
            view.identifier = identifier
        }
        view.configure(text: text, alignment: alignment, isDeleted: isDeleted)
        return view
    }
}
