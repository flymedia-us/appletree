import SwiftUI

@main
struct AppleTreeApp: App {
    @State private var appState = AppState()
    @AppStorage(AppState.appearancePreferenceKey) private var appearanceRawValue = AppearancePreference.system.rawValue

    private var preferredScheme: ColorScheme? {
        (AppearancePreference(rawValue: appearanceRawValue) ?? .system).colorScheme
    }

    var body: some Scene {
        WindowGroup {
            ContentView(appState: appState)
                .preferredColorScheme(preferredScheme)
        }
        // Ideal size for a fresh window; `.contentMinSize` keeps the
        // ContentView min frame as a floor while still allowing free enlarge.
        // (`.contentSize` with only minWidth/minHeight collapses to that min.)
        .defaultSize(width: 1200, height: 800)
        .windowResizability(.contentMinSize)
        .commands {
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
                .preferredColorScheme(preferredScheme)
        }
    }
}
