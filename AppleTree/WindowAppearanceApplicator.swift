import AppKit
import SwiftUI

/// Applies an `NSAppearance` to the enclosing `NSWindow`. SwiftUI's
/// `.preferredColorScheme` alone does not reliably drive AppKit-hosted
/// controls (outline/table alternating rows, headers, scrollers) when
/// switching away from a forced dark scheme.
struct WindowAppearanceApplicator: NSViewRepresentable {
    let appearance: NSAppearance?

    func makeNSView(context: Context) -> NSView {
        let probe = AppearanceProbeView()
        probe.appliedAppearance = appearance
        return probe
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        guard let probe = nsView as? AppearanceProbeView else { return }
        probe.appliedAppearance = appearance
    }

    private final class AppearanceProbeView: NSView {
        var appliedAppearance: NSAppearance? {
            didSet {
                guard appliedAppearance?.name != oldValue?.name else { return }
                apply()
            }
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            apply()
        }

        private func apply() {
            window?.appearance = appliedAppearance
        }
    }
}
