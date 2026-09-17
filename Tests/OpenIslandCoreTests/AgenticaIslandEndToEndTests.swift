import Foundation
import Testing
@testable import OpenIslandCore

/// One end-to-end pass over the three changes, asserting the behaviour the
/// user actually reported as broken rather than the units in isolation.
///
/// Feeds a real agentica event sequence through the same BridgeServer-side
/// merge the live path uses, and checks what the island would render at each
/// step plus whether a click could find the pane.
struct AgenticaIslandEndToEndTests {
    private func payload(
        _ event: AgenticaHookEventName,
        toolName: String? = nil,
        preview: String? = nil,
        prompt: String? = nil,
        answer: String? = nil
    ) -> AgenticaHookPayload {
        AgenticaHookPayload(
            hookEventName: event,
            sessionID: "s1",
            cwd: "/tmp/demo",
            prompt: prompt,
            answer: answer,
            toolName: toolName,
            preview: preview
        ).withRuntimeContext(
            environment: [
                "TMUX": "/private/tmp/tmux-501/default,12345,0",
                "TMUX_PANE": "%3",
                "TERM_PROGRAM": "ghostty"
            ],
            currentTTYProvider: { "/dev/ttys004" },
            terminalLocatorProvider: { _ in (nil, nil, nil) },
            // Stubbed so the suite never shells out to a real tmux server.
            tmuxTargetResolver: { _, _ in "demo:2.1" }
        )
    }

    /// Replays run.started -> tool.started -> tool.completed -> run.completed
    /// the way the bridge does, and pins the rendered state after each one.
    @Test
    func turnReportsContentAtEveryStepAndStaysJumpable() {
        var metadata: AgenticaSessionMetadata?

        func apply(_ payload: AgenticaHookPayload) {
            metadata = AgenticaSessionMetadata.merged(
                existing: metadata,
                update: payload.defaultAgenticaMetadata,
                clearsCurrentTool: payload.clearsCurrentTool
            )
        }

        // 1. Turn starts: the prompt is the anchor.
        apply(payload(.runStarted, prompt: "fix the parser"))
        #expect(metadata?.initialUserPrompt == "fix the parser")

        // 2. A tool runs: this is the information that previously could not
        //    leave BridgeServer at all.
        apply(payload(.toolStarted, toolName: "read_file", preview: "parser.swift"))
        #expect(metadata?.currentTool == "read_file")
        #expect(metadata?.currentToolInputPreview == "parser.swift")

        // 3. Tool finishes mid-turn: no tool is live, prompt survives.
        apply(payload(.toolCompleted, toolName: "read_file"))
        #expect(metadata?.currentTool == nil)
        #expect(metadata?.initialUserPrompt == "fix the parser")

        // 4. Turn completes: real answer text, and nothing claims to be running.
        apply(payload(.runCompleted, answer: "Parser fixed; two tests added."))
        #expect(metadata?.lastAssistantMessage == "Parser fixed; two tests added.")
        #expect(metadata?.currentTool == nil)

        // The jump target carries the pane throughout, which is what makes
        // TerminalJumpService take its precise branch instead of activating
        // the app.
        // Stored in `session:window.pane` form, which is what
        // TerminalJumpService splits and the resolver compares against.
        let target = payload(.runCompleted, answer: "done").defaultJumpTarget
        #expect(target.tmuxTarget == "demo:2.1")
        #expect(target.tmuxSocketPath == "/private/tmp/tmux-501/default")
    }

    /// A failing tool must not leave the row asserting that tool is still live.
    @Test
    func failedToolClearsActivity() {
        let started = AgenticaSessionMetadata.merged(
            existing: nil,
            update: payload(.toolStarted, toolName: "execute", preview: "swift build")
                .defaultAgenticaMetadata
        )
        #expect(started.currentTool == "execute")

        var failure = payload(.toolCompleted, toolName: "execute")
        failure.ok = false
        let after = AgenticaSessionMetadata.merged(
            existing: started,
            update: failure.defaultAgenticaMetadata,
            clearsCurrentTool: failure.clearsCurrentTool
        )

        #expect(after.currentTool == nil)
    }

    /// A cancelled run is terminal too, so it must not keep a tool pinned.
    @Test
    func cancelledRunClearsActivity() {
        let started = AgenticaSessionMetadata.merged(
            existing: nil,
            update: payload(.toolStarted, toolName: "execute").defaultAgenticaMetadata
        )

        let cancelled = payload(.runCancelled)
        #expect(cancelled.clearsCurrentTool)

        let after = AgenticaSessionMetadata.merged(
            existing: started,
            update: cancelled.defaultAgenticaMetadata,
            clearsCurrentTool: cancelled.clearsCurrentTool
        )

        #expect(after.currentTool == nil)
    }
}
