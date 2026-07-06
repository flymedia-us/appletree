/// The unit of treemap color. A large number of real-world extensions map
/// down to this small, visually-legible set (see `ExtensionCategoryMap`).
///
/// `.noExtension` is first-class and distinct from `.other`: WizTree's own
/// reference UI shows "(No Extension)" as a top-level category (often the
/// single largest slice), so extensionless files must never be silently
/// folded into the generic catch-all.
public enum FileCategory: String, Sendable, CaseIterable, Codable {
    case video
    case image
    case audio
    case codeOrDeveloper
    case archive
    case application
    case system
    case document
    case other
    case noExtension

    /// A fixed, distinct RGB color per category, expressed as plain
    /// component doubles in [0, 1] rather than a UI-framework `Color` — this
    /// type stays framework-free so `AppleTreeUI` can convert to
    /// `SwiftUI.Color` at the presentation layer.
    public var color: (red: Double, green: Double, blue: Double) {
        switch self {
        case .video: (0.55, 0.25, 0.85) // purple
        case .image: (0.20, 0.65, 0.90) // sky blue
        case .audio: (0.95, 0.65, 0.15) // amber
        case .codeOrDeveloper: (0.20, 0.75, 0.45) // green
        case .archive: (0.75, 0.55, 0.25) // tan/brown
        case .application: (0.90, 0.30, 0.30) // red
        case .system: (0.55, 0.55, 0.60) // slate gray
        case .document: (0.30, 0.45, 0.90) // blue
        case .other: (0.65, 0.65, 0.65) // neutral gray
        case .noExtension: (0.85, 0.20, 0.20) // strong red (matches its outsized share in the reference screenshot)
        }
    }
}
