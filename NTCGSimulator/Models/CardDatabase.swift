//
//  CardDatabase.swift
//  NTCGSimulator
//
//  Loads the card pool and answers lookups for it.
//
//  The pool is assembled from two sources, in order:
//
//    1. `cards.json` bundled with the app — a demo set with generated art.
//    2. Any `cards.json` the player has imported into Application Support,
//       which replaces the bundled set entirely.
//
//  See Resources/CARD_DATA.md for the import format.
//

import Foundation
import SwiftUI

@Observable
final class CardDatabase {

    /// Every card in the active pool, in display order.
    private(set) var cards: [Card] = []

    /// Fast lookup by collector number.
    private var index: [String: Card] = [:]

    /// Each card beside the text a search matches against. Built with the pool
    /// so a keystroke never has to lowercase the whole set again.
    private var searchIndex: [SearchEntry] = []

    /// Bumped every time the pool is replaced. Views that memoise derived work
    /// key off this to tell "a new pool arrived" from "SwiftUI drew again".
    private(set) var poolRevision = 0

    /// True when the pool came from an imported file rather than the bundle.
    private(set) var usingImportedData = false

    /// Set when the most recent import failed, for surfacing in Settings.
    private(set) var lastImportError: String?

    /// Illustrations the player has installed. Owned here so that
    /// `artwork(for:)` stays the single lookup every view already uses.
    let artStore = CardArtStore()

    // MARK: Derived pools

    // These four are read from inside `ForEach` on the Collection screen, so a
    // computed property would rebuild them on every render pass — once per
    // scrolled frame. They are stored instead, refreshed by `apply(_:imported:)`
    // whenever the pool changes, and stay observable because they are stored
    // properties on an `@Observable` object.

    /// Every Leader in the pool.
    private(set) var leaders: [Card] = []

    /// Every distinct trait in the pool, alphabetised — drives the filter list.
    private(set) var allTraits: [String] = []

    /// Every distinct set code in the pool.
    private(set) var allSets: [String] = []

    /// The Chakra cards a player can choose between for their board art.
    private(set) var chakraCards: [Card] = []

    // MARK: Lifecycle

    init() {
        load()
    }

    /// Builds a database around a fixed pool, bypassing disk entirely.
    /// Used by tests and by SwiftUI previews that need a known set of cards.
    init(cards: [Card]) {
        apply(cards, imported: false)
    }

    /// Loads the imported pool if present, else the bundled demo set.
    func load() {
        if let imported = Self.importedFileURL,
           FileManager.default.fileExists(atPath: imported.path),
           let pool = try? Self.decode(contentsOf: imported) {
            apply(pool, imported: true)
            return
        }
        if let bundled = Bundle.main.url(forResource: "cards", withExtension: "json"),
           let pool = try? Self.decode(contentsOf: bundled) {
            apply(pool, imported: false)
            return
        }
        apply([], imported: false)
    }

    /// The single place a pool becomes "the pool". Every derived collection is
    /// rebuilt here, which is what makes them safe to store: import and reset
    /// both funnel through this method.
    private func apply(_ pool: [Card], imported: Bool) {
        cards = pool.sorted(by: Card.displayOrder)
        index = Dictionary(cards.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        searchIndex = cards.map(SearchEntry.init)

        leaders = cards.filter { $0.type == .leader }
        chakraCards = cards.filter { $0.type == .chakra }
        allTraits = Array(Set(cards.flatMap(\.traits))).sorted()
        allSets = Array(Set(cards.map(\.setCode))).sorted()

        usingImportedData = imported
        poolRevision &+= 1
    }

    private static func decode(contentsOf url: URL) throws -> [Card] {
        let data = try Data(contentsOf: url)
        return try JSONDecoder().decode([Card].self, from: data)
    }

    // MARK: Lookup

    /// The card with a given collector number, if it exists in the pool.
    func card(id: String) -> Card? { index[id] }

    /// Expands a list of IDs into cards, silently dropping unknown numbers.
    func cards(ids: [String]) -> [Card] { ids.compactMap { index[$0] } }

    /// Cards legal in a deck led by the given Leader.
    func cardsPlayable(with leader: Card) -> [Card] {
        cards.filter { $0.color == leader.color && $0.type.countsTowardDeckSize }
    }

    // MARK: Filtering

    /// A card beside the lowercased text a search is matched against.
    ///
    /// Lowercasing is the expensive half of searching — it allocates a new
    /// string per card per call — so it happens once, when the pool loads.
    private struct SearchEntry {
        let card: Card
        let haystack: String

        init(_ card: Card) {
            self.card = card
            self.haystack = "\(card.name) \(card.id) \(card.effect)".lowercased()
        }
    }

    /// Applies the Collection screen's filters.
    func filtered(
        searchText: String = "",
        colors: Set<CardColor> = [],
        types: Set<CardType> = [],
        rarities: Set<Rarity> = [],
        trait: String? = nil,
        setCode: String? = nil
    ) -> [Card] {
        let needle = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()

        return searchIndex.compactMap { entry -> Card? in
            if !needle.isEmpty, !entry.haystack.contains(needle)         { return nil }

            let card = entry.card
            if !colors.isEmpty,   !colors.contains(card.color)           { return nil }
            if !types.isEmpty,    !types.contains(card.type)             { return nil }
            if !rarities.isEmpty, !rarities.contains(card.rarity)        { return nil }
            if let trait,   !card.traits.contains(trait)                 { return nil }
            if let setCode, card.setCode != setCode                      { return nil }
            return card
        }
    }

    // MARK: Import / reset

    /// Where an imported `cards.json` lives.
    static var importedFileURL: URL? {
        FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first?
            .appendingPathComponent("cards.json")
    }

    /// Where illustrations live. Shown in Settings so the player knows where

    /// Validates and installs a replacement card pool.
    /// - Returns: the number of cards installed, or `nil` on failure.
    @discardableResult
    func importPool(from url: URL) -> Int? {
        lastImportError = nil
        do {
            let pool = try Self.decode(contentsOf: url)
            guard !pool.isEmpty else {
                lastImportError = "That file contained no cards."
                return nil
            }
            guard let destination = Self.importedFileURL else {
                lastImportError = "Could not reach the app's storage."
                return nil
            }
            try FileManager.default.createDirectory(
                at: destination.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let data = try JSONEncoder().encode(pool)
            try data.write(to: destination, options: .atomic)
            apply(pool, imported: true)
            return pool.count
        } catch {
            lastImportError = error.localizedDescription
            return nil
        }
    }

    /// Discards imported data and returns to the bundled demo set.
    func resetToBundledPool() {
        if let imported = Self.importedFileURL {
            try? FileManager.default.removeItem(at: imported)
        }
        lastImportError = nil
        load()
    }

    /// The illustration to draw for a card, or `nil` to fall back to generated
    /// art.
    ///
    /// Two sources are consulted, in order:
    ///   1. art installed by card id, which is how bulk import works and needs
    ///      no edits to `cards.json`;
    ///   2. an explicit `artFilename` on the card itself, for data sets that
    ///      name their files independently of the collector number.
    ///
    /// Both paths go through the art store, so the named-file case is
    /// downsampled and cached exactly like art installed by id — otherwise
    /// every draw of that card would decode the file again from scratch.
    /// The illustration for a card. Artwork ships in the app bundle, so this
    /// is the same picture on every install.
    func artwork(for card: Card) -> UIImage? {
        artStore.image(forCardID: card.id)
    }

    /// A size-appropriate illustration for a card, for grids and board slots
    /// that draw far smaller than the art is printed.
    func artwork(for card: Card, maxPixelSize: Int) -> UIImage? {
        artStore.image(forCardID: card.id, maxPixelSize: maxPixelSize)
    }


    /// How many cards in the current pool have an illustration installed.
    var cardsWithArtworkCount: Int {
        cards.reduce(0) { $0 + (artStore.hasArt(forCardID: $1.id) ? 1 : 0) }
    }
}
