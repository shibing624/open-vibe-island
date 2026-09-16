import Foundation

public struct AgenticaHookInstallerManifest: Equatable, Codable, Sendable {
    public static let fileName = "open-island-agentica-hooks-install.json"

    public var hookCommand: [String]
    public var installedAt: Date

    public init(hookCommand: [String], installedAt: Date = .now) {
        self.hookCommand = hookCommand
        self.installedAt = installedAt
    }
}

public struct AgenticaHookFileMutation: Equatable, Sendable {
    public var contents: String?
    public var changed: Bool
    public var managedHooksPresent: Bool

    public init(contents: String?, changed: Bool, managedHooksPresent: Bool) {
        self.contents = contents
        self.changed = changed
        self.managedHooksPresent = managedHooksPresent
    }
}

public enum AgenticaHookInstallerError: Error, LocalizedError {
    case unsupportedConfigShape(String)
    case foreignHookCommand(String)

    public var errorDescription: String? {
        switch self {
        case let .unsupportedConfigShape(detail):
            "Open Island could not edit ~/.agentica/config.yaml safely: \(detail) "
                + "Add the settings.hooks block by hand instead."
        case let .foreignHookCommand(command):
            "agentica's hook wire is already taken by `\(command)`. agentica runs "
                + "exactly one hook command, so installing Open Island would disable "
                + "that one. Remove it first, or install with takeover."
        }
    }
}

/// Installs Open Island into agentica's `settings.hooks` block.
///
/// ## Why this edits text instead of round-tripping a parser
///
/// `~/.agentica/config.yaml` is a hand-written file that holds every model
/// profile and plaintext API key, and agentica documents it as comment-preserving
/// (it writes with `ruamel`). libyaml — and therefore every Swift YAML binding —
/// has no comment model at all, so loading and re-serializing this file would
/// silently delete the user's comments on every install and uninstall.
///
/// So the edit is textual and scoped: only the `settings.hooks` sub-block is
/// rewritten, every other byte is copied through. The safety property that makes
/// that acceptable is that an unrecognized shape is **refused, never guessed** —
/// see `unsupportedConfigShape`. A wrong guess here would either corrupt the file
/// or, worse, write a duplicate key that makes agentica fall back to an empty
/// config and quietly lose every profile.
public enum AgenticaHookInstaller {
    /// agentica takes an argv list, not a shell string: it refuses a string
    /// rather than inventing quoting rules. So the managed hook is three
    /// elements and needs no shell quoting even though the installed binary path
    /// contains spaces.
    public static func hookCommand(for binaryPath: String) -> [String] {
        [binaryPath, "--source", "agentica"]
    }

    private static let managedBinaryNames: Set<String> = ["OpenIslandHooks", "VibeIslandHooks"]

    /// Installs the managed hook command into `settings.hooks`.
    ///
    /// `replacingForeignCommand` decides what happens when the wire is already
    /// held by someone else's command. agentica runs **exactly one** hook
    /// command, so two desktop consumers cannot share it — installing over one is
    /// disabling it. That is a choice for the user to make, not for an installer
    /// to make silently, so the default is to refuse.
    public static func installConfigYAML(
        existingText: String?,
        hookCommand: [String],
        replacingForeignCommand: Bool = false
    ) throws -> AgenticaHookFileMutation {
        let original = existingText ?? ""
        var lines = original.isEmpty ? [] : original.components(separatedBy: "\n")
        try rejectTabIndentation(lines)

        guard let settings = topLevelKey("settings", in: lines) else {
            let appended = appendSettingsBlock(to: lines, hookCommand: hookCommand)
            let text = appended.joined(separator: "\n")
            return AgenticaHookFileMutation(
                contents: text,
                changed: text != original,
                managedHooksPresent: true
            )
        }

        try rejectInlineValue(on: lines[settings.keyIndex], key: "settings")

        let childIndent = childIndentation(of: lines, region: settings.childRange)

        guard let hooks = childKey("hooks", in: lines, region: settings.childRange, indent: childIndent) else {
            lines.insert(
                contentsOf: renderHooksBlock(indent: childIndent, hookCommand: hookCommand),
                at: insertionIndex(in: lines, region: settings.childRange)
            )
            let text = lines.joined(separator: "\n")
            return AgenticaHookFileMutation(
                contents: text,
                changed: text != original,
                managedHooksPresent: true
            )
        }

        try rejectInlineValue(on: lines[hooks.keyIndex], key: "settings.hooks")

        let block = Array(lines[hooks.keyIndex..<hooks.endIndex])

        if blockReferencesManagedBinary(block) {
            // Our own block: rewrite `enabled` and `command` where they sit and
            // leave everything else — a hand-tuned `events:` gate, the comments
            // the user wrote above it — exactly as found.
            lines.replaceSubrange(
                hooks.keyIndex..<hooks.endIndex,
                with: refreshedManagedBlock(block, indent: childIndent, hookCommand: hookCommand)
            )
        } else {
            guard replacingForeignCommand else {
                throw AgenticaHookInstallerError.foreignHookCommand(
                    foreignCommandDescription(in: block) ?? "another hook command"
                )
            }

            // Taking the wire over is a full replacement: the previous owner's
            // `events:` gating described what *they* wanted to hear about, and
            // inheriting it would silently mute our own events.
            lines.replaceSubrange(
                hooks.keyIndex..<hooks.endIndex,
                with: renderHooksBlock(indent: childIndent, hookCommand: hookCommand)
            )
        }

        let text = lines.joined(separator: "\n")
        return AgenticaHookFileMutation(
            contents: text,
            changed: text != original,
            managedHooksPresent: true
        )
    }

    /// Removes the managed `settings.hooks` block.
    ///
    /// A `hooks` block that does not point at our binary is left alone: the user
    /// may run their own notifier on this wire, and agentica supports exactly one
    /// command, so deleting theirs would be silently taking the channel.
    ///
    /// The now-childless `settings:` key is deliberately kept. agentica reads a
    /// non-mapping `settings` as "no settings", so it is harmless, and removing
    /// it would mean deciding which of the surrounding comments belonged to it.
    public static func uninstallConfigYAML(existingText: String?) throws -> AgenticaHookFileMutation {
        guard let original = existingText, !original.isEmpty else {
            return AgenticaHookFileMutation(contents: nil, changed: false, managedHooksPresent: false)
        }

        var lines = original.components(separatedBy: "\n")
        try rejectTabIndentation(lines)

        guard let settings = topLevelKey("settings", in: lines) else {
            return AgenticaHookFileMutation(contents: original, changed: false, managedHooksPresent: false)
        }

        try rejectInlineValue(on: lines[settings.keyIndex], key: "settings")

        let childIndent = childIndentation(of: lines, region: settings.childRange)
        guard let hooks = childKey("hooks", in: lines, region: settings.childRange, indent: childIndent) else {
            return AgenticaHookFileMutation(contents: original, changed: false, managedHooksPresent: false)
        }

        guard blockReferencesManagedBinary(Array(lines[hooks.keyIndex..<hooks.endIndex])) else {
            return AgenticaHookFileMutation(contents: original, changed: false, managedHooksPresent: false)
        }

        lines.removeSubrange(hooks.keyIndex..<hooks.endIndex)
        let text = lines.joined(separator: "\n")
        return AgenticaHookFileMutation(
            contents: text,
            changed: text != original,
            managedHooksPresent: true
        )
    }

    /// Whether the config currently routes agentica's hook wire at our binary.
    public static func hasManagedHooks(in text: String?) -> Bool {
        guard let text, !text.isEmpty else { return false }

        let lines = text.components(separatedBy: "\n")
        guard (try? rejectTabIndentation(lines)) != nil,
              let settings = topLevelKey("settings", in: lines) else {
            return false
        }

        let childIndent = childIndentation(of: lines, region: settings.childRange)
        guard let hooks = childKey("hooks", in: lines, region: settings.childRange, indent: childIndent) else {
            return false
        }

        let block = Array(lines[hooks.keyIndex..<hooks.endIndex])
        return blockReferencesManagedBinary(block) && blockEnablesHooks(block)
    }

    /// The command holding agentica's single hook slot when it is not ours.
    ///
    /// Lets the UI say *whose* hook is in the way instead of just refusing.
    public static func foreignHookCommand(in text: String?) -> String? {
        guard let text, !text.isEmpty else { return nil }

        let lines = text.components(separatedBy: "\n")
        guard (try? rejectTabIndentation(lines)) != nil,
              let settings = topLevelKey("settings", in: lines) else {
            return nil
        }

        let childIndent = childIndentation(of: lines, region: settings.childRange)
        guard let hooks = childKey("hooks", in: lines, region: settings.childRange, indent: childIndent) else {
            return nil
        }

        let block = Array(lines[hooks.keyIndex..<hooks.endIndex])
        guard !blockReferencesManagedBinary(block) else { return nil }

        return foreignCommandDescription(in: block)
    }

    /// The block a user can paste by hand when the config shape is refused.
    public static func manualSnippet(hookCommand: [String]) -> String {
        (["settings:"] + renderHooksBlock(indent: "  ", hookCommand: hookCommand))
            .joined(separator: "\n")
    }

    // MARK: - Rendering

    private static func renderHooksBlock(indent: String, hookCommand: [String]) -> [String] {
        ["\(indent)hooks:", "\(indent)  enabled: true"]
            + renderCommand(indent: indent + "  ", hookCommand: hookCommand)
    }

    private static func renderCommand(indent: String, hookCommand: [String]) -> [String] {
        ["\(indent)command:"] + hookCommand.map { "\(indent)  - \(quote($0))" }
    }

    /// Rewrites `enabled` and `command` in place inside a block we already own,
    /// leaving every other line of it untouched.
    private static func refreshedManagedBlock(
        _ block: [String],
        indent: String,
        hookCommand: [String]
    ) -> [String] {
        var lines = block
        let entryIndent = indent + "  "
        let rendered = renderCommand(indent: entryIndent, hookCommand: hookCommand)

        if let command = childKey("command", in: lines, region: 1..<lines.count, indent: entryIndent) {
            lines.replaceSubrange(command.keyIndex..<command.endIndex, with: rendered)
        } else {
            lines.insert(contentsOf: rendered, at: 1)
        }

        // Re-scanned rather than reusing an index: the replacement above moved
        // every line after `command:`.
        if let enabled = childKey("enabled", in: lines, region: 1..<lines.count, indent: entryIndent) {
            lines[enabled.keyIndex] = "\(entryIndent)enabled: true"
        } else {
            lines.insert("\(entryIndent)enabled: true", at: 1)
        }

        return lines
    }

    private static func appendSettingsBlock(to lines: [String], hookCommand: [String]) -> [String] {
        var result = lines

        // Drop the trailing empty component produced by a file that ends in a
        // newline, so the block is appended rather than separated by a blank.
        while let last = result.last, last.trimmingCharacters(in: .whitespaces).isEmpty {
            result.removeLast()
        }

        result.append("settings:")
        result.append(contentsOf: renderHooksBlock(indent: "  ", hookCommand: hookCommand))
        result.append("")
        return result
    }

    private static func quote(_ value: String) -> String {
        let escaped = value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        return "\"\(escaped)\""
    }

    // MARK: - Structure

    private struct KeyBlock {
        /// Index of the `key:` line itself.
        let keyIndex: Int
        /// One past the last line owned by this key.
        let endIndex: Int

        var childRange: Range<Int> {
            (keyIndex + 1)..<endIndex
        }
    }

    private static func rejectTabIndentation(_ lines: [String]) throws {
        for line in lines where line.prefix(while: { $0 == " " || $0 == "\t" }).contains("\t") {
            throw AgenticaHookInstallerError.unsupportedConfigShape(
                "the file indents with tabs, which YAML does not allow."
            )
        }
    }

    /// Locates a top-level key and the extent of the block it owns.
    ///
    /// Block scalars (`|`, `>`) are skipped wholesale: their body is always
    /// indented deeper than the key, so a `foo:` inside one is text, not a key.
    private static func topLevelKey(_ name: String, in lines: [String]) -> KeyBlock? {
        var foundIndex: Int?
        var index = 0

        while index < lines.count {
            let line = lines[index]

            guard indentation(of: line) == 0, let key = mappingKey(in: line) else {
                index += 1
                continue
            }

            if let foundIndex {
                return KeyBlock(keyIndex: foundIndex, endIndex: index)
            }

            if key == name {
                foundIndex = index
            }

            if isBlockScalarHeader(line) {
                index = endOfIndentedRegion(in: lines, after: index, deeperThan: 0)
                continue
            }

            index += 1
        }

        return foundIndex.map { KeyBlock(keyIndex: $0, endIndex: lines.count) }
    }

    private static func childKey(
        _ name: String,
        in lines: [String],
        region: Range<Int>,
        indent: String
    ) -> KeyBlock? {
        let indentWidth = indent.count
        var index = region.lowerBound

        while index < region.upperBound {
            let line = lines[index]

            guard indentation(of: line) == indentWidth, let key = mappingKey(in: line) else {
                index += 1
                continue
            }

            let end = endOfIndentedRegion(in: lines, after: index, deeperThan: indentWidth)
            if key == name {
                return KeyBlock(keyIndex: index, endIndex: min(end, region.upperBound))
            }

            index = end
        }

        return nil
    }

    /// Indentation used by the children of a block, or two spaces when it has none yet.
    private static func childIndentation(of lines: [String], region: Range<Int>) -> String {
        for index in region {
            let line = lines[index]
            guard isStructuralLine(line) else { continue }

            let width = indentation(of: line)
            if width > 0 {
                return String(repeating: " ", count: width)
            }
        }

        return "  "
    }

    /// Where a new child belongs: right after the last structural line of the
    /// block, so trailing blank lines and comments that lead into the next
    /// top-level key stay where the user put them.
    private static func insertionIndex(in lines: [String], region: Range<Int>) -> Int {
        var insertion = region.lowerBound

        for index in region where isStructuralLine(lines[index]) {
            insertion = index + 1
        }

        return insertion
    }

    private static func endOfIndentedRegion(
        in lines: [String],
        after keyIndex: Int,
        deeperThan indentWidth: Int
    ) -> Int {
        var end = keyIndex + 1
        var index = keyIndex + 1

        while index < lines.count {
            let line = lines[index]

            if !isStructuralLine(line) {
                index += 1
                continue
            }

            guard indentation(of: line) > indentWidth else {
                break
            }

            index += 1
            end = index
        }

        return end
    }

    private static func rejectInlineValue(on line: String, key: String) throws {
        guard let separator = line.range(of: ":") else { return }

        let remainder = line[separator.upperBound...].trimmingCharacters(in: .whitespaces)
        guard !remainder.isEmpty, !remainder.hasPrefix("#") else { return }

        throw AgenticaHookInstallerError.unsupportedConfigShape(
            "`\(key)` is written inline (`\(remainder)`) rather than as an indented block."
        )
    }

    // MARK: - Line classification

    private static func indentation(of line: String) -> Int {
        line.prefix(while: { $0 == " " }).count
    }

    /// A line that carries structure, as opposed to a blank line or a comment.
    private static func isStructuralLine(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        return !trimmed.isEmpty && !trimmed.hasPrefix("#")
    }

    /// The key name when this line opens a mapping entry, else `nil`.
    private static func mappingKey(in line: String) -> String? {
        guard isStructuralLine(line) else { return nil }

        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard !trimmed.hasPrefix("-") else { return nil }
        guard let separator = trimmed.range(of: ":") else { return nil }

        let key = trimmed[trimmed.startIndex..<separator.lowerBound]
        guard !key.isEmpty else { return nil }

        let after = trimmed[separator.upperBound...]
        guard after.isEmpty || after.hasPrefix(" ") else { return nil }

        return key
            .trimmingCharacters(in: .whitespaces)
            .trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
    }

    private static func isBlockScalarHeader(_ line: String) -> Bool {
        guard let separator = line.range(of: ":") else { return false }

        let value = line[separator.upperBound...].trimmingCharacters(in: .whitespaces)
        return value.hasPrefix("|") || value.hasPrefix(">")
    }

    // MARK: - Ownership

    private static func blockReferencesManagedBinary(_ block: [String]) -> Bool {
        block.contains { line in
            guard let value = scalarValue(in: line) else { return false }
            return managedBinaryNames.contains(URL(fileURLWithPath: value).lastPathComponent)
        }
    }

    /// A readable name for the command occupying the hook slot.
    ///
    /// Prefers the first argv element, which is the executable; falls back to an
    /// inline `command: /path` that agentica itself would refuse, because a user
    /// who wrote one still deserves to be told what is in the way.
    private static func foreignCommandDescription(in block: [String]) -> String? {
        for line in block {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("-"), let value = scalarValue(in: line) else { continue }
            return value
        }

        for line in block {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("command:"), let value = scalarValue(in: line) else { continue }
            return value
        }

        return nil
    }

    private static func blockEnablesHooks(_ block: [String]) -> Bool {
        block.contains { line in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("enabled:") else { return false }

            let value = trimmed
                .dropFirst("enabled:".count)
                .trimmingCharacters(in: .whitespaces)
                .lowercased()
            return ["true", "yes", "on"].contains(value)
        }
    }

    /// The scalar carried by a sequence item or a `key: value` line.
    private static func scalarValue(in line: String) -> String? {
        var trimmed = line.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, !trimmed.hasPrefix("#") else { return nil }

        if trimmed.hasPrefix("-") {
            trimmed = String(trimmed.dropFirst()).trimmingCharacters(in: .whitespaces)
        } else if let separator = trimmed.range(of: ": ") {
            trimmed = String(trimmed[separator.upperBound...]).trimmingCharacters(in: .whitespaces)
        }

        guard !trimmed.isEmpty else { return nil }

        if trimmed.count >= 2, let first = trimmed.first, first == "\"" || first == "'",
           trimmed.hasSuffix(String(first)) {
            trimmed = String(trimmed.dropFirst().dropLast())
        }

        return trimmed
            .replacingOccurrences(of: "\\\"", with: "\"")
            .replacingOccurrences(of: "\\\\", with: "\\")
    }
}
