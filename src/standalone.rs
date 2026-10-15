use std::collections::HashSet;
use std::fs;

use crate::payload::{current_unix_timestamp, AgentInfo, MAX_AGENTS_COUNT};

pub fn detect_standalone_agents() -> Vec<AgentInfo> {
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

                    if detected.len() < MAX_AGENTS_COUNT {
                        let info = AgentInfo {
                            name: comm_trim.to_string(),
                            status: "working".to_string(),
                            pane_id: format!("pid:{}", pid),
                            workspace_id: "system".to_string(),
                            tab_id: "system".to_string(),
                            title: format!("{} (system)", comm_trim),
                            cwd,
                            focused: false,
                            source: "system".to_string(),
                            session: "system".to_string(),
                            state_changed_at: current_unix_timestamp(),
                        }
                        .sanitized();
                        detected.push(info);
                    }
                }
            }
        }
    }

    detected
}
