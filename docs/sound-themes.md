# Event Sound Themes

Open Island can play a different sound for each kind of agent event, and switch
all of them at once by picking a *theme*. Themes are CESP (Community Event Sound
Pack) v1.0 packs — the same format the commercial Vibe Island app consumes from
the [PeonPing registry](https://PeonPing.github.io/registry/index.json).

## Bundled and downloaded audio

The Orc Peon pack (`peon`) is bought out for this project and committed under
`Sources/OpenIslandApp/SoundPacks/peon/`, shipped inside the app bundle via
SPM's `.copy("SoundPacks")` resource rule. A fresh install therefore already
has per-event sounds — no download step.

Every other pack in the fetch script's table is upstream game audio from the
PeonPing registry, whose manifests declare `CC-BY-NC-4.0` (non-commercial).
Those stay downloaded, never committed: they are personal-use only and cannot
be redistributed with this project.

Downloaded packs are installed outside the repository:

```
~/Library/Application Support/OpenIsland/SoundPacks/<pack>/
```

Install them with:

```bash
./scripts/fetch-sound-packs.sh            # everything in the pack table
./scripts/fetch-sound-packs.sh peon       # just one pack
./scripts/fetch-sound-packs.sh --list     # show the table, download nothing
```

Downloaded archives are cached in `~/Library/Caches/OpenIsland/sound-packs/`
(`og-packs` is a single 62 MB archive holding five packs, so it is cached per
repository rather than per pack).

The pack table in the script marks which packs are non-commercial game audio and
which are MIT / CC0 synthesized UI sounds. Only the latter could ever ship with a
build beyond the bought-out `peon`.

## Without a pack: the System theme

The reserved theme id `system` plays one macOS alert sound for every event —
exactly what Open Island did before themes existed. Settings then shows the
system sound list.

Once packs exist and the user has not chosen a theme, `peon` (Warcraft Orc Peon)
is selected. That default is hard-coded in `EventSoundService.preferredThemeID`
rather than derived from "first pack alphabetically", so installing a new pack
never silently changes the default. A downloaded pack whose id collides with a
bundled one is dropped in favor of the bundle.

## The five categories

`SoundCue` in `Sources/OpenIslandCore/SoundTheme.swift` mirrors the upstream
category table. `SoundCueRouter` decides which agent event triggers which cue,
under one rule: **only ring for something the user cannot already see.**

| Cue | Manifest key | Triggered by | Rings |
|---|---|---|---|
| `sessionStart` | `session.start` | — | no |
| `taskAcknowledge` | `task.acknowledge` | first `activityUpdated(.running)` of a session | yes |
| `taskComplete` | `task.complete` | `sessionCompleted` | yes |
| `taskError` | `task.error` | `sessionCompleted(isFailure: true)` | yes |
| `inputRequired` | `input.required` | `permissionRequested`, `questionAsked` | yes |

Notes on the two rows that surprise people:

- **`sessionStart` has no trigger.** A session is registered the moment the user
  types `claude` in a terminal they are looking at; a chime there carries no
  information. The cue stays in the table because it is part of the upstream
  protocol and because Settings previews all five.
- **Only the *first* prompt of a session rings.** Follow-up turns are the same
  piece of work, and one ring per turn dilutes into background noise. Tool
  activity inside a turn never rings — a turn runs a dozen tools.

### Only `startup` re-arms the first prompt

Claude Code re-registers the *same* session whenever context is resumed, cleared
or compacted, and it says which it was in the `SessionStart` payload's `source`
(`startup` / `resume` / `clear` / `compact`). Automatic compaction can fire
mid-conversation while the user is still working, so treating every
re-registration as "a new session" made the *next* prompt ring
`taskAcknowledge` again — the same work announced twice.

The router therefore re-arms the first prompt only on `startup`; the three
continuations leave the session acknowledged and the next prompt stays silent.
A genuinely new session needs no re-arming — its id is not in the set yet.

`startupSource` is read off the Claude metadata, because Claude Code is the only
agent whose wire reports a start source. Every other source reads `nil` and is
treated as a continuation, which is the conservative direction and costs
nothing.

A user-initiated interrupt (`isInterrupt`) is silent: the user pressed the key.

### Failure detection is partial

`SessionCompleted.isFailure` is set today only by the Claude-family `StopFailure`
hook. Codex's rollout watcher records a terminal failure message as a plain
completion, and Grok's failure hooks emit an activity update rather than a
completion, so both still ring `taskComplete`. Inferring failure from summary
text would be guessing; when those wires carry the flag, the router needs no
change.

## Pack layout

```
SoundPacks/peon/
  PeonReady1.wav
  PeonYes3.wav
  PeonAngry4.wav
  theme.json
```

Audio is flat inside the pack; categories exist only in `theme.json`. Some
upstream packs list the same 150 files under every category, and per-category
subdirectories would copy them once per category.

`theme.json` is a trimmed manifest written by the fetch script, keeping the CESP
field spellings so the script trims rather than translates:

```json
{
  "name": "peon",
  "display_name": "Orc Peon",
  "version": "1.0.0",
  "license": "CC-BY-NC-4.0",
  "author": { "name": "tonyyont", "github": "tonyyont" },
  "cesp_version": "1.0",
  "source_repo": "PeonPing/og-packs",
  "source_path": "peon",
  "categories": {
    "task.complete": [{ "file": "PeonReady1.wav", "label": "Ready to work?" }],
    "task.error": [{ "file": "PeonAngry4.wav", "label": "Me not that kind of orc!" }]
  }
}
```

Rules the app enforces:

- **Sounds are chosen by category, never by file name.** The manifest already
  states which sound means "finished" and which means "error".
- **`license` is optional.** The bundled `peon` pack declares none (bought
  out); downloaded packs carry theirs verbatim, and Settings shows the row
  only when the pack declares one.
- **A missing category borrows from the rest of the same pack**, in a fixed order
  so the choice is reproducible. Falling back to a macOS alert would make the
  pack sound broken; another line from the same pack still sounds like the pack
  the user chose. Settings labels borrowed categories.
- **Multiple sounds in one category rotate in order**, with a counter per
  category. Random repeats often enough to look stuck, and per-category counters
  keep three finished turns sounding like three different completions.
- **Cues longer than three seconds are dropped at install time.** Upstream does
  not separate "cue" from "whole track" — score-based packs have 10-second
  entries, and a cue longer than the event it announces is noise. Duration comes
  from `afinfo`, not file size, because mp3 and wav bitrates differ by an order
  of magnitude inside one pack.

## Settings

`Settings > Sound` exposes:

- mute (the island's existing switch) and volume
- one theme picker — switching a theme replaces all five sounds, because a
  coherent set is the point of a theme
- **Rescan Sound Packs**, for running the fetch script while the app is open
- per-event previews, not per-file: the question being answered is "do I like
  the finished sound", and each category rotates through its files anyway
- pack attribution: sound count, author, license (when declared), source
  repository

## Code map

| File | Role |
|---|---|
| `Sources/OpenIslandCore/SoundTheme.swift` | manifest parsing, category selection, borrowing, rotation, pack location |
| `Sources/OpenIslandCore/SoundCueRouter.swift` | agent event to cue, including the first-turn rule |
| `Sources/OpenIslandApp/EventSoundService.swift` | `AVAudioPlayer` playback, theme selection, volume, System fallback |
| `Sources/OpenIslandApp/NotificationSoundService.swift` | macOS system alert sounds |
| `scripts/fetch-sound-packs.sh` | downloader and manifest trimmer |
| `Sources/OpenIslandApp/SoundPacks/peon/` | the bundled pack: audio plus manifest |

Sound cue selection is pure logic and lives in Core because its failure mode is
invisible — a cue that never fires, or one that fires on every tool call.

## Tests

The suite is deliberately silent. It runs hundreds of times a day, and a test
that makes noise is a test people stop running, so no test may reach playback.

That is a constraint on new tests, not just a note about old ones, because the
app layer is what reaches `EventSoundService`: `AppModel` and
`OverlayUICoordinator` call it on the way to presenting a notification surface.
So a test that feeds a bridge event into a real `AppModel` plays the bundled
pack — the cue rides along with the card.

What is safe is the pure part: parse the manifest and resolve audio URLs
directly, the way `BundledSoundThemeTests` does. That covers loading and
selection without touching playback.
