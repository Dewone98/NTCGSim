//
//  DeckStore.swift
//  NTCGSimulator
//
//  Saved decks, kept on the device as a JSON file.
//

import Foundation

@Observable
final class DeckStore {

    /// Decks the player has built, newest first.
    private(set) var decks: [Deck] = []

    private static var fileURL: URL? {
        FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first?
            .appendingPathComponent("decks.json")
    }

    init() {
        load()
    }

    // MARK: Queries

    func deck(id: UUID) -> Deck? {
        decks.first { $0.id == id }
    }

    // MARK: Mutations

    /// Inserts a new deck or replaces an existing one with the same id.
    func save(_ deck: Deck) {
        var updated = deck
        updated.updatedAt = Date()

        if let index = decks.firstIndex(where: { $0.id == deck.id }) {
            decks[index] = updated
        } else {
            decks.insert(updated, at: 0)
        }
        persist()
    }

    func delete(id: UUID) {
        decks.removeAll { $0.id == id }
        persist()
    }

    /// Copies a deck under a new identity, for "duplicate" in the builder.
    @discardableResult
    func duplicate(id: UUID) -> Deck? {
        guard var copy = deck(id: id) else { return nil }
        copy.id = UUID()
        copy.name = "\(copy.name) copy"
        copy.isPreconstructed = false
        copy.createdAt = Date()
        save(copy)
        return copy
    }

    // MARK: Disk

    private func load() {
        guard
            let url = Self.fileURL,
            let data = try? Data(contentsOf: url),
            let stored = try? JSONDecoder().decode([Deck].self, from: data)
        else { return }
        decks = stored.sorted { $0.updatedAt > $1.updatedAt }
    }

    private func persist() {
        guard let url = Self.fileURL else { return }
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        if let data = try? JSONEncoder().encode(decks) {
            try? data.write(to: url, options: .atomic)
        }
    }
}
