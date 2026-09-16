import Foundation
import Testing
@testable import OpenIslandCore

struct AgenticaHooksTests {
    // MARK: - Wire format

    @Test
    func decodesNeedsApprovalRequest() throws {
        let json = """
        {
          "hook_event_name": "needs.approval",
          "session_id": "run-42",
          "request_id": "req-1",
          "transport": {"cwd": "/tmp/worktree", "tty": "/dev/ttys004"},
          "cwd": "/tmp/worktree",
          "tool_name": "shell",
          "tool_call_id": "call_7",
          "question": "Run `rm -rf build`?",
          "preview": "rm -rf build",
          "similar_label": "shell commands starting with rm",
          "options": ["allow", "deny", "allow_prefix"]
        }
        """.data(using: .utf8)!

        let payload = try JSONDecoder().decode(AgenticaHookPayload.self, from: json)

        #expect(payload.hookEventName == .needsApproval)
        #expect(payload.hookEventName.expectsReply)
        #expect(payload.resolvedSessionID == "agentica-run-42")
        #expect(payload.requestID == "req-1")
        #expect(payload.approvalTitle == "Run `rm -rf build`?")
        #expect(payload.approvalSummary == "rm -rf build")
        #expect(payload.toolCallID == "call_7")
        #expect(payload.transport?.cwd == "/tmp/worktree")
        #expect(payload.transport?.tty == "/dev/ttys004")
    }

    @Test
    func decodesToolEvents() throws {
        let started = try JSONDecoder().decode(
            AgenticaHookPayload.self,
            from: Data("""
            {"hook_event_name": "tool.started", "session_id": "s1",
             "tool_name": "read_file", "tool_call_id": "c1", "preview": "a.py"}
            """.utf8)
        )

        #expect(started.hookEventName == .toolStarted)
        #expect(!started.hookEventName.expectsReply)
        #expect(started.toolActivity == "read_file a.py")
        #expect(started.implicitSummary == "read_file a.py")

        let failed = try JSONDecoder().decode(
            AgenticaHookPayload.self,
            from: Data("""
            {"hook_event_name": "tool.completed", "session_id": "s1",
             "tool_name": "shell", "tool_call_id": "c2", "ok": false,
             "duration_seconds": 0.5, "error": "exit status 1"}
            """.utf8)
        )

        #expect(failed.ok == false)
        #expect(failed.implicitSummary == "shell failed: exit status 1")
    }

    @Test
    func decodesSessionLifecycle() throws {
        let started = try JSONDecoder().decode(
            AgenticaHookPayload.self,
            from: Data("""
            {"hook_event_name": "session.started", "session_id": "s1", "cwd": "/tmp/worktree",
             "source": "resume", "model": "hy3", "profile": "venus",
             "permission_mode": "ask", "transcript_path": "/tmp/log.jsonl"}
            """.utf8)
        )

        #expect(started.hookEventName == .sessionStarted)
        #expect(started.source == "resume")
        #expect(started.implicitSummary == "Agentica resumed a session in worktree.")

        let ended = try JSONDecoder().decode(
            AgenticaHookPayload.self,
            from: Data(#"{"hook_event_name": "session.ended", "session_id": "s1", "reason": "exit"}"#.utf8)
        )

        #expect(ended.hookEventName == .sessionEnded)
        #expect(ended.implicitSummary == "Agentica session ended: exit")
    }

    @Test
    func decodesRequestResolvedNotice() throws {
        let payload = try JSONDecoder().decode(
            AgenticaHookPayload.self,
            from: Data("""
            {"hook_event_name": "needs.resolved", "session_id": "s1", "request_id": "req-1",
             "event": "needs.approval", "decided_by": "terminal", "decision": "deny"}
            """.utf8)
        )

        #expect(payload.hookEventName == .needsResolved)
        #expect(!payload.hookEventName.expectsReply)
        #expect(payload.requestID == "req-1")
        #expect(payload.decidedBy == .terminal)
        #expect(payload.decision == .deny)
    }

    /// In a goal-driven session agentica defers the per-lap completions and
    /// releases exactly one when the goal finishes, so this is always end-of-turn.
    @Test
    func decodesRunCompletedNotice() throws {
        let payload = try JSONDecoder().decode(
            AgenticaHookPayload.self,
            from: Data("""
            {"hook_event_name": "run.completed", "session_id": "run-42", "cwd": "/tmp/worktree",
             "run_id": "r1", "duration_seconds": 12.5, "answer": "Updated three files."}
            """.utf8)
        )

        #expect(payload.hookEventName == .runCompleted)
        #expect(payload.implicitSummary == "Updated three files.")
        #expect(payload.sessionTitle == "Agentica · worktree")
    }

    /// Fields Open Island does not read must not make decoding fail: agentica is
    /// free to add to this wire.
    @Test
    func ignoresFieldsItDoesNotModel() throws {
        let payload = try JSONDecoder().decode(
            AgenticaHookPayload.self,
            from: Data("""
            {"hook_event_name": "run.completed", "session_id": "s1", "agent_name": "coder",
             "had_response": true, "title": "run completed", "something_new": {"a": 1}}
            """.utf8)
        )

        #expect(payload.hookEventName == .runCompleted)
    }

    /// agentica always sends a session id, falling back to a per-process UUID, so
    /// a payload without one is malformed rather than a case to paper over.
    @Test
    func requiresASessionID() throws {
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(
                AgenticaHookPayload.self,
                from: Data(#"{"hook_event_name": "run.started", "cwd": "/tmp/worktree"}"#.utf8)
            )
        }
    }

    /// The whole point of the id: without the echo, agentica discards the reply
    /// and the user's tap silently does nothing.
    @Test
    func replyDirectivesEchoTheRequestID() throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]

        let allow = try encoder.encode(AgenticaHookDirective.decision(.allow, requestID: "req-1"))
        #expect(
            String(decoding: allow, as: UTF8.self)
                == #"{"decision":"allow","request_id":"req-1"}"#
        )

        let answer = try encoder.encode(AgenticaHookDirective.answer("8080", requestID: "req-2"))
        #expect(
            String(decoding: answer, as: UTF8.self)
                == #"{"answer":"8080","request_id":"req-2"}"#
        )
    }

    /// Printing nothing is how the hook tells agentica "no decision", which
    /// leaves the terminal prompt as the answer path.
    @Test
    func emptyDirectiveProducesNoStandardOutput() throws {
        #expect(AgenticaHookDirective.noDecision.isEmpty)

        let silent = try AgenticaHookOutputEncoder.standardOutput(
            for: .agenticaHookDirective(.noDecision)
        )
        #expect(silent == nil)

        let acknowledged = try AgenticaHookOutputEncoder.standardOutput(for: .acknowledged)
        #expect(acknowledged == nil)

        let denied = try AgenticaHookOutputEncoder.standardOutput(
            for: .agenticaHookDirective(.decision(.deny, requestID: "req-9"))
        )
        let text = String(decoding: try #require(denied), as: UTF8.self)
        #expect(text == "{\"decision\":\"deny\",\"request_id\":\"req-9\"}\n")
    }

    /// agentica reads the TTY off the agent's own stdin, so its answer beats
    /// anything the hook can infer about its parent.
    @Test
    func runtimeContextPrefersTheTransportTTY() throws {
        let payload = AgenticaHookPayload(
            hookEventName: .runStarted,
            sessionID: "s1",
            transport: AgenticaHookTransport(cwd: "/tmp/worktree", tty: "/dev/ttys001"),
            cwd: "/tmp/worktree"
        )
        .withRuntimeContext(
            environment: ["TERM_PROGRAM": "iTerm.app"],
            currentTTYProvider: { "/dev/ttys004" },
            terminalLocatorProvider: { _ in ("w0t1p2", "/dev/ttys009", "worktree") }
        )

        #expect(payload.terminalApp == "iTerm")
        #expect(payload.terminalTTY == "/dev/ttys001")
        #expect(payload.terminalSessionID == "w0t1p2")
        #expect(payload.defaultJumpTarget.workspaceName == "worktree")
    }

    @Test
    func runtimeContextFallsBackToLocalTTYWithoutTransport() throws {
        let payload = AgenticaHookPayload(hookEventName: .runStarted, sessionID: "s1", cwd: "/tmp/worktree")
            .withRuntimeContext(
                environment: ["TERM_PROGRAM": "iTerm.app"],
                currentTTYProvider: { "/dev/ttys004" },
                terminalLocatorProvider: { _ in ("w0t1p2", "/dev/ttys009", "worktree") }
            )

        #expect(payload.terminalTTY == "/dev/ttys004")
    }

    // MARK: - Installer

    private static let command = [
        "/Users/me/Library/Application Support/OpenIsland/bin/OpenIslandHooks",
        "--source",
        "agentica"
    ]

    @Test
    func installsIntoAnAbsentConfig() throws {
        let mutation = try AgenticaHookInstaller.installConfigYAML(
            existingText: nil,
            hookCommand: Self.command
        )

        #expect(mutation.changed)
        #expect(mutation.managedHooksPresent)

        let text = try #require(mutation.contents)
        #expect(text.contains("settings:"))
        #expect(text.contains("    enabled: true"))
        #expect(text.contains("      - name: open-island"))
        #expect(text.contains("          - \"--source\""))
        #expect(AgenticaHookInstaller.hasManagedHooks(in: text))
    }

    /// The file holds every model profile and plaintext key, so an install must
    /// be additive and must not disturb the user's comments.
    @Test
    func installPreservesUnrelatedKeysAndComments() throws {
        let original = """
        # my agentica config
        active_profile: venus

        profiles:
          venus:
            # the good one
            model: hy3
            api_key: sk-secret

        """

        let mutation = try AgenticaHookInstaller.installConfigYAML(
            existingText: original,
            hookCommand: Self.command
        )

        let text = try #require(mutation.contents)
        #expect(text.contains("# my agentica config"))
        #expect(text.contains("# the good one"))
        #expect(text.contains("api_key: sk-secret"))
        #expect(text.contains("active_profile: venus"))
        #expect(AgenticaHookInstaller.hasManagedHooks(in: text))
    }

    @Test
    func installAddsHooksUnderAnExistingSettingsBlock() throws {
        let original = """
        settings:
          # keep this
          cron.enabled: true

        profiles:
          venus:
            model: hy3
        """

        let mutation = try AgenticaHookInstaller.installConfigYAML(
            existingText: original,
            hookCommand: Self.command
        )

        let text = try #require(mutation.contents)
        let lines = text.components(separatedBy: "\n")

        #expect(lines.filter { $0 == "settings:" }.count == 1)
        #expect(text.contains("  cron.enabled: true"))
        #expect(text.contains("  # keep this"))
        #expect(text.contains("  hooks:"))

        // The new block must land inside `settings`, not after `profiles`.
        let hooksIndex = try #require(lines.firstIndex(of: "  hooks:"))
        let profilesIndex = try #require(lines.firstIndex(of: "profiles:"))
        #expect(hooksIndex < profilesIndex)
        #expect(AgenticaHookInstaller.hasManagedHooks(in: text))
    }

    /// The whole reason the wire is a named list: another program's entry is not
    /// ours to read, move or delete.
    @Test
    func installLeavesOtherConsumersAlone() throws {
        let original = """
        settings:
          hooks:
            enabled: true
            consumers:
              # the desk pet
              - name: vpet
                command:
                  - /Users/me/Library/Application Support/VPet/agent-notify/vpet-hook
                events:
                  run.started: false
                  needs.approval: true
        """

        let mutation = try AgenticaHookInstaller.installConfigYAML(
            existingText: original,
            hookCommand: Self.command
        )
        let text = try #require(mutation.contents)

        #expect(text.contains("      # the desk pet"))
        #expect(text.contains("      - name: vpet"))
        #expect(text.contains("vpet-hook"))
        #expect(text.contains("          run.started: false"))
        #expect(text.contains("      - name: open-island"))
        #expect(AgenticaHookInstaller.hasManagedHooks(in: text))
        #expect(AgenticaHookInstaller.otherConsumerNames(in: text) == ["vpet"])
    }

    @Test
    func installReplacesAStaleCommandAndIsIdempotent() throws {
        let original = """
        settings:
          hooks:
            enabled: false
            consumers:
              - name: open-island
                command:
                  - "/old/path/OpenIslandHooks"
                  - "--source"
                  - "agentica"
              - name: vpet
                command:
                  - /usr/local/bin/vpet-hook
        """

        let first = try AgenticaHookInstaller.installConfigYAML(
            existingText: original,
            hookCommand: Self.command
        )
        let text = try #require(first.contents)

        #expect(first.changed)
        #expect(!text.contains("/old/path/OpenIslandHooks"))
        #expect(text.contains("vpet-hook"))
        // The master switch is ours to turn on: a disabled wire delivers nothing.
        #expect(text.contains("    enabled: true"))
        #expect(AgenticaHookInstaller.hasManagedHooks(in: text))

        let second = try AgenticaHookInstaller.installConfigYAML(
            existingText: text,
            hookCommand: Self.command
        )
        #expect(!second.changed)
        #expect(second.contents == text)
    }

    /// Reinstalling must not throw away tuning the user applied to *our* entry.
    @Test
    func reinstallPreservesUserAuthoredKeysInOurOwnEntry() throws {
        let original = """
        settings:
          hooks:
            enabled: true
            consumers:
              - name: open-island
                command:
                  - "/old/path/OpenIslandHooks"
                # only the noisy ones off
                events:
                  tool.started: false
                  needs.approval: true
        """

        let mutation = try AgenticaHookInstaller.installConfigYAML(
            existingText: original,
            hookCommand: Self.command
        )
        let text = try #require(mutation.contents)

        #expect(!text.contains("/old/path/OpenIslandHooks"))
        #expect(text.contains("\n        # only the noisy ones off"))
        #expect(text.contains("\n          tool.started: false"))
        #expect(text.contains("\n          needs.approval: true"))
        #expect(AgenticaHookInstaller.hasManagedHooks(in: text))
    }

    /// Guessing at a shape we do not understand risks writing a duplicate key,
    /// which makes agentica fall back to an empty config and lose every profile.
    @Test
    func installRefusesAnInlineSettingsMapping() throws {
        #expect(throws: AgenticaHookInstallerError.self) {
            try AgenticaHookInstaller.installConfigYAML(
                existingText: "settings: {cron.enabled: true}\n",
                hookCommand: Self.command
            )
        }
    }

    @Test
    func installIgnoresKeysInsideBlockScalars() throws {
        let original = """
        system_prompt: |
          settings:
            hooks: not really a key
        active_profile: venus
        """

        let mutation = try AgenticaHookInstaller.installConfigYAML(
            existingText: original,
            hookCommand: Self.command
        )

        let text = try #require(mutation.contents)
        #expect(text.contains("  hooks: not really a key"))
        #expect(text.contains("\nsettings:"))
        #expect(AgenticaHookInstaller.hasManagedHooks(in: text))
    }

    @Test
    func uninstallRemovesOnlyOurConsumer() throws {
        let installed = try #require(
            try AgenticaHookInstaller.installConfigYAML(
                existingText: """
                settings:
                  hooks:
                    enabled: true
                    consumers:
                      - name: vpet
                        command:
                          - /usr/local/bin/vpet-hook
                """,
                hookCommand: Self.command
            ).contents
        )
        #expect(AgenticaHookInstaller.hasManagedHooks(in: installed))

        let mutation = try AgenticaHookInstaller.uninstallConfigYAML(existingText: installed)
        let text = try #require(mutation.contents)

        #expect(mutation.changed)
        #expect(!text.contains("OpenIslandHooks"))
        #expect(!text.contains("open-island"))
        #expect(text.contains("      - name: vpet"))
        #expect(text.contains("vpet-hook"))
        #expect(!AgenticaHookInstaller.hasManagedHooks(in: text))
    }

    @Test
    func uninstallLeavesAConfigWithoutOurConsumerAlone() throws {
        let original = """
        settings:
          hooks:
            enabled: true
            consumers:
              - name: vpet
                command:
                  - /usr/local/bin/vpet-hook
        """

        let mutation = try AgenticaHookInstaller.uninstallConfigYAML(existingText: original)

        #expect(!mutation.changed)
        #expect(!mutation.managedHooksPresent)
        #expect(mutation.contents == original)
    }

    @Test
    func statusRequiresTheWireAndOurConsumerToBothBeOn() throws {
        let wireOff = """
        settings:
          hooks:
            enabled: false
            consumers:
              - name: open-island
                command:
                  - "/Applications/OpenIslandHooks"
        """

        let consumerOff = """
        settings:
          hooks:
            enabled: true
            consumers:
              - name: open-island
                enabled: false
                command:
                  - "/Applications/OpenIslandHooks"
        """

        #expect(!AgenticaHookInstaller.hasManagedHooks(in: wireOff))
        #expect(!AgenticaHookInstaller.hasManagedHooks(in: consumerOff))
        #expect(!AgenticaHookInstaller.hasManagedHooks(in: nil))
        #expect(!AgenticaHookInstaller.hasManagedHooks(in: "active_profile: venus\n"))
    }
}
