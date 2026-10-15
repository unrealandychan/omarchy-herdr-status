use serde_json::{json, Value};
use std::collections::{HashMap, HashSet};
use std::env;
use std::fs;
use std::io::{BufRead, BufReader, Write};
use std::os::unix::net::UnixStream;
use std::path::{Path, PathBuf};
use std::time::{Duration, Instant};

use crate::payload::*;
use crate::pi::session_ref_from;
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

/// Session name for a socket path: `<config>/herdr/sessions/<name>/herdr.sock` → `<name>`.
pub fn session_name_for(socket: &Path) -> String {
    let dir = socket.parent();
    match (
        dir.and_then(Path::file_name),
        dir.and_then(Path::parent).and_then(Path::file_name),
    ) {
        (Some(name), Some(parent)) if parent == "sessions" => name.to_string_lossy().to_string(),
        _ => "default".to_string(),
    }
}

/// Every running Herdr session: the default socket plus `sessions/*/herdr.sock`.
/// An explicit socket replaces discovery entirely (no fallback when it is missing).
pub fn discover_herdr_sessions(explicit_socket: Option<&Path>) -> Vec<(String, PathBuf)> {
    if let Some(sock) = explicit_socket {
        return if sock.exists() {
            vec![(session_name_for(sock), sock.to_path_buf())]
        } else {
            Vec::new()
        };
    }
    let Some(config) = herdr_config_dir() else {
        return Vec::new();
    };
    let default = config.join("herdr.sock");
    let named = fs::read_dir(config.join("sessions"))
        .into_iter()
        .flatten()
        .flatten()
        .map(|entry| entry.path().join("herdr.sock"));
    std::iter::once(default)
        .chain(named)
        .filter(|sock| sock.exists())
        .map(|sock| (session_name_for(&sock), sock))
        .collect()
}

/// Herdr re-checks agent state well inside this window; the resync only repairs missed events.
const RESYNC_INTERVAL: Duration = Duration::from_secs(30);
const REQUEST_TIMEOUT: Duration = Duration::from_millis(1500);
const BASE_SUBSCRIPTIONS: [&str; 5] = [
    "pane.agent_detected",
    "pane.updated",
    "pane.created",
    "pane.closed",
    "pane.exited",
];

type BoxError = Box<dyn std::error::Error>;

fn str_field(v: &Value, key: &str) -> String {
    v[key].as_str().unwrap_or("").to_string()
}

/// Maps a Herdr pane/agent object to an `AgentInfo`; `None` when it has no pane id or agent.
pub fn agent_from_pane(pane: &Value, session_name: &str) -> Option<AgentInfo> {
    let pane_id = pane["pane_id"].as_str().filter(|p| !p.is_empty())?;
    let name = pane["agent"].as_str()?;
    let cwd = pane["cwd"].as_str().unwrap_or("~");
    let raw_status = pane["agent_status"].as_str().unwrap_or("unknown");
    let session_ref = session_ref_from(pane);
    let status = determine_effective_status(raw_status, name, session_ref.as_ref(), cwd);
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
            state_changed_at: current_unix_timestamp(),
            session_ref,
            state_change_seq: pane["state_change_seq"].as_u64(),
        }
        .sanitized(),
    )
}

/// One request/response round trip on a fresh connection.
fn request(socket_path: &Path, method: &str, params: Value) -> Result<Value, BoxError> {
    let mut stream = UnixStream::connect(socket_path)?;
    stream.set_read_timeout(Some(REQUEST_TIMEOUT))?;
    writeln!(
        stream,
        "{}",
        json!({ "id": method, "method": method, "params": params })
    )?;
    let mut reader = BufReader::new(stream);
    let mut line = String::new();
    read_bounded_line(&mut reader, &mut line, MAX_SOCKET_LINE_BYTES)?;
    let v: Value = serde_json::from_str(line.trim())?;
    if let Some(err) = v.get("error") {
        return Err(format!("{} failed: {}", method, err).into());
    }
    Ok(v)
}

pub fn fetch_agents_snapshot(
    socket_path: &Path,
    session_name: &str,
) -> Result<HashMap<String, AgentInfo>, BoxError> {
    let v = request(socket_path, "agent.list", json!({}))?;
    let items = v["result"]["agents"]
        .as_array()
        .map(Vec::as_slice)
        .unwrap_or(&[]);
    let agent_map = items
        .iter()
        .take(MAX_AGENTS_COUNT)
        .filter_map(|item| {
            agent_from_pane(item, session_name).or_else(|| {
                // agent.list entries are agents even when Herdr has no label for them.
                let mut labelled = item.clone();
                labelled["agent"] =
                    json!(item["terminal_title_stripped"].as_str().unwrap_or("agent"));
                agent_from_pane(&labelled, session_name)
            })
        })
        .map(|info| (info.pane_id.clone(), info))
        .collect();

    Ok(agent_map)
}

fn list_pane_ids(socket_path: &Path) -> Result<HashSet<String>, BoxError> {
    let v = request(socket_path, "pane.list", json!({}))?;
    Ok(v["result"]["panes"]
        .as_array()
        .map(Vec::as_slice)
        .unwrap_or(&[])
        .iter()
        .filter_map(|p| p["pane_id"].as_str())
        .map(str::to_string)
        .collect())
}

/// Opens the event stream. Herdr fixes the subscription set per connection (a second
/// `events.subscribe` resets it), and `pane.agent_status_changed` must be requested per pane.
fn subscribe(
    socket_path: &Path,
    pane_ids: &HashSet<String>,
) -> Result<BufReader<UnixStream>, BoxError> {
    let subscriptions: Vec<Value> = BASE_SUBSCRIPTIONS
        .iter()
        .map(|t| json!({ "type": t }))
        .chain(
            pane_ids
                .iter()
                .map(|p| json!({ "type": "pane.agent_status_changed", "pane_id": p })),
        )
        .collect();
    let mut stream = UnixStream::connect(socket_path)?;
    stream.set_read_timeout(Some(REQUEST_TIMEOUT))?;
    writeln!(
        stream,
        "{}",
        json!({
            "id": "event_sub",
            "method": "events.subscribe",
            "params": { "subscriptions": subscriptions }
        })
    )?;
    let mut reader = BufReader::new(stream);
    let mut line = String::new();
    read_bounded_line(&mut reader, &mut line, MAX_SOCKET_LINE_BYTES)?;
    let ack: Value = serde_json::from_str(line.trim())?;
    if ack["result"]["type"] != "subscription_started" {
        return Err(format!("subscription rejected: {}", line.trim()).into());
    }
    reader.get_ref().set_read_timeout(Some(RESYNC_INTERVAL))?;
    Ok(reader)
}

/// What the stream loop must do after applying one event.
#[derive(Debug, Default, PartialEq)]
pub struct EventEffect {
    /// The agent map changed and should be re-emitted.
    pub changed: bool,
    /// The event lacked detail (e.g. a newly detected agent); fetch a fresh snapshot.
    pub refresh: bool,
    /// A pane was created and needs its own status subscription.
    pub new_pane: Option<String>,
}

pub fn process_event_json(
    trimmed: &str,
    session_name: &str,
    agents_map: &mut HashMap<String, AgentInfo>,
) -> EventEffect {
    let mut effect = EventEffect::default();
    let Ok(v) = serde_json::from_str::<Value>(trimmed) else {
        return effect;
    };
    let Some(event) = v.get("event").and_then(|e| e.as_str()) else {
        return effect;
    };
    let data = v.get("data").unwrap_or(&Value::Null);
    let pane_key = |raw: &Value| {
        raw.as_str()
            .filter(|p| !p.is_empty())
            .map(|p| sanitize_field(p, MAX_ID_LEN))
    };

    match event {
        // Subscription events use the dotted name; regular events use underscores.
        "pane.agent_status_changed" | "pane_agent_status_changed" => {
            let new_status = data["agent_status"].as_str().unwrap_or("");
            if let (Some(key), false) = (pane_key(&data["pane_id"]), new_status.is_empty()) {
                if let Some(agent) = agents_map.get_mut(&key) {
                    let effective = determine_effective_status(
                        new_status,
                        &agent.name,
                        agent.session_ref.as_ref(),
                        &agent.cwd,
                    );
                    let sanitized_status = sanitize_field(&effective, MAX_STATUS_LEN);
                    if agent.status != sanitized_status {
                        agent.status = sanitized_status;
                        agent.state_changed_at = current_unix_timestamp();
                        effect.changed = true;
                    }
                } else if data["agent"].is_string() {
                    effect.refresh = true;
                }
            }
        }
        "pane_agent_detected" => {
            if let Some(key) = pane_key(&data["pane_id"]) {
                if data["released"].as_bool().unwrap_or(false) {
                    effect.changed = agents_map.remove(&key).is_some();
                } else if data["agent"].is_string() {
                    // The event carries no status, cwd or title; the snapshot has them.
                    effect.refresh = true;
                }
            }
        }
        "pane_created" | "pane_updated" => {
            let pane = &data["pane"];
            let Some(key) = pane_key(&pane["pane_id"]) else {
                return effect;
            };
            if event == "pane_created" {
                effect.new_pane = pane["pane_id"].as_str().map(str::to_string);
            }
            let existing = agents_map.get(&key);
            if let Some(mut info) = agent_from_pane(pane, session_name) {
                if let Some(existing) = existing.filter(|e| e.status == info.status) {
                    info.state_changed_at = existing.state_changed_at;
                }
                if existing != Some(&info)
                    && (existing.is_some() || agents_map.len() < MAX_AGENTS_COUNT)
                {
                    agents_map.insert(key, info);
                    effect.changed = true;
                }
            }
        }
        "pane_closed" | "pane_exited" => {
            if let Some(key) = pane_key(&data["pane_id"]) {
                effect.changed = agents_map.remove(&key).is_some();
            }
        }
        _ => {}
    }

    effect
}

/// Replaces `agents_map` with a fresh snapshot, keeping timestamps for unchanged statuses.
/// Returns whether anything changed.
fn resync(
    socket_path: &Path,
    session_name: &str,
    agents_map: &mut HashMap<String, AgentInfo>,
) -> Result<bool, BoxError> {
    let mut fresh = fetch_agents_snapshot(socket_path, session_name)?;
    for (pane_id, fresh_agent) in fresh.iter_mut() {
        if let Some(existing) = agents_map.get(pane_id) {
            if existing.status == fresh_agent.status {
                fresh_agent.state_changed_at = existing.state_changed_at;
            }
        }
    }
    if fresh == *agents_map {
        return Ok(false);
    }
    *agents_map = fresh;
    Ok(true)
}

/// Follows one Herdr session, calling `on_change` with the full agent map whenever it changes.
/// Returns when the server closes the connection.
pub fn stream_events_loop(
    socket_path: &Path,
    session_name: &str,
    mut agents_map: HashMap<String, AgentInfo>,
    once_mode: bool,
    on_change: &mut dyn FnMut(&HashMap<String, AgentInfo>),
) -> Result<(), BoxError> {
    on_change(&agents_map);
    if once_mode {
        return Ok(());
    }

    let mut line = String::new();
    loop {
        let pane_ids = list_pane_ids(socket_path)?;
        let mut reader = subscribe(socket_path, &pane_ids)?;
        log!(
            "subscribed to {} ({} panes)",
            socket_path.display(),
            pane_ids.len()
        );
        // Reconcile anything that changed before the subscription was live.
        if resync(socket_path, session_name, &mut agents_map)? {
            on_change(&agents_map);
        }
        let mut last_sync = Instant::now();

        loop {
            let mut effect = EventEffect::default();
            match read_bounded_line(&mut reader, &mut line, MAX_SOCKET_LINE_BYTES) {
                Ok(0) => {
                    log!("herdr closed the event stream ({})", socket_path.display());
                    return Ok(());
                }
                Ok(_) => {
                    effect = process_event_json(line.trim(), session_name, &mut agents_map);
                    if effect.changed {
                        on_change(&agents_map);
                    }
                }
                Err(ref e)
                    if e.kind() == std::io::ErrorKind::WouldBlock
                        || e.kind() == std::io::ErrorKind::TimedOut => {}
                Err(ref e) if e.kind() == std::io::ErrorKind::InvalidData => {
                    log!("skipping oversized Herdr socket line: {}", e);
                }
                Err(e) => return Err(Box::new(e)),
            }

            if effect.new_pane.is_some_and(|p| !pane_ids.contains(&p)) {
                break; // resubscribe with the new pane included
            }
            if effect.refresh || last_sync.elapsed() >= RESYNC_INTERVAL {
                last_sync = Instant::now();
                match resync(socket_path, session_name, &mut agents_map) {
                    Ok(true) => on_change(&agents_map),
                    Ok(false) => {}
                    Err(e) => log!("snapshot sync failed: {}", e),
                }
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::payload::make_agent;

    fn status_event(name: &str, pane_id: &str, status: &str) -> String {
        json!({
            "event": name,
            "data": { "agent": "agent-1", "pane_id": pane_id, "workspace_id": "w1", "agent_status": status }
        })
        .to_string()
    }

    #[test]
    fn test_process_event_pane_agent_status_changed() {
        let mut map = HashMap::new();
        let mut agent = make_agent("agent-1", "working", "w1:p1");
        agent.state_changed_at = 1;
        map.insert("w1:p1".to_string(), agent);

        // Per-pane subscriptions deliver the dotted name; regular events the underscore one.
        let effect = process_event_json(
            &status_event("pane.agent_status_changed", "w1:p1", "blocked"),
            "default",
            &mut map,
        );
        assert!(effect.changed);
        assert!(!effect.refresh);
        assert_eq!(map["w1:p1"].status, "blocked");
        assert!(map["w1:p1"].state_changed_at > 1);

        let effect = process_event_json(
            &status_event("pane_agent_status_changed", "w1:p1", "working"),
            "default",
            &mut map,
        );
        assert!(effect.changed);
        assert_eq!(map["w1:p1"].status, "working");

        // Same status does not trigger update or touch the timestamp
        map.get_mut("w1:p1").unwrap().state_changed_at = 42;
        let effect = process_event_json(
            &status_event("pane.agent_status_changed", "w1:p1", "working"),
            "default",
            &mut map,
        );
        assert!(!effect.changed);
        assert_eq!(map["w1:p1"].state_changed_at, 42);
    }

    #[test]
    fn test_process_event_status_for_unknown_agent_requests_refresh() {
        let mut map = HashMap::new();
        let effect = process_event_json(
            &status_event("pane.agent_status_changed", "w1:p9", "idle"),
            "default",
            &mut map,
        );
        assert_eq!(
            effect,
            EventEffect {
                refresh: true,
                ..Default::default()
            }
        );
        assert!(map.is_empty());
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
        assert!(process_event_json(update_json, "default", &mut map).changed);
        assert_eq!(map["w1:p1"].cwd, "/home/arch/new-dir");
        assert_eq!(map["w1:p1"].state_changed_at, 1710000000);

        // Update status: state_changed_at should be refreshed
        let status_change_json = update_json.replace("\"working\"", "\"done\"");
        assert!(process_event_json(&status_change_json, "default", &mut map).changed);
        assert_eq!(map["w1:p1"].status, "done");
        assert!(map["w1:p1"].state_changed_at > 1710000000);
    }

    #[test]
    fn test_process_event_pane_created_requests_subscription() {
        let mut map = HashMap::new();
        let created = json!({
            "event": "pane_created",
            "data": { "type": "pane_created", "pane": {
                "pane_id": "w1:p7", "workspace_id": "w1", "tab_id": "w1:t1",
                "focused": false, "agent_status": "unknown", "revision": 0
            }}
        });
        let effect = process_event_json(&created.to_string(), "default", &mut map);
        assert_eq!(effect.new_pane.as_deref(), Some("w1:p7"));
        assert!(!effect.changed, "a pane without an agent is not an agent");
        assert!(map.is_empty());
    }

    #[test]
    fn test_process_event_pane_agent_detected_and_released() {
        let mut map = HashMap::new();

        // Detection carries no status/cwd/title: ask for a snapshot instead of guessing.
        let detect_json = r#"{
            "event": "pane_agent_detected",
            "data": {
                "type": "pane_agent_detected",
                "pane_id": "w1:p5",
                "workspace_id": "w1",
                "agent": "codex"
            }
        }"#;
        let effect = process_event_json(detect_json, "default", &mut map);
        assert_eq!(
            effect,
            EventEffect {
                refresh: true,
                ..Default::default()
            }
        );
        assert!(map.is_empty());

        map.insert("w1:p5".to_string(), make_agent("codex", "idle", "w1:p5"));
        let release_json = r#"{
            "event": "pane_agent_detected",
            "data": {
                "type": "pane_agent_detected",
                "pane_id": "w1:p5",
                "workspace_id": "w1",
                "released": true,
                "final_status": "done"
            }
        }"#;
        assert!(process_event_json(release_json, "default", &mut map).changed);
        assert!(!map.contains_key("w1:p5"));
    }

    #[test]
    fn test_process_event_pane_closed() {
        let mut map = HashMap::new();
        map.insert(
            "w1:p1".to_string(),
            make_agent("agent-1", "working", "w1:p1"),
        );

        let closed_json = r#"{
            "event": "pane_closed",
            "data": {
                "pane_id": "w1:p1"
            }
        }"#;
        assert!(process_event_json(closed_json, "default", &mut map).changed);
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
                vec![0xF0, 0x9F],        // Split midway through 🦀
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

        assert!(process_event_json(&event.to_string(), "default", &mut map).changed);
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
        assert!(process_event_json(&close_event.to_string(), "default", &mut map).changed);
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
    #[test]
    fn test_session_name_for() {
        assert_eq!(
            session_name_for(Path::new("/c/herdr/herdr.sock")),
            "default"
        );
        assert_eq!(
            session_name_for(Path::new("/c/herdr/sessions/work/herdr.sock")),
            "work"
        );
        assert_eq!(session_name_for(Path::new("/tmp/custom.sock")), "default");
    }

    #[test]
    fn test_explicit_socket_has_no_fallback() {
        assert!(discover_herdr_sessions(Some(Path::new("/nonexistent/herdr.sock"))).is_empty());
    }
}
