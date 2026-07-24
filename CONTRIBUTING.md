# Contributing to AppleTree

Thanks for your interest in the project. Bug reports, reproductions, and pull
requests are all welcome.

## Before you start

- **Bugs and features**: open an issue first for anything larger than a small
  fix, so we can agree on the approach before you spend time on it.
- **Scope**: `AppleTreeCore` must stay framework-free (no AppKit, no SwiftUI) so
  the scanning engine and layout algorithm remain unit-testable. All AppKit and
  SwiftUI integration belongs in `AppleTreeUI` or the app target.
- **Tests**: `swift test` must pass in both `Packages/AppleTreeCore` and
  `Packages/AppleTreeUI`. New behavior in either package needs test coverage.
- **Warnings**: the app builds clean under Swift 6 strict concurrency. Please
  keep it that way rather than silencing warnings locally.

## Developer Certificate of Origin and license grant

AppleTree is distributed two ways from one codebase: as GPLv3 source from this
repository, and as a paid binary on the Mac App Store. Apple's distribution
terms are not compatible with the GPL, so this only works while Fly Media LLC
holds the rights to every line of the code. A single contribution that Fly Media
LLC cannot relicense would make continued App Store distribution a license
violation — and force us to either remove the app or revert your work.

To keep both channels open, **by submitting a pull request you agree to the
following**:

1. You certify the contribution is your original work, or that you have the
   right to submit it under these terms (the
   [Developer Certificate of Origin 1.1](https://developercertificate.org/)).
2. You grant Fly Media LLC a perpetual, worldwide, non-exclusive, royalty-free,
   irrevocable license to use, reproduce, modify, publicly display, sublicense,
   and distribute your contribution **under any license terms**, including
   GPLv3 and including proprietary App Store distribution terms.
3. You retain full copyright in your contribution. This is a license grant, not
   an assignment — you may continue to use your own work however you wish.

Add a `Signed-off-by` line to your commits to record this:

```sh
git commit -s -m "your message"
```

If you would rather not grant that license, please open an issue describing the
change instead of a pull request — we can implement it independently.

## Third-party material

Do not commit code, assets, screenshots, or reference copies of other
applications (including competing disk analyzers) to this repository, even for
comparison purposes. Describe the behavior in `docs/` in your own words instead.
