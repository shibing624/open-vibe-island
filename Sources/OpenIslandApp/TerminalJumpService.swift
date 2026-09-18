import AppKit
import Foundation
import OpenIslandCore

struct TerminalJumpService {
    typealias ApplicationResolver = @Sendable (String) -> URL?
    typealias AppRunningChecker = @Sendable (String) -> Bool
    typealias OpenAction = @Sendable ([String]) throws -> Void
    typealias AppleScriptRunner = @Sendable (String) throws -> String
    typealias ProcessRunner = @Sendable (String, [String]) -> Bool
    typealias WarpFocusedPaneReader = @Sendable () -> String?
    typealias WarpTabCountReader = @Sendable () -> Int
    /// Returns true when Warp is the system's frontmost app and ready to
    /// receive the next tab-advance command. Production asks
    /// `NSWorkspace.shared.frontmostApplication`; tests inject `{ true }`
    /// to skip the polling loop entirely.
    typealias WarpFrontmostChecker = @Sendable () -> Bool
    /// Moves cmux onto the surface with this UUID and returns true only when
    /// cmux confirmed the switch over its control socket.
    typealias CmuxSurfaceFocuser = @Sendable (String) -> Bool
    /// Selects the tmux pane a target names, returning whether tmux accepted
    /// it. nil means "run the real tmux commands"; tests inject a stub so they
    /// can exercise the tmux branch without driving a live tmux server.
    typealias TmuxPaneSelector = @Sendable (JumpTarget) -> Bool
    /// Runs one tmux command, returning its stdout or nil when tmux rejected
    /// it. Injected so the switch-client/select-window/select-pane sequence can
    /// be asserted — including each failure point — without a live tmux server.
    /// `TmuxPaneSelector` stubs the whole pane jump; this stubs one command,
    /// which is what the ordering and abort behaviour need.
    typealias TmuxCommandRunner = @Sendable (_ socketArgs: [String], _ args: [String]) -> String?

    struct TerminalAppDescriptor {
        let displayName: String
        let bundleIdentifier: String
        let aliases: [String]
        let alternateBundleIdentifiers: [String]
        let preferredBundleIdentifiersByAlias: [String: String]

        init(
            displayName: String,
            bundleIdentifier: String,
            aliases: [String],
            alternateBundleIdentifiers: [String] = [],
            preferredBundleIdentifiersByAlias: [String: String] = [:]
        ) {
            self.displayName = displayName
            self.bundleIdentifier = bundleIdentifier
            self.aliases = aliases
            self.alternateBundleIdentifiers = alternateBundleIdentifiers
            self.preferredBundleIdentifiersByAlias = preferredBundleIdentifiersByAlias
        }

        var allBundleIdentifiers: [String] {
            [bundleIdentifier] + alternateBundleIdentifiers
        }
    }

    static let knownApps: [TerminalAppDescriptor] = [
        TerminalAppDescriptor(
            displayName: "iTerm",
            bundleIdentifier: "com.googlecode.iterm2",
            aliases: ["iterm", "iterm2", "iterm.app"]
        ),
        TerminalAppDescriptor(
            displayName: "cmux",
            bundleIdentifier: "com.cmuxterm.app",
            aliases: ["cmux"]
        ),
        TerminalAppDescriptor(
            displayName: "Ghostty",
            bundleIdentifier: "com.mitchellh.ghostty",
            aliases: ["ghostty"]
        ),
        TerminalAppDescriptor(
            displayName: "Terminal",
            bundleIdentifier: "com.apple.Terminal",
            aliases: ["terminal", "apple_terminal"]
        ),
        TerminalAppDescriptor(
            displayName: "Warp",
            bundleIdentifier: "dev.warp.Warp-Stable",
            aliases: ["warp", "warpterminal"]
        ),
        TerminalAppDescriptor(
            displayName: "WezTerm",
            bundleIdentifier: "com.github.wez.wezterm",
            aliases: ["wezterm"]
        ),
        TerminalAppDescriptor(
            displayName: "Codex.app",
            bundleIdentifier: "com.openai.codex",
            aliases: ["codex.app"]
        ),
        TerminalAppDescriptor(
            displayName: "Claude.app",
            bundleIdentifier: "com.anthropic.claudefordesktop",
            aliases: ["claude.app"]
        ),
        TerminalAppDescriptor(
            displayName: "Kaku",
            bundleIdentifier: "fun.tw93.kaku",
            aliases: ["kaku"]
        ),
        TerminalAppDescriptor(
            displayName: "Cursor",
            bundleIdentifier: "com.todesktop.230313mzl4w4u92",
            aliases: ["cursor"]
        ),
        TerminalAppDescriptor(
            displayName: "VS Code",
            bundleIdentifier: "com.microsoft.VSCode",
            aliases: ["vscode", "code", "visual studio code"]
        ),
        TerminalAppDescriptor(
            displayName: "VS Code Insiders",
            bundleIdentifier: "com.microsoft.VSCodeInsiders",
            aliases: ["vscode-insiders", "code-insiders"]
        ),
        TerminalAppDescriptor(
            displayName: "Windsurf",
            bundleIdentifier: "com.exafunction.windsurf",
            aliases: ["windsurf"]
        ),
        TerminalAppDescriptor(
            displayName: "Trae",
            bundleIdentifier: "com.trae.app",
            aliases: ["trae", "trae cn", "trae-cn", "traecn"],
            alternateBundleIdentifiers: ["cn.trae.app"],
            preferredBundleIdentifiersByAlias: [
                "trae": "com.trae.app",
                "trae cn": "cn.trae.app",
                "trae-cn": "cn.trae.app",
                "traecn": "cn.trae.app",
            ]
        ),
        TerminalAppDescriptor(
            displayName: "Qoder",
            bundleIdentifier: "com.qoder.app",
            aliases: ["qoder"],
            alternateBundleIdentifiers: ["com.qoder.qoder"]
        ),
        TerminalAppDescriptor(
            displayName: "Zed",
            bundleIdentifier: "dev.zed.Zed",
            aliases: ["zed"],
            alternateBundleIdentifiers: ["dev.zed.Zed-Preview"]
        ),
        TerminalAppDescriptor(
            displayName: "Conductor",
            bundleIdentifier: "com.conductor.app",
            aliases: ["conductor"]
        ),
        TerminalAppDescriptor(
            displayName: "IntelliJ IDEA",
            bundleIdentifier: "com.jetbrains.intellij",
            aliases: ["intellij", "idea"]
        ),
        TerminalAppDescriptor(
            displayName: "WebStorm",
            bundleIdentifier: "com.jetbrains.WebStorm",
            aliases: ["webstorm"]
        ),
        TerminalAppDescriptor(
            displayName: "PyCharm",
            bundleIdentifier: "com.jetbrains.pycharm",
            aliases: ["pycharm"]
        ),
        TerminalAppDescriptor(
            displayName: "GoLand",
            bundleIdentifier: "com.jetbrains.goland",
            aliases: ["goland"]
        ),
        TerminalAppDescriptor(
            displayName: "CLion",
            bundleIdentifier: "com.jetbrains.CLion",
            aliases: ["clion"]
        ),
        TerminalAppDescriptor(
            displayName: "RubyMine",
            bundleIdentifier: "com.jetbrains.rubymine",
            aliases: ["rubymine"]
        ),
        TerminalAppDescriptor(
            displayName: "PhpStorm",
            bundleIdentifier: "com.jetbrains.PhpStorm",
            aliases: ["phpstorm"]
        ),
        TerminalAppDescriptor(
            displayName: "Rider",
            bundleIdentifier: "com.jetbrains.rider",
            aliases: ["rider"]
        ),
        TerminalAppDescriptor(
            displayName: "RustRover",
            bundleIdentifier: "com.jetbrains.rustrover",
            aliases: ["rustrover"]
        ),
    ]

    /// Bundle identifiers of JetBrains IDEs.
    private static let jetbrainsBundleIDs: Set<String> = Set(
        knownApps
            .filter { $0.bundleIdentifier.hasPrefix("com.jetbrains.") }
            .map(\.bundleIdentifier)
    )

    /// Bundle identifiers of VS Code family editors. Derived from
    /// `vscodeFamilyCLI` so the two maps cannot drift.
    private static let vscodeFamilyBundleIDs: Set<String> = Set(vscodeFamilyCLI.keys)

    static let ghosttyFocusSettleDelay = 0.08
    static let ghosttyWindowActivationDelay = 0.04
    static let ghosttyFocusAttempts = 3

    /// Deadline for one `osascript` invocation. The window-walking scripts
    /// finish in tens of milliseconds; anything near this bound means osascript
    /// is blocked rather than slow, most often on the Automation consent prompt.
    private static let appleScriptTimeout: TimeInterval = 5

    /// Maximum time to wait for Warp to become the system frontmost app after
    /// an activation request. macOS app activation is async at the WindowServer
    /// level. Without waiting for `frontmostApplication` to actually be Warp,
    /// the first few Cmd+Shift+] keystrokes can land on whatever app was
    /// focused before activation, producing system beeps and never cycling
    /// Warp tabs. The poll loop exits as soon as Warp becomes frontmost (often
    /// 50-200ms on Apple Silicon); this constant is the cap. 1.5s tolerates
    /// machines under load where activation takes longer.
    private static let warpFrontmostMaxWait = 1.5
    /// Poll interval inside the frontmost-wait loop. Smaller = lower latency
    /// once Warp arrives but more SyscallChurn.
    private static let warpFrontmostPollInterval = 0.025
    /// How long to wait after each Cmd+Shift+] keystroke before re-reading
    /// `windows.active_tab_index` from Warp's SQLite. Warp persists the new
    /// active tab index a few tens of milliseconds after processing the
    /// keystroke; reading too soon can return stale state and cause the
    /// cycling loop to terminate at the wrong tab.
    private static let warpTabCycleSettleDelay = 0.1

    private let applicationResolver: ApplicationResolver
    private let appRunningChecker: AppRunningChecker
    private let openAction: OpenAction
    private let appleScriptRunner: AppleScriptRunner
    private let processRunner: ProcessRunner
    private let warpFocusedPaneReader: WarpFocusedPaneReader
    private let warpTabCountReader: WarpTabCountReader
    private let warpKeystroker: KeystrokeInjector
    private let warpFrontmostChecker: WarpFrontmostChecker
    private let cmuxSurfaceFocuser: CmuxSurfaceFocuser
    private let tmuxPaneSelector: TmuxPaneSelector?
    private let tmuxCommandRunner: TmuxCommandRunner?

    init(
        applicationResolver: @escaping ApplicationResolver = { bundleIdentifier in
            NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier)
        },
        appRunningChecker: @escaping AppRunningChecker = { bundleIdentifier in
            NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier).isEmpty == false
        },
        openAction: @escaping OpenAction = Self.defaultOpenAction(arguments:),
        appleScriptRunner: @escaping AppleScriptRunner = Self.defaultAppleScriptRunner(script:),
        processRunner: @escaping ProcessRunner = Self.defaultProcessRunner(executable:arguments:),
        warpFocusedPaneReader: @escaping WarpFocusedPaneReader = { WarpSQLiteReader().currentFocusedPaneUUID() },
        warpTabCountReader: @escaping WarpTabCountReader = { WarpSQLiteReader().tabCountInActiveWindow() },
        warpKeystroker: KeystrokeInjector = DefaultKeystrokeInjector(),
        warpFrontmostChecker: @escaping WarpFrontmostChecker = {
            // Use NSWorkspace.frontmostApplication (live workspace state)
            // rather than NSRunningApplication.isActive (a cached property
            // updated via KVO that can lag the real frontmost transition).
            NSWorkspace.shared.frontmostApplication?.bundleIdentifier
                == "dev.warp.Warp-Stable"
        },
        cmuxSurfaceFocuser: @escaping CmuxSurfaceFocuser = { surfaceID in
            guard let socketPath = Self.resolveCmuxSocketPath() else { return false }
            return Self.focusCmuxSurface(surfaceID: surfaceID, socketPath: socketPath)
        },
        tmuxPaneSelector: TmuxPaneSelector? = nil,
        tmuxCommandRunner: TmuxCommandRunner? = nil
    ) {
        self.applicationResolver = applicationResolver
        self.appRunningChecker = appRunningChecker
        self.openAction = openAction
        self.appleScriptRunner = appleScriptRunner
        self.processRunner = processRunner
        self.warpFocusedPaneReader = warpFocusedPaneReader
        self.warpTabCountReader = warpTabCountReader
        self.warpKeystroker = warpKeystroker
        self.warpFrontmostChecker = warpFrontmostChecker
        self.cmuxSurfaceFocuser = cmuxSurfaceFocuser
        self.tmuxPaneSelector = tmuxPaneSelector
        self.tmuxCommandRunner = tmuxCommandRunner
    }

    /// Probe, plan, execute.
    ///
    /// The three used to be one 480-line function whose branch order was the
    /// only record of the jump policy, which is why adding a terminal meant
    /// editing a dozen places and why a wrong target could only be reproduced
    /// by hand. The probe is the only part that touches the machine; the plan
    /// is a value, and the executor is the only part that sequences.
    func jump(to target: JumpTarget) throws -> String {
        let program = try planProgram(for: target)
        return try JumpExecutor.execute(program, perform: perform(_:))
    }

    /// The plan for `target`, with its block reason turned into the error
    /// `jump(to:)` reports.
    func planProgram(for target: JumpTarget) throws -> JumpProgram {
        switch JumpPlanner.plan(target, environment: probeEnvironment(for: target)) {
        case let .steps(program):
            return program
        case let .blocked(reason):
            throw reason.jumpError
        }
    }

    // MARK: - Environment probe

    /// Gathers everything planning branches on. The only part of a jump that
    /// asks the machine anything; the planner reads the result as data.
    func probeEnvironment(for target: JumpTarget) -> JumpEnvironment {
        let descriptor = jumpDescriptor(for: target)
        let appIsRunning = descriptor.map { appRunningChecker($0.resolvedBundleIdentifier) } ?? false
        // Uniformly nil when there is no directory: the fallback that opens one
        // requires both a resolved descriptor and a directory that exists, and
        // an invented `true` there would read as a fact nobody checked.
        let workingDirectoryExists = target.workingDirectory
            .map { FileManager.default.fileExists(atPath: $0) } ?? false

        var weztermCLIPath: String?
        if let descriptor, descriptor.kind == .weztermFamily {
            weztermCLIPath = weztermFamilyCLIPath(for: descriptor.resolvedBundleIdentifier)
        }

        return JumpEnvironment(
            descriptor: descriptor,
            appIsRunning: appIsRunning,
            workingDirectoryExists: workingDirectoryExists,
            weztermCLIPath: weztermCLIPath,
            zellij: probeZellij(target)
        )
    }

    /// Resolves the target's terminal name and classifies it into the kind the
    /// plan branches on, so no branch has to read a bundle identifier or a
    /// string again.
    private func jumpDescriptor(for target: JumpTarget) -> JumpDescriptor? {
        guard let descriptor = resolveTerminalApp(preferredName: target.terminalApp) else {
            return nil
        }

        let preferredBundleIdentifier = preferredBundleIdentifierForAlias(
            for: descriptor,
            normalizedPreferredName: normalizeTerminalAppName(target.terminalApp)
        )
        let resolvedBundleIdentifier = resolveBundleIdentifier(
            for: descriptor,
            preferredBundleIdentifier: preferredBundleIdentifier
        )

        let kind: JumpTerminalKind
        switch resolvedBundleIdentifier {
        case "com.mitchellh.ghostty": kind = .ghostty
        case "com.googlecode.iterm2": kind = .iterm
        case "com.apple.Terminal": kind = .terminalApp
        case "com.cmuxterm.app": kind = .cmux
        case "dev.warp.Warp-Stable": kind = .warp
        case "fun.tw93.kaku", "com.github.wez.wezterm": kind = .weztermFamily
        case "com.openai.codex": kind = .codexApp
        case "com.anthropic.claudefordesktop": kind = .claudeApp
        case "com.conductor.app": kind = .conductorApp
        case let id where Self.vscodeFamilyBundleIDs.contains(id): kind = .vscodeFamily
        case let id where Self.jetbrainsBundleIDs.contains(id): kind = .jetbrains
        default: kind = .other
        }

        return JumpDescriptor(
            displayName: descriptor.displayName,
            resolvedBundleIdentifier: resolvedBundleIdentifier,
            declaredBundleIdentifier: descriptor.bundleIdentifier,
            kind: kind
        )
    }

    /// Locates the Zellij pane the session recorded, so the planner only has to
    /// decide what to do with it.
    private func probeZellij(_ target: JumpTarget) -> ZellijProbe {
        guard target.terminalApp.lowercased() == "zellij" else {
            return .notZellij
        }

        guard let encoded = target.terminalSessionID, !encoded.isEmpty else {
            return .blocked(.multiplexerUnavailable(Self.zellijUnlocatedMessage))
        }

        let parts = encoded.split(separator: ":", maxSplits: 1)
        guard let paneID = Int(parts[0]) else {
            return .blocked(.multiplexerUnavailable(Self.zellijUnlocatedMessage))
        }
        let sessionName = parts.count > 1 ? String(parts[1]) : nil

        guard let zellijPath = resolveZellijPath() else {
            return .blocked(.multiplexerUnavailable(Self.zellijUnlocatedMessage))
        }

        guard let tabPosition = zellijTabPosition(
            zellijPath: zellijPath,
            sessionName: sessionName,
            paneID: paneID
        ) else {
            return .blocked(.multiplexerUnavailable(Self.zellijUnlocatedMessage))
        }

        return .located(path: zellijPath, session: sessionName, tabPosition: tabPosition)
    }

    /// What the Zellij path reports when the pane cannot be found. Whichever
    /// step of the probe gave up, the user gets this one sentence: the
    /// distinction is not actionable for them, and it was never surfaced
    /// before either.
    private static let zellijUnlocatedMessage = "Zellij (could not locate the pane)"

    // MARK: - Step execution

    /// Performs one planned action.
    ///
    /// `nil` from a terminal helper means "this did not land" and the plan
    /// carries on to its next step; only `open` failing is fatal, which is the
    /// behaviour the ladder had.
    private func perform(_ action: JumpAction) throws -> JumpStepOutcome {
        switch action {
        case let .tmuxSelectPane(target):
            let selected = tmuxPaneSelector.map { $0(target) } ?? jumpToTmuxPane(target)
            return selected ? .keepGoing : .failed

        case let .focusGhostty(target):
            return try jumpToGhosttyTerminal(target) ? .keepGoing : .failed
        case let .focusITerm(target):
            return try jumpToITermSession(target) ? .keepGoing : .failed
        case let .focusTerminalTab(target):
            return try jumpToTerminalTab(target) ? .keepGoing : .failed
        case let .focusCmux(target):
            return jumpToCmuxTerminal(target) ? .keepGoing : .failed

        case let .focusZellij(path, session, tabPosition):
            var arguments: [String] = []
            if let session, !session.isEmpty {
                arguments += ["--session", session]
            }
            arguments += ["action", "go-to-tab", "\(tabPosition + 1)"]
            return BoundedProcess.succeeds(
                executableURL: URL(fileURLWithPath: path),
                arguments: arguments
            ) ? .keepGoing : .failed

        case let .focusWarp(target):
            return .completed(try jumpToWarpPane(target))

        case let .focusWeztermFamily(cliPath, bundleIdentifier, target):
            return jumpToWeztermFamilyTerminal(
                target,
                cliPath: cliPath,
                bundleIdentifier: bundleIdentifier
            ) ? .keepGoing : .failed

        case let .openWorkspace(cli, arguments):
            return processRunner(cli, arguments) ? .keepGoing : .failed

        case let .openApp(bundleIdentifier, path):
            // A path means "open the app at this directory"; the bare form
            // brings the app forward.
            try openAction(path.map { ["-b", bundleIdentifier, $0] } ?? ["-b", bundleIdentifier])
            return .keepGoing

        case let .openURL(url):
            try openAction([url])
            return .keepGoing

        case let .revealInFinder(path):
            try openAction([path])
            return .keepGoing
        }
    }

    private func jumpToITermSession(_ target: JumpTarget) throws -> Bool {
        let script = """
        tell application "iTerm"
            if not (it is running) then return ""
            activate
            repeat with aWindow in windows
                repeat with aTab in tabs of aWindow
                    repeat with aSession in sessions of aTab
                        set matched to false
                        if "\(escapeAppleScript(target.terminalSessionID))" is not "" and (id of aSession as text) is "\(escapeAppleScript(target.terminalSessionID))" then
                            set matched to true
                        end if
                        if not matched and "\(escapeAppleScript(target.terminalTTY))" is not "" and (tty of aSession as text) is "\(escapeAppleScript(target.terminalTTY))" then
                            set matched to true
                        end if
                        if matched then
                            select aWindow
                            tell aWindow to select aTab
                            select aSession
                            return "matched"
                        end if
                    end repeat
                end repeat
            end repeat
        end tell
        return ""
        """

        return try runAppleScript(script) == "matched"
    }

    // MARK: - VS Code family (VS Code, Insiders, Cursor, Windsurf, Trae, Qoder)

    /// Maps bundle identifiers to the CLI command used to open a workspace.
    /// Single source of truth — `vscodeFamilyBundleIDs` is derived from these
    /// keys, so adding a fork here automatically routes its activation case.
    static let vscodeFamilyCLI: [String: String] = [
        "com.microsoft.VSCode": "code",
        "com.microsoft.VSCodeInsiders": "code-insiders",
        "com.todesktop.230313mzl4w4u92": "cursor",
        "com.exafunction.windsurf": "windsurf",
        "com.trae.app": "trae",
        "cn.trae.app": "trae",
        "com.qoder.qoder": "qoder",
        "com.qoder.app": "qoder",
    ]

    // MARK: - JetBrains IDE family

    /// Maps bundle identifiers to the CLI launcher script name (typically in
    /// `/usr/local/bin/` or `~/Library/Application Support/JetBrains/Toolbox/scripts/`).
    static let jetbrainsCLI: [String: String] = [
        "com.jetbrains.intellij": "idea",
        "com.jetbrains.WebStorm": "webstorm",
        "com.jetbrains.pycharm": "pycharm",
        "com.jetbrains.goland": "goland",
        "com.jetbrains.CLion": "clion",
        "com.jetbrains.rubymine": "rubymine",
        "com.jetbrains.PhpStorm": "phpstorm",
        "com.jetbrains.rider": "rider",
        "com.jetbrains.rustrover": "rustrover",
    ]

    private func jumpToCmuxTerminal(_ target: JumpTarget) -> Bool {
        guard let surfaceID = target.terminalSessionID,
              !surfaceID.isEmpty else {
            // No surface ID — fall back to generic app activation.
            return false
        }

        guard cmuxSurfaceFocuser(surfaceID) else {
            return false
        }

        // Best-effort: activate the cmux app window.
        try? openAction(["-b", "com.cmuxterm.app"])

        return true
    }

    /// Tells cmux to focus one surface over its control socket, and waits for
    /// the reply before reporting success. Kept separate from socket-path
    /// discovery so tests can drive it against a stub cmux.
    ///
    /// Reading the reply is what makes the result trustworthy, and it is not
    /// just bookkeeping: closing the socket right after `send` drops roughly one
    /// request in ten. Against a live cmux, abandoning the connection
    /// immediately moved focus on 35 of 40 calls, while reading the reply first
    /// moved it on 40 of 40. cmux also answers `{"ok":false,"error":...}` for a
    /// surface it does not know (a stale id from a closed tab), which must not
    /// be reported as a completed jump.
    ///
    /// Note that cmux is *not* driven through AppleScript here even though it
    /// ships a scripting dictionary with a `focus` command: the socket is the
    /// supported automation surface (`access_mode: automation` in
    /// `cmux capabilities`) and needs no Automation (TCC) entitlement, so a
    /// plain `swift run` of this app can still jump.
    static func focusCmuxSurface(surfaceID: String, socketPath: String) -> Bool {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }
        defer { close(fd) }

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = socketPath.utf8CString
        guard pathBytes.count <= MemoryLayout.size(ofValue: addr.sun_path) else {
            return false
        }
        withUnsafeMutableBytes(of: &addr.sun_path) { sunPath in
            for (i, byte) in pathBytes.enumerated() {
                sunPath[i] = UInt8(bitPattern: byte)
            }
        }

        let connectResult = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPtr in
                Darwin.connect(fd, sockaddrPtr, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard connectResult == 0 else { return false }

        let request = #"{"jsonrpc":"2.0","method":"surface.focus","params":{"surface_id":"\#(surfaceID)"},"id":1}"# + "\n"
        let sent = request.withCString { ptr in
            Darwin.send(fd, ptr, strlen(ptr), 0)
        }
        guard sent > 0 else { return false }

        // Bound the wait: a cmux that accepted the request but never answers
        // must not hold the jump task open indefinitely.
        var timeout = timeval(tv_sec: 2, tv_usec: 0)
        _ = setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))

        var buffer = [UInt8](repeating: 0, count: 4096)
        let received = Darwin.recv(fd, &buffer, buffer.count, 0)
        guard received > 0,
              let reply = String(bytes: buffer[0..<received], encoding: .utf8),
              Self.cmuxReplySucceeded(reply) == true else {
            return false
        }

        return true
    }

    /// Whether a cmux JSON-RPC reply reports success. Internal rather than
    /// private so the verdict can be asserted directly — the socket path that
    /// consumes it cannot be driven without a live cmux.
    ///
    /// The socket speaks the same `{"ok":bool,"result":…}` / `{"ok":false,"error":…}`
    /// envelope for every method, so the verdict is read from `ok` rather than
    /// from the absence of an error string. A reply that is not valid JSON is
    /// not a success.
    static func cmuxReplySucceeded(_ reply: String) -> Bool? {
        guard let data = reply.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }

        return object["ok"] as? Bool
    }

    private static func resolveCmuxSocketPath() -> String? {
        let fm = FileManager.default

        // 1. cmux writes the active socket path here on startup.
        if let redirected = try? String(contentsOfFile: "/tmp/cmux-last-socket-path", encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !redirected.isEmpty,
           fm.fileExists(atPath: redirected) {
            return redirected
        }

        // 2. Standard Application Support location.
        let appSupportPath = NSHomeDirectory() + "/Library/Application Support/cmux/cmux.sock"
        if fm.fileExists(atPath: appSupportPath) {
            return appSupportPath
        }

        // 3. Legacy fallback.
        let legacyPath = "/tmp/cmux.sock"
        if fm.fileExists(atPath: legacyPath) {
            return legacyPath
        }

        return nil
    }

    // MARK: - Tmux CLI-based jump

    private func jumpToTmuxPane(_ target: JumpTarget) -> Bool {
        guard let tmuxTarget = target.tmuxTarget, !tmuxTarget.isEmpty else {
            return false
        }

        // With a runner injected, tmux does not have to be installed: the
        // sequence under test is the command order, not the binary lookup.
        let runTmux: (_ socketArgs: [String], _ args: [String]) -> String?
        if let tmuxCommandRunner {
            runTmux = { tmuxCommandRunner($0, $1) }
        } else {
            guard let tmuxPath = resolveTmuxPath() else {
                return false
            }
            runTmux = { [self] socketArgs, args in
                runTmuxCommand(tmuxPath: tmuxPath, socketArgs: socketArgs, args: args)
            }
        }

        // tmuxTarget is "session:window.pane" (e.g. "oss-contributions:3.0")
        // When running from a macOS GUI app (outside tmux), there is no
        // "current client" — $TMUX is not set. We must explicitly find the
        // client TTY and pass it via -c to switch-client.

        func socketArgs() -> [String] {
            if let socketPath = target.tmuxSocketPath, !socketPath.isEmpty {
                return ["-S", socketPath]
            }
            return []
        }

        // Extract "session:window" and "session" from "session:window.pane"
        let sessionWindow: String
        if let dotIndex = tmuxTarget.lastIndex(of: ".") {
            sessionWindow = String(tmuxTarget[tmuxTarget.startIndex..<dotIndex])
        } else {
            sessionWindow = tmuxTarget
        }

        let sessionName: String
        if let colonIndex = tmuxTarget.firstIndex(of: ":") {
            sessionName = String(tmuxTarget[tmuxTarget.startIndex..<colonIndex])
        } else {
            sessionName = tmuxTarget
        }

        // Find the client TTY (and the session it is already attached to) so we
        // can explicitly target it with switch-client.
        //
        // A client already attached to the target session is preferred over
        // whichever client tmux happens to list first: with several clients on
        // one server (a terminal window plus `tmux -CC`, or an ssh client) the
        // first line is an arbitrary one, and switching it would move a client
        // the user was not looking at while leaving the right one behind.
        let clientLines = runTmux(socketArgs(),
                                  ["list-clients", "-F", "#{client_tty}\t#{client_session}"])?
            .components(separatedBy: "\n").filter { !$0.isEmpty } ?? []
        let clients: [(tty: String, session: String?)] = clientLines.compactMap { line in
            let fields = line.components(separatedBy: "\t")
            guard let tty = fields.first, !tty.isEmpty else { return nil }
            return (tty, fields.count > 1 ? fields[1] : nil)
        }
        let selectedClient = clients.first { $0.session == sessionName } ?? clients.first
        let clientTTY = selectedClient?.tty
        let clientSession = selectedClient?.session

        // Step 1: switch-client — point the client at the target session.
        // Skip it when the client is already attached to that session: a
        // redundant switch-client makes terminals that mirror tmux state
        // (e.g. iTerm2's tmux integration, `tmux -CC`) re-attach and rebuild
        // every native window, which loses window placement/fullscreen.
        // select-window / select-pane below are enough in that case.
        //
        // A failing switch-client means the client never moved to the target
        // session — a tty that went stale between list-clients and here, or a
        // client that detached. Continuing would still run select-window and
        // select-pane, which mutate a session nobody is watching, and the jump
        // would then be reported as a completed focus. Stop instead and let the
        // caller fall back to activating the app.
        if let clientTTY, clientSession != sessionName {
            guard runTmux(socketArgs(),
                          ["switch-client", "-c", clientTTY, "-t", sessionName]) != nil else {
                return false
            }
        }

        // Step 2: select-window — switch to the correct window.
        guard runTmux(socketArgs(), ["select-window", "-t", sessionWindow]) != nil else {
            return false
        }

        // Step 3: select-pane — focus the exact pane.
        return runTmux(socketArgs(), ["select-pane", "-t", tmuxTarget]) != nil
    }

    /// Run a tmux command and return its stdout (nil on failure or timeout).
    private func runTmuxCommand(tmuxPath: String, socketArgs: [String], args: [String]) -> String? {
        BoundedProcess.run(
            executableURL: URL(fileURLWithPath: tmuxPath),
            arguments: socketArgs + args
        )
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

    // MARK: - Zellij CLI-based jump

    private func resolveZellijPath() -> String? {
        let candidates = [
            NSHomeDirectory() + "/.local/bin/zellij",
            "/usr/local/bin/zellij",
            "/opt/homebrew/bin/zellij",
        ]
        if let found = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) {
            return found
        }

        // Fallback: which.
        guard let path = BoundedProcess.run(
            executableURL: URL(fileURLWithPath: "/usr/bin/which"),
            arguments: ["zellij"]
        ), !path.isEmpty else {
            return nil
        }
        return path
    }

    private struct ZellijPaneInfo: Decodable {
        let id: Int
        let tabPosition: Int?

        enum CodingKeys: String, CodingKey {
            case id
            case tabPosition = "tab_position"
        }
    }

    /// Queries Zellij for pane info and returns the tab position of the given pane.
    private func zellijTabPosition(
        zellijPath: String,
        sessionName: String?,
        paneID: Int
    ) -> Int? {
        var args: [String] = []
        if let sessionName, !sessionName.isEmpty {
            args += ["--session", sessionName]
        }
        args += ["action", "list-panes", "--json", "--tab"]

        guard let output = BoundedProcess.run(
            executableURL: URL(fileURLWithPath: zellijPath),
            arguments: args
        ),
            let panes = try? JSONDecoder().decode([ZellijPaneInfo].self, from: Data(output.utf8)) else {
            return nil
        }

        return panes.first(where: { $0.id == paneID })?.tabPosition
    }

    private func jumpToGhosttyTerminal(_ target: JumpTarget) throws -> Bool {
        try runAppleScript(ghosttyJumpScript(for: target)) == "matched"
    }

    func ghosttyJumpScript(for target: JumpTarget) -> String {
        let terminalSessionID = escapeAppleScript(target.terminalSessionID)
        let workingDirectory = escapeAppleScript(target.workingDirectory)
        let paneTitle = escapeAppleScript(target.paneTitle)

        return """
        tell application "Ghostty"
            if not (it is running) then return ""
            activate

            set targetWindow to missing value
            set targetTab to missing value
            set targetTerminal to missing value

            repeat with aWindow in windows
                repeat with aTab in tabs of aWindow
                    repeat with aTerminal in terminals of aTab
                        if "\(terminalSessionID)" is not "" and (id of aTerminal as text) is "\(terminalSessionID)" then
                            set targetWindow to aWindow
                            set targetTab to aTab
                            set targetTerminal to aTerminal
                            exit repeat
                        end if
                    end repeat

                    if targetTerminal is not missing value then
                        exit repeat
                    end if
                end repeat

                if targetTerminal is not missing value then
                    exit repeat
                end if
            end repeat

            if targetTerminal is missing value and "\(workingDirectory)" is not "" then
                repeat with aWindow in windows
                    repeat with aTab in tabs of aWindow
                        repeat with aTerminal in terminals of aTab
                            if (working directory of aTerminal as text) is "\(workingDirectory)" then
                                set targetWindow to aWindow
                                set targetTab to aTab
                                set targetTerminal to aTerminal
                                exit repeat
                            end if
                        end repeat

                        if targetTerminal is not missing value then
                            exit repeat
                        end if
                    end repeat

                    if targetTerminal is not missing value then
                        exit repeat
                    end if
                end repeat
            end if

            if targetTerminal is missing value and "\(paneTitle)" is not "" then
                repeat with aWindow in windows
                    repeat with aTab in tabs of aWindow
                        repeat with aTerminal in terminals of aTab
                            if (name of aTerminal as text) contains "\(paneTitle)" then
                                set targetWindow to aWindow
                                set targetTab to aTab
                                set targetTerminal to aTerminal
                                exit repeat
                            end if
                        end repeat

                        if targetTerminal is not missing value then
                            exit repeat
                        end if
                    end repeat

                    if targetTerminal is not missing value then
                        exit repeat
                    end if
                end repeat
            end if

            if targetTerminal is missing value then return ""

            if "\(terminalSessionID)" is "" then
                if targetWindow is not missing value then
                    activate window targetWindow
                    delay \(Self.ghosttyWindowActivationDelay)
                end if

                if targetTab is not missing value then
                    select tab targetTab
                    delay \(Self.ghosttyWindowActivationDelay)
                end if

                focus targetTerminal
                delay \(Self.ghosttyFocusSettleDelay)
                return "matched"
            end if

            repeat \(Self.ghosttyFocusAttempts) times
                if targetWindow is not missing value then
                    activate window targetWindow
                    delay \(Self.ghosttyWindowActivationDelay)
                end if

                if targetTab is not missing value then
                    select tab targetTab
                    delay \(Self.ghosttyWindowActivationDelay)
                end if

                focus targetTerminal
                -- Ghostty updates the focused split asynchronously after focus returns.
                delay \(Self.ghosttyFocusSettleDelay)

                try
                    if (id of focused terminal of selected tab of front window as text) is "\(terminalSessionID)" then
                        return "matched"
                    end if
                end try
            end repeat
        end tell
        return ""
        """
    }

    private func jumpToTerminalTab(_ target: JumpTarget) throws -> Bool {
        let script = """
        tell application "Terminal"
            if not (it is running) then return ""
            activate
            repeat with aWindow in windows
                repeat with aTab in tabs of aWindow
                    if "\(escapeAppleScript(target.terminalTTY))" is not "" and (tty of aTab as text) is "\(escapeAppleScript(target.terminalTTY))" then
                        set selected of aTab to true
                        set frontmost of aWindow to true
                        return "matched"
                    end if
                    if "\(escapeAppleScript(target.paneTitle))" is not "" and (custom title of aTab as text) contains "\(escapeAppleScript(target.paneTitle))" then
                        set selected of aTab to true
                        set frontmost of aWindow to true
                        return "matched"
                    end if
                end repeat
            end repeat
        end tell
        return ""
        """

        return try runAppleScript(script) == "matched"
    }

    // MARK: - WezTerm-family (Kaku / WezTerm) CLI-based jump

    private func weztermFamilyCLIPath(for bundleIdentifier: String) -> String? {
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

        // Try well-known .app bundle paths first (most reliable).
        let bundleCandidates = [
            "/Applications/\(appName).app/Contents/MacOS/\(cliName)",
            NSHomeDirectory() + "/Applications/\(appName).app/Contents/MacOS/\(cliName)",
        ]
        if let found = bundleCandidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) {
            return found
        }

        // Fallback: try PATH via /usr/bin/which.
        guard let path = BoundedProcess.run(
            executableURL: URL(fileURLWithPath: "/usr/bin/which"),
            arguments: [cliName]
        ), !path.isEmpty else {
            return nil
        }
        return path
    }

    /// Strip `file://` scheme and percent-encoding from a WezTerm/Kaku cwd URL.
    private static func weztermFamilyNormalizeCWD(_ cwd: String) -> String {
        if cwd.hasPrefix("file://"), let url = URL(string: cwd) {
            return url.path
        }
        return cwd
    }

    private func jumpToWeztermFamilyTerminal(
        _ target: JumpTarget,
        cliPath: String,
        bundleIdentifier: String
    ) -> Bool {
        guard let panes = weztermFamilyListPanes(cliPath: cliPath) else {
            return false
        }

        // Match by pane_id (stored in terminalSessionID).
        if let sessionID = target.terminalSessionID,
           let paneID = Int(sessionID),
           panes.contains(where: { $0.paneID == paneID }) {
            if weztermFamilyActivatePane(cliPath: cliPath, paneID: paneID) {
                try? openAction(["-b", bundleIdentifier])
                return true
            }
        }

        // Match by TTY.
        if let targetTTY = target.terminalTTY,
           !targetTTY.isEmpty,
           let matched = panes.first(where: { $0.ttyName == targetTTY }) {
            if weztermFamilyActivatePane(cliPath: cliPath, paneID: matched.paneID) {
                try? openAction(["-b", bundleIdentifier])
                return true
            }
        }

        // Match by working directory.
        if let targetCWD = target.workingDirectory {
            let normalizedTarget = URL(fileURLWithPath: targetCWD).standardizedFileURL.path
            if let matched = panes.first(where: {
                let paneCWD = Self.weztermFamilyNormalizeCWD($0.cwd)
                return URL(fileURLWithPath: paneCWD).standardizedFileURL.path == normalizedTarget
            }) {
                if weztermFamilyActivatePane(cliPath: cliPath, paneID: matched.paneID) {
                    try? openAction(["-b", bundleIdentifier])
                    return true
                }
            }
        }

        // Match by title.
        if !target.paneTitle.isEmpty {
            if let matched = panes.first(where: { $0.title.contains(target.paneTitle) }) {
                if weztermFamilyActivatePane(cliPath: cliPath, paneID: matched.paneID) {
                    try? openAction(["-b", bundleIdentifier])
                    return true
                }
            }
        }

        return false
    }

    struct WeztermFamilyPane: Decodable {
        let windowID: Int
        let tabID: Int
        let paneID: Int
        let title: String
        let cwd: String
        let ttyName: String?
        let isActive: Bool

        enum CodingKeys: String, CodingKey {
            case windowID = "window_id"
            case tabID = "tab_id"
            case paneID = "pane_id"
            case title
            case cwd
            case ttyName = "tty_name"
            case isActive = "is_active"
        }
    }

    private func weztermFamilyListPanes(cliPath: String) -> [WeztermFamilyPane]? {
        // JSON for every pane of every window: the output that is most likely
        // to exceed a pipe buffer, which is why it must not be read only after
        // the process has exited.
        guard let output = BoundedProcess.run(
            executableURL: URL(fileURLWithPath: cliPath),
            arguments: ["cli", "list", "--format", "json"]
        ) else {
            return nil
        }

        return try? JSONDecoder().decode([WeztermFamilyPane].self, from: Data(output.utf8))
    }

    private func weztermFamilyActivatePane(cliPath: String, paneID: Int) -> Bool {
        BoundedProcess.succeeds(
            executableURL: URL(fileURLWithPath: cliPath),
            arguments: ["cli", "activate-pane", "--pane-id", "\(paneID)"]
        )
    }

    private func jumpToWarpPane(_ target: JumpTarget) throws -> String {
        // 1. Always activate Warp first — this is the baseline behavior.
        //    `warpKeystroker.sendCmdShiftRightBracket()` also activates via
        //    AppleScript, but running `open -b` here ensures Warp is foreground
        //    even in the early-return branch below where no AppleScript ever
        //    fires.
        try openAction(["-b", "dev.warp.Warp-Stable"])

        // 2. If we don't have a mapped pane UUID, we're done. This happens
        //    when WarpSQLiteReader couldn't resolve the agent's cwd to a
        //    pane — usually because the user launched the agent through a
        //    compound command (e.g. `cd /tmp/foo && claude`) that bypassed
        //    Warp's shell-integration prompt render, so terminal_panes.cwd
        //    was never updated for that pane. See the "known limitation"
        //    note in WarpSQLiteReader.lookupPaneUUID for the full story.
        guard let targetPaneUUID = target.warpPaneUUID else {
            return "Activated Warp. No precise pane mapping available."
        }

        // 3. Wait for Warp to actually become the foreground app. `open -b`
        //    exits immediately but the WindowServer activation is async and
        //    can take 50-300ms depending on machine load. We poll
        //    `frontmostApplication` until Warp is really frontmost or we
        //    hit the cap.
        let frontmostStart = Date()
        while !warpFrontmostChecker() {
            if Date().timeIntervalSince(frontmostStart) >= Self.warpFrontmostMaxWait {
                break
            }
            Thread.sleep(forTimeInterval: Self.warpFrontmostPollInterval)
        }

        // 4. Fast path: if Warp is already showing the target pane we're
        //    done — no tab-advance needed.
        if warpFocusedPaneReader() == targetPaneUUID {
            return "Focused the matching Warp tab."
        }

        // 5. Cycle via repeated "Switch to Next Tab" clicks with a cap. We
        //    only need at most tabCount-1 cycles to reach any tab from any
        //    starting point, but +2 is safety margin for counting quirks
        //    and the rare case where active_tab_index is briefly stale
        //    between a click and the next SQLite read. The `KeystrokeInjector`
        //    protocol name is historical; the production implementation
        //    clicks the `Tab ▸ Switch to Next Tab` menu item via AX —
        //    see `DefaultKeystrokeInjector` for the rationale.
        let tabCount = max(1, warpTabCountReader())
        let maxAttempts = tabCount + 2

        for _ in 0..<maxAttempts {
            warpKeystroker.sendCmdShiftRightBracket()
            Thread.sleep(forTimeInterval: Self.warpTabCycleSettleDelay)
            if warpFocusedPaneReader() == targetPaneUUID {
                return "Focused the matching Warp tab."
            }
        }

        return "Activated Warp but could not confirm precision focus."
    }

    private func resolveTerminalApp(preferredName: String) -> TerminalAppDescriptor? {
        resolveTerminalAppForTesting(preferredName: preferredName)
    }

    /// Name resolution, reachable from tests. `jump(to:)` cannot stand in for
    /// it: every path past resolution activates an app or runs AppleScript, so
    /// asserting "this name finds this descriptor" needs the step on its own.
    func resolveTerminalAppForTesting(preferredName: String) -> TerminalAppDescriptor? {
        let normalized = normalizeTerminalAppName(preferredName)

        // "Unknown" is the hook-side sentinel meaning "we could not classify this
        // terminal". Returning nil here lets jump() fall through to the Finder
        // cwd fallback instead of silently activating the first installed
        // known terminal — the historical behavior that caused Warp sessions to
        // open Terminal.app (or worse, iTerm) windows.
        if normalized == "unknown" {
            return nil
        }

        // Only an actual name match resolves. A name we do not know is not a
        // reason to activate some other terminal: "whichever known app happens
        // to be installed" is unrelated to where the session lives, and since
        // knownApps is ordered it resolved to iTerm on most machines. The hook
        // layer does emit unmapped names — `HookTerminalContext` falls back to
        // the bare string "JetBrains" for any JetBrains IDE it cannot pin down
        // — so this path was reachable, not theoretical.
        //
        // nil sends jump() to the same Finder-cwd fallback as "unknown", which
        // at least lands the user in the right project.
        return Self.knownApps.first { descriptor in
            descriptor.displayName.lowercased() == normalized || descriptor.aliases.contains(normalized)
        }
    }

    private func normalizeTerminalAppName(_ preferredName: String) -> String {
        preferredName
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
    }

    private func preferredBundleIdentifierForAlias(
        for descriptor: TerminalAppDescriptor,
        normalizedPreferredName: String
    ) -> String? {
        if let aliasSpecific = descriptor.preferredBundleIdentifiersByAlias[normalizedPreferredName] {
            return aliasSpecific
        }
        if descriptor.displayName.lowercased() == normalizedPreferredName {
            return descriptor.bundleIdentifier
        }
        return nil
    }

    private func resolveBundleIdentifier(
        for descriptor: TerminalAppDescriptor,
        preferredBundleIdentifier: String?
    ) -> String {
        if let preferredBundleIdentifier, appRunningChecker(preferredBundleIdentifier) {
            return preferredBundleIdentifier
        }
        if let preferredBundleIdentifier, applicationResolver(preferredBundleIdentifier) != nil {
            return preferredBundleIdentifier
        }
        if let running = descriptor.allBundleIdentifiers.first(where: appRunningChecker) {
            return running
        }
        if let installed = descriptor.allBundleIdentifiers.first(where: { applicationResolver($0) != nil }) {
            return installed
        }
        return preferredBundleIdentifier ?? descriptor.bundleIdentifier
    }

    private func runAppleScript(_ script: String) throws -> String {
        try appleScriptRunner(script)
    }

    private static func defaultOpenAction(arguments: [String]) throws {
        guard BoundedProcess.succeeds(
            executableURL: URL(fileURLWithPath: "/usr/bin/open"),
            arguments: arguments
        ) else {
            throw TerminalJumpError.openFailed(arguments)
        }
    }

    private static func defaultAppleScriptRunner(script: String) throws -> String {
        // Bounded: the first osascript of a session can block on the Automation
        // (TCC) consent prompt, and the detached jump task cannot kill a child
        // already stuck in waitUntilExit.
        //
        // osascript puts the useful part (which app refused, which line failed)
        // on stderr, so report that rather than echoing the whole script back.
        let result = BoundedProcess.execute(
            executableURL: URL(fileURLWithPath: "/usr/bin/osascript"),
            arguments: ["-e", script],
            timeout: Self.appleScriptTimeout
        )

        guard result.succeeded else {
            if result.timedOut {
                throw TerminalJumpError.appleScriptFailed(
                    "osascript did not finish within \(Int(Self.appleScriptTimeout))s"
                )
            }
            throw TerminalJumpError.appleScriptFailed(
                result.standardError.isEmpty ? script : result.standardError
            )
        }

        return result.standardOutput
    }

    private static func defaultProcessRunner(executable: String, arguments: [String]) -> Bool {
        BoundedProcess.succeeds(
            executableURL: URL(fileURLWithPath: "/usr/bin/env"),
            arguments: [executable] + arguments
        )
    }

    private func escapeAppleScript(_ value: String?) -> String {
        guard let value else {
            return ""
        }

        return value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
    }
}

enum TerminalJumpError: Error, LocalizedError {
    case unsupportedTerminal(String)
    case openFailed([String])
    case appleScriptFailed(String)

    var errorDescription: String? {
        switch self {
        case let .unsupportedTerminal(terminal):
            "Could not resolve a supported terminal app for \(terminal)."
        case let .openFailed(arguments):
            "Failed to launch terminal with arguments: \(arguments.joined(separator: " "))"
        case let .appleScriptFailed(message):
            "Terminal automation failed: \(message)"
        }
    }
}
