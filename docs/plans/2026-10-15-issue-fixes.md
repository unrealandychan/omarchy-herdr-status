# Issue Fix Plan (#5–#17)

> **Goal:** Fix every open review issue, one commit per issue, on branch `fix/issues-5-17`.
> **Verified against:** Herdr 0.9.4 (`herdr api schema`, protocol 22) and an isolated headless server
> (`XDG_CONFIG_HOME=/tmp/… herdr server`) driven by `herdr pane report-agent` from inside a test pane.

## Herdr API facts this plan relies on

- Agent statuses are already canonical: `idle | working | blocked | done | unknown`.
- `agent.list` items carry `state_change_seq`, `agent_session {kind: id|path, value}`; **no timestamp**.
- `pane.agent_status_changed` is a *per-pane* subscription (`{"type": …, "pane_id": …}`) and is delivered
  with the dotted event name `pane.agent_status_changed`. Regular events use underscores
  (`pane_updated`, `pane_created`, `pane_agent_detected`, `pane_closed`, `pane_exited`).
- `pane_agent_detected` carries `agent`, `released`, `final_status` — no live status (Herdr starts at `unknown`).
- Status changes do **not** emit `pane_updated`.
- Panes inside Herdr export `HERDR_SOCKET_PATH`.

## Order

Small isolated bugs first, then the refactor that the larger fixes build on, then UI, then docs.

| # | Issue | Approach | Verify |
|---|---|---|---|
| 1 | #5 UTF-8 panic | char-aware tail slice; also match `？` | unit test with CJK/emoji |
| 2 | #6 `agent_session` id | resolve `kind=path` only if exists; `kind=id` → `<slug>/*<id>*.jsonl`; else cwd fallback | unit tests with temp HOME |
| 3 | #17 split `main.rs` | modules `herdr`, `status`, `pi`, `payload`, `standalone`; `agent_from_pane()`; sort before truncate; stderr logging via `HERDR_STATUS_LOG`; `--help/--version` | all tests still pass, `--once/--demo` output unchanged |
| 4 | #16 CI + clippy | `AgentInfo` args → struct literal; fix lints; GH Actions: fmt, clippy `-D warnings`, test, shellcheck, version sync | `cargo clippy -- -D warnings`, `shellcheck` locally |
| 5 | #9 polling | subscribe per-pane `pane.agent_status_changed`; handle dotted + underscore names; handle `pane_created`; resync every 30 s instead of 1.5 s; cache transcript results by (path, mtime, len) | e2e against isolated server: status change arrives without poll |
| 6 | #7 multi-session | worker thread per socket → mpsc → aggregator; key `(session, pane_id)`; rescan `sessions/` every 5 s; `--socket`/`HERDR_SOCKET(_PATH)` = single explicit socket | e2e with two isolated servers |
| 7 | #8 timers | aggregator owns `since` per `(session,pane_id,status)`; persisted to `$XDG_RUNTIME_DIR/herdr-status/state.json`; drop dead `state_changed_at` reads | unit test + restart bridge in e2e keeps timer |
| 8 | #10 standalone | `source:"system"` agents get status `unknown`, live in `external_agents`, opt-in `--detect-external`; not counted in badge; no jump action | unit test |
| 9 | #11 status SSOT | QML trusts canonical status; one `statusStyle` table; unknown handled consistently | qmllint, demo-mode visual check |
| 10 | #13 theme | colors derived from `Color.*` with `Qt.alpha`; `StatusPill.qml`, `AgentCard.qml` | load in shell, check light theme |
| 11 | #14 herdr-focus | find terminal window by PID ancestry of herdr client; class list fallback (`HERDR_FOCUS_CLASSES`); notify on focus failure | shellcheck; manual run |
| 12 | #12 bridge.py | delete + README mention | — |
| 13 | #15 README | structure, schema, flags, shortcuts, settings, prerequisites, honest perf numbers (measured) | review |

Version bump to 1.3.0 at the end (Cargo.toml + manifest.json).
