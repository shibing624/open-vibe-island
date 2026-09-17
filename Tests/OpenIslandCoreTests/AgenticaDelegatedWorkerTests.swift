import Foundation
import Testing
@testable import OpenIslandCore

/// The agentica `delegate` tool launches a whole other `agentica --query --print`
/// process per delegated task. Each of those is a top-level CLI that wires its
/// own hook egress, so without a discriminator the island grows one phantom
/// "Agentica" row per worker and rings on every one of its runs.
///
/// agentica marks those processes with `AGENTICA_DELEGATE_DEPTH` (0 = user
/// started, 1 = delegated by a session; `delegate_tool.py` sets depth+1 and the
/// child inherits its environment, including the hook processes it spawns).
/// That number is protocol data agentica itself maintains — the island reads it,
/// it does not guess.
struct AgenticaDelegatedWorkerTests {

    // MARK: - Wire format

    @Test
    func runtimeContextMarksDelegatedWorkers() {
        let payload = AgenticaHookPayload(
            hookEventName: .runStarted,
            sessionID: "worker-session"
        )

        // A user-started session: no depth variable, or depth 0.
        let top = payload.withRuntimeContext(environment: [:])
        #expect(top.isDelegatedWorker == false)

        let zeroDepth = payload.withRuntimeContext(environment: [
            "AGENTICA_DELEGATE_DEPTH": "0",
        ])
        #expect(zeroDepth.isDelegatedWorker == false)

        // A process spawned by the delegate tool: depth >= 1.
        let delegated = payload.withRuntimeContext(environment: [
            "AGENTICA_DELEGATE_DEPTH": "1",
        ])
        #expect(delegated.isDelegatedWorker == true)
    }

    // MARK: - Bridge behavior

    /// The decisive test: a delegated worker's hook events create no session and
    /// ring no bell, while the same event from a user-started session does.
    @Test
    func bridgeDropsDelegatedWorkerEvents() async throws {
        let socketURL = BridgeSocketLocation.uniqueTestURL()
        let server = BridgeServer(socketURL: socketURL)
        try server.start()
        defer { server.stop() }

        let observer = LocalBridgeClient(socketURL: socketURL)
        let stream = try observer.connect()
        defer { observer.disconnect() }

        let collector = AgentEventCollector()
        let collectionTask = Task {
            do {
                for try await event in stream {
                    await collector.append(event)
                }
            } catch {}
        }
        defer { collectionTask.cancel() }

        try await observer.send(.registerClient(role: .observer))

        let worker = AgenticaHookPayload(
            hookEventName: .runStarted,
            sessionID: "worker-1"
        ).withRuntimeContext(environment: ["AGENTICA_DELEGATE_DEPTH": "1"])

        let user = AgenticaHookPayload(
            hookEventName: .runStarted,
            sessionID: "user-1"
        ).withRuntimeContext(environment: [:])

        _ = try BridgeCommandClient(socketURL: socketURL).send(.processAgenticaHook(worker))
        _ = try BridgeCommandClient(socketURL: socketURL).send(.processAgenticaHook(user))

        var received: [AgentEvent] = []
        for _ in 0..<100 {
            received = await collector.snapshot()
            let sessionIDs = received.compactMap { event -> String? in
                if case let .sessionStarted(started) = event { return started.sessionID }
                return nil
            }
            if sessionIDs.contains("agentica-user-1") { break }
            try await Task.sleep(for: .milliseconds(50))
        }

        let sessionIDs = received.compactMap { event -> String? in
            if case let .sessionStarted(started) = event { return started.sessionID }
            return nil
        }

        // The delegated worker must not create a session; the user's session must.
        #expect(!sessionIDs.contains("agentica-worker-1"))
        #expect(sessionIDs.contains("agentica-user-1"))
    }
}

private actor AgentEventCollector {
    private var events: [AgentEvent] = []

    func append(_ event: AgentEvent) {
        events.append(event)
    }

    func snapshot() -> [AgentEvent] {
        events
    }
}
