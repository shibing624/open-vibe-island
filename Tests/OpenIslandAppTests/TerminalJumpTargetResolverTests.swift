import Foundation
import Testing
@testable import OpenIslandApp
import OpenIslandCore

/// Coverage for the matching rules that decide *which* terminal pane a session
/// is bound to. A wrong assignment here is a jump that lands on somebody else's
/// terminal, and until now none of it was exercised: `resolveJumpTargets` needs
/// a live Ghostty plus AppleScript consent, so the rules could only be reached
/// on a developer's machine.
@Suite(.serialized)
struct TerminalJumpTargetResolverTests {
    private func session(
        id: String,
        terminalApp: String = "Ghostty",
        workspaceName: String = "repo",
        paneTitle: String = "agent",
        workingDirectory: String? = nil,
        terminalSessionID: String? = nil,
        terminalTTY: String? = nil,
        tmuxTarget: String? = nil
    ) -> AgentSession {
        AgentSession(
            id: id,
            title: id,
            tool: .claudeCode,
            phase: .running,
            summary: "",
            updatedAt: Date(timeIntervalSince1970: 1_000),
            jumpTarget: JumpTarget(
                terminalApp: terminalApp,
                workspaceName: workspaceName,
                paneTitle: paneTitle,
                workingDirectory: workingDirectory,
                terminalSessionID: terminalSessionID,
                terminalTTY: terminalTTY,
                tmuxTarget: tmuxTarget
            )
        )
    }

    // MARK: - Ghostty

    private func ghosttySnapshot(sessionID: String, title: String, workingDirectory: String = "/Users/u") -> TerminalJumpTargetResolver.GhosttyTerminalSnapshot {
        TerminalJumpTargetResolver.GhosttyTerminalSnapshot(
            sessionID: sessionID, workingDirectory: workingDirectory, title: title
        )
    }

    /// The live shape the bug was reported from: four agent tabs open in one
    /// repository, so every Ghostty surface reports the same working directory,
    /// and the hook captured no surface id for some of the agents (only Claude
    /// sets a per-surface env var; the opencode plugin captures a TTY, and
    /// Ghostty's scripting dictionary exposes no tty at all).
    ///
    /// A working directory is not an identity when four tabs share it. Binding
    /// on it anyway is how one session's jump was pointed at another session's
    /// tab — the raised terminal then showed a different conversation, which is
    /// exactly the reported symptom.
    @Test
    func ghosttySharedWorkingDirectoryDoesNotBindOnItsOwn() {
        let resolver = TerminalJumpTargetResolver()
        let snapshots = [
            ghosttySnapshot(sessionID: "SURFACE-agentica", title: "agentica"),
            ghosttySnapshot(sessionID: "SURFACE-opencode", title: "xuming · Greeting · ses_f4b9bf4c3ffe"),
            ghosttySnapshot(sessionID: "SURFACE-claude", title: "xuming · hi,g3 · 63a37f5d-4763-41"),
            ghosttySnapshot(sessionID: "SURFACE-codex", title: "codex"),
        ]
        // What the opencode hook actually produces in a standalone Ghostty: no
        // surface id (nothing exposes the tty), and the default pane title. No
        // part of this names one of the four tabs.
        let sessions = [
            session(
                id: "opencode-ses_f4b9bf4c3ffe",
                paneTitle: "OpenCode ses_f4b9b",
                workingDirectory: "/Users/u"
            ),
        ]

        let matches = resolver.matchGhosttySnapshots(snapshots, to: sessions, activeProcesses: [])

        #expect(matches.isEmpty)
    }

    /// Claude Code titles its tab after the conversation it is running, and that
    /// title carries the session id. In a standalone Ghostty that is the only
    /// identity a surface can be recognised by — its environment carries no
    /// surface id and its scripting dictionary exposes neither a tty nor a
    /// process — so it has to be used, and it has to outrank the shared working
    /// directory. Without it the jump bound to whichever of the four same-cwd
    /// tabs Ghostty happened to list first.
    @Test
    func ghosttySessionIDInThePaneTitleBindsThatSurface() {
        let resolver = TerminalJumpTargetResolver()
        let snapshots = [
            ghosttySnapshot(sessionID: "SURFACE-agentica", title: "agentica"),
            ghosttySnapshot(sessionID: "SURFACE-opencode", title: "xuming · Greeting · ses_f4b9bf4c3ffe"),
            ghosttySnapshot(sessionID: "SURFACE-claude", title: "xuming · hi,g3 · 63a37f5d-4763-41"),
            ghosttySnapshot(sessionID: "SURFACE-codex", title: "codex"),
        ]
        let sessions = [
            session(
                id: "63a37f5d-4763-413e-a350-880cc4ad39a2",
                paneTitle: "xuming · hi,g3",
                workingDirectory: "/Users/u"
            ),
        ]

        let matches = resolver.matchGhosttySnapshots(snapshots, to: sessions, activeProcesses: [])

        #expect(matches["63a37f5d-4763-413e-a350-880cc4ad39a2"]?.sessionID == "SURFACE-claude")
    }

    /// The same shared-cwd shape, but for a signal the resolver already trusted:
    /// two tabs report identical titles. Neither tab identifies the session, so
    /// picking one of them is a coin flip on Ghostty's enumeration order, which
    /// is what made the mis-targeting look intermittent.
    @Test
    func ghosttyAmbiguousTitleDoesNotBindOnItsOwn() {
        let resolver = TerminalJumpTargetResolver()
        let snapshots = [
            ghosttySnapshot(sessionID: "SURFACE-A", title: "xuming · repo", workingDirectory: "/other/a"),
            ghosttySnapshot(sessionID: "SURFACE-B", title: "xuming · repo", workingDirectory: "/other/b"),
        ]
        let sessions = [
            session(id: "s1", paneTitle: "xuming · repo", workingDirectory: "/Users/u"),
        ]

        let matches = resolver.matchGhosttySnapshots(snapshots, to: sessions, activeProcesses: [])

        #expect(matches.isEmpty)
    }

    /// The session ID is the only exact identity available, so it has to win
    /// over the weaker cwd and title signals. Several agents in one repo share
    /// a working directory, and matching on that first would bind them to
    /// whichever pane was listed first.
    @Test
    func ghosttyExactSessionIDWinsOverASharedWorkingDirectory() {
        let resolver = TerminalJumpTargetResolver()
        let snapshots = [
            TerminalJumpTargetResolver.GhosttyTerminalSnapshot(
                sessionID: "SURFACE-A", workingDirectory: "/repo", title: "agent one"
            ),
            TerminalJumpTargetResolver.GhosttyTerminalSnapshot(
                sessionID: "SURFACE-B", workingDirectory: "/repo", title: "agent two"
            ),
        ]
        // Listed so that a cwd-first rule would bind s2 to SURFACE-A.
        let sessions = [
            session(id: "s2", workingDirectory: "/repo"),
            session(id: "s1", workingDirectory: "/repo", terminalSessionID: "SURFACE-A"),
        ]

        let matches = resolver.matchGhosttySnapshots(snapshots, to: sessions, activeProcesses: [])

        #expect(matches["s1"]?.sessionID == "SURFACE-A")
        #expect(matches["s2"]?.sessionID == "SURFACE-B")
    }

    /// One pane cannot host two agents. Without the claim bookkeeping both
    /// sessions bind to the same surface and one of them jumps to a terminal
    /// that belongs to the other.
    @Test
    func ghosttyNeverAssignsOneSurfaceToTwoSessions() {
        let resolver = TerminalJumpTargetResolver()
        let snapshots = [
            TerminalJumpTargetResolver.GhosttyTerminalSnapshot(
                sessionID: "SURFACE-A", workingDirectory: "/repo", title: "agent"
            ),
        ]
        let sessions = [
            session(id: "s1", workingDirectory: "/repo"),
            session(id: "s2", workingDirectory: "/repo"),
        ]

        let matches = resolver.matchGhosttySnapshots(snapshots, to: sessions, activeProcesses: [])

        #expect(matches.count == 1)
        #expect(matches["s1"]?.sessionID == "SURFACE-A")
        #expect(matches["s2"] == nil)
    }

    /// Paths reaching the resolver are not normalised: a trailing slash or a
    /// `/private` symlink prefix must not stop a cwd match.
    @Test
    func ghosttyWorkingDirectoryMatchIgnoresTrailingSlashes() {
        let resolver = TerminalJumpTargetResolver()
        let snapshots = [
            TerminalJumpTargetResolver.GhosttyTerminalSnapshot(
                sessionID: "SURFACE-A", workingDirectory: "/tmp/repo/", title: "unrelated title"
            ),
        ]
        let sessions = [session(id: "s1", workingDirectory: "/tmp/repo")]

        let matches = resolver.matchGhosttySnapshots(snapshots, to: sessions, activeProcesses: [])

        #expect(matches["s1"]?.sessionID == "SURFACE-A")
    }

    /// With no identity, no shared cwd and no title overlap there is nothing to
    /// match on. Binding anyway is how a jump lands on an unrelated window.
    @Test
    func ghosttyLeavesUnrelatedSessionsUnmatched() {
        let resolver = TerminalJumpTargetResolver()
        let snapshots = [
            TerminalJumpTargetResolver.GhosttyTerminalSnapshot(
                sessionID: "SURFACE-A", workingDirectory: "/other", title: "something else"
            ),
        ]
        let sessions = [session(id: "s1", paneTitle: "agent", workingDirectory: "/repo")]

        #expect(resolver.matchGhosttySnapshots(snapshots, to: sessions, activeProcesses: []).isEmpty)
    }

    // MARK: - tmux

    /// The TTY is the strong signal for a tmux pane; the title is a substring
    /// test and will happily match the wrong pane when several are similar.
    @Test
    func tmuxTTYMatchWinsOverASimilarTitle() {
        let resolver = TerminalJumpTargetResolver()
        let snapshots = [
            TerminalJumpTargetResolver.TmuxPaneSnapshot(
                paneID: "oss:1.0", tty: "/dev/ttys004", title: "agent"
            ),
            TerminalJumpTargetResolver.TmuxPaneSnapshot(
                paneID: "oss:2.0", tty: "/dev/ttys009", title: "agent"
            ),
        ]
        let sessions = [session(id: "s1", paneTitle: "agent", terminalTTY: "/dev/ttys009")]

        let matches = resolver.matchTmuxSnapshots(snapshots, to: sessions)

        #expect(matches["s1"]?.paneID == "oss:2.0")
    }

    /// A pane already addressed by `tmuxTarget` must keep that binding.
    @Test
    func tmuxPaneIDMatchBindsTheAddressedPane() {
        let resolver = TerminalJumpTargetResolver()
        let snapshots = [
            TerminalJumpTargetResolver.TmuxPaneSnapshot(
                paneID: "oss:1.0", tty: "/dev/ttys004", title: "one"
            ),
            TerminalJumpTargetResolver.TmuxPaneSnapshot(
                paneID: "oss:3.2", tty: "/dev/ttys005", title: "two"
            ),
        ]
        let sessions = [session(id: "s1", paneTitle: "nomatch", tmuxTarget: "oss:3.2")]

        #expect(resolver.matchTmuxSnapshots(snapshots, to: sessions)["s1"]?.paneID == "oss:3.2")
    }

    /// Two agents in two panes must not collapse onto one pane.
    @Test
    func tmuxNeverAssignsOnePaneToTwoSessions() {
        let resolver = TerminalJumpTargetResolver()
        let snapshots = [
            TerminalJumpTargetResolver.TmuxPaneSnapshot(
                paneID: "oss:1.0", tty: "/dev/ttys004", title: "agent"
            ),
        ]
        let sessions = [
            session(id: "s1", paneTitle: "agent"),
            session(id: "s2", paneTitle: "agent"),
        ]

        let matches = resolver.matchTmuxSnapshots(snapshots, to: sessions)

        #expect(matches.count == 1)
        #expect(matches["s2"] == nil)
    }

    /// An empty TTY on either side is absence of information, not a value to
    /// match on — otherwise every session with no TTY binds to the first pane
    /// that also reports none.
    @Test
    func tmuxDoesNotMatchTwoEmptyTTYs() {
        let resolver = TerminalJumpTargetResolver()
        let snapshots = [
            TerminalJumpTargetResolver.TmuxPaneSnapshot(
                paneID: "oss:1.0", tty: "", title: "unrelated"
            ),
        ]
        let sessions = [session(id: "s1", paneTitle: "agent", terminalTTY: "")]

        #expect(resolver.matchTmuxSnapshots(snapshots, to: sessions).isEmpty)
    }

    // MARK: - WezTerm / Kaku

    /// The pane id is the only exact identity WezTerm reports, so it has to win
    /// over the working directory. Several agents in one repo share a cwd, and
    /// matching on that first binds them to whichever pane the CLI listed first.
    @Test
    func weztermPaneIdentifierWinsOverASharedWorkingDirectory() {
        let resolver = TerminalJumpTargetResolver()
        let snapshots = [
            TerminalJumpTargetResolver.WeztermFamilySnapshot(
                paneID: 1, workingDirectory: "/repo", title: "agent", ttyName: "/dev/ttys001"
            ),
            TerminalJumpTargetResolver.WeztermFamilySnapshot(
                paneID: 2, workingDirectory: "/repo", title: "agent", ttyName: "/dev/ttys002"
            ),
        ]
        // Listed so that a cwd-first rule would bind s2 to pane 1.
        let sessions = [
            session(id: "s2", terminalApp: "WezTerm", workingDirectory: "/repo"),
            session(id: "s1", terminalApp: "WezTerm", workingDirectory: "/repo", terminalSessionID: "1"),
        ]

        let matches = resolver.matchWeztermFamilySnapshots(snapshots, to: sessions)

        #expect(matches["s1"]?.paneID == 1)
        #expect(matches["s2"]?.paneID == 2)
    }

    /// The TTY names the pane a session's process is actually attached to, so it
    /// has to outrank the working directory — two panes in the same repo differ
    /// only by their TTY.
    @Test
    func weztermTTYMatchBindsThePaneTheProcessIsAttachedTo() {
        let resolver = TerminalJumpTargetResolver()
        let snapshots = [
            TerminalJumpTargetResolver.WeztermFamilySnapshot(
                paneID: 1, workingDirectory: "/repo", title: "agent", ttyName: "/dev/ttys001"
            ),
            TerminalJumpTargetResolver.WeztermFamilySnapshot(
                paneID: 2, workingDirectory: "/repo", title: "agent", ttyName: "/dev/ttys009"
            ),
        ]
        let sessions = [session(id: "s1", terminalApp: "WezTerm", workingDirectory: "/repo", terminalTTY: "/dev/ttys009")]

        let matches = resolver.matchWeztermFamilySnapshots(snapshots, to: sessions)

        #expect(matches["s1"]?.paneID == 2)
    }

    /// A pane already claimed by the pane-id pass is not available to the TTY
    /// pass. Without that guard two sessions end up bound to the same pane and
    /// one of them jumps into the other's terminal.
    @Test
    func weztermNeverAssignsOnePaneToTwoSessions() {
        let resolver = TerminalJumpTargetResolver()
        let snapshots = [
            TerminalJumpTargetResolver.WeztermFamilySnapshot(
                paneID: 7, workingDirectory: "/snap", title: "unrelated", ttyName: "/dev/ttys004"
            ),
        ]
        let sessions = [
            session(
                id: "s1", terminalApp: "WezTerm", paneTitle: "one",
                workingDirectory: "/one", terminalSessionID: "7", terminalTTY: "/dev/ttys004"
            ),
            session(
                id: "s2", terminalApp: "WezTerm", paneTitle: "two",
                workingDirectory: "/two", terminalTTY: "/dev/ttys004"
            ),
        ]

        let matches = resolver.matchWeztermFamilySnapshots(snapshots, to: sessions)

        #expect(matches.count == 1)
        #expect(matches["s1"]?.paneID == 7)
        #expect(matches["s2"] == nil)
    }

    /// `wezterm cli list` reports the cwd as a `file://` URL while the session
    /// side carries a plain path, and paths reach here with a trailing slash or
    /// percent-encoded spaces. None of that may stop a cwd match.
    @Test
    func weztermWorkingDirectoryMatchIgnoresFileURLAndTrailingSlash() {
        let resolver = TerminalJumpTargetResolver()
        let snapshots = [
            TerminalJumpTargetResolver.WeztermFamilySnapshot(
                paneID: 3, workingDirectory: "file:///Users/u/My%20Repo/", title: "unrelated", ttyName: nil
            ),
        ]
        let sessions = [
            session(id: "s1", terminalApp: "WezTerm", workingDirectory: "/Users/u/My Repo"),
        ]

        let matches = resolver.matchWeztermFamilySnapshots(snapshots, to: sessions)

        #expect(matches["s1"]?.paneID == 3)
    }

    /// The title is a substring test and the last rule that runs, so it only
    /// decides when identity, TTY and cwd all failed to bind anything.
    @Test
    func weztermTitleMatchIsTheLastResort() {
        let resolver = TerminalJumpTargetResolver()
        let snapshots = [
            TerminalJumpTargetResolver.WeztermFamilySnapshot(
                paneID: 4, workingDirectory: "/somewhere/else", title: "codex ~/p/open-island", ttyName: "/dev/ttys077"
            ),
        ]
        let sessions = [
            session(
                id: "s1", terminalApp: "WezTerm", paneTitle: "open-island",
                workingDirectory: "/repo", terminalTTY: "/dev/ttys004"
            ),
        ]

        let matches = resolver.matchWeztermFamilySnapshots(snapshots, to: sessions)

        #expect(matches["s1"]?.paneID == 4)
    }

    /// An empty cwd is absence of information on the snapshot side too: the
    /// pass is skipped entirely rather than matching a session that also
    /// reports none.
    @Test
    func weztermDoesNotMatchTwoEmptyWorkingDirectories() {
        let resolver = TerminalJumpTargetResolver()
        let snapshots = [
            TerminalJumpTargetResolver.WeztermFamilySnapshot(
                paneID: 5, workingDirectory: "", title: "unrelated", ttyName: nil
            ),
        ]
        let sessions = [
            session(id: "s1", terminalApp: "WezTerm", paneTitle: "agent", workingDirectory: ""),
        ]

        #expect(resolver.matchWeztermFamilySnapshots(snapshots, to: sessions).isEmpty)
    }

    /// With no matching identity, TTY, cwd or title overlap there is nothing to
    /// bind on. Assigning anyway is how a jump lands on an unrelated pane.
    @Test
    func weztermLeavesUnrelatedSessionsUnmatched() {
        let resolver = TerminalJumpTargetResolver()
        let snapshots = [
            TerminalJumpTargetResolver.WeztermFamilySnapshot(
                paneID: 9, workingDirectory: "/other", title: "something else", ttyName: "/dev/ttys099"
            ),
        ]
        let sessions = [
            session(
                id: "s1", terminalApp: "WezTerm", paneTitle: "agent",
                workingDirectory: "/repo", terminalSessionID: "999", terminalTTY: "/dev/ttys004"
            ),
        ]

        #expect(resolver.matchWeztermFamilySnapshots(snapshots, to: sessions).isEmpty)
    }

    /// Passes are ordered strongest-first across all panes; testing the rules
    /// pane-major lets a weak pane occupy a session whose strong signal belongs
    /// to a later pane. Two panes in one repo, and the session is bound by cwd
    /// as well as by TTY: the TTY must decide.
    @Test
    func weztermStrongerSignalBeatsAnEarlierListedPanesWeakSignal() {
        let resolver = TerminalJumpTargetResolver()
        let snapshots = [
            TerminalJumpTargetResolver.WeztermFamilySnapshot(
                paneID: 1, workingDirectory: "/repo", title: "unrelated", ttyName: "/dev/ttys001"
            ),
            TerminalJumpTargetResolver.WeztermFamilySnapshot(
                paneID: 2, workingDirectory: "/elsewhere", title: "unrelated", ttyName: "/dev/ttys009"
            ),
        ]
        let sessions = [
            session(
                id: "s1", terminalApp: "WezTerm", paneTitle: "nomatch",
                workingDirectory: "/repo", terminalTTY: "/dev/ttys009"
            ),
        ]

        let matches = resolver.matchWeztermFamilySnapshots(snapshots, to: sessions)

        #expect(matches["s1"]?.paneID == 2)
    }

    /// Two panes whose titles both mention the session's, with no pane id, TTY
    /// or cwd to decide between them. Nothing here identifies which pane is the
    /// session's, so it must keep the target it had rather than be pointed at
    /// one of two equally plausible panes.
    @Test
    func weztermAmbiguousTitleDoesNotBindOnItsOwn() {
        let resolver = TerminalJumpTargetResolver()
        let snapshots = [
            TerminalJumpTargetResolver.WeztermFamilySnapshot(
                paneID: 1, workingDirectory: "/other/a", title: "codex ~/p/repo", ttyName: "/dev/ttys001"
            ),
            TerminalJumpTargetResolver.WeztermFamilySnapshot(
                paneID: 2, workingDirectory: "/other/b", title: "codex ~/p/repo", ttyName: "/dev/ttys002"
            ),
        ]
        let sessions = [
            session(id: "s1", terminalApp: "WezTerm", paneTitle: "repo", workingDirectory: "/Users/u"),
        ]

        #expect(resolver.matchWeztermFamilySnapshots(snapshots, to: sessions).isEmpty)
    }

    // MARK: - Terminal.app

    /// Within one tab the TTY is checked before the custom title. A substring
    /// title match on an earlier-listed tab is how a session pinned by TTY to a
    /// later tab gets selected in the wrong window.
    @Test
    func terminalTTYMatchWinsOverTheCustomTitle() {
        let resolver = TerminalJumpTargetResolver()
        let snapshots = [
            TerminalJumpTargetResolver.TerminalTabSnapshot(tty: "/dev/ttys004", customTitle: "claude session"),
        ]
        let sessions = [
            session(id: "s1", terminalApp: "Terminal", paneTitle: "claude session", terminalTTY: "/dev/ttys999"),
            session(id: "s2", terminalApp: "Terminal", paneTitle: "no title overlap", terminalTTY: "/dev/ttys004"),
        ]

        let matches = resolver.matchTerminalSnapshots(snapshots, to: sessions)

        #expect(matches.count == 1)
        #expect(matches["s2"]?.tty == "/dev/ttys004")
        #expect(matches["s1"] == nil)
    }

    /// With no TTY to match on the custom title is the remaining signal, and it
    /// is the tab's title that has to contain the session's pane title.
    @Test
    func terminalFallsBackToTheCustomTitle() {
        let resolver = TerminalJumpTargetResolver()
        let snapshots = [
            TerminalJumpTargetResolver.TerminalTabSnapshot(tty: "", customTitle: "claude ~/p/open-island"),
        ]
        let sessions = [
            session(id: "s1", terminalApp: "Terminal", paneTitle: "open-island", terminalTTY: "/dev/ttys004"),
        ]

        let matches = resolver.matchTerminalSnapshots(snapshots, to: sessions)

        #expect(matches["s1"]?.customTitle == "claude ~/p/open-island")
    }

    /// Two tabs, two sessions, one TTY each: every session has to keep its own
    /// tab. Letting an already-bound session take the second tab as well drops
    /// a session onto the other one's window and leaves its own unassigned.
    @Test
    func terminalNeverAssignsOneSessionTwoTabs() {
        let resolver = TerminalJumpTargetResolver()
        let snapshots = [
            TerminalJumpTargetResolver.TerminalTabSnapshot(tty: "/dev/ttys004", customTitle: "agent"),
            TerminalJumpTargetResolver.TerminalTabSnapshot(tty: "/dev/ttys005", customTitle: "agent"),
        ]
        let sessions = [
            session(id: "s1", terminalApp: "Terminal", paneTitle: "agent", terminalTTY: "/dev/ttys004"),
            session(id: "s2", terminalApp: "Terminal", paneTitle: "agent", terminalTTY: "/dev/ttys005"),
        ]

        let matches = resolver.matchTerminalSnapshots(snapshots, to: sessions)

        #expect(matches.count == 2)
        #expect(matches["s1"]?.tty == "/dev/ttys004")
        #expect(matches["s2"]?.tty == "/dev/ttys005")
    }

    /// One tab hosts one agent. The tab is consumed by the first session it
    /// binds, so a second session with the same title is left without a target
    /// instead of being pointed at a window it does not own.
    @Test
    func terminalNeverAssignsOneTabToTwoSessions() {
        let resolver = TerminalJumpTargetResolver()
        let snapshots = [
            TerminalJumpTargetResolver.TerminalTabSnapshot(tty: "", customTitle: "agent"),
        ]
        let sessions = [
            session(id: "s1", terminalApp: "Terminal", paneTitle: "agent"),
            session(id: "s2", terminalApp: "Terminal", paneTitle: "agent"),
        ]

        let matches = resolver.matchTerminalSnapshots(snapshots, to: sessions)

        #expect(matches.count == 1)
        #expect(matches["s1"]?.customTitle == "agent")
        #expect(matches["s2"] == nil)
    }

    /// An empty tty or title on either side is absence of information, not a
    /// value to match on — otherwise every session without a TTY binds to the
    /// first tab that reports none.
    @Test
    func terminalDoesNotMatchEmptyTTYOrTitle() {
        let resolver = TerminalJumpTargetResolver()
        let snapshots = [TerminalJumpTargetResolver.TerminalTabSnapshot(tty: "", customTitle: "")]
        let sessions = [session(id: "s1", terminalApp: "Terminal", paneTitle: "", terminalTTY: "")]

        #expect(resolver.matchTerminalSnapshots(snapshots, to: sessions).isEmpty)
    }

    /// No TTY and no title overlap means this tab is not the session's, so the
    /// session keeps whatever target it already had.
    @Test
    func terminalLeavesUnrelatedSessionsUnmatched() {
        let resolver = TerminalJumpTargetResolver()
        let snapshots = [
            TerminalJumpTargetResolver.TerminalTabSnapshot(tty: "/dev/ttys004", customTitle: "unrelated"),
        ]
        let sessions = [
            session(id: "s1", terminalApp: "Terminal", paneTitle: "agent", terminalTTY: "/dev/ttys005"),
        ]

        #expect(resolver.matchTerminalSnapshots(snapshots, to: sessions).isEmpty)
    }

    /// A TTY is an identity and a title is a substring test, so the TTY has to
    /// decide no matter which tab is listed first. Tabs are enumerated in
    /// whatever order Terminal.app reports, so testing the two rules per tab
    /// lets an earlier tab's *title* claim a session whose TTY belongs to a
    /// later one — the jump then selects a tab running a different agent.
    @Test
    func terminalTTYMatchWinsOverAnEarlierListedTabsTitle() {
        let resolver = TerminalJumpTargetResolver()
        let snapshots = [
            TerminalJumpTargetResolver.TerminalTabSnapshot(tty: "/dev/ttysOTHER", customTitle: "agent"),
            TerminalJumpTargetResolver.TerminalTabSnapshot(tty: "/dev/ttys007", customTitle: "unrelated"),
        ]
        let sessions = [
            session(id: "s1", terminalApp: "Terminal", paneTitle: "agent", terminalTTY: "/dev/ttys007"),
        ]

        let matches = resolver.matchTerminalSnapshots(snapshots, to: sessions)

        #expect(matches["s1"]?.tty == "/dev/ttys007")
    }

    /// Two tabs whose custom titles both mention the session's, and a session
    /// carrying neither a TTY nor any other identity: nothing here says which
    /// tab is its own, so it must keep the target it had rather than be pointed
    /// at one of two equally plausible tabs.
    @Test
    func terminalAmbiguousTitleDoesNotBindOnItsOwn() {
        let resolver = TerminalJumpTargetResolver()
        let snapshots = [
            TerminalJumpTargetResolver.TerminalTabSnapshot(tty: "", customTitle: "claude ~/p/open-island"),
            TerminalJumpTargetResolver.TerminalTabSnapshot(tty: "", customTitle: "claude ~/p/open-island"),
        ]
        let sessions = [
            session(id: "s1", terminalApp: "Terminal", paneTitle: "open-island"),
        ]

        #expect(resolver.matchTerminalSnapshots(snapshots, to: sessions).isEmpty)
    }
}
