import SwiftUI

@main
struct AppleTreeApp: App {
    @State private var appState = AppState()

    var body: some Scene {
        WindowGroup {
            ContentView(appState: appState)
        }
        .windowResizability(.contentSize)
    }
}
