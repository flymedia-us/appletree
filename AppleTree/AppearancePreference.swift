import AppKit
import SwiftUI

/// User-facing appearance choice for the app chrome (not the treemap, which
/// keeps its fixed WizTree-style dark palette by design).
enum AppearancePreference: String, CaseIterable, Identifiable {
    case system
    case light
    case dark

    var id: String { rawValue }

    var label: String {
        switch self {
        case .system: "System"
        case .light: "Light"
        case .dark: "Dark"
        }
    }

    /// Always resolves to a concrete scheme. Passing `nil` through
    /// `.preferredColorScheme` after a forced `.dark` is a known macOS
    /// SwiftUI failure mode — AppKit-hosted views (outline/table) stay dark.
    func resolvedColorScheme(systemIsDark: Bool) -> ColorScheme {
        switch self {
        case .light: .light
        case .dark: .dark
        case .system: systemIsDark ? .dark : .light
        }
    }

    /// Concrete `NSAppearance` for the window and AppKit representables.
    /// Mirrors the system appearance when preference is `.system` rather than
    /// assigning `nil`, which often leaves `NSColor` resolution stuck on the
    /// previously forced dark appearance.
    func nsAppearance(systemIsDark: Bool) -> NSAppearance? {
        let dark = switch self {
        case .light: false
        case .dark: true
        case .system: systemIsDark
        }
        return NSAppearance(named: dark ? .darkAqua : .aqua)
    }

    /// Snapshot of whether the app's effective appearance is currently dark.
    /// Call only after `NSApplication` exists (e.g. from `onAppear`).
    @MainActor
    static var systemIsDark: Bool {
        NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
    }
}
