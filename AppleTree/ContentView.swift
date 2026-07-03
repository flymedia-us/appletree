import AppKit
import AppleTreeUI
import SwiftUI

struct ContentView: View {
    var appState: AppState

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            VSplitView {
                FileTreeView(rootNode: appState.rootNode, selection: appState.selection, treeVersion: appState.scanGeneration)
                    .frame(minHeight: 180)
                TreemapView(rootNode: appState.rootNode, selection: appState.selection, treeVersion: appState.scanGeneration)
                    .frame(minHeight: 180)
            }
        }
        .frame(minWidth: 800, minHeight: 480)
    }

    private var toolbar: some View {
        HStack(spacing: 12) {
            Button("Choose Folder…", action: chooseFolder)
                .disabled(appState.isScanning)

            if appState.isScanning {
                ProgressView()
                    .controlSize(.small)
                Text("\(appState.filesScanned) files, \(SizeFormatting.string(for: appState.bytesScanned))")
                    .foregroundStyle(.secondary)
                    .font(.callout)
                    .lineLimit(1)
                Spacer()
                Button("Cancel", action: appState.cancelScan)
            } else if let root = appState.rootNode {
                Text("\(root.path) — \(SizeFormatting.string(for: root.displaySize)), \(root.fileCount) files")
                    .foregroundStyle(.secondary)
                    .font(.callout)
                    .lineLimit(1)
                if appState.foldersSkipped > 0 {
                    Text("(\(appState.foldersSkipped) folders skipped)")
                        .foregroundStyle(.tertiary)
                        .font(.caption)
                }
                Spacer()
            } else {
                Spacer()
            }

            if let errorMessage = appState.errorMessage {
                Text(errorMessage)
                    .foregroundStyle(.red)
                    .font(.callout)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Scan"
        panel.message = "Choose a folder or volume to scan"

        guard panel.runModal() == .OK, let url = panel.url else { return }
        appState.startScan(root: url)
    }
}
