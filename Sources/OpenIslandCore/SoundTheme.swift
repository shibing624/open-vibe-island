import Foundation

/// Where installed sound packs live.
///
/// Application Support rather than the app bundle: packs are downloaded, not
/// shipped (see `SoundTheme`), and a downloaded pack must survive app updates
/// and work the same for `swift run` and for an installed `.app`. Writing into
/// the bundle would also break its code signature.
public enum SoundPackLocation {
    public static var directoryURL: URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        return appSupport
            .appendingPathComponent("OpenIsland", isDirectory: true)
            .appendingPathComponent("SoundPacks", isDirectory: true)
    }
}

/// One kind of event sound.
///
/// The five cases are the CESP (Community Event Sound Pack) v1.0 category set
/// used by the PeonPing registry, mapped onto Open Island's own event
/// vocabulary. Keeping both names side by side is deliberate: `SoundCue` is the
/// domain language of this repository (it lines up with `AgentEvent`), while
/// `session.start` is the wire spelling used by upstream pack manifests.
/// Collapsing them into one would force a mental translation at every read.
public enum SoundCue: String, CaseIterable, Sendable, Equatable {
    /// A new session was registered.
    ///
    /// No event routes to this cue today — see `SoundCueRouter` for why. The
    /// case stays because it is one row of the upstream category table, and the
    /// settings pane previews cues by `allCases`: dropping it would silently
    /// hide a sound every pack ships.
    case sessionStart
    /// The user submitted a prompt — only the first turn of a session.
    case taskAcknowledge
    /// The turn finished.
    case taskComplete
    /// The turn failed.
    case taskError
    /// Someone is waiting on the user (permission request or question).
    case inputRequired

    /// The category key as written in a CESP manifest.
    public var upstreamKey: String {
        switch self {
        case .sessionStart: "session.start"
        case .taskAcknowledge: "task.acknowledge"
        case .taskComplete: "task.complete"
        case .taskError: "task.error"
        case .inputRequired: "input.required"
        }
    }
}

public enum SoundThemeError: Error, Equatable {
    /// A manifest with no playable entry at all.
    case emptyCategories(id: String)
}

/// A sound pack: a directory of audio files plus a `theme.json` manifest that
/// says which file belongs to which event category.
///
/// ## Where the audio lives
///
/// The Orc Peon pack is bought out and bundled with the app (see
/// `EventSoundService.bundledThemes`), so a fresh install has per-event
/// sounds without downloading anything. Further packs are installed under
/// `~/Library/Application Support/OpenIsland/SoundPacks/` by
/// `scripts/fetch-sound-packs.sh`; the fetch script's table says which packs
/// are safe to download for personal use.
///
/// A pack that is missing on disk therefore has to be *explained*, not merely
/// tolerated: the failure mode is "nothing plays", which reads as a broken
/// player. The settings pane names the script to run.
///
/// ## Categories the manifest does not have
///
/// Some upstream packs omit a category outright. In that case this type falls
/// back to the rest of the same pack rather than to a macOS system alert:
/// mixing a system "Bottle" into an Orc Peon pack sounds like a defect, while
/// borrowing another peon line still sounds like the pack the user chose. The
/// fallback order is fixed (category name, then manifest order) so the choice
/// is reproducible — randomness lives in `SoundRotation`, which is testable.
public struct SoundTheme: Sendable, Equatable, Identifiable {

    /// One playable sound inside a pack.
    public struct Entry: Sendable, Equatable {
        /// File name, relative to the pack directory (`PeonAngry4.wav`).
        /// Audio is flat inside the pack; categories exist only in the manifest.
        public let file: String
        /// The one-line description upstream ships (`"Me not that kind of orc!"`).
        ///
        /// Used only as a preview button title. It never participates in
        /// choosing a sound: matching labels against "which one sounds like an
        /// error" would be guessing, and the manifest already says.
        public let label: String

        public init(file: String, label: String) {
            self.file = file
            self.label = label
        }
    }

    /// Directory name, and the value persisted in `UserDefaults`.
    public let id: String
    public let displayName: String
    public let version: String
    /// The license the pack declares, if any. Passed through verbatim and
    /// never interpreted in code — deciding whether a license permits
    /// something is a human judgement; the app's job is to show the
    /// attribution. Empty when the pack declares none (the bundled pack).
    public let license: String
    public let author: String
    /// Upstream repository, shown for attribution.
    public let sourceRepo: String
    /// Directory the audio files live in. Bundled packs point inside the app's
    /// resource bundle; fetched packs point under Application Support. Audio
    /// resolution is the caller's job, so this is the only field that says
    /// where to actually read a file from.
    public let audioDirectory: URL?
    /// Upstream category key (`session.start`) to the entries available for it.
    public let categories: [String: [Entry]]

    public init(
        id: String,
        displayName: String,
        version: String,
        license: String,
        author: String,
        sourceRepo: String,
        audioDirectory: URL? = nil,
        categories: [String: [Entry]]
    ) {
        self.id = id
        self.displayName = displayName
        self.version = version
        self.license = license
        self.author = author
        self.sourceRepo = sourceRepo
        self.audioDirectory = audioDirectory
        self.categories = categories
    }

    public var entryCount: Int {
        categories.values.reduce(0) { $0 + $1.count }
    }

    /// Entries that may play for this cue, falling back to the whole pack when
    /// the manifest has no entry for the category.
    public func entries(for cue: SoundCue) -> [Entry] {
        let own = categories[cue.upstreamKey] ?? []
        if !own.isEmpty {
            return own
        }

        return categories.keys.sorted().flatMap { categories[$0] ?? [] }
    }

    public func files(for cue: SoundCue) -> [String] {
        entries(for: cue).map(\.file)
    }

    /// Whether this cue is borrowing from other categories, so the settings
    /// pane can say so instead of leaving the user to wonder why two events
    /// sound alike.
    public func isBorrowing(for cue: SoundCue) -> Bool {
        (categories[cue.upstreamKey] ?? []).isEmpty
    }

    // MARK: - Manifest

    /// The `theme.json` shape written by `scripts/fetch-sound-packs.sh`.
    ///
    /// Field names keep the CESP spelling (`display_name`, not `displayName`)
    /// so the script *trims* the upstream manifest instead of translating it —
    /// one less place where the two sides can drift apart.
    private struct Manifest: Decodable {
        struct Author: Decodable {
            let name: String?
        }

        struct Entry: Decodable {
            let file: String
            let label: String?
        }

        let name: String?
        let display_name: String?
        let version: String?
        let license: String?
        let author: Author?
        let source_repo: String?
        let categories: [String: [Entry]]
    }

    public init(manifest data: Data, id: String, audioDirectory: URL? = nil) throws {
        let manifest = try JSONDecoder().decode(Manifest.self, from: data)

        let categories = manifest.categories
            .mapValues { entries in
                entries.map { Entry(file: $0.file, label: $0.label ?? "") }
            }
            .filter { !$0.value.isEmpty }

        guard !categories.isEmpty else {
            throw SoundThemeError.emptyCategories(id: id)
        }

        self.id = id
        self.displayName = manifest.display_name ?? manifest.name ?? id
        self.version = manifest.version ?? ""
        self.license = manifest.license ?? ""
        self.author = manifest.author?.name ?? ""
        self.sourceRepo = manifest.source_repo ?? ""
        self.audioDirectory = audioDirectory
        self.categories = categories
    }

    /// Loads every installed pack under `directory`.
    ///
    /// A subdirectory without a readable `theme.json` is skipped. That is a
    /// contract, not leniency: manifests are written by the fetch script, so a
    /// directory without one is not a pack (a half-finished download, or files
    /// someone dropped in by hand) and guessing its categories would only play
    /// the wrong sound.
    public static func installedThemes(in directory: URL) -> [SoundTheme] {
        let contents = (try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isDirectoryKey]
        )) ?? []

        return contents
            .compactMap { url -> SoundTheme? in
                guard (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true,
                      let data = try? Data(contentsOf: url.appendingPathComponent("theme.json")) else {
                    return nil
                }

                return try? SoundTheme(manifest: data, id: url.lastPathComponent)
            }
            .sorted { $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending }
    }
}

/// Rotation between multiple sounds in the same category.
///
/// Plays them in order rather than at random: random repeats the same file
/// often enough that it reads as a stuck player, while a counter is one integer
/// and can be asserted in a test.
///
/// Counters are kept per cue. Three finished tasks in a row should produce three
/// different completion sounds instead of having their position shifted by the
/// errors in between.
public struct SoundRotation: Sendable {
    private var counts: [SoundCue: Int] = [:]

    public init() {}

    /// The file to play for this cue, or `nil` when the pack has nothing at all.
    public mutating func pick(_ cue: SoundCue, from theme: SoundTheme) -> String? {
        let files = theme.files(for: cue)
        guard !files.isEmpty else {
            return nil
        }

        let index = counts[cue, default: 0]
        counts[cue] = index + 1
        return files[index % files.count]
    }

    /// Restarts rotation, e.g. after switching packs — otherwise the new pack
    /// would resume at the previous pack's offset and its first sound would
    /// look randomly skipped.
    public mutating func reset() {
        counts.removeAll()
    }

    public func count(for cue: SoundCue) -> Int {
        counts[cue, default: 0]
    }
}
