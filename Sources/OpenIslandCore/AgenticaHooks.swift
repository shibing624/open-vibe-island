import Foundation

/// The eleven events on agentica's external shell-hook wire.
///
/// Names are agentica's own (`agentica/shell_hooks/config.py`
/// `SHELL_HOOK_EVENTS`) and are dotted rather than CamelCase, so they are not
/// interchangeable with the Claude-family event names.
///
/// Only the two `needs.approval` / `needs.input` events are requests: the hook
/// may print one JSON document on stdout and agentica races that reply against
/// the answer typed in the terminal. Everything else is a fire-and-forget notice,
/// including `needs.resolved`, which reports the outcome of a race that is over.
public enum AgenticaHookEventName: String, Codable, Sendable {
    case runStarted = "run.started"
    case runCompleted = "run.completed"
    case runFailed = "run.failed"
    case runCancelled = "run.cancelled"
    case toolStarted = "tool.started"
    case toolCompleted = "tool.completed"
    case sessionStarted = "session.started"
    case sessionEnded = "session.ended"
    case needsApproval = "needs.approval"
    case needsInput = "needs.input"
    case needsResolved = "needs.resolved"

    /// Whether agentica reads a reply from the hook's stdout for this event.
    public var expectsReply: Bool {
        switch self {
        case .needsApproval, .needsInput:
            true
        case .runStarted, .runCompleted, .runFailed, .runCancelled,
             .toolStarted, .toolCompleted, .sessionStarted, .sessionEnded, .needsResolved:
            false
        }
    }
}

/// A decision agentica accepts back on an approval request.
///
/// Mirrors `agentica.notify.wire.ALLOWED_DECISIONS`. Anything outside this set
/// is treated by agentica as "no decision" rather than being coerced, so the
/// vocabulary is not ours to extend.
public enum AgenticaHookDecision: String, Codable, Sendable {
    case allow
    case deny
    case allowPrefix = "allow_prefix"
    case denyPrefix = "deny_prefix"
}

/// Who ended a `needs.*` race, as reported by `needs.resolved`.
public enum AgenticaHookDecider: String, Codable, Sendable {
    case terminal
    case hook
    case cancelled
}

/// The single JSON document a hook may print back to agentica.
///
/// `request_id` is not optional in practice: agentica's `parse_reply` drops any
/// reply whose `request_id` does not match the request it sent, so a directive
/// without one is silently ignored. That failure would look exactly like "the
/// user never answered", which is why the two reply cases are only reachable
/// through factories that demand the id — the compiler refuses to let a caller
/// forget it.
public struct AgenticaHookDirective: Equatable, Codable, Sendable {
    public var requestID: String?
    public var decision: AgenticaHookDecision?
    public var answer: String?

    /// Print nothing: agentica falls back to the terminal prompt.
    public static let noDecision = AgenticaHookDirective()

    public static func decision(
        _ decision: AgenticaHookDecision,
        requestID: String
    ) -> AgenticaHookDirective {
        AgenticaHookDirective(requestID: requestID, decision: decision)
    }

    public static func answer(_ answer: String, requestID: String) -> AgenticaHookDirective {
        AgenticaHookDirective(requestID: requestID, answer: answer)
    }

    private init(
        requestID: String? = nil,
        decision: AgenticaHookDecision? = nil,
        answer: String? = nil
    ) {
        self.requestID = requestID
        self.decision = decision
        self.answer = answer
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        requestID = try container.decodeIfPresent(String.self, forKey: .requestID)
        decision = try container.decodeIfPresent(AgenticaHookDecision.self, forKey: .decision)
        answer = try container.decodeIfPresent(String.self, forKey: .answer)
    }

    /// Whether this directive carries something agentica could act on.
    public var isEmpty: Bool {
        decision == nil && answer == nil
    }

    private enum CodingKeys: String, CodingKey {
        case requestID = "request_id"
        case decision
        case answer
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(requestID, forKey: .requestID)
        try container.encodeIfPresent(decision, forKey: .decision)
        try container.encodeIfPresent(answer, forKey: .answer)
    }
}

/// Process identity agentica attaches to every payload.
///
/// Mirrors the consumed half of `agentica/notify/transport.py` `build_transport`.
/// agentica also sends `ppid` and an attach endpoint; neither is modelled because
/// Open Island tracks agentica rows by event activity and does not implement
/// attaching to a running agent. Wiring process-based liveness later would start
/// by adding `ppid` back here.
public struct AgenticaHookTransport: Equatable, Codable, Sendable {
    public var cwd: String?
    public var tty: String?

    public init(cwd: String? = nil, tty: String? = nil) {
        self.cwd = cwd
        self.tty = tty
    }
}

/// The document agentica hands the hook on stdin, plus the terminal context the
/// hook binary resolves locally.
///
/// `hookEventName` and `sessionID` are the only guaranteed fields: agentica
/// always sends a session id, falling back to a per-process UUID. Everything else
/// is omitted rather than sent as null when empty
/// (`agentica/shell_hooks/protocol.py`), so a missing key and an empty string are
/// genuinely different states.
///
/// This models the fields Open Island actually reads, not the whole wire.
/// agentica also sends `run_id`, `agent_name`, `duration_seconds`, `had_response`,
/// `title`, and — on `session.started` — `model`, `profile`, `permission_mode` and
/// `transcript_path`. The model badge would be the obvious next use for those, but
/// the existing badge path is `ClaudeSessionMetadata`, which is Claude-shaped;
/// agentica needs a source-neutral one first.
public struct AgenticaHookPayload: Equatable, Codable, Sendable {
    public var hookEventName: AgenticaHookEventName
    public var sessionID: String
    public var transport: AgenticaHookTransport?
    public var cwd: String?
    /// Correlates a `needs.*` request with its reply and its `needs.resolved`.
    public var requestID: String?
    /// The run's anchor text: the user's message on an ordinary turn, the goal
    /// objective in a goal-driven session. Not "what the user just typed".
    public var prompt: String?
    public var options: [String]?

    // run.* notices
    public var reason: String?
    public var error: String?
    public var answer: String?

    // tool.* notices, and the metadata slice of needs.approval
    public var toolName: String?
    public var toolCallID: String?
    public var preview: String?
    public var ok: Bool?

    // needs.approval / needs.input
    public var question: String?
    public var similarLabel: String?

    /// `session.started` only: `"startup"` or `"resume"`.
    public var source: String?

    // needs.resolved
    public var decidedBy: AgenticaHookDecider?
    public var decision: AgenticaHookDecision?

    // Resolved by the hook binary, not sent by agentica.
    public var terminalApp: String?
    public var terminalSessionID: String?
    public var terminalTTY: String?
    public var terminalTitle: String?

    private enum CodingKeys: String, CodingKey {
        case hookEventName = "hook_event_name"
        case sessionID = "session_id"
        case transport
        case cwd
        case requestID = "request_id"
        case prompt
        case options
        case reason
        case error
        case answer
        case toolName = "tool_name"
        case toolCallID = "tool_call_id"
        case preview
        case ok
        case question
        case similarLabel = "similar_label"
        case source
        case decidedBy = "decided_by"
        case decision
        case terminalApp = "terminal_app"
        case terminalSessionID = "terminal_session_id"
        case terminalTTY = "terminal_tty"
        case terminalTitle = "terminal_title"
    }

    public init(
        hookEventName: AgenticaHookEventName,
        sessionID: String,
        transport: AgenticaHookTransport? = nil,
        cwd: String? = nil,
        requestID: String? = nil,
        prompt: String? = nil,
        options: [String]? = nil,
        reason: String? = nil,
        error: String? = nil,
        answer: String? = nil,
        toolName: String? = nil,
        toolCallID: String? = nil,
        preview: String? = nil,
        ok: Bool? = nil,
        question: String? = nil,
        similarLabel: String? = nil,
        source: String? = nil,
        decidedBy: AgenticaHookDecider? = nil,
        decision: AgenticaHookDecision? = nil,
        terminalApp: String? = nil,
        terminalSessionID: String? = nil,
        terminalTTY: String? = nil,
        terminalTitle: String? = nil
    ) {
        self.hookEventName = hookEventName
        self.sessionID = sessionID
        self.transport = transport
        self.cwd = cwd
        self.requestID = requestID
        self.prompt = prompt
        self.options = options
        self.reason = reason
        self.error = error
        self.answer = answer
        self.toolName = toolName
        self.toolCallID = toolCallID
        self.preview = preview
        self.ok = ok
        self.question = question
        self.similarLabel = similarLabel
        self.source = source
        self.decidedBy = decidedBy
        self.decision = decision
        self.terminalApp = terminalApp
        self.terminalSessionID = terminalSessionID
        self.terminalTTY = terminalTTY
        self.terminalTitle = terminalTitle
    }
}

public extension AgenticaHookPayload {
    /// Namespace prefix so an agentica session can never collide with a session
    /// id minted by another CLI, and so the source is obvious while debugging.
    static let sessionIDPrefix = "agentica-"

    var workingDirectory: String {
        cwd ?? transport?.cwd ?? FileManager.default.homeDirectoryForCurrentUser.path
    }

    var workspaceName: String {
        WorkspaceNameResolver.workspaceName(for: workingDirectory)
    }

    var resolvedSessionID: String {
        Self.sessionIDPrefix + sessionID
    }

    var sessionTitle: String {
        "Agentica · \(workspaceName)"
    }

    var defaultJumpTarget: JumpTarget {
        JumpTarget(
            terminalApp: terminalApp ?? "Terminal",
            workspaceName: workspaceName,
            paneTitle: terminalTitle ?? "Agentica \(workspaceName)",
            workingDirectory: workingDirectory,
            terminalSessionID: terminalSessionID,
            terminalTTY: terminalTTY ?? transport?.tty
        )
    }

    var promptPreview: String? {
        clipped(prompt)
    }

    var answerPreview: String? {
        clipped(answer)
    }

    /// The tool line for the island's activity row, e.g. `read_file a.py`.
    ///
    /// agentica sanitizes `preview` before sending it, so it is safe to display
    /// as-is; the raw tool arguments are never on this wire.
    var toolActivity: String? {
        guard let toolName, !toolName.isEmpty else { return clipped(preview) }
        guard let detail = clipped(preview) else { return toolName }
        return "\(toolName) \(detail)"
    }

    /// Human-facing one-liner for the island row.
    ///
    /// `run.completed` ends a *turn*, and in a goal-driven session that means the
    /// whole goal: agentica defers the per-lap completions and releases exactly
    /// one when the goal finishes. So this never needs to guess whether more laps
    /// are coming. `run.failed` and `run.cancelled` are *not* deferred, so a
    /// failing lap reports immediately even if the goal carries on — which is the
    /// only honest option, because `goal.*` is deliberately kept off this wire and
    /// a consumer therefore cannot know a goal is driving.
    var implicitSummary: String {
        switch hookEventName {
        case .runStarted:
            return promptPreview.map { "Prompt: \($0)" } ?? "Agentica started a run in \(workspaceName)."
        case .runCompleted:
            return answerPreview
                ?? promptPreview.map { "Finished: \($0)" }
                ?? "Agentica completed the run."
        case .runFailed:
            let detail = clipped(error) ?? clipped(reason)
            return detail.map { "Agentica run failed: \($0)" } ?? "Agentica run failed."
        case .runCancelled:
            let detail = clipped(reason)
            return detail.map { "Agentica run cancelled: \($0)" } ?? "Agentica run was cancelled."
        case .toolStarted:
            return toolActivity ?? "Agentica is running a tool."
        case .toolCompleted:
            if ok == false {
                let detail = clipped(error)
                let name = toolName ?? "tool"
                return detail.map { "\(name) failed: \($0)" } ?? "\(name) failed."
            }
            return toolActivity ?? "Agentica finished a tool."
        case .sessionStarted:
            return source == "resume"
                ? "Agentica resumed a session in \(workspaceName)."
                : "Agentica started in \(workspaceName)."
        case .sessionEnded:
            return clipped(reason).map { "Agentica session ended: \($0)" } ?? "Agentica session ended."
        case .needsApproval:
            return approvalTitle
        case .needsInput:
            return questionTitle
        case .needsResolved:
            return "Agentica request resolved."
        }
    }

    var approvalTitle: String {
        if let question = clipped(question) {
            return question
        }

        if let toolName, !toolName.isEmpty {
            return "Allow \(toolName)"
        }

        return "Agentica needs approval"
    }

    var approvalSummary: String {
        clipped(preview)
            ?? clipped(similarLabel)
            ?? "Agentica is waiting for approval to continue."
    }

    var questionTitle: String {
        clipped(question) ?? clipped(prompt) ?? "Agentica has a question"
    }

    /// The question rendered for the island's answer card.
    ///
    /// agentica's `options` are plain strings chosen by the tool itself, so they
    /// are offered as-is; a freeform slot is always appended because the reply
    /// on this wire is free text, not an index into the list.
    var questionPrompt: QuestionPrompt {
        let optionLabels = (options ?? []).filter { !$0.isEmpty }
        guard !optionLabels.isEmpty else {
            return QuestionPrompt(title: questionTitle, options: [])
        }

        return QuestionPrompt(
            id: UUID(),
            title: questionTitle,
            questions: [
                QuestionPromptItem(
                    question: questionTitle,
                    header: "Agentica",
                    options: optionLabels.map { QuestionOption(label: $0) }
                )
            ]
        )
    }

    func withRuntimeContext(environment: [String: String]) -> AgenticaHookPayload {
        withRuntimeContext(
            environment: environment,
            currentTTYProvider: { HookTerminalContext.currentTTY() },
            terminalLocatorProvider: { HookTerminalContext.locator(for: $0) }
        )
    }

    /// Fills in which terminal this run belongs to.
    ///
    /// The TTY comes from agentica's `transport` block when it is there: agentica
    /// reads it from the agent's own stdin, which is the authoritative answer.
    /// Only the terminal *app* and its pane identifier have to be resolved
    /// locally, because those are facts about this machine's UI rather than about
    /// the agent process.
    func withRuntimeContext(
        environment: [String: String],
        currentTTYProvider: () -> String?,
        terminalLocatorProvider: (String) -> (sessionID: String?, tty: String?, title: String?)
    ) -> AgenticaHookPayload {
        var payload = self

        if payload.terminalApp == nil {
            payload.terminalApp = HookTerminalContext.inferTerminalApp(from: environment)
        }

        if payload.terminalTTY == nil {
            payload.terminalTTY = transport?.tty ?? currentTTYProvider()
        }

        guard HookTerminalContext.supportsFocusedWindowLocator(payload.terminalApp),
              let terminalApp = payload.terminalApp else {
            return payload
        }

        let locator = terminalLocatorProvider(terminalApp)
        payload.terminalSessionID = payload.terminalSessionID ?? locator.sessionID
        payload.terminalTTY = payload.terminalTTY ?? locator.tty
        payload.terminalTitle = payload.terminalTitle ?? locator.title
        return payload
    }

    private func clipped(_ value: String?, limit: Int = 110) -> String? {
        guard let value else {
            return nil
        }

        let collapsed = value
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\t", with: " ")
            .split(separator: " ", omittingEmptySubsequences: true)
            .joined(separator: " ")

        guard !collapsed.isEmpty else {
            return nil
        }

        guard collapsed.count > limit else {
            return collapsed
        }

        let endIndex = collapsed.index(collapsed.startIndex, offsetBy: limit - 1)
        return "\(collapsed[..<endIndex])…"
    }
}

/// Turns a bridge response into the bytes agentica reads from the hook's stdout.
public enum AgenticaHookOutputEncoder {
    /// `nil` means "print nothing", which agentica reads as "no decision" and
    /// falls back to the terminal prompt. That is the correct fail-open shape
    /// for every notice event and for a request the desktop declined to answer.
    public static func standardOutput(for response: BridgeResponse) throws -> Data? {
        guard case let .agenticaHookDirective(directive) = response, !directive.isEmpty else {
            return nil
        }

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        var data = try encoder.encode(directive)
        data.append(contentsOf: Data("\n".utf8))
        return data
    }
}
