import Foundation

/// How a terminal addresses one of its sessions.
///
/// This exists because a session identity has to mean the same thing everywhere
/// it is compared, and one of them arrives in two shapes.
enum TerminalSessionIdentity {
    /// iTerm's AppleScript `id` and its `ITERM_SESSION_ID` environment variable
    /// are the same UUID written two ways.
    ///
    /// `iTerm2.sdef` documents the environment variable as `w0t0p0:UUID`, while
    /// `id of session` answers with the bare UUID. Measured against a live
    /// iTerm2: comparing the bare form matches, and comparing the prefixed form
    /// does not. Every AppleScript source here reads the bare form, but pi and
    /// opencode record `ITERM_SESSION_ID` verbatim — so for those two agents the
    /// id comparison could never succeed, and the jump only worked because the
    /// TTY comparison caught it instead. A pane whose TTY is not recorded, or a
    /// TTY read from a hook process with no controlling terminal, then has
    /// nothing to fall back on.
    ///
    /// Taking the substring after the last colon leaves a bare UUID untouched
    /// and turns the prefixed form from never-matching into matching, so this
    /// can only add matches — there is no value it rewrites into something that
    /// used to match.
    static func iTermSessionID(_ raw: String) -> String {
        guard let separator = raw.lastIndex(of: ":") else {
            return raw
        }
        return String(raw[raw.index(after: separator)...])
    }
}
