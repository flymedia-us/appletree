import AppKit
import SwiftUI

/// Dismissible banner suggesting Full Disk Access when a scan hit
/// TCC-denied folders. Shown only after a real scan surfaces evidence
/// (see `AppState.shouldShowPermissionNudge`) rather than a pre-emptive
/// permission probe.
struct PermissionNudgeBanner: View {
    let deniedFolderCount: Int
    let onDismiss: () -> Void
    let onDismissPermanently: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "lock.shield")
                .foregroundStyle(.orange)
                .padding(.top, 2)

            VStack(alignment: .leading, spacing: 4) {
                Text("Skipped \(deniedFolderCount) folder\(deniedFolderCount == 1 ? "" : "s") that macOS restricts without Full Disk Access.")
                    .font(.callout)
                Text("Granting access — and re-scanning the whole disk rather than a subfolder — can recover this space. Local Time Machine snapshots and other users' files stay hidden either way.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                HStack(spacing: 12) {
                    Button("Open Privacy Settings…", action: openPrivacySettings)
                    Button("Don't Ask Again", action: onDismissPermanently)
                        .foregroundStyle(.secondary)
                }
                .font(.callout)
                .padding(.top, 2)
            }

            Spacer(minLength: 0)

            Button(action: onDismiss) {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
        }
        .padding(10)
        .background(Color.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
    }

    private func openPrivacySettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles") else { return }
        NSWorkspace.shared.open(url)
    }
}
