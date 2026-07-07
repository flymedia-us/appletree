import AppKit
import AppleTreeCore
import SwiftUI

/// Dismissible banner suggesting Full Disk Access when a scan hit
/// TCC-denied folders. Shown only after a real scan surfaces evidence
/// (see `AppState.shouldShowPermissionNudge`) rather than a pre-emptive
/// permission probe.
struct PermissionNudgeBanner: View {
    let deniedFolderCount: Int
    let skippedFolderSample: [SkippedFolder]
    let onDismiss: () -> Void
    let onDismissPermanently: () -> Void

    @State private var showsDetails = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "lock.shield")
                    .foregroundStyle(.orange)
                    .padding(.top, 2)

                VStack(alignment: .leading, spacing: 4) {
                    Text("Skipped \(deniedFolderCount) folder\(deniedFolderCount == 1 ? "" : "s") that macOS restricts without Full Disk Access.")
                        .font(.body)
                    Text("Granting access — and re-scanning the whole disk rather than a subfolder — can recover this space. Local Time Machine snapshots and other users' files stay hidden either way.")
                        .font(.body)
                    HStack(spacing: 12) {
                        Button("Open Privacy Settings…", action: openPrivacySettings)
                        Button("Don't Ask Again", action: onDismissPermanently)
                        Button(showsDetails ? "Hide Details" : "Show Details") {
                            showsDetails.toggle()
                        }
                    }
                    .font(.body)
                    .padding(.top, 2)
                }

                Spacer(minLength: 0)

                Button(action: onDismiss) {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }

            if showsDetails {
                skippedFolderList
            }
        }
        .padding(10)
        .background(Color.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
    }

    private var skippedFolderList: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 2) {
                ForEach(skippedFolderSample) { folder in
                    Text("\(folder.path) — \(describe(folder.reason))")
                        .font(.callout)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxHeight: 200)
        .padding(8)
        .background(Color.black.opacity(0.05), in: RoundedRectangle(cornerRadius: 6))
    }

    private func describe(_ reason: FolderSkipReason) -> String {
        switch reason {
        case .tccDenied: "restricted by macOS privacy protection (Full Disk Access)"
        case .systemProtected: "a root-owned system database — no permission grant unlocks this"
        case .accessDenied: "owned by another user or otherwise permission-denied"
        case .other(let errno): "errno \(errno)"
        }
    }

    private func openPrivacySettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles") else { return }
        NSWorkspace.shared.open(url)
    }
}
