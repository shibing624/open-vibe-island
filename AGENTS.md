## Project

Open Island — native macOS companion for AI coding agents. Sits in the notch / top bar, monitors local sessions, surfaces permission and question events, and jumps back to the right terminal/IDE. Local-first, no server.

- **Target product** (closed-source baseline): https://vibeisland.app/
- **OSS reference** (design ideas only, not a spec): https://github.com/farouqaldori/claude-island

## Architecture

One Swift package (`OpenIsland`), four targets:

- **OpenIslandApp** — SwiftUI + AppKit shell. `AppModel` owns state.
- **OpenIslandCore** — Models, bridge transport (Unix socket, NDJSON), hook installers, session discovery & registry.
- **OpenIslandHooks** — CLI invoked by agent hooks. Forwards stdin payload → bridge.
- **OpenIslandSetup** — Installer CLI for agent config files.

Data flow: `agent hook → OpenIslandHooks (stdin) → Unix socket → BridgeServer → AppModel → UI`. On launch: registry restore → JSONL transcript discovery → reconcile with active processes → live bridge.

Requires macOS 14+, Swift 6.2.

## Build & run

```bash
swift build
swift test
swift run OpenIslandApp                            # canonical dev runtime
swift build -c release --product OpenIslandHooks
```

For Xcode: open `Package.swift`.

## Dev app (Open Island Dev.app)

`~/Applications/Open Island Dev.app` is a wrapper around the repo build, not a separate product.

- **Launch**: `zsh scripts/launch-dev-app.sh` — never just `open -na`, the bundle goes stale.
- **One-time signing**: `zsh scripts/setup-dev-signing.sh` — without this every rebuild changes cdhash and silently invalidates TCC grants (Accessibility, Automation). Required for any AX-touching feature (precision jump, keystroke/menu injection).
- `scripts/harness.sh smoke` / `scripts/smoke-dev-app.sh` are for deterministic harness runs only.

## Scope guardrails

Current support matrix (agents / terminals / IDEs) lives in `README.md` — that's the single source of truth, keep it accurate at release time.

The project is past MVP and welcomes new ideas and creative directions, but the following stay off-limits without an explicit ask:

- Analytics or telemetry SDKs (Mixpanel etc.)
- Window-manager dependencies (`yabai` etc.)
- Claude-only assumptions that weaken the multi-agent model
- Anything that breaks local-first (remote-server dependencies, cloud-only paths)

## Release

- Bilingual required (English + 简体中文). Template: `.github/RELEASE_TEMPLATE.md`. Entry format: `- **Category**: English (#PR)\n  中文 (#PR)`. External contributors get `— Thanks @user` on the English line.
- Title: `Open Island vX.Y.Z — Short English Title`. Installation section bilingual.

## Conventions

- `SessionState.apply(_:)` is the single source of truth for session mutations.
- Bridge protocol: newline-delimited JSON envelopes (`BridgeCodec`).
- All models `Sendable` + `Codable`.
- Hooks **fail open** — if app/bridge is down, the agent runs unchanged.
- Native macOS APIs over cross-platform abstractions. Small end-to-end slices over speculative scaffolding.

## Key files

- `Sources/OpenIslandApp/AppModel.swift` — central state, session management, bridge lifecycle
- `Sources/OpenIslandCore/SessionState.swift` — pure reducer
- `Sources/OpenIslandCore/AgentEvent.swift` — event enum driving all transitions
- `Sources/OpenIslandCore/BridgeTransport.swift` + `BridgeServer.swift` — socket protocol & dispatch
- `Sources/OpenIslandCore/{Claude,Codex,Gemini,Kimi,Cursor}Hooks.swift` etc. — per-agent hook payload models
- `Sources/OpenIslandHooks/main.swift` — hook CLI entry
- `docs/product.md`, `docs/architecture.md`, `AGENTS.md` — design / working-agreement docs

This file defines the working agreement for the coding agent in this repository.

## Product Boundaries

- Keep product scope in `docs/product.md`. Do not duplicate the supported agent, terminal, or IDE matrix here.
- Do not broaden supported tools, runtimes, platforms, or environments unless the user explicitly asks.
- Keep hook behavior aligned with `docs/hooks.md` and the implementation in `Sources/OpenIslandCore`.

## Integration Guardrails

- Treat `Codex CLI` and `Codex Desktop App` as distinct runtime surfaces.
- Do not assume Codex file edits are covered by `PreToolUse`; Codex may edit through internal apply-patch paths.
- Keep managed Codex CLI hooks low-noise unless the user explicitly asks for richer hook coverage.
- Keep Claude-family integrations source-specific in user-facing behavior, even when payload formats are shared.
- Treat Gemini hooks as fire-and-forget unless the code being edited explicitly supports blocking behavior.

## App Targets And Naming

- Treat the repository executable product `OpenIslandApp` as the canonical OSS app runtime.
- Treat `swift run OpenIslandApp` and the Xcode app target as the source-of-truth way to run the current branch's app code.