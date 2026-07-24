import SwiftUI

/// Preferences for the 1.0 release — appearance, destructive-action safety,
/// and a way to undo the permanent Full Disk Access nudge.
struct SettingsView: View {
    @AppStorage(AppState.appearancePreferenceKey) private var appearanceRawValue = AppearancePreference.system.rawValue
    @AppStorage(AppState.confirmBeforeDeleteKey) private var confirmBeforeDelete = true
    @AppStorage(AppState.fdaNudgeDontAskAgainKey) private var fdaNudgeDismissed = false

    private var appearance: Binding<AppearancePreference> {
        Binding(
            get: { AppearancePreference(rawValue: appearanceRawValue) ?? .system },
            set: { appearanceRawValue = $0.rawValue }
        )
    }

    var body: some View {
        Form {
            Section("Appearance") {
                Picker("Theme", selection: appearance) {
                    ForEach(AppearancePreference.allCases) { preference in
                        Text(preference.label).tag(preference)
                    }
                }
                .pickerStyle(.segmented)
            }
            Section("Safety") {
                Toggle("Confirm before moving items to Trash", isOn: $confirmBeforeDelete)
            }
            Section("Permissions") {
                Toggle("Don't ask again about Full Disk Access", isOn: $fdaNudgeDismissed)
                Text("When a scan skips folders that Full Disk Access would unlock, AppleTree can show a banner. Turn this off to see that banner again.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 420)
        .padding()
    }
}
