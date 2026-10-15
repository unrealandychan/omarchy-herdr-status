use crate::payload::{current_unix_timestamp, AgentInfo};

pub fn get_demo_agents() -> Vec<AgentInfo> {
    let now = current_unix_timestamp();
    vec![
        AgentInfo {
            name: "pi".to_string(),
            status: "blocked".to_string(),
            pane_id: "w1:p1".to_string(),
            workspace_id: "w1".to_string(),
            tab_id: "w1:t1".to_string(),
            title: "Drop legacy migration confirmation".to_string(),
            cwd: "~/projects/billing-api".to_string(),
            focused: false,
            source: "herdr".to_string(),
            session: "default".to_string(),
            state_changed_at: now.saturating_sub(120),
            ..Default::default()
        },
        AgentInfo {
            name: "codex".to_string(),
            status: "done".to_string(),
            pane_id: "w1:p2".to_string(),
            workspace_id: "w1".to_string(),
            tab_id: "w1:t1".to_string(),
            title: "Upgrade search index algorithm".to_string(),
            cwd: "~/projects/docs-site".to_string(),
            focused: false,
            source: "herdr".to_string(),
            session: "default".to_string(),
            state_changed_at: now.saturating_sub(300),
            ..Default::default()
        },
        AgentInfo {
            name: "claude".to_string(),
            status: "working".to_string(),
            pane_id: "w2:p1".to_string(),
            workspace_id: "w2".to_string(),
            tab_id: "w2:t1".to_string(),
            title: "Rewrite checkout receipt formatting pipeline".to_string(),
            cwd: "~/projects/checkout-service".to_string(),
            focused: false,
            source: "herdr".to_string(),
            session: "default".to_string(),
            state_changed_at: now.saturating_sub(60),
            ..Default::default()
        },
        AgentInfo {
            name: "pi".to_string(),
            status: "idle".to_string(),
            pane_id: "w2:p2".to_string(),
            workspace_id: "w2".to_string(),
            tab_id: "w2:t2".to_string(),
            title: "Token names for design palette".to_string(),
            cwd: "~/projects/design-tokens".to_string(),
            focused: true,
            source: "herdr".to_string(),
            session: "default".to_string(),
            state_changed_at: now.saturating_sub(900),
            ..Default::default()
        },
    ]
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::payload::compute_summary;

    #[test]
    fn test_demo_agents() {
        let demo = get_demo_agents();
        assert_eq!(demo.len(), 4);
        let summary = compute_summary(&demo, true);
        assert_eq!(summary.primary_status, "blocked");
        assert_eq!(summary.blocked, 1);
        assert_eq!(summary.done, 1);
        assert_eq!(summary.working, 1);
        assert_eq!(summary.idle, 1);
    }
}
