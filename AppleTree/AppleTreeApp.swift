import AppKit
import SwiftUI

@main
struct AppleTreeApp: App {
    @State private var appState = AppState()
    @AppStorage(AppState.appearancePreferenceKey) private var appearanceRawValue = AppearancePreference.system.rawValue
    /// Tracks the live system appearance so `.system` can resolve to an
    /// explicit light/dark scheme (never `nil` — see `AppearancePreference`).
    /// Created empty: KVO on `NSApp` must wait until the app object exists
    /// (see `onAppear` below) — touching `NSApp` during `@State` init crashes.
    @State private var systemAppearance = SystemAppearanceMonitor()

    private var appearancePreference: AppearancePreference {
        AppearancePreference(rawValue: appearanceRawValue) ?? .system
    }

    private var resolvedScheme: ColorScheme {
        appearancePreference.resolvedColorScheme(systemIsDark: systemAppearance.isDark)
    }

    private var resolvedNSAppearance: NSAppearance? {
        appearancePreference.nsAppearance(systemIsDark: systemAppearance.isDark)
    }

    var body: some Scene {
        // Single primary window — avoids multi-window copies of one scan
        // state fighting each other. File → Open Folder… still works via
        // the replaced New Item command group below.
        Window("Apple Tree", id: "main") {
            ContentView(appState: appState, colorScheme: resolvedScheme)
                .preferredColorScheme(resolvedScheme)
                .background(WindowAppearanceApplicator(appearance: resolvedNSAppearance))
                .onAppear { systemAppearance.startIfNeeded() }
        }
        // Ideal size for a fresh window; `.contentMinSize` keeps the
        // ContentView min frame as a floor while still allowing free enlarge.
        // (`.contentSize` with only minWidth/minHeight collapses to that min.)
        .defaultSize(width: 1200, height: 800)
        .windowResizability(.contentMinSize)
        .commands {
            CommandGroup(replacing: .appInfo) {
                Button("About Apple Tree") {
                    Self.showAboutPanel()
                }
            }
            CommandGroup(replacing: .newItem) {
                Button("Open Folder…") {
                    appState.presentFolderPickerAndScan()
                }
                .keyboardShortcut("o", modifiers: .command)
                .disabled(appState.isScanning)
            }
        }

        Settings {
            SettingsView()
                .preferredColorScheme(resolvedScheme)
                .background(WindowAppearanceApplicator(appearance: resolvedNSAppearance))
                .onAppear { systemAppearance.startIfNeeded() }
        }
    }

    private static func showAboutPanel() {
        let credits = NSAttributedString(
            string: """
            A high-speed disk space analyzer for macOS.

            © 2026 Fly Media LLC
            Free software under the GNU General Public License v3.
            """,
            attributes: [
                .font: NSFont.systemFont(ofSize: NSFont.smallSystemFontSize),
                .foregroundColor: NSColor.labelColor,
                .paragraphStyle: {
                    let style = NSMutableParagraphStyle()
                    style.alignment = .center
                    return style
                }(),
            ]
        )
        NSApp.orderFrontStandardAboutPanel(options: [
            .credits: credits,
            .applicationName: "Apple Tree",
        ])
    }
}

/// Keeps a live KVO on `NSApp.effectiveAppearance` so System theme can
/// resolve to an explicit light/dark scheme when the user toggles Appearance
/// in System Settings. Must not touch `NSApp` in `init` — that runs while
/// SwiftUI is still constructing `@State` storage, before `NSApplication`
/// exists, and force-unwraps to a launch crash.
@Observable
@MainActor
final class SystemAppearanceMonitor {
    private(set) var isDark: Bool
    private var observation: NSKeyValueObservation?

    init() {
        // Safe pre-NSApp probe via UserDefaults; refined once `startIfNeeded`
        // can read `NSApp.effectiveAppearance`.
        isDark = UserDefaults.standard.string(forKey: "AppleInterfaceStyle") == "Dark"
    }

    func startIfNeeded() {
        guard observation == nil else {
            isDark = AppearancePreference.systemIsDark
            return
        }
        isDark = AppearancePreference.systemIsDark
        observation = NSApp.observe(\.effectiveAppearance, options: [.new]) { [weak self] _, _ in
            // KVO can fire before the new appearance is fully installed —
            // hop to the next run-loop turn so `bestMatch` sees the update.
            DispatchQueue.main.async {
                self?.isDark = AppearancePreference.systemIsDark
            }
        }
    }
}
