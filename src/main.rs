use serde::{Deserialize, Serialize};
use serde_json::{json, Value};
use std::collections::{HashMap, HashSet};
use std::env;
use std::fs;
use std::io::{BufRead, BufReader, Write};
use std::os::unix::net::UnixStream;
use std::path::{Path, PathBuf};
use std::time::Duration;

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct AgentInfo {
    pub name: String,
    pub status: String,
    pub pane_id: String,
    pub workspace_id: String,
    pub tab_id: String,
    pub title: String,
    pub cwd: String,
    pub focused: bool,
    pub source: String,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct StatusSummary {
    pub total: usize,
    pub working: usize,
    pub blocked: usize,
    pub done: usize,
    pub idle: usize,
    pub unknown: usize,
    pub primary_status: String,
    pub badge_text: String,
    pub badge_icon: String,
    pub status_color: String,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct StatusPayload {
    pub connected: bool,
    pub agents: Vec<AgentInfo>,
    pub summary: StatusSummary,
}

fn compute_summary(agents: &[AgentInfo], connected: bool) -> StatusSummary {
    if !connected && agents.is_empty() {
        return StatusSummary {
            total: 0,
            working: 0,
            blocked: 0,
            done: 0,
            idle: 0,
            unknown: 0,
            primary_status: "disconnected".to_string(),
            badge_text: "󰚩 off".to_string(),
            badge_icon: "󰚩".to_string(),
            status_color: "muted".to_string(),
        };
    }

    let mut working = 0;
    let mut blocked = 0;
    let mut done = 0;
    let mut idle = 0;
    let mut unknown = 0;

    for a in agents {
        match a.status.as_str() {
            "working" => working += 1,
            "blocked" => blocked += 1,
            "done" => done += 1,
            "idle" => idle += 1,
            _ => unknown += 1,
        }
    }

    let total = agents.len();
    let (primary_status, badge_icon, badge_text, status_color) = if total == 0 {
        (
            "idle".to_string(),
            "󰚩".to_string(),
            "󰚩 0".to_string(),
            "muted".to_string(),
        )
    } else if blocked > 0 {
        (
            "blocked".to_string(),
            "󰅚".to_string(),
            format!("󰅚 {} blocked", blocked),
            "urgent".to_string(),
        )
    } else if working > 0 {
        (
            "working".to_string(),
            "󱑎".to_string(),
            format!("󱑎 {} working", working),
            "accent".to_string(),
        )
    } else if done > 0 {
        (
            "done".to_string(),
            "󰄬".to_string(),
            format!("󰄬 {} done", done),
            "done".to_string(),
        )
    } else {
        (
            "idle".to_string(),
            "󰌒".to_string(),
            format!("󰌒 {} ready", total),
            "foreground".to_string(),
        )
    };

    StatusSummary {
        total,
        working,
        blocked,
        done,
        idle,
        unknown,
        primary_status,
        badge_text,
        badge_icon,
        status_color,
    }
}

fn locate_herdr_socket(override_path: Option<&str>) -> Option<PathBuf> {
    if let Some(p) = override_path {
        let pb = PathBuf::from(p);
        if pb.exists() {
            return Some(pb);
        }
    }

    if let Ok(p) = env::var("HERDR_SOCKET") {
        let pb = PathBuf::from(p);
        if pb.exists() {
            return Some(pb);
        }
    }

    if let Ok(config_home) = env::var("XDG_CONFIG_HOME") {
        let pb = PathBuf::from(config_home).join("herdr/herdr.sock");
        if pb.exists() {
            return Some(pb);
        }
    }

    if let Ok(home) = env::var("HOME") {
        let pb = PathBuf::from(home).join(".config/herdr/herdr.sock");
        if pb.exists() {
            return Some(pb);
        }
    }

    None
}

// Scans /proc for non-Herdr agents (e.g. claude, codex, opencode, gemini, pi)
fn detect_standalone_agents() -> Vec<AgentInfo> {
    let known_agents: HashSet<&'static str> =
        ["claude", "codex", "opencode", "gemini", "pi"].into_iter().collect();
    let mut detected = Vec::new();

    if let Ok(entries) = fs::read_dir("/proc") {
        for entry in entries.flatten() {
            let name = entry.file_name();
            let name_str = name.to_string_lossy();
            if !name_str.chars().all(|c| c.is_ascii_digit()) {
                continue;
            }

            let comm_path = entry.path().join("comm");
            if let Ok(comm) = fs::read_to_string(comm_path) {
                let comm_trim = comm.trim();
                if known_agents.contains(comm_trim) {
                    let pid = name_str.to_string();
                    let cwd = fs::read_link(entry.path().join("cwd"))
                        .map(|p| p.to_string_lossy().to_string())
                        .unwrap_or_else(|_| "~".to_string());

                    detected.push(AgentInfo {
                        name: comm_trim.to_string(),
                        status: "working".to_string(),
                        pane_id: format!("pid:{}", pid),
                        workspace_id: "system".to_string(),
                        tab_id: "system".to_string(),
                        title: format!("{} (system)", comm_trim),
                        cwd,
                        focused: false,
                        source: "system".to_string(),
                    });
                }
            }
        }
    }

    detected
}

fn emit_payload(payload: &StatusPayload) {
    if let Ok(serialized) = serde_json::to_string(payload) {
        println!("{}", serialized);
        let _ = std::io::stdout().flush();
    }
}

fn fetch_agents_snapshot(socket_path: &Path) -> Result<HashMap<String, AgentInfo>, Box<dyn std::error::Error>> {
    let mut stream = UnixStream::connect(socket_path)?;
    stream.set_read_timeout(Some(Duration::from_millis(1500)))?;

    let req = json!({
        "id": "init_agent_list",
        "method": "agent.list",
        "params": {}
    });
    writeln!(stream, "{}", req)?;

    let mut reader = BufReader::new(stream);
    let mut line = String::new();
    reader.read_line(&mut line)?;

    let mut agent_map = HashMap::new();
    if let Ok(v) = serde_json::from_str::<Value>(line.trim()) {
        if let Some(arr) = v.get("result").and_then(|r| r.get("agents")).and_then(|a| a.as_array()) {
            for item in arr {
                let name = item["agent"]
                    .as_str()
                    .or_else(|| item["terminal_title_stripped"].as_str())
                    .unwrap_or("agent")
                    .to_string();
                let status = item["agent_status"].as_str().unwrap_or("unknown").to_string();
                let pane_id = item["pane_id"].as_str().unwrap_or("").to_string();
                let workspace_id = item["workspace_id"].as_str().unwrap_or("").to_string();
                let tab_id = item["tab_id"].as_str().unwrap_or("").to_string();
                let title = item["terminal_title"].as_str().unwrap_or(&name).to_string();
                let cwd = item["cwd"].as_str().unwrap_or("~").to_string();
                let focused = item["focused"].as_bool().unwrap_or(false);

                if !pane_id.is_empty() {
                    agent_map.insert(
                        pane_id.clone(),
                        AgentInfo {
                            name,
                            status,
                            pane_id,
                            workspace_id,
                            tab_id,
                            title,
                            cwd,
                            focused,
                            source: "herdr".to_string(),
                        },
                    );
                }
            }
        }
    }

    Ok(agent_map)
}

fn stream_events_loop(
    socket_path: &Path,
    mut agents_map: HashMap<String, AgentInfo>,
    once_mode: bool,
) -> Result<(), Box<dyn std::error::Error>> {
    // Emit initial state
    let agents_list: Vec<AgentInfo> = agents_map.values().cloned().collect();
    let summary = compute_summary(&agents_list, true);
    emit_payload(&StatusPayload {
        connected: true,
        agents: agents_list,
        summary,
    });

    if once_mode {
        return Ok(());
    }

    let mut stream = UnixStream::connect(socket_path)?;
    // Read timeout for periodic health sync (every 6 seconds)
    stream.set_read_timeout(Some(Duration::from_millis(6000)))?;

    let sub_req = json!({
        "id": "event_sub",
        "method": "events.subscribe",
        "params": {
            "subscriptions": [
                { "type": "pane.agent_detected" },
                { "type": "pane.updated" },
                { "type": "pane.created" },
                { "type": "pane.closed" },
                { "type": "pane.exited" }
            ]
        }
    });
    writeln!(stream, "{}", sub_req)?;

    let mut reader = BufReader::new(stream);
    let mut line = String::new();

    loop {
        line.clear();
        match reader.read_line(&mut line) {
            Ok(0) => {
                // Herdr server disconnected
                return Ok(());
            }
            Ok(_) => {
                let trimmed = line.trim();
                if trimmed.is_empty() {
                    continue;
                }

                if let Ok(v) = serde_json::from_str::<Value>(trimmed) {
                    if let Some(event) = v.get("event").and_then(|e| e.as_str()) {
                        let mut changed = false;

                        match event {
                            "pane_agent_detected" => {
                                if let Some(data) = v.get("data") {
                                    let pane_id = data["pane_id"].as_str().unwrap_or("");
                                    let released = data["released"].as_bool().unwrap_or(false);

                                    if !pane_id.is_empty() {
                                        if released {
                                            if agents_map.remove(pane_id).is_some() {
                                                changed = true;
                                            }
                                        } else if let Some(agent_name) = data["agent"].as_str() {
                                            let workspace_id = data["workspace_id"].as_str().unwrap_or("");
                                            let entry = agents_map.entry(pane_id.to_string()).or_insert_with(|| AgentInfo {
                                                name: agent_name.to_string(),
                                                status: "unknown".to_string(),
                                                pane_id: pane_id.to_string(),
                                                workspace_id: workspace_id.to_string(),
                                                tab_id: "".to_string(),
                                                title: agent_name.to_string(),
                                                cwd: "~".to_string(),
                                                focused: false,
                                                source: "herdr".to_string(),
                                            });
                                            entry.name = agent_name.to_string();
                                            changed = true;
                                        }
                                    }
                                }
                            }
                            "pane_updated" => {
                                if let Some(pane) = v.get("data").and_then(|d| d.get("pane")) {
                                    let pane_id = pane["pane_id"].as_str().unwrap_or("");
                                    if !pane_id.is_empty() {
                                        let agent_name = pane.get("agent").and_then(|a| a.as_str());
                                        if let Some(name) = agent_name {
                                            let status = pane["agent_status"].as_str().unwrap_or("unknown");
                                            let cwd = pane["cwd"].as_str().unwrap_or("~");
                                            let title = pane["terminal_title"].as_str().unwrap_or(name);
                                            let workspace_id = pane["workspace_id"].as_str().unwrap_or("");
                                            let tab_id = pane["tab_id"].as_str().unwrap_or("");
                                            let focused = pane["focused"].as_bool().unwrap_or(false);

                                            agents_map.insert(
                                                pane_id.to_string(),
                                                AgentInfo {
                                                    name: name.to_string(),
                                                    status: status.to_string(),
                                                    pane_id: pane_id.to_string(),
                                                    workspace_id: workspace_id.to_string(),
                                                    tab_id: tab_id.to_string(),
                                                    title: title.to_string(),
                                                    cwd: cwd.to_string(),
                                                    focused,
                                                    source: "herdr".to_string(),
                                                },
                                            );
                                            changed = true;
                                        } else {
                                            // No agent in this pane
                                            if agents_map.remove(pane_id).is_some() {
                                                changed = true;
                                            }
                                        }
                                    }
                                }
                            }
                            "pane_closed" | "pane_exited" => {
                                if let Some(pane_id) = v.get("data").and_then(|d| d.get("pane_id")).and_then(|p| p.as_str()) {
                                    if agents_map.remove(pane_id).is_some() {
                                        changed = true;
                                    }
                                }
                            }
                            _ => {}
                        }

                        if changed {
                            let mut list: Vec<AgentInfo> = agents_map.values().cloned().collect();
                            if list.is_empty() {
                                // Fallback to system agents if any
                                list = detect_standalone_agents();
                            }
                            let summary = compute_summary(&list, true);
                            emit_payload(&StatusPayload {
                                connected: true,
                                agents: list,
                                summary,
                            });
                        }
                    }
                }
            }
            Err(ref e)
                if e.kind() == std::io::ErrorKind::WouldBlock
                    || e.kind() == std::io::ErrorKind::TimedOut =>
            {
                // Heartbeat sync: check if any snapshot changes or standalone agents
                if let Ok(fresh) = fetch_agents_snapshot(socket_path) {
                    if fresh != agents_map {
                        agents_map = fresh;
                        let mut list: Vec<AgentInfo> = agents_map.values().cloned().collect();
                        if list.is_empty() {
                            list = detect_standalone_agents();
                        }
                        let summary = compute_summary(&list, true);
                        emit_payload(&StatusPayload {
                            connected: true,
                            agents: list,
                            summary,
                        });
                    }
                }
            }
            Err(e) => {
                return Err(Box::new(e));
            }
        }
    }
}

fn main() {
    let args: Vec<String> = env::args().collect();
    let once_mode = args.iter().any(|a| a == "--once");
    let override_socket = args
        .iter()
        .position(|a| a == "--socket")
        .and_then(|i| args.get(i + 1).map(|s| s.as_str()));

    loop {
        if let Some(sock_path) = locate_herdr_socket(override_socket) {
            match fetch_agents_snapshot(&sock_path) {
                Ok(initial_agents) => {
                    if let Err(_e) = stream_events_loop(&sock_path, initial_agents, once_mode) {
                        // Connection dropped, retry after sleep
                    }
                }
                Err(_) => {
                    // Could not query socket, check standalone
                    let standalone = detect_standalone_agents();
                    let summary = compute_summary(&standalone, false);
                    emit_payload(&StatusPayload {
                        connected: false,
                        agents: standalone,
                        summary,
                    });
                }
            }
        } else {
            let standalone = detect_standalone_agents();
            let summary = compute_summary(&standalone, false);
            emit_payload(&StatusPayload {
                connected: false,
                agents: standalone,
                summary,
            });
        }

        if once_mode {
            break;
        }

        std::thread::sleep(Duration::from_millis(2500));
    }
}
