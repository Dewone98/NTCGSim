//
//  RemoteArtFetcher.swift
//  NTCGSimulator
//
//  Fetches card illustrations from a source the player configures.
//
//  The app ships with no source set and no artwork inside it. The player
//  supplies a URL template pointing at images they have the right to use; the
//  files are downloaded onto their device and cached by CardArtStore, so the
//  app binary never carries someone else's artwork.
//

import Foundation

/// Progress and results of a bulk fetch, for driving the Settings UI.
@Observable
final class ArtFetchProgress {
    /// Cards attempted so far.
    var completed: Int = 0

    /// Cards in this run.
    var total: Int = 0

    /// Cards whose art downloaded and installed.
    var succeeded: Int = 0

    /// Card ids that produced an error, with the reason.
    var failures: [(cardID: String, reason: String)] = []

    /// True while a fetch is in flight.
    var isRunning: Bool = false

    /// Set when the player asked to stop.
    var isCancelled: Bool = false

    var fraction: Double {
        total > 0 ? Double(completed) / Double(total) : 0
    }

    /// A one-line summary once the run has finished.
    var summary: String {
        guard !isRunning else { return "Fetching \(completed) of \(total)…" }
        guard total > 0 else { return "" }
        var parts = ["Downloaded \(succeeded) of \(total)"]
        if !failures.isEmpty { parts.append("\(failures.count) failed") }
        if isCancelled { parts.append("stopped") }
        return parts.joined(separator: " · ")
    }

    func reset(total: Int) {
        completed = 0
        succeeded = 0
        failures = []
        isCancelled = false
        isRunning = true
        self.total = total
    }
}

/// Downloads card art from a configurable URL template.
struct RemoteArtFetcher {

    /// The placeholder replaced with a card's collector number.
    static let idPlaceholder = "{id}"

    /// Why a fetch could not proceed.
    enum FetchError: LocalizedError {
        case templateEmpty
        case templateMissingPlaceholder
        case invalidURL(String)
        case badStatus(Int)
        case notAnImage

        var errorDescription: String? {
            switch self {
            case .templateEmpty:
                return "Set an image source first."
            case .templateMissingPlaceholder:
                return "The address needs \(RemoteArtFetcher.idPlaceholder) where the card number goes."
            case .invalidURL(let text):
                return "That address is not valid: \(text)"
            case .badStatus(let code):
                return "The server answered \(code)."
            case .notAnImage:
                return "That address did not return an image."
            }
        }
    }

    /// Checks a template before the player commits to a long run.
    static func validate(template: String) -> Result<Void, FetchError> {
        let trimmed = template.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .failure(.templateEmpty) }
        guard trimmed.contains(idPlaceholder) else {
            return .failure(.templateMissingPlaceholder)
        }
        let probe = trimmed.replacingOccurrences(of: idPlaceholder, with: "TEST")
        guard let url = URL(string: probe), url.scheme != nil, url.host != nil else {
            return .failure(.invalidURL(trimmed))
        }
        return .success(())
    }

    /// Builds the address for one card.
    static func url(for cardID: String, template: String) -> URL? {
        let encoded = cardID.addingPercentEncoding(
            withAllowedCharacters: .urlPathAllowed
        ) ?? cardID
        let text = template
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: idPlaceholder, with: encoded)
        return URL(string: text)
    }

    /// Downloads one card's illustration and installs it.
    @MainActor
    static func fetch(
        cardID: String,
        template: String,
        into store: CardArtStore
    ) async throws {
        guard let url = url(for: cardID, template: template) else {
            throw FetchError.invalidURL(cardID)
        }

        let (data, response) = try await URLSession.shared.data(from: url)

        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw FetchError.badStatus(http.statusCode)
        }

        // Write to a temporary file so the store's own validation and copying
        // logic is reused rather than duplicated here.
        let ext = url.pathExtension.isEmpty ? "png" : url.pathExtension
        let temporary = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(cardID).\(ext)")
        try data.write(to: temporary, options: .atomic)
        defer { try? FileManager.default.removeItem(at: temporary) }

        if case .failure(let error) = store.setArt(from: temporary, forCardID: cardID) {
            throw error
        }
    }

    /// Fetches art for many cards, one at a time so a large pool cannot open
    /// hundreds of simultaneous connections against someone's server.
    ///
    /// - Parameters:
    ///   - cards: the cards to fetch.
    ///   - skipExisting: leave cards that already have art untouched.
    @MainActor
    static func fetchAll(
        cards: [Card],
        template: String,
        into store: CardArtStore,
        progress: ArtFetchProgress,
        skipExisting: Bool = true
    ) async {
        let targets = skipExisting
            ? cards.filter { !store.hasArt(forCardID: $0.id) }
            : cards

        progress.reset(total: targets.count)

        for card in targets {
            if progress.isCancelled { break }

            do {
                try await fetch(cardID: card.id, template: template, into: store)
                progress.succeeded += 1
            } catch {
                progress.failures.append(
                    (cardID: card.id,
                     reason: (error as? LocalizedError)?.errorDescription
                             ?? error.localizedDescription)
                )
            }
            progress.completed += 1

            // A small gap between requests, so a bulk run behaves politely
            // toward whatever server the player pointed this at.
            try? await Task.sleep(for: .milliseconds(120))
        }

        progress.isRunning = false
        store.rebuildManifest()
    }
}
