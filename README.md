# AppleTree

A high-speed disk space analyzer for macOS, inspired by the speed of **WizTree** on Windows and the visualization style of **GrandPerspective**.

AppleTree scans a folder or whole volume with a parallel, native `fts(3)`-based traversal and shows the result three ways at once — an expandable size-sorted outline, a flat breakdown by file extension, and an interactive treemap — all kept in sync with each other as you select, hover, and delete.

---

## Status

**1.0.0** — available on the [Mac App Store](https://apps.apple.com/us/app/appletree-scan/id6796500800?mt=12) (listed as **AppleTree Scan**) and as public source on GitHub.

**Distribution** (same app either way, GrandPerspective-style):

- **Free** — download a drag-and-drop DMG from [GitHub Releases](https://github.com/flymedia-us/appletree/releases), or build from this repository
- **Mac App Store** — small paid download for convenience, automatic updates, and to support development

Source is licensed under the **GNU General Public License v3**. See [Known limitations](#known-limitations) for what is not finished yet.

Product site, support, and the privacy policy live at
[apps.flymedia.us/appletree](https://apps.flymedia.us/appletree/).

## Features

- **Fast parallel scanning** — a worker-pool `fts(3)` traversal (see [`DirectoryScanner`](Packages/AppleTreeCore/Sources/AppleTreeCore/Scanning/DirectoryScanner.swift)) that stays on one device, dedups hardlinks/APFS clones and firmlink-joined directories (e.g. `/Users` vs. `/System/Volumes/Data/Users`), and streams incremental progress rather than blocking until the whole tree is walked.
- **Tree View** — an `NSOutlineView`-backed, sortable outline (Folder, % of Parent, Size, Logical Size, Files, Folders, Modified), matching WizTree's default size-descending order.
- **Treemap** — a labeled, ordered treemap colored by file type, with hover tooltips and click-to-select synced against the Tree View.
- **Extension Summary** — a flat, whole-scan breakdown by file extension (color, type name, percent, size, file count).
- **Delete to Trash** — from either the Tree View's context menu or ⌘⌫, with a confirmation alert (toggleable in Settings), immediate struck-through row, and recomputed parent/treemap/extension totals (no rescan needed).
- **Quick Look** — Space bar to preview the selected file, Finder-style.
- **Live external-change detection** — an `FSEventStream` watch flags files deleted or moved out from under a completed scan by Finder, Terminal, or any other process.
- **Privacy-aware disk access** — the app uses only the App Sandbox and user-selected read/write entitlements. A chosen folder or volume grants recursive sandbox access; macOS may still protect folders such as Desktop, Documents, Downloads, media folders, Mail, and Messages.
- **Full Disk Access awareness** — scans classify *why* a folder was skipped (privacy-protected, root-owned/system-protected, plain permission-denied, or other) and nudge for Full Disk Access only when it would actually help. The folder-specific Downloads, Pictures, Music, and Movies entitlements are intentionally not requested.
- **Volume capacity readout** — Total/Used/Reserved/Free for the scanned volume, independent of the scan's own tree total.
- **Settings** — theme (System / Light / Dark), confirm-before-delete, and Full Disk Access nudge preferences (⌘,).
- **Open Folder** — File → Open Folder… (⌘O), toolbar button, or drag a folder onto the window.

## Known limitations

- **English-only UI** — no localization yet.
- **No Sparkle updater** — GitHub DMGs are a manual install; Mac App Store builds update through the store.

## Project structure

```
AppleTree/                    App target (SwiftUI shell, AppState, entitlements, PrivacyInfo.xcprivacy)
Packages/AppleTreeCore/       Scanning engine, FileNode model, categorization, treemap layout — no UI/framework dependencies
Packages/AppleTreeUI/         AppKit-backed views (Tree View, Treemap, Extension Summary) as SwiftUI NSViewRepresentables
packaging/                    Developer ID export options and DMG window artwork
scripts/                      DMG and GitHub-release packaging
docs/                         Privacy policy pointer, design research notes
```

`AppleTreeCore` is deliberately framework-free (no AppKit/SwiftUI) so the scanning engine and layout algorithm stay unit-testable and reusable; `AppleTreeUI` is where all the AppKit/SwiftUI integration lives.

## Building

Requires Xcode 26+ (Swift 6.2 toolchain) to build; the app itself targets macOS 15+ at runtime.

```sh
open AppleTree.xcodeproj
```

Build and run the **AppleTree** scheme. The project file is checked in and buildable as-is; [`project.yml`](project.yml) exists only so the project can be regenerated with [XcodeGen](https://github.com/yonaskolb/XcodeGen) after adding/removing files (`xcodegen generate`).

When scanning a home folder or whole volume, macOS may separately ask for
Desktop, Documents, or Downloads access. If other privacy-protected folders are
skipped, AppleTree offers a link to Full Disk Access and requires a rescan after
permission is granted. Selecting an individual folder directly normally grants
access without Full Disk Access.

## Testing

Each Swift package has its own test suite:

```sh
cd Packages/AppleTreeCore && swift test
cd Packages/AppleTreeUI && swift test
```

or run them from Xcode with the `AppleTreeCore`/`AppleTreeUI` schemes (⌘U).

CI runs the same package tests on push/PR via [`.github/workflows/ci.yml`](.github/workflows/ci.yml), and also packages an unsigned DMG as a layout smoke test. That artifact is not notarized and must not be shipped.

`Packages/AppleTreeCore/Sources/ScanBench` is a small CLI benchmarking harness (`swift run scanbench [path]`) for manually timing/verifying the scanner against real folders — not part of the shipping app, not covered by tests.

## Direct download (GitHub Releases)

Pushing a version tag (`v1.0.0`, matching `MARKETING_VERSION` in [`project.yml`](project.yml)) runs [`.github/workflows/release.yml`](.github/workflows/release.yml). That job archives a universal (`arm64` + `x86_64`) Release build, signs it with **Developer ID Application**, notarizes the app, wraps it in a drag-to-Applications DMG, notarizes the DMG, and attaches `AppleTree-<version>.dmg` plus a stable `AppleTree.dmg` to the GitHub Release.

The Mac App Store binary cannot be reused here — Gatekeeper will not launch an App Store signature outside the store.

### Secrets the repo needs (once)

Create these on [github.com/flymedia-us/appletree/settings/secrets/actions](https://github.com/flymedia-us/appletree/settings/secrets/actions):

| Secret | What it is |
|---|---|
| `DEVELOPER_ID_P12_BASE64` | Developer ID Application certificate, exported from Keychain as a `.p12` and base64-encoded (`base64 -i DeveloperID.p12`) |
| `DEVELOPER_ID_P12_PASSWORD` | Password you set on that `.p12` |
| `APP_STORE_CONNECT_API_KEY` | Full contents of the App Store Connect API `.p8` file |
| `APP_STORE_CONNECT_KEY_ID` | Key ID shown next to that API key |
| `APP_STORE_CONNECT_ISSUER_ID` | Issuer ID on the App Store Connect API keys page |

How to mint them, if they do not exist yet:

1. [Apple Developer → Certificates](https://developer.apple.com/account/resources/certificates/list) → **Developer ID Application** for team `BJZSH247Q9`. Export it from Keychain Access as `.p12`. This is a different certificate from the Apple Development identity used for local runs and from the Apple Distribution identity used for the App Store.
2. [App Store Connect → Integrations → Team API keys](https://appstoreconnect.apple.com/access/integrations/api) → generate a key with **Developer** or **App Manager** access. Download the `.p8` immediately (Apple only shows it once) and copy the Key ID and Issuer ID.

The app stays sandboxed. A sandboxed Developer ID build needs a Developer ID provisioning profile; the release job asks Xcode to create or refresh that profile via `-allowProvisioningUpdates` and the API key.

### Publishing a version

After the secrets are in place and this workflow is on `main`:

```sh
git tag v1.0.0
git push origin v1.0.0
```

To rebuild the DMG locally (same script the workflow runs):

```sh
export APP_STORE_CONNECT_KEY_ID=...
export APP_STORE_CONNECT_ISSUER_ID=...
export APP_STORE_CONNECT_API_KEY_PATH=/path/to/AuthKey_XXXX.p8
scripts/package-release.sh
```

`SKIP_NOTARIZE=1` skips notarytool for layout checks only — do not ship that DMG.

Regenerate the DMG window artwork with `packaging/dmg/render-background.swift` if you change the icon layout in `packaging/dmg/settings.py`.

## License

Copyright © 2026 Fly Media LLC.

AppleTree is free software: you can redistribute it and/or modify it under the terms of the [GNU General Public License](LICENSE) as published by the Free Software Foundation, either version 3 of the License, or (at your option) any later version.

This program is distributed in the hope that it will be useful, but WITHOUT ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the GNU General Public License for more details.

You should have received a copy of the GNU General Public License along with this program (see [`LICENSE`](LICENSE)). If not, see <https://www.gnu.org/licenses/>.

### Mac App Store distribution

Fly Media LLC is the sole copyright holder of AppleTree and therefore also
distributes this same software through the Mac App Store under Apple's standard
licensing terms. That dual distribution is not a GPL violation: a copyright
holder may license its own work on any terms it chooses, and the GPLv3 grant
above remains in force for every copy obtained from this repository.

The App Store binary is offered as a paid convenience (automatic updates and
support for development). The source here is, and will remain, free software —
you may always build it yourself at no cost.

To keep this arrangement intact, contributions must be licensed to Fly Media LLC
under terms that permit App Store redistribution. See
[`CONTRIBUTING.md`](CONTRIBUTING.md) before opening a pull request.
