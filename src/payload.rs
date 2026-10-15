use crate::pi::SessionRef;
use crate::status::normalize_status;
use serde::{Deserialize, Serialize};
use std::io::Write;
use std::time::{SystemTime, UNIX_EPOCH};

pub const MAX_SOCKET_LINE_BYTES: usize = 64 * 1024;

pub const MAX_AGENTS_COUNT: usize = 256;

pub const MAX_OUTPUT_LINE_BYTES: usize = 128 * 1024;

pub const MAX_NAME_LEN: usize = 128;

pub const MAX_TITLE_LEN: usize = 256;

pub const MAX_STATUS_LEN: usize = 32;

pub const MAX_ID_LEN: usize = 64;

pub const MAX_CWD_LEN: usize = 256;

pub const MAX_SESSION_LEN: usize = 128;

pub fn sanitize_field(s: &str, max_len: usize) -> String {
    let mut out = String::new();
    for c in s.chars().take(max_len) {
        if !c.is_control() || c == ' ' {
            out.push(c);
        }
    }
    out
}

#[derive(Debug, Clone, Default, PartialEq, Serialize, Deserialize)]
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
    #[serde(default = "default_session")]
    pub session: String,
    #[serde(default = "current_unix_timestamp")]
    pub state_changed_at: u64,
    /// Transcript reference used to refine Pi/OMP status on later events; not emitted.
    #[serde(skip)]
    pub session_ref: Option<SessionRef>,
}

impl AgentInfo {
    /// Strips control characters and bounds every string field.
    pub fn sanitized(self) -> Self {
        Self {
            name: sanitize_field(&self.name, MAX_NAME_LEN),
            status: sanitize_field(&self.status, MAX_STATUS_LEN),
            pane_id: sanitize_field(&self.pane_id, MAX_ID_LEN),
            workspace_id: sanitize_field(&self.workspace_id, MAX_ID_LEN),
            tab_id: sanitize_field(&self.tab_id, MAX_ID_LEN),
            title: sanitize_field(&self.title, MAX_TITLE_LEN),
            cwd: sanitize_field(&self.cwd, MAX_CWD_LEN),
            source: sanitize_field(&self.source, MAX_NAME_LEN),
            session: sanitize_field(&self.session, MAX_SESSION_LEN),
            ..self
        }
    }
}

pub fn current_unix_timestamp() -> u64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_secs())
        .unwrap_or(0)
}

pub fn default_session() -> String {
    "default".to_string()
}

pub fn sort_agents_by_priority(agents: &mut [AgentInfo]) {
    agents.sort_by(|a, b| {
        let rank = |status: &str| match normalize_status(status) {
            "blocked" => 0,
            "done" => 1,
            "working" => 2,
            "idle" => 3,
            _ => 4,
        };
        rank(&a.status)
            .cmp(&rank(&b.status))
            .then_with(|| a.name.cmp(&b.name))
            .then_with(|| a.pane_id.cmp(&b.pane_id))
    });
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

impl StatusPayload {
    pub fn new(connected: bool, agents: Vec<AgentInfo>) -> Self {
        let summary = compute_summary(&agents, connected);
        Self {
            connected,
            agents,
            summary,
        }
    }
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
        match normalize_status(&a.status) {
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

pub fn emit_payload(payload: &mut StatusPayload) {
    let stdout = std::io::stdout();
    let mut handle = stdout.lock();
    if !emit_payload_to(payload, &mut handle) {
        // Downstream reader (e.g. Quickshell) closed the pipe or stdout is unwritable.
        // Exit cleanly instead of panicking on BrokenPipe with SIGABRT.
        std::process::exit(0);
    }
}

pub fn emit_payload_to<W: Write>(payload: &mut StatusPayload, writer: &mut W) -> bool {
    // Sort first so truncation drops the least urgent agents. The summary keeps the full counts.
    sort_agents_by_priority(&mut payload.agents);
    payload.agents.truncate(MAX_AGENTS_COUNT);
    if let Ok(mut serialized) = serde_json::to_string(payload) {
        if serialized.len() > MAX_OUTPUT_LINE_BYTES {
            while payload.agents.len() > 10 && serialized.len() > MAX_OUTPUT_LINE_BYTES {
                payload.agents.truncate(payload.agents.len() / 2);
                if let Ok(s) = serde_json::to_string(payload) {
                    serialized = s;
                } else {
                    break;
                }
            }
        }
        if serialized.len() <= MAX_OUTPUT_LINE_BYTES {
            if writeln!(writer, "{}", serialized).is_err() || writer.flush().is_err() {
                return false;
            }
        } else {
            let minimal = StatusPayload {
                connected: payload.connected,
                agents: Vec::new(),
                summary: payload.summary.clone(),
            };
            if let Ok(min_ser) = serde_json::to_string(&minimal) {
                if writeln!(writer, "{}", min_ser).is_err() || writer.flush().is_err() {
                    return false;
                }
            }
        }
    }
    true
}

#[cfg(test)]
pub fn make_agent(name: &str, status: &str, pane_id: &str) -> AgentInfo {
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
        session: "default".to_string(),
        state_changed_at: 0,
        ..Default::default()
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::Value;

    #[test]
    fn test_sort_agents_by_priority() {
        let mut agents = vec![
            make_agent("agent-idle", "idle", "w1:p1"),
            make_agent("agent-blocked", "blocked", "w1:p2"),
            make_agent("agent-working", "working", "w1:p3"),
            make_agent("agent-done", "done", "w1:p4"),
        ];
        sort_agents_by_priority(&mut agents);
        assert_eq!(agents[0].status, "blocked");
        assert_eq!(agents[1].status, "done");
        assert_eq!(agents[2].status, "working");
        assert_eq!(agents[3].status, "idle");
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
    fn test_status_payload_roundtrip() {
        let mut agent = make_agent("pi", "blocked", "wG:p1");
        agent.state_changed_at = 1712345678;
        let agents = vec![agent];
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
        assert_eq!(parsed["agents"][0]["state_changed_at"], 1712345678);

        let roundtrip: StatusPayload =
            serde_json::from_str(&serialized).expect("Deserialization failed");
        assert_eq!(roundtrip.agents[0].state_changed_at, 1712345678);
    }

    #[test]
    fn test_agent_info_deserialize_default_timestamp() {
        let json = r#"{
            "name": "pi",
            "status": "working",
            "pane_id": "w1:p1",
            "workspace_id": "w1",
            "tab_id": "w1:t1",
            "title": "pi",
            "cwd": "/home/arch",
            "focused": false,
            "source": "herdr"
        }"#;
        let agent: AgentInfo = serde_json::from_str(json).expect("Deserialization failed");
        assert_eq!(agent.session, "default");
        assert!(agent.state_changed_at > 0);
    }

    #[test]
    fn test_emit_payload_to_success() {
        let mut payload = StatusPayload {
            connected: true,
            agents: vec![make_agent("pi", "working", "w1:p1")],
            summary: compute_summary(&[], true),
        };
        let mut buffer = Vec::new();
        let ok = emit_payload_to(&mut payload, &mut buffer);
        assert!(ok);
        let output = String::from_utf8(buffer).expect("Valid utf8");
        assert!(output.contains("\"name\":\"pi\""));
        assert!(output.ends_with('\n'));
    }

    #[test]
    fn test_emit_payload_to_broken_pipe() {
        struct FailingWriter;
        impl Write for FailingWriter {
            fn write(&mut self, _buf: &[u8]) -> std::io::Result<usize> {
                Err(std::io::Error::new(
                    std::io::ErrorKind::BrokenPipe,
                    "broken pipe",
                ))
            }
            fn flush(&mut self) -> std::io::Result<()> {
                Err(std::io::Error::new(
                    std::io::ErrorKind::BrokenPipe,
                    "broken pipe",
                ))
            }
        }

        let mut payload = StatusPayload {
            connected: true,
            agents: vec![make_agent("pi", "working", "w1:p1")],
            summary: compute_summary(&[], true),
        };
        let mut writer = FailingWriter;
        let ok = emit_payload_to(&mut payload, &mut writer);
        assert!(!ok);
    }

    #[test]
    fn test_sanitize_field() {
        let long_str = "a".repeat(500);
        let sanitized = sanitize_field(&long_str, 50);
        assert_eq!(sanitized.len(), 50);

        let with_ctrl = "hello\x00\x07world\n";
        let cleaned = sanitize_field(with_ctrl, 50);
        assert_eq!(cleaned, "helloworld");
    }

    #[test]
    fn test_emit_payload_to_bounds_oversized() {
        let mut many_agents = Vec::new();
        for i in 0..500 {
            many_agents.push(make_agent(
                &format!("agent_{}", i),
                "working",
                &format!("pane_{}", i),
            ));
        }
        let mut payload = StatusPayload {
            connected: true,
            agents: many_agents,
            summary: compute_summary(&[], true),
        };
        let mut buffer = Vec::new();
        let ok = emit_payload_to(&mut payload, &mut buffer);
        assert!(ok);
        assert!(buffer.len() <= MAX_OUTPUT_LINE_BYTES);
        assert!(payload.agents.len() <= MAX_AGENTS_COUNT);
    }

    #[test]
    fn test_sort_agents_priority_with_waiting_and_prompt() {
        let mut agents = vec![
            make_agent("agent-idle", "idle", "w1:p1"),
            make_agent("agent-waiting", "waiting", "w1:p2"),
            make_agent("agent-prompt", "prompt", "w1:p3"),
            make_agent("agent-working", "working", "w1:p4"),
        ];
        sort_agents_by_priority(&mut agents);
        // Both "waiting" and "prompt" map to rank 0 (blocked)
        assert!(agents[0].status == "waiting" || agents[0].status == "prompt");
        assert!(agents[1].status == "waiting" || agents[1].status == "prompt");
        assert_eq!(agents[2].status, "working");
        assert_eq!(agents[3].status, "idle");
    }

    #[test]
    fn test_compute_summary_counts_waiting_as_blocked() {
        let agents = vec![
            make_agent("pi", "waiting", "w1:p1"),
            make_agent("claude", "prompt", "w1:p2"),
            make_agent("codex", "working", "w1:p3"),
        ];
        let summary = compute_summary(&agents, true);
        assert_eq!(summary.blocked, 2);
        assert_eq!(summary.working, 1);
        assert_eq!(summary.primary_status, "blocked");
        assert_eq!(summary.status_color, "urgent");
    }
    #[test]
    fn test_emit_payload_truncation_keeps_most_urgent() {
        let mut agents: Vec<AgentInfo> = (0..MAX_AGENTS_COUNT + 10)
            .map(|i| make_agent(&format!("idle_{:03}", i), "idle", &format!("p{}", i)))
            .collect();
        agents.push(make_agent("zz_blocked", "blocked", "p_blocked"));
        let mut payload = StatusPayload::new(true, agents);
        let mut buffer = Vec::new();
        assert!(emit_payload_to(&mut payload, &mut buffer));
        let parsed: Value = serde_json::from_slice(&buffer).unwrap();
        assert_eq!(parsed["agents"][0]["name"], "zz_blocked");
        assert_eq!(parsed["agents"].as_array().unwrap().len(), MAX_AGENTS_COUNT);
        // Summary still reports every agent, not just the emitted ones.
        assert_eq!(parsed["summary"]["total"], MAX_AGENTS_COUNT + 11);
        assert_eq!(parsed["summary"]["blocked"], 1);
    }
}
