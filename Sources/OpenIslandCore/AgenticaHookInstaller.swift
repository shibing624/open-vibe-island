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

    public var errorDescription: String? {
        switch self {
        case let .unsupportedConfigShape(detail):
            "Open Island could not edit ~/.agentica/config.yaml safely: \(detail) "
                + "Add the settings.hooks consumer by hand instead."
        }
    }
}

/// Installs Open Island as a named consumer in agentica's `settings.hooks`.
///
/// ## Why this edits text instead of round-tripping a parser
///
/// `~/.agentica/config.yaml` is a hand-written file that holds every model
/// profile and plaintext API key, and agentica documents it as comment-preserving
/// (it writes with `ruamel`). libyaml — and therefore every Swift YAML binding —
/// has no comment model at all, so loading and re-serializing this file would
/// silently delete the user's comments on every install and uninstall.
///
/// So the edit is textual and scoped: only our own consumer entry is rewritten,
/// every other byte is copied through. The safety property that makes that
/// acceptable is that an unrecognized shape is **refused, never guessed** — see
/// `unsupportedConfigShape`. A wrong guess here would either corrupt the file or,
/// worse, write a duplicate key that makes agentica fall back to an empty config
/// and quietly lose every profile.
///
/// ## Why there is no takeover
///
/// `settings.hooks.consumers` is a list of named entries, and agentica fans every
/// event out to all of them. So a hook wire is not a slot to win: Open Island owns
/// the entry called `open-island` and never reads, moves or deletes anyone else's.
public enum AgenticaHookInstaller {
    /// Our identity in `settings.hooks.consumers`. This name *is* the ownership
    /// record — install, refresh and uninstall all key off it.
    public static let consumerName = "open-island"

    /// agentica takes an argv list, not a shell string: it refuses a string
    /// rather than inventing quoting rules. So the managed hook is three
    /// elements and needs no shell quoting even though the installed binary path
    /// contains spaces.
    public static func hookCommand(for binaryPath: String) -> [String] {
        [binaryPath, "--source", "agentica"]
    }

    /// Adds or refreshes our consumer entry, leaving every other consumer alone.
    public static func installConfigYAML(
        existingText: String?,
        hookCommand: [String]
    ) throws -> AgenticaHookFileMutation {
        let original = existingText ?? ""
        var lines = original.isEmpty ? [] : original.components(separatedBy: "\n")
        try rejectTabIndentation(lines)

        func result() -> AgenticaHookFileMutation {
            let text = lines.joined(separator: "\n")
            return AgenticaHookFileMutation(
                contents: text,
                changed: text != original,
                managedHooksPresent: true
            )
        }

        guard let settings = topLevelKey("settings", in: lines) else {
            lines = appendSettingsBlock(to: lines, hookCommand: hookCommand)
            return result()
        }

        try rejectInlineValue(on: lines[settings.keyIndex], key: "settings")
        let settingsChildIndent = childIndentation(of: lines, region: settings.childRange)

        guard let hooks = childKey(
            "hooks",
            in: lines,
            region: settings.childRange,
            indent: settingsChildIndent
        ) else {
            lines.insert(
                contentsOf: renderHooksBlock(indent: settingsChildIndent, hookCommand: hookCommand),
                at: insertionIndex(in: lines, region: settings.childRange)
            )
            return result()
        }

        try rejectInlineValue(on: lines[hooks.keyIndex], key: "settings.hooks")
        let hooksChildIndent = childIndentation(of: lines, region: hooks.childRange)

        // `enabled` first: it moves indices below it, and `consumers` is looked up
        // fresh afterwards.
        lines = enablingHooks(lines, hooks: hooks, indent: hooksChildIndent)

        guard let refreshedHooks = childKey(
            "hooks",
            in: lines,
            region: topLevelKey("settings", in: lines)?.childRange ?? 0..<lines.count,
            indent: settingsChildIndent
        ) else {
            throw AgenticaHookInstallerError.unsupportedConfigShape(
                "`settings.hooks` disappeared while editing."
            )
        }

        guard let consumers = childKey(
            "consumers",
            in: lines,
            region: refreshedHooks.childRange,
            indent: hooksChildIndent
        ) else {
            lines.insert(
                contentsOf: renderConsumersBlock(indent: hooksChildIndent, hookCommand: hookCommand),
                at: insertionIndex(in: lines, region: refreshedHooks.childRange)
            )
            return result()
        }

        try rejectInlineValue(on: lines[consumers.keyIndex], key: "settings.hooks.consumers")

        let itemIndent = childIndentation(of: lines, region: consumers.childRange)
        let items = sequenceItems(in: lines, region: consumers.childRange, indent: itemIndent)

        if let ours = items.first(where: { consumerName(of: lines, item: $0, indent: itemIndent) == consumerName }) {
            lines.replaceSubrange(
                ours,
                with: try refreshedConsumerItem(
                    Array(lines[ours]),
                    indent: itemIndent,
                    hookCommand: hookCommand
                )
            )
        } else {
            lines.insert(
                contentsOf: renderConsumerItem(indent: itemIndent, hookCommand: hookCommand),
                at: insertionIndex(in: lines, region: consumers.childRange)
            )
        }

        return result()
    }

    /// Removes our consumer entry and nothing else.
    ///
    /// Another program's entry on this wire is theirs; a `consumers:` key left
    /// with no items of ours is left as it is, because agentica reads an empty
    /// list as "no consumers" and deleting the key would mean deciding which of
    /// the surrounding comments belonged to it.
    public static func uninstallConfigYAML(existingText: String?) throws -> AgenticaHookFileMutation {
        guard let original = existingText, !original.isEmpty else {
            return AgenticaHookFileMutation(contents: nil, changed: false, managedHooksPresent: false)
        }

        var lines = original.components(separatedBy: "\n")
        try rejectTabIndentation(lines)

        func unchanged() -> AgenticaHookFileMutation {
            AgenticaHookFileMutation(contents: original, changed: false, managedHooksPresent: false)
        }

        guard let location = locateOurConsumer(in: lines) else { return unchanged() }

        lines.removeSubrange(location.item)
        let text = lines.joined(separator: "\n")
        return AgenticaHookFileMutation(
            contents: text,
            changed: text != original,
            managedHooksPresent: false
        )
    }

    /// Whether agentica will currently fan events out to us.
    public static func hasManagedHooks(in text: String?) -> Bool {
        guard let text, !text.isEmpty else { return false }
        let lines = text.components(separatedBy: "\n")
        guard let location = locateOurConsumer(in: lines) else { return false }

        let block = Array(lines[location.item])
        return blockEnablesHooks(Array(lines[location.hooks])) && !blockDisablesConsumer(block)
    }

    /// The other programs listening on this wire, for display only.
    ///
    /// Open Island neither needs nor takes anything from them; showing them just
    /// makes it obvious that the wire is shared.
    public static func otherConsumerNames(in text: String?) -> [String] {
        guard let text, !text.isEmpty else { return [] }
        let lines = text.components(separatedBy: "\n")
        guard (try? rejectTabIndentation(lines)) != nil,
              let settings = topLevelKey("settings", in: lines),
              let hooks = childKey(
                  "hooks",
                  in: lines,
                  region: settings.childRange,
                  indent: childIndentation(of: lines, region: settings.childRange)
              ),
              let consumers = childKey(
                  "consumers",
                  in: lines,
                  region: hooks.childRange,
                  indent: childIndentation(of: lines, region: hooks.childRange)
              )
        else {
            return []
        }

        let itemIndent = childIndentation(of: lines, region: consumers.childRange)
        return sequenceItems(in: lines, region: consumers.childRange, indent: itemIndent)
            .compactMap { consumerName(of: lines, item: $0, indent: itemIndent) }
            .filter { $0 != consumerName }
    }

    /// The block a user can paste by hand when the config shape is refused.
    public static func manualSnippet(hookCommand: [String]) -> String {
        (["settings:"] + renderHooksBlock(indent: "  ", hookCommand: hookCommand))
            .joined(separator: "\n")
    }

    // MARK: - Rendering

    private static func renderHooksBlock(indent: String, hookCommand: [String]) -> [String] {
        ["\(indent)hooks:", "\(indent)  enabled: true"]
            + renderConsumersBlock(indent: indent + "  ", hookCommand: hookCommand)
    }

    private static func renderConsumersBlock(indent: String, hookCommand: [String]) -> [String] {
        ["\(indent)consumers:"]
            + renderConsumerItem(indent: indent + "  ", hookCommand: hookCommand)
    }

    /// One sequence item. `indent` is the indentation of the `-`.
    private static func renderConsumerItem(indent: String, hookCommand: [String]) -> [String] {
        ["\(indent)- name: \(consumerName)"]
            + renderCommand(indent: indent + "  ", hookCommand: hookCommand)
    }

    private static func renderCommand(indent: String, hookCommand: [String]) -> [String] {
        ["\(indent)command:"] + hookCommand.map { "\(indent)  - \(quote($0))" }
    }

    /// Rebuilds our own item: a fresh `name` and `command`, and every other child
    /// key copied through verbatim so a hand-tuned `events:` gate survives.
    private static func refreshedConsumerItem(
        _ item: [String],
        indent: String,
        hookCommand: [String]
    ) throws -> [String] {
        // Normalize the `- key: …` line into an ordinary child so `name` and
        // `command` can be found the same way wherever the user put them.
        var mapping = item
        let childIndent = indent + "  "
        let firstLine = mapping[0].trimmingCharacters(in: .whitespaces)
        guard firstLine.hasPrefix("-") else {
            throw AgenticaHookInstallerError.unsupportedConfigShape(
                "the `\(consumerName)` consumer does not start with a `-` item."
            )
        }
        mapping[0] = childIndent + String(firstLine.dropFirst()).trimmingCharacters(in: .whitespaces)

        for key in ["name", "command"] {
            while let block = childKey(key, in: mapping, region: 0..<mapping.count, indent: childIndent) {
                mapping.removeSubrange(block.keyIndex..<block.endIndex)
            }
        }

        return renderConsumerItem(indent: indent, hookCommand: hookCommand) + mapping
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

    /// Forces `settings.hooks.enabled: true`, which is the wire's master switch.
    private static func enablingHooks(_ lines: [String], hooks: KeyBlock, indent: String) -> [String] {
        var result = lines
        let line = "\(indent)enabled: true"

        if let enabled = childKey("enabled", in: result, region: hooks.childRange, indent: indent) {
            result[enabled.keyIndex] = line
        } else {
            result.insert(line, at: hooks.keyIndex + 1)
        }

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

    /// Where our consumer entry sits, together with the `hooks` block holding it.
    private struct ConsumerLocation {
        let hooks: Range<Int>
        let item: Range<Int>
    }

    private static func locateOurConsumer(in lines: [String]) -> ConsumerLocation? {
        guard (try? rejectTabIndentation(lines)) != nil,
              let settings = topLevelKey("settings", in: lines),
              let hooks = childKey(
                  "hooks",
                  in: lines,
                  region: settings.childRange,
                  indent: childIndentation(of: lines, region: settings.childRange)
              ),
              let consumers = childKey(
                  "consumers",
                  in: lines,
                  region: hooks.childRange,
                  indent: childIndentation(of: lines, region: hooks.childRange)
              )
        else {
            return nil
        }

        let itemIndent = childIndentation(of: lines, region: consumers.childRange)
        guard let ours = sequenceItems(in: lines, region: consumers.childRange, indent: itemIndent)
            .first(where: { consumerName(of: lines, item: $0, indent: itemIndent) == consumerName })
        else {
            return nil
        }

        return ConsumerLocation(hooks: hooks.keyIndex..<hooks.endIndex, item: ours)
    }

    /// The line ranges of the `- ` items directly inside a sequence.
    private static func sequenceItems(
        in lines: [String],
        region: Range<Int>,
        indent: String
    ) -> [Range<Int>] {
        let indentWidth = indent.count
        var starts: [Int] = []

        var index = region.lowerBound
        while index < region.upperBound {
            let line = lines[index]
            if isStructuralLine(line), indentation(of: line) == indentWidth,
               line.trimmingCharacters(in: .whitespaces).hasPrefix("-") {
                starts.append(index)
            }
            index += 1
        }

        return starts.enumerated().map { position, start in
            let next = position + 1 < starts.count ? starts[position + 1] : region.upperBound
            // Trailing blanks and comments belong to whatever comes next, not to
            // the item being measured, so removing an item cannot eat them.
            var end = start + 1
            for line in start + 1..<next where isStructuralLine(lines[line]) {
                end = line + 1
            }
            return start..<max(end, start + 1)
        }
    }

    /// The `name` of a sequence item, whether it sits on the `-` line or below it.
    private static func consumerName(of lines: [String], item: Range<Int>, indent: String) -> String? {
        var mapping = Array(lines[item])
        let childIndent = indent + "  "
        let first = mapping[0].trimmingCharacters(in: .whitespaces)
        guard first.hasPrefix("-") else { return nil }
        mapping[0] = childIndent + String(first.dropFirst()).trimmingCharacters(in: .whitespaces)

        guard let name = childKey("name", in: mapping, region: 0..<mapping.count, indent: childIndent) else {
            return nil
        }
        return scalarValue(in: mapping[name.keyIndex])
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

    /// Indentation used by the children of a block, or two more than the block
    /// itself when it has none yet.
    private static func childIndentation(of lines: [String], region: Range<Int>) -> String {
        for index in region {
            let line = lines[index]
            guard isStructuralLine(line) else { continue }

            let width = indentation(of: line)
            if width > 0 {
                return String(repeating: " ", count: width)
            }
        }

        guard region.lowerBound > 0, region.lowerBound <= lines.count else { return "  " }
        return String(repeating: " ", count: indentation(of: lines[region.lowerBound - 1]) + 2)
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

    private static func blockEnablesHooks(_ block: [String]) -> Bool {
        block.contains { line in
            booleanValue(in: line, key: "enabled") == true
        }
    }

    private static func blockDisablesConsumer(_ block: [String]) -> Bool {
        block.contains { line in
            booleanValue(in: line, key: "enabled") == false
        }
    }

    private static func booleanValue(in line: String, key: String) -> Bool? {
        var trimmed = line.trimmingCharacters(in: .whitespaces)
        if trimmed.hasPrefix("-") {
            trimmed = String(trimmed.dropFirst()).trimmingCharacters(in: .whitespaces)
        }
        guard trimmed.hasPrefix("\(key):") else { return nil }

        let value = trimmed
            .dropFirst("\(key):".count)
            .trimmingCharacters(in: .whitespaces)
            .lowercased()
        if ["true", "yes", "on"].contains(value) { return true }
        if ["false", "no", "off"].contains(value) { return false }
        return nil
    }

    /// The scalar carried by a sequence item or a `key: value` line.
    private static func scalarValue(in line: String) -> String? {
        var trimmed = line.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, !trimmed.hasPrefix("#") else { return nil }

        if trimmed.hasPrefix("-") {
            trimmed = String(trimmed.dropFirst()).trimmingCharacters(in: .whitespaces)
        }
        if let separator = trimmed.range(of: ": ") {
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
