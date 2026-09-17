import AVFoundation
import Foundation
import OpenIslandCore

/// Turns a `SoundCue` into an actual sound.
///
/// ## One theme, five events
///
/// A theme is global rather than per-event, because a coherent set is the whole
/// point of a theme: half Orc Peon and half GLaDOS is not "customized", it is
/// broken. The same reason drives the settings UI to preview *categories* rather
/// than files — the user is deciding whether the "turn finished" sound is
/// pleasant, not browsing an audio library.
///
/// ## The System theme
///
/// The Orc Peon pack ships in the app bundle (bought out for this project), so
/// a fresh install already has per-event sounds. The reserved theme id `system`
/// still exists: it plays a macOS alert sound for every cue, which is what
/// Open Island did before packs existed.
///
/// ## Two gates
///
/// 1. `AppModel.isSoundMuted` — the island's mute switch, passed in per call so
///    there is one owner of that state.
/// 2. Volume.
@MainActor
final class EventSoundService {

    static let shared = EventSoundService()

    /// Reserved theme id: macOS system alert sounds, no pack required.
    static let systemThemeID = "system"

    /// Preferred theme once packs exist but the user has not chosen one.
    ///
    /// Hard-coded rather than "the first pack alphabetically": otherwise the
    /// default would silently change whenever a pack with an earlier display
    /// name gets installed, and no line of code would say what the default is
    /// supposed to be.
    static let preferredThemeID = "peon"

    enum DefaultsKey {
        static let themeID = "sound.theme.id"
        static let volume = "sound.theme.volume"
    }

    /// Packs available to the user: bundled ones plus those installed under
    /// Application Support. `private(set)` so the settings pane and the player
    /// can never disagree about what is installed.
    private(set) var themes: [SoundTheme] = EventSoundService.loadThemes(
        installedIn: SoundTheme.installedThemes(in: SoundPackLocation.directoryURL)
    )

    /// Merges bundled packs with the packs found in Application Support.
    ///
    /// A downloaded pack whose id collides with a bundled one is dropped: the
    /// bundle is the copy this repository ships and keeps updated, so an old
    /// fetch-script copy must never shadow it.
    nonisolated static func loadThemes(installedIn installed: [SoundTheme]) -> [SoundTheme] {
        // Packs shipped inside the app bundle. `Package.swift` declares
        // `SoundPacks` with `.copy`, so the `SoundPacks/<id>/` directory shape
        // survives into the resource bundle.
        let bundled = ["peon"].compactMap { id -> SoundTheme? in
            guard let directory = Bundle.appResources.url(
                forResource: id,
                withExtension: nil,
                subdirectory: "SoundPacks"
            ) else {
                return nil
            }
            return Self.loadTheme(id: id, in: directory)
        }

        let bundledIDs = Set(bundled.map(\.id))
        return (bundled + installed.filter { !bundledIDs.contains($0.id) })
            .sorted { $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending }
    }

    /// Loads one pack from a directory holding `theme.json` and its audio.
    nonisolated private static func loadTheme(id: String, in directory: URL) -> SoundTheme? {
        do {
            let data = try Data(contentsOf: directory.appendingPathComponent("theme.json"))
            return try SoundTheme(manifest: data, id: id, audioDirectory: directory)
        } catch {
            return nil
        }
    }

    /// Where the audio for a theme entry lives. Bundled packs read from the
    /// resource bundle; everything else from Application Support.
    nonisolated static func audioURL(for file: String, in theme: SoundTheme) -> URL? {
        let directory = theme.audioDirectory ?? SoundPackLocation.directoryURL
            .appendingPathComponent(theme.id, isDirectory: true)
        return directory.appendingPathComponent(file)
    }

    /// Rescans the packs directory — used after the fetch script runs while the
    /// app is open.
    func reloadThemes() {
        themes = EventSoundService.loadThemes(
            installedIn: SoundTheme.installedThemes(in: SoundPackLocation.directoryURL)
        )
        rotation.reset()
    }

    var hasInstalledThemes: Bool { !themes.isEmpty }

    /// Selected theme id, persisted. Falls back to the preferred pack and then
    /// to `system`, so a pack the user selected and later deleted degrades to
    /// audible system sounds instead of silence.
    var themeID: String {
        get {
            let stored = UserDefaults.standard.string(forKey: DefaultsKey.themeID)
            if let stored, stored == Self.systemThemeID || themes.contains(where: { $0.id == stored }) {
                return stored
            }

            if themes.contains(where: { $0.id == Self.preferredThemeID }) {
                return Self.preferredThemeID
            }

            return themes.first?.id ?? Self.systemThemeID
        }
        set {
            UserDefaults.standard.set(newValue, forKey: DefaultsKey.themeID)
            // Switching themes restarts rotation: otherwise the new theme
            // resumes at the old theme's offset and its first sound looks
            // randomly skipped.
            rotation.reset()
        }
    }

    /// `nil` means the System theme (or a pack that is no longer installed).
    var currentTheme: SoundTheme? {
        let id = themeID
        guard id != Self.systemThemeID else {
            return nil
        }
        return themes.first { $0.id == id }
    }

    /// Playback volume. 0.7 by default: an event sound sits behind whatever the
    /// user is listening to.
    var volume: Float {
        get {
            guard UserDefaults.standard.object(forKey: DefaultsKey.volume) != nil else {
                return 0.7
            }
            return Float(UserDefaults.standard.double(forKey: DefaultsKey.volume))
        }
        set {
            UserDefaults.standard.set(Double(newValue), forKey: DefaultsKey.volume)
        }
    }

    // MARK: - Playback

    private var rotation = SoundRotation()

    /// Players currently sounding.
    ///
    /// A strong reference is mandatory: `AVAudioPlayer.play()` is asynchronous
    /// and a released player stops instantly, so without this a sound cuts off
    /// mid-file with no error at all. The delegate removes them when finished.
    private var playing: [AVAudioPlayer] = []

    func play(_ cue: SoundCue, isMuted: Bool) {
        guard !isMuted else {
            return
        }

        guard let theme = currentTheme else {
            NotificationSoundService.play(NotificationSoundService.selectedSoundName, volume: volume)
            return
        }

        guard let file = rotation.pick(cue, from: theme) else {
            return
        }

        play(file: file, in: theme)
    }

    /// Settings preview. Deliberately shares the rotation with `play` so that
    /// pressing a category twice demonstrates the alternates the pack ships.
    func preview(_ cue: SoundCue) {
        play(cue, isMuted: false)
    }

    private func play(file: String, in theme: SoundTheme) {
        guard let url = EventSoundService.audioURL(for: file, in: theme) else {
            return
        }

        // A manifest entry whose file is missing has to be reported: the symptom
        // is "one sound occasionally does not play", which is unreadable
        // otherwise. Recoverable at this boundary, so it is not fatal.
        guard FileManager.default.fileExists(atPath: url.path) else {
            NSLog("[sound] missing file \(theme.id)/\(file) at \(url.path)")
            return
        }

        do {
            let player = try AVAudioPlayer(contentsOf: url)
            player.volume = volume
            player.delegate = playbackDelegate
            player.play()
            playing.append(player)
        } catch {
            NSLog("[sound] failed to play \(theme.id)/\(file): \(error.localizedDescription)")
        }
    }

    func stopAll() {
        for player in playing {
            player.stop()
        }
        playing.removeAll()
    }

    private lazy var playbackDelegate = SoundPlaybackDelegate { [weak self] player in
        // Remove by identity, not by clearing: when two sounds overlap, the
        // first one finishing must not stop the second.
        self?.playing.removeAll { $0 === player }
    }

    // MARK: - Diagnostics

    var diagnostics: String {
        guard let theme = currentTheme else {
            let packs = themes.isEmpty ? "no packs installed" : "\(themes.count) packs installed"
            return "theme=system sound=\(NotificationSoundService.selectedSoundName) (\(packs))"
        }

        let cues = SoundCue.allCases.map { cue in
            let count = theme.files(for: cue).count
            return "\(cue.rawValue)=\(count)\(theme.isBorrowing(for: cue) ? "(borrowed)" : "")"
        }.joined(separator: " ")

        return "theme=\(theme.id) license=\(theme.license) entries=\(theme.entryCount) "
            + "volume=\(String(format: "%.2f", volume)) \(cues)"
    }
}

/// `AVAudioPlayerDelegate` requires an `NSObject`. A small standalone class
/// keeps `EventSoundService` out of the ObjC runtime for the sake of one
/// callback.
private final class SoundPlaybackDelegate: NSObject, AVAudioPlayerDelegate {
    private let didFinish: (AVAudioPlayer) -> Void

    init(didFinish: @escaping (AVAudioPlayer) -> Void) {
        self.didFinish = didFinish
    }

    func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        didFinish(player)
    }

    /// Release on decode errors too, otherwise that player stays in `playing`
    /// forever.
    func audioPlayerDecodeErrorDidOccur(_ player: AVAudioPlayer, error: Error?) {
        didFinish(player)
    }
}
