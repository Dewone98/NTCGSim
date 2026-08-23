//
//  MusicLibrary.swift
//  NTCGSimulator
//
//  Where the background music comes from — and, deliberately, nothing else.
//
//  The app ships with no music of its own. The tracks that would suit it are
//  commercial recordings, and shipping those is not ours to do, so the library
//  is built the way the card-art importer was built: a discovery pass that
//  plays whatever files are actually present and simply finds nothing when
//  nothing has been added. An empty library is a supported state, not a
//  failure — `MusicPlayer` stays silent and Settings says where to put files.
//
//  Two places are searched. Resources/Music inside the bundle is for anything
//  that ever does ship with the app, and the app's own Application Support/Music
//  folder is for files the owner drops in afterwards, so adding a track never
//  needs a rebuild. A file in the second folder wins over a bundled file of the
//  same name, because that folder belongs to the owner and an override there is
//  the only way they could replace a shipped track.
//

import Foundation

// MARK: - Track

/// One playable audio file the library found.
struct MusicTrack: Identifiable, Hashable {

    /// Which of the two searched folders a file came from.
    enum Source: Hashable {
        /// Shipped inside the app bundle, under Resources/Music.
        case bundled

        /// Copied into the app's Music folder after install.
        case added
    }

    /// The filename without its extension, lowercased.
    ///
    /// The persisted choice in `SettingsStore` stores this rather than a path,
    /// because a container path changes on every install while a filename does
    /// not. The consequence is the one a folder of loose files leads people to
    /// expect: replacing a file keeps the choice, renaming it forgets it.
    let id: String

    /// The name the Settings list shows.
    let title: String

    let url: URL
    let source: Source
}

// MARK: - Library

/// The set of tracks available to play, rebuilt on demand.
///
/// Discovery is a directory listing and a bundle lookup, so `refresh()` is
/// cheap enough to call whenever the owner says they have added something —
/// which is the only way the app can learn about a file copied in while it was
/// already running.
@Observable
final class MusicLibrary {

    /// Everything playable, ordered by title the way a person reads a list.
    private(set) var tracks: [MusicTrack] = []

    init() {
        refresh()
    }

    // MARK: Formats

    /// Extensions accepted from the Music folder, matched case-insensitively.
    ///
    /// All four decode on the device without any conversion step; anything
    /// else is ignored rather than handed to `AVAudioPlayer` to fail on.
    static let supportedExtensions: Set<String> = ["mp3", "m4a", "aac", "wav"]

    /// The same formats spelled both ways, because the bundle lookup matches
    /// the extension literally and an exported file may carry either case.
    private static let bundleExtensionSpellings = [
        "mp3", "MP3", "m4a", "M4A", "aac", "AAC", "wav", "WAV",
    ]

    /// Folder inside the bundle holding any shipped music.
    private static let bundleSubdirectory = "Music"

    // MARK: The owner's folder

    /// Where files added after install live.
    static var addedTracksDirectoryURL: URL? {
        FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first?
            .appendingPathComponent("Music", isDirectory: true)
    }

    /// The same folder as text, for the line Settings shows so the owner can
    /// find it. Decoded rather than percent-encoded — it is meant to be read
    /// and copied, not opened as a URL.
    var addedTracksPath: String {
        Self.addedTracksDirectoryURL?.path(percentEncoded: false)
            ?? "This device has no Application Support folder."
    }

    // MARK: Queries

    func track(id: String) -> MusicTrack? {
        tracks.first { $0.id == id }
    }

    var isEmpty: Bool { tracks.isEmpty }

    /// The next track for shuffle play.
    ///
    /// Shuffle's one promise is that it never plays the same thing twice in a
    /// row, so `currentID` is dropped from the candidates — but only while
    /// something else remains, since a library of one track has to repeat it or
    /// fall silent. `skipping` carries files the player has just failed to
    /// open, so a corrupt file is stepped over instead of being drawn again.
    func nextShuffled(after currentID: String?, skipping: Set<String> = []) -> MusicTrack? {
        var candidates = tracks.filter { !skipping.contains($0.id) }
        if candidates.count > 1 {
            candidates.removeAll { $0.id == currentID }
        }
        return candidates.randomElement()
    }

    // MARK: Discovery

    /// Rebuilds `tracks` from both folders.
    ///
    /// Keyed by id while merging so the owner's folder shadows a bundled file
    /// of the same name, then sorted with `localizedStandardCompare` so
    /// "Track 2" sorts before "Track 10" rather than after it.
    func refresh() {
        var found: [String: MusicTrack] = [:]
        for track in bundledTracks() { found[track.id] = track }
        for track in addedTracks()   { found[track.id] = track }

        tracks = found.values.sorted {
            let byTitle = $0.title.localizedStandardCompare($1.title)
            return byTitle == .orderedSame ? $0.id < $1.id : byTitle == .orderedAscending
        }
    }

    /// Bundled audio, looked for in the resource folder AND at the bundle root.
    ///
    /// Xcode's synchronized folders FLATTEN a resource directory into the bundle
    /// root, so a lookup scoped to the subdirectory finds nothing even though
    /// the files shipped. Searching both and de-duplicating by filename means
    /// the library works whichever way the build lays the resources out — the
    /// card artwork needed exactly the same fallback.
    private func bundledTracks() -> [MusicTrack] {
        var seen: Set<String> = []
        var found: [MusicTrack] = []

        for ext in Self.bundleExtensionSpellings {
            let scoped = Bundle.main.urls(
                forResourcesWithExtension: ext,
                subdirectory: Self.bundleSubdirectory
            ) ?? []
            let atRoot = Bundle.main.urls(
                forResourcesWithExtension: ext,
                subdirectory: nil
            ) ?? []

            for url in scoped + atRoot {
                let name = url.lastPathComponent
                guard !seen.contains(name) else { continue }
                seen.insert(name)
                found.append(Self.track(at: url, source: .bundled))
            }
        }
        return found
    }

    /// Lists the owner's folder, creating it first so the path Settings prints
    /// is a folder that exists and can be copied into rather than one they have
    /// to make themselves.
    private func addedTracks() -> [MusicTrack] {
        guard let directory = Self.addedTracksDirectoryURL else { return [] }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let contents = (try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles, .skipsSubdirectoryDescendants]
        )) ?? []

        return contents.compactMap { url in
            guard Self.supportedExtensions.contains(url.pathExtension.lowercased()) else {
                return nil
            }
            return Self.track(at: url, source: .added)
        }
    }

    private static func track(at url: URL, source: MusicTrack.Source) -> MusicTrack {
        let stem = url.deletingPathExtension().lastPathComponent
        return MusicTrack(
            id: stem.lowercased(),
            title: displayName(fromStem: stem),
            url: url,
            source: source
        )
    }

    /// Turns a filename into something worth reading in a list.
    ///
    /// Only underscores are opened out into spaces and runs of whitespace are
    /// collapsed. Hyphens are left alone on purpose: they nearly always
    /// separate an artist from a title, and replacing them would turn one
    /// readable line into two halves of a sentence.
    private static func displayName(fromStem stem: String) -> String {
        let opened = stem
            .replacingOccurrences(of: "_", with: " ")
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
        return opened.isEmpty ? stem : opened
    }
}
