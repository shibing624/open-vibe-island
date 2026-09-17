import Foundation
import OpenIslandCore
import Testing
@testable import OpenIslandApp

/// Coverage for loading the bundled sound pack and merging it with packs the
/// user installed under Application Support.
struct BundledSoundThemeTests {

    /// The bundled peon pack ships inside the app's resource bundle (flat:
    /// manifest and audio side by side), so it must load via the flat lookup.
    @Test
    func bundledPackManifestLoads() throws {
        let url = Bundle.appResources.url(
            forResource: "theme",
            withExtension: "json",
            subdirectory: "SoundPacks/peon"
        )
        #expect(url != nil)

        let data = try Data(contentsOf: try #require(url))
        let theme = try SoundTheme(manifest: data, id: "peon")

        #expect(theme.displayName == "Orc Peon")
        #expect(theme.license == "")
        #expect(theme.author == "tonyyont")
        #expect(!theme.isBorrowing(for: .taskComplete))
        #expect(theme.files(for: .taskComplete).contains("PeonReady1.wav"))
        #expect(theme.files(for: .taskError).contains("PeonAngry4.wav"))
    }

    /// Audio for a bundled pack resolves inside the resource bundle, not under
    /// Application Support — the bundled copy is the one that ships.
    @Test
    func bundledPackAudioResolvesInsideTheResourceBundle() throws {
        let themes = EventSoundService.loadThemes(installedIn: [])
        let peon = try #require(themes.first { $0.id == "peon" })

        let url = EventSoundService.audioURL(for: "PeonReady1.wav", in: peon)

        #expect(url?.path.contains("SoundPacks/peon/PeonReady1.wav") == true)
        #expect(FileManager.default.fileExists(atPath: try #require(url).path))
    }

    /// Audio for a pack that is not bundled resolves under Application Support,
    /// where the fetch script installs packs.
    @Test
    func installedPackAudioResolvesUnderApplicationSupport() throws {
        let theme = SoundTheme(
            id: "zelda-ocarina",
            displayName: "Zelda Ocarina of Time",
            version: "1.0.0",
            license: "CC-BY-NC-4.0",
            author: "a",
            sourceRepo: "PeonPing/og-packs",
            categories: ["task.complete": [.init(file: "z.wav", label: "")]]
        )

        let url = EventSoundService.audioURL(for: "z.wav", in: theme)

        #expect(url == SoundPackLocation.directoryURL
            .appendingPathComponent("zelda-ocarina", isDirectory: true)
            .appendingPathComponent("z.wav"))
    }

    /// A fresh install has no packs in Application Support, yet the peon theme
    /// must still be selectable — that is the point of bundling.
    @Test
    func bundledThemesAreAlwaysPresent() throws {
        let themes = EventSoundService.loadThemes(installedIn: [])
        #expect(themes.map(\.id) == ["peon"])
    }

    /// An installed pack with the same id as the bundled one is dropped in
    /// favor of the bundle: the bundle is the copy this repository ships and
    /// keeps updated, so an old fetch-script copy must never shadow it.
    @Test
    func installedPackWithBundledIDIsDropped() throws {
        let installed = [
            SoundTheme(
                id: "peon",
                displayName: "Old fetched peon",
                version: "0.0.1",
                license: "CC-BY-NC-4.0",
                author: "tonyyont",
                sourceRepo: "PeonPing/og-packs",
                categories: ["task.complete": [.init(file: "PeonReady1.wav", label: "")]]
            ),
        ]

        let themes = EventSoundService.loadThemes(installedIn: installed)

        #expect(themes.count == 1)
        #expect(themes.first?.displayName == "Orc Peon")
    }

    /// Installed packs keep their place next to the bundled one, sorted by
    /// display name — the picker order must not depend on which pack shipped
    /// with the app.
    @Test
    func installedPacksAreMergedAndSorted() throws {
        let installed = [
            SoundTheme(
                id: "zelda-ocarina",
                displayName: "Zelda Ocarina of Time",
                version: "1.0.0",
                license: "CC-BY-NC-4.0",
                author: "a",
                sourceRepo: "PeonPing/og-packs",
                categories: ["task.complete": [.init(file: "z.wav", label: "")]]
            ),
            SoundTheme(
                id: "cute-minimal",
                displayName: "Cute UI",
                version: "1.0.0",
                license: "MIT",
                author: "b",
                sourceRepo: "TechPdM/openpeon-cute-minimal",
                categories: ["task.complete": [.init(file: "c.wav", label: "")]]
            ),
        ]

        let themes = EventSoundService.loadThemes(installedIn: installed)

        #expect(themes.map(\.id) == ["cute-minimal", "peon", "zelda-ocarina"])
    }
}
