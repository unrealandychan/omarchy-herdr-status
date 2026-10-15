//! Watches every Herdr session concurrently and merges their agents into one payload stream.

use std::collections::{BTreeMap, HashMap, HashSet};
use std::path::{Path, PathBuf};
use std::sync::mpsc::{self, RecvTimeoutError, Sender};
use std::sync::{Arc, Mutex};
use std::thread;
use std::time::{Duration, Instant};

use crate::herdr::{discover_herdr_sessions, fetch_agents_snapshot, stream_events_loop};
use crate::payload::{emit_payload, AgentInfo, StatusPayload};
use crate::standalone::detect_external_agents;
use crate::timers::{default_state_path, StateTimers};

/// How often new or restarted sessions are picked up.
const SCAN_INTERVAL: Duration = Duration::from_secs(5);
const RECONNECT_DELAY: Duration = Duration::from_millis(2500);

type AgentMap = HashMap<String, AgentInfo>;

enum Update {
    Agents { session: String, agents: AgentMap },
    Disconnected { session: String },
}

/// Connected sessions and their agents, keyed by session name.
#[derive(Default)]
struct Sessions {
    connected: BTreeMap<String, AgentMap>,
    timers: StateTimers,
    external: Vec<AgentInfo>,
}

impl Sessions {
    fn apply(&mut self, update: Update) {
        match update {
            Update::Agents { session, agents } => {
                self.connected.insert(session, agents);
            }
            Update::Disconnected { session } => {
                self.connected.remove(&session);
            }
        }
    }

    fn payload(&mut self) -> StatusPayload {
        let mut agents: Vec<AgentInfo> = self
            .connected
            .values()
            .flat_map(|m| m.values().cloned())
            .collect();
        let connected: HashSet<&str> = self.connected.keys().map(String::as_str).collect();
        self.timers.stamp(&mut agents, &connected);
        let mut payload = StatusPayload::new(!self.connected.is_empty(), agents);
        payload.external_agents = self.external.clone();
        payload
    }
}

/// Follows one session until its socket disappears, reconnecting after drops.
fn spawn_worker(
    name: String,
    socket: PathBuf,
    tx: Sender<Update>,
    running: Arc<Mutex<HashSet<String>>>,
) {
    thread::spawn(move || {
        loop {
            match fetch_agents_snapshot(&socket, &name) {
                Ok(initial) => {
                    let mut send = |agents: &AgentMap| {
                        let _ = tx.send(Update::Agents {
                            session: name.clone(),
                            agents: agents.clone(),
                        });
                    };
                    if let Err(e) = stream_events_loop(&socket, &name, initial, false, &mut send) {
                        log!("session {}: event stream dropped: {}", name, e);
                    }
                }
                Err(e) => log!("session {}: cannot query {}: {}", name, socket.display(), e),
            }
            let _ = tx.send(Update::Disconnected {
                session: name.clone(),
            });
            if !socket.exists() {
                break;
            }
            thread::sleep(RECONNECT_DELAY);
        }
        log!("session {}: socket gone, stopping", name);
        if let Ok(mut running) = running.lock() {
            running.remove(&name);
        }
    });
}

/// Streams merged status for all sessions forever.
pub fn run(explicit_socket: Option<&Path>, detect_external: bool) {
    let (tx, rx) = mpsc::channel();
    let running = Arc::new(Mutex::new(HashSet::new()));
    let mut sessions = Sessions {
        timers: StateTimers::load(default_state_path()),
        ..Default::default()
    };
    let mut last_emitted: Option<(bool, Vec<AgentInfo>, Vec<AgentInfo>)> = None;
    let mut last_scan: Option<Instant> = None;

    loop {
        if last_scan.is_none_or(|t| t.elapsed() >= SCAN_INTERVAL) {
            last_scan = Some(Instant::now());
            if detect_external {
                sessions.external = detect_external_agents();
            }
            let found = discover_herdr_sessions(explicit_socket);
            if let Ok(mut watched) = running.lock() {
                for (name, socket) in found {
                    if watched.insert(name.clone()) {
                        log!("session {}: watching {}", name, socket.display());
                        spawn_worker(name, socket, tx.clone(), Arc::clone(&running));
                    }
                }
            }
        }

        match rx.recv_timeout(SCAN_INTERVAL) {
            Ok(update) => sessions.apply(update),
            Err(RecvTimeoutError::Timeout) => {}
            Err(RecvTimeoutError::Disconnected) => unreachable!("monitor holds a sender"),
        }
        // Drain whatever else arrived so a burst is emitted once.
        while let Ok(update) = rx.try_recv() {
            sessions.apply(update);
        }

        let mut payload = sessions.payload();
        let current = (
            payload.connected,
            payload.agents.clone(),
            payload.external_agents.clone(),
        );
        if last_emitted.as_ref() != Some(&current) {
            emit_payload(&mut payload);
            last_emitted = Some(current);
        }
    }
}

/// Prints one merged snapshot of all sessions.
pub fn snapshot_once(explicit_socket: Option<&Path>, detect_external: bool) {
    let mut sessions = Sessions {
        timers: StateTimers::load(default_state_path()),
        ..Default::default()
    };
    for (name, socket) in discover_herdr_sessions(explicit_socket) {
        match fetch_agents_snapshot(&socket, &name) {
            Ok(agents) => sessions.apply(Update::Agents {
                session: name,
                agents,
            }),
            Err(e) => log!("session {}: cannot query {}: {}", name, socket.display(), e),
        }
    }
    if detect_external {
        sessions.external = detect_external_agents();
    }
    emit_payload(&mut sessions.payload());
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::payload::make_agent;

    fn agents(session: &str, panes: &[&str]) -> AgentMap {
        panes
            .iter()
            .map(|p| {
                let mut a = make_agent("pi", "idle", p);
                a.session = session.to_string();
                (p.to_string(), a)
            })
            .collect()
    }

    #[test]
    fn test_sessions_merge_same_pane_ids() {
        let mut sessions = Sessions::default();
        sessions.apply(Update::Agents {
            session: "default".into(),
            agents: agents("default", &["w1:p1"]),
        });
        sessions.apply(Update::Agents {
            session: "work".into(),
            agents: agents("work", &["w1:p1"]),
        });
        let payload = sessions.payload();
        assert!(payload.connected);
        assert_eq!(
            payload.agents.len(),
            2,
            "same pane id in two sessions is two agents"
        );
        assert_eq!(payload.summary.total, 2);

        sessions.apply(Update::Disconnected {
            session: "work".into(),
        });
        let payload = sessions.payload();
        assert_eq!(payload.agents.len(), 1);
        assert_eq!(payload.agents[0].session, "default");
    }

    #[test]
    fn test_sessions_connected_without_agents() {
        let mut sessions = Sessions::default();
        assert!(!sessions.payload().connected);
        sessions.apply(Update::Agents {
            session: "default".into(),
            agents: AgentMap::new(),
        });
        assert!(sessions.payload().connected);
    }
}
