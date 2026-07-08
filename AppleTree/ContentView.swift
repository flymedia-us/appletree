import AppKit
import AppleTreeCore
import AppleTreeUI
import SwiftUI

struct ContentView: View {
    var appState: AppState

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            if appState.shouldShowPermissionNudge {
                PermissionNudgeBanner(
                    deniedFolderCount: appState.tccDeniedFolders,
                    skippedFolderSample: appState.skippedFolderSample,
                    onDismiss: appState.dismissPermissionNudge,
                    onDismissPermanently: appState.dismissPermissionNudgePermanently
                )
                .padding(.horizontal, 12)
                .padding(.top, 8)
            }
            VSplitView {
                HSplitView {
                    FileTreeView(
                        rootNode: appState.rootNode,
                        selection: appState.selection,
                        treeVersion: appState.scanGeneration,
                        isScanning: appState.isScanning,
                        externallyDeletedNodeIDs: appState.externallyDeletedNodeIDs,
                        onTreeMutated: appState.notifyTreeMutated
                    )
                        .frame(minWidth: 320)
                        // `HSplitView` doesn't expose a percentage-based
                        // initial-size API (and ignores `idealWidth` as a
                        // proportion hint), so the only reliable way to set
                        // a default 60/40 divider position is to reach into
                        // the underlying `NSSplitView` directly once, right
                        // after its first layout.
                        .background(SplitDividerPositioner(fraction: 0.6))
                    ExtensionSummaryView(
                        rootNode: appState.rootNode,
                        treeVersion: appState.scanGeneration,
                        onRecomputeFinished: appState.extensionSummaryDidFinishRendering
                    )
                        .frame(minWidth: 260)
                }
                .frame(minHeight: 180)
                TreemapView(
                    rootNode: appState.rootNode,
                    selection: appState.selection,
                    treeVersion: appState.scanGeneration,
                    onRelayoutFinished: appState.treemapDidFinishRendering
                )
                    .frame(minHeight: 180)
            }
        }
        .frame(minWidth: 800, minHeight: 480)
    }

    private var toolbar: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 6) {
                Button("Choose Folder…", action: chooseFolder)
                    .disabled(appState.isScanning)
                HStack(spacing: 6) {
                    if appState.isScanning || appState.isLoadingTree {
                        ProgressView()
                            .controlSize(.small)
                    }
                    scanTimerText
                }
            }

            if let volumeInfo = appState.volumeInfo, let root = appState.rootNode {
                VolumeInfoView(selectionName: selectionLabel(root: root, volumeInfo: volumeInfo), info: volumeInfo)
            }

            Spacer()

            if appState.isScanning {
                Button("Cancel", action: appState.cancelScan)
            }

            if let errorMessage = appState.errorMessage {
                Text(errorMessage)
                    .foregroundStyle(.red)
                    .font(.body)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    /// The volume root itself (whatever it was mounted at) is shown by its
    /// friendly volume name; any other selected folder shows its full path,
    /// since a bare folder name alone (e.g. "Downloads") doesn't disambiguate
    /// which one when the same name exists in several places.
    private func selectionLabel(root: FileNode, volumeInfo: VolumeInfo) -> String {
        root.path == volumeInfo.volumeRootPath ? volumeInfo.volumeName : root.path
    }

    @ViewBuilder
    private var scanTimerText: some View {
        if appState.isScanning {
            Text("Scanning... (Folders: \(SizeFormatting.countString(for: appState.foldersScanned)) Files: \(SizeFormatting.countString(for: appState.filesScanned)))")
                .font(.body)
        } else if appState.isLoadingTree {
            Text("Loading tree...")
                .font(.body)
        } else if let duration = appState.lastScanDuration {
            Text("Scan completed in \(Self.secondsString(Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18)) seconds")
                .font(.body)
        }
    }

    private static func secondsString(_ seconds: Double) -> String {
        String(format: "%.2f", seconds)
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

/// Volume-level capacity readout (Selection / Total / Used / Reserved /
/// Free) — deliberately independent of the scan's own tree total, since a
/// subfolder scan's size is not the disk's size.
private struct VolumeInfoView: View {
    let selectionName: String
    let info: VolumeInfo

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            Self.label("Selection: ", value: selectionName)
            Self.label("Total Space: ", value: SizeFormatting.string(for: info.totalBytes))
            HStack(spacing: 8) {
                Self.label("Space Used: ", value: "\(SizeFormatting.string(for: info.usedBytes)) (\(SizeFormatting.percentString(for: info.usedFraction)))")
                if info.reservedBytes > 0 {
                    Self.label("Reserved Space: ", value: SizeFormatting.string(for: info.reservedBytes))
                }
            }
            Self.label("Space Free: ", value: "\(SizeFormatting.string(for: info.freeBytes)) (\(SizeFormatting.percentString(for: info.freeFraction)))")
        }
        .font(.body)
        .lineLimit(1)
    }

    /// A plain label followed by a bolded value, built from an
    /// `AttributedString` rather than `Text` concatenation (deprecated) or
    /// markdown interpolation — `value` can be an arbitrary filesystem path,
    /// and markdown interpolation would misrender one containing `*`/`_`.
    private static func label(_ label: String, value: String) -> Text {
        var result = AttributedString(label)
        var boldValue = AttributedString(value)
        boldValue.font = .body.bold()
        result += boldValue
        return Text(result)
    }
}

/// Invisible helper view that finds its enclosing `NSSplitView` and sets the
/// first divider's position once, as a fraction of the split view's own
/// width — the one-shot fix for `HSplitView` having no declarative
/// percentage-based initial-size API. Only runs on the first layout pass;
/// the user is free to drag the divider anywhere afterward.
private struct SplitDividerPositioner: NSViewRepresentable {
    let fraction: CGFloat

    func makeNSView(context: Context) -> NSView {
        let probe = NSView()
        DispatchQueue.main.async {
            guard let splitView = probe.enclosingSplitView, splitView.subviews.count >= 2 else { return }
            splitView.setPosition(splitView.bounds.width * fraction, ofDividerAt: 0)
        }
        return probe
    }

    func updateNSView(_ nsView: NSView, context: Context) {}
}

private extension NSView {
    var enclosingSplitView: NSSplitView? {
        var view = superview
        while let current = view {
            if let splitView = current as? NSSplitView { return splitView }
            view = current.superview
        }
        return nil
    }
}
