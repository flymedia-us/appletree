# Mac App Store submission checklist

Owner tasks for Apple Tree **1.0.0** (`com.FlyMedia.AppleTree`). The repo is
prepared for a **GrandPerspective-style** distribution: free builds from
GitHub (GPLv3) plus a small paid Mac App Store listing of the same app.

## Before upload

- [ ] Apple Developer Program membership active (organization: Fly Media LLC)
- [ ] App ID `com.FlyMedia.AppleTree` registered; Mac App Store distribution
      provisioning profile / automatic signing with team `BJZSH247Q9`
- [ ] Final **App Icon** art replacing the placeholder in
      `AppleTree/Assets.xcassets/AppIcon.appiconset` (all required macOS sizes)
- [ ] Privacy policy hosted at a public HTTPS URL (draft:
      [`privacy-policy.md`](privacy-policy.md))
- [ ] App Store Connect record created; category **Utilities**; price set
      (paid download — no In-App Purchase required for a simple paid app)
- [ ] Review notes mention GPLv3 source availability (e.g. GitHub URL) so
      App Store GPL expectations are clear

## App Store Connect metadata

- [ ] Name, subtitle, description, keywords, support URL, marketing URL
- [ ] Privacy policy URL
- [ ] Age rating questionnaire (utility; no objectionable content expected)
- [ ] Export compliance: uses only standard OS encryption (HTTPS not used by
      the app today — answer accordingly)
- [ ] Mac screenshots (recommended: main window after a scan; empty state;
      Settings) for required display sizes
- [ ] Review notes: explain sandbox + folder picker; optional Full Disk Access
      for `~/Library`; deletion moves to Trash with confirmation by default;
      no network / no account; source under GPLv3 on GitHub

## Build & submit

- [ ] Archive a **Release** build in Xcode (scheme **Apple Tree**)
- [ ] Validate and upload to App Store Connect
- [ ] Submit for review

## After approval

- [ ] Confirm GitHub repo is public with `LICENSE` (GNU GPLv3)
- [ ] Publish free release binaries (optional but matches the dual-channel model)
- [ ] Point README Status at the live App Store link
- [ ] Keep `MARKETING_VERSION` / `CURRENT_PROJECT_VERSION` in sync for updates
      (App Store handles customer updates — no Sparkle needed for MAS builds)

## Explicitly out of scope for 1.0

- Sparkle / direct-download updater (optional later for non-MAS free builds)
- Localization beyond English
- Flat File View, filters, duplicate finder, CSV/image export
