#  Apple Tree

An upcoming high-speed disk space analyzer for macOS, inspired by the speed of **WizTree** on Windows and built with references to **GrandPerspective**.

---

## 👁️ Project Vision

**Apple Tree** aims to solve a common pain point for macOS users: scanning large drives for disk space usage is often slow and resource-intensive. 

On Windows, **WizTree** achieves near-instantaneous scans by reading the Master File Table (MFT) directly from NTFS drives, bypassing slow operating system APIs. 

**Apple Tree**'s mission is to bring that class of performance to macOS by:
1. **Low-Level APFS Scanning**: Leveraging fast, low-level macOS file system interfaces (such as `getattrlistbulk(2)`, `getdirentries`, and multi-threaded traversal) to query Apple File System (APFS) metadata as rapidly as possible.
2. **Interactive Treemap Visualization**: Providing a gorgeous, interactive treemap representation of disk usage, allowing users to immediately spot and manage large files and directories.
3. **Modern macOS Experience**: Featuring a native SwiftUI interface designed for modern macOS, complete with a clean dark mode, responsive layouts, smooth animations, and intuitive controls.

---

## 📂 Current Repository Structure

The project is currently in the **research and planning phase**. 

* **[GrandPerspective-3_7_2](GrandPerspective-3_7_2)**: A copy of the source code for GrandPerspective (v3.7.2), a mature, GPL-licensed disk usage visualizer for macOS. We are keeping this in the repository as a key reference for:
  - Treemap layout algorithms (e.g., squarified treemaps).
  - Legacy Cocoa file system interaction patterns.
  - Scan result caching and filtering logic.

---

## 🛠️ Proposed Tech Stack

* **Language**: Swift (for UI and safety) coupled with C/Objective-C where low-level system call wrappers are required.
* **UI Framework**: SwiftUI (targeting modern macOS versions) for a sleek, responsive, and native aesthetic.
* **Scan Engine**: Multi-threaded scanner optimized for SSDs and APFS container structures.
* **Render Pipeline**: Metal or Core Graphics for fluid, 60fps zooming and panning across millions of files in the treemap.

---

## 🗺️ Roadmap & Next Steps

- [ ] **APFS Performance Benchmarking**: Prototype different scanning methods (`NSFileManager`, C-level `fts`, and `getattrlistbulk`) to identify the fastest scanning path on modern Apple Silicon and APFS.
- [ ] **Core Scanner Architecture**: Build a high-performance, cancellable, and thread-safe scanning engine that builds a lightweight in-memory tree of the file system.
- [ ] **Modern UI Design**: Design a sleek, premium dark-mode interface in SwiftUI, featuring a visual breakdown bar and searchable file lists.
- [ ] **Treemap Port/Modernization**: Adapt and optimize the tree-mapping drawing algorithm from GrandPerspective to render cleanly in modern SwiftUI/Metal views.
- [ ] **File Operations**: Add support for quick actions (Reveal in Finder, Quick Look, Move to Trash).

---

## 📄 License

As this project references GrandPerspective, any derivative work or components leveraging GPL-licensed code from GrandPerspective will comply with the **GNU General Public License**. See [GrandPerspective COPYING.txt](GrandPerspective-3_7_2/COPYING.txt) for details.
