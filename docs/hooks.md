# Hook System

OpenIsland receives lifecycle events from managed hook CLIs and runtime extensions. Codex, Claude-family agents, Gemini CLI, Grok Build, Kimi CLI, and Agentica CLI invoke `OpenIslandHooks`; Pi and Oh My Pi load a TypeScript extension. Both paths forward typed payloads to the app over its Unix socket. Hook sources that support blocking can receive directives on stdout; Pi-family extensions are fire-and-forget.

## Architecture

```text
Managed hook agent                     Pi / Oh My Pi
  │ stdin: JSON payload                  │ runtime ExtensionAPI events
  ▼                                      ▼
OpenIslandHooks CLI                   open-island.ts
  │                                      │
  └──────────── Unix socket ──────────────┘
                         │
                         ▼
              BridgeServer → AppModel → UI

```
Blocking hook sources receive a `BridgeResponse` through `OpenIslandHooks` stdout. Pi-family extension events do not block the agent.

**Fail-open principle**: if the bridge is unavailable, managed hook processes exit without writing to stdout and Pi-family extensions ignore socket errors, so the agent continues running unchanged.

## Skip Hooks For Delegated Control

Set `OPEN_ISLAND_SKIP_HOOKS=1` on a child agent process when another local controller intentionally owns permission handling for that run. The hook CLI exits immediately without reading or forwarding the payload, so the agent continues without Open Island UI intervention.

`VIBE_ISLAND_SKIP=1` is also recognized as a legacy compatibility alias.

This is meant for per-process launches. Do not set it globally unless you want Open Island hooks disabled for every agent started from that environment.

**Entry point**: [`Sources/OpenIslandHooks/main.swift`](../Sources/OpenIslandHooks/main.swift)

---

## Coexistence With Commercial Vibe Island

Open Island and the commercial Vibe Island app are independent products with
independent hook installs. They are expected to be installed side by side on the
same machine, and Open Island's installer must never read, rewrite, or delete the
other product's entries.

The two are told apart by **command ownership**, not by sharing a manifest:

| Product | Hook binary |
|---|---|
| Open Island | `OpenIslandHooks` (bundled, copied to `~/Library/Application Support/OpenIsland/bin/`) |
| Vibe Island | `~/.vibe-island/bin/vibe-island-bridge` |

An entry is "ours" only when its command either matches the command recorded in
our own manifest (`open-island-claude-hooks-install.json`, `open-island-grok-hooks-install.json`,
`open-island-agentica-hooks-install.json`, …) **or** names `OpenIslandHooks` with the
matching `--source <agent>`. The `--source` clause matters because one binary
serves every Claude-family fork: a CodeBuddy install must not disturb the Claude
Code entry.

Installing or uninstalling therefore touches only Open Island entries. A
Vibe Island hook left in `settings.json` is passed through verbatim, and a
Vibe-Island-only file never reports as "Open Island installed".

**Practical consequence**: with both apps installed, an agent session produces two
hook invocations per event — one per product. Each controller only sees its own
payload, and either one can be uninstalled without affecting the other.

---

## Codex Hooks (`--source codex`)

**Payload type**: `CodexHookPayload`
**Source**: [`Sources/OpenIslandCore/CodexHooks.swift`](../Sources/OpenIslandCore/CodexHooks.swift)

### Events

| `hook_event_name` | When it fires | Notable fields |
|---|---|---|
| `SessionStart` | Session starts or resumes (`source: "resume"` on resume) | `prompt`, `source` |
| `PreToolUse` | Before a shell command executes | `tool_name`, `tool_input.command`, `turn_id`, `tool_use_id` |
| `PermissionRequest` | Codex requests permission for a tool/action | `tool_name`, `tool_input`, `turn_id` |
| `PostToolUse` | After a shell command completes | `tool_name`, `tool_input`, `tool_response`, `turn_id` |
| `UserPromptSubmit` | User submits a new prompt | `prompt` |
| `Stop` | A turn completes | `last_assistant_message`, `stop_hook_active` |

### Default managed installation

The managed Codex hook installer (`CodexHookInstaller`) installs `SessionStart`, `UserPromptSubmit`, `PermissionRequest`, and `Stop` by default. This keeps the lifecycle hooks low-noise while still allowing OpenIsland to broker Codex's first-class approval requests. Per-command `PreToolUse` / `PostToolUse` hooks remain opt-in because they can add terminal log noise.

The installer chooses the Codex hook feature flag that the local Codex CLI advertises. Newer Codex builds use `[features].hooks = true`; older builds use the legacy `[features].codex_hooks = true`. Status checks recognize both keys, and managed installs migrate between them when the local Codex version changes.

After hooks are installed or changed, Codex may require a manual trust review before running them. Open `/hooks` inside Codex CLI and approve the expected Open Island hook entries. This approval gate belongs to Codex and is not bypassed by Open Island.

The `CodexHookPayload` model and `BridgeServer` can parse richer events (`PreToolUse`, `PostToolUse`) when they are present in the hook payload, and will surface them in the UI if received. However, these per-tool lifecycle events are **not** installed by the managed installer and must be configured manually if desired.

> **Note on file-edit coverage**: Codex file edits may use internal apply-patch paths that do not emit `PreToolUse` events. File-edit approval should not be treated as guaranteed `PreToolUse` coverage; the current reliable coverage is command/shell-level events, depending on Codex hook configuration.

### Common payload fields

| JSON key | Swift property | Description |
|---|---|---|
| `cwd` | `cwd` | Working directory |
| `hook_event_name` | `hookEventName` | Event type |
| `session_id` | `sessionID` | Session UUID |
| `model` | `model` | Model name |
| `permission_mode` | `permissionMode` | `default` / `acceptEdits` / `plan` / `dontAsk` / `bypassPermissions` |
| `transcript_path` | `transcriptPath` | JSONL transcript file path |
| `terminal_app` | `terminalApp` | Terminal name (`Terminal`, `Ghostty`, `iTerm`, …) |
| `terminal_session_id` | `terminalSessionID` | Terminal session identifier |
| `terminal_tty` | `terminalTTY` | TTY device path |
| `terminal_title` | `terminalTitle` | Tab / window title |
| `turn_id` | `turnID` | Current turn ID |
| `tool_name` | `toolName` | Tool name (e.g. `shell`) |
| `tool_use_id` | `toolUseID` | Tool-use call ID |
| `tool_input` | `toolInput` | Tool input (commonly includes `command` and/or `description`) |
| `tool_response` | `toolResponse` | Tool output (JSON) |
| `prompt` | `prompt` | User prompt text |
| `last_assistant_message` | `lastAssistantMessage` | Last assistant message |
| `stop_hook_active` | `stopHookActive` | Whether the stop hook is active |

### Directive responses

#### `PreToolUse`

The app can block a command by writing this to stdout:

```json
{"decision": "block", "reason": "Blocked by Open Island"}
```

#### `PermissionRequest`

The managed `PermissionRequest` hook has a 1-hour timeout so the user can approve or deny from the UI.

Allow:

```json
{
  "continue": true,
  "hookSpecificOutput": {
    "hookEventName": "PermissionRequest",
    "decision": {
      "behavior": "allow"
    }
  }
}
```

Deny:

```json
{
  "continue": true,
  "hookSpecificOutput": {
    "hookEventName": "PermissionRequest",
    "decision": {
      "behavior": "deny",
      "message": "User denied the permission request"
    }
  }
}
```

All other Codex events require no stdout response.

---

## Claude Code Hooks (`--source claude`)

**Payload type**: `ClaudeHookPayload`
**Source**: [`Sources/OpenIslandCore/ClaudeHooks.swift`](../Sources/OpenIslandCore/ClaudeHooks.swift)

### Events

| `hook_event_name` | When it fires | Directive response |
|---|---|---|
| `SessionStart` | Session starts (`startup` / `resume` / `clear` / `compact`) | None |
| `SessionEnd` | Session ends | None |
| `UserPromptSubmit` | User submits a prompt | None |
| `PreToolUse` | Before a tool call | **Yes** — allow / deny / modify input |
| `PostToolUse` | After a successful tool call | None |
| `PostToolUseFailure` | After a failed tool call | None |
| `PermissionRequest` | Agent requests user approval | **Yes** — allow or deny (24 h timeout) |
| `PermissionDenied` | A permission was denied | None |
| `Notification` | Agent emits a notification | None |
| `Stop` | Turn ends normally | None |
| `StopFailure` | Turn ends with an error | None |
| `SubagentStart` | A sub-agent starts | None |
| `SubagentStop` | A sub-agent stops | None |
| `PreCompact` | Before context compaction | None |

### Common payload fields

| JSON key | Swift property | Description |
|---|---|---|
| `cwd` | `cwd` | Working directory |
| `hook_event_name` | `hookEventName` | Event type |
| `session_id` | `sessionID` | Session UUID |
| `transcript_path` | `transcriptPath` | JSONL transcript file path |
| `permission_mode` | `permissionMode` | Permission mode |
| `model` | `model` | Model name |
| `agent_id` | `agentID` | Sub-agent ID (SubagentStart/Stop) |
| `agent_type` | `agentType` | Sub-agent type |
| `source` | `source` | Start source (`startup` / `resume` / `clear` / `compact`) |
| `tool_name` | `toolName` | Tool name |
| `tool_input` | `toolInput` | Tool input parameters (JSON) |
| `tool_use_id` | `toolUseID` | Tool-use call ID |
| `tool_response` | `toolResponse` | Tool output (JSON) |
| `permission_suggestions` | `permissionSuggestions` | Suggested permission changes (PermissionRequest) |
| `prompt` | `prompt` | User prompt text |
| `message` | `message` | Notification message body |
| `title` | `title` | Notification title |
| `notification_type` | `notificationType` | Notification type |
| `stop_hook_active` | `stopHookActive` | Whether the stop hook is active |
| `last_assistant_message` | `lastAssistantMessage` | Last assistant message |
| `error` | `error` | Error message (Failure events) |
| `error_details` | `errorDetails` | Extended error details |
| `is_interrupt` | `isInterrupt` | Whether the event is an interrupt |
| `agent_transcript_path` | `agentTranscriptPath` | Sub-agent transcript path |
| `terminal_app` | `terminalApp` | Terminal name |
| `terminal_session_id` | `terminalSessionID` | Terminal session identifier |
| `terminal_tty` | `terminalTTY` | TTY device path |
| `terminal_title` | `terminalTitle` | Tab / window title |

### PreToolUse directive response

```json
{
  "continue": true,
  "suppressOutput": true,
  "hookSpecificOutput": {
    "hookEventName": "PreToolUse",
    "permissionDecision": "allow" | "deny" | "ask",
    "permissionDecisionReason": "reason shown to the agent",
    "updatedInput": { ... },
    "additionalContext": "extra context injected into the turn"
  }
}
```

| Field | Description |
|---|---|
| `permissionDecision` | `allow` — proceed; `deny` — block; `ask` — let the agent ask the user |
| `permissionDecisionReason` | Human-readable reason forwarded to the agent |
| `updatedInput` | Replace the tool's input parameters (optional) |
| `additionalContext` | Inject additional context into the turn (optional) |

### PermissionRequest directive response

The `PermissionRequest` event has a **24-hour timeout** to allow the user to review and approve in the UI.

Allow:

```json
{
  "continue": true,
  "suppressOutput": true,
  "hookSpecificOutput": {
    "hookEventName": "PermissionRequest",
    "decision": {
      "behavior": "allow",
      "updatedInput": { ... },
      "updatedPermissions": [ ... ]
    }
  }
}
```

Deny:

```json
{
  "continue": true,
  "suppressOutput": true,
  "hookSpecificOutput": {
    "hookEventName": "PermissionRequest",
    "decision": {
      "behavior": "deny",
      "message": "User denied the permission request",
      "interrupt": false
    }
  }
}
```

Setting `interrupt: true` terminates the current agent turn immediately.

---

## Gemini CLI Hooks (`--source gemini`)

**Payload type**: `GeminiHookPayload`
**Source**: [`Sources/OpenIslandCore/GeminiHooks.swift`](../Sources/OpenIslandCore/GeminiHooks.swift)

### Events

| `hook_event_name` | When it fires | Current OpenIsland behavior |
|---|---|---|
| `SessionStart` | Session starts or resumes | Creates or restores the Gemini session, title, jump target, and transcript metadata |
| `BeforeAgent` | Gemini starts handling a prompt / turn | Marks the session running, updates prompt text, refreshes terminal metadata |
| `AfterAgent` | Gemini finishes a turn | Marks the turn completed and emits a completion card |
| `SessionEnd` | Gemini reports the session ended | Marks the hook-managed session ended and removes it from active visibility |
| `Notification` | Gemini emits a notification message | Updates the session summary / activity text without blocking the agent |

### Common payload fields

| JSON key | Swift property | Description |
|---|---|---|
| `cwd` | `cwd` | Working directory |
| `hook_event_name` | `hookEventName` | Event type |
| `session_id` | `sessionID` | Session identifier |
| `transcript_path` | `transcriptPath` | Gemini transcript file path |
| `timestamp` | `timestamp` | Hook timestamp |
| `prompt` | `prompt` | User prompt text |
| `prompt_response` | `promptResponse` | Gemini response text |
| `source` | `source` | Session start source |
| `reason` | `reason` | Session-end reason |
| `notification_type` | `notificationType` | Notification category |
| `message` | `message` | Notification message |
| `details` | `details` | Structured notification payload |
| `stop_hook_active` | `stopHookActive` | Whether Gemini stop hook support is active |
| `terminal_app` | `terminalApp` | Terminal name |
| `terminal_session_id` | `terminalSessionID` | Terminal session identifier |
| `terminal_tty` | `terminalTTY` | TTY device path |
| `terminal_title` | `terminalTitle` | Tab / window title |

### Current feature coverage

- Session lifecycle ingestion for Gemini CLI via `OpenIslandHooks --source gemini`
- Session list and island visibility updates from Gemini hook events
- Prompt / response metadata capture for completion cards and session details
- Terminal jump metadata enrichment for Terminal.app, iTerm2, Ghostty, and other supported terminals
- Process-assisted liveness matching so active Gemini CLI sessions can stay visible even when hook traffic is sparse

### Current limitations

- Gemini hooks are currently treated as fire-and-forget. OpenIsland does not send Gemini-specific approval or modification directives back to stdout.
- Gemini hook payloads sometimes include a duplicated copy of the final response body, often with whitespace-only differences. OpenIsland applies a best-effort compatibility pass before rendering completion content, but the result is not guaranteed to be perfect for every response shape.
- Gemini support is currently limited to the hook events and UI/session behaviors listed above. It does not yet match the richer permission / interaction flows available for Claude Code or OpenCode.

---

## Pi and Oh My Pi Extensions

**Payload type**: `PiHookPayload`

**Sources**: [`Sources/OpenIslandCore/PiHooks.swift`](../Sources/OpenIslandCore/PiHooks.swift), [`Sources/OpenIslandApp/Resources/open-island-pi.ts`](../Sources/OpenIslandApp/Resources/open-island-pi.ts)

Open Island installs one bundled extension per runtime:

- Pi: `~/.pi/agent/extensions/open-island.ts`
- Oh My Pi: `~/.omp/agent/extensions/open-island.ts`

The setup UI installs, refreshes, reveals, and uninstalls each extension independently. The installer writes only `open-island.ts` plus its Open Island ownership manifest; uninstall leaves other user extensions untouched.

### Event coverage

| Open Island event | Pi event | Oh My Pi event | Behavior |
|---|---|---|---|
| `SessionStart` | `session_start` | `session_start` | Creates the typed Pi/OMP session with model, transcript, working-directory, and terminal metadata |
| `UserPromptSubmit` | `before_agent_start` | `before_agent_start` | Updates the latest user prompt and marks the session running |
| `PreToolUse` | `tool_execution_start` | `tool_execution_start` | Shows the active tool and a clipped input preview |
| `PostToolUse` | `tool_execution_end` | `tool_execution_end` | Clears the active tool and records tool completion |
| `Stop` | `agent_settled` | `session_stop` | Marks the current turn completed and records the latest assistant text |
| `Heartbeat` | 15-second session timer | 15-second session timer | Refreshes only per-session liveness; it does not change turn phase, summary, tool, or message metadata |
| `SessionEnd` | `session_shutdown` | `session_shutdown` | Ends the tracked session immediately; reload shutdowns stop the timer without ending the session |

Jump-back metadata (terminal app, terminal session ID, TTY) is read from the agent process environment at event time; the extension does not forward terminal variables into child shell commands. When a prompt starts it sets `OPEN_ISLAND_ACTIVE=1` in the agent process environment, so commands the agent spawns can tell that Open Island is tracking the session. If the socket is unavailable, connection errors are ignored and agent execution continues. Pi and Oh My Pi liveness is keyed by `session_id`: heartbeat keeps or restores that specific session, a 45-second heartbeat timeout hides it after an abnormal exit, and generic process polling does not keep Pi/OMP sessions alive.

### Current limitations

- Pi and Oh My Pi extension events are fire-and-forget. Open Island does not block, approve, deny, or rewrite tool calls through these integrations.
- Runtime event objects are intentionally decoded defensively because Pi and Oh My Pi expose overlapping lifecycle concepts with some different event names.

---

## Timeout Policy

| Source | Event | Timeout |
|---|---|---|
| Codex | `PermissionRequest` | **1 hour** (awaits human approval) |
| Codex | All other managed events | **45 seconds** |
| Claude Code | `PermissionRequest` | **24 hours** (awaits human approval) |
| Claude Code | All other events | **45 seconds** |
| Gemini CLI | All events | Bridge default |
| Grok Build | All managed events | **45 seconds** |
| Agentica | `needs.approval` / `needs.input` | **24 hours** (agentica sets no cap of its own) |
| Agentica | `run.*` / `tool.*` / `session.*` / `needs.resolved` notices | **45 seconds** (agentica reaps its side at 30s) |
| Pi / Oh My Pi | Heartbeat liveness | **45 seconds** |

---

## Grok Build Hooks (`--source grok`)

**Payload type**: `GrokHookPayload`
**Source**: [`Sources/OpenIslandCore/GrokHooks.swift`](../Sources/OpenIslandCore/GrokHooks.swift)

Grok Build (Grok CLI / Grok TUI) discovers hooks from `~/.grok/hooks/*.json`. Open Island writes a dedicated managed file at `~/.grok/hooks/open-island.json`.

### Events (managed install)

All of the following are registered in `~/.grok/hooks/open-island.json` by the managed installer:

| Event | Matcher | Current OpenIsland behavior |
|---|---|---|
| `SessionStart` | — | Creates / re-opens the Grok session, title, and jump target |
| `SessionEnd` | — | Marks the hook-managed session ended (`isSessionEnd`) |
| `UserPromptSubmit` | — | Marks the session running and updates summary |
| `Stop` | — | Completion when `reason == "end_turn"`; if `reason` is omitted, treat as turn completion; non-`end_turn` reasons are observe-only |
| `StopFailure` | — | Activity update, phase `.completed` (session not ended) |
| `StopCancelled` | — | Turn completion flagged `isInterrupt` — fires *instead of* `Stop` on a user interrupt (Ctrl+C / Esc), a declined or cancelled permission prompt, `--max-turns`, or a no-progress bail-out; summary is `lastAssistantMessage` when present, else derived from `reason` |
| `Notification` | `*` | Activity update; `notificationType == "idle_prompt"` settles a still-running session as completed (Grok's backstop for turns that reported no Stop-family event) and leaves an already-completed session untouched |
| `PreToolUse` | `*` | Activity update, **fire-and-forget** (no deny directive; fail-open) |
| `PostToolUse` | `*` | Activity update |
| `PostToolUseFailure` | `*` | Activity update, phase `.completed` |
| `SubagentStart` / `SubagentStop` | — | Activity updates |
| `PermissionDenied` | — | Activity update; session stays running. Fires for both a user **Reject** (a `StopCancelled` with `permission_rejected` follows and settles the turn) and a configured **PolicyDeny** rule (the model is told the tool was skipped and keeps working) |
| `PreCompact` / `PostCompact` | — | Activity updates |

Managed status is **healthy only when every event above** is present with an Open Island Grok command. A Vibe Island-only command does **not** count as installed.

### Lifecycle / liveness notes

- Non-`SessionStart` events on an **already ended** session are acknowledged and ignored (no resurrection).
- Process discovery cannot recover Grok session UUIDs. While a `grok` process is alive, Open Island keeps non-ended Grok sessions in the process-alive set (TTY/CWD match when unique; otherwise a conservative “any Grok process” fallback similar to Kimi). Explicit `SessionEnd` still ends the session.

### Wire format notes

- Stdin JSON uses **camelCase** keys (`sessionId`, `hookEventName`, `toolName`, `toolResult`).
- `hookEventName` may arrive as PascalCase (`PreToolUse`), snake_case (`pre_tool_use`) or camelCase (`preToolUse`); all are accepted.
- Envelopes may carry `promptId`; it is decoded as `promptID` but not acted on yet (reserved for ignoring stale-prompt reports).
- `StopCancelled` carries `reason` (`user_interrupt`, `permission_rejected`, `permission_cancelled`, `max_turns`, `no_progress`, `unknown`), `cancelledBy` (`user` / `runtime` / `unknown`) and optional `cancelTrigger` / `reasonDetails` / `lastAssistantMessage`.
- PreToolUse decision format (not used by the managed install yet): `{"decision":"allow"}` / `{"decision":"deny","reason":"..."}`.
- Sessions also land under `~/.grok/sessions/<url-encoded-cwd>/<session-id>/` for offline discovery (not yet scanned by Open Island).

### Install / uninstall

```bash
swift run OpenIslandSetup installGrok
swift run OpenIslandSetup statusGrok
swift run OpenIslandSetup uninstallGrok
```

Or use **Settings → Setup → Grok Build** in the app.

> If commercial Vibe Island is also installed, both may write under `~/.grok/hooks/`. Open Island writes only its own `open-island.json`; Vibe Island's file is left untouched.

---

## Agentica CLI Hooks (`--source agentica`)

**Payload type**: `AgenticaHookPayload`
**Source**: [`Sources/OpenIslandCore/AgenticaHooks.swift`](../Sources/OpenIslandCore/AgenticaHooks.swift)

Agentica's wire is not a Claude-family wire. Event names are dotted rather than
PascalCase, the wire is **multi-consumer** rather than a single hook command, and
the two blocking events are *requests* that race the terminal instead of gates
that own the decision.

### Events

#### Delegated workers are dropped

agentica's `delegate` tool launches each delegated task as a whole other
`agentica --query --print` process, and that process is a top-level CLI that
wires its own hook egress — so without a discriminator the island would grow one
phantom row per `delegate` call and ring on every one of its runs. agentica
marks those processes with `AGENTICA_DELEGATE_DEPTH` (0 = user-started, 1 =
delegated; `delegate_tool.py` sets depth + 1 and hook processes inherit the
environment). The hook binary resolves that number into
`is_delegated_worker`, and the bridge drops those payloads before they can
create a session. A delegated worker is an implementation detail of the parent
session, not a session of its own; the parent's row keeps reporting as usual.
The in-process `task` tool never reaches the wire at all — agentica drops its
runs at the source (`parent_run_id`).

| `hook_event_name` | When it fires | Current Open Island behavior |
|---|---|---|
| `session.started` | The CLI booted or resumed | Creates the session row idle; carries `model`, `profile`, `permission_mode`, `transcript_path` |
| `session.ended` | The CLI exited or switched session | Marks the session completed |
| `run.started` | A run begins | Marks it running, shows the run's anchor prompt |
| `run.completed` | A run finishes with a response | Turn completion card, summary from `answer` |
| `run.failed` | A run raised | Turn completion card, summary from `error` / `reason` |
| `run.cancelled` | A run was cancelled | Turn completion flagged `isInterrupt` |
| `tool.started` | A tool call begins executing | Activity line, e.g. `read_file a.py` |
| `tool.completed` | A tool call finished | Activity line; a failure shows `error` |
| `needs.approval` | A tool call is waiting for approval | Permission card; **replies** `{"request_id":…,"decision":"allow"\|"deny"}` |
| `needs.input` | The agent is asking the user a question | Question card; **replies** `{"request_id":…,"answer":"…"}` |
| `needs.resolved` | A `needs.*` race ended | Dismisses the card, whoever won |

`tool.*` fire at the real execution boundary, so a serial batch does not mark
later tools started before they run, and the first tool to finish in a parallel
batch reports completed immediately. They stay `.running`: a finished tool call is
progress within a turn, and only `run.*` closes one.

`run.completed` ends a **turn**, and in a goal-driven session that means the whole
goal: agentica defers the per-lap completions and releases exactly one when the
goal finishes. So there is no per-iteration flicker and nothing to guess. Two
details follow from that:

- `duration_seconds` on a released goal completion is the **sum** of the laps —
  total busy time — while `answer` is the last lap's. Open Island reads neither.
- `run.failed` and `run.cancelled` are **not** deferred, so a failing lap reports
  immediately even when the goal carries on. That is the only honest option:
  `goal.*` is deliberately kept off this wire, so a consumer cannot know a goal is
  driving. The island shows the failure and returns to running on the next lap.

### Reply contract

Agentica reads **one JSON document** from the hook's stdout and races it against
the answer typed in the terminal and every other subscribed consumer — the first
valid answer wins, and the losers are not errors. Three rules shape the
implementation:

- **`request_id` must be echoed.** Agentica's `parse_reply` discards any reply
  whose `request_id` does not match the request it sent. A directive without one
  is silently ignored, which would look exactly like "the user never answered", so
  the two reply cases are only reachable through `AgenticaHookDirective.decision`
  and `.answer` — both demand the id, and the compiler refuses to let a caller
  forget it.
- **Printing nothing means "no decision."** Open Island stays silent whenever it
  has nothing usable to say (a notice event, a question the user dismissed, an
  empty answer). Agentica then falls back to the terminal prompt. This is the
  fail-open path and it is the default, not an error branch.
- **The decision vocabulary is agentica's**: `allow`, `deny`, `allow_prefix`,
  `deny_prefix`. Anything else is read as "no decision" rather than coerced, so
  Open Island never invents a value. Only `allow` and `deny` are sent: the
  permission card has two actions, and a decision that silently covers every
  similar future call is not something to infer from a two-button tap.

A `needs.approval` that arrives without a `request_id` is acknowledged and **not**
parked. A card the user can tap but that can never take effect is worse than no
card, so the terminal owns that one.

Agentica imposes **no wait cap** on a request, so a desktop answer must not get
less time than a typed one: `needs.*` uses the same 24-hour client timeout as
Claude `PermissionRequest`. Agentica kills the hook process group itself once
someone answers, and `needs.resolved` tells us so.

### Wire format notes

- Stdin JSON uses **snake_case** (`hook_event_name`, `session_id`, `tool_call_id`).
- Optional fields are **omitted, never null**.
- `hook_event_name` and `session_id` are the only guaranteed keys: agentica always
  sends a session id, falling back to a per-process UUID. A payload without one is
  malformed, so decoding fails and the hook exits without printing — the
  fail-open path — rather than inventing a key.
- Every payload carries a `transport` block (`ppid`, `cwd`, `tty`, and the attach
  endpoint when there is one). The TTY in there is read from the agent's own stdin,
  so it beats anything the hook could infer about its parent; only the terminal
  *app* and pane id are still resolved locally, because those are facts about this
  machine's UI rather than about the agent process.
- `prompt` is the run's *anchor text* — the user's message on an ordinary turn,
  the goal objective in a goal-driven session. It is not "what the user just typed".
- `preview`, `error` and the other `tool.*` metadata are redacted by agentica
  before truncation, so they are safe to display; raw tool arguments and outputs
  are never on this wire.
- Island session ids are prefixed `agentica-` so they cannot collide with ids
  minted by another CLI.

### Lifecycle / liveness notes

`session.ended` covers a clean exit, but it cannot cover a hard kill, and agentica
rows are not process-tracked the way Codex and Claude rows are. So the row is
still *removed* by ageing it out 10 minutes after its last event
(`SessionState.expireIdleAgenticaSessions`). A session that is still waiting on the
user is never aged out. Generic process polling does not keep agentica sessions
alive; `transport.ppid` would make process-based liveness possible and is not
wired up yet.

### Install / uninstall

Agentica reads `settings.hooks` from `~/.agentica/config.yaml` (or
`$AGENTICA_HOME/config.yaml`) **once at startup**, so an install only takes
effect on the next `agentica` launch.

```bash
swift run OpenIslandSetup installAgentica
swift run OpenIslandSetup statusAgentica
swift run OpenIslandSetup uninstallAgentica
```

Or use **Settings → Setup → Agentica CLI** in the app.

`settings.hooks.consumers` is a list of **named** entries and agentica fans every
event out to all of them, so a hook wire is not a slot to win. Open Island owns
the entry called `open-island` and never reads, moves or deletes anyone else's:

```yaml
settings:
  hooks:
    enabled: true
    consumers:
      # somebody else's, untouched
      - name: vpet
        command: ["/Users/you/Library/Application Support/VPet/agent-notify/vpet-hook"]
        events:
          run.started: false

      - name: open-island
        command:
          - "/Users/you/Library/Application Support/OpenIsland/bin/OpenIslandHooks"
          - "--source"
          - "agentica"
```

`command` is an argv list, which is why a binary path containing spaces needs no
quoting rules. Omitting `events` subscribes to everything.

That file also holds every model profile and plaintext API key, and agentica
documents it as comment-preserving. So the installer edits **text**, scoped to our
own consumer entry, instead of round-tripping a YAML parser that would delete the
user's comments. The safety property that makes this acceptable is that an
unrecognized shape (an inline `settings: {...}`, tab indentation) is **refused with
an error, never guessed** — a wrong guess could write a duplicate key and make
agentica fall back to an empty config.

Three ownership rules follow:

- **Reinstalling rewrites only `name` and `command` inside our own entry.** A
  hand-tuned `events:` gate, and the comments around it, stay exactly as found.
- **`settings.hooks.enabled` is forced on**, because it is the wire's master
  switch and a disabled wire delivers nothing to anyone.
- **Uninstall removes our entry and nothing else.** A `consumers:` list with no
  entry of ours is left exactly as it is.

### Scope

- **The interactive `agentica` CLI is what is supported.**
  `install_hook_egress()` is called from agentica's interactive app, so `agentica
  run`, scripted use, cron and SDK embeddings emit nothing and the island stays
  quiet for them. This is the intended scope, not a gap.
- **No process-based liveness.** See the lifecycle note above.
- **Only the fields the island reads are modelled.** agentica also sends `run_id`,
  `agent_name`, `duration_seconds`, `had_response`, `title`, and — on
  `session.started` — `model`, `profile`, `permission_mode` and `transcript_path`.
  Unknown keys are ignored rather than rejected, so agentica can keep adding to the
  wire. A model badge is the obvious next use for those, but the existing badge
  path is `ClaudeSessionMetadata`, which is Claude-shaped; a source-neutral one has
  to come first.


---

## Terminal Auto-detection

The hook process infers the terminal type from environment variables at runtime:

| Environment variable | Inferred terminal |
|---|---|
| `ITERM_SESSION_ID` or `LC_TERMINAL=iTerm2` | `iTerm` |
| `CMUX_WORKSPACE_ID` or `CMUX_SOCKET_PATH` | `cmux` |
| `GHOSTTY_RESOURCES_DIR` | `Ghostty` |
| `WARP_IS_LOCAL_SHELL_SESSION` | `Warp` |
| `TERM_PROGRAM=Apple_Terminal` | `Terminal` |
| `TERM_PROGRAM=WezTerm` | `WezTerm` |

For iTerm, Terminal, and Ghostty the process additionally runs an AppleScript query to obtain the session ID, TTY, and window title — used to power the "jump back to terminal" feature. The `cmux` terminal uses `CMUX_SURFACE_ID` instead: an AppleScript query can only report the *focused* cmux terminal, which is not necessarily the one running the agent, so the id cmux exports into each surface is the only source that identifies this tab. It lands in `terminal_session_id`, and the app consumes it with `surface.focus` on cmux's control socket — which also switches workspace when the tab lives in another one.

That capture is not limited to the tmux case, and it is not dropped when the session does run inside tmux: the pane target and the surface id travel together, so one click selects the pane *and* brings its cmux tab forward. Every hook source that reports `terminal_app: cmux` fills the same field.

---

## Related source files

| File | Responsibility |
|---|---|
| [`Sources/OpenIslandHooks/OpenIslandHooksCLI.swift`](../Sources/OpenIslandHooks/OpenIslandHooksCLI.swift) | Hook CLI entry point — routes to Codex, Claude, Gemini, Grok, … |
| [`Sources/OpenIslandCore/CodexHooks.swift`](../Sources/OpenIslandCore/CodexHooks.swift) | Codex payload model, output encoder, terminal detection |
| [`Sources/OpenIslandCore/ClaudeHooks.swift`](../Sources/OpenIslandCore/ClaudeHooks.swift) | Claude Code payload model, directive types, output encoder |
| [`Sources/OpenIslandCore/ClaudeHookInstaller.swift`](../Sources/OpenIslandCore/ClaudeHookInstaller.swift) | Owns the `settings.json` hook entries for every Claude-family fork; `HookIdentity` keeps Open Island entries distinct from the commercial Vibe Island bridge |
| [`Sources/OpenIslandCore/GeminiHooks.swift`](../Sources/OpenIslandCore/GeminiHooks.swift) | Gemini CLI payload model, terminal detection, metadata helpers |
| [`Sources/OpenIslandCore/GrokHooks.swift`](../Sources/OpenIslandCore/GrokHooks.swift) | Grok Build payload model, terminal detection, lifecycle summaries |
| [`Sources/OpenIslandCore/GrokHookInstaller.swift`](../Sources/OpenIslandCore/GrokHookInstaller.swift) | Writes `~/.grok/hooks/open-island.json` |
| [`Sources/OpenIslandCore/PiHooks.swift`](../Sources/OpenIslandCore/PiHooks.swift) | Pi/OMP payload model and session metadata helpers |
| [`Sources/OpenIslandCore/PiExtensionInstallationManager.swift`](../Sources/OpenIslandCore/PiExtensionInstallationManager.swift) | Installs and removes the runtime-specific TypeScript extension |
| [`Sources/OpenIslandCore/PiSessionRegistry.swift`](../Sources/OpenIslandCore/PiSessionRegistry.swift) | Persists recent Pi and OMP sessions |
| [`Sources/OpenIslandApp/Resources/open-island-pi.ts`](../Sources/OpenIslandApp/Resources/open-island-pi.ts) | Shared Pi/OMP runtime extension |
| [`Sources/OpenIslandCore/BridgeServer.swift`](../Sources/OpenIslandCore/BridgeServer.swift) | Unix socket server — handles incoming hook payloads |
| [`Sources/OpenIslandCore/BridgeTransport.swift`](../Sources/OpenIslandCore/BridgeTransport.swift) | Protocol codec and envelope types |
