use serde_json::{json, Value};
use std::collections::HashMap;
use std::env;
use std::fs;
use std::io::{BufRead, BufReader, Write};
use std::os::unix::net::UnixStream;
use std::path::{Path, PathBuf};
use std::time::Duration;

use crate::payload::*;
use crate::pi::session_ref_from;
use crate::standalone::detect_standalone_agents;
use crate::status::determine_effective_status;

pub fn read_bounded_line<R: BufRead>(
    reader: &mut R,
    buf: &mut String,
    limit: usize,
) -> std::io::Result<usize> {
    buf.clear();
    let mut raw_bytes: Vec<u8> = Vec::new();

    loop {
        let available = match reader.fill_buf() {
            Ok(b) => b,
            Err(e) if e.kind() == std::io::ErrorKind::Interrupted => continue,
            Err(e) => return Err(e),
        };
        if available.is_empty() {
            break;
        }
        let newline_pos = available.iter().position(|&b| b == b'\n');
        let to_take = match newline_pos {
            Some(pos) => pos + 1,
            None => available.len(),
        };

        if raw_bytes.len() + to_take > limit {
            reader.consume(to_take);
            if newline_pos.is_none() {
                loop {
                    let av = match reader.fill_buf() {
                        Ok(b) => b,
                        Err(e) if e.kind() == std::io::ErrorKind::Interrupted => continue,
                        Err(e) => return Err(e),
                    };
                    if av.is_empty() {
                        break;
                    }
                    if let Some(p) = av.iter().position(|&b| b == b'\n') {
                        reader.consume(p + 1);
                        break;
                    }
                    let len = av.len();
                    reader.consume(len);
                }
            }
            return Err(std::io::Error::new(
                std::io::ErrorKind::InvalidData,
                "input line exceeded maximum allowed length",
            ));
        }

        raw_bytes.extend_from_slice(&available[..to_take]);
        reader.consume(to_take);

        if newline_pos.is_some() {
            break;
        }
    }

    if raw_bytes.is_empty() {
        return Ok(0);
    }

    *buf = String::from_utf8_lossy(&raw_bytes).into_owned();
    Ok(raw_bytes.len())
}

/// `$XDG_CONFIG_HOME/herdr`, falling back to `~/.config/herdr`.
fn herdr_config_dir() -> Option<PathBuf> {
    env::var_os("XDG_CONFIG_HOME")
        .map(PathBuf::from)
        .or_else(|| env::var_os("HOME").map(|home| PathBuf::from(home).join(".config")))
        .map(|config| config.join("herdr"))
}

pub fn locate_herdr_socket(override_path: Option<&str>) -> Option<PathBuf> {
    let explicit = override_path
        .map(PathBuf::from)
        .or_else(|| env::var_os("HERDR_SOCKET").map(PathBuf::from));
    explicit
        .into_iter()
        .chain(herdr_config_dir().map(|dir| dir.join("herdr.sock")))
        .find(|p| p.exists())
}

// Scans for Herdr sessions across default and named sockets
pub fn discover_herdr_sessions(override_socket: Option<&str>) -> Vec<(String, PathBuf)> {
    if let Some(sock) = locate_herdr_socket(override_socket) {
        return vec![("default".to_string(), sock)];
    }

    let Some(sessions_dir) = herdr_config_dir().map(|dir| dir.join("sessions")) else {
        return Vec::new();
    };
    fs::read_dir(sessions_dir)
        .into_iter()
        .flatten()
        .flatten()
        .filter_map(|entry| {
            let name = entry.file_name().to_string_lossy().to_string();
            let sock = entry.path().join("herdr.sock");
            (sock.exists() && name != "default").then_some((name, sock))
        })
        .collect()
}

fn str_field(v: &Value, key: &str) -> String {
    v[key].as_str().unwrap_or("").to_string()
}

/// Maps a Herdr pane/agent object to an `AgentInfo`; `None` when it has no pane id or agent.
pub fn agent_from_pane(pane: &Value, session_name: &str) -> Option<AgentInfo> {
    let pane_id = pane["pane_id"].as_str().filter(|p| !p.is_empty())?;
    let name = pane["agent"].as_str()?;
    let cwd = pane["cwd"].as_str().unwrap_or("~");
    let raw_status = pane["agent_status"].as_str().unwrap_or("unknown");
    let status =
        determine_effective_status(raw_status, name, session_ref_from(pane).as_ref(), cwd);
    Some(
        AgentInfo {
            name: name.to_string(),
            status,
            pane_id: pane_id.to_string(),
            workspace_id: str_field(pane, "workspace_id"),
            tab_id: str_field(pane, "tab_id"),
            title: pane["terminal_title"].as_str().unwrap_or(name).to_string(),
            cwd: cwd.to_string(),
            focused: pane["focused"].as_bool().unwrap_or(false),
            source: "herdr".to_string(),
            session: session_name.to_string(),
            state_changed_at: pane
                .get("state_changed_at")
                .and_then(|t| t.as_u64())
                .unwrap_or_else(current_unix_timestamp),
        }
        .sanitized(),
    )
}

pub fn fetch_agents_snapshot(
    socket_path: &Path,
    session_name: &str,
) -> Result<HashMap<String, AgentInfo>, Box<dyn std::error::Error>> {
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
    read_bounded_line(&mut reader, &mut line, MAX_SOCKET_LINE_BYTES)?;

    let v: Value = serde_json::from_str(line.trim()).unwrap_or(Value::Null);
    let items = v["result"]["agents"].as_array().map(Vec::as_slice).unwrap_or(&[]);
    let agent_map = items
        .iter()
        .take(MAX_AGENTS_COUNT)
        .filter_map(|item| {
            agent_from_pane(item, session_name).or_else(|| {
                // agent.list entries are agents even when Herdr has no label for them.
                let mut labelled = item.clone();
                labelled["agent"] = json!(item["terminal_title_stripped"].as_str().unwrap_or("agent"));
                agent_from_pane(&labelled, session_name)
            })
        })
        .map(|info| (info.pane_id.clone(), info))
        .collect();

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
            let raw_pane_id = data.get("pane_id").and_then(|p| p.as_str()).unwrap_or("");
            let new_status = data
                .get("agent_status")
                .and_then(|s| s.as_str())
                .unwrap_or("");

            if !raw_pane_id.is_empty() && !new_status.is_empty() {
                let pane_key = sanitize_field(raw_pane_id, MAX_ID_LEN);
                if let Some(agent) = agents_map.get_mut(&pane_key) {
                    let effective = determine_effective_status(
                        new_status,
                        &agent.name,
                        None,
                        &agent.cwd,
                    );
                    let sanitized_status = sanitize_field(&effective, MAX_STATUS_LEN);
                    if agent.status != sanitized_status {
                        agent.status = sanitized_status;
                        agent.state_changed_at = data
                            .get("state_changed_at")
                            .and_then(|t| t.as_u64())
                            .unwrap_or_else(current_unix_timestamp);
                        changed = true;
                    }
                }
            }
        }
        "pane_agent_detected" => {
            if let Some(data) = v.get("data") {
                let raw_pane_id = data["pane_id"].as_str().unwrap_or("");
                let released = data["released"].as_bool().unwrap_or(false);

                if !raw_pane_id.is_empty() {
                    let pane_key = sanitize_field(raw_pane_id, MAX_ID_LEN);
                    if released {
                        if agents_map.remove(&pane_key).is_some() {
                            changed = true;
                        }
                    } else if let Some(agent_name) = data["agent"].as_str() {
                        if agents_map.contains_key(&pane_key) || agents_map.len() < MAX_AGENTS_COUNT {
                            let info = AgentInfo {
                                name: agent_name.to_string(),
                                status: "working".to_string(),
                                pane_id: pane_key.clone(),
                                workspace_id: str_field(data, "workspace_id"),
                                tab_id: String::new(),
                                title: agent_name.to_string(),
                                cwd: "~".to_string(),
                                focused: false,
                                source: "herdr".to_string(),
                                session: "default".to_string(),
                                state_changed_at: data
                                    .get("state_changed_at")
                                    .and_then(|t| t.as_u64())
                                    .unwrap_or_else(current_unix_timestamp),
                            }
                            .sanitized();
                            agents_map.insert(pane_key, info);
                            changed = true;
                        }
                    }
                }
            }
        }
        "pane_updated" => {
            if let Some(pane) = v.get("data").and_then(|d| d.get("pane")) {
                let pane_key = sanitize_field(pane["pane_id"].as_str().unwrap_or(""), MAX_ID_LEN);
                let existing = agents_map.get(&pane_key);
                let session = existing.map_or("default", |a| a.session.as_str());
                if let Some(mut info) = agent_from_pane(pane, session) {
                    if pane.get("state_changed_at").is_none() {
                        if let Some(existing) = existing.filter(|e| e.status == info.status) {
                            info.state_changed_at = existing.state_changed_at;
                        }
                    }
                    if existing != Some(&info)
                        && (existing.is_some() || agents_map.len() < MAX_AGENTS_COUNT)
                    {
                        agents_map.insert(pane_key, info);
                        changed = true;
                    }
                }
            }
        }
        "pane_closed" | "pane_exited" => {
            if let Some(raw_pane_id) = v
                .get("data")
                .and_then(|d| d.get("pane_id"))
                .and_then(|p| p.as_str())
            {
                let pane_key = sanitize_field(raw_pane_id, MAX_ID_LEN);
                if agents_map.remove(&pane_key).is_some() {
                    changed = true;
                }
            }
        }
        _ => {}
    }

    changed
}

/// Emits the connected payload, falling back to standalone processes when Herdr has no agents.
fn emit_agents(agents_map: &HashMap<String, AgentInfo>) {
    let mut list: Vec<AgentInfo> = agents_map.values().cloned().collect();
    if list.is_empty() {
        list = detect_standalone_agents();
    }
    emit_payload(&mut StatusPayload::new(true, list));
}

pub fn stream_events_loop(
    socket_path: &Path,
    session_name: &str,
    mut agents_map: HashMap<String, AgentInfo>,
    once_mode: bool,
) -> Result<(), Box<dyn std::error::Error>> {
    emit_agents(&agents_map);

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
        let read_res = read_bounded_line(&mut reader, &mut line, MAX_SOCKET_LINE_BYTES);

        match read_res {
            Ok(0) => {
                log!("herdr closed the event stream ({})", socket_path.display());
                return Ok(());
            }
            Ok(_) => {
                let trimmed = line.trim();
                if !trimmed.is_empty() && process_event_json(trimmed, &mut agents_map) {
                    emit_agents(&agents_map);
                }
            }
            Err(ref e)
                if e.kind() == std::io::ErrorKind::WouldBlock
                    || e.kind() == std::io::ErrorKind::TimedOut =>
            {
                // Timeout is normal; periodic sync below handles snapshot refresh
            }
            Err(ref e) if e.kind() == std::io::ErrorKind::InvalidData => {
                log!("skipping oversized Herdr socket line: {}", e);
            }
            Err(e) => {
                return Err(Box::new(e));
            }
        }

        // Periodic ground-truth sync: query Herdr socket every 1500ms to eliminate any state mismatch
        if last_snapshot_sync.elapsed() >= Duration::from_millis(1500) {
            last_snapshot_sync = std::time::Instant::now();
            match fetch_agents_snapshot(socket_path, session_name) {
                Ok(mut fresh) => {
                    for (pane_id, fresh_agent) in fresh.iter_mut() {
                        if let Some(existing) = agents_map.get(pane_id) {
                            if existing.status == fresh_agent.status {
                                fresh_agent.state_changed_at = existing.state_changed_at;
                            }
                        }
                    }
                    if fresh != agents_map {
                        agents_map = fresh;
                        emit_agents(&agents_map);
                    }
                }
                Err(e) => log!("snapshot sync failed: {}", e),
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::payload::make_agent;

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
        assert!(map["w1:p1"].state_changed_at > 0);

        // Transition back to working with explicit timestamp
        let event_json_working = r#"{
            "event": "pane_agent_status_changed",
            "data": {
                "type": "pane_agent_status_changed",
                "pane_id": "w1:p1",
                "workspace_id": "w1",
                "agent_status": "working",
                "state_changed_at": 1720000000
            }
        }"#;
        let changed2 = process_event_json(event_json_working, &mut map);
        assert!(changed2);
        assert_eq!(map["w1:p1"].status, "working");
        assert_eq!(map["w1:p1"].state_changed_at, 1720000000);

        // Same status does not trigger update
        let event_json_same = r#"{
            "event": "pane_agent_status_changed",
            "data": {
                "type": "pane_agent_status_changed",
                "pane_id": "w1:p1",
                "workspace_id": "w1",
                "agent_status": "working",
                "state_changed_at": 1799999999
            }
        }"#;
        let changed3 = process_event_json(event_json_same, &mut map);
        assert!(!changed3);
        assert_eq!(map["w1:p1"].state_changed_at, 1720000000);
    }

    #[test]
    fn test_process_event_pane_updated() {
        let mut map = HashMap::new();
        let mut initial = make_agent("agent-1", "working", "w1:p1");
        initial.state_changed_at = 1710000000;
        map.insert("w1:p1".to_string(), initial);

        // Update title/cwd only without changing status: state_changed_at should be preserved
        let update_json = r#"{
            "event": "pane_updated",
            "data": {
                "pane": {
                    "pane_id": "w1:p1",
                    "agent": "agent-1",
                    "agent_status": "working",
                    "cwd": "/home/arch/new-dir",
                    "terminal_title": "new title",
                    "workspace_id": "w1",
                    "tab_id": "w1:t1",
                    "focused": true
                }
            }
        }"#;
        let changed = process_event_json(update_json, &mut map);
        assert!(changed);
        assert_eq!(map["w1:p1"].cwd, "/home/arch/new-dir");
        assert_eq!(map["w1:p1"].state_changed_at, 1710000000);

        // Update status: state_changed_at should be refreshed
        let status_change_json = r#"{
            "event": "pane_updated",
            "data": {
                "pane": {
                    "pane_id": "w1:p1",
                    "agent": "agent-1",
                    "agent_status": "done",
                    "cwd": "/home/arch/new-dir",
                    "terminal_title": "new title",
                    "workspace_id": "w1",
                    "tab_id": "w1:t1",
                    "focused": true,
                    "state_changed_at": 1725000000
                }
            }
        }"#;
        let changed2 = process_event_json(status_change_json, &mut map);
        assert!(changed2);
        assert_eq!(map["w1:p1"].status, "done");
        assert_eq!(map["w1:p1"].state_changed_at, 1725000000);
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
    fn test_read_bounded_line_within_limit() {
        let data = b"hello world\nnext line\n";
        let mut cursor = std::io::Cursor::new(data);
        let mut line = String::new();
        let bytes = read_bounded_line(&mut cursor, &mut line, 100).expect("read ok");
        assert_eq!(bytes, 12);
        assert_eq!(line, "hello world\n");
    }

    #[test]
    fn test_read_bounded_line_exceeds_limit() {
        let long_data = format!("{}\n", "x".repeat(200));
        let mut cursor = std::io::Cursor::new(long_data.as_bytes());
        let mut line = String::new();
        let res = read_bounded_line(&mut cursor, &mut line, 50);
        assert!(res.is_err());
        assert!(line.is_empty());
    }

    #[test]
    fn test_read_bounded_line_multibyte_utf8_split_chunks() {
        // 4-byte emoji 🦀 is [0xF0, 0x9F, 0xA6, 0x80]
        struct ChunkedReader {
            chunks: Vec<Vec<u8>>,
            index: usize,
        }
        impl std::io::Read for ChunkedReader {
            fn read(&mut self, buf: &mut [u8]) -> std::io::Result<usize> {
                if self.index >= self.chunks.len() {
                    return Ok(0);
                }
                let chunk = &self.chunks[self.index];
                let len = chunk.len().min(buf.len());
                buf[..len].copy_from_slice(&chunk[..len]);
                self.index += 1;
                Ok(len)
            }
        }
        impl BufRead for ChunkedReader {
            fn fill_buf(&mut self) -> std::io::Result<&[u8]> {
                if self.index >= self.chunks.len() {
                    return Ok(&[]);
                }
                Ok(&self.chunks[self.index])
            }
            fn consume(&mut self, _amt: usize) {
                self.index += 1;
            }
        }

        let mut reader = ChunkedReader {
            chunks: vec![
                vec![0xF0, 0x9F],       // Split midway through 🦀
                vec![0xA6, 0x80, b'\n'], // Rest of 🦀 and newline
            ],
            index: 0,
        };

        let mut line = String::new();
        let bytes = read_bounded_line(&mut reader, &mut line, 100).expect("decode ok");
        assert_eq!(bytes, 5);
        assert_eq!(line, "🦀\n");
    }

    #[test]
    fn test_consistent_bounded_pane_id_keys() {
        let mut map = HashMap::new();
        let long_pane_id = "x".repeat(200);
        let event = json!({
            "event": "pane_updated",
            "data": {
                "pane": {
                    "pane_id": long_pane_id,
                    "agent": "long_agent",
                    "agent_status": "working",
                    "cwd": "/home/arch",
                    "terminal_title": "title"
                }
            }
        });

        let changed = process_event_json(&event.to_string(), &mut map);
        assert!(changed);
        let expected_key = sanitize_field(&long_pane_id, MAX_ID_LEN);
        assert_eq!(expected_key.len(), MAX_ID_LEN);
        assert!(map.contains_key(&expected_key));
        assert_eq!(map[&expected_key].pane_id, expected_key);

        // Verify pane_closed removes it with the same long raw pane_id
        let close_event = json!({
            "event": "pane_closed",
            "data": {
                "pane_id": long_pane_id
            }
        });
        let closed = process_event_json(&close_event.to_string(), &mut map);
        assert!(closed);
        assert!(!map.contains_key(&expected_key));
    }
    #[test]
    fn test_agent_from_pane_requires_pane_id_and_agent() {
        let pane = json!({"pane_id": "w1:p1", "agent": "claude", "agent_status": "idle",
                          "cwd": "/tmp", "terminal_title": "t", "tab_id": "w1:t1", "workspace_id": "w1"});
        let info = agent_from_pane(&pane, "work").unwrap();
        assert_eq!(info.name, "claude");
        assert_eq!(info.status, "idle");
        assert_eq!(info.session, "work");
        assert_eq!(info.tab_id, "w1:t1");

        assert!(agent_from_pane(&json!({"pane_id": "w1:p1"}), "default").is_none());
        assert!(agent_from_pane(&json!({"agent": "claude"}), "default").is_none());
        assert!(agent_from_pane(&json!({"pane_id": "", "agent": "claude"}), "default").is_none());
    }
}
