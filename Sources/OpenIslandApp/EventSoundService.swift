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
/// No audio ships with this repository (licensing — see `SoundTheme`), so a
/// fresh install has no packs. Rather than being silent, the reserved theme id
/// `system` plays a macOS alert sound for every cue, which is exactly the
/// behavior Open Island had before packs existed. Installing a pack via
/// `scripts/fetch-sound-packs.sh` upgrades that to per-event sounds.
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

    /// Packs found on disk. `private(set)` so the settings pane and the player
    /// can never disagree about what is installed.
    private(set) var themes: [SoundTheme] = SoundTheme.installedThemes(in: SoundPackLocation.directoryURL)

    /// Rescans the packs directory — used after the fetch script runs while the
    /// app is open.
    func reloadThemes() {
        themes = SoundTheme.installedThemes(in: SoundPackLocation.directoryURL)
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
        let url = SoundPackLocation.directoryURL
            .appendingPathComponent(theme.id, isDirectory: true)
            .appendingPathComponent(file)

        // A manifest entry whose file is missing has to be reported: the symptom
        // is "one sound occasionally does not play", which is unreadable
        // otherwise. Recoverable at this boundary, so it is not fatal.
        guard FileManager.default.fileExists(atPath: url.path) else {
            NSLog("[sound] missing file \(theme.id)/\(file) — re-run scripts/fetch-sound-packs.sh")
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
