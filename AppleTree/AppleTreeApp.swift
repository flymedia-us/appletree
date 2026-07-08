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
