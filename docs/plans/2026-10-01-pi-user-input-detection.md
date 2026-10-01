# Specification: Pi User-Input Status Detection & Normalization

## Overview
In Herdr, Pi coding agents use `herdr-agent-state.ts` which reports `working` during an active turn and `idle` when settled. Because `screen_detection_skipped: true` is set for `herdr:pi`, Herdr does not perform terminal screen regex matching to detect approvals or questions. Consequently, when Pi halts for user input (e.g. via `ask`, `goal_question`, `goal_questionnaire`, `propose_goal_draft`, or awaiting user response to an open question), Herdr leaves the agent state as `idle` or `prompt`, and does not emit `blocked`.

To fix this, `omarchy-herdr-status` adopts the battle-tested hybrid strategy from `agent-orchestr` and `omarchy-herdr`:
1. **Status Normalization**: Map raw incoming statuses from Herdr, plugins, and CLI events into standard lifecycle buckets:
   - Needs Input / Blocked: `"blocked"`, `"waiting"`, `"prompt"`, `"input"`, `"needs_input"`, `"permission"`, `"confirm"` -> `"blocked"`.
   - Working: `"working"`, `"busy"`, `"running"`, `"thinking"`, `"generating"` -> `"working"`.
   - Done: `"done"`, `"completed"`, `"finished"` -> `"done"`.
   - Idle: `"idle"`, `"ready"` -> `"idle"`.
   - Other / unrecognized -> `"unknown"`.

2. **Session Tail Inspection for Pi / OMP Agents**:
   - Herdr's `agent.list` returns `agent_session.value` pointing to the agent's active session transcript (`.jsonl`).
   - If `agent_session` is present and points to a readable `.jsonl` file:
     - Read the bounded tail (up to last 64 KB or last 50 lines).
     - Inspect the last assistant message and tool interactions:
       - If there is an unresolved tool call for interactive input (`ask`, `goal_question`, `goal_questionnaire`, `propose_goal_draft`, `question`), status override is `"blocked"`.
       - If the agent is reported `idle` by Herdr but the last assistant text ends with an open question (`?`), status override is `"blocked"`.
       - If a tool call was initiated and not yet completed without interactive input, status override is `"working"`.
   - Rule of precedence:
     - Live Herdr `"working"` always takes precedence over session transcript reading (preventing stale history from downgrading an active turn).
     - Session-detected `"blocked"` (waiting for input) overrides Herdr's `"idle"`.

3. **UI and Notification Representation**:
   - Any agent in `"blocked"` state displays the urgent indicator (`󰅚`), red/urgent badge styling, and is ranked with highest priority.
   - Status badge text and metrics pill display the count of blocked/input-waiting agents.
