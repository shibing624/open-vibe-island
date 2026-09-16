import Foundation
import Testing
@testable import OpenIslandCore

/// Coverage for CESP sound pack parsing and category selection.
struct SoundThemeTests {

    private func manifestData(
        license: String? = "CC-BY-NC-4.0",
        author: String? = "tonyyont",
        categories: [String: [[String: String]]]
    ) -> Data {
        var manifest: [String: Any] = [
            "name": "peon",
            "display_name": "Orc Peon",
            "version": "1.0.0",
            "source_repo": "PeonPing/og-packs",
            "categories": categories,
        ]
        if let license {
            manifest["license"] = license
        }
        if let author {
            manifest["author"] = ["name": author]
        }
        return try! JSONSerialization.data(withJSONObject: manifest)
    }

    @Test
    func parsesManifestAndSelectsSoundsByCategory() throws {
        let data = manifestData(categories: [
            "task.complete": [["file": "PeonReady1.wav", "label": "Ready to work?"]],
            "task.error": [["file": "PeonAngry4.wav", "label": "Me not that kind of orc!"]],
        ])

        let theme = try SoundTheme(manifest: data, id: "peon")

        #expect(theme.displayName == "Orc Peon")
        #expect(theme.license == "CC-BY-NC-4.0")
        #expect(theme.author == "tonyyont")
        #expect(theme.sourceRepo == "PeonPing/og-packs")
        #expect(theme.entryCount == 2)
        #expect(theme.files(for: .taskComplete) == ["PeonReady1.wav"])
        #expect(theme.files(for: .taskError) == ["PeonAngry4.wav"])
        #expect(theme.entries(for: .taskError).first?.label == "Me not that kind of orc!")
    }

    /// Attribution is the only record of what may be redistributed, so a pack
    /// without it must not become selectable.
    @Test
    func rejectsManifestWithoutAttribution() {
        let noLicense = manifestData(license: nil, categories: [
            "task.complete": [["file": "a.wav", "label": ""]],
        ])
        let noAuthor = manifestData(author: nil, categories: [
            "task.complete": [["file": "a.wav", "label": ""]],
        ])

        #expect(throws: SoundThemeError.missingAttribution(id: "peon")) {
            try SoundTheme(manifest: noLicense, id: "peon")
        }
        #expect(throws: SoundThemeError.missingAttribution(id: "peon")) {
            try SoundTheme(manifest: noAuthor, id: "peon")
        }
    }

    @Test
    func rejectsManifestWithNoPlayableEntry() {
        let data = manifestData(categories: ["task.complete": []])

        #expect(throws: SoundThemeError.emptyCategories(id: "peon")) {
            try SoundTheme(manifest: data, id: "peon")
        }
    }

    /// A category the pack does not ship borrows from the rest of the same pack,
    /// in a fixed order so the choice is reproducible.
    @Test
    func borrowsFromWholePackWhenCategoryIsMissing() throws {
        let data = manifestData(categories: [
            "task.complete": [["file": "complete.wav", "label": ""]],
            "input.required": [["file": "waiting.wav", "label": ""]],
        ])

        let theme = try SoundTheme(manifest: data, id: "peon")

        #expect(theme.isBorrowing(for: .taskError))
        #expect(!theme.isBorrowing(for: .taskComplete))
        // Sorted by category key: input.required before task.complete.
        #expect(theme.files(for: .taskError) == ["waiting.wav", "complete.wav"])
    }

    @Test
    func rotationCyclesPerCueIndependently() throws {
        let data = manifestData(categories: [
            "task.complete": [
                ["file": "done1.wav", "label": ""],
                ["file": "done2.wav", "label": ""],
            ],
            "input.required": [["file": "waiting.wav", "label": ""]],
        ])
        let theme = try SoundTheme(manifest: data, id: "peon")
        var rotation = SoundRotation()

        #expect(rotation.pick(.taskComplete, from: theme) == "done1.wav")
        #expect(rotation.pick(.inputRequired, from: theme) == "waiting.wav")
        // The input.required pick must not shift task.complete's position.
        #expect(rotation.pick(.taskComplete, from: theme) == "done2.wav")
        #expect(rotation.pick(.taskComplete, from: theme) == "done1.wav")
        #expect(rotation.count(for: .taskComplete) == 3)

        rotation.reset()
        #expect(rotation.pick(.taskComplete, from: theme) == "done1.wav")
    }

    /// Directories without a manifest are not packs and must be skipped rather
    /// than guessed at.
    @Test
    func installedThemesSkipsDirectoriesWithoutManifest() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("sound-packs-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }

        let valid = root.appendingPathComponent("peon")
        let bare = root.appendingPathComponent("loose-audio")
        try FileManager.default.createDirectory(at: valid, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: bare, withIntermediateDirectories: true)
        try manifestData(categories: ["task.complete": [["file": "done.wav", "label": ""]]])
            .write(to: valid.appendingPathComponent("theme.json"))
        try Data().write(to: bare.appendingPathComponent("random.wav"))

        let themes = SoundTheme.installedThemes(in: root)

        #expect(themes.map(\.id) == ["peon"])
    }

    @Test
    func installedThemesIsEmptyWhenDirectoryIsMissing() {
        let missing = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("absent-\(UUID().uuidString)")

        #expect(SoundTheme.installedThemes(in: missing).isEmpty)
    }
}
