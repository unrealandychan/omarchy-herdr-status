use serde_json::Value;
use std::env;
use std::fs;
use std::io::{BufRead, BufReader, Seek, SeekFrom};
use std::path::{Path, PathBuf};

pub fn resolve_path(p: &str) -> PathBuf {
    if p.starts_with("~/") {
        if let Ok(home) = env::var("HOME") {
            return PathBuf::from(home).join(&p[2..]);
        }
    }
    PathBuf::from(p)
}

pub fn is_interactive_tool(tool_name: &str) -> bool {
    let lower = tool_name.trim().to_lowercase();
    matches!(
        lower.as_str(),
        "ask"
            | "goal_question"
            | "goal_questionnaire"
            | "propose_goal_draft"
            | "confirm"
            | "prompt_user"
            | "user_input"
    ) || lower.starts_with("ask_")
        || lower.starts_with("question_")
}

pub fn inspect_session_lines(lines: &[String]) -> Option<&'static str> {
    let mut pending_ask_question = false;
    let mut pending_tool = false;
    let mut last_assistant_text: Option<String> = None;
    let mut session_exited = false;

    for line in lines {
        let Ok(v) = serde_json::from_str::<Value>(line) else {
            continue;
        };

        let msg_type = v.get("type").and_then(|t| t.as_str());
        if msg_type == Some("message") {
            if let Some(msg) = v.get("message") {
                let role = msg.get("role").and_then(|r| r.as_str());
                if role == Some("assistant") {
                    if let Some(content) = msg.get("content").and_then(|c| c.as_array()) {
                        for item in content {
                            let item_type = item.get("type").and_then(|t| t.as_str());
                            if item_type == Some("text") {
                                if let Some(txt) = item.get("text").and_then(|t| t.as_str()) {
                                    last_assistant_text = Some(txt.to_string());
                                    pending_tool = false;
                                    pending_ask_question = false;
                                }
                            } else if item_type == Some("toolCall") {
                                let name = item.get("name").and_then(|n| n.as_str()).unwrap_or("");
                                pending_tool = true;
                                if is_interactive_tool(name) {
                                    pending_ask_question = true;
                                }
                            }
                        }
                    }
                } else if role == Some("toolResult") {
                    pending_tool = false;
                    pending_ask_question = false;
                }
            }
        } else if msg_type == Some("custom") {
            let c_type = v.get("customType").and_then(|c| c.as_str());
            if c_type == Some("session_exit") {
                session_exited = true;
                pending_tool = false;
                pending_ask_question = false;
            } else if c_type == Some("tool_execution_start") {
                if let Some(data) = v.get("data") {
                    let tool_name = data.get("toolName").and_then(|t| t.as_str()).unwrap_or("");
                    pending_tool = true;
                    if is_interactive_tool(tool_name) {
                        pending_ask_question = true;
                    }
                }
            }
        }
    }

    if session_exited {
        Some("done")
    } else if pending_ask_question {
        Some("blocked")
    } else if pending_tool {
        Some("working")
    } else if let Some(text) = last_assistant_text {
        let trimmed = text.trim();
        // Last 60 chars, sliced on a char boundary so multi-byte text cannot panic.
        let end_slice = trimmed
            .char_indices()
            .rev()
            .nth(59)
            .map_or(trimmed, |(i, _)| &trimmed[i..]);
        if end_slice.contains(['?', '？']) {
            Some("blocked")
        } else {
            None
        }
    } else {
        None
    }
}

pub fn inspect_session_tail(path: &Path) -> Option<&'static str> {
    let mut file = fs::File::open(path).ok()?;
    let meta = file.metadata().ok()?;
    let len = meta.len();
    if len == 0 {
        return None;
    }
    let seek_start = len.saturating_sub(64 * 1024);
    if seek_start > 0 {
        file.seek(SeekFrom::Start(seek_start)).ok()?;
    }
    let reader = BufReader::new(file);
    let mut lines = Vec::new();
    for line in reader.lines() {
        if let Ok(l) = line {
            let trimmed = l.trim();
            if !trimmed.is_empty() {
                lines.push(trimmed.to_string());
            }
        }
    }
    inspect_session_lines(&lines)
}

/// How Herdr identifies an agent's session transcript (`agent_session.kind`).
#[derive(Debug, Clone, PartialEq)]
pub enum SessionRef {
    Path(PathBuf),
    Id(String),
}

/// Reads `agent_session` ({kind, value}) or the legacy `agent_session_path` from a pane/agent object.
pub fn session_ref_from(item: &Value) -> Option<SessionRef> {
    if let Some(session) = item.get("agent_session") {
        let value = session.get("value").and_then(|v| v.as_str())?;
        if value.is_empty() {
            return None;
        }
        return match session.get("kind").and_then(|k| k.as_str()) {
            Some("id") => Some(SessionRef::Id(value.to_string())),
            _ => Some(SessionRef::Path(resolve_path(value))),
        };
    }
    item.get("agent_session_path")
        .and_then(|p| p.as_str())
        .filter(|p| !p.is_empty())
        .map(|p| SessionRef::Path(resolve_path(p)))
}

pub fn pi_sessions_root() -> Option<PathBuf> {
    env::var("HOME")
        .ok()
        .map(|home| PathBuf::from(home).join(".pi/agent/sessions"))
}

fn pi_cwd_slug(cwd: &str) -> String {
    format!("--{}--", cwd.trim_matches('/').replace('/', "-"))
}

fn jsonl_files(dir: &Path) -> impl Iterator<Item = fs::DirEntry> {
    fs::read_dir(dir)
        .into_iter()
        .flatten()
        .flatten()
        .filter(|e| e.path().extension().is_some_and(|ext| ext == "jsonl"))
}

fn find_latest_jsonl(dir: &Path) -> Option<PathBuf> {
    jsonl_files(dir)
        .filter_map(|e| Some((e.metadata().ok()?.modified().ok()?, e.path())))
        .max_by_key(|(modified, _)| *modified)
        .map(|(_, path)| path)
}

/// Pi names transcripts `<timestamp>_<session-id>.jsonl`.
fn find_jsonl_for_id(dir: &Path, id: &str) -> Option<PathBuf> {
    let suffix = format!("_{}.jsonl", id);
    let exact = format!("{}.jsonl", id);
    jsonl_files(dir)
        .map(|e| e.path())
        .find(|p| {
            p.file_name()
                .and_then(|n| n.to_str())
                .is_some_and(|n| n.ends_with(&suffix) || n == exact)
        })
}

/// Resolves the transcript to inspect: an existing path, the file matching a session id
/// (cwd directory first, then any project directory), else the newest transcript for the cwd.
pub fn locate_pi_session_in(
    root: &Path,
    session: Option<&SessionRef>,
    cwd: &str,
) -> Option<PathBuf> {
    let cwd_dir = root.join(pi_cwd_slug(&resolve_path(cwd).to_string_lossy()));
    match session {
        Some(SessionRef::Path(p)) if p.is_absolute() && p.is_file() => return Some(p.clone()),
        Some(SessionRef::Id(id)) => {
            let found = find_jsonl_for_id(&cwd_dir, id).or_else(|| {
                fs::read_dir(root)
                    .into_iter()
                    .flatten()
                    .flatten()
                    .filter(|e| e.path().is_dir())
                    .find_map(|e| find_jsonl_for_id(&e.path(), id))
            });
            if found.is_some() {
                return found;
            }
        }
        _ => {}
    }
    find_latest_jsonl(&cwd_dir)
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    #[test]
    fn test_inspect_session_lines_pending_ask_tool() {
        let lines = vec![
            json!({
                "type": "message",
                "message": {
                    "role": "assistant",
                    "content": [
                        {
                            "type": "toolCall",
                            "name": "ask",
                            "arguments": { "question": "Should I proceed with the migration?" }
                        }
                    ]
                }
            }).to_string(),
        ];
        assert_eq!(inspect_session_lines(&lines), Some("blocked"));
    }

    #[test]
    fn test_inspect_session_lines_goal_question() {
        let lines = vec![
            json!({
                "type": "message",
                "message": {
                    "role": "assistant",
                    "content": [
                        {
                            "type": "toolCall",
                            "name": "goal_question",
                            "arguments": { "question": "Which architecture pattern do you prefer?" }
                        }
                    ]
                }
            }).to_string(),
        ];
        assert_eq!(inspect_session_lines(&lines), Some("blocked"));
    }

    #[test]
    fn test_inspect_session_lines_tool_resolved() {
        let lines = vec![
            json!({
                "type": "message",
                "message": {
                    "role": "assistant",
                    "content": [
                        {
                            "type": "toolCall",
                            "name": "ask",
                            "arguments": { "question": "Should I proceed?" }
                        }
                    ]
                }
            }).to_string(),
            json!({
                "type": "message",
                "message": {
                    "role": "toolResult",
                    "toolCallId": "call_123",
                    "content": [ { "type": "text", "text": "Yes" } ]
                }
            }).to_string(),
        ];
        // Tool was answered; no pending question
        assert_ne!(inspect_session_lines(&lines), Some("blocked"));
    }

    #[test]
    fn test_inspect_session_lines_assistant_question_text() {
        let lines = vec![
            json!({
                "type": "message",
                "message": {
                    "role": "assistant",
                    "content": [
                        {
                            "type": "text",
                            "text": "I noticed two approaches. Would you like me to use option A or option B?"
                        }
                    ]
                }
            }).to_string(),
        ];
        assert_eq!(inspect_session_lines(&lines), Some("blocked"));
    }

    fn assistant_text_line(text: &str) -> String {
        json!({
            "type": "message",
            "message": {
                "role": "assistant",
                "content": [ { "type": "text", "text": text } ]
            }
        })
        .to_string()
    }

    #[test]
    fn test_inspect_session_lines_multibyte_text_does_not_panic() {
        // Byte offset len-60 lands inside a 3-byte CJK char for this text.
        let cjk = "好的，我已经完成了重构。".repeat(4) + "你想让我继续处理测试吗？";
        assert_eq!(inspect_session_lines(&[assistant_text_line(&cjk)]), Some("blocked"));

        let emoji = format!("{}x", "🦀".repeat(30));
        assert_eq!(inspect_session_lines(&[assistant_text_line(&emoji)]), None);
    }

    #[test]
    fn test_inspect_session_lines_only_checks_tail_for_question() {
        let early_question = format!("Should I? {}", "Done with the refactor. ".repeat(5));
        assert_eq!(inspect_session_lines(&[assistant_text_line(&early_question)]), None);
    }

    struct TempDir(PathBuf);

    impl TempDir {
        fn new(tag: &str) -> Self {
            let dir = env::temp_dir().join(format!(
                "herdr-status-test-{}-{}-{:?}",
                tag,
                std::process::id(),
                std::thread::current().id()
            ));
            let _ = fs::remove_dir_all(&dir);
            fs::create_dir_all(&dir).unwrap();
            TempDir(dir)
        }
        fn touch(&self, rel: &str) -> PathBuf {
            let p = self.0.join(rel);
            fs::create_dir_all(p.parent().unwrap()).unwrap();
            fs::write(&p, "{}\n").unwrap();
            p
        }
    }

    impl Drop for TempDir {
        fn drop(&mut self) {
            let _ = fs::remove_dir_all(&self.0);
        }
    }

    #[test]
    fn test_session_ref_from_variants() {
        let id = json!({"agent_session": {"kind": "id", "value": "abc-123"}});
        assert_eq!(session_ref_from(&id), Some(SessionRef::Id("abc-123".into())));

        let path = json!({"agent_session": {"kind": "path", "value": "/tmp/s.jsonl"}});
        assert_eq!(
            session_ref_from(&path),
            Some(SessionRef::Path(PathBuf::from("/tmp/s.jsonl")))
        );

        let legacy = json!({"agent_session_path": "/tmp/legacy.jsonl"});
        assert_eq!(
            session_ref_from(&legacy),
            Some(SessionRef::Path(PathBuf::from("/tmp/legacy.jsonl")))
        );

        assert_eq!(session_ref_from(&json!({"agent_session": null})), None);
        assert_eq!(session_ref_from(&json!({})), None);
    }

    #[test]
    fn test_locate_pi_session_by_id_in_cwd_dir() {
        let root = TempDir::new("by-id");
        let wanted = root.touch("--work-proj--/2026-10-15T00-00-00-000Z_abc-123.jsonl");
        root.touch("--work-proj--/2026-10-15T09-00-00-000Z_newer-999.jsonl");
        let sref = SessionRef::Id("abc-123".into());
        assert_eq!(
            locate_pi_session_in(&root.0, Some(&sref), "/work/proj"),
            Some(wanted)
        );
    }

    #[test]
    fn test_locate_pi_session_by_id_in_other_project_dir() {
        // Agent started in /work/proj then the pane cd'd elsewhere.
        let root = TempDir::new("by-id-other");
        let wanted = root.touch("--work-proj--/2026-10-15T00-00-00-000Z_abc-123.jsonl");
        let sref = SessionRef::Id("abc-123".into());
        assert_eq!(
            locate_pi_session_in(&root.0, Some(&sref), "/work/elsewhere"),
            Some(wanted)
        );
    }

    #[test]
    fn test_locate_pi_session_falls_back_to_cwd_latest() {
        let root = TempDir::new("fallback");
        let only = root.touch("--work-proj--/2026-10-15T00-00-00-000Z_zzz.jsonl");

        let unknown_id = SessionRef::Id("not-there".into());
        assert_eq!(
            locate_pi_session_in(&root.0, Some(&unknown_id), "/work/proj"),
            Some(only.clone())
        );

        let missing_path = SessionRef::Path(root.0.join("missing.jsonl"));
        assert_eq!(
            locate_pi_session_in(&root.0, Some(&missing_path), "/work/proj"),
            Some(only.clone())
        );

        let relative = SessionRef::Path(PathBuf::from("abc-123"));
        assert_eq!(
            locate_pi_session_in(&root.0, Some(&relative), "/work/proj"),
            Some(only)
        );
    }

    #[test]
    fn test_locate_pi_session_existing_path_wins() {
        let root = TempDir::new("path");
        root.touch("--work-proj--/2026-10-15T00-00-00-000Z_zzz.jsonl");
        let explicit = root.touch("elsewhere/session.jsonl");
        let sref = SessionRef::Path(explicit.clone());
        assert_eq!(
            locate_pi_session_in(&root.0, Some(&sref), "/work/proj"),
            Some(explicit)
        );
    }
}
