# Notch Surface Model

The island now separates layout from content surface:

- `closed`: collapsed notch only
- `opened + sessionList`: manual browsing of attached sessions
- `opened + approvalCard`: auto-expanded approval interaction
- `opened + questionCard`: auto-expanded question interaction
- `opened + completionCard`: auto-expanded finished-task reminder

Routing rules:

- manual click or hover opens `sessionList`
- `permissionRequested` opens `approvalCard`
- `questionAsked` opens `questionCard`
- `sessionCompleted` opens `completionCard`

Auto-expanded cards are temporary surfaces:

- they auto-collapse after a short timeout
- they also collapse when the pointer leaves the card after first hover
- they are not rendered as inline actions inside the session list

This keeps the session list focused on navigation while question and approval
flows use dedicated notification surfaces.

### Transience is a property of the card, not of how it was opened

Whether a surface may close itself is decided solely by
`IslandSurface.autoDismissesWhenPresentedAsNotification`, which is true exactly
when the surface fronts a session with nothing left to answer. `NotchOpenReason`
only records *why* the overlay opened (`.click`, `.hover`, `.notification`,
`.boot`) and must not gate the dwell timer.

This distinction matters because the same card is reachable several ways. A
finished session can be surfaced by its completion event, opened by a manual
click, or widened into the full session list; all three must behave the same.
When the timer was conditioned on `.notification`, a completed card reached by
click had no path back to closed except an explicit dismissal, and widening a
completion card into the list cancelled the timer without re-arming it, leaving
the island open indefinitely.

The converse rule is equally load-bearing: a session awaiting a decision is
never transient for *any* open reason. An unanswered approval or question card
cannot be timed out from under the user, so it stays until it is answered.

The wait-for-first-hover guard is scoped the same way. It exists so a card that
appears under the cursor is not dismissed before it can be read, so it applies
only to surfaces that appeared on their own. A click-opened list was explicitly
requested by the user and may close as soon as the pointer leaves.

The main DEV window is now a dedicated debug harness for these surfaces. It
drives inline mock previews for the session list plus approval, question, and
completion cards, and it can mirror the currently selected mock onto the real
island overlay for visual inspection.
