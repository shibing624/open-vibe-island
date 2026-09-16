import Foundation

public struct AgenticaHookInstallationStatus: Equatable, Sendable {
    public var agenticaDirectory: URL
    public var configURL: URL
    public var manifestURL: URL
    public var hooksBinaryURL: URL?
    public var managedHooksPresent: Bool
    public var manifest: AgenticaHookInstallerManifest?
    /// Someone else's command in agentica's single hook slot, if any.
    public var foreignHookCommand: String?

    public init(
        agenticaDirectory: URL,
        configURL: URL,
        manifestURL: URL,
        hooksBinaryURL: URL?,
        managedHooksPresent: Bool,
        manifest: AgenticaHookInstallerManifest?,
        foreignHookCommand: String?
    ) {
        self.agenticaDirectory = agenticaDirectory
        self.configURL = configURL
        self.manifestURL = manifestURL
        self.hooksBinaryURL = hooksBinaryURL
        self.managedHooksPresent = managedHooksPresent
        self.manifest = manifest
        self.foreignHookCommand = foreignHookCommand
    }
}

/// Owns the on-disk side of agentica hook installation.
public final class AgenticaHookInstallationManager: @unchecked Sendable {
    /// agentica resolves its home lazily from `AGENTICA_HOME`, so a user who
    /// moved it would otherwise get hooks written to a file agentica never reads.
    public static func defaultDirectory(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        fileManager: FileManager = .default
    ) -> URL {
        guard let home = environment["AGENTICA_HOME"], !home.isEmpty else {
            return fileManager.homeDirectoryForCurrentUser.appendingPathComponent(".agentica", isDirectory: true)
        }

        return URL(fileURLWithPath: (home as NSString).expandingTildeInPath, isDirectory: true)
    }

    public let agenticaDirectory: URL
    public let managedHooksBinaryURL: URL
    private let fileManager: FileManager

    public init(
        agenticaDirectory: URL = AgenticaHookInstallationManager.defaultDirectory(),
        managedHooksBinaryURL: URL = ManagedHooksBinary.defaultURL(),
        fileManager: FileManager = .default
    ) {
        self.agenticaDirectory = agenticaDirectory
        self.managedHooksBinaryURL = managedHooksBinaryURL.standardizedFileURL
        self.fileManager = fileManager
    }

    private var configURL: URL {
        agenticaDirectory.appendingPathComponent("config.yaml")
    }

    private var manifestURL: URL {
        agenticaDirectory.appendingPathComponent(AgenticaHookInstallerManifest.fileName)
    }

    public func status(hooksBinaryURL: URL? = nil) throws -> AgenticaHookInstallationStatus {
        let config = try? readConfig()

        return AgenticaHookInstallationStatus(
            agenticaDirectory: agenticaDirectory,
            configURL: configURL,
            manifestURL: manifestURL,
            hooksBinaryURL: resolvedHooksBinaryURL(explicitURL: hooksBinaryURL),
            managedHooksPresent: AgenticaHookInstaller.hasManagedHooks(in: config),
            manifest: try loadManifest(),
            foreignHookCommand: AgenticaHookInstaller.foreignHookCommand(in: config)
        )
    }

    /// - Parameter replacingForeignCommand: take over agentica's single hook slot
    ///   even when another program holds it. Defaults to refusing, because doing
    ///   it silently would disable that program's hook.
    @discardableResult
    public func install(
        hooksBinaryURL: URL,
        replacingForeignCommand: Bool = false
    ) throws -> AgenticaHookInstallationStatus {
        try fileManager.createDirectory(at: agenticaDirectory, withIntermediateDirectories: true)

        let installedBinaryURL = try ManagedHooksBinary.install(
            from: hooksBinaryURL,
            to: managedHooksBinaryURL,
            fileManager: fileManager
        )
        let command = AgenticaHookInstaller.hookCommand(for: installedBinaryURL.path)
        let mutation = try AgenticaHookInstaller.installConfigYAML(
            existingText: try? readConfig(),
            hookCommand: command,
            replacingForeignCommand: replacingForeignCommand
        )

        try apply(mutation)

        let manifest = AgenticaHookInstallerManifest(hookCommand: command)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(manifest).write(to: manifestURL, options: .atomic)

        return try status(hooksBinaryURL: installedBinaryURL)
    }

    @discardableResult
    public func uninstall() throws -> AgenticaHookInstallationStatus {
        let mutation = try AgenticaHookInstaller.uninstallConfigYAML(existingText: try? readConfig())
        try apply(mutation)

        if fileManager.fileExists(atPath: manifestURL.path) {
            try fileManager.removeItem(at: manifestURL)
        }

        return try status()
    }

    private func apply(_ mutation: AgenticaHookFileMutation) throws {
        guard mutation.changed, let contents = mutation.contents else {
            return
        }

        if fileManager.fileExists(atPath: configURL.path) {
            try backupConfig()
        }

        try Data(contents.utf8).write(to: configURL, options: .atomic)

        // agentica keeps this file at 0600 because it holds plaintext API keys.
        // An atomic write creates a new inode, so the mode has to be restored or
        // the keys would end up world-readable.
        try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: configURL.path)
    }

    private func readConfig() throws -> String {
        try String(contentsOf: configURL, encoding: .utf8)
    }

    private func loadManifest() throws -> AgenticaHookInstallerManifest? {
        guard fileManager.fileExists(atPath: manifestURL.path) else { return nil }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(
            AgenticaHookInstallerManifest.self,
            from: try Data(contentsOf: manifestURL)
        )
    }

    private func resolvedHooksBinaryURL(explicitURL: URL?) -> URL? {
        if let explicitURL {
            return explicitURL.standardizedFileURL
        }

        guard fileManager.isExecutableFile(atPath: managedHooksBinaryURL.path) else {
            return nil
        }

        return managedHooksBinaryURL
    }

    private func backupConfig() throws {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        let timestamp = formatter.string(from: .now).replacingOccurrences(of: ":", with: "-")
        let backupURL = configURL.appendingPathExtension("backup.\(timestamp)")

        if fileManager.fileExists(atPath: backupURL.path) {
            try fileManager.removeItem(at: backupURL)
        }

        try fileManager.copyItem(at: configURL, to: backupURL)
        try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: backupURL.path)
    }
}
