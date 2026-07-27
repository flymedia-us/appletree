# Mac App Store submission checklist

Owner tasks for AppleTree **1.0.0** (`com.FlyMedia.AppleTree`). The repo is
prepared for a **GrandPerspective-style** distribution: free builds from
GitHub (GPLv3) plus a small paid Mac App Store listing of the same app.

## Before upload

- [ ] Apple Developer Program membership active (organization: Fly Media LLC)
- [ ] App ID `com.FlyMedia.AppleTree` registered; Mac App Store distribution
      provisioning profile / automatic signing with team `BJZSH247Q9`
- [ ] Final **App Icon** brand art replacing the provisional treemap in
      `AppleTree/Assets.xcassets/AppIcon.appiconset` (all required macOS sizes).
      The current art already uses macOS geometry — an 824pt rounded-rect body
      inset in a 1024pt canvas with a drop shadow, *not* a full-bleed iOS
      square — so keep that inset if you replace it.
- [x] Privacy policy hosted at a public HTTPS URL:
      <https://apps.flymedia.us/appletree/privacy/> (source lives in
      `flymedia-us/apps`; [`privacy-policy.md`](privacy-policy.md) is a pointer)
- [ ] App Store Connect record created; category **Utilities**; price set
      (paid download — no In-App Purchase required for a simple paid app)
- [ ] Review notes mention GPLv3 source availability (e.g. GitHub URL) so
      App Store GPL expectations are clear

## App Store Connect metadata

- [ ] Name, subtitle, description, keywords. The three URL fields are live:
      - Marketing URL — <https://apps.flymedia.us/appletree/>
      - Support URL — <https://apps.flymedia.us/appletree/support/>
      - Privacy Policy URL — <https://apps.flymedia.us/appletree/privacy/>

      All three resolve directly with no redirect hop, which is how they must
      stay — reviewers re-check them on every submission.
- [ ] Age rating questionnaire (utility; no objectionable content expected)
- [ ] Export compliance: already declared in the build settings
      (`ITSAppUsesNonExemptEncryption = NO`), so uploads should no longer stop
      to ask. Verify the answer carried over on the first submission.
- [ ] Mac screenshots (recommended: main window after a scan; empty state;
      Settings) for required display sizes
- [ ] Review notes: explain sandbox + folder picker; optional Full Disk Access
      for `~/Library`; deletion moves to Trash with confirmation by default;
      no network / no account; source under GPLv3 on GitHub

### Review notes — items that need pre-empting

Reviewers reliably ask about these three. Answer them in the submission notes
rather than waiting for a rejection round-trip:

- [ ] **App name.** "AppleTree" uses *apple* as the common noun (the tree), not
      Apple Inc. Apple's trademark guidelines list "Appletree" as an example of
      an unacceptable name, so state the generic usage explicitly, note that the
      icon and branding make no reference to Apple Inc., and that no Apple logo
      or trademark appears in the app. Be prepared for a 5.2.5 challenge.
- [ ] **Photos Library entitlement.** `com.apple.security.personal-information.photos-library`
      is declared but the app links no PhotoKit and reads no photo *content*. It
      is required purely so the sandbox can traverse
      `~/Pictures/Photos Library.photoslibrary` and total its size — for most
      users that bundle is the single largest item in Pictures, so omitting it
      would make a Pictures or whole-disk scan silently under-report. Say this
      plainly; an unexercised privacy entitlement otherwise reads as overreach.
- [ ] **GPLv3 source alongside a paid listing.** Fly Media LLC is the sole
      copyright holder and licenses the same code both ways; contributions are
      gated by a CLA (`CONTRIBUTING.md`) so this stays true. Link the repo.

## Build & submit

- [ ] Archive a **Release** build in Xcode (scheme **AppleTree**)
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
