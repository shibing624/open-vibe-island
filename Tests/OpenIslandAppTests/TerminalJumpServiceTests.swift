import Foundation
import Testing
@testable import OpenIslandApp
import OpenIslandCore

@Suite(.serialized)
struct TerminalJumpServiceTests {
    private final class OpenedArgumentsBox: @unchecked Sendable {
        var values: [[String]] = []
    }

    private final class ProcessInvocationBox: @unchecked Sendable {
        var values: [(String, [String])] = []
    }

    private final class FocusedSurfacesBox: @unchecked Sendable {
        var values: [String] = []
    }

    @Test
    func ghosttyJumpScriptActivatesWindowAndRetriesFocusUntilItSticks() {
        let target = JumpTarget(
            terminalApp: "Ghostty",
            workspaceName: "open-island",
            paneTitle: "codex ~/p/open-island",
            workingDirectory: "/Users/wangruobing/Personal/open-island",
            terminalSessionID: "448D7E28-24FB-46F1-9504-C252F97926C1"
        )

        let script = TerminalJumpService().ghosttyJumpScript(for: target)

        #expect(script.contains("activate"))
        #expect(script.contains("activate window targetWindow"))
        #expect(script.contains("select tab targetTab"))
        #expect(script.contains("focus targetTerminal"))
        #expect(script.contains("repeat 3 times"))
        #expect(script.contains("delay 0.04"))
        #expect(script.contains("delay 0.08"))
        #expect(script.contains("focused terminal of selected tab of front window"))
        #expect(script.contains("repeat with aWindow in windows"))
        #expect(script.contains("repeat with aTab in tabs of aWindow"))
        #expect(script.contains("repeat with aTerminal in terminals of aTab"))
    }

    @Test
    func ghosttyJumpScriptFallsBackToWorkingDirectoryAndTitle() {
        let target = JumpTarget(
            terminalApp: "Ghostty",
            workspaceName: "open-island",
            paneTitle: "codex ~/p/open-island",
            workingDirectory: "/Users/wangruobing/Personal/open-island"
        )

        let script = TerminalJumpService().ghosttyJumpScript(for: target)

        #expect(script.contains("(working directory of aTerminal as text) is \"/Users/wangruobing/Personal/open-island\""))
        #expect(script.contains("(name of aTerminal as text) contains \"codex ~/p/open-island\""))
        #expect(script.contains("if \"\" is \"\" then"))
    }

    @Test
    func ghosttyJumpIntegrationMatchesFocusedTerminalForLiveSurfaces() throws {
        guard ProcessInfo.processInfo.environment["OPEN_ISLAND_RUN_GHOSTTY_JUMP_INTEGRATION"] == "1" else {
            try Test.cancel("Set OPEN_ISLAND_RUN_GHOSTTY_JUMP_INTEGRATION=1 to run live Ghostty jump verification.")
        }

        let terminals = try liveGhosttyTerminals()
        if terminals.isEmpty {
            try Test.cancel("No live Ghostty terminals were found.")
        }

        let service = TerminalJumpService()
        for terminal in terminals {
            var matched = false
            var lastResult = ""
            var lastFocusedID = ""

            for _ in 0..<2 {
                lastResult = try service.jump(
                    to: JumpTarget(
                        terminalApp: "Ghostty",
                        workspaceName: URL(fileURLWithPath: terminal.workingDirectory).lastPathComponent,
                        paneTitle: terminal.title,
                        workingDirectory: terminal.workingDirectory,
                        terminalSessionID: terminal.id
                    )
                )
                lastFocusedID = try focusedGhosttyTerminalID()
                if lastResult == "Focused the matching Ghostty terminal.",
                   lastFocusedID == terminal.id {
                    matched = true
                    break
                }

                Thread.sleep(forTimeInterval: 0.25)
            }

            #expect(
                matched,
                "Ghostty jump did not settle on \(terminal.id). lastResult=\(lastResult) lastFocusedID=\(lastFocusedID)"
            )
        }
    }

    @Test
    func ghosttyJumpDoesNotOpenNewTabWhenPreciseTargetMissesInRunningApp() throws {
        let openedArguments = OpenedArgumentsBox()
        let service = TerminalJumpService(
            applicationResolver: { bundleIdentifier in
                bundleIdentifier == "com.mitchellh.ghostty" ? URL(fileURLWithPath: "/Applications/Ghostty.app") : nil
            },
            appRunningChecker: { bundleIdentifier in
                bundleIdentifier == "com.mitchellh.ghostty"
            },
            openAction: { arguments in
                openedArguments.values.append(arguments)
            },
            appleScriptRunner: { _ in "" }
        )

        let result = try service.jump(
            to: JumpTarget(
                terminalApp: "Ghostty",
                workspaceName: "open-island",
                paneTitle: "Claude open-island",
                workingDirectory: "/Users/wangruobing/Personal/open-island",
                terminalTTY: "/dev/ttys002"
            )
        )

        #expect(result == "Activated Ghostty. Exact pane targeting could not find the live terminal.")
        #expect(openedArguments.values == [["-b", "com.mitchellh.ghostty"]])
    }

    @Test
    func cursorJumpActivatesRunningAppWithoutWorkspaceReuse() throws {
        let openedArguments = OpenedArgumentsBox()
        let service = TerminalJumpService(
            applicationResolver: { bundleIdentifier in
                bundleIdentifier == "com.todesktop.230313mzl4w4u92" ? URL(fileURLWithPath: "/Applications/Cursor.app") : nil
            },
            appRunningChecker: { bundleIdentifier in
                bundleIdentifier == "com.todesktop.230313mzl4w4u92"
            },
            openAction: { arguments in
                openedArguments.values.append(arguments)
            },
            appleScriptRunner: { _ in "" },
            processRunner: { _, _ in false }
        )

        let result = try service.jump(
            to: JumpTarget(
                terminalApp: "Cursor",
                workspaceName: "open-vibe-island",
                paneTitle: "Cursor abc123",
                workingDirectory: "/Users/test/open-vibe-island"
            )
        )

        #expect(result == "Activated Cursor.")
        #expect(openedArguments.values == [["-b", "com.todesktop.230313mzl4w4u92"]])
    }

    @Test
    func cursorJumpFallsBackToWorkspaceWhenAppNotRunning() throws {
        let openedArguments = OpenedArgumentsBox()
        let service = TerminalJumpService(
            applicationResolver: { bundleIdentifier in
                bundleIdentifier == "com.todesktop.230313mzl4w4u92" ? URL(fileURLWithPath: "/Applications/Cursor.app") : nil
            },
            appRunningChecker: { _ in false },
            openAction: { arguments in
                openedArguments.values.append(arguments)
            },
            appleScriptRunner: { _ in "" },
            processRunner: { _, _ in true }
        )

        let result = try service.jump(
            to: JumpTarget(
                terminalApp: "Cursor",
                workspaceName: "open-vibe-island",
                paneTitle: "Cursor abc123",
                workingDirectory: "/Users/test/open-vibe-island"
            )
        )

        #expect(result == "Focused the matching Cursor workspace.")
        #expect(openedArguments.values.isEmpty)
    }

    @Test
    func warpJumpReturnsImmediatelyWhenAlreadyOnTargetPane() throws {
        let openedArguments = OpenedArgumentsBox()
        let keystroker = KeystrokeInjectorSpy()
        let targetUUID = "D1A5DF3027E44FC080FE2656FAF2BA2E"

        let service = TerminalJumpService(
            applicationResolver: { id in
                id == "dev.warp.Warp-Stable" ? URL(fileURLWithPath: "/Applications/Warp.app") : nil
            },
            appRunningChecker: { id in id == "dev.warp.Warp-Stable" },
            openAction: { arguments in openedArguments.values.append(arguments) },
            appleScriptRunner: { _ in "" },
            warpFocusedPaneReader: { targetUUID },  // already at target
            warpTabCountReader: { 3 },
            warpKeystroker: keystroker,
            warpFrontmostChecker: { true }
        )

        let result = try service.jump(
            to: JumpTarget(
                terminalApp: "Warp",
                workspaceName: "demo",
                paneTitle: "Claude demo",
                workingDirectory: "/Users/u/demo",
                warpPaneUUID: targetUUID
            )
        )

        #expect(result == "Focused the matching Warp tab.")
        #expect(keystroker.callCount == 0)
        #expect(openedArguments.values == [["-b", "dev.warp.Warp-Stable"]])
    }

    @Test
    func warpJumpCyclesThroughTabsUntilTargetIsFocused() throws {
        let openedArguments = OpenedArgumentsBox()
        let keystroker = KeystrokeInjectorSpy()
        let targetUUID = "BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB"

        // Simulate starting on some other tab, then after 2 keystrokes landing on target.
        let readSequence = ReadSequenceBox(values: [
            "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA", // initial
            "CCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCC", // after 1st keystroke
            targetUUID,                         // after 2nd keystroke — match!
        ])

        let service = TerminalJumpService(
            applicationResolver: { id in
                id == "dev.warp.Warp-Stable" ? URL(fileURLWithPath: "/Applications/Warp.app") : nil
            },
            appRunningChecker: { id in id == "dev.warp.Warp-Stable" },
            openAction: { arguments in openedArguments.values.append(arguments) },
            appleScriptRunner: { _ in "" },
            warpFocusedPaneReader: { readSequence.next() },
            warpTabCountReader: { 4 },
            warpKeystroker: keystroker,
            warpFrontmostChecker: { true }
        )

        let result = try service.jump(
            to: JumpTarget(
                terminalApp: "Warp",
                workspaceName: "demo",
                paneTitle: "Claude demo",
                workingDirectory: "/Users/u/demo",
                warpPaneUUID: targetUUID
            )
        )

        #expect(result == "Focused the matching Warp tab.")
        #expect(keystroker.callCount == 2)
        #expect(openedArguments.values == [["-b", "dev.warp.Warp-Stable"]])
    }

    @Test
    func warpJumpCapsOutAfterTabCountPlusTwoAndReturnsBestEffortMessage() throws {
        let keystroker = KeystrokeInjectorSpy()
        let service = TerminalJumpService(
            applicationResolver: { id in
                id == "dev.warp.Warp-Stable" ? URL(fileURLWithPath: "/Applications/Warp.app") : nil
            },
            appRunningChecker: { id in id == "dev.warp.Warp-Stable" },
            openAction: { _ in },
            appleScriptRunner: { _ in "" },
            warpFocusedPaneReader: { "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA" },  // never matches
            warpTabCountReader: { 3 },
            warpKeystroker: keystroker,
            warpFrontmostChecker: { true }
        )

        let result = try service.jump(
            to: JumpTarget(
                terminalApp: "Warp",
                workspaceName: "demo",
                paneTitle: "Claude demo",
                workingDirectory: "/Users/u/demo",
                warpPaneUUID: "BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB"
            )
        )

        #expect(result == "Activated Warp but could not confirm precision focus.")
        #expect(keystroker.callCount == 5)  // tabCount (3) + 2
    }

    @Test
    func warpJumpWithNilWarpPaneUUIDFallsBackToAppActivation() throws {
        let keystroker = KeystrokeInjectorSpy()
        let openedArguments = OpenedArgumentsBox()
        let service = TerminalJumpService(
            applicationResolver: { id in
                id == "dev.warp.Warp-Stable" ? URL(fileURLWithPath: "/Applications/Warp.app") : nil
            },
            appRunningChecker: { id in id == "dev.warp.Warp-Stable" },
            openAction: { arguments in openedArguments.values.append(arguments) },
            appleScriptRunner: { _ in "" },
            warpFocusedPaneReader: { "SHOULD-NOT-BE-READ" },
            warpTabCountReader: { 3 },
            warpKeystroker: keystroker,
            warpFrontmostChecker: { true }
        )

        let result = try service.jump(
            to: JumpTarget(
                terminalApp: "Warp",
                workspaceName: "demo",
                paneTitle: "Claude demo",
                workingDirectory: "/Users/u/demo",
                warpPaneUUID: nil
            )
        )

        #expect(result == "Activated Warp. No precise pane mapping available.")
        #expect(keystroker.callCount == 0)
        #expect(openedArguments.values == [["-b", "dev.warp.Warp-Stable"]])
    }

    @Test
    func unknownTerminalAppFallsBackToFinderInsteadOfFirstInstalledTerminal() throws {
        let openedArguments = OpenedArgumentsBox()
        // Pretend iTerm is installed. Without the "unknown" guard in
        // resolveTerminalApp, the silent "first installed known app" fallback
        // would return iTerm's descriptor and the cwd would end up being opened
        // via `open -b com.googlecode.iterm2 /path` (wrong terminal).
        let service = TerminalJumpService(
            applicationResolver: { bundleIdentifier in
                bundleIdentifier == "com.googlecode.iterm2" ? URL(fileURLWithPath: "/Applications/iTerm.app") : nil
            },
            appRunningChecker: { _ in false },
            openAction: { arguments in
                openedArguments.values.append(arguments)
            },
            appleScriptRunner: { _ in "" }
        )

        let result = try service.jump(
            to: JumpTarget(
                terminalApp: "Unknown",
                workspaceName: "my-project",
                paneTitle: "",
                workingDirectory: "/tmp"
            )
        )

        #expect(openedArguments.values == [["/tmp"]])
        #expect(
            result.contains("Finder"),
            "Expected Finder fallback, got: \(result)"
        )
    }

    // MARK: - cmux

    /// A cmux notification click must switch to the tab that owns the agent.
    /// The surface id is the only handle for that, and `jumpToCmuxTerminal`
    /// gives up without it — which is what made earlier builds merely bring
    /// cmux forward.
    @Test
    func cmuxJumpFocusesTheRecordedSurface() throws {
        let focusedSurfaces = FocusedSurfacesBox()
        let service = TerminalJumpService(
            applicationResolver: { id in
                id == "com.cmuxterm.app" ? URL(fileURLWithPath: "/Applications/cmux.app") : nil
            },
            appRunningChecker: { id in id == "com.cmuxterm.app" },
            openAction: { _ in },
            appleScriptRunner: { _ in "" },
            cmuxSurfaceFocuser: { surfaceID in
                focusedSurfaces.values.append(surfaceID)
                return true
            }
        )

        let result = try service.jump(
            to: JumpTarget(
                terminalApp: "cmux",
                workspaceName: "open-island",
                paneTitle: "open-island-1",
                workingDirectory: "/Users/u/open-island",
                terminalSessionID: "4FB58912-B60B-49EB-A1BD-A5C42A7536C4"
            )
        )

        #expect(focusedSurfaces.values == ["4FB58912-B60B-49EB-A1BD-A5C42A7536C4"])
        #expect(result == "Focused the matching cmux terminal.")
    }

    /// The tmux branch used to fall through to `default` for cmux and merely
    /// activate the app, so a tmux pane inside a cmux tab could never bring its
    /// own tab forward — the pane got selected in a tab the user was not
    /// looking at.
    @Test
    func cmuxJumpFocusesTheSurfaceWhenTheSessionIsInsideTmux() throws {
        let focusedSurfaces = FocusedSurfacesBox()
        let service = TerminalJumpService(
            applicationResolver: { id in
                id == "com.cmuxterm.app" ? URL(fileURLWithPath: "/Applications/cmux.app") : nil
            },
            appRunningChecker: { id in id == "com.cmuxterm.app" },
            openAction: { _ in },
            appleScriptRunner: { _ in "" },
            cmuxSurfaceFocuser: { surfaceID in
                focusedSurfaces.values.append(surfaceID)
                return true
            },
            tmuxPaneSelector: { _ in true }
        )

        let result = try service.jump(
            to: JumpTarget(
                terminalApp: "cmux",
                workspaceName: "open-island",
                paneTitle: "open-island-1",
                workingDirectory: "/Users/u/open-island",
                terminalSessionID: "4FB58912-B60B-49EB-A1BD-A5C42A7536C4",
                tmuxTarget: "oss-contributions:3.0",
                tmuxSocketPath: "/private/tmp/tmux-501/default"
            )
        )

        #expect(focusedSurfaces.values == ["4FB58912-B60B-49EB-A1BD-A5C42A7536C4"])
        #expect(result == "Focused the matching tmux pane in cmux.")
    }

    /// When the pane itself cannot be selected the tab must still be focused:
    /// landing the user in the right tab is the larger half of the jump, and
    /// saying so is better than reporting the whole jump as failed.
    @Test
    func cmuxJumpStillFocusesTheTabWhenTmuxPaneSelectionFails() throws {
        let focusedSurfaces = FocusedSurfacesBox()
        let service = TerminalJumpService(
            applicationResolver: { id in
                id == "com.cmuxterm.app" ? URL(fileURLWithPath: "/Applications/cmux.app") : nil
            },
            appRunningChecker: { id in id == "com.cmuxterm.app" },
            openAction: { _ in },
            appleScriptRunner: { _ in "" },
            cmuxSurfaceFocuser: { surfaceID in
                focusedSurfaces.values.append(surfaceID)
                return true
            },
            tmuxPaneSelector: { _ in false }
        )

        let result = try service.jump(
            to: JumpTarget(
                terminalApp: "cmux",
                workspaceName: "open-island",
                paneTitle: "open-island-1",
                workingDirectory: "/Users/u/open-island",
                terminalSessionID: "4FB58912-B60B-49EB-A1BD-A5C42A7536C4",
                tmuxTarget: "oss-contributions:3.0",
                tmuxSocketPath: "/private/tmp/tmux-501/default"
            )
        )

        #expect(focusedSurfaces.values == ["4FB58912-B60B-49EB-A1BD-A5C42A7536C4"])
        #expect(result == "Focused the matching cmux tab. tmux pane targeting failed.")
    }

    /// cmux refusing the surface (a stale id from a closed tab) must not be
    /// reported as a completed jump: falling back to activating the app is
    /// honest, claiming the tab was focused is not.
    @Test
    func cmuxJumpDoesNotClaimSuccessWhenCmuxRefusesTheSurface() throws {
        let openedArguments = OpenedArgumentsBox()
        let service = TerminalJumpService(
            applicationResolver: { id in
                id == "com.cmuxterm.app" ? URL(fileURLWithPath: "/Applications/cmux.app") : nil
            },
            appRunningChecker: { id in id == "com.cmuxterm.app" },
            openAction: { arguments in openedArguments.values.append(arguments) },
            appleScriptRunner: { _ in "" },
            cmuxSurfaceFocuser: { _ in false }
        )

        let result = try service.jump(
            to: JumpTarget(
                terminalApp: "cmux",
                workspaceName: "open-island",
                paneTitle: "open-island-1",
                workingDirectory: "/Users/u/open-island",
                terminalSessionID: "STALE-SURFACE-ID"
            )
        )

        #expect(openedArguments.values == [["-b", "com.cmuxterm.app"]])
        #expect(result == "Activated cmux. Exact pane targeting could not find the live terminal.")
    }

    /// The verdict is read from cmux's own `ok` field, which is the one thing
    /// that distinguishes "switched the tab" from "accepted the bytes". A
    /// success envelope, a refusal for an unknown surface, and a reply that is
    /// not JSON at all have to land on three different answers.
    @Test
    func cmuxReplyVerdictComesFromTheOkField() {
        #expect(
            TerminalJumpService.cmuxReplySucceeded(
                #"{"ok":true,"id":1,"result":{"surface_ref":"surface:8"}}"#
            ) == true
        )
        #expect(
            TerminalJumpService.cmuxReplySucceeded(
                #"{"ok":false,"id":1,"error":{"code":"not_found","message":"Workspace not found"}}"#
            ) == false
        )
        #expect(TerminalJumpService.cmuxReplySucceeded("not json") == nil)
        #expect(TerminalJumpService.cmuxReplySucceeded("") == nil)
        // An envelope with no `ok` at all is not evidence of a switch.
        #expect(TerminalJumpService.cmuxReplySucceeded(#"{"id":1,"result":{}}"#) == nil)
    }

    /// Pins the bytes cmux actually receives and the behaviour on each reply.
    ///
    /// The method name and the `surface_id` key are the contract with cmux, and
    /// getting either wrong fails silently — a request cmux does not recognise
    /// simply never moves the tab. A stub cmux is used because the real one
    /// cannot be driven from a test.
    @Test
    func cmuxSurfaceFocusSpeaksTheSocketContractAndHonoursTheReply() throws {
        let surfaceID = "4FB58912-B60B-49EB-A1BD-A5C42A7536C4"

        // Records what arrived, then answers with `reply`. A nil reply stands
        // for a cmux that accepts the connection and then says nothing.
        func runStub(reply: String?) -> (accepted: Bool, request: String) {
            // /tmp rather than NSTemporaryDirectory(): the latter expands to a
            // /var/folders/... path long enough that the socket path no longer
            // fits in `sun_path`.
            let directory = URL(fileURLWithPath: "/tmp")
                .appendingPathComponent("cmux-stub-\(UUID().uuidString)")
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: directory) }
            let socketPath = directory.appendingPathComponent("cmux.sock").path

            let serverFD = socket(AF_UNIX, SOCK_STREAM, 0)
            guard serverFD >= 0 else { return (false, "") }
            defer { close(serverFD) }

            var addr = sockaddr_un()
            addr.sun_family = sa_family_t(AF_UNIX)
            addr.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
            let pathBytes = socketPath.utf8CString
            guard pathBytes.count <= MemoryLayout.size(ofValue: addr.sun_path) else {
                return (false, "")
            }
            withUnsafeMutableBytes(of: &addr.sun_path) { sunPath in
                for (i, byte) in pathBytes.enumerated() {
                    sunPath[i] = UInt8(bitPattern: byte)
                }
            }
            let bound = withUnsafePointer(to: &addr) { ptr in
                ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPtr in
                    Darwin.bind(serverFD, sockaddrPtr, socklen_t(MemoryLayout<sockaddr_un>.size))
                }
            }
            guard bound == 0, listen(serverFD, 1) == 0 else { return (false, "") }

            let acceptedBox = ReceivedRequestBox()
            let done = DispatchSemaphore(value: 0)
            DispatchQueue.global().async {
                defer { done.signal() }
                let client = accept(serverFD, nil, nil)
                guard client >= 0 else { return }
                defer { close(client) }

                var buffer = [UInt8](repeating: 0, count: 4096)
                let n = read(client, &buffer, buffer.count)
                guard n > 0 else { return }
                acceptedBox.request = String(bytes: buffer[0..<n], encoding: .utf8) ?? ""

                if let reply {
                    let out = Array(reply.utf8)
                    _ = out.withUnsafeBufferPointer { write(client, $0.baseAddress, $0.count) }
                }
            }

            let accepted = TerminalJumpService.focusCmuxSurface(
                surfaceID: surfaceID,
                socketPath: socketPath
            )
            _ = done.wait(timeout: .now() + 5)
            return (accepted, acceptedBox.request)
        }

        // A success envelope is the only thing that may count as a switch.
        let success = runStub(
            reply: #"{"ok":true,"id":1,"result":{"surface_ref":"surface:8"}}"# + "\n"
        )
        #expect(success.accepted)
        #expect(success.request.contains(#""method":"surface.focus""#))
        #expect(success.request.contains(#""surface_id":"\#(surfaceID)""#))

        // cmux refusing the surface must not be reported as a jump.
        let refused = runStub(
            reply: #"{"ok":false,"id":1,"error":{"code":"not_found","message":"Workspace not found"}}"# + "\n"
        )
        #expect(!refused.accepted)

        // Silence must not be reported as a jump either.
        let silent = runStub(reply: nil)
        #expect(!silent.accepted)
    }

    private final class ReceivedRequestBox: @unchecked Sendable {
        var request = ""
    }

    @Test
    func traeJumpActivatesRunningTraeCNApp() throws {
        let openedArguments = OpenedArgumentsBox()
        let service = TerminalJumpService(
            applicationResolver: { bundleIdentifier in
                bundleIdentifier == "cn.trae.app" ? URL(fileURLWithPath: "/Applications/Trae CN.app") : nil
            },
            appRunningChecker: { bundleIdentifier in
                bundleIdentifier == "cn.trae.app"
            },
            openAction: { arguments in
                openedArguments.values.append(arguments)
            },
            appleScriptRunner: { _ in "" },
            // Must be injected: the default runner shells out to the real `trae`
            // CLI, so an uninjected test launches the IDE on any machine that
            // has it installed — and then never reaches the activation branch
            // this test is about.
            processRunner: { _, _ in false }
        )

        let result = try service.jump(
            to: JumpTarget(
                terminalApp: "Trae",
                workspaceName: "open-vibe-island",
                paneTitle: "Trae abc123",
                workingDirectory: "/Users/test/open-vibe-island"
            )
        )

        #expect(result == "Activated Trae.")
        #expect(openedArguments.values == [["-b", "cn.trae.app"]])
    }

    @Test
    func traeCNJumpPrefersCNBundleWhenBothTraeVariantsExist() throws {
        let openedArguments = OpenedArgumentsBox()
        let service = TerminalJumpService(
            applicationResolver: { bundleIdentifier in
                switch bundleIdentifier {
                case "com.trae.app":
                    return URL(fileURLWithPath: "/Applications/Trae.app")
                case "cn.trae.app":
                    return URL(fileURLWithPath: "/Applications/Trae CN.app")
                default:
                    return nil
                }
            },
            appRunningChecker: { bundleIdentifier in
                bundleIdentifier == "com.trae.app"
            },
            openAction: { arguments in
                openedArguments.values.append(arguments)
            },
            appleScriptRunner: { _ in "" }
        )

        let result = try service.jump(
            to: JumpTarget(
                terminalApp: "Trae CN",
                workspaceName: "open-vibe-island",
                paneTitle: "Trae abc123"
            )
        )

        #expect(result == "Activated Trae. Exact pane targeting is still best-effort.")
        #expect(openedArguments.values == [["-b", "cn.trae.app"]])
    }

    @Test
    func codexAppJumpActivatesCodexDesktopApp() throws {
        let openedArguments = OpenedArgumentsBox()
        let service = TerminalJumpService(
            applicationResolver: { bundleIdentifier in
                bundleIdentifier == "com.openai.codex" ? URL(fileURLWithPath: "/Applications/Codex.app") : nil
            },
            appRunningChecker: { bundleIdentifier in
                bundleIdentifier == "com.openai.codex"
            },
            openAction: { arguments in
                openedArguments.values.append(arguments)
            },
            appleScriptRunner: { _ in "" }
        )

        let result = try service.jump(
            to: JumpTarget(
                terminalApp: "Codex.app",
                workspaceName: "my-project",
                paneTitle: "",
                workingDirectory: "/Users/test/my-project"
            )
        )

        #expect(result == "Activated Codex.app.")
        #expect(openedArguments.values == [["-b", "com.openai.codex"]])
    }

    @Test
    func codexAppJumpOpensSpecificThreadWhenThreadIDProvided() throws {
        let openedArguments = OpenedArgumentsBox()
        let service = TerminalJumpService(
            applicationResolver: { bundleIdentifier in
                bundleIdentifier == "com.openai.codex" ? URL(fileURLWithPath: "/Applications/Codex.app") : nil
            },
            appRunningChecker: { bundleIdentifier in
                bundleIdentifier == "com.openai.codex"
            },
            openAction: { arguments in
                openedArguments.values.append(arguments)
            },
            appleScriptRunner: { _ in "" }
        )

        let threadID = "019d9a98-d3ab-7060-95b2-0a435912da57"
        let result = try service.jump(
            to: JumpTarget(
                terminalApp: "Codex.app",
                workspaceName: "my-project",
                paneTitle: "",
                workingDirectory: "/Users/test/my-project",
                codexThreadID: threadID
            )
        )

        #expect(result == "Focused the Codex.app conversation.")
        #expect(openedArguments.values == [["codex://threads/\(threadID)"]])
    }

    @Test
    func traeCNJumpFallsBackToWorkspaceViaTraeCLI() throws {
        let openedArguments = OpenedArgumentsBox()
        let processInvocations = ProcessInvocationBox()
        let service = TerminalJumpService(
            applicationResolver: { bundleIdentifier in
                bundleIdentifier == "cn.trae.app" ? URL(fileURLWithPath: "/Applications/Trae CN.app") : nil
            },
            appRunningChecker: { _ in false },
            openAction: { arguments in
                openedArguments.values.append(arguments)
            },
            appleScriptRunner: { _ in "" },
            processRunner: { executable, arguments in
                processInvocations.values.append((executable, arguments))
                return true
            }
        )

        let result = try service.jump(
            to: JumpTarget(
                terminalApp: "Trae CN",
                workspaceName: "open-vibe-island",
                paneTitle: "Trae abc123",
                workingDirectory: "/Users/test/open-vibe-island"
            )
        )

        #expect(result == "Focused the matching Trae workspace.")
        #expect(openedArguments.values.isEmpty)
        #expect(processInvocations.values.count == 1)
        #expect(processInvocations.values.first?.0 == "trae")
        #expect(processInvocations.values.first?.1 == ["-r", "/Users/test/open-vibe-island"])
    }

    // MARK: - tmux command sequence

    /// tmux moves a client between sessions with `switch-client`. When that
    /// fails the client never left the session it was on, so `select-window`
    /// and `select-pane` would rearrange a session nobody is watching and the
    /// jump would still be reported as a focus. The sequence has to stop.
    @Test
    func tmuxJumpStopsWhenSwitchClientFails() throws {
        let invocations = TmuxInvocationBox()
        let service = TerminalJumpService(
            applicationResolver: { _ in URL(fileURLWithPath: "/Applications/Ghostty.app") },
            appRunningChecker: { _ in true },
            openAction: { _ in },
            appleScriptRunner: { _ in "" },
            tmuxCommandRunner: { _, args in
                invocations.values.append(args)
                if args.first == "list-clients" { return "/dev/ttys004\tother-session" }
                if args.first == "switch-client" { return nil }
                return ""
            }
        )

        let result = try service.jump(
            to: JumpTarget(
                terminalApp: "Ghostty",
                workspaceName: "open-island",
                paneTitle: "agent",
                workingDirectory: "/Users/u/open-island",
                tmuxTarget: "oss:3.0"
            )
        )

        // Nothing may run after the failed switch-client.
        #expect(invocations.values.map(\.first) == ["list-clients", "switch-client"])
        #expect(!result.contains("Focused the matching tmux pane"))
    }

    /// With several clients attached, the one already on the target session is
    /// the user's window onto that session. Taking whichever client tmux lists
    /// first would switch an unrelated client away from what it was showing.
    @Test
    func tmuxJumpPrefersTheClientAlreadyOnTheTargetSession() throws {
        let invocations = TmuxInvocationBox()
        let service = TerminalJumpService(
            applicationResolver: { _ in URL(fileURLWithPath: "/Applications/Ghostty.app") },
            appRunningChecker: { _ in true },
            openAction: { _ in },
            appleScriptRunner: { _ in "matched" },
            tmuxCommandRunner: { _, args in
                invocations.values.append(args)
                if args.first == "list-clients" {
                    return "/dev/ttys004\tunrelated\n/dev/ttys009\toss"
                }
                return ""
            }
        )

        _ = try service.jump(
            to: JumpTarget(
                terminalApp: "Ghostty",
                workspaceName: "open-island",
                paneTitle: "agent",
                workingDirectory: "/Users/u/open-island",
                tmuxTarget: "oss:3.0"
            )
        )

        // The chosen client is already on "oss", so no switch-client at all —
        // and critically not one aimed at /dev/ttys004.
        #expect(!invocations.values.contains { $0.first == "switch-client" })
        #expect(invocations.values.map(\.first) == ["list-clients", "select-window", "select-pane"])
    }

    /// The window/pane addresses are derived from "session:window.pane", and
    /// getting that split wrong silently targets the wrong pane.
    @Test
    func tmuxJumpAddressesTheWindowAndPaneItWasGiven() throws {
        let invocations = TmuxInvocationBox()
        let service = TerminalJumpService(
            applicationResolver: { _ in URL(fileURLWithPath: "/Applications/Ghostty.app") },
            appRunningChecker: { _ in true },
            openAction: { _ in },
            appleScriptRunner: { _ in "matched" },
            tmuxCommandRunner: { _, args in
                invocations.values.append(args)
                if args.first == "list-clients" { return "/dev/ttys004\toss" }
                return ""
            }
        )

        _ = try service.jump(
            to: JumpTarget(
                terminalApp: "Ghostty",
                workspaceName: "open-island",
                paneTitle: "agent",
                workingDirectory: "/Users/u/open-island",
                tmuxTarget: "oss:3.0"
            )
        )

        #expect(invocations.values.contains(["select-window", "-t", "oss:3"]))
        #expect(invocations.values.contains(["select-pane", "-t", "oss:3.0"]))
    }

    /// A failing select-window means the target window was never brought
    /// forward, so the pane selection underneath it is not a completed jump.
    @Test
    func tmuxJumpStopsWhenSelectWindowFails() throws {
        let invocations = TmuxInvocationBox()
        let service = TerminalJumpService(
            applicationResolver: { _ in URL(fileURLWithPath: "/Applications/Ghostty.app") },
            appRunningChecker: { _ in true },
            openAction: { _ in },
            appleScriptRunner: { _ in "" },
            tmuxCommandRunner: { _, args in
                invocations.values.append(args)
                if args.first == "list-clients" { return "/dev/ttys004\toss" }
                if args.first == "select-window" { return nil }
                return ""
            }
        )

        let result = try service.jump(
            to: JumpTarget(
                terminalApp: "Ghostty",
                workspaceName: "open-island",
                paneTitle: "agent",
                workingDirectory: "/Users/u/open-island",
                tmuxTarget: "oss:3.0"
            )
        )

        #expect(!invocations.values.contains { $0.first == "select-pane" })
        #expect(!result.contains("Focused the matching tmux pane"))
    }

    // MARK: - No guessing at an unresolvable host

    /// `HookTerminalContext` emits the bare string "JetBrains" when it cannot
    /// pin down which JetBrains IDE is hosting the session. That name matches
    /// no descriptor, and the old fallback then activated the first *installed*
    /// entry of the ordered `knownApps` list — iTerm on most machines.
    @Test
    func unmappedTerminalNameDoesNotActivateAnUnrelatedTerminal() throws {
        let openedArguments = OpenedArgumentsBox()
        let service = TerminalJumpService(
            applicationResolver: { _ in URL(fileURLWithPath: "/Applications/iTerm.app") },
            appRunningChecker: { _ in true },
            openAction: { arguments in openedArguments.values.append(arguments) },
            appleScriptRunner: { _ in "" }
        )

        let result = try service.jump(
            to: JumpTarget(
                terminalApp: "JetBrains",
                workspaceName: "open-island",
                paneTitle: "agent",
                workingDirectory: FileManager.default.temporaryDirectory.path
            )
        )

        // The cwd is opened in Finder; no terminal bundle is activated.
        #expect(!openedArguments.values.contains { $0.contains("-b") })
        #expect(result.contains("Finder"))
    }

    /// Which emulator draws a Zellij session is not implied by which emulator
    /// is running. Activating the first running known app raised iTerm for a
    /// Zellij session living in Ghostty.
    @Test
    func zellijJumpDoesNotActivateAGuessedParentTerminal() {
        let openedArguments = OpenedArgumentsBox()
        let service = TerminalJumpService(
            applicationResolver: { _ in URL(fileURLWithPath: "/Applications/iTerm.app") },
            appRunningChecker: { _ in true },
            openAction: { arguments in openedArguments.values.append(arguments) },
            appleScriptRunner: { _ in "" }
        )

        // No terminalSessionID, so the pane cannot be located and the old code
        // took the parent-terminal fallback.
        #expect(throws: (any Error).self) {
            try service.jump(
                to: JumpTarget(
                    terminalApp: "Zellij",
                    workspaceName: "open-island",
                    paneTitle: "agent",
                    workingDirectory: "/Users/u/open-island"
                )
            )
        }
        #expect(openedArguments.values.isEmpty)
    }
}

final class TmuxInvocationBox: @unchecked Sendable {
    var values: [[String]] = []
}

final class ReadSequenceBox: @unchecked Sendable {
    private var values: [String?]
    init(values: [String?]) { self.values = values }
    func next() -> String? {
        guard !values.isEmpty else { return nil }
        return values.removeFirst()
    }
}

private struct LiveGhosttyTerminal: Equatable {
    let id: String
    let workingDirectory: String
    let title: String
}

private let fieldSeparator = "\u{1f}"
private let recordSeparator = "\u{1e}"

private func liveGhosttyTerminals() throws -> [LiveGhosttyTerminal] {
    let script = """
    tell application "Ghostty"
        if not (it is running) then return ""
        set outputRecords to {}
        repeat with aWindow in windows
            repeat with aTab in tabs of aWindow
                repeat with aTerminal in terminals of aTab
                    set end of outputRecords to (id of aTerminal as text) & "\(fieldSeparator)" & (working directory of aTerminal as text) & "\(fieldSeparator)" & (name of aTerminal as text)
                end repeat
            end repeat
        end repeat
        set previousDelimiters to AppleScript's text item delimiters
        set AppleScript's text item delimiters to "\(recordSeparator)"
        set joinedOutput to outputRecords as text
        set AppleScript's text item delimiters to previousDelimiters
        return joinedOutput
    end tell
    """

    let output = try runAppleScript(script)
    if output.isEmpty {
        return []
    }

    return output
        .components(separatedBy: recordSeparator)
        .compactMap { record in
            let fields = record.components(separatedBy: fieldSeparator)
            guard fields.count == 3 else {
                return nil
            }

            return LiveGhosttyTerminal(id: fields[0], workingDirectory: fields[1], title: fields[2])
        }
}

private func focusedGhosttyTerminalID() throws -> String {
    let script = """
    tell application "Ghostty"
        if not (it is running) then return ""
        return id of focused terminal of selected tab of front window as text
    end tell
    """

    return try runAppleScript(script)
}

private func runAppleScript(_ script: String) throws -> String {
    let task = Process()
    task.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
    task.arguments = ["-e", script]

    let outputPipe = Pipe()
    let errorPipe = Pipe()
    task.standardOutput = outputPipe
    task.standardError = errorPipe

    try task.run()
    task.waitUntilExit()

    let output = String(data: outputPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
        .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

    guard task.terminationStatus == 0 else {
        let stderr = String(data: errorPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let message = stderr.isEmpty ? "AppleScript command failed." : stderr
        throw NSError(
            domain: "TerminalJumpServiceTests",
            code: Int(task.terminationStatus),
            userInfo: [NSLocalizedDescriptionKey: message]
        )
    }

    return output
}
