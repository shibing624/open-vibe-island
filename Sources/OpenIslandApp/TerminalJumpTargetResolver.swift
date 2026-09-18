import AppKit
import Foundation
import OpenIslandCore

/// Resolves precise jump targets for sessions by querying Ghostty and
/// Terminal.app via AppleScript. This type is responsible ONLY for jump
/// target precision — it never affects session visibility or attachment state.
///
/// Introduced in Phase 2 of the session state refactoring to separate
/// jump-target resolution from the attachment state machine.
struct TerminalJumpTargetResolver {
    typealias ActiveProcessSnapshot = ActiveAgentProcessDiscovery.ProcessSnapshot

    struct GhosttyTerminalSnapshot: Sendable {
        var sessionID: String
        var workingDirectory: String
        var title: String
    }

    struct TerminalTabSnapshot: Sendable {
        var tty: String
        var customTitle: String
    }

    struct WeztermFamilySnapshot: Sendable {
        var paneID: Int
        var workingDirectory: String
        var title: String
        var ttyName: String?
    }

    struct TmuxPaneSnapshot: Sendable {
        var paneID: String
        var tty: String
        var title: String
    }

    private static let appleScriptTimeout: TimeInterval = 3
    private static let fieldSeparator = "\u{1F}"
    private static let recordSeparator = "\u{1E}"

    // MARK: - Public API

    /// Resolve jump target updates for the given sessions. Returns a dictionary
    /// of session ID → corrected JumpTarget for sessions whose targets changed.
    func resolveJumpTargets(
        for sessions: [AgentSession],
        activeProcesses: [ActiveProcessSnapshot]
    ) -> [String: JumpTarget] {
        guard !sessions.isEmpty else { return [:] }

        let ghosttySessions = sessions.filter { normalizedTerminalName(for: $0.jumpTarget?.terminalApp) == "ghostty" }
        let terminalSessions = sessions.filter { normalizedTerminalName(for: $0.jumpTarget?.terminalApp) == "terminal" }
        let weztermFamilySessions = sessions.filter {
            let name = normalizedTerminalName(for: $0.jumpTarget?.terminalApp)
            return name == "kaku" || name == "wezterm"
        }
        // Tmux candidates: sessions that already have a tmuxTarget, OR sessions
        // whose terminalTTY maps to a tmux pane (e.g. OpenCode sessions created
        // by BridgeServer without tmux info). We discover the mapping below.
        let tmuxSessions = sessions.filter {
            $0.jumpTarget?.tmuxTarget != nil || $0.jumpTarget?.terminalTTY != nil
        }

        var jumpTargetUpdates: [String: JumpTarget] = [:]

        // Tmux: match sessions and resolve their tmux pane info.
        // Also discovers tmux targets for sessions that only have a TTY.
        if !tmuxSessions.isEmpty {
            let tmuxSnapshots = fetchTmuxSnapshots()
            if let snapshots = tmuxSnapshots {
                let matched = matchTmuxSnapshots(snapshots, to: tmuxSessions)
                for (sessionID, snapshot) in matched {
                    if let session = sessions.first(where: { $0.id == sessionID }),
                       let corrected = correctedTmuxJumpTarget(for: session, snapshot: snapshot) {
                        jumpTargetUpdates[sessionID] = corrected
                    }
                }
            }
        }

        // Ghostty: match sessions to AppleScript snapshots.
        if !ghosttySessions.isEmpty || sessions.contains(where: { needsGhosttyProbe($0) }) {
            let ghosttySnapshots = fetchGhosttySnapshots()
            if let snapshots = ghosttySnapshots {
                let allGhosttyCandidates = sessions.filter {
                    normalizedTerminalName(for: $0.jumpTarget?.terminalApp) == "ghostty"
                        || ($0.jumpTarget?.terminalApp == nil && $0.jumpTarget == nil)
                }
                let matched = matchGhosttySnapshots(snapshots, to: allGhosttyCandidates, activeProcesses: activeProcesses)
                for (sessionID, snapshot) in matched {
                    if let session = sessions.first(where: { $0.id == sessionID }),
                       let corrected = correctedGhosttyJumpTarget(for: session, snapshot: snapshot) {
                        jumpTargetUpdates[sessionID] = corrected
                    }
                }
            }
        }

        // WezTerm-family (Kaku / WezTerm): match sessions to CLI snapshots.
        if !weztermFamilySessions.isEmpty {
            for session in weztermFamilySessions {
                let terminalName = normalizedTerminalName(for: session.jumpTarget?.terminalApp) ?? ""
                let bundleID = terminalName == "kaku" ? "fun.tw93.kaku" : "com.github.wez.wezterm"
                if let cliPath = resolveWeztermFamilyCLIPath(for: bundleID),
                   let snapshots = fetchWeztermFamilySnapshots(cliPath: cliPath, bundleIdentifier: bundleID) {
                    let matched = matchWeztermFamilySnapshots(snapshots, to: [session])
                    for (sessionID, snapshot) in matched {
                        if let corrected = correctedWeztermFamilyJumpTarget(
                            for: session, snapshot: snapshot, terminalName: terminalName
                        ) {
                            jumpTargetUpdates[sessionID] = corrected
                        }
                    }
                }
            }
        }

        // Terminal.app: match sessions to AppleScript snapshots.
        if !terminalSessions.isEmpty {
            let terminalSnapshots = fetchTerminalSnapshots()
            if let snapshots = terminalSnapshots {
                let matched = matchTerminalSnapshots(snapshots, to: terminalSessions)
                for (sessionID, snapshot) in matched {
                    if let session = sessions.first(where: { $0.id == sessionID }),
                       let corrected = correctedTerminalJumpTarget(for: session, snapshot: snapshot) {
                        jumpTargetUpdates[sessionID] = corrected
                    }
                }
            }
        }

        return jumpTargetUpdates
    }

    // MARK: - Ghostty matching

    /// Internal rather than private so the matching rules can be asserted
    /// directly. These decide *which* pane a session is bound to, so a wrong
    /// assignment here is a jump that lands on someone else's terminal — and
    /// it cannot be reached through `resolveJumpTargets`, which needs a live
    /// Ghostty and AppleScript consent.
    func matchGhosttySnapshots(
        _ snapshots: [GhosttyTerminalSnapshot],
        to sessions: [AgentSession],
        activeProcesses: [ActiveProcessSnapshot]
    ) -> [String: GhosttyTerminalSnapshot] {
        var assignments: [String: GhosttyTerminalSnapshot] = [:]
        var claimedSessionIDs: Set<String> = []
        var claimedSnapshotIndices: Set<Int> = []

        // Pass 1: the session id in the pane title.
        //
        // Agent CLIs title their tab after the conversation they are running,
        // and in a standalone Ghostty that title is the only identity a surface
        // carries: the process environment has no surface id (only the cmux fork
        // exports one), and the scripting dictionary exposes neither a tty nor a
        // process.
        //
        // Ahead of the recorded surface id, not behind it, and deliberately: a
        // stored id can already be wrong — a working-directory pass bound it to
        // whichever tab was enumerated first — and an id that matches its
        // snapshot would otherwise keep that mis-binding for the rest of the
        // session. `TerminalSessionAttachmentProbe` resolves the same surfaces
        // in this order, so the two writers of a jump target agree.
        bindUniquelyMatching(
            sessions: sessions,
            snapshots: snapshots,
            claimedSessionIDs: &claimedSessionIDs,
            claimedSnapshotIndices: &claimedSnapshotIndices,
            assignments: &assignments
        ) { snapshot, session in
            snapshotTitleMentionsSessionID(snapshot, session: session)
        }

        // Pass 2: exact session ID match via terminal session ID.
        bindUniquelyMatching(
            sessions: sessions,
            snapshots: snapshots,
            claimedSessionIDs: &claimedSessionIDs,
            claimedSnapshotIndices: &claimedSnapshotIndices,
            assignments: &assignments
        ) { snapshot, session in
            nonEmptyValue(session.jumpTarget?.terminalSessionID) == snapshot.sessionID
        }

        // Pass 3: working directory match.
        bindUniquelyMatching(
            sessions: sessions,
            snapshots: snapshots,
            claimedSessionIDs: &claimedSessionIDs,
            claimedSnapshotIndices: &claimedSnapshotIndices,
            assignments: &assignments
        ) { snapshot, session in
            let snapshotCWD = normalizedPathForMatching(snapshot.workingDirectory)
            return snapshotCWD != nil
                && normalizedPathForMatching(session.jumpTarget?.workingDirectory) == snapshotCWD
        }

        // Pass 4: pane title match.
        bindUniquelyMatching(
            sessions: sessions,
            snapshots: snapshots,
            claimedSessionIDs: &claimedSessionIDs,
            claimedSnapshotIndices: &claimedSnapshotIndices,
            assignments: &assignments
        ) { snapshot, session in
            nonEmptyValue(session.jumpTarget?.paneTitle).map { snapshot.title.contains($0) } == true
        }

        return assignments
    }

    /// Binds each unclaimed session that exactly one unclaimed snapshot matches.
    ///
    /// The uniqueness is the point. A working directory or a title is a *weak*
    /// signal: several tabs in one repository report the same directory, and
    /// agent titles repeat. Binding on one of them anyway picks whichever
    /// surface the terminal happened to enumerate first, so a jump was raised on
    /// another agent's tab and the user saw a different conversation — and
    /// because that order changes as tabs are focused and reordered, it looked
    /// intermittent. A signal that several surfaces share identifies none of
    /// them, so the session keeps whatever target it already had.
    ///
    /// Iterated session-major so an already-bound session cannot take a second
    /// surface, which is the bookkeeping the passes above used to do inline.
    private func bindUniquelyMatching<Snapshot>(
        sessions: [AgentSession],
        snapshots: [Snapshot],
        claimedSessionIDs: inout Set<String>,
        claimedSnapshotIndices: inout Set<Int>,
        assignments: inout [String: Snapshot],
        matches: (Snapshot, AgentSession) -> Bool
    ) {
        for session in sessions where !claimedSessionIDs.contains(session.id) {
            let candidates = snapshots.indices.filter {
                !claimedSnapshotIndices.contains($0) && matches(snapshots[$0], session)
            }

            guard candidates.count == 1, let index = candidates.first else {
                continue
            }

            assignments[session.id] = snapshots[index]
            claimedSessionIDs.insert(session.id)
            claimedSnapshotIndices.insert(index)
        }
    }

    /// Whether the surface title names this session.
    ///
    /// Titles are clipped by their author, so the id arrives as a prefix of
    /// varying length rather than whole; the lengths are the ones the attachment
    /// probe has always accepted, kept identical so both matchers agree on which
    /// tab a session owns.
    private func snapshotTitleMentionsSessionID(
        _ snapshot: GhosttyTerminalSnapshot,
        session: AgentSession
    ) -> Bool {
        let normalizedTitle = snapshot.title.lowercased()
        return sessionIDPrefixes(for: session).contains { normalizedTitle.contains($0) }
    }

    private func sessionIDPrefixes(for session: AgentSession) -> [String] {
        let normalizedID = session.id.lowercased()
        let prefixLengths = [normalizedID.count, 18, 13, 8]

        return prefixLengths.compactMap { length in
            guard length > 0, normalizedID.count >= length else {
                return nil
            }

            return String(normalizedID.prefix(length))
        }
    }

    private func correctedGhosttyJumpTarget(
        for session: AgentSession,
        snapshot: GhosttyTerminalSnapshot
    ) -> JumpTarget? {
        let hadExistingJumpTarget = session.jumpTarget != nil
        var jumpTarget = session.jumpTarget ?? JumpTarget(
            terminalApp: "Ghostty",
            workspaceName: URL(fileURLWithPath: snapshot.workingDirectory).lastPathComponent,
            paneTitle: snapshot.title,
            workingDirectory: snapshot.workingDirectory,
            terminalSessionID: snapshot.sessionID
        )

        var changed = !hadExistingJumpTarget

        if normalizedTerminalName(for: jumpTarget.terminalApp) != "ghostty" {
            jumpTarget.terminalApp = "Ghostty"
            changed = true
        }

        if nonEmptyValue(jumpTarget.terminalSessionID) != snapshot.sessionID {
            jumpTarget.terminalSessionID = snapshot.sessionID
            changed = true
        }

        if nonEmptyValue(jumpTarget.workingDirectory) != snapshot.workingDirectory {
            jumpTarget.workingDirectory = snapshot.workingDirectory
            changed = true
        }

        if let title = nonEmptyValue(snapshot.title), title != jumpTarget.paneTitle {
            jumpTarget.paneTitle = title
            changed = true
        }

        let workspaceName = URL(fileURLWithPath: snapshot.workingDirectory).lastPathComponent
        if !workspaceName.isEmpty, workspaceName != jumpTarget.workspaceName {
            jumpTarget.workspaceName = workspaceName
            changed = true
        }

        return changed ? jumpTarget : nil
    }

    // MARK: - Tmux matching

    func matchTmuxSnapshots(
        _ snapshots: [TmuxPaneSnapshot],
        to sessions: [AgentSession]
    ) -> [String: TmuxPaneSnapshot] {
        var assignments: [String: TmuxPaneSnapshot] = [:]
        var claimedPaneIDs: Set<String> = []

        // Strongest signal first across *all* panes, the way the Ghostty
        // matcher does it. Iterating pane-major and trying all three rules per
        // pane let a weak title match on an earlier pane consume a session
        // whose exact TTY belonged to a later one: two panes both titled
        // "agent", and the session pinned to the second by TTY got bound to
        // the first. TTY and pane id are identities; a title is a substring
        // test and must never outrank them.
        let rules: [(TmuxPaneSnapshot, AgentSession) -> Bool] = [
            { snapshot, session in
                nonEmptyValue(session.jumpTarget?.terminalTTY).map { $0 == snapshot.tty } == true
            },
            { snapshot, session in
                nonEmptyValue(session.jumpTarget?.tmuxTarget).map { $0 == snapshot.paneID } == true
            },
            { snapshot, session in
                nonEmptyValue(session.jumpTarget?.paneTitle).map { snapshot.title.contains($0) } == true
            },
        ]

        for rule in rules {
            for snapshot in snapshots where !claimedPaneIDs.contains(snapshot.paneID) {
                guard let session = sessions.first(where: {
                    assignments[$0.id] == nil && rule(snapshot, $0)
                }) else {
                    continue
                }
                assignments[session.id] = snapshot
                claimedPaneIDs.insert(snapshot.paneID)
            }
        }

        return assignments
    }

    private func correctedTmuxJumpTarget(
        for session: AgentSession,
        snapshot: TmuxPaneSnapshot
    ) -> JumpTarget? {
        guard var jumpTarget = session.jumpTarget else {
            return nil
        }

        var changed = false

        if nonEmptyValue(jumpTarget.terminalTTY) != snapshot.tty {
            jumpTarget.terminalTTY = snapshot.tty
            changed = true
        }

        if nonEmptyValue(jumpTarget.tmuxTarget) != snapshot.paneID {
            jumpTarget.tmuxTarget = snapshot.paneID
            changed = true
        }

        if let title = nonEmptyValue(snapshot.title),
           title != jumpTarget.paneTitle {
            jumpTarget.paneTitle = title
            changed = true
        }

        return changed ? jumpTarget : nil
    }

    // MARK: - Tmux fetching

    private func fetchTmuxSnapshots() -> [TmuxPaneSnapshot]? {
        guard let tmuxPath = resolveTmuxPath() else {
            return nil
        }

        // Use a printable multi-char separator — tmux converts control
        // characters (0x09, 0x1F, etc.) to printable equivalents.
        // Use session:window.pane target format so the jump service can
        // extract session name for switch-client and session:window for
        // select-window. Also fetch pane_tty for TTY matching.
        let tmuxSep = "<|>"
        guard let output = runTmuxCommand(
            tmuxPath: tmuxPath,
            arguments: [
                "list-panes", "-a", "-F",
                "#{session_name}:#{window_index}.#{pane_index}\(tmuxSep)#{pane_tty}\(tmuxSep)#{pane_title}",
            ]
        ) else {
            return nil
        }

        let lines = output.split(separator: "\n")

        return lines
            .compactMap { line in
                let parts = line.components(separatedBy: tmuxSep)
                guard parts.count == 3 else {
                    return nil
                }

                return TmuxPaneSnapshot(
                    paneID: parts[0],  // e.g. "rust-projects:5.3"
                    tty: parts[1],
                    title: parts[2]
                )
            }
    }

    private func resolveTmuxPath() -> String? {
        let candidates = [
            "/opt/homebrew/bin/tmux",
            "/usr/local/bin/tmux",
            "/usr/bin/tmux",
        ]

        if let found = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) {
            return found
        }

        // Fallback to 'which'
        guard let path = BoundedProcess.run(
            executableURL: URL(fileURLWithPath: "/usr/bin/which"),
            arguments: ["tmux"]
        ), !path.isEmpty else {
            return nil
        }
        return path
    }

    private func runTmuxCommand(tmuxPath: String, arguments: [String]) -> String? {
        guard let output = BoundedProcess.run(
            executableURL: URL(fileURLWithPath: tmuxPath),
            arguments: arguments,
            timeout: Self.appleScriptTimeout
        ), !output.isEmpty else {
            return nil
        }

        return output
    }

    // MARK: - Terminal.app matching

    /// Internal rather than private so the matching rules can be asserted
    /// directly. These decide *which* tab a session is bound to, so a wrong
    /// assignment here is a jump that lands on someone else's Terminal.app
    /// window — and it cannot be reached through `resolveJumpTargets`, which
    /// needs a live Terminal.app and AppleScript consent.
    func matchTerminalSnapshots(
        _ snapshots: [TerminalTabSnapshot],
        to sessions: [AgentSession]
    ) -> [String: TerminalTabSnapshot] {
        var assignments: [String: TerminalTabSnapshot] = [:]
        var claimedSessionIDs: Set<String> = []
        var claimedSnapshotIndices: Set<Int> = []

        // Strongest signal first across all tabs, the way the Ghostty and tmux
        // matchers do it. Testing both rules per tab let an earlier tab's
        // *title* claim a session whose TTY belongs to a later one: two tabs
        // titled alike, and the session pinned by TTY to the second was selected
        // in the first. A TTY is an identity; a title is a substring test and
        // must never outrank it.
        bindUniquelyMatching(
            sessions: sessions,
            snapshots: snapshots,
            claimedSessionIDs: &claimedSessionIDs,
            claimedSnapshotIndices: &claimedSnapshotIndices,
            assignments: &assignments
        ) { snapshot, session in
            nonEmptyValue(session.jumpTarget?.terminalTTY) == snapshot.tty
        }

        // The title is the last resort and only decides when it is unambiguous.
        bindUniquelyMatching(
            sessions: sessions,
            snapshots: snapshots,
            claimedSessionIDs: &claimedSessionIDs,
            claimedSnapshotIndices: &claimedSnapshotIndices,
            assignments: &assignments
        ) { snapshot, session in
            nonEmptyValue(session.jumpTarget?.paneTitle).map { snapshot.customTitle.contains($0) } == true
        }

        return assignments
    }

    private func correctedTerminalJumpTarget(
        for session: AgentSession,
        snapshot: TerminalTabSnapshot
    ) -> JumpTarget? {
        guard var jumpTarget = session.jumpTarget else {
            return nil
        }

        var changed = false

        if normalizedTerminalName(for: jumpTarget.terminalApp) != "terminal" {
            jumpTarget.terminalApp = "Terminal"
            changed = true
        }

        if nonEmptyValue(jumpTarget.terminalTTY) != snapshot.tty {
            jumpTarget.terminalTTY = snapshot.tty
            changed = true
        }

        if let title = nonEmptyValue(snapshot.customTitle),
           title != jumpTarget.paneTitle {
            jumpTarget.paneTitle = title
            changed = true
        }

        return changed ? jumpTarget : nil
    }

    // MARK: - WezTerm-family matching

    /// Internal rather than private so the matching rules can be asserted
    /// directly. These decide *which* pane a session is bound to, so a wrong
    /// assignment here is a jump that lands on someone else's WezTerm/Kaku
    /// pane — and it cannot be reached through `resolveJumpTargets`, which
    /// needs a live WezTerm/Kaku to answer `cli list`.
    func matchWeztermFamilySnapshots(
        _ snapshots: [WeztermFamilySnapshot],
        to sessions: [AgentSession]
    ) -> [String: WeztermFamilySnapshot] {
        var assignments: [String: WeztermFamilySnapshot] = [:]
        var claimedSessionIDs: Set<String> = []
        var claimedSnapshotIndices: Set<Int> = []

        // Strongest signal first across all panes, and each pass binds only
        // when a single unclaimed pane matches. A pane id or a TTY is an
        // identity; the working directory and the title are not, and pane
        // order follows focus, so the weak passes bind only when unambiguous.
        bindUniquelyMatching(
            sessions: sessions,
            snapshots: snapshots,
            claimedSessionIDs: &claimedSessionIDs,
            claimedSnapshotIndices: &claimedSnapshotIndices,
            assignments: &assignments
        ) { snapshot, session in
            nonEmptyValue(session.jumpTarget?.terminalSessionID) == "\(snapshot.paneID)"
        }

        bindUniquelyMatching(
            sessions: sessions,
            snapshots: snapshots,
            claimedSessionIDs: &claimedSessionIDs,
            claimedSnapshotIndices: &claimedSnapshotIndices,
            assignments: &assignments
        ) { snapshot, session in
            guard let snapshotTTY = nonEmptyValue(snapshot.ttyName) else { return false }
            return nonEmptyValue(session.jumpTarget?.terminalTTY) == snapshotTTY
        }

        bindUniquelyMatching(
            sessions: sessions,
            snapshots: snapshots,
            claimedSessionIDs: &claimedSessionIDs,
            claimedSnapshotIndices: &claimedSnapshotIndices,
            assignments: &assignments
        ) { snapshot, session in
            let snapshotCWD = normalizedPathForMatching(
                Self.weztermFamilyNormalizeCWD(snapshot.workingDirectory)
            )
            return snapshotCWD != nil
                && normalizedPathForMatching(session.jumpTarget?.workingDirectory) == snapshotCWD
        }

        bindUniquelyMatching(
            sessions: sessions,
            snapshots: snapshots,
            claimedSessionIDs: &claimedSessionIDs,
            claimedSnapshotIndices: &claimedSnapshotIndices,
            assignments: &assignments
        ) { snapshot, session in
            nonEmptyValue(session.jumpTarget?.paneTitle).map { snapshot.title.contains($0) } == true
        }

        return assignments
    }

    private func correctedWeztermFamilyJumpTarget(
        for session: AgentSession,
        snapshot: WeztermFamilySnapshot,
        terminalName: String
    ) -> JumpTarget? {
        let displayName = terminalName == "kaku" ? "Kaku" : "WezTerm"
        let cwd = Self.weztermFamilyNormalizeCWD(snapshot.workingDirectory)
        let hadExistingJumpTarget = session.jumpTarget != nil
        var jumpTarget = session.jumpTarget ?? JumpTarget(
            terminalApp: displayName,
            workspaceName: URL(fileURLWithPath: cwd).lastPathComponent,
            paneTitle: snapshot.title,
            workingDirectory: cwd,
            terminalSessionID: "\(snapshot.paneID)"
        )

        var changed = !hadExistingJumpTarget

        if normalizedTerminalName(for: jumpTarget.terminalApp) != terminalName {
            jumpTarget.terminalApp = displayName
            changed = true
        }

        if nonEmptyValue(jumpTarget.terminalSessionID) != "\(snapshot.paneID)" {
            jumpTarget.terminalSessionID = "\(snapshot.paneID)"
            changed = true
        }

        if nonEmptyValue(jumpTarget.workingDirectory) != cwd {
            jumpTarget.workingDirectory = cwd
            changed = true
        }

        if let title = nonEmptyValue(snapshot.title), title != jumpTarget.paneTitle {
            jumpTarget.paneTitle = title
            changed = true
        }

        if let tty = nonEmptyValue(snapshot.ttyName), tty != jumpTarget.terminalTTY {
            jumpTarget.terminalTTY = tty
            changed = true
        }

        let workspaceName = URL(fileURLWithPath: cwd).lastPathComponent
        if !workspaceName.isEmpty, workspaceName != jumpTarget.workspaceName {
            jumpTarget.workspaceName = workspaceName
            changed = true
        }

        return changed ? jumpTarget : nil
    }

    // MARK: - WezTerm-family CLI fetching

    private func resolveWeztermFamilyCLIPath(for bundleIdentifier: String) -> String? {
        let cliName: String
        let appName: String
        switch bundleIdentifier {
        case "fun.tw93.kaku":
            cliName = "kaku"
            appName = "Kaku"
        case "com.github.wez.wezterm":
            cliName = "wezterm"
            appName = "WezTerm"
        default: return nil
        }

        let bundleCandidates = [
            "/Applications/\(appName).app/Contents/MacOS/\(cliName)",
            NSHomeDirectory() + "/Applications/\(appName).app/Contents/MacOS/\(cliName)",
        ]
        if let found = bundleCandidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) {
            return found
        }

        guard let path = BoundedProcess.run(
            executableURL: URL(fileURLWithPath: "/usr/bin/which"),
            arguments: [cliName]
        ), !path.isEmpty else {
            return nil
        }
        return path
    }

    private func fetchWeztermFamilySnapshots(cliPath: String, bundleIdentifier: String) -> [WeztermFamilySnapshot]? {
        guard isRunning(bundleIdentifier: bundleIdentifier) else {
            return []
        }

        guard let output = BoundedProcess.run(
            executableURL: URL(fileURLWithPath: cliPath),
            arguments: ["cli", "list", "--format", "json"],
            timeout: Self.appleScriptTimeout
        ) else {
            return nil
        }

        struct CLIPane: Decodable {
            let pane_id: Int
            let title: String
            let cwd: String
            let tty_name: String?
        }

        guard let panes = try? JSONDecoder().decode([CLIPane].self, from: Data(output.utf8)) else {
            return nil
        }

        return panes.map { pane in
            WeztermFamilySnapshot(
                paneID: pane.pane_id,
                workingDirectory: pane.cwd,
                title: pane.title,
                ttyName: pane.tty_name
            )
        }
    }

    // MARK: - AppleScript fetching

    private func fetchGhosttySnapshots() -> [GhosttyTerminalSnapshot]? {
        guard isRunning(bundleIdentifier: "com.mitchellh.ghostty") else {
            return []
        }

        let script = """
        set fieldSeparator to ASCII character 31
        set recordSeparator to ASCII character 30
        tell application "Ghostty"
            if not (it is running) then return ""
            set outputLines to {}
            repeat with aTerminal in terminals
                set terminalID to ""
                set terminalDirectory to ""
                set terminalTitle to ""
                try
                    set terminalID to (id of aTerminal as text)
                end try
                try
                    set terminalDirectory to (working directory of aTerminal as text)
                end try
                try
                    set terminalTitle to (name of aTerminal as text)
                end try
                set end of outputLines to terminalID & fieldSeparator & terminalDirectory & fieldSeparator & terminalTitle
            end repeat
            set AppleScript's text item delimiters to recordSeparator
            set joinedOutput to outputLines as string
            set AppleScript's text item delimiters to ""
            return joinedOutput
        end tell
        """

        guard let output = try? runAppleScript(script) else {
            return nil
        }

        return output
            .split(separator: Character(Self.recordSeparator), omittingEmptySubsequences: true)
            .map(String.init)
            .compactMap { line in
                let values = line.components(separatedBy: Self.fieldSeparator)
                guard values.count == 3 else { return nil }
                return GhosttyTerminalSnapshot(
                    sessionID: values[0],
                    workingDirectory: values[1],
                    title: values[2]
                )
            }
    }

    private func fetchTerminalSnapshots() -> [TerminalTabSnapshot]? {
        guard isRunning(bundleIdentifier: "com.apple.Terminal") else {
            return []
        }

        let script = """
        set fieldSeparator to ASCII character 31
        set recordSeparator to ASCII character 30
        tell application "Terminal"
            if not (it is running) then return ""
            set outputLines to {}
            repeat with aWindow in windows
                repeat with aTab in tabs of aWindow
                    set tabTTY to ""
                    set tabTitle to ""
                    try
                        set tabTTY to (tty of aTab as text)
                    end try
                    try
                        set tabTitle to (custom title of aTab as text)
                    end try
                    set end of outputLines to tabTTY & fieldSeparator & tabTitle
                end repeat
            end repeat
            set AppleScript's text item delimiters to recordSeparator
            set joinedOutput to outputLines as string
            set AppleScript's text item delimiters to ""
            return joinedOutput
        end tell
        """

        guard let output = try? runAppleScript(script) else {
            return nil
        }

        return output
            .split(separator: Character(Self.recordSeparator), omittingEmptySubsequences: true)
            .map(String.init)
            .compactMap { line in
                let values = line.components(separatedBy: Self.fieldSeparator)
                guard values.count == 2 else { return nil }
                return TerminalTabSnapshot(
                    tty: values[0],
                    customTitle: values[1]
                )
            }
    }

    /// Strip `file://` scheme and percent-encoding from a WezTerm/Kaku cwd URL.
    private static func weztermFamilyNormalizeCWD(_ cwd: String) -> String {
        if cwd.hasPrefix("file://"), let url = URL(string: cwd) {
            return url.path
        }
        return cwd
    }

    // MARK: - Helpers

    private func needsGhosttyProbe(_ session: AgentSession) -> Bool {
        session.jumpTarget == nil && session.isProcessAlive
    }

    private func normalizedTerminalName(for value: String?) -> String? {
        value?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    private func normalizedPathForMatching(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty else { return nil }
        return URL(fileURLWithPath: value).standardizedFileURL.path.lowercased()
    }

    private func nonEmptyValue(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty else { return nil }
        return trimmed
    }

    private func isRunning(bundleIdentifier: String) -> Bool {
        NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier).isEmpty == false
    }

    private func runAppleScript(_ script: String) throws -> String {
        let result = BoundedProcess.execute(
            executableURL: URL(fileURLWithPath: "/usr/bin/osascript"),
            arguments: ["-e", script],
            timeout: Self.appleScriptTimeout
        )

        if result.timedOut {
            throw NSError(domain: "TerminalJumpTargetResolver", code: 408, userInfo: [
                NSLocalizedDescriptionKey: "AppleScript probe timed out.",
            ])
        }

        guard result.succeeded else {
            throw NSError(
                domain: "TerminalJumpTargetResolver",
                code: Int(result.exitStatus ?? -1),
                userInfo: [
                    NSLocalizedDescriptionKey: result.standardError.isEmpty
                        ? "AppleScript probe failed."
                        : result.standardError,
                ]
            )
        }

        return result.standardOutput
    }
}
