//! Opt-in detection of coding agents running outside Herdr (`--detect-external`).
//!
//! The bridge cannot know these processes' state, so they are reported with status
//! `unknown` in a separate `external_agents` list and never counted in the summary.

use std::collections::HashMap;
use std::fs;
use std::path::Path;

use crate::payload::{current_unix_timestamp, AgentInfo, MAX_AGENTS_COUNT};

const KNOWN_AGENTS: [&str; 6] = ["claude", "codex", "opencode", "gemini", "pi", "omp"];
const SCRIPT_RUNTIMES: [&str; 3] = ["node", "bun", "deno"];

struct Process {
    ppid: u32,
    agent: String,
    cwd: String,
}

/// Agent name for a process: its `comm`, or for script runtimes the script's basename.
fn agent_name(comm: &str, cmdline: &[u8]) -> Option<String> {
    let basename = |s: &str| Path::new(s).file_name()?.to_str().map(str::to_string);
    let candidate = if SCRIPT_RUNTIMES.contains(&comm) {
        let script = cmdline.split(|&b| b == 0).nth(1)?;
        basename(std::str::from_utf8(script).ok()?)?
    } else {
        comm.to_string()
    };
    KNOWN_AGENTS
        .contains(&candidate.as_str())
        .then_some(candidate)
}

fn parent_pid(stat: &str) -> Option<u32> {
    // Format: "pid (comm) state ppid ..."; comm may contain spaces or parentheses.
    stat.rsplit_once(") ")?
        .1
        .split_whitespace()
        .nth(1)?
        .parse()
        .ok()
}

fn inside_herdr(environ: &[u8]) -> bool {
    environ
        .split(|&b| b == 0)
        .any(|var| var.starts_with(b"HERDR_PANE_ID="))
}

fn read_process(proc_dir: &Path) -> Option<Process> {
    let comm = fs::read_to_string(proc_dir.join("comm")).ok()?;
    let agent = agent_name(comm.trim(), &fs::read(proc_dir.join("cmdline")).ok()?)?;
    // Unreadable environ means another user's process: not ours to report.
    if inside_herdr(&fs::read(proc_dir.join("environ")).ok()?) {
        return None;
    }
    Some(Process {
        ppid: parent_pid(&fs::read_to_string(proc_dir.join("stat")).ok()?)?,
        agent,
        cwd: fs::read_link(proc_dir.join("cwd"))
            .map(|p| p.to_string_lossy().to_string())
            .unwrap_or_else(|_| "~".to_string()),
    })
}

pub fn detect_external_agents() -> Vec<AgentInfo> {
    let processes: HashMap<u32, Process> = fs::read_dir("/proc")
        .into_iter()
        .flatten()
        .flatten()
        .filter_map(|entry| {
            let pid = entry.file_name().to_str()?.parse::<u32>().ok()?;
            Some((pid, read_process(&entry.path())?))
        })
        .collect();

    let mut detected: Vec<AgentInfo> = processes
        .iter()
        // Helpers spawned by an agent (same CLI, child process) are part of that agent.
        .filter(|(_, p)| {
            processes
                .get(&p.ppid)
                .is_none_or(|parent| parent.agent != p.agent)
        })
        .map(|(pid, p)| {
            AgentInfo {
                name: p.agent.clone(),
                status: "unknown".to_string(),
                pane_id: format!("pid:{}", pid),
                workspace_id: String::new(),
                tab_id: String::new(),
                title: format!("{} (outside Herdr)", p.agent),
                cwd: p.cwd.clone(),
                focused: false,
                source: "system".to_string(),
                session: "system".to_string(),
                state_changed_at: current_unix_timestamp(),
                ..Default::default()
            }
            .sanitized()
        })
        .collect();
    detected.sort_by(|a, b| a.name.cmp(&b.name).then_with(|| a.pane_id.cmp(&b.pane_id)));
    detected.truncate(MAX_AGENTS_COUNT);
    detected
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_agent_name() {
        assert_eq!(
            agent_name("claude", b"claude\0--resume\0"),
            Some("claude".into())
        );
        assert_eq!(
            agent_name("node", b"node\0/usr/lib/node_modules/.bin/gemini\0"),
            Some("gemini".into())
        );
        assert_eq!(agent_name("node", b"node\0/srv/app/server.js\0"), None);
        assert_eq!(agent_name("bash", b"bash\0"), None);
    }

    #[test]
    fn test_parent_pid_handles_odd_comm() {
        assert_eq!(parent_pid("1234 (claude) S 77 1234 1234 0"), Some(77));
        assert_eq!(parent_pid("1234 (we ird) name) S 88 1 1 0"), Some(88));
    }

    #[test]
    fn test_inside_herdr() {
        assert!(inside_herdr(b"PATH=/usr/bin\0HERDR_PANE_ID=w1:p1\0"));
        assert!(!inside_herdr(b"PATH=/usr/bin\0NOT_HERDR_PANE_ID=x\0"));
    }
}
