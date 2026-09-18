import Foundation
import Testing
@testable import OpenIslandApp
import OpenIslandCore

/// The planner is a pure function of `JumpTarget` + `JumpEnvironment`, which is
/// the whole reason it exists: the strategy a session's terminal produces used
/// to be recorded only by the branch order of a 480-line function, so "a Zellij
/// session in Ghostty raises iTerm" could not be stated as a test at all.
///
/// Every assertion here is on the **step sequence and the sentence**, not on
/// "it did not crash". A jump that runs the right steps in the wrong order is
/// still a wrong jump.
@Suite
struct JumpPlannerTests {

    // MARK: - Fixtures

    private static func target(
        terminalApp: String,
        workingDirectory: String? = "/Users/u/repo",
        terminalSessionID: String? = nil,
        terminalTTY: String? = nil,
        tmuxTarget: String? = nil,
        warpPaneUUID: String? = nil,
        codexThreadID: String? = nil
    ) -> JumpTarget {
        JumpTarget(
            terminalApp: terminalApp,
            workspaceName: "repo",
            paneTitle: "agent",
            workingDirectory: workingDirectory,
            terminalSessionID: terminalSessionID,
            terminalTTY: terminalTTY,
            tmuxTarget: tmuxTarget,
            warpPaneUUID: warpPaneUUID,
            codexThreadID: codexThreadID
        )
    }

    /// Facts for a *resolved, running* terminal of the named kind. Individual
    /// tests override the field they are about.
    private static func environment(
        descriptor: JumpDescriptor?,
        appIsRunning: Bool = true,
        workingDirectoryExists: Bool = true,
        weztermCLIPath: String? = nil,
        zellij: ZellijProbe = .notZellij
    ) -> JumpEnvironment {
        JumpEnvironment(
            descriptor: descriptor,
            appIsRunning: appIsRunning,
            workingDirectoryExists: workingDirectoryExists,
            weztermCLIPath: weztermCLIPath,
            zellij: zellij
        )
    }

    private static func descriptor(
        _ displayName: String,
        bundleID: String,
        kind: JumpTerminalKind,
        declaredBundleID: String? = nil
    ) -> JumpDescriptor {
        JumpDescriptor(
            displayName: displayName,
            resolvedBundleIdentifier: bundleID,
            declaredBundleIdentifier: declaredBundleID ?? bundleID,
            kind: kind
        )
    }

    private static func assertPlan(
        _ target: JumpTarget,
        _ environment: JumpEnvironment,
        is expected: JumpProgram,
        sourceLocation: SourceLocation = #_sourceLocation
    ) {
        let plan = JumpPlanner.plan(target, environment: environment)
        guard case let .steps(program) = plan else {
            Issue.record("expected a program, got \(plan)", sourceLocation: sourceLocation)
            return
        }
        // The actual program goes in the message: a step list that differs by
        // one rung is the common failure here, and "they are not equal" does
        // not say which rung.
        #expect(
            program == expected,
            "plan mismatch | actual: \(program) | expected: \(expected)",
            sourceLocation: sourceLocation
        )
    }

    private static func assertBlocked(
        _ target: JumpTarget,
        _ environment: JumpEnvironment,
        is expected: JumpBlockedReason,
        sourceLocation: SourceLocation = #_sourceLocation
    ) {
        let plan = JumpPlanner.plan(target, environment: environment)
        #expect(plan == .blocked(expected), sourceLocation: sourceLocation)
    }

    // MARK: - The tmux prefix, and the ordering it forces

    /// The pane is selected first because that is what the terminal-specific
    /// step then reveals. Swapping the two makes the tab come forward showing
    /// whatever pane tmux was already on.
    @Test
    func tmuxPanesAreSelectedBeforeTheTerminalStepsThatRevealThem() {
        let target = Self.target(
            terminalApp: "Ghostty",
            terminalSessionID: "ABC",
            tmuxTarget: "oss:3.0"
        )
        let ghostty = Self.descriptor("Ghostty", bundleID: "com.mitchellh.ghostty", kind: .ghostty)

        Self.assertPlan(target, Self.environment(descriptor: ghostty), is: JumpProgram(
            steps: [
                JumpStep(.tmuxSelectPane(target)),
                JumpStep(
                    .focusGhostty(target),
                    completion: .fixed("Focused the matching tmux pane in Ghostty.")
                ),
                JumpStep(.openApp(bundleIdentifier: "com.mitchellh.ghostty", path: nil))
            ],
            finishesWith: .paneDependent(
                selected: "Focused the matching tmux pane and activated Ghostty.",
                notSelected: "Activated Ghostty. tmux pane targeting failed."
            )
        ))
    }

    /// With no resolvable terminal there is nothing to reveal the pane with, so
    /// the pane selection succeeding *is* the jump.
    @Test
    func aTmuxPaneWithNoResolvedTerminalEndsOnThePaneItself() {
        let target = Self.target(terminalApp: "JetBrains", tmuxTarget: "oss:3.0")

        Self.assertPlan(target, Self.environment(descriptor: nil), is: JumpProgram(
            steps: [
                JumpStep(
                    .tmuxSelectPane(target),
                    completion: .fixed("Focused the matching tmux pane.")
                ),
                JumpStep(.revealInFinder(path: "/Users/u/repo"))
            ],
            finishesWith: .fixed(
                "Opened repo in Finder because no supported terminal app could be resolved."
            )
        ))
    }

    /// cmux keeps the split that made a tmux pane inside a cmux tab reachable:
    /// the surface is focused whether or not the pane selection landed, and the
    /// sentence says which half did.
    @Test
    func aTmuxPaneInCmuxFocussesTheSurfaceAndNamesWhichHalfLanded() {
        let target = Self.target(
            terminalApp: "cmux",
            terminalSessionID: "4FB58912",
            tmuxTarget: "oss:3.0"
        )
        let cmux = Self.descriptor("cmux", bundleID: "com.cmuxterm.app", kind: .cmux)

        Self.assertPlan(target, Self.environment(descriptor: cmux), is: JumpProgram(
            steps: [
                JumpStep(.tmuxSelectPane(target)),
                JumpStep(
                    .focusCmux(target),
                    completion: .paneDependent(
                        selected: "Focused the matching tmux pane in cmux.",
                        notSelected: "Focused the matching cmux tab. tmux pane targeting failed."
                    )
                ),
                JumpStep(.openApp(bundleIdentifier: "com.cmuxterm.app", path: nil))
            ],
            finishesWith: .paneDependent(
                selected: "Focused the matching tmux pane and activated cmux.",
                notSelected: "Activated cmux. tmux pane targeting failed."
            )
        ))
    }

    /// A kind with no window of its own — Warp, an IDE, Codex.app — gets the
    /// pane step and then the activation, with no terminal-specific detour in
    /// between.
    @Test
    func aTmuxPaneInATerminalWithNoTabPrimitiveGoesStraightToActivation() {
        let target = Self.target(terminalApp: "Cursor", tmuxTarget: "oss:3.0")
        let cursor = Self.descriptor(
            "Cursor",
            bundleID: "com.todesktop.230313mzl4w4u92",
            kind: .vscodeFamily
        )

        Self.assertPlan(target, Self.environment(descriptor: cursor), is: JumpProgram(
            steps: [
                JumpStep(.tmuxSelectPane(target)),
                JumpStep(.openApp(bundleIdentifier: "com.todesktop.230313mzl4w4u92", path: nil))
            ],
            finishesWith: .paneDependent(
                selected: "Focused the matching tmux pane and activated Cursor.",
                notSelected: "Activated Cursor. tmux pane targeting failed."
            )
        ))
    }

    /// A fork that is both inside tmux and has an alternate bundle identifier:
    /// the tmux layer's activation addresses the *declared* id, which is the
    /// one the old code used there. Pinned because it is the only place the
    /// distinction is observable.
    @Test
    func theTmuxActivationAddressesTheDeclaredBundleIdentifier() {
        let target = Self.target(terminalApp: "Trae CN", tmuxTarget: "oss:3.0")
        let trae = Self.descriptor(
            "Trae",
            bundleID: "cn.trae.app",
            kind: .vscodeFamily,
            declaredBundleID: "com.trae.app"
        )

        Self.assertPlan(target, Self.environment(descriptor: trae), is: JumpProgram(
            steps: [
                JumpStep(.tmuxSelectPane(target)),
                JumpStep(.openApp(bundleIdentifier: "com.trae.app", path: nil))
            ],
            finishesWith: .paneDependent(
                selected: "Focused the matching tmux pane and activated Trae.",
                notSelected: "Activated Trae. tmux pane targeting failed."
            )
        ))
    }

    // MARK: - One case per terminal path
    //
    // Each of these is a specific attempt *plus* the ladder rung behind it. A
    // step that carries a `completion` ends the jump when it lands, so the rung
    // only runs when the attempt did not — which is what the old control flow
    // spelled as "if it returned, that was the answer; otherwise fall through".
    // The pair is asserted together because the rung's presence is part of the
    // policy: it is what makes a failed focus recoverable.

    @Test
    func ghosttyFocusesTheTerminalAndFallsBackToActivatingTheApp() {
        let target = Self.target(terminalApp: "Ghostty", terminalSessionID: "ABC")
        let ghostty = Self.descriptor("Ghostty", bundleID: "com.mitchellh.ghostty", kind: .ghostty)

        Self.assertPlan(target, Self.environment(descriptor: ghostty), is: JumpProgram(
            steps: [
                JumpStep(
                    .focusGhostty(target),
                    completion: .fixed("Focused the matching Ghostty terminal.")
                ),
                JumpStep(.openApp(bundleIdentifier: "com.mitchellh.ghostty", path: nil))
            ],
            finishesWith: .fixed(
                "Activated Ghostty. Exact pane targeting could not find the live terminal."
            )
        ))
    }

    @Test
    func iTermFocusesTheSessionAndFallsBackToActivatingTheApp() {
        let target = Self.target(terminalApp: "iTerm", terminalSessionID: "w0t0p0")
        let iterm = Self.descriptor("iTerm", bundleID: "com.googlecode.iterm2", kind: .iterm)

        Self.assertPlan(target, Self.environment(descriptor: iterm), is: JumpProgram(
            steps: [
                JumpStep(
                    .focusITerm(target),
                    completion: .fixed("Focused the matching iTerm session.")
                ),
                JumpStep(.openApp(bundleIdentifier: "com.googlecode.iterm2", path: nil))
            ],
            finishesWith: .fixed(
                "Activated iTerm. Exact pane targeting could not find the live terminal."
            )
        ))
    }

    @Test
    func terminalAppFocusesTheTabAndFallsBackToActivatingTheApp() {
        let target = Self.target(terminalApp: "Terminal", terminalTTY: "/dev/ttys002")
        let terminal = Self.descriptor("Terminal", bundleID: "com.apple.Terminal", kind: .terminalApp)

        Self.assertPlan(target, Self.environment(descriptor: terminal), is: JumpProgram(
            steps: [
                JumpStep(
                    .focusTerminalTab(target),
                    completion: .fixed("Focused the matching Terminal tab.")
                ),
                JumpStep(.openApp(bundleIdentifier: "com.apple.Terminal", path: nil))
            ],
            finishesWith: .fixed(
                "Activated Terminal. Exact pane targeting could not find the live terminal."
            )
        ))
    }

    @Test
    func cmuxFocusesTheSurfaceAndFallsBackToActivatingTheApp() {
        let target = Self.target(terminalApp: "cmux", terminalSessionID: "4FB58912")
        let cmux = Self.descriptor("cmux", bundleID: "com.cmuxterm.app", kind: .cmux)

        Self.assertPlan(target, Self.environment(descriptor: cmux), is: JumpProgram(
            steps: [
                JumpStep(
                    .focusCmux(target),
                    completion: .fixed("Focused the matching cmux terminal.")
                ),
                JumpStep(.openApp(bundleIdentifier: "com.cmuxterm.app", path: nil))
            ],
            finishesWith: .fixed(
                "Activated cmux. Exact pane targeting could not find the live terminal."
            )
        ))
    }

    /// Warp's step owns the sentence: it knows whether it reached the pane, and
    /// "activated but could not confirm" is a different outcome from "focused".
    @Test
    func warpReportsItsOwnOutcomeRatherThanTakingASentence() {
        let target = Self.target(terminalApp: "Warp", warpPaneUUID: "D1A5DF30")
        let warp = Self.descriptor("Warp", bundleID: "dev.warp.Warp-Stable", kind: .warp)

        Self.assertPlan(target, Self.environment(descriptor: warp), is: JumpProgram(
            steps: [JumpStep(.focusWarp(target))],
            finishesWith: .fixed("Activated Warp but could not confirm precision focus.")
        ))
    }

    @Test
    func weztermFocusesThePaneThroughItsCLIThenFallsBackToTheApp() {
        let target = Self.target(terminalApp: "WezTerm", terminalSessionID: "7")
        let wezterm = Self.descriptor("WezTerm", bundleID: "com.github.wez.wezterm", kind: .weztermFamily)

        Self.assertPlan(
            target,
            Self.environment(descriptor: wezterm, weztermCLIPath: "/opt/homebrew/bin/wezterm"),
            is: JumpProgram(
                steps: [
                    JumpStep(
                        .focusWeztermFamily(
                            cliPath: "/opt/homebrew/bin/wezterm",
                            bundleIdentifier: "com.github.wez.wezterm",
                            target: target
                        ),
                        completion: .fixed("Focused the matching WezTerm pane.")
                    ),
                    JumpStep(.openApp(bundleIdentifier: "com.github.wez.wezterm", path: nil))
                ],
                finishesWith: .fixed(
                    "Activated WezTerm. Exact pane targeting could not find the live terminal."
                )
            )
        )
    }

    /// No CLI on disk means no way to address a pane at all. Listing the step
    /// anyway would be a step that can only fail, so the plan omits it and the
    /// ladder below decides — here, activating the running app.
    @Test
    func weztermWithoutItsCLIOmitsTheStepInsteadOfListingOneThatCannotRun() {
        let target = Self.target(terminalApp: "WezTerm", terminalSessionID: "7")
        let wezterm = Self.descriptor("WezTerm", bundleID: "com.github.wez.wezterm", kind: .weztermFamily)

        Self.assertPlan(target, Self.environment(descriptor: wezterm, weztermCLIPath: nil), is: JumpProgram(
            steps: [
                JumpStep(.openApp(bundleIdentifier: "com.github.wez.wezterm", path: nil))
            ],
            finishesWith: .fixed(
                "Activated WezTerm. Exact pane targeting could not find the live terminal."
            )
        ))
    }

    @Test
    func vscodeFamilyOpensTheWorkspaceWithTheReuseFlag() {
        let target = Self.target(terminalApp: "Trae CN")
        let trae = Self.descriptor("Trae", bundleID: "cn.trae.app", kind: .vscodeFamily)

        Self.assertPlan(target, Self.environment(descriptor: trae), is: JumpProgram(
            steps: [
                JumpStep(
                    .openWorkspace(cli: "trae", arguments: ["-r", "/Users/u/repo"]),
                    completion: .fixed("Focused the matching Trae workspace.")
                ),
                // A running window is reused only if the CLI did not already
                // land the workspace, which is why this rung exists at all.
                JumpStep(.openApp(bundleIdentifier: "cn.trae.app", path: nil))
            ],
            finishesWith: .fixed("Activated Trae.")
        ))
    }

    /// JetBrains launchers take the project path alone, and the user is told
    /// "project" — the two families are separate cases for exactly this reason.
    @Test
    func jetbrainsOpensTheProjectPathWithoutTheReuseFlag() {
        let target = Self.target(terminalApp: "IntelliJ IDEA")
        let intellij = Self.descriptor("IntelliJ IDEA", bundleID: "com.jetbrains.intellij", kind: .jetbrains)

        Self.assertPlan(target, Self.environment(descriptor: intellij), is: JumpProgram(
            steps: [
                JumpStep(
                    .openWorkspace(cli: "idea", arguments: ["/Users/u/repo"]),
                    completion: .fixed("Focused the matching IntelliJ IDEA project.")
                ),
                JumpStep(.openApp(bundleIdentifier: "com.jetbrains.intellij", path: nil))
            ],
            finishesWith: .fixed("Activated IntelliJ IDEA.")
        ))
    }

    /// A *running* app with no workspace to hand it gets activated, and that is
    /// the end of the plan: the ladder's "could not find the live terminal"
    /// rung is about an app that has a precise locator, which this is not.
    @Test
    func aRunningIdeWithNoWorkspaceIsActivatedAndEndsThePlan() {
        let target = Self.target(terminalApp: "VS Code", workingDirectory: nil)
        let code = Self.descriptor("VS Code", bundleID: "com.microsoft.VSCode", kind: .vscodeFamily)

        Self.assertPlan(target, Self.environment(descriptor: code), is: JumpProgram(
            steps: [JumpStep(.openApp(bundleIdentifier: "com.microsoft.VSCode", path: nil))],
            finishesWith: .fixed("Activated VS Code.")
        ))
    }

    @Test
    func codexAppWithAThreadOpensTheConversationDeepLink() {
        let target = Self.target(terminalApp: "Codex.app", codexThreadID: "019d9a98")
        let codex = Self.descriptor("Codex.app", bundleID: "com.openai.codex", kind: .codexApp)

        Self.assertPlan(target, Self.environment(descriptor: codex), is: JumpProgram(
            steps: [JumpStep(.openURL("codex://threads/019d9a98"))],
            finishesWith: .fixed("Focused the Codex.app conversation.")
        ))
    }

    @Test
    func codexAppWithoutAThreadJustActivates() {
        let target = Self.target(terminalApp: "Codex.app")
        let codex = Self.descriptor("Codex.app", bundleID: "com.openai.codex", kind: .codexApp)

        Self.assertPlan(target, Self.environment(descriptor: codex), is: JumpProgram(
            steps: [JumpStep(.openApp(bundleIdentifier: "com.openai.codex", path: nil))],
            finishesWith: .fixed("Activated Codex.app.")
        ))
    }

    @Test
    func claudeAppAndConductorAreBroughtForward() {
        let claude = Self.target(terminalApp: "Claude.app")
        Self.assertPlan(
            claude,
            Self.environment(descriptor: Self.descriptor(
                "Claude.app",
                bundleID: "com.anthropic.claudefordesktop",
                kind: .claudeApp
            )),
            is: JumpProgram(
                steps: [JumpStep(.openApp(bundleIdentifier: "com.anthropic.claudefordesktop", path: nil))],
                finishesWith: .fixed("Activated Claude.")
            )
        )

        let conductor = Self.target(terminalApp: "Conductor")
        Self.assertPlan(
            conductor,
            Self.environment(descriptor: Self.descriptor(
                "Conductor",
                bundleID: "com.conductor.app",
                kind: .conductorApp
            )),
            is: JumpProgram(
                steps: [JumpStep(.openApp(bundleIdentifier: "com.conductor.app", path: nil))],
                finishesWith: .fixed("Activated Conductor.")
            )
        )
    }

    // MARK: - Zellij

    /// The bug this whole change is named after: which emulator draws a Zellij
    /// session is not implied by which emulator happens to be running, so the
    /// plan activates no emulator at all.
    @Test
    func zellijActivatingItsTabNeverActivatesAHostEmulator() {
        let target = Self.target(terminalApp: "Zellij", terminalSessionID: "3:work")
        let zellij = ZellijProbe.located(
            path: "/opt/homebrew/bin/zellij",
            session: "work",
            tabPosition: 2
        )

        Self.assertPlan(target, Self.environment(descriptor: nil, zellij: zellij), is: JumpProgram(
            steps: [
                JumpStep(
                    .focusZellij(path: "/opt/homebrew/bin/zellij", session: "work", tabPosition: 2),
                    completion: .fixed("Focused the matching Zellij pane.")
                )
            ],
            finishesWith: .fixed("Focused the matching Zellij pane.")
        ))
    }

    /// A Zellij session with no browser tab to select is not silently reported
    /// as a jump into some other terminal: it is blocked.
    @Test
    func zellijWithoutALocatablePaneIsBlocked() {
        let target = Self.target(terminalApp: "Zellij", terminalSessionID: "3:work")
        let blocked = JumpBlockedReason.multiplexerUnavailable("Zellij (could not locate the pane)")

        Self.assertBlocked(
            target,
            Self.environment(descriptor: nil, zellij: .blocked(blocked)),
            is: blocked
        )
    }

    // MARK: - The fallback ladder

    /// A precise locator that found no live terminal: the app is raised, and
    /// the sentence admits the pane was not reached.
    @Test
    func aPreciseLocatorThatMissesRaisesTheRunningApp() {
        let target = Self.target(
            terminalApp: "Ghostty",
            terminalTTY: "/dev/ttys002"
        )
        let ghostty = Self.descriptor("Ghostty", bundleID: "com.mitchellh.ghostty", kind: .ghostty)

        Self.assertPlan(target, Self.environment(descriptor: ghostty), is: JumpProgram(
            steps: [
                JumpStep(
                    .focusGhostty(target),
                    completion: .fixed("Focused the matching Ghostty terminal.")
                ),
                JumpStep(.openApp(bundleIdentifier: "com.mitchellh.ghostty", path: nil))
            ],
            finishesWith: .fixed(
                "Activated Ghostty. Exact pane targeting could not find the live terminal."
            )
        ))
    }

    /// With a directory but no locator, the project is handed to the app —
    /// which is what makes the fallback useful rather than a bare activation.
    @Test
    func aDirectoryButNoLocatorOpensTheProjectInTheApp() {
        let target = Self.target(terminalApp: "Ghostty")
        let ghostty = Self.descriptor("Ghostty", bundleID: "com.mitchellh.ghostty", kind: .ghostty)

        Self.assertPlan(target, Self.environment(descriptor: ghostty), is: JumpProgram(
            steps: [
                JumpStep(
                    .focusGhostty(target),
                    completion: .fixed("Focused the matching Ghostty terminal.")
                ),
                JumpStep(.openApp(bundleIdentifier: "com.mitchellh.ghostty", path: "/Users/u/repo"))
            ],
            finishesWith: .fixed(
                "Opened repo in Ghostty. Exact pane targeting is still best-effort."
            )
        ))
    }

    /// Neither locator nor directory, and the app is not running: activating it
    /// is all that is left.
    @Test
    func noLocatorAndNoDirectoryStillActivatesTheApp() {
        let target = Self.target(terminalApp: "Ghostty", workingDirectory: nil)
        let ghostty = Self.descriptor("Ghostty", bundleID: "com.mitchellh.ghostty", kind: .ghostty)

        Self.assertPlan(
            target,
            Self.environment(descriptor: ghostty, appIsRunning: false),
            is: JumpProgram(
                steps: [
                    JumpStep(
                        .focusGhostty(target),
                        completion: .fixed("Focused the matching Ghostty terminal.")
                    ),
                    JumpStep(.openApp(bundleIdentifier: "com.mitchellh.ghostty", path: nil))
                ],
                finishesWith: .fixed("Activated Ghostty. Exact pane targeting is still best-effort.")
            )
        )
    }

    /// No descriptor and a directory: Finder. The step is the point — a
    /// sentence claiming a Finder window without opening one would read as a
    /// jump that happened.
    @Test
    func anUnresolvableTerminalRevealsTheDirectoryInFinder() {
        let target = Self.target(terminalApp: "JetBrains")

        Self.assertPlan(target, Self.environment(descriptor: nil), is: JumpProgram(
            steps: [JumpStep(.revealInFinder(path: "/Users/u/repo"))],
            finishesWith: .fixed(
                "Opened repo in Finder because no supported terminal app could be resolved."
            )
        ))
    }

    /// A directory on disk is what a fallback needs; one that is not there is
    /// not a window to open.
    @Test
    func aDirectoryThatDoesNotExistIsNotAWindowToOpen() {
        let target = Self.target(terminalApp: "Unknown")

        Self.assertBlocked(
            target,
            Self.environment(descriptor: nil, workingDirectoryExists: false),
            is: .terminalUnclassified("Unknown")
        )
    }

    // MARK: - Blocked reasons

    /// The probe reports "classified to no known app" for any unmapped name.
    /// The payload is the name, because that is what makes the message
    /// actionable.
    @Test
    func anUnmappedNameWithNothingToOpenIsBlockedWithThatName() {
        let target = Self.target(terminalApp: "Some Future Terminal", workingDirectory: nil)

        let plan = JumpPlanner.plan(target, environment: Self.environment(descriptor: nil))
        #expect(plan == .blocked(.terminalUnclassified("Some Future Terminal")))

        guard case let .blocked(reason) = plan else { return }
        #expect(
            reason.jumpError.errorDescription
                == "Could not resolve a supported terminal app for Some Future Terminal."
        )
    }

    /// The recorded pane is gone, the binary is missing, the session name is
    /// not there — this layer cannot tell them apart, so they are one reason
    /// carrying the sentence the user reads.
    @Test
    func aMultiplexerThatCannotBeLocatedIsBlockedWithTheUserFacingSentence() {
        let target = Self.target(terminalApp: "Zellij", terminalSessionID: "3:work")

        let plan = JumpPlanner.plan(
            target,
            environment: Self.environment(
                descriptor: nil,
                zellij: .blocked(.multiplexerUnavailable("Zellij (could not locate the pane)"))
            )
        )
        #expect(plan == .blocked(.multiplexerUnavailable("Zellij (could not locate the pane)")))

        guard case let .blocked(reason) = plan else { return }
        #expect(
            reason.jumpError.errorDescription
                == "Could not resolve a supported terminal app for Zellij (could not locate the pane)."
        )
    }

    /// Both reasons must throw, not return a sentence that reads like a jump.
    @Test
    func everyBlockedReasonThrowsItsDocumentedError() {
        #expect(
            JumpBlockedReason.terminalUnclassified("Unknown").jumpError.errorDescription
                == "Could not resolve a supported terminal app for Unknown."
        )
        #expect(
            JumpBlockedReason.multiplexerUnavailable("Zellij (could not locate the pane)")
                .jumpError.errorDescription
                == "Could not resolve a supported terminal app for Zellij (could not locate the pane)."
        )
    }

    // MARK: - Precise locator classification

    /// A locator is a session id or a TTY; whitespace is not one, and neither
    /// is an empty string. Uses the real field names so a rename breaks here.
    @Test
    func onlyANonEmptyLocatorCountsAsPrecise() {
        #expect(JumpPlanner.hasPreciseLocator(Self.target(terminalApp: "Ghostty", terminalTTY: "/dev/ttys002")))
        #expect(JumpPlanner.hasPreciseLocator(Self.target(terminalApp: "Ghostty", terminalSessionID: "ABC")))
        #expect(!JumpPlanner.hasPreciseLocator(Self.target(terminalApp: "Ghostty", terminalTTY: "   ")))
        #expect(!JumpPlanner.hasPreciseLocator(Self.target(terminalApp: "Ghostty", terminalSessionID: "")))
        #expect(!JumpPlanner.hasPreciseLocator(Self.target(terminalApp: "Ghostty")))
    }

    /// An empty `tmuxTarget` is not a tmux jump, so the plan is the ordinary
    /// one rather than a pane step aimed at nothing.
    @Test
    func anEmptyTmuxTargetIsNotATmuxJump() {
        let target = Self.target(terminalApp: "Ghostty", tmuxTarget: "")
        let ghostty = Self.descriptor("Ghostty", bundleID: "com.mitchellh.ghostty", kind: .ghostty)

        Self.assertPlan(target, Self.environment(descriptor: ghostty), is: JumpProgram(
            steps: [
                JumpStep(
                    .focusGhostty(target),
                    completion: .fixed("Focused the matching Ghostty terminal.")
                ),
                JumpStep(.openApp(bundleIdentifier: "com.mitchellh.ghostty", path: "/Users/u/repo"))
            ],
            finishesWith: .fixed(
                "Opened repo in Ghostty. Exact pane targeting is still best-effort."
            )
        ))
    }
}

// MARK: - Executor

/// The sequencing rules, which are properties of the executor and not of any
/// terminal: an optional failure carries on, an action that reports the jump is
/// over ends it, a thrown error aborts, and a pane-dependent sentence is
/// resolved from whether the pane step actually landed.
@Suite
struct JumpExecutorTests {
    private static let target = JumpTarget(
        terminalApp: "Ghostty",
        workspaceName: "repo",
        paneTitle: "agent",
        workingDirectory: "/Users/u/repo"
    )

    private static func program(
        steps: [JumpStep],
        finishesWith: JumpCompletion
    ) -> JumpProgram {
        JumpProgram(steps: steps, finishesWith: finishesWith)
    }

    /// A step with no completion does not end the jump; the plan keeps going.
    @Test
    func anOptionalStepThatSucceedsContinuesToTheNextStep() throws {
        let program = Self.program(
            steps: [
                JumpStep(.tmuxSelectPane(Self.target), completion: .fixed("focused the pane")),
                JumpStep(.focusGhostty(Self.target)),
                JumpStep(.openApp(bundleIdentifier: "app", path: nil))
            ],
            finishesWith: .fixed("fell through")
        )

        var performed: [JumpAction] = []
        let message = try JumpExecutor.execute(program) { action in
            performed.append(action)
            return .keepGoing
        }

        // The pane step's completion ended the jump, so the two after it never ran.
        #expect(message == "focused the pane")
        #expect(performed == [.tmuxSelectPane(Self.target)])
    }

    /// A failed optional step is skipped and the plan carries on — the shape of
    /// "Ghostty could not find the window, so activate the app".
    @Test
    func aFailedStepIsSkippedAndThePlanCarriesOn() throws {
        let program = Self.program(
            steps: [
                JumpStep(.focusGhostty(Self.target)),
                JumpStep(.openApp(bundleIdentifier: "com.mitchellh.ghostty", path: nil))
            ],
            finishesWith: .fixed("activated the app")
        )

        var performed: [JumpAction] = []
        let message = try JumpExecutor.execute(program) { action in
            performed.append(action)
            return .failed
        }

        #expect(performed.count == 2)
        #expect(message == "activated the app")
    }

    /// An action that knows the jump is over supplies its own sentence — this is
    /// Warp reporting "activated but could not confirm".
    @Test
    func anActionCanEndTheJumpInItsOwnWords() throws {
        let program = Self.program(
            steps: [
                JumpStep(.focusWarp(Self.target)),
                JumpStep(.openApp(bundleIdentifier: "app", path: nil))
            ],
            finishesWith: .fixed("never reached")
        )

        var performed: [JumpAction] = []
        let message = try JumpExecutor.execute(program) { action in
            performed.append(action)
            return .completed("activated Warp but could not confirm precision focus")
        }

        #expect(performed == [.focusWarp(Self.target)])
        #expect(message == "activated Warp but could not confirm precision focus")
    }

    /// A thrown error aborts the remaining steps: `open` failing is fatal, and
    /// the steps after it must not run against a session nobody moved to.
    @Test
    func aThrownErrorAbortsTheRemainingSteps() {
        let program = Self.program(
            steps: [
                JumpStep(.focusGhostty(Self.target)),
                JumpStep(.openApp(bundleIdentifier: "app", path: nil)),
                JumpStep(.revealInFinder(path: "/Users/u/repo"))
            ],
            finishesWith: .fixed("never reached")
        )

        var performed: [JumpAction] = []
        #expect(throws: TerminalJumpError.self) {
            try JumpExecutor.execute(program) { action in
                performed.append(action)
                if case .openApp = action {
                    throw TerminalJumpError.openFailed(["-b", "app"])
                }
                return .failed
            }
        }

        #expect(performed.count == 2)
    }

    /// The pane-dependent wording is resolved from what actually happened, not
    /// assumed: the same plan has to be able to say either sentence.
    @Test
    func aPaneDependentSentenceFollowsWhetherThePaneStepLanded() throws {
        let program = Self.program(
            steps: [
                JumpStep(.tmuxSelectPane(Self.target)),
                JumpStep(.openApp(bundleIdentifier: "app", path: nil))
            ],
            finishesWith: .paneDependent(selected: "pane and app", notSelected: "app, no pane")
        )

        let selected = try JumpExecutor.execute(program) { _ in .keepGoing }
        #expect(selected == "pane and app")

        // The pane step runs but does not land; the app step still does.
        let notSelected = try JumpExecutor.execute(program) { action in
            if case .tmuxSelectPane = action { return .failed }
            return .keepGoing
        }
        #expect(notSelected == "app, no pane")
    }

    /// A plan with no pane step at all must not claim a pane was selected.
    @Test
    func aPlanWithoutAPaneStepNeverClaimsThePaneLanded() throws {
        let program = Self.program(
            steps: [JumpStep(.openApp(bundleIdentifier: "app", path: nil))],
            finishesWith: .paneDependent(selected: "pane and app", notSelected: "app, no pane")
        )

        let message = try JumpExecutor.execute(program) { _ in .keepGoing }
        #expect(message == "app, no pane")
    }
}
