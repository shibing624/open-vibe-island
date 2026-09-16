import Foundation

/// The six events on agentica's external shell-hook wire.
///
/// Names are agentica's own (`agentica/shell_hooks/config.py`
/// `SHELL_HOOK_EVENTS`) and are dotted rather than CamelCase, so they are not
/// interchangeable with the Claude-family event names.
///
/// Four are fire-and-forget notices. The two `needs.*` events are requests: the
/// hook may print one JSON document on stdout and agentica races that reply
/// against the answer typed in the terminal.
public enum AgenticaHookEventName: String, Codable, Sendable {
    case runStarted = "run.started"
    case runCompleted = "run.completed"
    case runFailed = "run.failed"
    case runCancelled = "run.cancelled"
    case needsApproval = "needs.approval"
    case needsInput = "needs.input"

    /// Whether agentica reads a reply from the hook's stdout for this event.
    public var expectsReply: Bool {
        switch self {
        case .needsApproval, .needsInput:
            true
        case .runStarted, .runCompleted, .runFailed, .runCancelled:
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

/// The single JSON document a hook may print back to agentica.
///
/// Optional fields are omitted rather than encoded as `null`: agentica reads one
/// key per event and an unexpected shape costs a decision.
public struct AgenticaHookDirective: Equatable, Codable, Sendable {
    public var decision: AgenticaHookDecision?
    public var answer: String?

    public init(decision: AgenticaHookDecision? = nil, answer: String? = nil) {
        self.decision = decision
        self.answer = answer
    }

    private enum CodingKeys: String, CodingKey {
        case decision
        case answer
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(decision, forKey: .decision)
        try container.encodeIfPresent(answer, forKey: .answer)
    }
}

/// The document agentica hands the hook on stdin, plus the terminal context the
/// hook binary resolves locally.
///
/// Every field except `hookEventName` is optional because agentica omits empty
/// values instead of sending nulls (`agentica/shell_hooks/protocol.py`).
public struct AgenticaHookPayload: Equatable, Codable, Sendable {
    public var hookEventName: AgenticaHookEventName
    public var sessionID: String?
    public var cwd: String?
    public var runID: String?
    /// The run's anchor text: the user's message on an ordinary turn, the goal
    /// objective in a goal-driven session. Not "what the user just typed".
    public var prompt: String?
    public var options: [String]?

    // run.* notices
    public var agentName: String?
    public var durationSeconds: Double?
    public var hadResponse: Bool?
    public var reason: String?
    public var error: String?
    public var answer: String?
    public var title: String?

    // needs.approval
    public var toolName: String?
    public var toolCallID: String?
    public var question: String?
    public var preview: String?
    public var similarLabel: String?

    // Resolved by the hook binary, not sent by agentica.
    public var terminalApp: String?
    public var terminalSessionID: String?
    public var terminalTTY: String?
    public var terminalTitle: String?

    private enum CodingKeys: String, CodingKey {
        case hookEventName = "hook_event_name"
        case sessionID = "session_id"
        case cwd
        case runID = "run_id"
        case prompt
        case options
        case agentName = "agent_name"
        case durationSeconds = "duration_seconds"
        case hadResponse = "had_response"
        case reason
        case error
        case answer
        case title
        case toolName = "tool_name"
        case toolCallID = "tool_call_id"
        case question
        case preview
        case similarLabel = "similar_label"
        case terminalApp = "terminal_app"
        case terminalSessionID = "terminal_session_id"
        case terminalTTY = "terminal_tty"
        case terminalTitle = "terminal_title"
    }

    public init(
        hookEventName: AgenticaHookEventName,
        sessionID: String? = nil,
        cwd: String? = nil,
        runID: String? = nil,
        prompt: String? = nil,
        options: [String]? = nil,
        agentName: String? = nil,
        durationSeconds: Double? = nil,
        hadResponse: Bool? = nil,
        reason: String? = nil,
        error: String? = nil,
        answer: String? = nil,
        title: String? = nil,
        toolName: String? = nil,
        toolCallID: String? = nil,
        question: String? = nil,
        preview: String? = nil,
        similarLabel: String? = nil,
        terminalApp: String? = nil,
        terminalSessionID: String? = nil,
        terminalTTY: String? = nil,
        terminalTitle: String? = nil
    ) {
        self.hookEventName = hookEventName
        self.sessionID = sessionID
        self.cwd = cwd
        self.runID = runID
        self.prompt = prompt
        self.options = options
        self.agentName = agentName
        self.durationSeconds = durationSeconds
        self.hadResponse = hadResponse
        self.reason = reason
        self.error = error
        self.answer = answer
        self.title = title
        self.toolName = toolName
        self.toolCallID = toolCallID
        self.question = question
        self.preview = preview
        self.similarLabel = similarLabel
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
        cwd ?? FileManager.default.homeDirectoryForCurrentUser.path
    }

    var workspaceName: String {
        WorkspaceNameResolver.workspaceName(for: workingDirectory)
    }

    /// The island's session id.
    ///
    /// `session_id` is optional on the wire — a run dispatched without a live
    /// `Agent` carries none — so the working directory is the fallback key. That
    /// merges concurrent runs in one directory into a single row, which is
    /// strictly better than the alternative of dropping the event.
    var resolvedSessionID: String {
        if let sessionID, !sessionID.isEmpty {
            return Self.sessionIDPrefix + sessionID
        }

        return Self.sessionIDPrefix + "cwd-" + workingDirectory
    }

    var sessionTitle: String {
        "Agentica · \(workspaceName)"
    }

    var defaultJumpTarget: JumpTarget {
        JumpTarget(
            terminalApp: terminalApp ?? "Terminal",
            workspaceName: workspaceName,
            paneTitle: terminalTitle ?? "Agentica \(workspaceName)",
            workingDirectory: cwd,
            terminalSessionID: terminalSessionID,
            terminalTTY: terminalTTY
        )
    }

    var promptPreview: String? {
        clipped(prompt)
    }

    var answerPreview: String? {
        clipped(answer)
    }

    /// Human-facing one-liner for the island row.
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
        case .needsApproval:
            return approvalTitle
        case .needsInput:
            return questionTitle
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

    /// agentica also accepts `allow_prefix` / `deny_prefix`, which apply the
    /// decision to every similar call. Open Island does not offer them: the
    /// permission card has exactly two actions, and a decision that silently
    /// covers future calls is not something to infer from a two-button tap.
    func withRuntimeContext(environment: [String: String]) -> AgenticaHookPayload {
        withRuntimeContext(
            environment: environment,
            currentTTYProvider: { HookTerminalContext.currentTTY() },
            terminalLocatorProvider: { HookTerminalContext.locator(for: $0) }
        )
    }

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
            payload.terminalTTY = currentTTYProvider()
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
        guard case let .agenticaHookDirective(directive) = response else {
            return nil
        }

        guard directive.decision != nil || directive.answer != nil else {
            return nil
        }

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        var data = try encoder.encode(directive)
        data.append(contentsOf: Data("\n".utf8))
        return data
    }
}
