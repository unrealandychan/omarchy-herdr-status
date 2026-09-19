#!/usr/bin/env python3
"""
Herdr Status Bridge (Python fallback)
Ultra-low overhead JSON streaming bridge for Herdr AI coding agents.
"""

import json
import os
import select
import socket
import sys
import time

def locate_socket():
    if "HERDR_SOCKET" in os.environ and os.path.exists(os.environ["HERDR_SOCKET"]):
        return os.environ["HERDR_SOCKET"]
    xdg_config = os.environ.get("XDG_CONFIG_HOME", os.path.expanduser("~/.config"))
    candidate = os.path.join(xdg_config, "herdr", "herdr.sock")
    if os.path.exists(candidate):
        return candidate
    return None

def compute_summary(agents, connected):
    if not connected and not agents:
        return {
            "total": 0, "working": 0, "blocked": 0, "done": 0, "idle": 0,
            "primary_status": "disconnected", "badge_text": "󰚩 off",
            "badge_icon": "󰚩", "status_color": "muted"
        }
    working = sum(1 for a in agents if a.get("status") == "working")
    blocked = sum(1 for a in agents if a.get("status") == "blocked")
    done = sum(1 for a in agents if a.get("status") == "done")
    idle = sum(1 for a in agents if a.get("status") == "idle")
    total = len(agents)

    if total == 0:
        return {"total": 0, "working": 0, "blocked": 0, "done": 0, "idle": 0, "primary_status": "idle", "badge_text": "󰚩 0", "badge_icon": "󰚩", "status_color": "muted"}
    elif blocked > 0:
        return {"total": total, "working": working, "blocked": blocked, "done": done, "idle": idle, "primary_status": "blocked", "badge_text": f"󰅚 {blocked} blocked", "badge_icon": "󰅚", "status_color": "urgent"}
    elif working > 0:
        return {"total": total, "working": working, "blocked": blocked, "done": done, "idle": idle, "primary_status": "working", "badge_text": f"󱑎 {working} working", "badge_icon": "󱑎", "status_color": "accent"}
    elif done > 0:
        return {"total": total, "working": working, "blocked": blocked, "done": done, "idle": idle, "primary_status": "done", "badge_text": f"󰄬 {done} done", "badge_icon": "󰄬", "status_color": "done"}
    else:
        return {"total": total, "working": working, "blocked": blocked, "done": done, "idle": idle, "primary_status": "idle", "badge_text": f"󰌒 {total} ready", "badge_icon": "󰌒", "status_color": "foreground"}

def emit_payload(agents, connected):
    summary = compute_summary(agents, connected)
    payload = {"connected": connected, "agents": agents, "summary": summary}
    sys.stdout.write(json.dumps(payload) + "\n")
    sys.stdout.flush()

def main():
    sock_path = locate_socket()
    if not sock_path:
        emit_payload([], False)
        return

    try:
        s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        s.connect(sock_path)
        s.sendall(json.dumps({"id": "init", "method": "agent.list", "params": {}}).encode("utf-8") + b"\n")
        res = s.recv(8192).decode("utf-8")
        agents = []
        for line in res.strip().split("\n"):
            try:
                data = json.loads(line)
                raw_agents = data.get("result", {}).get("agents", [])
                for ra in raw_agents:
                    agents.append({
                        "name": ra.get("agent", "agent"),
                        "status": ra.get("agent_status", "unknown"),
                        "pane_id": ra.get("pane_id", ""),
                        "workspace_id": ra.get("workspace_id", ""),
                        "tab_id": ra.get("tab_id", ""),
                        "title": ra.get("terminal_title", ""),
                        "cwd": ra.get("cwd", "~"),
                        "focused": ra.get("focused", False),
                        "source": "herdr"
                    })
            except Exception:
                pass
        emit_payload(agents, True)
        s.close()
    except Exception:
        emit_payload([], False)

if __name__ == "__main__":
    main()
