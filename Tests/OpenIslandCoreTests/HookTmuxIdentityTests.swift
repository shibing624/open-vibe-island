import Foundation
import Testing
@testable import OpenIslandCore

/// Pins tmux pane capture, the missing half of precise jump.
///
/// `TerminalJumpService` has always implemented the precise path — select the
/// pane, then focus the hosting window — and `JumpTarget` has always had the
/// fields for it. But no hook filled `tmuxTarget`: the only writers were the
/// process-polling paths, so every hook-driven session reached
/// `TerminalJumpService` with `tmuxTarget == nil`, skipped the precise branch
/// entirely, and fell through to bare app activation.
///
/// These assert on the resolved values rather than on non-nil, because a
/// target in the wrong *shape* is still non-nil and still fails: the stored
/// form must be `session:window.pane`, which is what `TerminalJumpService`
/// splits for `switch-client` / `select-window` and what
/// `TerminalJumpTargetResolver` compares its snapshots against.
struct HookTmuxIdentityTests {
    /// Stands in for the `tmux display-message` call, so these stay hermetic.
    private static func resolver(
        expectingPane expectedPane: String? = nil,
        expectingSocket expectedSocket: String? = nil,
        returning target: String? = "demo:2.1"
    ) -> (String, String?) -> String? {
        { paneID, socketPath in
            if let expectedPane {
                #expect(paneID == expectedPane)
            }
            if let expectedSocket {
                #expect(socketPath == expectedSocket)
            }
            return target
        }
    }

    @Test
    func storesCanonicalTargetAndSocketPath() {
        let identity = HookTerminalContext.tmuxIdentity(
            from: [
                "TMUX": "/private/tmp/tmux-501/default,12345,0",
                "TMUX_PANE": "%3"
            ],
            targetResolver: Self.resolver(
                expectingPane: "%3",
                expectingSocket: "/private/tmp/tmux-501/default",
                returning: "demo:2.1"
            )
        )

        // `%3` is what the environment knows, but `session:window.pane` is
        // what every consumer of the field requires. Storing `%3` would break
        // `switch-client` and never match the resolver's snapshots.
        #expect(identity?.paneID == "demo:2.1")
        #expect(identity?.socketPath == "/private/tmp/tmux-501/default")
    }

    /// Outside tmux there is no partial answer to give.
    @Test
    func returnsNilOutsideTmux() {
        #expect(
            HookTerminalContext.tmuxIdentity(
                from: [:],
                targetResolver: Self.resolver()
            ) == nil
        )
        #expect(
            HookTerminalContext.tmuxIdentity(
                from: ["TERM_PROGRAM": "ghostty"],
                targetResolver: Self.resolver()
            ) == nil
        )
    }

    /// A socket path is how one tmux server is told from another, but a pane
    /// with no socket is still selectable on the default server.
    @Test
    func paneWithoutSocketStillResolves() {
        let identity = HookTerminalContext.tmuxIdentity(
            from: ["TMUX_PANE": "%7"],
            targetResolver: Self.resolver(
                expectingPane: "%7",
                returning: "solo:0.0"
            )
        )

        #expect(identity?.paneID == "solo:0.0")
        #expect(identity?.socketPath == nil)
    }

    /// `TMUX_PANE` present but blank is not a pane.
    @Test
    func blankPaneIDIsNotAPane() {
        #expect(
            HookTerminalContext.tmuxIdentity(
                from: ["TMUX_PANE": "   "],
                targetResolver: Self.resolver()
            ) == nil
        )
    }

    /// When tmux cannot answer, no target is better than a wrong-shaped one:
    /// a nil degrades to activating the app, while `%3` would corrupt the
    /// resolver's comparison and fail `switch-client`.
    @Test
    func unresolvableTargetYieldsNoTmuxIdentity() {
        #expect(
            HookTerminalContext.tmuxIdentity(
                from: ["TMUX_PANE": "%3"],
                targetResolver: Self.resolver(returning: nil)
            ) == nil
        )
        #expect(
            HookTerminalContext.tmuxIdentity(
                from: ["TMUX_PANE": "%3"],
                targetResolver: Self.resolver(returning: "  ")
            ) == nil
        )
    }

    /// The shape contract itself, stated against both consumers.
    @Test
    func storedTargetSplitsIntoSessionAndWindow() {
        let identity = HookTerminalContext.tmuxIdentity(
            from: ["TMUX_PANE": "%3"],
            targetResolver: Self.resolver(returning: "oss-contributions:3.0")
        )
        let target = try! #require(identity?.paneID)

        // What TerminalJumpService recovers for switch-client / select-window.
        #expect(target.prefix(while: { $0 != ":" }) == "oss-contributions")
        #expect(target[target.startIndex..<target.lastIndex(of: ".")!] == "oss-contributions:3")
    }

    /// The end of the chain that was broken: a payload resolved inside tmux
    /// produces a JumpTarget that carries the pane, which is what makes
    /// `TerminalJumpService` take its precise branch at all.
    @Test
    func resolvedPayloadCarriesPaneIntoJumpTarget() {
        let payload = AgenticaHookPayload(
            hookEventName: .runStarted,
            sessionID: "s1",
            cwd: "/tmp/demo"
        ).withRuntimeContext(
            environment: [
                "TMUX": "/private/tmp/tmux-501/default,12345,0",
                "TMUX_PANE": "%3",
                "TERM_PROGRAM": "ghostty"
            ],
            currentTTYProvider: { "/dev/ttys004" },
            terminalLocatorProvider: { _ in
                Issue.record("focused-window locator must not run inside tmux")
                return (nil, nil, nil)
            },
            tmuxTargetResolver: Self.resolver(returning: "demo:2.1")
        )

        #expect(payload.tmuxTarget == "demo:2.1")
        #expect(payload.tmuxSocketPath == "/private/tmp/tmux-501/default")

        let target = payload.defaultJumpTarget
        #expect(target.tmuxTarget == "demo:2.1")
        #expect(target.tmuxSocketPath == "/private/tmp/tmux-501/default")
    }

    /// Outside tmux the locator is still the best available answer, so the
    /// tmux branch must not have disabled it.
    @Test
    func focusedWindowLocatorStillRunsOutsideTmux() {
        var locatorCalls = 0
        let payload = AgenticaHookPayload(
            hookEventName: .runStarted,
            sessionID: "s1",
            cwd: "/tmp/demo"
        ).withRuntimeContext(
            environment: ["TERM_PROGRAM": "ghostty"],
            currentTTYProvider: { "/dev/ttys004" },
            terminalLocatorProvider: { _ in
                locatorCalls += 1
                return ("ghostty-1", nil, "agentica ~/tmp/demo")
            },
            tmuxTargetResolver: Self.resolver(returning: "unused:0.0")
        )

        #expect(locatorCalls == 1)
        #expect(payload.tmuxTarget == nil)
        #expect(payload.terminalSessionID == "ghostty-1")
    }

    // MARK: - The other payload types
    //
    // The gap was never agentica-specific: none of the eight defaultJumpTarget
    // implementations filled tmux identity. Claude's path alone serves seven
    // CLI sources, so a regression there is the widest of the set.

    private static let tmuxEnvironment = [
        "TMUX": "/private/tmp/tmux-501/default,12345,0",
        "TMUX_PANE": "%3",
        "TERM_PROGRAM": "ghostty"
    ]

    @Test
    func claudePayloadCarriesPaneIntoJumpTarget() {
        let payload = ClaudeHookPayload(
            cwd: "/tmp/demo",
            hookEventName: .sessionStart,
            sessionID: "s1"
        ).withRuntimeContext(
            environment: Self.tmuxEnvironment,
            currentTTYProvider: { "/dev/ttys004" },
            terminalLocatorProvider: { _ in
                Issue.record("focused-window locator must not run inside tmux")
                return (nil, nil, nil)
            },
            warpPaneResolver: { _ in nil },
            tmuxTargetResolver: Self.resolver(returning: "demo:2.1")
        )

        #expect(payload.defaultJumpTarget.tmuxTarget == "demo:2.1")
        #expect(payload.defaultJumpTarget.tmuxSocketPath == "/private/tmp/tmux-501/default")
    }

    @Test
    func codexPayloadCarriesPaneIntoJumpTarget() {
        let payload = CodexHookPayload(
            cwd: "/tmp/demo",
            hookEventName: .sessionStart,
            model: "gpt-4o",
            permissionMode: .default,
            sessionID: "s1",
            transcriptPath: nil
        ).withRuntimeContext(
            environment: Self.tmuxEnvironment,
            currentTTYProvider: { "/dev/ttys004" },
            terminalLocatorProvider: { _ in
                Issue.record("focused-window locator must not run inside tmux")
                return (nil, nil, nil)
            },
            warpPaneResolver: { _ in nil },
            tmuxTargetResolver: Self.resolver(returning: "demo:2.1")
        )

        #expect(payload.defaultJumpTarget.tmuxTarget == "demo:2.1")
        #expect(payload.defaultJumpTarget.tmuxSocketPath == "/private/tmp/tmux-501/default")
    }

    @Test
    func geminiPayloadCarriesPaneIntoJumpTarget() {
        let payload = GeminiHookPayload(
            cwd: "/tmp/demo",
            hookEventName: .sessionStart,
            sessionID: "s1"
        ).withRuntimeContext(
            environment: Self.tmuxEnvironment,
            currentTTYProvider: { "/dev/ttys004" },
            terminalLocatorProvider: { _ in
                Issue.record("focused-window locator must not run inside tmux")
                return (nil, nil, nil)
            },
            tmuxTargetResolver: Self.resolver(returning: "demo:2.1")
        )

        #expect(payload.defaultJumpTarget.tmuxTarget == "demo:2.1")
        #expect(payload.defaultJumpTarget.tmuxSocketPath == "/private/tmp/tmux-501/default")
    }

    @Test
    func grokPayloadCarriesPaneIntoJumpTarget() {
        let payload = GrokHookPayload(
            cwd: "/tmp/demo",
            hookEventName: .sessionStart,
            sessionID: "s1"
        ).withRuntimeContext(
            environment: Self.tmuxEnvironment,
            currentTTYProvider: { "/dev/ttys004" },
            terminalLocatorProvider: { _ in
                Issue.record("focused-window locator must not run inside tmux")
                return (nil, nil, nil)
            },
            tmuxTargetResolver: Self.resolver(returning: "demo:2.1")
        )

        #expect(payload.defaultJumpTarget.tmuxTarget == "demo:2.1")
        #expect(payload.defaultJumpTarget.tmuxSocketPath == "/private/tmp/tmux-501/default")
    }
}
