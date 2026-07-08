# Apple Tree

A high-speed disk space analyzer for macOS, inspired by the speed of **WizTree** on Windows and the visualization style of **GrandPerspective**.

Apple Tree scans a folder or whole volume with a parallel, native `fts(3)`-based traversal and shows the result three ways at once — an expandable size-sorted outline, a flat breakdown by file extension, and an interactive treemap — all kept in sync with each other as you select, hover, and delete.

---

## Status

Pre-release. Scanning, all three views, deletion, and Quick Look integration work end-to-end against real volumes. Not yet on the App Store — see [Known limitations](#known-limitations) below.

## Features

- **Fast parallel scanning** — a worker-pool `fts(3)` traversal (see [`DirectoryScanner`](Packages/AppleTreeCore/Sources/AppleTreeCore/Scanning/DirectoryScanner.swift)) that stays on one device, dedups hardlinks/APFS clones and firmlink-joined directories (e.g. `/Users` vs. `/System/Volumes/Data/Users`), and streams incremental progress rather than blocking until the whole tree is walked.
- **Tree View** — an `NSOutlineView`-backed, sortable outline (Folder, % of Parent, Size, Logical Size, Files, Folders, Modified), matching WizTree's default size-descending order.
- **Treemap** — a labeled, ordered treemap colored by file type, with hover tooltips and click-to-select synced against the Tree View.
- **Extension Summary** — a flat, whole-scan breakdown by file extension (color, type name, percent, size, file count).
- **Delete to Trash** — from either the Tree View's context menu or ⌘⌫, with an immediate struck-through row and recomputed parent/treemap/extension totals (no rescan needed).
- **Quick Look** — Space bar to preview the selected file, Finder-style.
- **Live external-change detection** — an `FSEventStream` watch flags files deleted or moved out from under a completed scan by Finder, Terminal, or any other process.
- **Full Disk Access awareness** — scans classify *why* a folder was skipped (TCC-gated, root-owned/system-protected, plain permission-denied, or other) and nudge for Full Disk Access only when it would actually help.
- **Volume capacity readout** — Total/Used/Reserved/Free for the scanned volume, independent of the scan's own tree total.

## Known limitations

- **DUNS/Apple Developer Program enrollment is pending** — the app isn't notarized or code-signed for distribution yet, and there's no App Store listing.
- **Placeholder app icon.** [`AppIcon.appiconset`](AppleTree/Assets.xcassets/AppIcon.appiconset) has a temporary icon, not a final one.
- **No promotional site or privacy policy yet** — planned as a separate, lightweight website, out of scope for this repository.

## Project structure

```
AppleTree/                    App target (SwiftUI shell, AppState, entitlements)
Packages/AppleTreeCore/       Scanning engine, FileNode model, categorization, treemap layout — no UI/framework dependencies
Packages/AppleTreeUI/         AppKit-backed views (Tree View, Treemap, Extension Summary) as SwiftUI NSViewRepresentables
GrandPerspective-3_7_2/       Vendored GPL-licensed reference source, for reading (treemap layout shape, legacy scan patterns) — not compiled into the app; see its own COPYING.txt
WizTree_REFERENCE/            A reference screenshot of WizTree's UI
docs/wiztree-research.md      Research notes on WizTree's/GrandPerspective's UI and scanning approach that informed this design
```

`AppleTreeCore` is deliberately framework-free (no AppKit/SwiftUI) so the scanning engine and layout algorithm stay unit-testable and reusable; `AppleTreeUI` is where all the AppKit/SwiftUI integration lives.

## Building

Requires Xcode 26+ (Swift 6.2 toolchain) to build; the app itself targets macOS 15+ at runtime.

```sh
open AppleTree.xcodeproj
```

Build and run the **AppleTree** scheme. The project file is checked in and buildable as-is; [`project.yml`](project.yml) exists only so the project can be regenerated with [XcodeGen](https://github.com/yonaskolb/XcodeGen) after adding/removing files (`xcodegen generate`).

## Testing

Each Swift package has its own test suite:

```sh
cd Packages/AppleTreeCore && swift test
cd Packages/AppleTreeUI && swift test
```

or run them from Xcode with the `AppleTreeCore`/`AppleTreeUI` schemes (⌘U).

`Packages/AppleTreeCore/Sources/ScanBench` is a small CLI benchmarking harness (`swift run scanbench [path]`) for manually timing/verifying the scanner against real folders — not part of the shipping app, not covered by tests.

## License

No license has been chosen yet for Apple Tree's own source (all rights reserved by default). The vendored [`GrandPerspective-3_7_2`](GrandPerspective-3_7_2) sources remain under the GNU GPL v2 — see [its own `COPYING.txt`](GrandPerspective-3_7_2/COPYING.txt) — and are kept purely as a design reference; no code from it is compiled into or shipped with Apple Tree.
