use crate::pi::{inspect_session_tail, locate_pi_session_in, pi_sessions_root, SessionRef};

pub fn normalize_status(raw: &str) -> &'static str {
    match raw.trim().to_lowercase().as_str() {
        "blocked" | "waiting" | "prompt" | "input" | "needs_input" | "permission" | "confirm" => {
            "blocked"
        }
        "working" | "busy" | "running" | "thinking" | "generating" => "working",
        "done" | "completed" | "finished" => "done",
        "idle" | "ready" => "idle",
        _ => "unknown",
    }
}

pub fn determine_effective_status(
    raw_status: &str,
    agent_name: &str,
    session: Option<&SessionRef>,
    cwd: &str,
) -> String {
    let norm = normalize_status(raw_status);
    // Real-time Herdr "working" status is authoritative; do not downgrade active turns.
    if norm == "working" {
        return "working".to_string();
    }
    // If Herdr already explicitly flagged the agent as blocked, preserve it.
    if norm == "blocked" {
        return "blocked".to_string();
    }

    // Inspect session for Pi/OMP agents when Herdr reports idle, prompt, or unknown
    let is_pi_or_omp =
        agent_name.eq_ignore_ascii_case("pi") || agent_name.eq_ignore_ascii_case("omp");

    if is_pi_or_omp {
        let path_to_inspect =
            pi_sessions_root().and_then(|root| locate_pi_session_in(&root, session, cwd));

        if let Some(path) = path_to_inspect {
            if let Some(override_status) = inspect_session_tail(&path) {
                if override_status == "blocked" {
                    return "blocked".to_string();
                } else if override_status == "working" && norm == "idle" {
                    return "working".to_string();
                } else if override_status == "done" && norm == "idle" {
                    return "done".to_string();
                }
            }
        }
    }

    norm.to_string()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_normalize_status() {
        assert_eq!(normalize_status("blocked"), "blocked");
        assert_eq!(normalize_status("WAITING"), "blocked");
        assert_eq!(normalize_status("prompt"), "blocked");
        assert_eq!(normalize_status("needs_input"), "blocked");
        assert_eq!(normalize_status("permission"), "blocked");
        assert_eq!(normalize_status("confirm"), "blocked");
        assert_eq!(normalize_status("input"), "blocked");

        assert_eq!(normalize_status("working"), "working");
        assert_eq!(normalize_status("BUSY"), "working");
        assert_eq!(normalize_status("running"), "working");
        assert_eq!(normalize_status("thinking"), "working");
        assert_eq!(normalize_status("generating"), "working");

        assert_eq!(normalize_status("done"), "done");
        assert_eq!(normalize_status("completed"), "done");
        assert_eq!(normalize_status("finished"), "done");

        assert_eq!(normalize_status("idle"), "idle");
        assert_eq!(normalize_status("ready"), "idle");

        assert_eq!(normalize_status("other_unexpected"), "unknown");
    }

    #[test]
    fn test_determine_effective_status_precedence() {
        // Working takes precedence over transcript
        assert_eq!(
            determine_effective_status("working", "pi", None, "/home/arch"),
            "working"
        );
        // Explicit blocked remains blocked
        assert_eq!(
            determine_effective_status("blocked", "pi", None, "/home/arch"),
            "blocked"
        );
        // Raw waiting normalizes to blocked
        assert_eq!(
            determine_effective_status("waiting", "pi", None, "/home/arch"),
            "blocked"
        );
        assert_eq!(
            determine_effective_status("prompt", "claude", None, "/home/arch"),
            "blocked"
        );
        // Idle without session remains idle
        assert_eq!(
            determine_effective_status("idle", "pi", None, "/nonexistent/path"),
            "idle"
        );
    }
}
