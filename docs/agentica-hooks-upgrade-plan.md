# Agentica hook wire: what Open Island depends on

Consumer-side record for Open Island's `--source agentica` integration.

The original version of this file was a gap analysis against agentica 1.4.x.
Almost all of it has since been implemented on the agentica side, so this is now a
record of what the wire guarantees — which is what Open Island depends on — plus
the scope decisions that closed the remaining questions.

## Delivered

Every item below is relied on by the integration; a regression in any of them is a
user-visible break, so they are listed as the contract rather than as history.

| Was | Now |
|---|---|
| Single `settings.hooks.command`; two desktop apps could not coexist | Named `consumers[]`, every event fanned out to all subscribers. Each installer owns one entry and touches nothing else. |
| `AGENTICA_HOOKS_COMMAND` split on whitespace, shredding paths with spaces | `AGENTICA_HOOKS_CONSUMERS` is a JSON array; no shell-string parsing anywhere. |
| No tool-level events | `tool.started` / `tool.completed` at the real execution boundary, with redacted `preview` / `error`. |
| No session lifecycle | `session.started` (with `model`, `profile`, `permission_mode`, `transcript_path`) and `session.ended`. |
| `needs.input` had no correlation id | Both `needs.*` carry a `request_id` that the reply must echo; a mismatched or missing id is discarded. |
| A request resolved elsewhere left the desktop card up forever | `needs.resolved` reports `decided_by` (`terminal` / `hook` / `cancelled`) and the winning `decision`. |
| No process identity on the hook wire | Every payload carries the `transport` block (`ppid`, `cwd`, `tty`, attach endpoint), same as the notify sink. |
| `session_id` omitted when there was no live `Agent` | Always present, falling back to a per-process UUID. |
| `HookProcess` waited for process exit to read a reply | Reads available bytes and races as soon as a complete document arrives; cleanup signals the whole process group. |
| Notices could linger | Fire-and-forget notices are bounded at 30s and reaped; `needs.*` still has no cap, which is correct. |

Two behaviours are worth calling out because a future refactor could plausibly
"fix" them into breakage:

- **`_nothing_more_queued()` returns `True` when there is no idle provider.** The
  call site is `not _nothing_more_queued()`, so `True` means "report the
  completion". Any process without the interactive CLI's provider — SDK, script,
  cron — depends on this. The docstring used to say `False`; it was the docstring
  that was wrong.
- **An unrecognized reply is "no decision", never `allow`.** Approving by accident
  is the one failure this channel must not have.

## Settled scope

### Interactive CLI only, on purpose

`install_hook_egress()` is called from `agentica/cli/interactive/app.py`, so
`agentica run`, scripted use, cron and SDK embeddings emit nothing. **This is the
intended scope**, not a gap: Open Island supports the agentica CLI.

`ensure_hook_egress_installed()` exists and is idempotent, so widening this later
is a matter of calling it from a shared bootstrap. Until someone asks for it, a
headless run is out of scope and the island stays quiet for one.

### `run.completed` ends a goal, not a lap

In a goal-driven session agentica **defers** the per-lap completions and releases
exactly one when the goal finishes (`notify/sink.py`, guarded by
`_goal_is_driving`). So `run.completed` is always end-of-turn and a consumer never
has to guess whether more laps are coming — no per-iteration flicker, no stalled
run.

Two consequences worth knowing before using the fields:

- **`duration_seconds` sums the laps.** On a released goal completion it is total
  busy time, deliberately: the question it answers is "how long was it working
  while I was away". `answer` is the last lap's, and `had_response` is sticky.
- **`run.failed` and `run.cancelled` are not deferred.** A failing lap reports
  immediately even when the goal carries on. That is the only honest option,
  because `goal.*` is deliberately kept off the external wire — one request
  becoming N runs is an agentica implementation detail — so a consumer cannot know
  a goal is driving. Open Island shows the failure and returns to running on the
  next lap's `run.started`.

## Nice to have

- **A source-neutral model badge.** `session.started` carries `model`, `profile`,
  `permission_mode` and `transcript_path`, and Open Island reads none of them: the
  existing badge path is `ClaudeSessionMetadata`, which is Claude-shaped, and
  routing agentica through it would be a lie. A source-neutral metadata event would
  make those four fields useful for every non-Claude CLI at once.
- **Process-based liveness.** `transport.ppid` is on the wire, so agentica sessions
  could be tracked the way Codex and Claude sessions are instead of ageing rows out
  on a 10-minute idle timer. Consumer-side work, not an agentica change — noted
  because that timer is the last remaining heuristic.

## Not proposed: an `agentica hooks install` subcommand

Worth recording as a rejected option. Editing `~/.agentica/config.yaml` is the
**consumer's** job, not agentica's: Open Island locates the file, adds its own
named consumer, and removes that entry on uninstall — the same thing it does for
`~/.claude/settings.json`, `~/.kimi/config.toml` and `~/.grok/hooks/*.json`. Asking
each agent product to ship an installer for us inverts the relationship, and it
would not reduce the work either, since the refuse-rather-than-guess and
comment-preservation logic has to exist on our side anyway for the other formats.

Named `consumers[]` already solved the part that actually mattered: with an
identity to key on, an installer can add and remove its own entry without ever
having to interpret anybody else's.
