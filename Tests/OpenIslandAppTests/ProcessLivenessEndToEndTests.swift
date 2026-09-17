import Foundation
import Testing
@testable import OpenIslandApp
import OpenIslandCore

/// Drives the decisive liveness path against **real** processes.
///
/// The `SessionState` tests pin the state transition, but they cannot answer the
/// question that decides whether this works in practice: does a process that was
/// really spawned and really killed read as gone? So these spawn `/bin/sleep`,
/// kill it, and run the same coordinator entry point the 2-second wake runs.
///
/// Note the session box: `stateAccessor`/`stateUpdater` are closures, so a local
/// `var state` would be captured by value and the coordinator's write-back would
/// never be observable.
@MainActor
@Suite(.serialized)
struct ProcessLivenessEndToEndTests {
    @Test
    func exitedProcessTakesItsSessionOffTheIsland() throws {
        let doomedPID = try spawnThenKill()

        let coordinator = ProcessMonitoringCoordinator()
        let state = SessionStateBox(SessionState(sessions: [hookManagedSession(id: "dead-1")]))
        coordinator.stateAccessor = { state.value }
        coordinator.stateUpdater = { state.value = $0 }

        coordinator.recordConfirmedProcessIDsForTesting([
            snapshot(sessionID: "dead-1", pid: doomedPID)
        ])
        #expect(state.value.session(id: "dead-1")?.isVisibleInIsland == true)

        coordinator.reconcileConfirmedProcessLivenessForTesting()

        // The row is ended *and* removed, which is the behaviour under test: a
        // completed-but-still-listed session would read as "the island never
        // noticed".
        #expect(state.value.session(id: "dead-1") == nil)
    }

    /// The load-bearing half: a live process must never be mistaken for a dead one.
    @Test
    func liveProcessKeepsItsSession() throws {
        let alive = Process()
        alive.executableURL = URL(fileURLWithPath: "/bin/sleep")
        alive.arguments = ["30"]
        try alive.run()
        defer { alive.terminate() }

        let coordinator = ProcessMonitoringCoordinator()
        let state = SessionStateBox(SessionState(sessions: [hookManagedSession(id: "alive-1")]))
        coordinator.stateAccessor = { state.value }
        coordinator.stateUpdater = { state.value = $0 }

        coordinator.recordConfirmedProcessIDsForTesting([
            snapshot(sessionID: "alive-1", pid: Int32(alive.processIdentifier))
        ])
        coordinator.reconcileConfirmedProcessLivenessForTesting()

        #expect(state.value.session(id: "alive-1")?.isSessionEnded == false)
        #expect(state.value.session(id: "alive-1")?.isVisibleInIsland == true)
    }

    /// A session stopped on an approval must still leave, because
    /// `isVisibleInIsland` short-circuits to true for attention phases.
    @Test
    func exitedProcessEndsASessionAwaitingApproval() throws {
        let doomedPID = try spawnThenKill()

        var waiting = hookManagedSession(id: "waiting-1")
        waiting.phase = .waitingForApproval

        let coordinator = ProcessMonitoringCoordinator()
        let state = SessionStateBox(SessionState(sessions: [waiting]))
        coordinator.stateAccessor = { state.value }
        coordinator.stateUpdater = { state.value = $0 }

        coordinator.recordConfirmedProcessIDsForTesting([
            snapshot(sessionID: "waiting-1", pid: doomedPID)
        ])
        #expect(state.value.session(id: "waiting-1")?.isVisibleInIsland == true)

        coordinator.reconcileConfirmedProcessLivenessForTesting()

        #expect(state.value.session(id: "waiting-1") == nil)
    }

    /// A pid that no full reconcile has re-confirmed is not evidence: the OS
    /// recycles pids, so an old one may now name an unrelated process.
    @Test
    func unconfirmedPidIsNotTrusted() throws {
        let doomedPID = try spawnThenKill()

        let coordinator = ProcessMonitoringCoordinator()
        let state = SessionStateBox(SessionState(sessions: [hookManagedSession(id: "stale-1")]))
        coordinator.stateAccessor = { state.value }
        coordinator.stateUpdater = { state.value = $0 }

        coordinator.recordConfirmedProcessIDsForTesting(
            [snapshot(sessionID: "stale-1", pid: doomedPID)],
            confirmedAt: Date().addingTimeInterval(-3600)
        )
        coordinator.reconcileConfirmedProcessLivenessForTesting()

        #expect(state.value.session(id: "stale-1")?.isSessionEnded == false)
        #expect(state.value.session(id: "stale-1")?.isVisibleInIsland == true)
    }

    /// Sessions the island never attributed a process to must be left to the slow
    /// `processNotSeenCount` path rather than decided here.
    @Test
    func sessionsWithoutAConfirmedPidAreUntouched() {
        let coordinator = ProcessMonitoringCoordinator()
        let state = SessionStateBox(SessionState(sessions: [hookManagedSession(id: "unattributed-1")]))
        coordinator.stateAccessor = { state.value }
        coordinator.stateUpdater = { state.value = $0 }

        coordinator.reconcileConfirmedProcessLivenessForTesting()

        #expect(state.value.session(id: "unattributed-1")?.isSessionEnded == false)
    }

    // MARK: - Helpers

    private func spawnThenKill() throws -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sleep")
        process.arguments = ["30"]
        try process.run()
        let pid = Int32(process.processIdentifier)
        process.terminate()
        process.waitUntilExit()
        return pid
    }

    private func hookManagedSession(id: String) -> AgentSession {
        var session = AgentSession(
            id: id,
            title: "Claude · test",
            tool: .claudeCode,
            phase: .running,
            summary: "Working",
            updatedAt: Date()
        )
        session.isHookManaged = true
        return session
    }

    private func snapshot(
        sessionID: String,
        pid: Int32
    ) -> ActiveAgentProcessDiscovery.ProcessSnapshot {
        ActiveAgentProcessDiscovery.ProcessSnapshot(
            tool: .claudeCode,
            sessionID: sessionID,
            processID: pid,
            workingDirectory: "/tmp",
            terminalTTY: "/dev/ttys000"
        )
    }
}

@MainActor
final class SessionStateBox {
    var value: SessionState

    init(_ value: SessionState) {
        self.value = value
    }
}
