# Architecture

## System Shape

The project is a single Swift package with four targets:

| Target | Role |
|---|---|
| **OpenIslandApp** | SwiftUI + AppKit shell — menu bar extra, overlay panel (notch/top-bar), settings. Entry point: `OpenIslandApp.swift` with `AppModel` as the central `@Observable` state owner. |
| **OpenIslandCore** | Shared library — models (`AgentSession`, `AgentEvent`, `SessionState`), bridge transport (Unix socket IPC with JSON line protocol), hook models/installers, transcript discovery, session persistence/registry. |
| **OpenIslandHooks** | Lightweight CLI executable invoked by agent hooks. Reads hook payload from stdin, forwards to app bridge via Unix socket, writes blocking JSON to stdout only when island denies a `PreToolUse`. |
| **OpenIslandSetup** | Installer CLI for managing `~/.codex/config.toml` and `hooks.json`. |

## Data Flow

### Hook-based agents (Codex, Claude Code, and forks)

```
Agent
  │  stdin: JSON payload
  ▼
OpenIslandHooks CLI  (--source codex | --source claude | ...)
  │  Unix socket
  ▼
BridgeServer → AppModel → UI
  │  BridgeResponse
  ▼
OpenIslandHooks CLI
  │  stdout: JSON directive (only when a response is needed)
  ▼
Agent
```

### Plugin-based agents (OpenCode)

```
OpenCode → JS plugin (~/.config/opencode/plugins/) → Unix socket → BridgeServer → AppModel → UI
```

### Session discovery (on launch)

1. Restore cached sessions from registry
2. Discover recent JSONL transcripts (`~/.claude/projects/`)
3. Reconcile with active terminal processes
4. Start live bridge

**Fail-open principle**: if the bridge is unavailable, the hook process exits silently without writing to stdout, so the agent continues running unaffected.

## Event Model

The shared `AgentEvent` enum drives all state transitions:

- Session started / updated / completed
- Permission requested
- Question asked
- Tool use (pre/post)
- Subagent lifecycle
- Jump target updated

Each event carries a stable session identifier, agent type, timestamps, and enough metadata to route approvals or focus changes.

## State Management

- `SessionState.apply(_:)` is the single source of truth for session mutations (pure reducer)
- `AppModel` owns all live state and bridge lifecycle
- All models are `Sendable` and `Codable`

## Transport

- Unix domain sockets for app ↔ hook communication
- Newline-delimited JSON envelopes (`BridgeCodec`)
- Bridge server lives inside the app process

## Terminal Jump-Back

Terminal focus restoration is implemented per-terminal:

| Terminal | Strategy |
|---|---|
| Terminal.app | TTY targeting via AppleScript |
| Ghostty | Window ID matching |
| cmux | Unix socket API (`surface.focus` on `CMUX_SOCKET_PATH`) |
| Kaku | CLI pane targeting |
| WezTerm | CLI pane targeting |
| iTerm2 | AppleScript session/TTY probe |
| tmux (multiplexer) | switch-client → select-window → select-pane |

The hook helper enriches payloads with terminal-local hints (terminal app, TTY, session ID, window title) from environment inspection at hook invocation time.

### Matching a session to a tab

Every terminal host is queried for a list of its tabs, and each session is then
matched to one of them. The signals are not interchangeable, so the order below
is load-bearing:

1. **Identity** — a terminal session id (Ghostty surface, iTerm session, cmux
   surface, WezTerm/Kaku pane id) or a TTY names exactly one tab.
2. **The session id inside the tab title.** Agent CLIs title their tab after the
   conversation they are running, and in a standalone Ghostty that title is the
   *only* identity a tab carries: the environment exports no surface id there and
   the scripting dictionary exposes neither a tty nor a process.
3. **Working directory** and **title**, which are weak: several agents of one
   kind in one repository share a working directory, and their titles repeat.

An identity decides on its own. A weak signal is allowed to bind only when
exactly one candidate tab matches — the count is taken inside the AppleScript for
the jump itself, and in Swift for the resolver and the attachment probe. A weak
signal that several tabs share identifies none of them; binding anyway raises
whichever tab the terminal happens to enumerate first, which is a jump onto
another agent's conversation, and it looks intermittent because that order
follows tab focus and reordering.

The same rule applies to the hook that captures the target: a focus-scoped
AppleScript locator (`focused terminal of …`, `current session of current window`,
`selected tab of front window`) may only be asked at `SessionStart` and
`UserPromptSubmit`, when the agent's own tab is the focused one. Asking on later
events stamps whichever tab is frontmost onto the session that fired.

## Technologies

- SwiftUI for most UI composition
- AppKit for panel behavior, status item control, and activation policy edge cases
- Unix domain sockets for IPC
- JSON event envelopes for debugging and adapter simplicity
- Sparkle for auto-updates

## Engineering Rules

- Preserve clean separation between UI state and transport concerns
- Version the event schema so adapters can evolve safely
- Keep setup reversible when editing third-party tool config files
- Keep the runtime surface bound to real agent state rather than shipping UI-level demo toggles
