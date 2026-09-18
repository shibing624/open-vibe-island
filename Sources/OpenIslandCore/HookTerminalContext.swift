import Foundation

/// Terminal identification shared by hook payloads that are not spawned with a
/// controlling TTY of their own.
///
/// Older hook payload types (Claude / Codex / Gemini / Grok) each carry their own
/// private copy of this logic. New sources use this helper instead of growing a
/// sixth copy; the existing ones are deliberately left untouched so adding a
/// source cannot regress a shipped one.
enum HookTerminalContext {
    /// Terminal emulator inferred from the environment the agent CLI passed down.
    ///
    /// Hook processes inherit the agent's environment, so `TERM_PROGRAM` and
    /// friends still describe the terminal even when the hook itself was
    /// detached from it.
    static func inferTerminalApp(from environment: [String: String]) -> String? {
        if environment["ITERM_SESSION_ID"] != nil || environment["LC_TERMINAL"] == "iTerm2" {
            return "iTerm"
        }

        if environment["CMUX_WORKSPACE_ID"] != nil || environment["CMUX_SOCKET_PATH"] != nil {
            return "cmux"
        }

        if environment["ZELLIJ"] != nil {
            return "Zellij"
        }

        if environment["GHOSTTY_RESOURCES_DIR"] != nil {
            return "Ghostty"
        }

        if environment["WARP_IS_LOCAL_SHELL_SESSION"] != nil {
            return "Warp"
        }

        switch environment["TERM_PROGRAM"]?.lowercased() {
        case .some("apple_terminal"):
            return "Terminal"
        case .some("iterm.app"), .some("iterm2"):
            return "iTerm"
        case let value? where value.contains("ghostty"):
            return "Ghostty"
        case let value? where value.contains("warp"):
            return "Warp"
        case let value? where value.contains("wezterm"):
            return "WezTerm"
        case .some("kaku"):
            return "Kaku"
        case .some("vscode"):
            return "VS Code"
        case .some("vscode-insiders"):
            return "VS Code Insiders"
        case .some("windsurf"):
            return "Windsurf"
        case .some("trae"):
            return "Trae"
        case .some("zed"):
            return "Zed"
        default:
            break
        }

        if let terminalEmulator = environment["TERMINAL_EMULATOR"]?.lowercased(),
           terminalEmulator.contains("jetbrains") {
            if let bundleID = environment["__CFBundleIdentifier"]?.lowercased() {
                if bundleID.contains("webstorm") { return "WebStorm" }
                if bundleID.contains("pycharm") { return "PyCharm" }
                if bundleID.contains("goland") { return "GoLand" }
                if bundleID.contains("clion") { return "CLion" }
                if bundleID.contains("rubymine") { return "RubyMine" }
                if bundleID.contains("phpstorm") { return "PhpStorm" }
                if bundleID.contains("rider") { return "Rider" }
                if bundleID.contains("rustrover") { return "RustRover" }
            }
            return "JetBrains"
        }

        return nil
    }

    /// The TTY the agent CLI is attached to.
    ///
    /// A hook spawned with `setsid` has no controlling terminal of its own, so
    /// `/usr/bin/tty` fails and the parent process (the agent CLI) is the one
    /// holding the terminal.
    static func currentTTY() -> String? {
        if let tty = commandOutput(executablePath: "/usr/bin/tty", arguments: []),
           !tty.contains("not a tty") {
            return tty
        }

        return processTTY(pid: getppid())
    }

    static func processTTY(pid: pid_t) -> String? {
        guard let raw = commandOutput(
            executablePath: "/bin/ps",
            arguments: ["-p", "\(pid)", "-o", "tty="]
        ) else {
            return nil
        }

        let tty = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !tty.isEmpty, tty != "??", tty != "-" else {
            return nil
        }

        return tty.hasPrefix("/dev/") ? tty : "/dev/\(tty)"
    }

    /// The tmux pane the agent is running in, in the `session:window.pane`
    /// form every consumer of `JumpTarget.tmuxTarget` expects.
    ///
    /// Without this, `JumpTarget.tmuxTarget` was nil for every hook-driven
    /// session, so `TerminalJumpService` skipped its precise branch entirely
    /// and fell through to activating the terminal app.
    ///
    /// The environment supplies the two things only it knows: `TMUX_PANE`
    /// identifies this pane (`%3`), and the first comma-separated field of
    /// `TMUX` (`<socket>,<pid>,<session>`) is the server socket that tells one
    /// tmux server from another. But `%3` is *not* the stored format:
    /// `TerminalJumpService` splits the target on `:` and `.` to recover the
    /// session for `switch-client` and the window for `select-window`, and
    /// `TerminalJumpTargetResolver` compares it against
    /// `#{session_name}:#{window_index}.#{pane_index}`. Storing `%3` would
    /// make `switch-client -t %3` fail and would never match the resolver's
    /// snapshot, so the field would be rewritten on every poll.
    ///
    /// So the canonical target is asked of tmux rather than assembled here —
    /// tmux is the only thing that knows which session and window hold a pane,
    /// and both can change while the agent runs. When tmux cannot answer this
    /// returns nil: no target at all degrades to activating the app, whereas a
    /// wrongly-shaped one corrupts the resolver's state.
    static func tmuxIdentity(
        from environment: [String: String],
        targetResolver: (_ paneID: String, _ socketPath: String?) -> String? = defaultTmuxTarget
    ) -> (paneID: String, socketPath: String?)? {
        guard let paneID = environment["TMUX_PANE"]?
            .trimmingCharacters(in: .whitespacesAndNewlines),
            !paneID.isEmpty else {
            return nil
        }

        let socketPath = environment["TMUX"]?
            .split(separator: ",", maxSplits: 1, omittingEmptySubsequences: false)
            .first
            .map(String.init)
            .flatMap { $0.isEmpty ? nil : $0 }

        guard let target = targetResolver(paneID, socketPath)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
            !target.isEmpty else {
            return nil
        }

        return (target, socketPath)
    }

    /// The cmux surface (its "tab") the agent is running in.
    ///
    /// `locator(for:)` cannot answer this: it asks the *focused* window, which
    /// in cmux would stamp whichever tab the user last looked at rather than the
    /// tab holding the agent — the same mistake `opaqueTerminalApps` exists to
    /// prevent. The environment is the only honest source, and cmux sets
    /// `CMUX_SURFACE_ID` in every surface it spawns. `TerminalJumpService` hands
    /// this straight to cmux's `surface.focus` socket method, which is also what
    /// switches the enclosing workspace when the target surface lives in
    /// another one.
    ///
    /// Captured independently of tmux on purpose: a tmux pane inside a cmux
    /// surface is the normal case here, and focusing the pane is useless while
    /// cmux is still showing a different tab. Presenting the surface alone would
    /// also have to be undone after the pane is selected.
    static func cmuxSurfaceID(from environment: [String: String]) -> String? {
        guard let surfaceID = environment["CMUX_SURFACE_ID"]?
            .trimmingCharacters(in: .whitespacesAndNewlines),
            !surfaceID.isEmpty else {
            return nil
        }

        return surfaceID
    }

    /// Asks tmux for the `session:window.pane` address of one pane.
    static func defaultTmuxTarget(paneID: String, socketPath: String?) -> String? {
        guard let tmuxPath = resolveTmuxPath() else {
            return nil
        }

        var arguments: [String] = []
        if let socketPath, !socketPath.isEmpty {
            arguments += ["-S", socketPath]
        }
        arguments += [
            "display-message", "-p", "-t", paneID,
            "-F", "#{session_name}:#{window_index}.#{pane_index}"
        ]

        return commandOutput(executablePath: tmuxPath, arguments: arguments)
    }

    private static func resolveTmuxPath() -> String? {
        let candidates = [
            "/opt/homebrew/bin/tmux",
            "/usr/local/bin/tmux",
            "/usr/bin/tmux"
        ]

        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    /// Session / TTY / title of the focused window of `terminalApp`, via AppleScript.
    static func locator(for terminalApp: String) -> (sessionID: String?, tty: String?, title: String?) {
        let normalized = terminalApp.lowercased()

        if normalized.contains("iterm") {
            let values = osascriptValues(script: GeminiHookPayload.terminalLocatorAppleScript(for: "iTerm"))
            return (values[safe: 0], values[safe: 1], values[safe: 2])
        }

        if normalized.contains("ghostty") {
            let values = osascriptValues(script: GeminiHookPayload.terminalLocatorAppleScript(for: "Ghostty"))
            return (values[safe: 0], nil, values[safe: 2])
        }

        if normalized.contains("terminal") {
            let values = osascriptValues(script: GeminiHookPayload.terminalLocatorAppleScript(for: "Terminal"))
            return (nil, values[safe: 0], values[safe: 1])
        }

        return (nil, nil, nil)
    }

    /// Terminals whose focused-window AppleScript cannot identify the pane that
    /// actually owns the agent, so querying it would stamp the wrong target.
    private static let opaqueTerminalApps: Set<String> = [
        "cmux", "kaku", "wezterm", "zellij",
        "vs code", "vs code insiders", "cursor", "windsurf", "trae",
        "intellij idea", "webstorm", "pycharm", "goland", "clion",
        "rubymine", "phpstorm", "rider", "rustrover"
    ]

    static func supportsFocusedWindowLocator(_ terminalApp: String?) -> Bool {
        guard let terminalApp, !terminalApp.isEmpty else { return false }

        let normalized = terminalApp.lowercased()
        if normalized.contains("jetbrains") {
            return false
        }

        return !opaqueTerminalApps.contains(normalized)
    }

    private static func osascriptValues(script: String) -> [String] {
        guard !script.isEmpty,
              let raw = commandOutput(executablePath: "/usr/bin/osascript", arguments: ["-e", script]) else {
            return []
        }

        return raw
            .components(separatedBy: String(UnicodeScalar(31)!))
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
    }

    private static func commandOutput(executablePath: String, arguments: [String]) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executablePath)
        process.arguments = arguments

        let outputPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = Pipe()

        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return nil
        }

        let data = outputPipe.fileHandleForReading.readDataToEndOfFile()
        guard !data.isEmpty else {
            return nil
        }

        return String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
