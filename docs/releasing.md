# Releasing AppleTree

Publishing source changes or a pull request does not publish an app. The
Release workflow publishes a signed, notarized DMG when a `v*.*.*` tag is pushed.
Do not create a release tag until the release has been approved.

## Before publication

- Run both package suites and the app lifecycle tests documented in README.md.
- Build Release for both `arm64` and `x86_64`. Test launch and core workflows
  on the oldest supported macOS version and on a current stable macOS version.
  Cross-compiling Intel is useful, but does not replace an Intel runtime check.
- Exercise scanning, cancellation, replacing a scan, sorting, selection sync,
  Quick Look, external deletion, and deletion error handling. Use disposable
  folders and disk images for deletion tests, never real user data.
- Verify ordinary deletion is recoverable by default. Permanent deletion and
  emptying Trash must always ask, with Cancel as the default keyboard action.
- Confirm the live privacy policy and store listing describe the actual
  entitlements and deletion behavior. AppleTree currently requests only App
  Sandbox and user-selected read/write access. It has no blanket media-folder
  or Photos Library entitlement. No scan data is sent over the network.
- Update `MARKETING_VERSION` and `CURRENT_PROJECT_VERSION` in `project.yml`,
  then run `xcodegen generate`. Do not reuse a published version/build pair.
- Review the public source diff, license, dependency changes, CI results, and
  security alerts. Confirm the release tag points at the tested commit.

## Local packaging without publication

To exercise the universal build and DMG layout without signing, notarization,
or uploading anything:

```sh
SKIP_NOTARIZE=1 OUTPUT_DIR=/tmp/appletree-package-check scripts/package-release.sh
```

The resulting DMG is a test artifact and must not be distributed. Normal
packaging requires a Fly Media LLC Developer ID Application identity, verified
with `security find-identity -v -p codesigning`. The script prefers fingerprint
`120D2200993750D65F7CC0BC117EDE47DEA94AEC`, with a same-team fallback for a
renewed certificate. App Store signing is a separate distribution path.

For signed local packaging, provide these environment variables:

- `APP_STORE_CONNECT_KEY_ID`
- `APP_STORE_CONNECT_ISSUER_ID`
- `APP_STORE_CONNECT_API_KEY_PATH` (path to the `.p8` key), or
  `APP_STORE_CONNECT_API_KEY` (the key contents)

Run `scripts/package-release.sh`. It embeds the license, signs the app with
hardened runtime and sandbox entitlements, notarizes and staples the app,
packages the DMG, then notarizes and staples the DMG. Packaging itself does not
publish a GitHub Release. Keep credentials out of the repository and logs.

Verify the actual final artifact, including after copying it from the DMG:

```sh
codesign --verify --deep --strict --verbose=2 /path/to/AppleTree.app
xcrun stapler validate /path/to/AppleTree.app
spctl --assess --type execute --verbose=2 /path/to/AppleTree.app
xcrun stapler validate /path/to/AppleTree.dmg
```

If signing or notarization credentials are unavailable, those checks remain
outstanding; a successful unsigned build is not distribution approval.

## GitHub release workflow

Repository secrets required by `.github/workflows/release.yml`:

- `DEVELOPER_ID_P12_BASE64`
- `DEVELOPER_ID_P12_PASSWORD`
- `APP_STORE_CONNECT_KEY_ID`
- `APP_STORE_CONNECT_ISSUER_ID`
- `APP_STORE_CONNECT_API_KEY`

The certificate must belong to Fly Media LLC (`BJZSH247Q9`). A manual workflow
dispatch builds a signed, notarized artifact without publishing a release;
a version-tag push also publishes the release. Use the latter only after
approval. No App Store upload or submission is performed by this workflow.

## App Store preparation

The separate **App Store preparation** workflow uses the existing App Store
Connect API secrets to inspect metadata, screenshots, builds, and available
distribution certificates. It can only run from main. Its initial snapshot
does not submit a version for review or change the live listing.

`docs/app-store-listing.json` contains the 1.1.0 listing draft and name variants,
all within Apple's 30-character name limit. Preserve the existing screenshots,
pricing, availability, age rating, and review contact unless a release requires
a specific change. Keep the version on manual release and stop before final
review submission when the maintainer is still evaluating listing names.
