# Agentica hook wire: assessment and upgrade plan

Written from the consumer side, after implementing `--source agentica` against
agentica **1.4.x** (`agentica/shell_hooks/`, `agentica/notify/`,
`agentica/run_events.py`, `agentica/runner/loop.py`, `agentica/cli/approvals.py`,
`agentica/cli/interactive/ask_hook.py`).

## Verdict

The existing wire is **enough to ship an integration, and not enough to ship the
product**. Everything Open Island needs in order to *reply* is already there and
well designed; almost nothing it needs in order to *show what is happening* is.

Concretely, the island can today say "Agentica is running in ~/proj" and "it
finished", and can answer an approval or a question. It cannot say which tool is
running, cannot tell that the CLI has quit, and shows nothing at all for
non-interactive runs.

The most useful finding is that this is **not missing data**. agentica already
computes per-tool-call activity and hands it to its own renderer; it is simply not
exported. See G1 — the fix is plumbing, not new instrumentation.

### The two external channels

agentica has two ways to talk to a desktop app, and they carry the *same four*
lifecycle events:

- **notify sink** (`settings.notify`) — HTTP over a Unix socket, observe-only,
  fire-and-forget. Envelope adds a `transport` block (`ppid`, `cwd`, `tty`,
  optional attach endpoint), which is how a consumer jumps back to the session.
- **shell hooks** (`settings.hooks`) — spawns an argv command with JSON on stdin.
  Same four `run.*` notices plus the two `needs.*` requests, and it is the only
  channel that takes a reply.

Open Island uses the hook channel because it needs to answer approvals. Note the
sink's `transport` block already carries the process identity that the hook wire
omits — see G6.

The gaps below are ordered by user-visible payoff, not by implementation cost.

## What is already right (do not change)

These are load-bearing decisions that a consumer depends on. Listing them so a
refactor does not quietly drop one:

| Decision | Where | Why a consumer needs it |
|---|---|---|
| `command` is an argv list, a string is refused | `config.py:49` | The installed binary path contains spaces (`~/Library/Application Support/…`). No quoting rules to get wrong. |
| Optional fields omitted, never null | `protocol.py:59` | A missing key and an empty string are genuinely different states. |
| Unrecognized reply = no decision, never `allow` | `protocol.py:80` | The one failure this channel must not have. |
| No wait cap invented in the hook layer | `requests.py:9` | A desktop answer must not get less time than a typed one. |
| Terminal and hook race; second answer is not an error | `requests.py:13` | Lets the consumer stay silent as a valid response. |
| stdout drained on its own thread even for notices | `process.py:7` | A consumer that prints anything cannot wedge a run. |
| `events` block gates all six events in one place | `config.py:19` | New events can ship default-on without taking away the user's off switch. |
| Config read once at install time | `egress.py:10` | No half-wired channel mid-run. |

## P0 — blocks the island's core loop

### G1. Tool-call activity exists, but cannot reach an external consumer

agentica **does** report tool calls — just not on any wire that leaves the
process. There are two separate event buses, and only the weaker one is exported:

| Bus | Values | Tool calls? | Who can read it |
|---|---|---|---|
| `RunEvent` (`run_response.py:24`) | `ToolCallStarted`, `ToolCallCompleted`, `ToolCallFailed`, `Reasoning*`, `Subagent*`, … | **yes**, with `tools: [ToolCallInfo]` | in-process only: the CLI's own renderer (`run_display.py:68`), the subagent runtime (`subagents/runtime.py:528`), any SDK caller iterating `agent.run(stream=True)` |
| `RunEventType` (`run_events.py:29`) | 4 × `run.*` + 4 × `goal.*` | **no** | `Runner._emit_event` → `notify_sink_dispatch` → both external egresses |

`notify_sink_dispatch` is fed exclusively from `Runner._emit_event`, which only
ever carries a `RunEventType`. So no config can surface tool activity today: the
notify sink gates on `RUN_EVENTS` (4 names) and the hook egress gates on
`SHELL_HOOK_EVENTS` (those 4 plus the 2 `needs.*`), and `event_enabled` reads any
unlisted name as off. The information is already computed one layer below, at
`runner/loop.py:1127-1158`, where the loop translates
`ModelResponseEvent.tool_call_started` / `_completed` into yielded chunks.

**Proposed** — three small edits at sites that already exist:

1. Add to `RunEventType`:
   ```
   tool_started    tool_name, tool_call_id, preview
   tool_completed  tool_name, tool_call_id, ok: bool, error?, duration_seconds
   ```
2. Call `_emit_event` for them at the two `loop.py:1127-1158` branches that
   already have the `ToolCallInfo` in hand. This is also the order
   `run_events.py`'s own scope rule asks for — *"Add the emit site first, then
   add the enum value in the same change."*
3. Add the two names to `SHELL_HOOK_EVENTS` (and `RUN_EVENTS` if the sink should
   carry them too).

Fire-and-forget on the `run.*` path, not requests: approval already owns the
blocking case, and a second gate on the same call would be a second place to
deadlock.

**Payoff:** this single change is the difference between a progress row and a
status surface. It is the highest-value item on this list by a wide margin, and
because the data already exists it is mostly plumbing.

**Also worth fixing while there:** `run_events.py:12` claims the Runner emits
`tool.failed` and `subagent.spawned`. Neither is in the enum. A consumer reading
that docstring would build against events that never arrive.

### G2. No session lifecycle

There is no `session.started` / `session.ended`. `run.*` is per-run, so quitting
the CLI produces no event at all, and a consumer cannot distinguish "the agent is
thinking" from "the process is gone".

Open Island currently ages an agentica row out 10 minutes after its last event.
That is a workaround with two visible costs: a finished session lingers for ten
minutes, and a genuinely long-running tool call is indistinguishable from a dead
CLI.

**Proposed:**

```
session.started  session_id, cwd, source: "startup" | "resume", model?, profile?
session.ended    session_id, reason: "exit" | "clear" | "error"
```

`session.ended` should fire on the interactive CLI's shutdown path (including
Ctrl-D / Ctrl-C), which is the same place the CLI already kills in-flight hook
processes.

**Payoff:** removes the timer heuristic entirely, and lets the island show a
session as gone the moment it is gone.

### G3. Hooks only fire in the interactive CLI

`install_hook_egress()` has exactly one production call site:
`agentica/cli/interactive/app.py:790`. So `agentica run`, one-shot invocations,
scripted use and every SDK embedding emit nothing, even with
`settings.hooks.enabled: true`. From a user's point of view the feature is silently
absent half the time, and the config gives no hint why.

**Proposed:** install the egress from a shared bootstrap that every entry point
passes through (the runner / `Agent` construction), keyed off the same config.
Installation is already idempotent and already a no-op when `effective` is false,
so this needs no new guard.

**Payoff:** the same hooks work for `agentica run` in CI, for a scripted batch job,
and for a library embedding — which is where a desktop status surface is arguably
most useful, because there is no TUI to look at.

### G4. A resolved request is never announced

When the terminal wins the race, `HookProcess.kill()` closes the pipe and that is
all the consumer learns. The desktop's approval card has no idea it is obsolete.
Open Island works around this by clearing a parked card when the *next* lifecycle
event arrives, which can be much later — or never, if the run is still going.

**Proposed:**

```
needs.resolved   request_id, event: "needs.approval" | "needs.input",
                 decided_by: "terminal" | "hook" | "cancelled", decision?
```

Emitted from the point that already decides the race
(`agentica/cli/approvals.py`, `ask_hook.py`), on the fire-and-forget path.

**Payoff:** removes a class of stuck UI that a consumer cannot fix on its own.

## P1 — correctness and identity

### G5. No correlation id on `needs.input`

`needs.approval` carries `tool_call_id`, so a reply can be attributed. A question
carries nothing (`question_payload` sends only `question` and `options`). If two
questions overlap, or one is superseded, a desktop reply can be applied to the
wrong prompt — and the consumer cannot even detect that it happened.

**Proposed:** a `request_id` on **both** `needs.*` payloads, echoed by the
consumer in its reply and ignored (as today) when absent. Then
`parse_reply` can drop a reply whose `request_id` no longer matches, which closes
the race properly instead of relying on the kill being fast enough.

### G6. No process identity in the payload

`config.py:56` deliberately leaves `$PPID` and the controlling TTY to a user who
writes `["/bin/sh", "-c", …]`. That is a coherent position for a notifier, but it
does not survive contact with a desktop consumer, which needs to (a) know whether
the agent is still alive and (b) raise the *specific* terminal pane on click.

The notify sink already answers exactly this, in its `transport` block
(`sink.py:228`): `ppid`, `cwd`, `tty`. So the information is considered
consumer-relevant on one channel and withheld on the other — and the hook channel
is the one whose consumer has to *act*.

Open Island currently recovers both by calling `getppid()` inside the hook and
reading the parent's TTY with `ps`. This works only because agentica spawns the
binary directly — the moment a user adopts the `/bin/sh -c` form the docstring
suggests, the parent becomes a shell that exits and both signals are lost.

**Proposed:** put the sink's `transport` block on the hook payload too. Same
fields, same meaning, one implementation. Both are cheap, neither is sensitive,
and it makes the payload self-describing rather than requiring the consumer to
introspect its own parent.

### G7. `session_id` is optional

`build_payload` omits `session_id` when it is falsy, which happens for any run
dispatched without a live `Agent`. A consumer must then invent a key; Open Island
falls back to hashing `cwd`, which merges concurrent runs in one directory into one
row.

**Proposed:** always send a `session_id`, falling back to a per-process UUID
minted once. A stable synthetic id is strictly better than no id, and the consumer
cannot mint a better one.

### G8. No model / profile / mode metadata

Nothing on the wire says which model or profile is running, or whether
auto-approve is on. Open Island shows the model for other CLIs and cannot for
agentica. `session.started` (G2) is the natural carrier; adding `model` and
`profile` there costs nothing extra.

## P2 — bugs and ergonomics

### G9. `AGENTICA_HOOKS_COMMAND` splits on whitespace

```python
# config.py:126
command = _env("COMMAND")
if command is not None:
    cfg.command = _parse_command(command.split())
```

This is the exact whitespace-splitting that `_parse_command` refuses on the
config path, with a warning explaining why. Via the env var it happens silently,
so any path containing a space — including the standard macOS
`~/Library/Application Support/…` — is shredded into broken argv elements and the
hook simply never runs.

**Proposed:** parse the env value as a JSON array, and refuse a bare string the
same way the config path does. That keeps one rule for the whole feature.

### G10. One hook slot, and desktop consumers have to fight over it

`settings.hooks.command` is a single argv list, so agentica runs **exactly one**
hook command. Two desktop consumers cannot both listen. This is not hypothetical:
the config on this machine already routes the wire at VPet's
`agent-notify/vpet-hook`, so installing Open Island means turning VPet's hook off.

Open Island now refuses that install rather than winning silently, and offers an
explicit takeover. But that is damage control, not the right shape. A hook wire is
inherently multi-subscriber: VPet notifying its pet is VPet's business, a beeper
beeping is the beeper's business, and Open Island drawing an island is ours. None
of that should require taking anything away from the others.

**Proposed:** make `settings.hooks` a list of named consumers.

```yaml
settings:
  hooks:
    enabled: true
    consumers:
      - name: vpet
        command: ["…/vpet-hook"]
        events: { run.started: false, needs.approval: true }
      - name: open-island
        command: ["…/OpenIslandHooks", "--source", "agentica"]
```

`name` is the load-bearing part: it lets each installer add, update and remove
**its own** entry without parsing or touching anyone else's. `events` belongs per
consumer, because which events you care about is a property of the consumer — VPet
muting `run.*` because the notify sink already covers it is VPet's decision, not a
global one. Keep top-level `command` working as sugar for a single anonymous
consumer so existing configs keep running.

**`needs.*` with N consumers** generalizes the race that already exists rather
than introducing ambiguity. Today it is terminal vs one hook; then it is terminal
vs N hooks, with the same rules: spawn the subscribed consumers **in parallel**,
**first usable reply wins**, kill the rest, silence is not an answer. The one
thing to get right is not degenerating into serial waits, which would multiply
latency by N. `request_id` (G5) becomes more valuable here, since it is what tells
you *which* request a given reply belongs to.

Once this lands, Open Island's takeover prompt and `--take-over-hook-slot` flag
both go away.

### G11. No transcript path

Claude and Codex both hand over a `transcript_path`, which is how a consumer
renders the conversation rather than just its summary. agentica persists sessions
somewhere; exposing that path on `session.started` would enable the same.

### G12. `run.completed` semantics on goal loops are undocumented

Open Island treats `run.completed` as end-of-turn, but the wire does not say
whether a goal-driven session emits it per iteration or once at the end. Whichever
it is, it belongs in the docstring: a consumer that guesses wrong either flickers a
completion card per iteration or shows a stalled run.

## Backward compatibility

Every item above is additive:

- New event names, no renames. Consumers switch on `hook_event_name` and must
  ignore unknown values — Open Island already does.
- New payload fields are optional; existing fields keep their meaning.
- The `events` block already defaults absent keys to on
  (`ShellHooksConfig.__post_init__`), so new events ship enabled while remaining
  individually switchable.
- Replies stay one JSON document with the same two keys; `request_id` is honoured
  when present and ignored when absent.

## What Open Island does once each lands

Prioritisation aid — the consumer-side work is already written and gated only on
the wire:

| Item | What the island can then show |
|---|---|
| G1 tool events | Live per-tool activity and tool-failure cards, i.e. parity with Claude / Codex rows |
| G2 session lifecycle | Rows that appear and disappear with the CLI; the 10-minute idle timer is deleted |
| G3 non-interactive install | Any agentica run at all, including CI and SDK embeddings |
| G4 `needs.resolved` | Approval cards that dismiss themselves when the terminal answers |
| G5 `request_id` | Replies that cannot be applied to the wrong prompt |
| G6 `pid` / `tty` | Reliable liveness and click-to-raise-the-right-pane |
| G8 model / profile | Model badge on the session row |
| G10 multi-consumer wire | Open Island and VPet both listen; the takeover prompt is deleted |

## Not proposed: an `agentica hooks install` subcommand

Worth recording as a rejected option. Editing `~/.agentica/config.yaml` is the
**consumer's** job, not agentica's: Open Island already locates the file, rewrites
`settings.hooks` in place, and removes its own block on uninstall — the same thing
it does for `~/.claude/settings.json`, `~/.kimi/config.toml` and
`~/.grok/hooks/*.json`. Asking each agent product to ship an installer for us
inverts the relationship, and it would not even reduce the work: the refuse-rather-
than-guess and comment-preservation logic has to exist on our side anyway for the
other five formats.

The one thing that *would* help is `settings.hooks` becoming multi-consumer
(G10) — but that is a capability gap, not an install-flow convenience.
