import Foundation

/// The agentica-shaped slice of session state, mirroring what
/// `PiSessionMetadata` does for the Pi family.
///
/// Fields exist only where agentica's wire actually carries them
/// (`AgenticaHookPayload`): `tool.*` carries the tool name and a preview that
/// agentica has already sanitized, `run.started` carries the anchor prompt,
/// and `run.completed` carries the answer. Nothing here is recovered from
/// prose — `implicitSummary` renders these same facts into a sentence for the
/// row, and reading the sentence back apart would be guessing at something the
/// protocol already states.
///
/// `model` and `transcriptPath` are deliberately absent even though the other
/// agents model them: agentica does send `model` and `transcript_path` on
/// `session.started`, but the badge that would consume them is currently
/// Claude-shaped, so adding the fields here would create a second unused
/// carrier rather than a feature.
public struct AgenticaSessionMetadata: Equatable, Codable, Sendable {
    /// The run's anchor prompt, captured once and never overwritten.
    public var initialUserPrompt: String?
    public var lastUserPrompt: String?
    /// The agent's answer, from `run.completed`.
    public var lastAssistantMessage: String?
    /// Tool currently executing, from `tool.started`. Cleared by every event
    /// that means "no tool is running now".
    public var currentTool: String?
    /// agentica-sanitized argument preview for `currentTool`.
    public var currentToolInputPreview: String?

    public init(
        initialUserPrompt: String? = nil,
        lastUserPrompt: String? = nil,
        lastAssistantMessage: String? = nil,
        currentTool: String? = nil,
        currentToolInputPreview: String? = nil
    ) {
        self.initialUserPrompt = initialUserPrompt
        self.lastUserPrompt = lastUserPrompt
        self.lastAssistantMessage = lastAssistantMessage
        self.currentTool = currentTool
        self.currentToolInputPreview = currentToolInputPreview
    }

    public var isEmpty: Bool {
        initialUserPrompt == nil
            && lastUserPrompt == nil
            && lastAssistantMessage == nil
            && currentTool == nil
            && currentToolInputPreview == nil
    }

    /// Field-level merge, so a `tool.started` cannot erase the prompt that
    /// `run.started` recorded.
    ///
    /// `initialUserPrompt` is anchored on first sight and never overwritten;
    /// every other field prefers the incoming value and falls back to what was
    /// already known. `clearsCurrentTool` drops the active tool and its preview
    /// instead of carrying them forward.
    public static func merged(
        existing: AgenticaSessionMetadata?,
        update: AgenticaSessionMetadata,
        clearsCurrentTool: Bool = false
    ) -> AgenticaSessionMetadata {
        AgenticaSessionMetadata(
            initialUserPrompt: existing?.initialUserPrompt ?? update.initialUserPrompt ?? update.lastUserPrompt,
            lastUserPrompt: update.lastUserPrompt ?? existing?.lastUserPrompt,
            lastAssistantMessage: update.lastAssistantMessage ?? existing?.lastAssistantMessage,
            currentTool: clearsCurrentTool ? nil : (update.currentTool ?? existing?.currentTool),
            currentToolInputPreview: clearsCurrentTool
                ? nil
                : (update.currentToolInputPreview ?? existing?.currentToolInputPreview)
        )
    }
}
