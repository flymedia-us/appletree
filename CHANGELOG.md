# Changelog

## 1.1.0 — 2026-10-15

- Recognize native Trash locations and empty only the current user's contents
  when selecting a shared Trash container.
- Add an opt-in permanent deletion setting. Irreversible deletion always asks
  for confirmation, with Cancel as the default keyboard action.
- Show deletion failures and reflect successful removals after partially
  emptying Trash. Refuse symlinked Trash containers and duplicate requests.
- Keep deletion unavailable while a scan is building the tree.
- Fix cancellation before the first scan event leaving the app stuck scanning,
  and ignore state updates from scans that have been replaced.
- Normalize root path separators so deletion results and external changes can
  resolve nodes selected through a folder picker or volume-root scan.
- Add app lifecycle and deletion safety regression tests, including real
  disposable APFS volume coverage, and run app tests and universal builds in CI.
- Clarify size-accounting limits: shared APFS clone extents are not deduplicated.
