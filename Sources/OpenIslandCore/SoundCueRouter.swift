import Foundation

/// Decides which sound, if any, an incoming `AgentEvent` should play.
///
/// Kept in Core and kept pure: choosing a cue is the part that can be wrong in a
/// way nobody notices (a sound that never fires, or one that fires on every tool
/// call), so it is the part that needs tests. Playback belongs to the app layer.
///
/// ## Which events ring
///
/// The boundary is "only ring for something the user cannot already see":
///
/// | Event | Rings | Why |
/// |---|---|---|
/// | session registered | no | the user is looking at the terminal they just typed in |
/// | first prompt of a session | `taskAcknowledge` | "this piece of work has started" |
/// | later prompts in the same session | no | still the same piece of work; ringing every turn dilutes into noise |
/// | tool activity | no | a turn runs a dozen tools — that is a scrolling log, not a notification |
/// | turn finished | `taskComplete` | the user has probably looked away |
/// | turn failed | `taskError` | same, and it needs a different sound |
/// | waiting for approval / answer | `inputRequired` | the agent is blocked on the user |
/// | user-initiated interrupt | no | the user pressed the key themselves |
///
/// `sessionStart` therefore has no trigger. It stays in `SoundCue` because it is
/// a row of the upstream CESP table and because the settings pane previews all
/// five cues.
///
/// ## Failure detection
///
/// Only the Claude-family `StopFailure` hook currently sets
/// `SessionCompleted.isFailure`. Codex's rollout watcher marks a terminal
/// failure message as a plain completion, and Grok's failure hooks emit an
/// activity update rather than a completion, so those still ring
/// `taskComplete`. Guessing failure from summary text is not worth it — when
/// those wires learn to carry the flag, this router needs no change.
public struct SoundCueRouter: Sendable {

    /// Sessions that already produced their first cue.
    ///
    /// Only session IDs, and only for sessions observed during this app run, so
    /// the set stays in the tens. It is never consulted for anything but the
    /// "first turn" decision.
    private var acknowledgedSessionIDs: Set<String> = []

    public init() {}

    public mutating func cue(for event: AgentEvent) -> SoundCue? {
        switch event {
        case let .sessionStarted(payload):
            // Silent by design (see the table above), but a fresh session
            // registration means the next turn is a first turn again.
            acknowledgedSessionIDs.remove(payload.sessionID)
            return nil

        case let .activityUpdated(payload):
            guard payload.phase == .running else {
                return nil
            }

            return markAcknowledged(payload.sessionID) ? nil : .taskAcknowledge

        case let .permissionRequested(payload):
            _ = markAcknowledged(payload.sessionID)
            return .inputRequired

        case let .questionAsked(payload):
            _ = markAcknowledged(payload.sessionID)
            return .inputRequired

        case let .sessionCompleted(payload):
            // A completion is also the end of a first turn: a session that was
            // only ever seen completing must not ring "started" afterwards.
            _ = markAcknowledged(payload.sessionID)

            if payload.isInterrupt == true {
                return nil
            }

            return payload.isFailure == true ? .taskError : .taskComplete

        case .jumpTargetUpdated,
             .sessionMetadataUpdated,
             .claudeSessionMetadataUpdated,
             .geminiSessionMetadataUpdated,
             .openCodeSessionMetadataUpdated,
             .cursorSessionMetadataUpdated,
             .piSessionMetadataUpdated,
             .agenticaSessionMetadataUpdated,
             .sessionHeartbeat,
             .actionableStateResolved:
            return nil
        }
    }

    /// Returns whether the session had already been acknowledged.
    private mutating func markAcknowledged(_ sessionID: String) -> Bool {
        !acknowledgedSessionIDs.insert(sessionID).inserted
    }
}
