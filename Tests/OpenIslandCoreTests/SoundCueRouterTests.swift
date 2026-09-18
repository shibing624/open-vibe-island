import Foundation
import Testing
@testable import OpenIslandCore

/// Coverage for which agent events ring, and which deliberately do not.
struct SoundCueRouterTests {

    private func started(
        _ sessionID: String,
        source: ClaudeSessionStartSource? = nil
    ) -> AgentEvent {
        .sessionStarted(
            SessionStarted(
                sessionID: sessionID,
                title: "Claude · island",
                tool: .claudeCode,
                summary: "Session started.",
                timestamp: Date(timeIntervalSince1970: 1_000),
                claudeMetadata: source.map { ClaudeSessionMetadata(startupSource: $0) }
            )
        )
    }

    private func running(_ sessionID: String, summary: String = "Prompt: ship it") -> AgentEvent {
        .activityUpdated(
            SessionActivityUpdated(
                sessionID: sessionID,
                summary: summary,
                phase: .running,
                timestamp: Date(timeIntervalSince1970: 1_001)
            )
        )
    }

    private func completed(
        _ sessionID: String,
        isInterrupt: Bool? = nil,
        isFailure: Bool? = nil
    ) -> AgentEvent {
        .sessionCompleted(
            SessionCompleted(
                sessionID: sessionID,
                summary: "Turn over.",
                timestamp: Date(timeIntervalSince1970: 1_002),
                isInterrupt: isInterrupt,
                isFailure: isFailure
            )
        )
    }

    /// Registering a session is silent: the user is looking at the terminal they
    /// just typed in. The first prompt is what marks work as started.
    @Test
    func firstPromptRingsOncePerSession() {
        var router = SoundCueRouter()

        #expect(router.cue(for: started("s1")) == nil)
        #expect(router.cue(for: running("s1")) == .taskAcknowledge)
        #expect(router.cue(for: running("s1", summary: "Bash: ls")) == nil)
        #expect(router.cue(for: completed("s1")) == .taskComplete)
        // A later turn in the same session stays silent — it is the same piece
        // of work, and ringing per turn dilutes into noise.
        #expect(router.cue(for: running("s1", summary: "Prompt: also fix tests")) == nil)
    }

    @Test
    func sessionsAreTrackedIndependently() {
        var router = SoundCueRouter()

        #expect(router.cue(for: running("s1")) == .taskAcknowledge)
        #expect(router.cue(for: running("s2")) == .taskAcknowledge)
        #expect(router.cue(for: running("s1")) == nil)
    }

    /// `startup` is the only registration that means "a new conversation", so it
    /// is the only one that re-arms the first prompt.
    @Test
    func startupRegistrationRingsItsFirstPromptAgain() {
        var router = SoundCueRouter()

        #expect(router.cue(for: running("s1")) == .taskAcknowledge)
        #expect(router.cue(for: started("s1", source: .startup)) == nil)
        #expect(router.cue(for: running("s1")) == .taskAcknowledge)
    }

    /// Claude Code re-announces the *same* session as `resume`, `clear` or
    /// `compact` — after an automatic context compaction, most often. Those are
    /// continuations of work the user already acknowledged, so the next prompt
    /// must stay silent instead of ringing "task started" a second time.
    @Test
    func continuationRegistrationsDoNotRearmTheFirstPrompt() {
        for source in [ClaudeSessionStartSource.resume, .clear, .compact] {
            var router = SoundCueRouter()

            #expect(router.cue(for: running("s1")) == .taskAcknowledge)
            #expect(router.cue(for: started("s1", source: source)) == nil)
            #expect(router.cue(for: running("s1")) == nil)
        }
    }

    @Test
    func waitingOnUserRingsInputRequired() {
        var router = SoundCueRouter()

        let permission = AgentEvent.permissionRequested(
            PermissionRequested(
                sessionID: "s1",
                request: PermissionRequest(
                    title: "Run command",
                    summary: "rm -rf build",
                    affectedPath: "/tmp/build"
                ),
                timestamp: Date(timeIntervalSince1970: 1_003)
            )
        )
        let question = AgentEvent.questionAsked(
            QuestionAsked(
                sessionID: "s2",
                prompt: QuestionPrompt(title: "Which framework?", options: ["React", "Vue"]),
                timestamp: Date(timeIntervalSince1970: 1_004)
            )
        )

        #expect(router.cue(for: permission) == .inputRequired)
        #expect(router.cue(for: question) == .inputRequired)
        // Being blocked on the user already counted as the session's first cue.
        #expect(router.cue(for: running("s1")) == nil)
    }

    @Test
    func failedTurnRingsErrorAndInterruptStaysSilent() {
        var router = SoundCueRouter()

        #expect(router.cue(for: completed("s1", isFailure: true)) == .taskError)
        // The user pressed the interrupt key — they know.
        #expect(router.cue(for: completed("s2", isInterrupt: true)) == nil)
    }

    /// Tool churn inside a turn is a scrolling log, not a notification.
    @Test
    func nonRunningActivityAndMetadataStaySilent() {
        var router = SoundCueRouter()

        let idle = AgentEvent.activityUpdated(
            SessionActivityUpdated(
                sessionID: "s1",
                summary: "Waiting.",
                phase: .completed,
                timestamp: Date(timeIntervalSince1970: 1_005)
            )
        )
        let jump = AgentEvent.jumpTargetUpdated(
            JumpTargetUpdated(
                sessionID: "s1",
                jumpTarget: JumpTarget(
                    terminalApp: "Ghostty",
                    workspaceName: "island",
                    paneTitle: "claude"
                ),
                timestamp: Date(timeIntervalSince1970: 1_006)
            )
        )

        #expect(router.cue(for: idle) == nil)
        #expect(router.cue(for: jump) == nil)
    }
}
