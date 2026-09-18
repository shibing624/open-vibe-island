# Changelog

All notable changes to Open Island are recorded here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this project
adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

Released sections are transcribed from the published
[GitHub releases](https://github.com/Octane0411/open-vibe-island/releases),
which stay the source of truth for release notes, installation instructions,
and contributor credits. Each release's bilingual notes and download assets
live on the release page; this file keeps the English entries so the history is
readable in one place and greppable offline.

`Unreleased` collects work merged to `main` after the newest tag.

## [Unreleased]

- **Feature**: Support the agentica CLI. Managed hooks are installed for the
  agentica wire, adapted to its named multi-consumer egress, and delegated
  worker runs are dropped instead of growing a phantom island row per
  `delegate` call — a delegated worker is an implementation detail of the
  parent session, identified by `AGENTICA_DELEGATE_DEPTH` rather than guessed.
- **Feature**: Carry agentica tool names and answer text into session metadata.
  `AgenticaSessionMetadata` gives the hook's `tool.started` / `tool.completed`
  facts somewhere to land, so an agentica row shows the running tool and the
  finished answer instead of a bare `Running` / `Ready` label.
- **Feature**: Report a finished run by content rather than a status word. A
  completed row prefers the assistant message, then the hook's own summary
  (answer preview or `Finished: <prompt>`), and only falls back to `Done`.
- **Feature**: Add CESP event sound themes with per-event cues and a pack
  downloader, and bundle the bought-out Orc Peon pack so a fresh install has
  per-event sounds with no download step.
- **Feature**: End a session through confirmed-pid liveness between reconciles.
  A CLI that exits right after its last hook event used to linger on the island
  for up to two poll intervals; tracked pids are now re-checked every 2 s with
  `kill(pid, 0)`, with recycled-pid and ambiguity guards.
- **Feature**: Capture tmux pane identity at hook time. `tmuxTarget` was only
  ever filled by the process-polling paths, so every hook-driven session
  skipped the precise-jump branch and fell through to bare app activation. The
  capture lands in the shared `HookTerminalContext` and covers all five payload
  types that reach the Swift hook binary.
- **Feature**: Add a `--source` flag to the setup CLI for Claude-family forks.
- **Fix**: Stop reporting a tmux jump that landed somewhere else. `switch-client`
  and `select-window` had their exit codes discarded with `_ =`, so a jump that
  never left the old session still reported success; `list-clients` was read as
  "first line wins", which switched an arbitrary client when a server had more
  than one.
- **Fix**: Rank tmux pane matching by signal strength instead of pane order. The
  loop was pane-major, so a weak title match on an earlier pane could consume a
  session whose exact TTY belonged to a later one. TTY and pane id are
  identities and no longer lose to a substring title test.
- **Fix**: Store the tmux target in the `session:window.pane` form every
  consumer requires, instead of the raw `TMUX_PANE` value.
- **Fix**: Bound every terminal-automation subprocess and drain it while it
  runs. `waitUntilExit()` ran before the output pipe was read, so a child
  writing more than the pipe buffer deadlocked with its parent; most spawns
  also had no deadline, and the first `osascript` of a session can block
  indefinitely on the Automation (TCC) consent prompt.
- **Fix**: Keep an ended session from being reported as running again. The
  guard now lives in the reducer, which covers the paths that had no
  hand-written workaround; a late `.completed` still lands, so a terminal
  summary is not dropped.
- **Fix**: Focus the cmux tab when jumping to a cmux session. The hook binary
  never captured `CMUX_SURFACE_ID`, so the jump only brought cmux forward.
- **Fix**: Auto-collapse a completed card regardless of how it was opened.
- **Fix**: Re-arm the first-prompt chime only on a startup session. Claude Code
  re-registers the same session as `resume`, `clear` or `compact`, so
  `taskAcknowledge` used to ring again for work the user had already
  acknowledged.
- **Fix**: Keep Open Island hooks independent from the commercial Vibe Island.
- **Fix**: Restore the execute bits on scripts changed by patching, and drop a
  zsh-only glob qualifier so `sh scripts/fetch-sound-packs.sh` runs to its
  final summary instead of aborting after the packs are already installed.
- **Tests**: Pin one agentica turn end to end across the three metadata fixes,
  add the tmux/Ghostty resolver's first tests, and pin the
  terminal-registration invariants that have drifted before.
- **Docs**: Link the agentica hooks upgrade plan in the docs index.
- **Chore**: Add a clean-and-run script with launch liveness verification, and
  ignore superpowers plan output. Post-release plumbing for v1.2.1 (appcast
  entry, contributors image cache) also landed after the tag.

## [v1.2.1] - 2026-09-15 — Click Handling, Panel Morph & Jump-back Fixes

- **Fix**: Repair a closed island that keeps swallowing clicks. When a mouse-down reaches the panel while the island is closed and outside the pill, the panel now logs the stray click, re-applies click-through, re-orders the window so the WindowServer honours it, and reposts the click to whatever sits underneath (throttled to one repair per 0.5 s) (#689).
- **Fix**: Stop reposting outside clicks that already reached other apps. The global and local mouse monitors now tell the panel whether a click was delivered to Open Island itself; an outside click that another app already received closes the island without being synthesised a second time, which removes the double-click artifacts when dismissing the opened island (#682 by @hnrobert).
- **Fix**: Smooth the closed-to-open panel morph. The island surface now animates its size and corner radii inside the stable panel frame, starts from the closed pill's actual rendered width, and clips its content to the transitioning shape so nothing draws outside the surface mid-animation. Harness scenarios disable overlay event monitoring by default; set `OPEN_ISLAND_HARNESS_INTERACTIVE=1` to keep pointer interaction for manual verification (#662 by @CommitTheKermit).
- **Fix**: Skip the redundant tmux `switch-client` when the client is already on the target session. Jump-back reads `#{client_session}` alongside the client tty and only switches sessions when needed, so iTerm2's tmux integration (`tmux -CC`) no longer tears down and recreates its windows on every jump (#700 by @Buer2333).
- **Fix**: Map Qoder's real bundle ID for jump-back. Qoder 0.1.6 reports `com.qoder.app`, not `com.qoder.qoder`, so the workspace jump never matched and fell through to the first installed terminal. Qoder now has its own app descriptor with both identifiers, and jump-back activates the Qoder workspace directly (#692 by @jerryyon-eng).
- **Tests**: Loosen the CI timing bound in `CodexAppServerTimeoutTests`. The elapsed-time check that guards against hanging on a wedged app-server was tripping on CI runners at 2.0–2.4 s because parallel suites block on osascript timeouts; the floor is now 5 s with the intent unchanged (#702).

## [v1.2.0] - 2026-09-03 — Grok Build, Pi & Oh My Pi

- **Feature**: Support Grok Build / Grok CLI. Open Island installs a hook file at `~/.grok/hooks/open-island.json` covering the full session lifecycle — session start and end, prompts, tool use, subagents, `Stop`, `StopCancelled` and `StopFailure` — so Grok sessions, their activity and their completion show up in the island and jump back to the right terminal. Interrupted turns settle immediately; runtime bail-outs such as max turns surface as completions. Events are fire-and-forget for now (no permission round-trip). Install it from Settings → Setup (#630 by @neighborLing).
- **Feature**: Support the Pi coding agent and Oh My Pi. A TypeScript extension is installed into `~/.pi/agent/extensions` and `~/.omp/agent/extensions` and talks to the bridge socket directly, reporting session start, turns, tool execution and shutdown, with heartbeat-based liveness so a killed agent ages out on its own. Pi and Oh My Pi get their own colours and Settings → Setup rows, and the extension does not need the hooks binary (#639 by @UNICKCHENG).

## [v1.1.9] - 2026-09-03 — Usage Windows, Conductor & Stability Fixes

- **Feature**: Show every Claude usage window in the island header — 5h and 7d side by side, each with its own colour threshold and a countdown to its reset — instead of only the higher one. Narrow header lanes step down through shorter layouts before dropping anything (#675 by @danielhabila).
- **Feature**: Detect Claude Code sessions hosted by Conductor instead of showing `Unknown`. Session liveness follows the Conductor app, and jump-back activates it (#669 by @arenier).
- **Feature**: New opt-in setting to keep the island open until you approve, deny, or answer a pending request, so a stray click outside cannot dismiss it. It is off by default and only considers sessions shown in the island (#646 by @KesleyDavid, #679).
- **Fix**: Stop the Claude usage bridge from wrapping its own status-line script. A `$HOME`-style `statusLine.command` was mistaken for a user command and wrapped again on every relaunch, leaving the wrapper and its delegate spawning each other until the machine ran out of processes. Corrupted installs are repaired automatically, and the wrapper now refuses to re-enter itself (#676).
- **Fix**: Clear the Codex app-server read handlers at EOF. After the app-server child exited, both handlers kept firing and pinned two CPU cores (#668 by @TangHuaiZhe).
- **Fix**: Deliver the first click on a hover-opened island. Session rows previously needed a second click because AppKit spent the first one making the panel key (#678).
- **Fix**: Keep injected Codex context (`<environment_context>`, AGENTS.md instructions, `## My request for Codex:` wrappers) out of session titles and previews, and repair titles that were already cached (#611 by @qyy3369-hue).
- **Fix**: Tag transcript-discovered Claude Desktop sessions as `Claude.app` by reading the transcript's `entrypoint`, instead of leaving them as `Unknown` (#609 by @namearth5005).
- **Fix**: Label hook diagnostics in Settings by agent, and include OpenCode issues in the repair flow (#616 by @1AdityaX).
- **Infra**: Dev launch and packaging no longer re-render the tracked brand icons, which dirtied the worktree on machines with a different Pillow and leaked into unrelated commits (#680).

## [v1.1.8] - 2026-08-24 — Zed Support & Display Reliability

- **Feature**: Detect Zed and Zed Preview through `TERM_PROGRAM`, bundle identifier, and process parent instead of falling back to `Unknown`. Jump-back activates Zed and opens the project folder (#644 by @KesleyDavid).
- **Fix**: Decode hex-escaped UTF-8 paths when ingesting `cwd` and deriving workspace names, so Japanese and Chinese directory names no longer render as escaped byte sequences. Already-persisted titles are decoded too (#643 by @KesleyDavid).
- **Fix**: Preserve the selected display preference when an external monitor is disconnected and reconnected, instead of falling back to another screen (#655 by @leaft).
- **Fix**: Clear completed Claude background subagents by reading task-notification records from newly appended transcript lines. Claude does not always deliver a matching `SubagentStop` hook, which previously left finished agents marked active (#647 by @wenqiw777).
- **Fix**: Prevent session-row agent and terminal badges from wrapping mid-word under layout compression (#640 by @KesleyDavid).
- **Tests**: Make display- and pointer-dependent tests deterministic on notched MacBooks, complete the Swift Testing migration, and add a Command Line Tools-compatible test runner for toolchains without Xcode (#661 by @sakutarooo).
- **Docs**: Restore the Star History chart in the English and Chinese READMEs (#660 by @FaintFlower).

## [v1.1.7] - 2026-08-03

- Reduced sustained CPU usage during Codex.app session rediscovery by reading only newly appended rollout data instead of reparsing entire files.
- Prevented overlapping rediscovery scans from stacking CPU work.
- Preserved session results across partial lines, truncation, and same-size rollout rewrites.

## [v1.1.6] - 2026-07-13 — Notarized Reissue

- **Distribution**: Rebuilt the app as v1.1.6 with successful Apple notarization and stapled tickets for both the app bundle and DMG. It now launches normally through Gatekeeper.
- **Infra**: Added a manual notarization credential preflight and made credential or notarization failures stop the release unless `SKIP_NOTARIZE=true` is explicitly configured (#598).

## [v1.1.5] - 2026-07-13 — Hook & Display Reliability

- **Fix**: Detect active OpenCode processes that do not expose a TTY in IDE-integrated terminals, preventing their sessions from disappearing shortly after they appear (#590 by @imlx).
- **Fix**: Keep the managed hook helper running when stderr is closed or its pipe reader disappears, so diagnostic logging cannot terminate hook delivery (#593 by @Octane0411).
- **Fix**: Refresh monitor-picker entries after display hotplug, sleep/wake, and arrangement changes. Explicit display selections now use stable Core Graphics UUIDs, avoiding cases where a reused display ID maps a saved choice to another physical monitor (#594, originally contributed in #494 by @leaft).
- **Compatibility**: Display preferences saved by earlier releases reset once to **Automatic** after upgrading. If you previously selected a fixed monitor, select it again in Settings. AirPlay and virtual displays may also fall back to Automatic when their fallback identity changes.
- **Fix**: Remove Kimi's common empty, single-line top-level `hooks = []` or `hooks = [ ]` placeholder before installing managed `[[hooks]]` entries. The cleanup handles trailing comments and CRLF files while preserving similarly named content inside nested tables and strings (#595, originally contributed in #499 by @YingchaoX).

## [v1.1.4] - 2026-06-29 — Session Stability

- **Fix**: Keep distinct Codex.app threads visible as separate island sessions, avoiding false count drops when multiple threads share the same workspace/title (#567 by @Octane0411).
- **Fix**: Detect Cursor CLI `cursor-agent` sessions from running processes and attach them to the correct workspace/TTY when hooks have not created a session yet (#567 by @Octane0411).
- **Fix**: Detect Codex managed hook feature support correctly so installed hooks are recognized reliably (#550 by @GenjiCy, with implementation commits by @chenyangyang).
- **Fix**: Keep Codex CLI sessions independent from Codex.app liveness, and clean up completed non-Codex.app Codex sessions correctly (#545 by @wenqiw777, #563 by @GenjiCy with implementation commits by @chenyangyang, #567 by @Octane0411).
- **Fix**: Keep Claude Desktop local-agent sessions visible while Claude.app is running, with the known usage-panel limitation documented (#556 by @huangzhenghz).
- **Fix**: Reduce idle monitoring CPU usage while keeping Codex.app maintenance responsive (#557 by @cyberhal).
- **Infra**: Harden smoke harness validation for current UI state and AX summary jitter (#565 and #566 by @Octane0411).
- **Release**: Make notarization credential validation best-effort so a signed release can still be produced when Apple Developer agreements block notary validation (#568 by @Octane0411).
- **Docs**: Update Homebrew cask installation guidance (#523 by @SSakutaro).

## [v1.1.3] - 2026-06-03 — Codex Approvals

- **Feature**: Added managed Codex `PermissionRequest` hook support with approve/deny responses, flexible tool input decoding, and a 1-hour interactive timeout (#477)
- **Fix**: Prevent stale Codex approval clicks from mutating session state after the hook process has disconnected (#477)
- **Fix**: Keep completed Claude sessions completed when a late `SubagentStop` hook arrives after the parent `Stop` event (#489)
- **Tests**: Stabilized the Claude subagent regression test for the macOS 26 CI runner (#524)

## [v1.1.2] - 2026-05-12 — Memory Pressure Fix

- **Fix**: Reduced severe memory pressure in long-running sessions by removing the v1.1.1 Codex CLI periodic rollout rediscovery loop and returning CLI discovery behavior to the pre-v1.1.1 model (#484).
- **Fix**: Stream Codex rollout and Claude transcript parsing instead of loading full JSONL files into memory on discovery paths (#484).
- **Fix**: Reduced retained UI/background work by releasing inactive opened-island content, cancelling the appearance preview auto-cycle with SwiftUI task lifecycle, and pruning long-lived session ordering state (#484).
- **Fix**: Added cleanup and bounds around long-lived bridge, Codex app-server, Watch relay, and pending context paths to reduce retained state during extended use (#484).

## [v1.1.1] - 2026-05-09 — Codex and Notification Fixes

- **Fix**: Mark Claude Code sessions complete when newer away-summary notifications arrive after a missed or delayed stop event (#470)
- **Fix**: Keep completion and notification cards visible and stable while hovered, including preventing replacement by another notification and resetting measured heights for changed card content (#471, #475)
- **Fix**: Rediscover active Codex CLI sessions when Codex keeps older session logs open, so new sessions created after app startup still appear in the island (#473)
- **Fix**: Improve Codex session status labels for thinking, shell commands, patch edits, tools, web search, image generation, compaction, approvals, and questions (#474)
- **Fix**: Use the current session's agent/tool name in completion-card reply placeholders instead of always saying Claude (#472)
- **Docs**: Restore the README banner and clarify that PRs should be ready for review by default unless explicitly requested as draft or blocked by known gaps (#469, #476)

## [v1.1.0] - 2026-05-09 — Redesigned Island and Session List

- **Feature**: Redesigned the island appearance and session list with refreshed visuals, per-display appearance profiles, grouping, sorting, stale-session controls, notification styling, and settings previews (#458)
- **Feature**: Added per-process hook skip controls with `OPEN_ISLAND_SKIP_HOOKS=1` and the legacy `VIBE_ISLAND_SKIP=1` alias for delegated or wrapper-managed agent runs (#462) — thanks @ViperThanks

## [v1.0.30] - 2026-05-09 — Codex hooks compatibility

- **Fix**: Updated Codex hook installation for the v0.130 feature flag rename from `codex_hooks` to `hooks`, while still recognizing legacy installs (#463) — thanks @ViperThanks
- **Fix**: Choose the Codex hooks feature flag based on the installed Codex CLI version, preserving compatibility with newer and older Codex builds (#464)
- **Docs**: Clarified README wording for the Codex CLI managed installer in English and Chinese (#461) — thanks @ViperThanks
- **Chore**: Removed the debug-only Control Center panel and aligned user-facing docs and copy around Settings as the canonical configuration surface (#455)
- **Docs**: Slimmed down agent workflow documentation and clarified feature worktree rules for future contributions (#452, #456)

## [v1.0.29] - 2026-05-02 — VS Code Forks + Homebrew

- **Fix**: Detect VS Code forks (Cursor / Windsurf / Trae / Qoder / CodeBuddy) before stock VS Code in the process tree, so click-to-jump activates the correct editor (#441) — thanks @Carl-Dai
- **Fix**: Keep overlay pinned during macOS's "click wallpaper to reveal desktop", Mission Control, and Show Desktop (#423) — thanks @MVPGFC
- **Feature**: Distribute via Homebrew tap — `brew install --cask octane0411/tap/openisland` (#427)
- **Chore**: Remove menu bar status item and popover; the icon was nearly invisible and the popover surfaced dev-only controls (#443, closes #425, #428)
- **Docs**: Clarify Codex hook coverage limits in README (#440) — thanks @ViperThanks

## [v1.0.28] - 2026-04-29 — Stability Fixes

- **Fix**: Wire Launch at Login toggle to SMAppService (#398)
- **Fix**: Register openWindow from MenuBarExtra label so Settings opens reliably (#413) — thanks @dumatoma
- **Fix**: Add missing `auto` case to ClaudePermissionMode enum (#409) — thanks @wuzeyou

## [v1.0.27] - 2026-04-22 — Quit Button & External Display Polish

- **Feature**: Add quit button to island header (#361) — thanks @opriz
- **Feature**: Support free-text "other" option in ask-user UI (#380) — thanks @mdolr
- **Fix**: Narrow closed island on external displays (#383)
- **Fix**: Clear Cursor agent indicator from notch after inactivity timeout (#350) — thanks @stmartins

## [v1.0.26] - 2026-04-19 — External Display Tool Call & Question UI Redesign

- **Feature**: Show active tool call in closed island on external displays (#372)
- **Feature**: Redesign ask-user-question UI with vertical CLI-style options (#367) — thanks @mdolr
- **Fix**: Overhaul OpenCode process discovery and session liveness tracking (#369) — thanks @Raygooo

## [v1.0.25] - 2026-04-18 — Kimi CLI Support & Hook Intent

- **Feature**: Add Kimi CLI hook support — TOML installer, process detection, settings UI, and CLI commands (#362)
- **Fix**: Respect hook uninstall intent + empty-state prompts (#365)
- **Docs**: Add Codex Desktop App to supported agents in README (#358)

## [v1.0.24] - 2026-04-17 — Codex Desktop App Support

- **Feature**: Codex Desktop App support — detection, WebSocket lifecycle, precise jump via `codex://threads/<id>` (#343)
- **Fix**: Recognize Claude binaries at non-standard install paths & show hidden files in directory selection (#336) — thanks @Raygooo
- **Fix**: Add macOS safe zone padding to app icon (#354)

## [v1.0.23] - 2026-04-17 — Wrapper Mode & Mission Control Fix

- **Feature**: Install Claude usage bridge in wrapper mode when statusLine is occupied (#330) — thanks @DoTheWorkNow
- **Fix**: Auto-close overlay when entering Mission Control (#344)
- **Fix**: Generalize empty-state prompt to not hardcode Codex (#331) — thanks @DoTheWorkNow
- **Chore**: Disable Sparkle auto-update check in DEBUG builds (#334) — thanks @DoTheWorkNow

## [v1.0.22] - 2026-04-15 — Reply from Completion Card

- **Feature**: Reply to agent from completion card (#327)
- **Fix**: Suppress notifications for frontmost terminal sessions (#326) — thanks @Piping
- **Fix**: Update expired Discord invite link (#325)
- **Chore**: Add external contributor thanks convention to release template (#318)

## [v1.0.21] - 2026-04-14 — Gemini CLI Support & UI Fixes

- **Feature**: Add Gemini CLI hook integration (#312) — thanks @Cynosure159
- **Feature**: Auto-install Gemini hooks on startup (#309) — thanks @Cynosure159
- **Feature**: Reveal hook config locations in setup (#315) — thanks @Cynosure159
- **Fix**: Completion notification content truncated instead of scrollable (#317)
- **Fix**: Add preference toggle for Codex usage display (#316)
- **Fix**: Include boundary edges in island hit testing (#313) — thanks @itswenb
- **Chore**: Use static Discord badge to hide online count (#306)
- **Chore**: Update WeChat group QR code (#305)

## [v1.0.20] - 2026-04-13 — Session List Scroll Fix

- **Fix**: Session list not scrollable when content under AutoHeightScrollView threshold (#302)

## [v1.0.19] - 2026-04-13 — Traditional Chinese & Panel Fix

- **Feature**: Add Traditional Chinese (zh-Hant) language option (#299) — thanks @DingWeizhe
- **Fix**: Fix panel height clipping and notification mode regression (#300) — thanks @LuoboTian

## [v1.0.18] - 2026-04-12 — Gemini Setup UI & Responsive Settings

- **Feature**: Add Gemini CLI hook row to Settings > Setup page (#288)
- **Fix**: Make settings panel content adaptive when resized (#289)

## [v1.0.17] - 2026-04-12 — Gemini CLI Support & Trae CN

- **New Agent**: Gemini CLI hook integration — payload model, installer, bridge, Control Center UI (#277) — thanks @destinyfrancis
- **Fix**: Support alternate bundle identifier for Trae CN app (#255) — thanks @ethanjin
- **Feature**: Settings window is now freely resizable (#281)
- **Docs**: Update READMEs with Gemini CLI support (#285)

## [v1.0.16] - 2026-04-11 — Apple Watch, Auto-Hide & Warp Precision Jump

- **Feature**: Apple Watch + iOS companion app with Bonjour discovery, WCSession, notifications, and action resolution (#272)
- **Feature**: Island auto-hide with hover edge reveal (#276) — thanks @seedoilz
- **Feature**: Warp precision tab jump via SQLite polling + PID-based pane lookup (#266) — thanks @loop2zero
- **Feature**: Stable self-signed dev identity so TCC grants survive rebuilds (#263) — thanks @loop2zero
- **Fix**: Remove alpha channel from iOS and watchOS app icons (#274)
- **Docs**: Update READMEs with Warp support details (#279)

## [v1.0.15] - 2026-04-11 — Appearance Customization & IDE Window Fix

- **Feature**: Appearance settings tab with default/custom mode and custom avatar glyph (#267) — thanks @fengren & @LE-0111
- **Fix**: Jump to correct VS Code/JetBrains window when multiple are open (#269)
- **Docs**: Add bilingual privacy policy for App Store submission (#270)

## [v1.0.14] - 2026-04-10 — Haptic Feedback & Warp Support

- **Feature**: Haptic feedback on hover for island panel (#250) — thanks @St0ff3l
- **Feature**: All-contributors integration with auto cache-bust (#252, #253)
- **Fix**: Identify Warp terminal and harden unknown-terminal fallback (#254) — thanks @loop2zero

## [v1.0.13] - 2026-04-10 — tmux Jump & Remote Session Fix

- **Feature**: tmux session/window/pane jump support (#247) — thanks @graelo
- **Fix**: Remote session dismiss button and hover feedback (#246) — thanks @dashan0313
- **Docs**: Sync CLAUDE.md, AGENTS.md, and all docs with current supported scope (#245, #249)

## [v1.0.12] - 2026-04-10 — Cursor Support & Custom Config Dir

- **Feature**: Support `CLAUDE_CONFIG_DIR` environment variable for custom config directories with auto-refresh (#242)
- **Feature**: Add quit button to About settings pane (#239) — thanks @fengren
- **Fix**: Detect Cursor terminal via `CURSOR_TRACE_ID` before `TERM_PROGRAM=vscode` (#241) — thanks @ObiTracks
- **Fix**: Detect Cursor.app via bundle ID for session liveness (#236) — thanks @toddwyl

## [v1.0.11] - 2026-04-10 — Qwen Code Support & Layout Fix

- **New Agent**: Add Qwen Code agent support (#226)
- **Fix**: Prevent infinite layout loop in notification panel sizing (#227)
- **Docs**: Update READMEs for international audience and GitHub Trending (#225, #228, #229, #230, #231) — thanks @MarkLKK

## [v1.0.10] - 2026-04-09 — IDE Jump & Notch Fix

- **Feature**: Workspace-level jump for VS Code, JetBrains, Windsurf, Trae (#223)
- **Fix**: Ensure island fills full notch height on notch screens (#222)
- **Perf**: Skip redundant state writes in reconciliation (#219)

## [v1.0.9] - 2026-04-09 — Cursor Support & Smooth Animations

- **Feature**: Integrate Cursor hooks (#210) — thanks @toddwyl
- **Refactor**: Fixed-size window for jank-free island animations (#213)
- **Perf**: Optimize session row hover rendering (#214)
- **Fix**: Stable hover-open timing with cancel grace period (#217)
- **Docs**: Add News section to README (#199)

## [v1.0.8] - 2026-04-09 — Zellij Support & Animation Polish

- **Feature**: Add Zellij terminal multiplexer support (#198) — thanks @XciD
- **Fix**: Use panel fade-out for island close transition (#205)
- **Fix**: Hide scroll indicators and re-disable NSScrollView scrollers on every layout pass (#206, #209)
- **Fix**: Add padding and styling to markdown table cells (#188)
- **Docs**: Add community roadmap with contribution focus areas (#191)

## [v1.0.7] - 2026-04-08 — Animation Polish & Docs

- **Perf**: Unify animation system — remove AppKit/SwiftUI animation desync (#186)
- **Docs**: Add CONTRIBUTING.md (EN) and CONTRIBUTING.zh-CN.md (#185)
- **Docs**: Update product/architecture docs, clean up obsolete files (#187)
- **Chore**: Move community section higher in README (#180)

## [v1.0.6] - 2026-04-08 — Approval UI & Performance

- **Perf**: Fix UI jank from layout thrashing, sync blocking, and redundant state updates (#169)
- **Feature**: Replace hardcoded permission mode buttons with dynamic approval actions (#170)
- **Fix**: Match Claude Code option text and show approval state in session list (#177)
- **Fix**: Correct approval buttons, preserve session state, fix launch script (#179)

## [v1.0.5] - 2026-04-08 — Hook Health Check & Multi-Agent Support

- **Feature**: Hook health check, auto-repair & diagnostics UI (#148)
- **Feature**: Add support for Qoder, Factory, and CodeBuddy agents (#165)
- **Feature**: Add Qoder/Factory/CodeBuddy to Settings setup guide (#168)
- **Fix**: Bridge auto-reconnect, stable socket, dual-socket compatibility (#167)
- **Fix**: Update appcast.xml and automate Sparkle updates (#163)
- **Infra**: Appcast update via PR instead of direct push (#171, #172, #175)

## [v1.0.4] - 2026-04-08 — Subagent & Task Fixes

- **Fix**: Use correct camelCase field names for Claude Code task tools (#159)
- **Fix**: Clean up stale subagent indicators via timeout and turn-end (#160)
- **Fix**: Cap panel height to match AutoHeightScrollView max (#164)
- **Fix**: Extract task ID from nested response object (#166)

## [v1.0.3] - 2026-04-08 — Intel Support & Polish

- **Feature**: Add Intel (x86_64) Mac support for builds and packaging (#145)
- **Perf**: Reduce hover delay to 150ms and animation duration to 300ms (#146)
- **Fix**: Widen closed count badge to prevent digit compression (#147)
- **Fix**: Eliminate blank space at bottom of island session list (#151)
- **Fix**: Correct Claude Code task status tracking (#153)
- **Fix**: Rename CLI entry points for x86_64 build compatibility (#154, #156)
- **Fix**: Prevent NSApp.setActivationPolicy crash in CI tests (#150)

## [v1.0.2] - 2026-04-08 — UX Polish

- **Feature**: Dock icon is now visible by default for new users (#144)
- **Fix**: Island idle height misalignment on MacBook Air M2 notch (#140)

## [v1.0.1] - 2026-04-08 — Hook-Based Session Lifecycle

- **Fix**: Claude Code sessions now use hook-based lifecycle instead of process polling for visibility (#136)
- **Fix**: Corrected process liveness threshold for Codex sessions (was immediately marking dead on first missed poll) (#136)
- **Docs**: Added bilingual release template and release policy (#138)

## [v1.0.0] - 2026-04-08 — 首个正式签名公证版本 🎉

- **Apple Developer ID 签名** — 应用已通过 Apple 代码签名
- **Apple 公证（Notarization）通过** — 经过 Apple 安全审查，macOS Gatekeeper 不再拦截
- **Stapled ticket** — 公证凭据已嵌入应用包，离线安装也不会弹警告
- macOS 原生 Notch/Top-bar 浮窗，实时显示 AI Agent 会话状态
- 支持 Codex 和 Claude Code 双 Agent 监控
- Unix Socket IPC 桥接，通过 Hook 机制自动连接 Agent
- 支持 Terminal.app、Ghostty 终端自动检测与跳转
- SSH 远程 Claude Code 支持（Python hook 客户端）
- 会话持久化与自动恢复

## [v0.2.1] - 2026-04-07 — SSH Remote Support

- **Feature**: SSH remote Claude Code support via Python hook client (#121)
- **Feature**: Remote session detection with SSH badge in UI (#121)
- **Feature**: One-command remote setup script and in-app setup guide (#121)
- **Infra**: Add SKIP_NOTARIZE flag to release workflow (#122)

## [v0.2.0] - 2026-04-07 — Code Signing

- **Feature**: App is now signed with Apple Developer ID certificate (#113)
- **Feature**: Sparkle framework and all nested binaries are properly signed (#115 #117)
- **Feature**: Notarization support in release workflow (best-effort with timeout) (#118)
- **Infra**: Automated release pipeline with certificate import, signing, and DMG packaging (#113 #114)
- **Fix**: Move SPM resource bundle to Contents/Resources/ for sealed code signing (#116)

## [v0.1.9] - 2026-04-06 — OpenCode Support & iTerm2

- **Feature**: Add OpenCode agent support via JS plugin bridge (#107)
- **Feature**: Add OpenCode plugin installer and auto-install at startup (#108)
- **Feature**: Add iTerm2 attachment probe for precise session detection (#105)
- **Fix**: iTerm2 jump-back now raises window and switches tab (#109)
- **Fix**: Dev app launch on macOS 26 (unsealed contents workaround) (#109)
- **Fix**: Dock icon not disappearing when toggled off at runtime (#111)
- **Fix**: Remove unimplemented behavior toggles in General settings (#103)
- **Docs**: Add badges for release, discord, and license to README (#110)

## [v0.1.8] - 2026-04-06 — Dock Icon Toggle

- **Feature**: Add Dock icon toggle in Settings > General > Behavior (#90)
- **Docs**: Update README with agents, auto-update status, star history & contributors (#99)

## [v0.1.7] - 2026-04-06 — Patch Release

- **Fix**: Restore SPM resource bundle to .app root — fixes crash on launch for all users except the build machine (#100)
- **Infra**: Add out-of-repo smoke test to packaging script — catches local environment hacks before release (#100)

## [v0.1.6] - 2026-04-06 — Sparkle Auto-Update

- **Feature**: Integrate Sparkle framework for automatic app updates — check and install updates without leaving the app (#88)
- **Feature**: Auto-update installed hooks binary on app launch — hooks stay in sync after app updates (#88)
- **Fix**: Correct GitHub repo URL in UpdateChecker (#86)
- **Fix**: Align dev/prod bundle structure, add CI package verification (#87)
- **Fix**: TTY-based pane matching for Kaku/WezTerm multi-pane support (#94)
- **Fix**: Add @loader_path/../Frameworks rpath for Sparkle, move resource bundle to Contents/Resources (#96)
- **Docs**: Update terminal support status for Kaku and WezTerm (#93)

## [v0.1.5] - 2026-04-06 — Patch Release

- **Fix**: Fix launch crash on Mac Mini and other non-notch Macs (#85)

## [v0.1.4] - 2026-04-06 — Patch Release

- **Feature**: Add Setup tab in settings with auto-install on first launch (#81)
- **Fix**: Prevent Codex completion notification from flashing and disappearing (#82)
- **Fix**: Suppress duplicate/stale Codex completion notifications (#80)
- **Fix**: Clean script bugs and update install docs for unsigned app (#78)
- **Chore**: Add --skip-setup flag to launch-dev-app.sh (#79)

## [v0.1.3] - 2026-04-06 — Patch Release

- **Feature**: Add version update checker in Settings (#77)
- **Fix**: Completion card content area not rendering due to drawingGroup + empty text (#67)
- **Fix**: Correct xattr command and add M5 chip in release template (#76)
- **CI**: Add plutil lint for .strings files to catch syntax errors early (#75)

## [v0.1.2] - 2026-04-06 — Patch Release

- **Fix**: Copy SPM resource bundle into app bundle to fix startup crash (#70)
- **Fix**: Pass `executableDirectory` to `HooksBinaryLocator` so release DMG can find hooks binary (#73)
- **Fix**: Sign DMG and fix notarization order in `package-app.sh` (#69)
- **Docs**: Add release process documentation (#65)
- **Docs**: Add hooks page to docs index (#68)
- **Chore**: Add GPL v3 license (#66)
- **Chore**: Organize brand logo source asset (#59)

## [v0.1.1] - 2026-04-05 — Patch Release

- **Feature**: Add uninstall hooks button with confirmation dialog in Settings (#63)
- **Fix**: Hook status incorrectly reported as installed when JSON format differs (#61)
- **Docs**: Add product screenshot and remove demo placeholder (#62)
- **Docs**: Add feature status tables and agent-powered issue template (#60)

## [v0.1.0] - 2026-04-05 — Early Access

- Real-time agent session status in the notch/top-bar
- Permission request notifications with one-click approval
- Jump back to the corresponding terminal context
- Supports Claude Code and Codex agents
- Works with Terminal.app, Ghostty, and cmux

[Unreleased]: https://github.com/Octane0411/open-vibe-island/compare/v1.2.1...HEAD
[v1.2.1]: https://github.com/Octane0411/open-vibe-island/compare/v1.2.0...v1.2.1
[v1.2.0]: https://github.com/Octane0411/open-vibe-island/compare/v1.1.9...v1.2.0
[v1.1.9]: https://github.com/Octane0411/open-vibe-island/compare/v1.1.8...v1.1.9
[v1.1.8]: https://github.com/Octane0411/open-vibe-island/compare/v1.1.7...v1.1.8
[v1.1.7]: https://github.com/Octane0411/open-vibe-island/compare/v1.1.6...v1.1.7
[v1.1.6]: https://github.com/Octane0411/open-vibe-island/compare/v1.1.5...v1.1.6
[v1.1.5]: https://github.com/Octane0411/open-vibe-island/compare/v1.1.4...v1.1.5
[v1.1.4]: https://github.com/Octane0411/open-vibe-island/compare/v1.1.3...v1.1.4
[v1.1.3]: https://github.com/Octane0411/open-vibe-island/compare/v1.1.2...v1.1.3
[v1.1.2]: https://github.com/Octane0411/open-vibe-island/compare/v1.1.1...v1.1.2
[v1.1.1]: https://github.com/Octane0411/open-vibe-island/compare/v1.1.0...v1.1.1
[v1.1.0]: https://github.com/Octane0411/open-vibe-island/compare/v1.0.30...v1.1.0
[v1.0.30]: https://github.com/Octane0411/open-vibe-island/compare/v1.0.29...v1.0.30
[v1.0.29]: https://github.com/Octane0411/open-vibe-island/compare/v1.0.28...v1.0.29
[v1.0.28]: https://github.com/Octane0411/open-vibe-island/compare/v1.0.27...v1.0.28
[v1.0.27]: https://github.com/Octane0411/open-vibe-island/compare/v1.0.26...v1.0.27
[v1.0.26]: https://github.com/Octane0411/open-vibe-island/compare/v1.0.25...v1.0.26
[v1.0.25]: https://github.com/Octane0411/open-vibe-island/compare/v1.0.24...v1.0.25
[v1.0.24]: https://github.com/Octane0411/open-vibe-island/compare/v1.0.23...v1.0.24
[v1.0.23]: https://github.com/Octane0411/open-vibe-island/compare/v1.0.22...v1.0.23
[v1.0.22]: https://github.com/Octane0411/open-vibe-island/compare/v1.0.21...v1.0.22
[v1.0.21]: https://github.com/Octane0411/open-vibe-island/compare/v1.0.20...v1.0.21
[v1.0.20]: https://github.com/Octane0411/open-vibe-island/compare/v1.0.19...v1.0.20
[v1.0.19]: https://github.com/Octane0411/open-vibe-island/compare/v1.0.18...v1.0.19
[v1.0.18]: https://github.com/Octane0411/open-vibe-island/compare/v1.0.17...v1.0.18
[v1.0.17]: https://github.com/Octane0411/open-vibe-island/compare/v1.0.16...v1.0.17
[v1.0.16]: https://github.com/Octane0411/open-vibe-island/compare/v1.0.15...v1.0.16
[v1.0.15]: https://github.com/Octane0411/open-vibe-island/compare/v1.0.14...v1.0.15
[v1.0.14]: https://github.com/Octane0411/open-vibe-island/compare/v1.0.13...v1.0.14
[v1.0.13]: https://github.com/Octane0411/open-vibe-island/compare/v1.0.12...v1.0.13
[v1.0.12]: https://github.com/Octane0411/open-vibe-island/compare/v1.0.11...v1.0.12
[v1.0.11]: https://github.com/Octane0411/open-vibe-island/compare/v1.0.10...v1.0.11
[v1.0.10]: https://github.com/Octane0411/open-vibe-island/compare/v1.0.9...v1.0.10
[v1.0.9]: https://github.com/Octane0411/open-vibe-island/compare/v1.0.8...v1.0.9
[v1.0.8]: https://github.com/Octane0411/open-vibe-island/compare/v1.0.7...v1.0.8
[v1.0.7]: https://github.com/Octane0411/open-vibe-island/compare/v1.0.6...v1.0.7
[v1.0.6]: https://github.com/Octane0411/open-vibe-island/compare/v1.0.5...v1.0.6
[v1.0.5]: https://github.com/Octane0411/open-vibe-island/compare/v1.0.4...v1.0.5
[v1.0.4]: https://github.com/Octane0411/open-vibe-island/compare/v1.0.3...v1.0.4
[v1.0.3]: https://github.com/Octane0411/open-vibe-island/compare/v1.0.2...v1.0.3
[v1.0.2]: https://github.com/Octane0411/open-vibe-island/compare/v1.0.1...v1.0.2
[v1.0.1]: https://github.com/Octane0411/open-vibe-island/compare/v1.0.0...v1.0.1
[v1.0.0]: https://github.com/Octane0411/open-vibe-island/compare/v0.2.1...v1.0.0
[v0.2.1]: https://github.com/Octane0411/open-vibe-island/compare/v0.2.0...v0.2.1
[v0.2.0]: https://github.com/Octane0411/open-vibe-island/compare/v0.1.9...v0.2.0
[v0.1.9]: https://github.com/Octane0411/open-vibe-island/compare/v0.1.8...v0.1.9
[v0.1.8]: https://github.com/Octane0411/open-vibe-island/compare/v0.1.7...v0.1.8
[v0.1.7]: https://github.com/Octane0411/open-vibe-island/compare/v0.1.6...v0.1.7
[v0.1.6]: https://github.com/Octane0411/open-vibe-island/compare/v0.1.5...v0.1.6
[v0.1.5]: https://github.com/Octane0411/open-vibe-island/compare/v0.1.4...v0.1.5
[v0.1.4]: https://github.com/Octane0411/open-vibe-island/compare/v0.1.3...v0.1.4
[v0.1.3]: https://github.com/Octane0411/open-vibe-island/compare/v0.1.2...v0.1.3
[v0.1.2]: https://github.com/Octane0411/open-vibe-island/compare/v0.1.1...v0.1.2
[v0.1.1]: https://github.com/Octane0411/open-vibe-island/compare/v0.1.0...v0.1.1
[v0.1.0]: https://github.com/Octane0411/open-vibe-island/releases/tag/v0.1.0
