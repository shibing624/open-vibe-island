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
}
