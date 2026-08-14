# Privacy Policy — AppleTree

**The live policy is at <https://apps.flymedia.us/appletree/privacy/>.**

That page is the canonical version and the URL filed with App Store Connect.
This file is a pointer, not a second copy — two copies drift, and the hosted
one is the one that is legally operative.

To change the policy, edit
[`src/pages/appletree/privacy.astro`](https://github.com/flymedia-us/apps/blob/main/src/pages/appletree/privacy.astro)
in the `flymedia-us/apps` repository. Cloudflare Pages deploys on push to
`main`.

## Summary, for readers of this repository

AppleTree is a local disk space analyzer. It creates no accounts, collects no
personal data, has no analytics or crash reporting, and makes no network
connections of any kind. It runs in the macOS App Sandbox and reads only the
folders you point it at. Scan results are held in memory and discarded when the
window closes; the only thing written to disk is a handful of preferences in
standard `UserDefaults`.

The app requests only sandbox access and user-selected read/write access; it
does not request blanket Downloads, Pictures, Music, Movies, or Photos Library
entitlements. Choosing a folder or volume grants access to its hierarchy, but
macOS privacy controls can still restrict nested folders. AppleTree reports
those skips and suggests Full Disk Access only when that permission may help.

See the live policy for the full text, including the sandbox entitlements and
Full Disk Access details.
