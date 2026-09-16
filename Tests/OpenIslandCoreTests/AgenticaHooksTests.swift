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
        #expect(payload.approvalTitle == "Run `rm -rf build`?")
        #expect(payload.approvalSummary == "rm -rf build")
        #expect(payload.toolCallID == "call_7")
    }

    @Test
    func decodesRunCompletedNotice() throws {
        let json = """
        {
          "hook_event_name": "run.completed",
          "session_id": "run-42",
          "cwd": "/tmp/worktree",
          "run_id": "r1",
          "agent_name": "coder",
          "duration_seconds": 12.5,
          "had_response": true,
          "answer": "Updated three files.",
          "title": "run completed"
        }
        """.data(using: .utf8)!

        let payload = try JSONDecoder().decode(AgenticaHookPayload.self, from: json)

        #expect(payload.hookEventName == .runCompleted)
        #expect(!payload.hookEventName.expectsReply)
        #expect(payload.durationSeconds == 12.5)
        #expect(payload.implicitSummary == "Updated three files.")
    }

    /// agentica omits `session_id` when a run is dispatched without a live
    /// `Agent`, so the island must still be able to key the row.
    @Test
    func fallsBackToWorkingDirectoryWhenSessionIDIsAbsent() throws {
        let json = """
        {"hook_event_name": "run.started", "cwd": "/tmp/worktree", "prompt": "fix the flaky test"}
        """.data(using: .utf8)!

        let payload = try JSONDecoder().decode(AgenticaHookPayload.self, from: json)

        #expect(payload.resolvedSessionID == "agentica-cwd-/tmp/worktree")
        #expect(payload.implicitSummary == "Prompt: fix the flaky test")
        #expect(payload.sessionTitle == "Agentica · worktree")
    }

    @Test
    func directiveOmitsAbsentKeys() throws {
        let allow = try JSONEncoder().encode(AgenticaHookDirective(decision: .allow))
        #expect(String(decoding: allow, as: UTF8.self) == #"{"decision":"allow"}"#)

        let answer = try JSONEncoder().encode(AgenticaHookDirective(answer: "yes"))
        #expect(String(decoding: answer, as: UTF8.self) == #"{"answer":"yes"}"#)
    }

    /// Printing nothing is how the hook tells agentica "no decision", which
    /// leaves the terminal prompt as the answer path.
    @Test
    func emptyDirectiveProducesNoStandardOutput() throws {
        let silent = try AgenticaHookOutputEncoder.standardOutput(
            for: .agenticaHookDirective(AgenticaHookDirective())
        )
        #expect(silent == nil)

        let acknowledged = try AgenticaHookOutputEncoder.standardOutput(for: .acknowledged)
        #expect(acknowledged == nil)

        let denied = try AgenticaHookOutputEncoder.standardOutput(
            for: .agenticaHookDirective(AgenticaHookDirective(decision: .deny))
        )
        let text = String(decoding: try #require(denied), as: UTF8.self)
        #expect(text == "{\"decision\":\"deny\"}\n")
    }

    @Test
    func runtimeContextPrefersTheParentTerminal() throws {
        let payload = AgenticaHookPayload(hookEventName: .runStarted, cwd: "/tmp/worktree")
            .withRuntimeContext(
                environment: ["TERM_PROGRAM": "iTerm.app"],
                currentTTYProvider: { "/dev/ttys004" },
                terminalLocatorProvider: { _ in ("w0t1p2", "/dev/ttys009", "worktree") }
            )

        #expect(payload.terminalApp == "iTerm")
        // The locator describes the focused pane; the TTY we already resolved
        // describes the pane that actually spawned the hook.
        #expect(payload.terminalTTY == "/dev/ttys004")
        #expect(payload.terminalSessionID == "w0t1p2")
        #expect(payload.defaultJumpTarget.workspaceName == "worktree")
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
        #expect(text.contains("      - \"--source\""))
        #expect(AgenticaHookInstaller.hasManagedHooks(in: text))
    }

    /// The file holds every model profile and plaintext key, so an install must
    /// be additive and must not disturb the user's comments.
    @Test
    func installPreservesUnrelatedKeysAndComments() throws {
        let original = """
        # my agentica config
        current_profile: venus

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
        #expect(text.contains("current_profile: venus"))
        #expect(AgenticaHookInstaller.hasManagedHooks(in: text))
    }

    @Test
    func installAddsHooksUnderAnExistingSettingsBlock() throws {
        let original = """
        settings:
          # keep this
          auto_approve: false

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
        #expect(text.contains("  auto_approve: false"))
        #expect(text.contains("  # keep this"))
        #expect(text.contains("  hooks:"))

        // The new block must land inside `settings`, not after `profiles`.
        let hooksIndex = try #require(lines.firstIndex(of: "  hooks:"))
        let profilesIndex = try #require(lines.firstIndex(of: "profiles:"))
        #expect(hooksIndex < profilesIndex)
        #expect(AgenticaHookInstaller.hasManagedHooks(in: text))
    }

    @Test
    func installReplacesAStaleManagedBlockAndIsIdempotent() throws {
        let original = """
        settings:
          hooks:
            enabled: true
            command:
              - "/old/path/OpenIslandHooks"
              - "--source"
              - "agentica"
          auto_approve: true
        """

        let first = try AgenticaHookInstaller.installConfigYAML(
            existingText: original,
            hookCommand: Self.command
        )
        let text = try #require(first.contents)

        #expect(first.changed)
        #expect(!text.contains("/old/path/OpenIslandHooks"))
        #expect(text.contains("  auto_approve: true"))

        let second = try AgenticaHookInstaller.installConfigYAML(
            existingText: text,
            hookCommand: Self.command
        )
        #expect(!second.changed)
        #expect(second.contents == text)
    }

    /// Guessing at a shape we do not understand risks writing a duplicate key,
    /// which makes agentica fall back to an empty config and lose every profile.
    @Test
    func installRefusesAnInlineSettingsMapping() throws {
        #expect(throws: AgenticaHookInstallerError.self) {
            try AgenticaHookInstaller.installConfigYAML(
                existingText: "settings: {auto_approve: true}\n",
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
        current_profile: venus
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
    func uninstallRemovesOnlyTheManagedBlock() throws {
        let installed = try #require(
            try AgenticaHookInstaller.installConfigYAML(
                existingText: "current_profile: venus\n",
                hookCommand: Self.command
            ).contents
        )

        let mutation = try AgenticaHookInstaller.uninstallConfigYAML(existingText: installed)
        let text = try #require(mutation.contents)

        #expect(mutation.changed)
        #expect(!text.contains("OpenIslandHooks"))
        #expect(text.contains("current_profile: venus"))
        #expect(!AgenticaHookInstaller.hasManagedHooks(in: text))
    }

    /// agentica supports exactly one hook command, so someone else's notifier on
    /// this wire is theirs to remove.
    @Test
    func uninstallLeavesAThirdPartyHookAlone() throws {
        let original = """
        settings:
          hooks:
            enabled: true
            command:
              - /usr/local/bin/my-notifier
        """

        let mutation = try AgenticaHookInstaller.uninstallConfigYAML(existingText: original)

        #expect(!mutation.changed)
        #expect(!mutation.managedHooksPresent)
        #expect(mutation.contents == original)
    }

    /// agentica runs exactly one hook command, so installing over somebody else's
    /// is disabling it. That has to be the user's call, not the installer's.
    @Test
    func installRefusesToTakeAForeignHookSlot() throws {
        let original = """
        settings:
          hooks:
            enabled: true
            command:
              - /Users/me/Library/Application Support/VPet/agent-notify/vpet-hook
            events:
              run.started: false
              needs.approval: true
        """

        #expect(throws: AgenticaHookInstallerError.self) {
            try AgenticaHookInstaller.installConfigYAML(
                existingText: original,
                hookCommand: Self.command
            )
        }

        #expect(
            AgenticaHookInstaller.foreignHookCommand(in: original)
                == "/Users/me/Library/Application Support/VPet/agent-notify/vpet-hook"
        )

        // Taking over is a clean replacement: the previous owner's `events`
        // gating said what *they* wanted, and inheriting it would mute us.
        let taken = try AgenticaHookInstaller.installConfigYAML(
            existingText: original,
            hookCommand: Self.command,
            replacingForeignCommand: true
        )
        let text = try #require(taken.contents)
        #expect(AgenticaHookInstaller.hasManagedHooks(in: text))
        #expect(!text.contains("vpet-hook"))
        #expect(!text.contains("run.started: false"))
        #expect(AgenticaHookInstaller.foreignHookCommand(in: text) == nil)
    }

    /// Reinstalling must not throw away tuning the user applied to *our* block.
    @Test
    func reinstallPreservesUserAuthoredKeysInOurOwnBlock() throws {
        let original = """
        settings:
          hooks:
            enabled: false
            command:
              - "/old/path/OpenIslandHooks"
              - "--source"
              - "agentica"
            # only tell me when you need me
            events:
              run.started: false
              needs.approval: true
        """

        let mutation = try AgenticaHookInstaller.installConfigYAML(
            existingText: original,
            hookCommand: Self.command
        )
        let text = try #require(mutation.contents)

        #expect(!text.contains("/old/path/OpenIslandHooks"))
        #expect(text.contains("\n    enabled: true"))
        #expect(text.contains("    # only tell me when you need me"))
        #expect(text.contains("      run.started: false"))
        #expect(text.contains("      needs.approval: true"))
        #expect(AgenticaHookInstaller.hasManagedHooks(in: text))
    }

    @Test
    func statusRequiresBothOurCommandAndAnEnabledFlag() throws {
        let disabled = """
        settings:
          hooks:
            enabled: false
            command:
              - "/Applications/OpenIslandHooks"
        """

        #expect(!AgenticaHookInstaller.hasManagedHooks(in: disabled))
        #expect(!AgenticaHookInstaller.hasManagedHooks(in: nil))
        #expect(!AgenticaHookInstaller.hasManagedHooks(in: "current_profile: venus\n"))
    }
}
