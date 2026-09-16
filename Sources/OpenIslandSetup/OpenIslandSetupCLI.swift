import Foundation
import OpenIslandCore

@main
struct OpenIslandSetupCLI {
    static func main() {
        do {
            let command = try SetupCommand(arguments: Array(CommandLine.arguments.dropFirst()))
            try command.run()
        } catch let error as SetupError {
            fputs("error: \(error.localizedDescription)\n", stderr)
            exit(1)
        } catch {
            fputs("error: \(error.localizedDescription)\n", stderr)
            exit(1)
        }
    }
}

private struct SetupCommand {
    enum Action: String {
        case install
        case uninstall
        case status
        case installClaude
        case uninstallClaude
        case statusClaude
        case installKimi
        case uninstallKimi
        case statusKimi
        case installGrok
        case uninstallGrok
        case statusGrok
        case installAgentica
        case uninstallAgentica
        case statusAgentica
    }

    let action: Action
    let codexDirectory: URL
    let claudeDirectory: URL
    let kimiDirectory: URL
    let grokDirectory: URL
    let agenticaDirectory: URL
    let hooksBinary: URL?
    /// Take over agentica's single hook slot from another program's command.
    let replacingForeignCommand: Bool

    init(arguments: [String]) throws {
        guard let rawAction = arguments.first,
              let action = Action(rawValue: rawAction) else {
            throw SetupError.usage
        }

        self.action = action

        var hooksBinary: URL?
        var codexDirectory = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex", isDirectory: true)
        var claudeDirectory = ClaudeConfigDirectory.resolved()
        var kimiDirectory = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".kimi", isDirectory: true)
        var grokDirectory = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".grok", isDirectory: true)
        var agenticaDirectory = AgenticaHookInstallationManager.defaultDirectory()
        var replacingForeignCommand = false

        var index = 1
        while index < arguments.count {
            switch arguments[index] {
            case "--take-over-hook-slot":
                replacingForeignCommand = true

            case "--hooks-binary":
                index += 1
                guard index < arguments.count else {
                    throw SetupError.missingValue("--hooks-binary")
                }
                hooksBinary = URL(fileURLWithPath: arguments[index]).standardizedFileURL

            case "--codex-dir":
                index += 1
                guard index < arguments.count else {
                    throw SetupError.missingValue("--codex-dir")
                }
                codexDirectory = URL(fileURLWithPath: arguments[index]).standardizedFileURL

            case "--claude-dir":
                index += 1
                guard index < arguments.count else {
                    throw SetupError.missingValue("--claude-dir")
                }
                claudeDirectory = URL(fileURLWithPath: arguments[index]).standardizedFileURL

            case "--kimi-dir":
                index += 1
                guard index < arguments.count else {
                    throw SetupError.missingValue("--kimi-dir")
                }
                kimiDirectory = URL(fileURLWithPath: arguments[index]).standardizedFileURL

            case "--grok-dir":
                index += 1
                guard index < arguments.count else {
                    throw SetupError.missingValue("--grok-dir")
                }
                grokDirectory = URL(fileURLWithPath: arguments[index]).standardizedFileURL

            case "--agentica-dir":
                index += 1
                guard index < arguments.count else {
                    throw SetupError.missingValue("--agentica-dir")
                }
                agenticaDirectory = URL(fileURLWithPath: arguments[index]).standardizedFileURL

            default:
                throw SetupError.unexpectedArgument(arguments[index])
            }

            index += 1
        }

        if (action == .install
            || action == .installClaude
            || action == .installKimi
            || action == .installGrok
            || action == .installAgentica), hooksBinary == nil {
            hooksBinary = HooksBinaryLocator.locate()
        }

        self.codexDirectory = codexDirectory
        self.claudeDirectory = claudeDirectory
        self.kimiDirectory = kimiDirectory
        self.grokDirectory = grokDirectory
        self.agenticaDirectory = agenticaDirectory
        self.hooksBinary = hooksBinary
        self.replacingForeignCommand = replacingForeignCommand
    }

    func run() throws {
        switch action {
        case .install:
            try install()
        case .uninstall:
            try uninstall()
        case .status:
            try status()
        case .installClaude:
            try installClaude()
        case .uninstallClaude:
            try uninstallClaude()
        case .statusClaude:
            try statusClaude()
        case .installKimi:
            try installKimi()
        case .uninstallKimi:
            try uninstallKimi()
        case .statusKimi:
            try statusKimi()
        case .installGrok:
            try installGrok()
        case .uninstallGrok:
            try uninstallGrok()
        case .statusGrok:
            try statusGrok()
        case .installAgentica:
            try installAgentica()
        case .uninstallAgentica:
            try uninstallAgentica()
        case .statusAgentica:
            try statusAgentica()
        }
    }

    private func install() throws {
        guard let hooksBinary else {
            throw SetupError.usage
        }

        let manager = CodexHookInstallationManager(codexDirectory: codexDirectory)
        let status = try manager.install(hooksBinaryURL: hooksBinary)

        print("Installed Open Island Codex hooks.")
        print("Codex dir: \(status.codexDirectory.path)")
        print("Hooks binary: \(hooksBinary.path)")
        if status.manifest?.enabledCodexHooksFeature == true {
            print("Updated config.toml to enable Codex hooks")
        } else {
            print("config.toml already had Codex hooks enabled")
        }
    }

    private func uninstall() throws {
        let manager = CodexHookInstallationManager(codexDirectory: codexDirectory)
        let status = try manager.uninstall()

        print("Removed Open Island Codex hooks.")
        print("Codex dir: \(status.codexDirectory.path)")
        if FileManager.default.fileExists(atPath: status.hooksURL.path) {
            print("Preserved unrelated hooks.json entries.")
        }
    }

    private func status() throws {
        let manager = CodexHookInstallationManager(codexDirectory: codexDirectory)
        let status = try manager.status(hooksBinaryURL: hooksBinary)

        print("Codex dir: \(status.codexDirectory.path)")
        print("Feature flag enabled: \(status.featureFlagEnabled ? "yes" : "no")")
        print("Managed hooks present: \(status.managedHooksPresent ? "yes" : "no")")
        if let hooksBinary {
            print("Hooks binary: \(hooksBinary.path)")
        }
        if let manifest = status.manifest {
            print("Manifest: present")
            print("Feature enabled by installer: \(manifest.enabledCodexHooksFeature ? "yes" : "no")")
        } else {
            print("Manifest: missing")
        }
    }

    private func installClaude() throws {
        guard let hooksBinary else {
            throw SetupError.usage
        }

        let manager = ClaudeHookInstallationManager(claudeDirectory: claudeDirectory)
        let status = try manager.install(hooksBinaryURL: hooksBinary)

        print("Installed Open Island Claude hooks.")
        print("Claude dir: \(status.claudeDirectory.path)")
        print("Hooks binary: \(hooksBinary.path)")
        if status.hasClaudeIslandHooks {
            print("Note: claude-island hooks are still present alongside Open Island hooks.")
        }
    }

    private func uninstallClaude() throws {
        let manager = ClaudeHookInstallationManager(claudeDirectory: claudeDirectory)
        let status = try manager.uninstall()

        print("Removed Open Island Claude hooks.")
        print("Claude dir: \(status.claudeDirectory.path)")
        if status.hasClaudeIslandHooks {
            print("Preserved claude-island hooks.")
        }
    }

    private func statusClaude() throws {
        let manager = ClaudeHookInstallationManager(claudeDirectory: claudeDirectory)
        let status = try manager.status(hooksBinaryURL: hooksBinary)

        print("Claude dir: \(status.claudeDirectory.path)")
        print("Managed hooks present: \(status.managedHooksPresent ? "yes" : "no")")
        print("claude-island hooks present: \(status.hasClaudeIslandHooks ? "yes" : "no")")
        if let hooksBinary {
            print("Hooks binary: \(hooksBinary.path)")
        }
        if let manifest = status.manifest {
            print("Manifest: present")
            print("Hook command: \(manifest.hookCommand)")
        } else {
            print("Manifest: missing")
        }
    }

    private func installKimi() throws {
        guard let hooksBinary else {
            throw SetupError.usage
        }

        let manager = KimiHookInstallationManager(kimiDirectory: kimiDirectory)
        let status = try manager.install(hooksBinaryURL: hooksBinary)

        print("Installed Open Island Kimi hooks.")
        print("Kimi dir: \(status.kimiDirectory.path)")
        print("Hooks binary: \(hooksBinary.path)")
    }

    private func uninstallKimi() throws {
        let manager = KimiHookInstallationManager(kimiDirectory: kimiDirectory)
        let status = try manager.uninstall()

        print("Removed Open Island Kimi hooks.")
        print("Kimi dir: \(status.kimiDirectory.path)")
        if FileManager.default.fileExists(atPath: status.configURL.path) {
            print("Preserved unrelated [[hooks]] entries in config.toml.")
        }
    }

    private func statusKimi() throws {
        let manager = KimiHookInstallationManager(kimiDirectory: kimiDirectory)
        let status = try manager.status(hooksBinaryURL: hooksBinary)

        print("Kimi dir: \(status.kimiDirectory.path)")
        print("Managed hooks present: \(status.managedHooksPresent ? "yes" : "no")")
        if let hooksBinary {
            print("Hooks binary: \(hooksBinary.path)")
        }
        if let manifest = status.manifest {
            print("Manifest: present")
            print("Hook command: \(manifest.hookCommand)")
        } else {
            print("Manifest: missing")
        }
    }

    private func installGrok() throws {
        guard let hooksBinary else {
            throw SetupError.usage
        }

        let manager = GrokHookInstallationManager(grokDirectory: grokDirectory)
        let status = try manager.install(hooksBinaryURL: hooksBinary)

        print("Installed Open Island Grok hooks.")
        print("Grok dir: \(status.grokDirectory.path)")
        print("Hooks file: \(status.hooksURL.path)")
        print("Hooks binary: \(hooksBinary.path)")
    }

    private func uninstallGrok() throws {
        let manager = GrokHookInstallationManager(grokDirectory: grokDirectory)
        let status = try manager.uninstall()

        print("Removed Open Island Grok hooks.")
        print("Grok dir: \(status.grokDirectory.path)")
        if FileManager.default.fileExists(atPath: status.hooksURL.path) {
            print("Note: hooks file still present.")
        }
    }

    private func statusGrok() throws {
        let manager = GrokHookInstallationManager(grokDirectory: grokDirectory)
        let status = try manager.status(hooksBinaryURL: hooksBinary)

        print("Grok dir: \(status.grokDirectory.path)")
        print("Hooks file: \(status.hooksURL.path)")
        print("Managed hooks present: \(status.managedHooksPresent ? "yes" : "no")")
        if let hooksBinary {
            print("Hooks binary: \(hooksBinary.path)")
        }
        if let manifest = status.manifest {
            print("Manifest: present")
            print("Hook command: \(manifest.hookCommand)")
        } else {
            print("Manifest: missing")
        }
    }

    private func installAgentica() throws {
        guard let hooksBinary else {
            throw SetupError.usage
        }

        let manager = AgenticaHookInstallationManager(agenticaDirectory: agenticaDirectory)
        let status = try manager.install(
            hooksBinaryURL: hooksBinary,
            replacingForeignCommand: replacingForeignCommand
        )

        print("Installed Open Island agentica hooks.")
        print("Agentica dir: \(status.agenticaDirectory.path)")
        print("Config: \(status.configURL.path)")
        print("Hooks binary: \(hooksBinary.path)")
        print("Restart the agentica CLI: settings.hooks is read once at startup.")
    }

    private func uninstallAgentica() throws {
        let manager = AgenticaHookInstallationManager(agenticaDirectory: agenticaDirectory)
        let status = try manager.uninstall()

        print("Removed Open Island agentica hooks.")
        print("Agentica dir: \(status.agenticaDirectory.path)")
        if status.managedHooksPresent {
            print("Note: settings.hooks still routes at Open Island.")
        }
    }

    private func statusAgentica() throws {
        let manager = AgenticaHookInstallationManager(agenticaDirectory: agenticaDirectory)
        let status = try manager.status(hooksBinaryURL: hooksBinary)

        print("Agentica dir: \(status.agenticaDirectory.path)")
        print("Config: \(status.configURL.path)")
        print("Managed hooks present: \(status.managedHooksPresent ? "yes" : "no")")
        if let foreign = status.foreignHookCommand {
            print("Hook slot held by: \(foreign)")
            print("agentica runs one hook command; pass --take-over-hook-slot to replace it.")
        }
        if let hooksBinary {
            print("Hooks binary: \(hooksBinary.path)")
        }
        if let manifest = status.manifest {
            print("Manifest: present")
            print("Hook command: \(manifest.hookCommand.joined(separator: " "))")
        } else {
            print("Manifest: missing")
        }
    }
}

private enum SetupError: Error, LocalizedError {
    case usage
    case missingValue(String)
    case unexpectedArgument(String)

    var errorDescription: String? {
        switch self {
        case .usage:
            """
            Usage:
              swift run OpenIslandSetup install [--hooks-binary /abs/path/to/OpenIslandHooks] [--codex-dir /abs/path/to/.codex]
              swift run OpenIslandSetup uninstall [--codex-dir /abs/path/to/.codex]
              swift run OpenIslandSetup status [--hooks-binary /abs/path/to/OpenIslandHooks] [--codex-dir /abs/path/to/.codex]
              swift run OpenIslandSetup installClaude [--hooks-binary /abs/path/to/OpenIslandHooks] [--claude-dir /abs/path/to/.claude]
              swift run OpenIslandSetup uninstallClaude [--claude-dir /abs/path/to/.claude]
              swift run OpenIslandSetup statusClaude [--hooks-binary /abs/path/to/OpenIslandHooks] [--claude-dir /abs/path/to/.claude]
              swift run OpenIslandSetup installKimi [--hooks-binary /abs/path/to/OpenIslandHooks] [--kimi-dir /abs/path/to/.kimi]
              swift run OpenIslandSetup uninstallKimi [--kimi-dir /abs/path/to/.kimi]
              swift run OpenIslandSetup statusKimi [--hooks-binary /abs/path/to/OpenIslandHooks] [--kimi-dir /abs/path/to/.kimi]
              swift run OpenIslandSetup installGrok [--hooks-binary /abs/path/to/OpenIslandHooks] [--grok-dir /abs/path/to/.grok]
              swift run OpenIslandSetup uninstallGrok [--grok-dir /abs/path/to/.grok]
              swift run OpenIslandSetup statusGrok [--hooks-binary /abs/path/to/OpenIslandHooks] [--grok-dir /abs/path/to/.grok]
              swift run OpenIslandSetup installAgentica [--hooks-binary /abs/path/to/OpenIslandHooks] [--agentica-dir /abs/path/to/.agentica] [--take-over-hook-slot]
              swift run OpenIslandSetup uninstallAgentica [--agentica-dir /abs/path/to/.agentica]
              swift run OpenIslandSetup statusAgentica [--hooks-binary /abs/path/to/OpenIslandHooks] [--agentica-dir /abs/path/to/.agentica]
            """
        case let .missingValue(flag):
            "Missing value for \(flag)"
        case let .unexpectedArgument(argument):
            "Unexpected argument: \(argument)"
        }
    }
}
