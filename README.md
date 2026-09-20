# omarchy-herdr-status

> Real-time status indicator on the Omarchy navigation bar for [Herdr](https://herdr.dev) AI coding agents, engineered in Rust for ultra-low CPU and RAM footprint.

![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)
![Language: Rust](https://img.shields.io/badge/Language-Rust%20%2F%20QML-orange.svg)
![Platform: Linux / Omarchy](https://img.shields.io/badge/Platform-Linux%20%2F%20Omarchy-blue.svg)

---

## Overview

When orchestrating multiple AI coding agents across Herdr workspaces and panes (such as `pi`, `claude`, `codex`, `gemini`, or subagent swarms), you need to know their state at a glance without having to switch terminal windows:
- Is an agent **working**?
- Is an agent **blocked** awaiting human confirmation or a permission prompt?
- Has a background turn **finished** (`done`)?

This project provides an event-driven status bar plugin for **Omarchy Linux** (Quickshell). It monitors Herdr's live agent multiplexer via UNIX domain socket and visualizes current agent activity directly on the desktop panel.

---

## Performance & Resource Consumption

Status bar widgets that invoke external CLI processes on a timer can cause continuous CPU wakeups and memory churn. **omarchy-herdr-status** was designed from the ground up for minimal resource usage:

| Metric | Measured Value |
|---|---|
| **CPU Usage** | **0.00%** (blocks directly in Linux kernel `epoll`/`read`) |
| **RAM Footprint (RSS)** | **~2.1 MB** (Rust native binary, no GC, no runtime) |
| **Event Latency** | **< 1 ms** (real-time push over `herdr.sock`) |
| **I/O** | Zero disk writes |

---

## Features

- **Live Agent Status Visualization**:
  - `󱑎 <N> working`: Active turns and tool execution.
  - `󰅚 <N> blocked`: Urgent indicator when an agent is stopped at an approval or input prompt.
  - `󰄬 <N> done`: Turn completed and ready for review.
  - `󰌒 <N> ready`: Idle agents awaiting instructions.
  - `󰚩 off`: Herdr offline or disconnected.
- **Multi-Agent & Subagent Support**: Automatically aggregates and tracks all active agents across workspaces, tabs, and split panes.
- **Interactive Controls**:
  - **Left-Click**: Toggles a rich summary popup card listing every live agent, their status badges, pane handles, and working directories. Clicking an individual agent row immediately focuses that agent!
  - **Right-Click**: Instantly jumps to the Herdr terminal screen and brings the active window into focus.
- **Detailed Hover Preview**: Hovering over the widget displays a clean, multi-line status breakdown without opening the full panel.

---

## Project Structure

```
omarchy-herdr-status/
├── Cargo.toml               # Cargo package configuration
├── src/
│   └── main.rs              # Rust UNIX-socket event-streaming bridge
├── plugin/
│   ├── manifest.json        # Omarchy shell plugin manifest
│   └── HerdrStatus.qml      # Quickshell BarWidget component
├── scripts/
│   └── bridge.py            # Optional zero-dependency Python fallback
├── install.sh               # One-click build and installation script
├── LICENSE                  # MIT License
└── README.md
```

---

## Installation

### Prerequisites
- Omarchy Linux with Hyprland and Quickshell
- Rust & Cargo (`rustc >= 1.70`)
- Herdr (`herdr >= 0.8.0`)

### One-Command Setup
Clone the repository and run the installer:

```bash
git clone https://github.com/unrealandychan/omarchy-herdr-status.git
cd omarchy-herdr-status
chmod +x install.sh
./install.sh
```

The installer will:
1. Compile the optimized release binary (`herdr-status-bridge`).
2. Copy it to `~/.local/bin/`.
3. Link the plugin into `~/.config/omarchy/plugins/arch.herdr-status`.
4. Register the widget in `~/.config/omarchy/shell.json`.
5. Trigger an Omarchy shell plugin reload.

---

## Removal & Uninstallation

To completely remove Herdr Agent Status:

```bash
chmod +x uninstall.sh
./uninstall.sh
```

Or manually remove the installed artifacts:

```bash
# 1. Remove binaries
rm -f ~/.local/bin/herdr-status-bridge ~/.local/bin/herdr-focus

# 2. Remove Quickshell plugin link
rm -rf ~/.config/omarchy/plugins/arch.herdr-status

# 3. Remove "arch.herdr-status" from ~/.config/omarchy/shell.json and rescan
omarchy-shell shell rescanPlugins
```

---

## Standalone Usage

The Rust bridge binary can also be used independently from the command line:

```bash
# Print a single JSON snapshot of all live agents and exit
herdr-status-bridge --once

# Stream real-time status updates as newline-delimited JSON
herdr-status-bridge
```

Example JSON output:
```json
{
  "connected": true,
  "agents": [
    {
      "name": "pi",
      "status": "working",
      "pane_id": "wD:p3",
      "workspace_id": "wD",
      "tab_id": "wD:t1",
      "title": "π - arch",
      "cwd": "/home/arch",
      "focused": true,
      "source": "herdr"
    }
  ],
  "summary": {
    "total": 1,
    "working": 1,
    "blocked": 0,
    "done": 0,
    "idle": 0,
    "unknown": 0,
    "primary_status": "working",
    "badge_text": "󱑎 1 working",
    "badge_icon": "󱑎",
    "status_color": "accent"
  }
}
```

---

## License

This project is licensed under the [MIT License](LICENSE).
