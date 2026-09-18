import Foundation
import OpenIslandCore

/// One primitive action a jump is built from.
///
/// The planner chooses which of these run, in what order, and what the user is
/// told; the executor only performs them. Keeping "which terminal lives where"
/// out of the executor is the point: `JumpPlanner.plan` is a pure function of
/// `JumpTarget` + `JumpEnvironment`, so a jump *strategy* can be asserted
/// without a live terminal, which is what made the earlier mis-targeting
/// (a Zellij session in Ghostty raising iTerm) only reproducible by hand.
enum JumpAction: Equatable {
    /// The whole tmux pane sequence: `switch-client` (only when the chosen
    /// client is attached to a different session), `select-window`, then
    /// `select-pane`.
    ///
    /// The three commands stay one action deliberately. Their internal rule —
    /// a failed `switch-client` aborts the other two, because they would
    /// otherwise rearrange a session nobody is looking at — is one atomic
    /// operation with its own tests; splitting it here would relocate that rule
    /// into the step list without changing a single byte of what runs.
    case tmuxSelectPane(JumpTarget)
    case focusGhostty(JumpTarget)
    case focusITerm(JumpTarget)
    case focusTerminalTab(JumpTarget)
    case focusCmux(JumpTarget)
    case focusZellij(path: String, session: String?, tabPosition: Int)
    /// Warp picks between three outcomes (already on the pane, cycled to it, or
    /// capped out without finding it), so it reports its own sentence rather
    /// than taking one from the step.
    case focusWarp(JumpTarget)
    case focusWeztermFamily(cliPath: String, bundleIdentifier: String, target: JumpTarget)
    case openWorkspace(cli: String, arguments: [String])
    case openApp(bundleIdentifier: String, path: String?)
    case openURL(String)
    case revealInFinder(path: String)
}

/// What the user is told when the jump ends here.
enum JumpCompletion: Equatable {
    /// This exact sentence.
    case fixed(String)
    /// Depends on whether the tmux pane step landed. Both sentences claim a
    /// different half of the jump, and only one of them is true.
    case paneDependent(selected: String, notSelected: String)
}

/// A step, plus the sentence that ends the jump if this step succeeds.
///
/// `completion == nil` means success is not an ending: the plan keeps running.
/// That is the whole of "best effort" — a Ghostty focus that finds no matching
/// window carries on to the generic ladder below it.
struct JumpStep: Equatable {
    var action: JumpAction
    var completion: JumpCompletion?

    init(_ action: JumpAction, completion: JumpCompletion? = nil) {
        self.action = action
        self.completion = completion
    }
}

/// The sequence a jump runs, and what it says when nothing ended it early.
struct JumpProgram: Equatable {
    var steps: [JumpStep]
    /// Used when every step ran without an earlier one ending the jump. Always
    /// defined, so `JumpExecutor.execute` cannot fall off the end with nothing
    /// to report.
    var finishesWith: JumpCompletion
}

/// What performing one action achieved.
enum JumpStepOutcome: Equatable {
    /// The action did its job and the plan continues.
    case keepGoing
    /// The action did its job and decided the jump is over, in its own words.
    case completed(String)
    /// The action did not achieve its purpose. Not an error: the plan carries
    /// on to whatever it listed next.
    case failed
}

/// Why a jump cannot run at all.
///
/// Only the reasons this codebase can actually produce are listed — the same
/// rule the step list follows. There is no "no local handle" case because
/// nothing here models an SSH origin, and a reason no code path returns would
/// be a placeholder that reads like a guarantee. A "the pane is gone" case is
/// also absent because this layer cannot tell that apart from a missing
/// binary: both arrive as "the multiplexer jump could not be built".
enum JumpBlockedReason: Equatable {
    /// The hook named a terminal that maps to no known app, and there is no
    /// working directory to fall back to, so there is nowhere to land.
    case terminalUnclassified(String)
    /// A multiplexer jump could not be built — the binary is missing, the
    /// pane is gone, or the session is not there. The payload is the sentence
    /// the user sees, which is the one the Zellij path has always reported.
    case multiplexerUnavailable(String)

    /// The error `jump(to:)` throws for this reason.
    var jumpError: TerminalJumpError {
        switch self {
        case let .terminalUnclassified(terminal):
            return .unsupportedTerminal(terminal)
        case let .multiplexerUnavailable(message):
            return .unsupportedTerminal(message)
        }
    }
}

/// The plan, or the reason there is not one.
enum JumpPlan: Equatable {
    case steps(JumpProgram)
    case blocked(JumpBlockedReason)
}

// MARK: - Environment facts

/// How a session's terminal behaves, which is what the plan branches on.
/// Classified once, in the probe, so the planner never re-derives it from a
/// string.
enum JumpTerminalKind: Equatable {
    case ghostty
    case iterm
    case terminalApp
    case cmux
    case warp
    /// Kaku or WezTerm: same CLI, same matching rules.
    case weztermFamily
    /// VS Code and its forks, which open a workspace through a CLI.
    case vscodeFamily
    case jetbrains
    case codexApp
    case claudeApp
    case conductorApp
    /// A known app with no jump of its own: it gets the generic ladder.
    case other
}

struct JumpDescriptor: Equatable {
    var displayName: String
    /// The identifier after alias preference and alternate-bundle resolution.
    /// This is the one every step is addressed to.
    var resolvedBundleIdentifier: String
    /// The descriptor's own identifier, before resolution.
    ///
    /// Kept separate because the tmux layer's app activation has always used
    /// this one rather than the resolved id. For the four kinds that layer
    /// switches on the two are identical, so this is only observable for a
    /// target that is both inside tmux and a fork with alternates (Trae CN,
    /// Qoder). Preserved rather than corrected: this change is a refactor.
    var declaredBundleIdentifier: String
    var kind: JumpTerminalKind
}

/// What the Zellij probe found.
enum ZellijProbe: Equatable {
    case notZellij
    case located(path: String, session: String?, tabPosition: Int)
    case blocked(JumpBlockedReason)
}

/// Everything the plan branches on, probed before planning.
///
/// All of it costs a subprocess or a file-system call, which is why it is
/// gathered once by the caller and handed over as data: the planner itself runs
/// nothing.
struct JumpEnvironment: Equatable {
    /// nil when the target's terminal name maps to no known app.
    var descriptor: JumpDescriptor?
    var appIsRunning: Bool
    var workingDirectoryExists: Bool
    /// The WezTerm/Kaku CLI on disk, for a target that is one of those.
    var weztermCLIPath: String?
    var zellij: ZellijProbe
}

// MARK: - Planner

enum JumpPlanner {
    /// Chooses the steps for `target`, from facts already probed.
    ///
    /// Pure: no file system, no subprocess, no injected runner. The order of
    /// the two layers is the order the old single function ran them in — the
    /// tmux prefix first, because selecting the pane is what the terminal then
    /// reveals — and it is load-bearing, so it is asserted in both layers.
    static func plan(_ target: JumpTarget, environment: JumpEnvironment) -> JumpPlan {
        let descriptor = environment.descriptor
        var steps: [JumpStep] = []

        if let tmuxTarget = target.tmuxTarget, !tmuxTarget.isEmpty {
            // With a descriptor, the pane step is a best-effort prefix: the
            // terminal-specific focus below is what brings the tab forward, and
            // it runs whether or not the pane selection landed. Without one
            // there is nothing else to try, so the pane step succeeding IS the
            // jump, and failing falls through to the generic ladder.
            steps.append(
                JumpStep(
                    .tmuxSelectPane(target),
                    completion: descriptor == nil
                        ? .fixed("Focused the matching tmux pane.")
                        : nil
                )
            )

            if let descriptor {
                // Only the kinds with a window/tab of their own can do better
                // than activating the app; the rest fall straight through to
                // the activation below.
                switch descriptor.kind {
                case .ghostty:
                    steps.append(JumpStep(
                        .focusGhostty(target),
                        completion: .fixed("Focused the matching tmux pane in Ghostty.")
                    ))
                case .iterm:
                    steps.append(JumpStep(
                        .focusITerm(target),
                        completion: .fixed("Focused the matching tmux pane in iTerm.")
                    ))
                case .terminalApp:
                    steps.append(JumpStep(
                        .focusTerminalTab(target),
                        completion: .fixed("Focused the matching tmux pane in Terminal.")
                    ))
                case .cmux:
                    // The pane lives inside one cmux tab, so selecting the pane
                    // is invisible until the tab is focused — which is also what
                    // switches workspaces when the tab sits in another one.
                    steps.append(JumpStep(
                        .focusCmux(target),
                        completion: .paneDependent(
                            selected: "Focused the matching tmux pane in cmux.",
                            notSelected: "Focused the matching cmux tab. tmux pane targeting failed."
                        )
                    ))
                case .warp, .weztermFamily, .vscodeFamily, .jetbrains,
                     .codexApp, .claudeApp, .conductorApp, .other:
                    break
                }

                steps.append(JumpStep(.openApp(
                    bundleIdentifier: descriptor.declaredBundleIdentifier,
                    path: nil
                )))

                // Reached only when no terminal-specific step above ended the
                // jump, so both sentences have to admit which half landed.
                return .steps(JumpProgram(
                    steps: steps,
                    finishesWith: .paneDependent(
                        selected: "Focused the matching tmux pane and activated \(descriptor.displayName).",
                        notSelected: "Activated \(descriptor.displayName). tmux pane targeting failed."
                    )
                ))
            }
            // No descriptor: the ladder below carries on from these steps.
        }

        return genericPlan(target, environment: environment, prefixedBy: steps)
    }

    /// The descriptor dispatch and the fallback ladder beneath it.
    ///
    /// Steps that cannot succeed on their own leave `completion` nil and let
    /// this function's tail decide, which is exactly the shape of the code it
    /// replaces: a kind-specific attempt, then four rungs of decreasing
    /// precision.
    private static func genericPlan(
        _ target: JumpTarget,
        environment: JumpEnvironment,
        prefixedBy prefix: [JumpStep]
    ) -> JumpPlan {
        var steps = prefix

        // Zellij is a multiplexer, not a macOS app: it has no descriptor, and
        // which emulator draws it is not implied by which emulator is running.
        if target.terminalApp.lowercased() == "zellij" {
            switch environment.zellij {
            case let .blocked(reason):
                return .blocked(reason)
            case let .located(path, session, tabPosition):
                steps.append(JumpStep(
                    .focusZellij(path: path, session: session, tabPosition: tabPosition),
                    completion: .fixed("Focused the matching Zellij pane.")
                ))
                return .steps(JumpProgram(
                    steps: steps,
                    finishesWith: .fixed("Focused the matching Zellij pane.")
                ))
            case .notZellij:
                // The probe classifies by the same name this branch tests, so
                // reaching here would mean the two disagree.
                return .blocked(.multiplexerUnavailable("Zellij (could not locate the pane)"))
            }
        }

        let descriptor = environment.descriptor

        if let descriptor {
            switch descriptor.kind {
            case .codexApp:
                // A thread id addresses the conversation directly; without one
                // the app is all there is to bring forward.
                if let threadID = target.codexThreadID, !threadID.isEmpty {
                    steps.append(JumpStep(.openURL("codex://threads/\(threadID)")))
                    return .steps(JumpProgram(
                        steps: steps,
                        finishesWith: .fixed("Focused the Codex.app conversation.")
                    ))
                }
                steps.append(JumpStep(.openApp(bundleIdentifier: "com.openai.codex", path: nil)))
                return .steps(JumpProgram(
                    steps: steps,
                    finishesWith: .fixed("Activated Codex.app.")
                ))

            case .claudeApp:
                // The conversation lives inside the app and there is no
                // per-session deep link.
                steps.append(JumpStep(.openApp(
                    bundleIdentifier: "com.anthropic.claudefordesktop",
                    path: nil
                )))
                return .steps(JumpProgram(
                    steps: steps,
                    finishesWith: .fixed("Activated Claude.")
                ))

            case .conductorApp:
                steps.append(JumpStep(.openApp(bundleIdentifier: "com.conductor.app", path: nil)))
                return .steps(JumpProgram(
                    steps: steps,
                    finishesWith: .fixed("Activated Conductor.")
                ))

            case .warp:
                // Warp reports which of its three outcomes happened, so its step
                // supplies the sentence. `finishesWith` is the confirmed-failure
                // wording, used only if that step somehow does not.
                steps.append(JumpStep(.focusWarp(target)))
                return .steps(JumpProgram(
                    steps: steps,
                    finishesWith: .fixed("Activated Warp but could not confirm precision focus.")
                ))

            case .ghostty:
                steps.append(JumpStep(
                    .focusGhostty(target),
                    completion: .fixed("Focused the matching Ghostty terminal.")
                ))
            case .iterm:
                steps.append(JumpStep(
                    .focusITerm(target),
                    completion: .fixed("Focused the matching iTerm session.")
                ))
            case .terminalApp:
                steps.append(JumpStep(
                    .focusTerminalTab(target),
                    completion: .fixed("Focused the matching Terminal tab.")
                ))
            case .cmux:
                steps.append(JumpStep(
                    .focusCmux(target),
                    completion: .fixed("Focused the matching cmux terminal.")
                ))
            case .weztermFamily:
                // No CLI on disk means no way to address a pane, so the step is
                // left out entirely rather than listed to fail.
                if let cliPath = environment.weztermCLIPath {
                    steps.append(JumpStep(
                        .focusWeztermFamily(
                            cliPath: cliPath,
                            bundleIdentifier: descriptor.resolvedBundleIdentifier,
                            target: target
                        ),
                        completion: .fixed("Focused the matching \(descriptor.displayName) pane.")
                    ))
                }
            case .vscodeFamily:
                // `-r` reuses the running window instead of opening a second
                // one. The noun stays "workspace" here and "project" for
                // JetBrains: the two CLIs differ, and so does what the user
                // reads, so they are two cases and not one table-driven case.
                if let workingDirectory = target.workingDirectory,
                   let cli = TerminalJumpService.vscodeFamilyCLI[descriptor.resolvedBundleIdentifier] {
                    steps.append(JumpStep(
                        .openWorkspace(cli: cli, arguments: ["-r", workingDirectory]),
                        completion: .fixed("Focused the matching \(descriptor.displayName) workspace.")
                    ))
                }
                if environment.appIsRunning {
                    steps.append(JumpStep(.openApp(
                        bundleIdentifier: descriptor.resolvedBundleIdentifier,
                        path: nil
                    )))
                    return .steps(JumpProgram(
                        steps: steps,
                        finishesWith: .fixed("Activated \(descriptor.displayName).")
                    ))
                }
            case .jetbrains:
                if let workingDirectory = target.workingDirectory,
                   let cli = TerminalJumpService.jetbrainsCLI[descriptor.resolvedBundleIdentifier] {
                    steps.append(JumpStep(
                        .openWorkspace(cli: cli, arguments: [workingDirectory]),
                        completion: .fixed("Focused the matching \(descriptor.displayName) project.")
                    ))
                }
                if environment.appIsRunning {
                    steps.append(JumpStep(.openApp(
                        bundleIdentifier: descriptor.resolvedBundleIdentifier,
                        path: nil
                    )))
                    return .steps(JumpProgram(
                        steps: steps,
                        finishesWith: .fixed("Activated \(descriptor.displayName).")
                    ))
                }
            case .other:
                // A known app with no jump of its own: the ladder decides.
                break
            }
        }

        // Where the tail lands is a property of the plan, decided here: an
        // unresolvable terminal with nothing to aim at has no plan at all.
        switch tail(target, environment: environment) {
        case let .blocked(reason):
            return .blocked(reason)
        case let .steps(program):
            steps.append(contentsOf: program.steps)
            return .steps(JumpProgram(steps: steps, finishesWith: program.finishesWith))
        }
    }

    /// The ladder every unresolvable or unsuccessful path ends on, in
    /// descending order of precision: the running app, the project directory in
    /// the app, the app alone, the directory in Finder.
    ///
    /// Each rung carries both the `open` that performs it and the sentence that
    /// claims it — the sentence without its step would have described a jump
    /// that never ran.
    private static func tail(
        _ target: JumpTarget,
        environment: JumpEnvironment
    ) -> JumpPlan {
        if let descriptor = environment.descriptor,
           hasPreciseLocator(target),
           environment.appIsRunning {
            return .steps(JumpProgram(
                steps: [JumpStep(.openApp(
                    bundleIdentifier: descriptor.resolvedBundleIdentifier,
                    path: nil
                ))],
                finishesWith: .fixed(
                    "Activated \(descriptor.displayName). Exact pane targeting could not find the live terminal."
                )
            ))
        }
        if let descriptor = environment.descriptor,
           let workingDirectory = target.workingDirectory,
           environment.workingDirectoryExists {
            return .steps(JumpProgram(
                steps: [JumpStep(.openApp(
                    bundleIdentifier: descriptor.resolvedBundleIdentifier,
                    path: workingDirectory
                ))],
                finishesWith: .fixed(
                    "Opened \(target.workspaceName) in \(descriptor.displayName). Exact pane targeting is still best-effort."
                )
            ))
        }
        if let descriptor = environment.descriptor {
            return .steps(JumpProgram(
                steps: [JumpStep(.openApp(
                    bundleIdentifier: descriptor.resolvedBundleIdentifier,
                    path: nil
                ))],
                finishesWith: .fixed(
                    "Activated \(descriptor.displayName). Exact pane targeting is still best-effort."
                )
            ))
        }
        if let workingDirectory = target.workingDirectory, environment.workingDirectoryExists {
            return .steps(JumpProgram(
                steps: [JumpStep(.revealInFinder(path: workingDirectory))],
                finishesWith: .fixed(
                    "Opened \(target.workspaceName) in Finder because no supported terminal app could be resolved."
                )
            ))
        }

        // No descriptor and no directory to reveal: there is no window, tab,
        // workspace or folder this jump could land in. Reporting that beats
        // returning a sentence that reads like success.
        return .blocked(.terminalUnclassified(target.terminalApp))
    }

    /// Whether the target carries something that could address a single pane.
    /// Pure, so it lives here rather than in the probe.
    static func hasPreciseLocator(_ target: JumpTarget) -> Bool {
        [target.terminalSessionID, target.terminalTTY].contains { value in
            guard let value else { return false }
            return !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }
}

// MARK: - Executor

/// Runs a plan's steps and reports what the user is told.
///
/// It owns the sequencing rules and nothing else: performing an action is one
/// injected closure, built by `TerminalJumpService`, which owns the terminal
/// machinery. That split is what lets the rules — an optional failure carries
/// on, an action that says the jump is over ends it, a throw aborts — be
/// asserted with a stub instead of a live tmux.
struct JumpExecutor {
    typealias Perform = (JumpAction) throws -> JumpStepOutcome

    /// - Returns: the sentence for the jump, which a plan always defines.
    static func execute(_ program: JumpProgram, perform: Perform) throws -> String {
        // Recorded as the plan runs so a later step's `.paneDependent` wording
        // can tell which half of the jump actually landed. Stays false when the
        // plan has no pane step, which is the truth: no pane was selected.
        var paneStepSucceeded = false

        for step in program.steps {
            switch try perform(step.action) {
            case .keepGoing:
                if case .tmuxSelectPane = step.action {
                    paneStepSucceeded = true
                }
                if let completion = step.completion {
                    return render(completion, paneStepSucceeded: paneStepSucceeded)
                }
            case let .completed(message):
                return message
            case .failed:
                continue
            }
        }

        return render(program.finishesWith, paneStepSucceeded: paneStepSucceeded)
    }

    private static func render(_ completion: JumpCompletion, paneStepSucceeded: Bool) -> String {
        switch completion {
        case let .fixed(message):
            return message
        case let .paneDependent(selected, notSelected):
            return paneStepSucceeded ? selected : notSelected
        }
    }
}
