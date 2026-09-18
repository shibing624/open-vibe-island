import Foundation
import Testing
@testable import OpenIslandApp

/// The two failure modes this helper exists to prevent: a child that outlives
/// its deadline, and a child that writes more than a pipe buffer holds.
@Suite(.serialized)
struct BoundedProcessTests {
    /// The deadlock this replaced: `waitUntilExit()` before reading means the
    /// child blocks writing once the ~64 KB pipe buffer fills while the parent
    /// blocks waiting for it to exit. 512 KB is comfortably past that, and is
    /// realistic — `wezterm cli list --format json` on a busy server and the
    /// Ghostty window-walking AppleScript both get large.
    @Test
    func readsOutputLargerThanThePipeBuffer() throws {
        let payloadSize = 512 * 1024
        let output = try #require(
            BoundedProcess.run(
                executableURL: URL(fileURLWithPath: "/bin/sh"),
                arguments: ["-c", "yes abcdefghij | head -c \(payloadSize)"],
                timeout: 20
            )
        )

        // Assert the byte count, not merely that something came back: a
        // truncated read is exactly what a partially drained pipe looks like.
        #expect(output.count == payloadSize)
    }

    /// A child that ignores SIGTERM must still not outlive the call — this is
    /// the `osascript` blocked on a TCC consent prompt case, which is why the
    /// timeout path escalates to SIGKILL.
    @Test
    func killsAChildThatOutlivesItsDeadlineAndIgnoresSIGTERM() {
        let start = Date()
        let result = BoundedProcess.execute(
            executableURL: URL(fileURLWithPath: "/bin/sh"),
            arguments: ["-c", "trap '' TERM; sleep 30"],
            timeout: 0.5
        )
        let elapsed = Date().timeIntervalSince(start)

        #expect(result.timedOut)
        #expect(!result.succeeded)
        #expect(result.exitStatus == nil)
        // 0.5s deadline + up to two 0.2s escalation waits, with slack for CI.
        #expect(elapsed < 5)
    }

    @Test
    func reportsExitStatusAndStreamsSeparately() {
        let result = BoundedProcess.execute(
            executableURL: URL(fileURLWithPath: "/bin/sh"),
            arguments: ["-c", "echo out; echo err 1>&2; exit 3"]
        )

        #expect(result.exitStatus == 3)
        #expect(!result.succeeded)
        #expect(!result.timedOut)
        #expect(result.standardOutput == "out")
        // stderr is kept even on failure: it is the only place a tool says why
        // it refused, and the AppleScript runner surfaces it to the user.
        #expect(result.standardError == "err")
    }

    @Test
    func aFailedLaunchIsReportedRatherThanThrown() {
        let result = BoundedProcess.execute(
            executableURL: URL(fileURLWithPath: "/nonexistent/binary"),
            arguments: []
        )

        #expect(result.exitStatus == nil)
        #expect(!result.succeeded)
        #expect(!result.timedOut)
    }

    @Test
    func runReturnsNilForANonZeroExit() {
        #expect(BoundedProcess.run(
            executableURL: URL(fileURLWithPath: "/bin/sh"),
            arguments: ["-c", "echo ignored; exit 1"]
        ) == nil)
    }

    @Test
    func succeedsReportsTheExitStatus() {
        #expect(BoundedProcess.succeeds(
            executableURL: URL(fileURLWithPath: "/bin/sh"),
            arguments: ["-c", "exit 0"]
        ))
        #expect(!BoundedProcess.succeeds(
            executableURL: URL(fileURLWithPath: "/bin/sh"),
            arguments: ["-c", "exit 1"]
        ))
    }
}
