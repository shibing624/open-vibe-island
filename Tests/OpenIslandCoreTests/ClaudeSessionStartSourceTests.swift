import Foundation
import Testing
@testable import OpenIslandCore

/// Claude Code re-announces an existing session whenever it resumes, clears or
/// compacts context. Those hooks carry a `source`, and the island must carry it
/// through to `SessionStarted` — `SoundCueRouter` reads it to decide whether the
/// next prompt is a first prompt or a continuation.
///
/// The router's own tests cover the decision; these cover the wire, so a
/// payload field that stops being forwarded is caught here rather than only
/// showing up as an extra chime in a long session.
struct ClaudeSessionStartSourceTests {

    private func sessionStartPayload(
        sessionID: String,
        source: ClaudeSessionStartSource?
    ) -> ClaudeHookPayload {
        ClaudeHookPayload(
            cwd: "/tmp/island",
            hookEventName: .sessionStart,
            sessionID: sessionID,
            source: source
        )
    }

    /// The decisive wire test: the value Claude Code sends arrives on the
    /// emitted event, per source. A dropped or mis-mapped field fails here.
    @Test
    func claudeSessionStartCarriesItsSourceOntoTheEvent() async throws {
        let socketURL = BridgeSocketLocation.uniqueTestURL()
        let server = BridgeServer(socketURL: socketURL)
        try server.start()
        defer { server.stop() }

        let observer = LocalBridgeClient(socketURL: socketURL)
        let stream = try observer.connect()
        defer { observer.disconnect() }

        var iterator = stream.makeAsyncIterator()
        try await observer.send(.registerClient(role: .observer))

        for (index, source) in [
            ClaudeSessionStartSource.startup,
            .resume,
            .clear,
            .compact,
        ].enumerated() {
            let sessionID = "claude-source-\(index)"
            _ = try BridgeCommandClient(socketURL: socketURL).send(
                .processClaudeHook(sessionStartPayload(sessionID: sessionID, source: source))
            )

            let event = try await nextMatchingClaudeEvent(from: &iterator) { event in
                guard case let .sessionStarted(started) = event else { return false }
                return started.sessionID == sessionID
            }

            guard case let .sessionStarted(started) = event else {
                Issue.record("Expected a sessionStarted event")
                return
            }

            #expect(started.claudeMetadata?.startupSource == source)
        }
    }

    /// A `SessionStart` with no `source` — what the hooks CLI emits when an
    /// agent (or an older Claude Code) omits it — must decode to `nil` rather
    /// than being guessed into `.startup`, which would re-arm the first prompt.
    @Test
    func claudeSessionStartWithoutSourceStaysUnset() async throws {
        let socketURL = BridgeSocketLocation.uniqueTestURL()
        let server = BridgeServer(socketURL: socketURL)
        try server.start()
        defer { server.stop() }

        let observer = LocalBridgeClient(socketURL: socketURL)
        let stream = try observer.connect()
        defer { observer.disconnect() }

        var iterator = stream.makeAsyncIterator()
        try await observer.send(.registerClient(role: .observer))

        _ = try BridgeCommandClient(socketURL: socketURL).send(
            .processClaudeHook(sessionStartPayload(sessionID: "claude-no-source", source: nil))
        )

        let event = try await nextMatchingClaudeEvent(from: &iterator) { event in
            guard case let .sessionStarted(started) = event else { return false }
            return started.sessionID == "claude-no-source"
        }

        guard case let .sessionStarted(started) = event else {
            Issue.record("Expected a sessionStarted event")
            return
        }

        #expect(started.claudeMetadata?.startupSource == nil)
    }
}

private func nextMatchingClaudeEvent(
    from iterator: inout AsyncThrowingStream<AgentEvent, Error>.AsyncIterator,
    maxEvents: Int = 8,
    predicate: (AgentEvent) -> Bool
) async throws -> AgentEvent {
    for _ in 0..<maxEvents {
        guard let event = try await iterator.next() else {
            break
        }
        if predicate(event) {
            return event
        }
    }

    Issue.record("Expected matching event within \(maxEvents) events")
    throw CancellationError()
}
