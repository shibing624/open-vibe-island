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
/// These assert on the parsed values rather than on non-nil, because a pane id
/// in the wrong form would still be non-nil and still fail to select anything.
struct HookTmuxIdentityTests {
    @Test
    func readsPaneIDAndSocketPathFromTmuxEnvironment() {
        let identity = HookTerminalContext.tmuxIdentity(
            from: [
                "TMUX": "/private/tmp/tmux-501/default,12345,0",
                "TMUX_PANE": "%3"
            ]
        )

        // `%3` is already the form `select-pane -t` takes; it must survive
        // verbatim rather than being normalized into something else.
        #expect(identity?.paneID == "%3")
        #expect(identity?.socketPath == "/private/tmp/tmux-501/default")
    }

    /// Outside tmux there is no partial answer to give.
    @Test
    func returnsNilOutsideTmux() {
        #expect(HookTerminalContext.tmuxIdentity(from: [:]) == nil)
        #expect(HookTerminalContext.tmuxIdentity(from: ["TERM_PROGRAM": "ghostty"]) == nil)
    }

    /// A socket path is how one tmux server is told from another, but a pane
    /// with no socket is still selectable on the default server.
    @Test
    func paneWithoutSocketStillResolves() {
        let identity = HookTerminalContext.tmuxIdentity(from: ["TMUX_PANE": "%7"])

        #expect(identity?.paneID == "%7")
        #expect(identity?.socketPath == nil)
    }

    /// `TMUX_PANE` present but blank is not a pane.
    @Test
    func blankPaneIDIsNotAPane() {
        #expect(HookTerminalContext.tmuxIdentity(from: ["TMUX_PANE": "   "]) == nil)
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
            }
        )

        #expect(payload.tmuxTarget == "%3")
        #expect(payload.tmuxSocketPath == "/private/tmp/tmux-501/default")

        let target = payload.defaultJumpTarget
        #expect(target.tmuxTarget == "%3")
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
            }
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
            warpPaneResolver: { _ in nil }
        )

        #expect(payload.defaultJumpTarget.tmuxTarget == "%3")
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
            warpPaneResolver: { _ in nil }
        )

        #expect(payload.defaultJumpTarget.tmuxTarget == "%3")
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
            }
        )

        #expect(payload.defaultJumpTarget.tmuxTarget == "%3")
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
            }
        )

        #expect(payload.defaultJumpTarget.tmuxTarget == "%3")
        #expect(payload.defaultJumpTarget.tmuxSocketPath == "/private/tmp/tmux-501/default")
    }
}
