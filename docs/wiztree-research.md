# WizTree Research: Layout, Features & Scanning Technique

Research notes to inform AppleTree's design. Based on the reference screenshot
(`WizTree_REFERENCE/Tree_View.png`), WizTree's own docs/guide, third-party
write-ups, and analysis of the GrandPerspective source already vendored in
this repo.

## 1. UI Layout (from the reference screenshot)

WizTree's main window is a single scan result split into three stacked/side-by-side panes:

1. **Top bar**: drive/folder selector + Scan button, scan summary ("Scan complete
   in 3.95 seconds"), selection summary (Total Space / Space Used / Reserved / Free).
2. **Tree View** (left pane, primary — this is our v1 priority):
   - Columns: **Folder** (name, with expand/collapse disclosure triangle),
     **% of Parent** (a horizontal bar *and* a percentage number in the same
     column — not two separate columns), **Size**, **Allocated** (on-disk size,
     accounts for compression/sparse files), and further off-screen columns
     (Files, Folders, Last Modified — reachable by scrolling).
   - It's a standard hierarchical outline (NSOutlineView equivalent), lazily
     expandable per folder, sorted by Size descending by default.
   - Selecting a row highlights the corresponding rectangle(s) in the treemap.
3. **File View** (tab next to Tree View): a flat list of every file, sortable
   by size/name/date — explicitly **secondary/not a v1 priority** per project goals.
4. **Extension list** (right pane): flat breakdown of all file extensions
   across the whole scan — color swatch, Extension, File Type description,
   Percent, Size, Allocated, Files count. Selecting an extension highlights
   matching regions across the whole treemap (cross-cutting selection, not
   tied to tree position).
5. **Treemap** (bottom, full width): the visual centerpiece.
   - One rectangle per file/folder, area-proportional to size, laid out with a
     grid-like ("squarified"/ordered treemap) algorithm — siblings are grouped
     into columns/rows so large folders read as clean rectangular blocks
     rather than thin slivers.
   - **Text labels are drawn directly on top of boxes** that are large enough
     to hold text (`Users\ (317.7 GB)`), including nested labels for
     sub-folders inside a parent block, indented per level. Boxes too small
     for their label just render as an unlabeled colored cell. This is the
     specific feature the project brief calls out as currently missing.
   - Default coloring is by **top-level branch/subtree** (each major folder
     gets a hue, children are shaded variants), not by extension — extension
     coloring is a separate toggle (Options → Colors → color by extension).
   - Clicking a box in the treemap syncs/scrolls the Tree View selection, and
     vice versa (bidirectional selection sync).

## 2. Interaction & feature surface

- **Filters**: include/exclude patterns, toggled via a filter icon or
  `Ctrl+Shift+F`; can exclude folders from a scan entirely.
- **Context menu** (right-click, both in the tree and on treemap boxes): open
  in Explorer, delete, rename, copy path, properties — i.e. it reuses the OS
  shell context menu on Windows. On macOS the equivalent is "Reveal in
  Finder," "Move to Trash," "Get Info," "Quick Look" (already on this
  project's roadmap).
- **Duplicate finder**: by name/size/modified date only — explicitly *not*
  content-hash based (WizTree warns users to verify before deleting).
- **Export**: CSV export with configurable columns, clipboard copy, and a
  command-line mode that can export a treemap as an image (with options for
  grayscale, dimensions, showing free/allocated space).
- **Color options**: theme (incl. dark mode), color-by-extension vs
  color-by-subtree, colorblind-friendly palette.
- **Sorting**: by name, % of parent, size, allocated size, item count, or
  last-modified date, in both Tree View and File View.

## 3. How WizTree gets its speed (Windows-specific technique)

WizTree's headline trick is **reading the NTFS Master File Table (MFT)
directly** instead of walking the directory tree and stat-ing every file:

- The MFT is a database NTFS already maintains listing every file's metadata
  (name, size, parent record, timestamps). Parsing it sequentially avoids
  per-file syscalls and random I/O entirely — this is why full-volume scans
  complete in seconds even on multi-TB drives.
- This requires **admin/elevated privileges** to open the raw volume handle.
  Without elevation, or on non-NTFS volumes (FAT/exFAT/network shares),
  WizTree silently falls back to slower API-based enumeration.
- **This technique has no direct macOS/APFS equivalent.** APFS's on-disk
  metadata structures aren't a published, stable format the way NTFS's MFT
  is (no public "APFS MFT" to parse), and Apple doesn't expose one via a
  supported API. Spotlight's index (`mdfind`) tracks metadata but not
  reliably up-to-date on-disk sizes for every file, and isn't a general
  substitute. **AppleTree's speed strategy has to come from traversal/syscall
  efficiency and parallelism, not a shortcut that skips traversal.**

## 4. macOS traversal API research

Comparing the realistic options for a from-scratch macOS scanner (findings
from third-party benchmarks, notably blog.tempel.org's directory-read
performance study and the `dumac`/macdirstat projects):

| API | Notes |
|---|---|
| `readdir()` / `opendir()` | Fastest *if* you only need names on APFS — but needs a separate `lstat()` per entry for size, which dominates cost when you actually need sizes. |
| `getattrlistbulk(2)` | Batches "readdir + stat" into one kernel call, returning names + requested attributes (size, type, dates) for many entries per call. Big win over `readdir`+`lstat` pairs when attributes are needed. Used by `macdirstat` (Rust, GPL-3.0, explicit "WinDirStat/WizTree homage for macOS") and other modern scanners. |
| `fts(3)` (`fts_open`/`fts_children`/`fts_read`) | A recursive-traversal wrapper around `readdir`+`lstat`. Benchmarks found **FTS consistently fastest on local HFS+/APFS volumes** even vs `getattrlistbulk`, though `getattrlistbulk` pulls ahead on network volumes (AFP/SMB). |
| `NSFileManager` (`contentsOfDirectoryAtURL:` / `enumeratorAtURL:`) | Roughly matches `getattrlistbulk` performance (it's implemented on top of it) but with Foundation object overhead; convenient but not the fastest path for a hot loop. |

**Key existing-code finding**: `GrandPerspective`'s scanner
([`TreeBuilder.m`](../GrandPerspective-3_7_2/src/tree/TreeBuilder.m)) already
uses `fts_open`/`fts_children` — i.e. it already picked the API that
benchmarks show is fastest for local traversal. However **the scan is
single-threaded**: one FTS walk, no concurrent subdirectory traversal (a
`dispatch_queue` is used only to balance the in-memory tree after the fact,
not to parallelize I/O). On a modern NVMe SSD, which has high queue depth and
services many concurrent I/Os in parallel, this leaves significant
throughput on the table.

**Implication for AppleTree's "improve scanning speed" goal**: the biggest
lever isn't switching syscalls (FTS is already near-optimal for local
volumes), it's **parallelizing traversal across subdirectories** — e.g. a
work-stealing pool of worker threads each running independent `fts`/
`getattrlistbulk` walks over different subtrees, sized to available cores —
which is exactly what `macdirstat` does with Rust's `rayon`, and what the
`dumac` prototype benchmarked (≈6.4x faster than serial `du` on ~400K files).
A `getattrlistbulk`-based bulk fetch may still be worth it *within* each
worker to cut syscall count further, but FTS-per-thread is a defensible
starting point that's a drop-in evolution of the vendored GrandPerspective
scanner rather than a rewrite.

Two macOS-specific gotchas to design around:
- **Full Disk Access**: modern macOS sandboxes protected folders (Mail,
  Messages, Time Machine backups, other users' home dirs); scanning them
  fully requires the user to grant Full Disk Access in System Settings —
  functionally AppleTree's equivalent of WizTree's "run as admin" prompt.
- **APFS clones / hard links**: APFS copy-on-write clones share extents;
  naive size summation can double-count space that isn't actually
  duplicated on disk. WizTree's "Allocated" column and hardlink-aware
  counting (see `macdirstat`'s sharded inode-tracking dedup) are the pattern
  to follow — track visited inodes/extent ownership to avoid over-reporting.

## 5. Prior art: three more macOS clones, one is a strong base candidate

There are at least **three** independent "WinDirStat/WizTree for Mac" projects
on GitHub beyond GrandPerspective. Their licenses vary a lot, which matters
because it determines whether we can literally build on their code
(as this repo already does by vendoring GrandPerspective) vs. use them only
as a design/behavior reference:

| Project | Lang / Stack | License | Stars | Last push | Visualization | Notes |
|---|---|---|---|---|---|---|
| [`phalladar/MacDirStat`](https://github.com/phalladar/MacDirStat) | **Swift 6 + SwiftUI**, zero deps, SPM | **MIT** | 33 | 2026-02-16 | Squarify treemap + tree sidebar | Closest to our target stack *and* license. |
| [`MichaelStromberg/macdirstat`](https://github.com/michaelstromberg/macdirstat) | Rust + rayon | GPL-3.0 | 10 | 2026-03-08 | Squarified treemap (cushion-shaded) + tree list | Wrong language for our stack; copyleft. |
| [`Ti-03/MacDirStat`](https://github.com/Ti-03/MacDirStat) | Swift + SwiftUI, POSIX `opendir`/`fstatat` | **AGPL-3.0** | 159 | 2026-06-29 | **Sunburst** (rings) + sortable tree panel, SHA-256 duplicate finder | Most popular/active of the three, but sunburst-first (not WizTree's treemap layout) and AGPL is the most restrictive license of the group. Good competitive reference only. |
| [`AlexGladkov/Spacie`](https://github.com/AlexGladkov/Spacie) | Swift 6 + SwiftUI | **NOASSERTION** (no usable license) | 82 | 2026-06-05 | Sunburst/treemap + duplicate finder | Feature reference only — no license means no legal right to reuse code. |

### `phalladar/MacDirStat` is worth treating as a serious alternative starting point

This one stands out: **MIT-licensed**, Swift 6 (strict concurrency) +
SwiftUI, zero external dependencies, and its architecture already
implements several things this project's research independently concluded
were the right approach:

- **Scanner** (`Sources/MacDirStat/Scanning/FileScanner.swift`): BSD `fts`
  traversal, but unlike GrandPerspective **it already parallelizes across
  subdirectories** with `withTaskGroup` (falls back to sequential for
  single-child dirs to skip TaskGroup overhead). Streams results via
  `AsyncStream<ScanEvent>` (progress every 10k files, throttled 50ms UI
  updates). Handles hardlink/APFS-clone dedup via inode tracking
  (`OSAllocatedUnfairLock`-protected `seenInodes` set), skips already-visited
  directory inodes (cycles/firmlinks), stays on one device
  (`st_dev` check), and doesn't follow symlinks (`AT_SYMLINK_NOFOLLOW`).
  This is essentially the parallel-FTS design this doc's section 4 already
  recommended, already written and MIT-licensed.
- **Treemap** (`Treemap/TreemapLayout.swift` + `TreemapRenderer.swift`):
  Squarify algorithm (max depth 8), rendered on `Canvas` (not per-rect
  SwiftUI views, for performance), colors darkened by depth. **It already
  draws on-box text labels** — a name label gated at `width > 60 && height >
  16`, a separate size label gated at `width > 80 && height > 32`, both
  suppressed during active zoom/pan for performance. This is the one gap
  GrandPerspective had that WizTree needs, and it's already solved here.
- **Tree pane** (`Views/DirectoryTreeView.swift`): `List` + `OutlineGroup`
  sidebar showing name + size per row, bidirectionally bound to treemap
  selection via a custom `Binding` that resolves node-by-id. It's real but
  thinner than WizTree's target — **no "% of Parent" bar/column, no
  Allocated/Files/Folders columns, no sort-by-column** yet. That gap is
  exactly this project's Tree View roadmap item.
- **State**: single `@Observable AppState` (modern Swift concurrency
  patterns, not Cocoa notifications/KVO like GrandPerspective).
- Ships with its own `CLAUDE.md`, i.e. it was itself built with Claude Code
  — useful precedent for how this project's own tooling might approach it.

**License comparison that matters for the "lightweight, modern, native"
goal**: GrandPerspective is GPL-2-or-later Objective-C/Cocoa (legacy AppKit
patterns, copyleft). `phalladar/MacDirStat` is MIT Swift 6/SwiftUI with
zero dependencies — both a better license (permissive, no copyleft
obligations) and a much closer starting stack to what we actually want to
ship. If we lean on it the way GrandPerspective is currently vendored, MIT
means we can freely copy/modify/relicense; GPL/AGPL sources (GrandPerspective,
both `macdirstat` variants) can only inform *design*, not be copied from
directly, without pulling the whole project under GPL/AGPL.

## 6. Foundation options: what's reusable from each candidate

### GrandPerspective (currently vendored, GPL-2+, Objective-C/Cocoa)

- [`TreeLayoutBuilder.m`](../GrandPerspective-3_7_2/src/tree/TreeLayoutBuilder.m):
  a recursive binary-split layout (largest child carved off first, alternating
  split axis by aspect ratio) — the "ordered/cushion treemap" family, the
  same lineage as WinDirStat/SequoiaView, visually equivalent to WizTree's
  clean rectangular blocks. Sound algorithm, but it's 20-year-old
  Objective-C/Cocoa `NSView` drawing code — re-hosting it into SwiftUI/Metal
  is a port, not a drop-in, and it drags GPL-2+ copyleft along with it.
- [`TreeDrawer.m`](../GrandPerspective-3_7_2/src/view/TreeDrawer.m): flat/
  gradient rectangle fills only — **zero text drawing anywhere** (confirmed
  by inspection). No text-label feature to lean on here at all.
- **No Tree View equivalent** — GrandPerspective is treemap-only,
  single-pane. Would be fully new UI work.
- Net assessment: sound layout *theory*, but the actual code is the
  least aligned of the candidates with the "lightweight, modern,
  made-for-Mac" goal — old language, old UI framework, most restrictive
  common license of the group besides AGPL.

### `phalladar/MacDirStat` (MIT, Swift 6/SwiftUI) — closest match to our target stack

As detailed in section 5: parallel-`fts` scanner with hardlink/clone dedup
already written, Squarify treemap already rendered on `Canvas` with on-box
text labels already implemented (name + size, size-gated), and a working
(if basic) `OutlineGroup`-based tree sidebar already synced to treemap
selection. Its MIT license means we can copy and modify it directly, the
way GrandPerspective is currently vendored, without copyleft
consequences. The main gap vs. our goal is the Tree View's column depth
(no % of Parent, Allocated, Files/Folders columns/sort yet) — which is
exactly the feature this project wants to lead with, so it's additive work
on a modern base rather than a green-field build.

### `Ti-03/MacDirStat` and `AlexGladkov/Spacie` — reference only

Both are useful for competitive/feature-parity checks (duplicate finder,
file categorization, sunburst as an alternate visualization) but not viable
as code sources: `Ti-03` is AGPL-3.0 (the strongest copyleft of any
candidate — would obligate open-sourcing the whole app, including over a
network), and `Spacie` has no asserted license (default copyright — no
legal right to copy).

## 7. Decision: `phalladar/MacDirStat` is reference-only, not vendored

Given the "lightweight, modern, made-for-Mac" direction, `phalladar/MacDirStat`
is a materially better starting point than GrandPerspective on every axis
that matters here (language, UI framework, dependency count, license
permissiveness, *and* it already has parallel scanning + labeled treemap
boxes — the two hardest items on our roadmap). Three ways to use it were
weighed — vendor it in fully (like `GrandPerspective-3_7_2/` is handled
today), vendor just its `Scanning/` module, or treat it as a design
reference only and write fresh Swift throughout.

**Decision (2026-07-03): reference only.** AppleTree's scanner, treemap, and
Tree View will be written from scratch, informed by `phalladar/MacDirStat`'s
documented techniques (TaskGroup-per-subdirectory traversal, inode-based
hardlink/clone dedup, `Canvas`-based size-gated label rendering) and by
GrandPerspective's treemap layout math, but without importing code from
either. This keeps AppleTree's license posture clean (no inherited
obligations from any reference project) and lets the implementation match
WizTree's specific column/label layout exactly rather than adapting someone
else's UI. `GrandPerspective-3_7_2/` remains vendored in the repo per the
existing README (its code may still be *read* for the layout algorithm,
per GPL's allowance of studying/reimplementing ideas — just not copied).

## 8. Recommendations mapped to project goals

1. **Tree View (priority)**: whichever foundation we pick, extend/replace
   the tree pane to add Folder / % of Parent (bar + number) / Size columns
   first, Allocated / Files / Folders as fast-follows, sorted by column,
   synced bidirectionally with the treemap — matching WizTree's UX. If we
   vendor `phalladar/MacDirStat`, this builds directly on its existing
   `DirectoryTreeView.swift` rather than starting from zero.
2. **Treemap text labels (priority)**: `phalladar/MacDirStat`'s
   `TreemapRenderer.swift` already solves this (size-gated name/size
   labels on `Canvas`) — if we lean on that codebase, this roadmap item is
   largely done and just needs WizTree-specific tuning (nested sub-folder
   labels, indentation style). If we instead port GrandPerspective's layout
   algorithm, this remains net-new work as previously noted.
3. **Scanning speed**: `phalladar/MacDirStat`'s `FileScanner.swift` already
   implements the parallel-FTS-per-subdirectory design this doc's section 4
   independently recommended, plus hardlink/APFS-clone dedup and
   cross-device/symlink safety — a strong candidate to adopt largely as-is
   and refine (e.g. evaluate `getattrlistbulk` as a further optimization)
   rather than reimplement. Still need to plan for Full Disk Access
   onboarding, which none of the three clones document explicitly.
4. **File View**: confirmed secondary across every reference product —
   safe to defer regardless of foundation choice.
5. **Treemap coloring**: color boxes **by file type/extension** (like
   WizTree's default treemap coloring and its extension breakdown pane),
   not by subtree/branch. Files with no extension get their own explicit
   bucket/color — WizTree's own extension list treats `(No Extension)` as
   a first-class category (it's the single largest slice in the reference
   screenshot, 32.2%), so the category model must not silently drop or
   mis-bucket extensionless files. This maps to a `FileCategory`-style
   extension→color mapping (`phalladar/MacDirStat`'s 200+-entry
   `FileExtensionMap` is a useful *design* reference for the category set,
   per the reference-only decision in section 7).

## 9. Stack directive: modern Swift/macOS only

Per explicit project direction: target the **most modern Swift and macOS
APIs available**, not backward-compatible/legacy patterns. Concretely:
Swift 6 language mode with strict concurrency, SwiftUI-first UI (Cocoa/
AppKit only where SwiftUI genuinely can't deliver the needed performance,
e.g. a virtualized outline for very large trees), `@Observable` over
Combine/KVO, structured concurrency (`async`/`await`, `TaskGroup`) over
`DispatchQueue`/callbacks, and a deployment target set to the current/
latest macOS rather than chasing broad backward compatibility.
