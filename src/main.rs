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

pub fn compute_summary(agents: &[AgentInfo], connected: bool) -> StatusSummary {
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
        match a.status.trim().to_lowercase().as_str() {
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
    } else if idle > 0 {
        (
            "idle".to_string(),
            "󰌒".to_string(),
            format!("󰌒 {} ready", total),
            "foreground".to_string(),
        )
    } else {
        (
            "unknown".to_string(),
            "󰚩".to_string(),
            format!("󰚩 {} active", total),
            "muted".to_string(),
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

pub fn process_event_json(
    trimmed: &str,
    agents_map: &mut HashMap<String, AgentInfo>,
) -> bool {
    let Ok(v) = serde_json::from_str::<Value>(trimmed) else {
        return false;
    };

    let Some(event) = v.get("event").and_then(|e| e.as_str()) else {
        return false;
    };

    let mut changed = false;

    match event {
        "pane_agent_status_changed" => {
            let data = v.get("data").unwrap_or(&v);
            let pane_id = data.get("pane_id").and_then(|p| p.as_str()).unwrap_or("");
            let new_status = data
                .get("agent_status")
                .and_then(|s| s.as_str())
                .unwrap_or("");

            if !pane_id.is_empty() && !new_status.is_empty() {
                if let Some(agent) = agents_map.get_mut(pane_id) {
                    if agent.status != new_status {
                        agent.status = new_status.to_string();
                        changed = true;
                    }
                }
            }
        }
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
                            status: "working".to_string(),
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

                        let info = AgentInfo {
                            name: name.to_string(),
                            status: status.to_string(),
                            pane_id: pane_id.to_string(),
                            workspace_id: workspace_id.to_string(),
                            tab_id: tab_id.to_string(),
                            title: title.to_string(),
                            cwd: cwd.to_string(),
                            focused,
                            source: "herdr".to_string(),
                        };

                        if agents_map.get(pane_id) != Some(&info) {
                            agents_map.insert(pane_id.to_string(), info);
                            changed = true;
                        }
                    }
                }
            }
        }
        "pane_closed" | "pane_exited" => {
            if let Some(pane_id) = v
                .get("data")
                .and_then(|d| d.get("pane_id"))
                .and_then(|p| p.as_str())
            {
                if agents_map.remove(pane_id).is_some() {
                    changed = true;
                }
            }
        }
        _ => {}
    }

    changed
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
    // Read timeout for periodic snapshot sync (every 1 second)
    stream.set_read_timeout(Some(Duration::from_millis(1000)))?;

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
    let mut last_snapshot_sync = std::time::Instant::now();

    loop {
        line.clear();
        let read_res = reader.read_line(&mut line);

        match read_res {
            Ok(0) => {
                // Herdr server disconnected
                return Ok(());
            }
            Ok(_) => {
                let trimmed = line.trim();
                if !trimmed.is_empty() {
                    let changed = process_event_json(trimmed, &mut agents_map);
                    if changed {
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
            Err(ref e)
                if e.kind() == std::io::ErrorKind::WouldBlock
                    || e.kind() == std::io::ErrorKind::TimedOut =>
            {
                // Timeout is normal; periodic sync below handles snapshot refresh
            }
            Err(e) => {
                return Err(Box::new(e));
            }
        }

        // Periodic ground-truth sync: query Herdr socket every 1500ms to eliminate any state mismatch
        if last_snapshot_sync.elapsed() >= Duration::from_millis(1500) {
            last_snapshot_sync = std::time::Instant::now();
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

#[cfg(test)]
mod tests {
    use super::*;

    fn make_agent(name: &str, status: &str, pane_id: &str) -> AgentInfo {
        AgentInfo {
            name: name.to_string(),
            status: status.to_string(),
            pane_id: pane_id.to_string(),
            workspace_id: "w1".to_string(),
            tab_id: "w1:t1".to_string(),
            title: name.to_string(),
            cwd: "/home/arch".to_string(),
            focused: false,
            source: "herdr".to_string(),
        }
    }

    #[test]
    fn test_compute_summary_disconnected() {
        let summary = compute_summary(&[], false);
        assert_eq!(summary.primary_status, "disconnected");
        assert_eq!(summary.badge_text, "󰚩 off");
        assert_eq!(summary.status_color, "muted");
        assert_eq!(summary.total, 0);
    }

    #[test]
    fn test_compute_summary_empty_connected() {
        let summary = compute_summary(&[], true);
        assert_eq!(summary.primary_status, "idle");
        assert_eq!(summary.badge_text, "󰚩 0");
        assert_eq!(summary.badge_icon, "󰚩");
        assert_eq!(summary.status_color, "muted");
        assert_eq!(summary.total, 0);
    }

    #[test]
    fn test_compute_summary_blocked_takes_highest_precedence() {
        // If any agent is blocked, urgent color and blocked badge must be shown
        let agents = vec![
            make_agent("agent-1", "working", "w1:p1"),
            make_agent("agent-2", "blocked", "w1:p2"),
            make_agent("agent-3", "done", "w1:p3"),
            make_agent("agent-4", "idle", "w1:p4"),
        ];
        let summary = compute_summary(&agents, true);
        assert_eq!(summary.total, 4);
        assert_eq!(summary.blocked, 1);
        assert_eq!(summary.working, 1);
        assert_eq!(summary.done, 1);
        assert_eq!(summary.idle, 1);
        assert_eq!(summary.primary_status, "blocked");
        assert_eq!(summary.badge_text, "󰅚 1 blocked");
        assert_eq!(summary.badge_icon, "󰅚");
        assert_eq!(summary.status_color, "urgent");
    }

    #[test]
    fn test_compute_summary_multiple_blocked() {
        let agents = vec![
            make_agent("agent-1", "blocked", "w1:p1"),
            make_agent("agent-2", "blocked", "w1:p2"),
        ];
        let summary = compute_summary(&agents, true);
        assert_eq!(summary.blocked, 2);
        assert_eq!(summary.primary_status, "blocked");
        assert_eq!(summary.badge_text, "󰅚 2 blocked");
        assert_eq!(summary.status_color, "urgent");
    }

    #[test]
    fn test_compute_summary_working_precedence_over_done_and_idle() {
        let agents = vec![
            make_agent("agent-1", "working", "w1:p1"),
            make_agent("agent-2", "done", "w1:p2"),
            make_agent("agent-3", "idle", "w1:p3"),
        ];
        let summary = compute_summary(&agents, true);
        assert_eq!(summary.working, 1);
        assert_eq!(summary.blocked, 0);
        assert_eq!(summary.primary_status, "working");
        assert_eq!(summary.badge_text, "󱑎 1 working");
        assert_eq!(summary.badge_icon, "󱑎");
        assert_eq!(summary.status_color, "accent");
    }

    #[test]
    fn test_compute_summary_done_when_all_complete() {
        let agents = vec![
            make_agent("agent-1", "done", "w1:p1"),
            make_agent("agent-2", "done", "w1:p2"),
        ];
        let summary = compute_summary(&agents, true);
        assert_eq!(summary.done, 2);
        assert_eq!(summary.working, 0);
        assert_eq!(summary.blocked, 0);
        assert_eq!(summary.primary_status, "done");
        assert_eq!(summary.badge_text, "󰄬 2 done");
        assert_eq!(summary.badge_icon, "󰄬");
        assert_eq!(summary.status_color, "done");
    }

    #[test]
    fn test_compute_summary_idle_ready() {
        let agents = vec![
            make_agent("agent-1", "idle", "w1:p1"),
            make_agent("agent-2", "idle", "w1:p2"),
        ];
        let summary = compute_summary(&agents, true);
        assert_eq!(summary.idle, 2);
        assert_eq!(summary.primary_status, "idle");
        assert_eq!(summary.badge_text, "󰌒 2 ready");
        assert_eq!(summary.badge_icon, "󰌒");
        assert_eq!(summary.status_color, "foreground");
    }

    #[test]
    fn test_compute_summary_case_and_whitespace_normalization() {
        let agents = vec![
            make_agent("agent-1", "  Blocked  ", "w1:p1"),
            make_agent("agent-2", "WORKING", "w1:p2"),
        ];
        let summary = compute_summary(&agents, true);
        assert_eq!(summary.blocked, 1);
        assert_eq!(summary.working, 1);
        assert_eq!(summary.primary_status, "blocked");
        assert_eq!(summary.badge_text, "󰅚 1 blocked");
    }

    #[test]
    fn test_process_event_pane_agent_status_changed() {
        let mut map = HashMap::new();
        map.insert("w1:p1".to_string(), make_agent("agent-1", "working", "w1:p1"));

        let event_json = r#"{
            "event": "pane_agent_status_changed",
            "data": {
                "type": "pane_agent_status_changed",
                "pane_id": "w1:p1",
                "workspace_id": "w1",
                "agent_status": "blocked"
            }
        }"#;

        let changed = process_event_json(event_json, &mut map);
        assert!(changed, "Expected status change to be handled");
        assert_eq!(map["w1:p1"].status, "blocked");

        // Transition back to working
        let event_json_working = r#"{
            "event": "pane_agent_status_changed",
            "data": {
                "type": "pane_agent_status_changed",
                "pane_id": "w1:p1",
                "workspace_id": "w1",
                "agent_status": "working"
            }
        }"#;
        let changed2 = process_event_json(event_json_working, &mut map);
        assert!(changed2);
        assert_eq!(map["w1:p1"].status, "working");
    }

    #[test]
    fn test_process_event_pane_agent_detected_and_released() {
        let mut map = HashMap::new();

        // Agent detected
        let detect_json = r#"{
            "event": "pane_agent_detected",
            "data": {
                "type": "pane_agent_detected",
                "pane_id": "w1:p5",
                "workspace_id": "w1",
                "agent": "codex",
                "released": false
            }
        }"#;
        let changed = process_event_json(detect_json, &mut map);
        assert!(changed);
        assert!(map.contains_key("w1:p5"));
        assert_eq!(map["w1:p5"].name, "codex");

        // Agent released
        let release_json = r#"{
            "event": "pane_agent_detected",
            "data": {
                "type": "pane_agent_detected",
                "pane_id": "w1:p5",
                "workspace_id": "w1",
                "released": true
            }
        }"#;
        let changed2 = process_event_json(release_json, &mut map);
        assert!(changed2);
        assert!(!map.contains_key("w1:p5"));
    }

    #[test]
    fn test_process_event_pane_closed() {
        let mut map = HashMap::new();
        map.insert("w1:p1".to_string(), make_agent("agent-1", "working", "w1:p1"));

        let closed_json = r#"{
            "event": "pane_closed",
            "data": {
                "pane_id": "w1:p1"
            }
        }"#;
        let changed = process_event_json(closed_json, &mut map);
        assert!(changed);
        assert!(!map.contains_key("w1:p1"));
    }

    #[test]
    fn test_status_payload_roundtrip() {
        let agents = vec![make_agent("pi", "blocked", "wG:p1")];
        let summary = compute_summary(&agents, true);
        let payload = StatusPayload {
            connected: true,
            agents,
            summary,
        };

        let serialized = serde_json::to_string(&payload).expect("Serialization failed");
        let parsed: Value = serde_json::from_str(&serialized).expect("Deserialization failed");

        assert_eq!(parsed["connected"], true);
        assert_eq!(parsed["summary"]["blocked"], 1);
        assert_eq!(parsed["summary"]["primary_status"], "blocked");
        assert_eq!(parsed["agents"][0]["name"], "pi");
    }
}
