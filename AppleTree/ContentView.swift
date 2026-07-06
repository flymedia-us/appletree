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
                HSplitView {
                    FileTreeView(rootNode: appState.rootNode, selection: appState.selection, treeVersion: appState.scanGeneration, isScanning: appState.isScanning)
                        .frame(minWidth: 320)
                        // `HSplitView` doesn't expose a percentage-based
                        // initial-size API (and ignores `idealWidth` as a
                        // proportion hint), so the only reliable way to set
                        // a default 60/40 divider position is to reach into
                        // the underlying `NSSplitView` directly once, right
                        // after its first layout.
                        .background(SplitDividerPositioner(fraction: 0.6))
                    ExtensionSummaryView(rootNode: appState.rootNode, treeVersion: appState.scanGeneration)
                        .frame(minWidth: 260)
                }
                .frame(minHeight: 180)
                TreemapView(rootNode: appState.rootNode, selection: appState.selection, treeVersion: appState.scanGeneration)
                    .frame(minHeight: 180)
            }
        }
        .frame(minWidth: 800, minHeight: 480)
    }

    private var toolbar: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Button("Choose Folder…", action: chooseFolder)
                    .disabled(appState.isScanning)
                scanTimerText
            }

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

    @ViewBuilder
    private var scanTimerText: some View {
        if appState.isScanning, let start = appState.scanStartDate {
            TimelineView(.periodic(from: start, by: 0.03)) { context in
                Text("Scanning for \(Self.secondsString(context.date.timeIntervalSince(start))) seconds")
                    .foregroundStyle(.secondary)
                    .font(.caption)
            }
        } else if let duration = appState.lastScanDuration {
            Text("Scan complete in \(Self.secondsString(Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18)) seconds")
                .foregroundStyle(.secondary)
                .font(.caption)
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
