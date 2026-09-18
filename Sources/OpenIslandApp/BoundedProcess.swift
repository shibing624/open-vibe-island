import Foundation

/// Runs a short-lived child process with a deadline, draining its output while
/// it runs.
///
/// Both halves matter and the codebase had been missing one or the other:
///
/// - **Draining concurrently.** `Process.waitUntilExit()` followed by
///   `readDataToEndOfFile()` deadlocks once the child writes more than the pipe
///   buffer (~64 KB on macOS): the child blocks writing, the parent blocks
///   waiting for it to exit. `tmux list-panes -a` on a busy server and the
///   AppleScript that walks every Ghostty window both reach that size. Reading
///   on another queue while waiting means the buffer never fills up.
/// - **A deadline.** `osascript` can sit indefinitely the first time it needs
///   Automation consent, because the TCC prompt blocks the interpreter. Jump
///   work happens in a detached task, and cancelling that task cannot kill a
///   child already blocked in `waitUntilExit`, so an unbounded call is a leak
///   that survives the jump.
///
/// Terminating on timeout escalates: `SIGTERM` first, then `SIGKILL` if the
/// child ignores it, so a wedged `osascript` cannot outlive the call.
enum BoundedProcess {
    /// Default deadline for the terminal-automation helpers. Matches the value
    /// `TerminalJumpTargetResolver` already used for its AppleScript probes.
    static let defaultTimeout: TimeInterval = 3

    /// Everything observed about a finished (or abandoned) process.
    ///
    /// `standardError` is kept even on success because callers that report a
    /// failure reason need it, and it is the only place a tool like `osascript`
    /// says *why* it refused.
    struct Result {
        /// Exit status, or nil when the process could not be launched or was
        /// killed for outliving its deadline.
        let exitStatus: Int32?
        let standardOutput: String
        let standardError: String
        let timedOut: Bool

        /// True only for a process that ran to completion and reported success.
        var succeeded: Bool { exitStatus == 0 }
    }

    /// Runs `executableURL` and returns its trimmed stdout, or nil when the
    /// process could not be launched, exited non-zero, or outlived `timeout`.
    static func run(
        executableURL: URL,
        arguments: [String],
        timeout: TimeInterval = defaultTimeout
    ) -> String? {
        let result = execute(executableURL: executableURL, arguments: arguments, timeout: timeout)
        return result.succeeded ? result.standardOutput : nil
    }

    /// Runs `executableURL` and reports whether it exited zero within `timeout`.
    static func succeeds(
        executableURL: URL,
        arguments: [String],
        timeout: TimeInterval = defaultTimeout
    ) -> Bool {
        execute(executableURL: executableURL, arguments: arguments, timeout: timeout).succeeded
    }

    /// Runs `executableURL` to completion or to its deadline, whichever comes
    /// first, and reports everything observed.
    static func execute(
        executableURL: URL,
        arguments: [String],
        timeout: TimeInterval = defaultTimeout
    ) -> Result {
        let task = Process()
        task.executableURL = executableURL
        task.arguments = arguments

        let outputPipe = Pipe()
        let errorPipe = Pipe()
        task.standardOutput = outputPipe
        task.standardError = errorPipe

        // Drain both pipes on their own queues, started before the wait below.
        // This is what keeps a chatty child from blocking on a full buffer.
        let collector = OutputCollector()
        let drainGroup = DispatchGroup()
        for (pipe, isStandardOutput) in [(outputPipe, true), (errorPipe, false)] {
            drainGroup.enter()
            DispatchQueue.global(qos: .userInitiated).async {
                defer { drainGroup.leave() }
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                collector.append(data, isStandardOutput: isStandardOutput)
            }
        }

        let exitGroup = DispatchGroup()
        exitGroup.enter()
        task.terminationHandler = { _ in exitGroup.leave() }

        do {
            try task.run()
        } catch {
            // The termination handler never runs for a process that failed to
            // launch, so release the group by hand and close the write ends so
            // the drain tasks see EOF instead of hanging.
            exitGroup.leave()
            try? outputPipe.fileHandleForWriting.close()
            try? errorPipe.fileHandleForWriting.close()
            drainGroup.wait()
            return Result(
                exitStatus: nil,
                standardOutput: "",
                standardError: collector.text(isStandardOutput: false),
                timedOut: false
            )
        }

        if exitGroup.wait(timeout: .now() + timeout) == .timedOut {
            task.terminate()
            if exitGroup.wait(timeout: .now() + 0.2) == .timedOut {
                // SIGTERM was ignored — a TCC prompt does that. SIGKILL cannot be.
                kill(task.processIdentifier, SIGKILL)
                _ = exitGroup.wait(timeout: .now() + 0.2)
            }
            // Do not wait for the readers here. Killing the child does not
            // close the write end if it spawned a grandchild that inherited
            // the pipe (a shell backgrounding something, `wezterm cli` behind a
            // wrapper), so readDataToEndOfFile can block long after the process
            // we launched is gone — which would reintroduce the unbounded wait
            // this type exists to remove. Close our own handles so the readers
            // unblock on their own and return what has arrived so far; the
            // result is discarded by every caller anyway.
            try? outputPipe.fileHandleForReading.close()
            try? errorPipe.fileHandleForReading.close()
            return Result(
                exitStatus: nil,
                standardOutput: collector.text(isStandardOutput: true),
                standardError: collector.text(isStandardOutput: false),
                timedOut: true
            )
        }

        // Both write ends are closed once the child is gone, so the readers
        // have either finished or are about to see EOF.
        drainGroup.wait()

        return Result(
            exitStatus: task.terminationStatus,
            standardOutput: collector.text(isStandardOutput: true),
            standardError: collector.text(isStandardOutput: false),
            timedOut: false
        )
    }

    /// Collects pipe output from the two drain queues.
    private final class OutputCollector: @unchecked Sendable {
        private let lock = NSLock()
        private var standardOutput = Data()
        private var standardError = Data()

        func append(_ data: Data, isStandardOutput: Bool) {
            lock.lock()
            defer { lock.unlock() }
            if isStandardOutput {
                standardOutput.append(data)
            } else {
                standardError.append(data)
            }
        }

        func text(isStandardOutput: Bool) -> String {
            lock.lock()
            defer { lock.unlock() }
            let data = isStandardOutput ? standardOutput : standardError
            return String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        }
    }
}
