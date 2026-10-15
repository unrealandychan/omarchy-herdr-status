//! Tracks how long each agent has been in its current status, across bridge restarts.
//!
//! Herdr reports no timestamps, so `state_changed_at` is "first time the bridge saw this
//! status". Persisting it to the runtime dir keeps timers running through reconnects,
//! shell reloads and crashes.

use serde::{Deserialize, Serialize};
use std::collections::{HashMap, HashSet};
use std::env;
use std::fs;
use std::path::{Path, PathBuf};

use crate::payload::{current_unix_timestamp, AgentInfo};

const MAX_ENTRIES: usize = 512;

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
struct Entry {
    session: String,
    pane_id: String,
    status: String,
    since: u64,
    seq: Option<u64>,
    /// Restored entries are trusted only once Herdr's state counter confirms them.
    #[serde(skip, default)]
    verified: bool,
}

#[derive(Debug, Default)]
pub struct StateTimers {
    entries: HashMap<(String, String), Entry>,
    path: Option<PathBuf>,
}

/// `$XDG_RUNTIME_DIR/herdr-status/state.json` (tmpfs, cleared at logout).
pub fn default_state_path() -> Option<PathBuf> {
    env::var_os("XDG_RUNTIME_DIR").map(|dir| PathBuf::from(dir).join("herdr-status/state.json"))
}

impl StateTimers {
    /// Loads persisted timers; a missing or unreadable file starts empty.
    pub fn load(path: Option<PathBuf>) -> Self {
        let entries = path
            .as_deref()
            .and_then(|p| fs::read(p).ok())
            .and_then(|bytes| serde_json::from_slice::<Vec<Entry>>(&bytes).ok())
            .unwrap_or_default()
            .into_iter()
            .map(|e| ((e.session.clone(), e.pane_id.clone()), e))
            .collect();
        Self { entries, path }
    }

    /// Sets `state_changed_at` on Herdr agents and forgets panes that vanished from a
    /// connected session. Persists when anything changed.
    pub fn stamp(&mut self, agents: &mut [AgentInfo], connected_sessions: &HashSet<&str>) {
        let now = current_unix_timestamp();
        let mut changed = false;
        let mut seen = HashSet::new();

        for agent in agents.iter_mut().filter(|a| a.source == "herdr") {
            let key = (agent.session.clone(), agent.pane_id.clone());
            let entry = self.entries.entry(key.clone()).or_insert_with(|| {
                changed = true;
                Entry {
                    session: key.0.clone(),
                    pane_id: key.1.clone(),
                    status: agent.status.clone(),
                    since: now,
                    seq: agent.state_change_seq,
                    verified: true,
                }
            });
            let seq_matches = match (entry.seq, agent.state_change_seq) {
                (Some(old), Some(new)) => old == new,
                _ => true,
            };
            let same_state = entry.status == agent.status && (entry.verified || seq_matches);
            if !same_state {
                entry.status = agent.status.clone();
                entry.since = now;
                changed = true;
            }
            entry.verified = true;
            if agent.state_change_seq.is_some() && entry.seq != agent.state_change_seq {
                entry.seq = agent.state_change_seq;
                changed = true;
            }
            agent.state_changed_at = entry.since;
            seen.insert(key);
        }

        let before = self.entries.len();
        self.entries
            .retain(|key, _| seen.contains(key) || !connected_sessions.contains(key.0.as_str()));
        if self.entries.len() > MAX_ENTRIES {
            let mut oldest: Vec<_> = self
                .entries
                .iter()
                .map(|(k, e)| (e.since, k.clone()))
                .collect();
            oldest.sort();
            for (_, key) in oldest.into_iter().take(self.entries.len() - MAX_ENTRIES) {
                self.entries.remove(&key);
            }
        }
        if changed || self.entries.len() != before {
            self.save();
        }
    }

    fn save(&self) {
        let Some(path) = self.path.as_deref() else {
            return;
        };
        if let Err(e) = write_atomic(path, &self.entries.values().collect::<Vec<_>>()) {
            log!("cannot persist timers to {}: {}", path.display(), e);
        }
    }
}

fn write_atomic(path: &Path, entries: &[&Entry]) -> std::io::Result<()> {
    let dir = path.parent().unwrap_or(Path::new("."));
    fs::create_dir_all(dir)?;
    let tmp = dir.join(format!(".state.{}.tmp", std::process::id()));
    fs::write(&tmp, serde_json::to_vec(entries)?)?;
    fs::rename(&tmp, path)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::payload::make_agent;

    fn agent(session: &str, pane: &str, status: &str, seq: Option<u64>) -> AgentInfo {
        let mut a = make_agent("pi", status, pane);
        a.session = session.to_string();
        a.state_change_seq = seq;
        a
    }

    fn connected(s: &[&'static str]) -> HashSet<&'static str> {
        s.iter().copied().collect()
    }

    #[test]
    fn test_keeps_since_while_status_unchanged() {
        let mut timers = StateTimers::default();
        let mut agents = vec![agent("default", "w1:p1", "blocked", Some(3))];
        timers.stamp(&mut agents, &connected(&["default"]));
        let first = agents[0].state_changed_at;
        timers
            .entries
            .get_mut(&("default".into(), "w1:p1".into()))
            .unwrap()
            .since = first - 300;

        let mut again = vec![agent("default", "w1:p1", "blocked", Some(3))];
        timers.stamp(&mut again, &connected(&["default"]));
        assert_eq!(again[0].state_changed_at, first - 300);

        let mut changed = vec![agent("default", "w1:p1", "working", Some(4))];
        timers.stamp(&mut changed, &connected(&["default"]));
        assert!(changed[0].state_changed_at >= first);
    }

    #[test]
    fn test_survives_restart_and_detects_round_trips() {
        let dir = env::temp_dir().join(format!("herdr-status-timers-{}", std::process::id()));
        let path = dir.join("state.json");
        let _ = fs::remove_dir_all(&dir);

        let mut timers = StateTimers::load(Some(path.clone()));
        let mut agents = vec![
            agent("default", "w1:p1", "blocked", Some(3)),
            agent("work", "w1:p1", "idle", Some(8)),
        ];
        timers.stamp(&mut agents, &connected(&["default", "work"]));
        for e in timers.entries.values_mut() {
            e.since -= 600;
        }
        timers.save();

        // Restarted bridge: same status and counter keeps the timer; a counter that moved
        // (working -> idle -> working... while we were down) restarts it.
        let mut restarted = StateTimers::load(Some(path.clone()));
        let mut agents = vec![
            agent("default", "w1:p1", "blocked", Some(3)),
            agent("work", "w1:p1", "idle", Some(10)),
        ];
        restarted.stamp(&mut agents, &connected(&["default", "work"]));
        let now = current_unix_timestamp();
        assert!(
            now - agents[0].state_changed_at >= 600,
            "unchanged agent keeps its timer"
        );
        assert!(
            now - agents[1].state_changed_at < 600,
            "round trip restarts the timer"
        );
        let _ = fs::remove_dir_all(&dir);
    }

    #[test]
    fn test_forgets_closed_panes_but_keeps_disconnected_sessions() {
        let mut timers = StateTimers::default();
        let mut agents = vec![
            agent("default", "w1:p1", "idle", None),
            agent("work", "w1:p1", "idle", None),
        ];
        timers.stamp(&mut agents, &connected(&["default", "work"]));

        // "work" disconnected, default's pane closed.
        timers.stamp(&mut [], &connected(&["default"]));
        assert!(timers
            .entries
            .contains_key(&("work".into(), "w1:p1".into())));
        assert!(!timers
            .entries
            .contains_key(&("default".into(), "w1:p1".into())));
    }

    #[test]
    fn test_ignores_standalone_agents() {
        let mut timers = StateTimers::default();
        let mut agents = vec![make_agent("claude", "unknown", "pid:42")];
        agents[0].source = "system".into();
        timers.stamp(&mut agents, &connected(&[]));
        assert!(timers.entries.is_empty());
    }
}
