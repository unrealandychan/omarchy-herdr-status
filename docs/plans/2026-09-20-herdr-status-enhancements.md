# Herdr Agent Status Enhancements Implementation Plan

> **Goal:** Enhance `omarchy-herdr-status` with priority-sorted attention queues, keyboard navigation (`PanelKeyCatcher`), multi-session socket discovery, built-in demo mode, desktop card pinning, and marketplace preview assets.
> **Architecture:** Event-driven Rust bridge with multi-session discovery + Quickshell QML component supporting both bar popout and pinned floating overlay.
> **Tech Stack:** Rust (serde, serde_json, unix sockets), Quickshell QML, Hyprland IPC, Omarchy Shell framework.

---

### Task Breakdown

#### Task 1: Priority Attention Queue Sorting & UI Hierarchy
- **Files:** `src/main.rs`, `plugin/HerdrStatus.qml`
- **Changes:**
  - Rust: In `compute_summary` and payload emission, sort `agents` by attention priority:
    1. `blocked` (needs human answer)
    2. `done` (finished unseen work)
    3. `working` (busy executing)
    4. `idle` (ready for prompt)
    5. `unknown`
  - QML:
    - Label `idle` as "ready".
    - Apply distinctive attention tinting: `blocked` gets urgent border/tint, `done` gets soft success green tint, while `working` and `ready` stay subdued.
- **Verification:** Unit tests in Rust for sorting order + visual check.

#### Task 2: Keyboard-First Navigation in Popup (`PanelKeyCatcher`)
- **Files:** `plugin/HerdrStatus.qml`
- **Changes:**
  - Track `selectedIndex` (defaulting to 0, which is the most urgent agent).
  - Add `PanelKeyCatcher` / key handlers:
    - `Up` / `Down` / `k` / `j`: Move selection up/down.
    - `Enter` / `o`: Jump to selected agent's pane (`switchToHerdr`).
    - `Escape`: Close popup.
    - `r`: Force snapshot sync.
  - Highlight selected card visually with accent indicator.
- **Verification:** Test keyboard events and navigation bindings.

#### Task 3: Multi-Session Socket Discovery in Rust Bridge
- **Files:** `src/main.rs`
- **Changes:**
  - Add session discovery function:
    - Check default socket: `~/.config/herdr/herdr.sock`
    - Check named sessions: `~/.config/herdr/sessions/*/herdr.sock`
  - In `AgentInfo`, record `session: String`.
  - Update `herdr-focus` script to accept optional session argument: `herdr --session <name> agent focus <pane>`.
  - Support multiplexed polling across all active sessions.
- **Verification:** Unit test discovering mock sockets, and verify single-session fallback.

#### Task 4: Built-in Demo Mode & Marketplace `preview.png`
- **Files:** `src/main.rs`, `preview.png`
- **Changes:**
  - Add `--demo` flag to `herdr-status-bridge` returning realistic, clean demo agents across multiple states without leaking personal paths.
  - Generate a clean 720px wide `preview.png` at repository root for the Omarchy Marketplace.
- **Verification:** Test `herdr-status-bridge --demo` output and validate preview image format.

#### Task 5: Pinned Floating Desktop Mode (Quickshell Overlay)
- **Files:** `plugin/HerdrStatus.qml`
- **Changes:**
  - Add `pinned` property stored in widget settings (`setting("pinned", false)`).
  - Add pin toggle icon in popup header (`\uF08D` or `󰐃`).
  - When pinned, card detaches from bar and becomes a movable desktop overlay window, tracking position in `shell.json`.
- **Verification:** Validate settings serialization and toggle behavior.

#### Task 6: Deploy, Test, Bump Version & Publish
- **Files:** `Cargo.toml`, `manifest.json`, `README.md`
- **Changes:**
  - Bump version to `0.2.0` / `1.1.0`.
  - Run all unit tests (`cargo test`).
  - Run `./install.sh`.
  - Commit, push to GitHub, update GitHub release, and update Marketplace listing.
