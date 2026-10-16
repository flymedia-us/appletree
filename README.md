<p align="center">
  <img src="docs/icon.png" width="128" height="128" alt="AppleTree">
</p>

# AppleTree

A high-speed disk space analyzer for macOS, inspired by the speed of **WizTree** on Windows and the visualization style of **GrandPerspective**.

Scan a folder or a whole volume and see exactly what is using space — as a sortable outline, a breakdown by file type, and an interactive treemap, all kept in sync.

**[Download 1.1.1](https://github.com/flymedia-us/appletree/releases/tag/v1.1.1)** · **[Mac App Store](https://apps.apple.com/us/app/appletree-scan/id6796500800?mt=12)** · **[Website](https://apps.flymedia.us/appletree/)** · **GPLv3**

Requires macOS 15 or later. Runs on Apple silicon and Intel.

## Getting AppleTree

The [Mac App Store](https://apps.apple.com/us/app/appletree-scan/id6796500800?mt=12) is the preferred way to run AppleTree (listed as **AppleTree Scan**). It updates automatically and supports continued development.

The signed and notarized [GitHub download](https://github.com/flymedia-us/appletree/releases/tag/v1.1.1) is free and does not auto-update. Open the DMG and drag AppleTree into Applications. Version 1.1.1 is available there; its App Store update is still being prepared.

This repository is the complete source. You can read it, modify it, and build it yourself at no cost.

## Features

- **Fast parallel scanning** — a worker-pool `fts(3)` traversal that stays on one device, deduplicates hardlinks and firmlink-joined directories, and streams progress instead of blocking until the walk finishes
- **Tree View** — a sortable outline (Folder, % of Parent, Size, Logical Size, Files, Folders, Modified)
- **Treemap** — a labeled, ordered treemap colored by file type, synced with the Tree View
- **Extension Summary** — a whole-scan breakdown by file extension
- **Delete to Trash** — ⌘⌫ or the context menu, with confirmation (on by default) and instant recomputed totals. Items already in macOS Trash folders are deleted permanently; Trash containers are emptied for the current user. Settings also offers permanent deletion for all items; permanent deletion always requires confirmation.
- **Quick Look** — Space bar, Finder-style
- **Live external-change detection** — files deleted or moved by other apps are flagged in a completed scan
- **Honest skip reasons** — privacy-protected, system-owned, or permission-denied, with Full Disk Access suggested only when it would help
- **Volume capacity readout** — Total / Used / Reserved / Free for the scanned volume
- **Nothing leaves your Mac** — no account, no analytics, no network calls

## Building

Requires Xcode 26 or later (Swift 6.2). The app targets macOS 15+.

```sh
open AppleTree.xcodeproj
```

Build and run the **AppleTree** scheme. The project file is checked in; [`project.yml`](project.yml) is only used if you regenerate it with [XcodeGen](https://github.com/yonaskolb/XcodeGen) after adding or removing files (`xcodegen generate`).

Scanning a home folder or whole volume may prompt for Desktop, Documents, or Downloads access. Other privacy-protected folders are skipped unless Full Disk Access is granted. Opening a single folder directly usually does not need Full Disk Access.

## Testing

```sh
swift test --package-path Packages/AppleTreeCore
swift test --package-path Packages/AppleTreeUI
xcodebuild -project AppleTree.xcodeproj -scheme AppleTree \
  -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO test
```

Run these from the repository root. The app tests cover cancellation, replacing a scan, error recovery, and visualization completion. You can also run the package schemes or the **AppleTree** scheme in Xcode (⌘U).

`Packages/AppleTreeCore/Sources/ScanBench` is an optional CLI (`swift run scanbench [path]`) for timing scans against real folders. It is not part of the app.

## Size accuracy

The Size column sums each file's allocated blocks (`st_blocks`), with hardlinks counted once. APFS clones have separate inodes and can share physical blocks; AppleTree does not deduplicate those shared extents. Snapshots, filesystem metadata, inaccessible folders, and purgeable space can also make scan totals differ from the volume's Used value. A displayed size is not a promise of how much space deleting an item will free.

## Release builds

See [`docs/releasing.md`](docs/releasing.md) for local packaging, signing requirements, and checks before publication. CI artifacts are unsigned test builds. Pushing a `v*.*.*` tag triggers public distribution; do that only when the release is approved.

## Project structure

```
AppleTree/                 App target (SwiftUI shell, entitlements)
Packages/AppleTreeCore/    Scanning engine, model, categorization, treemap layout — no AppKit/SwiftUI
Packages/AppleTreeUI/      Tree View, Treemap, and Extension Summary as SwiftUI representables
```

## Contributing

See [`CONTRIBUTING.md`](CONTRIBUTING.md). Please open an issue before starting anything larger than a small fix.

## Support and security

Use GitHub Issues for ordinary bugs and feature requests. Please report
security-sensitive problems privately according to [`SECURITY.md`](SECURITY.md).

## License

Copyright © 2026 Fly Media LLC.

AppleTree is free software under the [GNU General Public License v3](LICENSE) or later.

Fly Media LLC is the sole copyright holder and also distributes this software through the Mac App Store under Apple's standard terms. That dual distribution is not a GPL violation: a copyright holder may license its own work on any terms it chooses. The GPLv3 grant remains in force for every copy obtained from this repository.

Contributions must be licensed to Fly Media LLC under terms that permit App Store redistribution — see [`CONTRIBUTING.md`](CONTRIBUTING.md).
