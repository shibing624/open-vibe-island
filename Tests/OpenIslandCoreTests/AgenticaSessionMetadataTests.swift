import Foundation
import Testing
@testable import OpenIslandCore

/// Pins the agentica metadata path end to end: hook payload → merged
/// `AgenticaSessionMetadata` → the accessors the island actually renders.
///
/// The regression these guard is specific. agentica's wire has carried
/// `tool.started` / `tool.completed` with a tool name and a sanitized preview
/// all along, and `BridgeServer` handled both events — but the only place the
/// facts could land was `SessionActivityUpdated.summary`, a rendered sentence.
/// `AgentSession.currentToolName` reads from per-agent metadata, and there was
/// no agentica carrier, so it was permanently nil and every agentica row
/// degraded to a bare status word no matter what the hook reported.
///
/// So these tests assert on `currentToolName` / `lastAssistantMessageText` —
/// the values the UI reads — rather than on "an event was emitted".
struct AgenticaSessionMetadataTests {
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
            prompt: prompt,
            answer: answer,
            toolName: toolName,
            preview: preview
        )
    }

    @Test
    func toolStartedCarriesToolNameAndPreview() {
        let update = payload(.toolStarted, toolName: "read_file", preview: "a.py").defaultAgenticaMetadata

        #expect(update.currentTool == "read_file")
        #expect(update.currentToolInputPreview == "a.py")
    }

    /// The whole point of the carrier: a session fed a real `tool.started`
    /// reports that tool by name to the presentation layer.
    @Test
    func sessionExposesCurrentToolAfterToolStarted() {
        let metadata = AgenticaSessionMetadata.merged(
            existing: nil,
            update: payload(.toolStarted, toolName: "read_file", preview: "a.py").defaultAgenticaMetadata,
            clearsCurrentTool: false
        )

        let session = AgentSession(
            id: "agentica-s1",
            title: "Agentica · demo",
            tool: .agenticaCLI,
            phase: .running,
            summary: "read_file a.py",
            updatedAt: .now,
            agenticaMetadata: metadata
        )

        #expect(session.currentToolName == "read_file")
        #expect(session.currentCommandPreviewText == "a.py")
    }

    /// A finished tool is not a running tool, but it must not take the prompt
    /// with it: `tool.completed` carries no text of its own, so a whole-value
    /// overwrite here would blank the run's anchor prompt.
    @Test
    func toolCompletedClearsToolButKeepsPrompt() {
        let started = AgenticaSessionMetadata.merged(
            existing: nil,
            update: payload(.runStarted, prompt: "fix the parser").defaultAgenticaMetadata
        )
        let running = AgenticaSessionMetadata.merged(
            existing: started,
            update: payload(.toolStarted, toolName: "read_file", preview: "a.py").defaultAgenticaMetadata
        )
        #expect(running.currentTool == "read_file")

        let completedPayload = payload(.toolCompleted, toolName: "read_file")
        #expect(completedPayload.clearsCurrentTool)

        let completed = AgenticaSessionMetadata.merged(
            existing: running,
            update: completedPayload.defaultAgenticaMetadata,
            clearsCurrentTool: completedPayload.clearsCurrentTool
        )

        #expect(completed.currentTool == nil)
        #expect(completed.currentToolInputPreview == nil)
        #expect(completed.lastUserPrompt == "fix the parser")
        #expect(completed.initialUserPrompt == "fix the parser")
    }

    /// `run.completed` is what replaces the "Ready" fallback with real content.
    @Test
    func runCompletedSuppliesAssistantMessageAndEndsToolActivity() {
        let running = AgenticaSessionMetadata.merged(
            existing: AgenticaSessionMetadata.merged(
                existing: nil,
                update: payload(.runStarted, prompt: "fix the parser").defaultAgenticaMetadata
            ),
            update: payload(.toolStarted, toolName: "apply_patch").defaultAgenticaMetadata
        )

        let donePayload = payload(.runCompleted, answer: "Parser fixed; two tests added.")
        #expect(donePayload.clearsCurrentTool)

        let done = AgenticaSessionMetadata.merged(
            existing: running,
            update: donePayload.defaultAgenticaMetadata,
            clearsCurrentTool: donePayload.clearsCurrentTool
        )

        let session = AgentSession(
            id: "agentica-s1",
            title: "Agentica · demo",
            tool: .agenticaCLI,
            phase: .completed,
            summary: "Parser fixed; two tests added.",
            updatedAt: .now,
            agenticaMetadata: done
        )

        #expect(session.lastAssistantMessageText == "Parser fixed; two tests added.")
        // A completed row must not still claim a tool is live.
        #expect(session.currentToolName == nil)
    }

    /// `initialUserPrompt` is an anchor: a second turn updates `lastUserPrompt`
    /// and leaves the first one alone.
    @Test
    func initialPromptIsAnchoredAcrossTurns() {
        let first = AgenticaSessionMetadata.merged(
            existing: nil,
            update: payload(.runStarted, prompt: "first thing").defaultAgenticaMetadata
        )
        let second = AgenticaSessionMetadata.merged(
            existing: first,
            update: payload(.runStarted, prompt: "second thing").defaultAgenticaMetadata
        )

        #expect(second.initialUserPrompt == "first thing")
        #expect(second.lastUserPrompt == "second thing")
    }

    /// `SessionState` is where the event becomes visible state, and it drops
    /// empty metadata rather than storing a hollow object.
    @Test
    func sessionStateAppliesMetadataEvent() {
        var state = SessionState()
        state.apply(
            .sessionStarted(
                SessionStarted(
                    sessionID: "agentica-s1",
                    title: "Agentica · demo",
                    tool: .agenticaCLI,
                    summary: "started",
                    timestamp: .now
                )
            )
        )
        #expect(state.session(id: "agentica-s1")?.currentToolName == nil)

        state.apply(
            .agenticaSessionMetadataUpdated(
                AgenticaSessionMetadataUpdated(
                    sessionID: "agentica-s1",
                    agenticaMetadata: AgenticaSessionMetadata(
                        currentTool: "execute",
                        currentToolInputPreview: "swift build"
                    ),
                    timestamp: .now
                )
            )
        )

        #expect(state.session(id: "agentica-s1")?.currentToolName == "execute")
        #expect(state.session(id: "agentica-s1")?.currentCommandPreviewText == "swift build")
    }

    @Test
    func emptyMetadataIsNotStored() {
        var state = SessionState()
        state.apply(
            .sessionStarted(
                SessionStarted(
                    sessionID: "agentica-s1",
                    title: "Agentica · demo",
                    tool: .agenticaCLI,
                    summary: "started",
                    timestamp: .now
                )
            )
        )
        state.apply(
            .agenticaSessionMetadataUpdated(
                AgenticaSessionMetadataUpdated(
                    sessionID: "agentica-s1",
                    agenticaMetadata: AgenticaSessionMetadata(),
                    timestamp: .now
                )
            )
        )

        #expect(state.session(id: "agentica-s1")?.agenticaMetadata == nil)
    }

    /// The event round-trips through the hand-written `AgentEvent` Codable.
    @Test
    func metadataEventRoundTripsThroughCodable() throws {
        let event = AgentEvent.agenticaSessionMetadataUpdated(
            AgenticaSessionMetadataUpdated(
                sessionID: "agentica-s1",
                agenticaMetadata: AgenticaSessionMetadata(
                    initialUserPrompt: "fix the parser",
                    currentTool: "read_file"
                ),
                timestamp: Date(timeIntervalSince1970: 1_700_000_000)
            )
        )

        let data = try JSONEncoder().encode(event)
        let decoded = try JSONDecoder().decode(AgentEvent.self, from: data)

        #expect(decoded == event)
    }
}
