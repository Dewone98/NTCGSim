//
//  StarterDecks.swift
//  NTCGSimulator
//
//  Ready-made decks, derived from whatever card pool is loaded.
//
//  A new player has nothing to play with until they have hand-built fifty
//  cards, which is a poor first five minutes. Nothing here names a collector
//  number: each list is built from the pool by trait and by display order, so an
//  imported set produces its own starters — or none at all, when a colour cannot
//  fill a legal deck.
//

import Foundation
import SwiftUI

// MARK: - Theme

/// One ready-made list: a name, the colour whose Leader anchors it, and the
/// traits that decide which cards are reached for first.
private struct StarterTheme {
    let name: String

    /// The Leader's colour. The first Leader printed in this colour fronts the
    /// deck, so an imported set picks its own.
    let color: CardColor

    /// Traits the theme is about. Cards carrying more of them are taken first;
    /// everything after that comes from the colour in display order.
    let traits: [String]
}

// MARK: - Provider

/// Builds legal, playable decks out of the active pool.
enum StarterDecks {

    /// Support cards a starter aims to carry.
    ///
    /// Summoning a body is free, so a deck holding no Support cards leaves the
    /// chakra row with nothing to buy and the economy never comes into play.
    /// Trimmed automatically when a pool cannot print this many.
    static let preferredSupportCount = 8

    /// Every ready-made deck the current pool can actually fill, in menu order.
    static func all(using database: CardDatabase) -> [Deck] {
        themes.compactMap { deck(for: $0, using: database) }
    }

    /// A player-owned copy of a ready-made deck: fresh identity and no longer
    /// marked preconstructed, so editing the copy never disturbs the original.
    static func playerCopy(of deck: Deck) -> Deck {
        var copy = deck
        copy.id = UUID()
        copy.isPreconstructed = false
        copy.createdAt = Date()
        copy.updatedAt = Date()
        return copy
    }

    // MARK: Themes

    /// Two decks per Leader, so a player meets each colour twice over with a
    /// different plan rather than the same fifty cards renamed.
    private static let themes: [StarterTheme] = [
        StarterTheme(
            name: "Toad Summons",
            color: .red,
            traits: ["Toad", "Mount Myoboku", "Jinchuriki", "The Legendary Sannin"]
        ),
        StarterTheme(
            name: "Leaf Village Assault",
            color: .red,
            traits: ["Hidden Leaf Village", "Team 7", "Taijutsu", "The Five Kage"]
        ),
        StarterTheme(
            name: "The Taka",
            color: .blue,
            traits: ["The Taka", "Village Hidden in the Sound", "Snake", "Lightning"]
        ),
        StarterTheme(
            name: "Uchiha Illusion",
            color: .blue,
            traits: ["Uchiha Clan", "Illusion", "Akatsuki", "Special"]
        )
    ]

    // MARK: Construction

    /// Builds one theme, or returns `nil` when the pool cannot make it legal —
    /// no Leader in that colour, or too few cards to reach the required size.
    private static func deck(for theme: StarterTheme, using database: CardDatabase) -> Deck? {
        guard let leader = database.leaders.first(where: { $0.color == theme.color }) else { return nil }

        let pool = database.cardsPlayable(with: leader)

        // What chakra can actually be spent on: a Support card, or any card
        // with a Support line that may be played as a jutsu. A set printing no
        // Support cards at all still gives chakra a use through the latter, so
        // both count here — a deck holding neither plays with a dead resource.
        let sinks = pool.filter { $0.isChakraSink }
        let rest = pool.filter { !$0.isChakraSink }

        guard let sinkTarget = supportTarget(supports: sinks.count, bodies: rest.count) else { return nil }

        var cardIDs = copies(from: sinks, matching: theme, upTo: sinkTarget)
        cardIDs += copies(from: rest, matching: theme, upTo: DeckRules.requiredSize - cardIDs.count)

        // Top up from the whole pool if either bucket ran dry, so a lopsided
        // set still yields a legal deck rather than none.
        if cardIDs.count < DeckRules.requiredSize {
            cardIDs += copies(from: pool, matching: theme,
                              upTo: DeckRules.requiredSize - cardIDs.count,
                              excluding: cardIDs)
        }
        guard cardIDs.count == DeckRules.requiredSize else { return nil }

        return Deck(
            id: identifier(for: theme),
            name: theme.name,
            leaderID: leader.id,
            cardIDs: ordered(cardIDs, using: database),
            isPreconstructed: true
        )
    }

    /// How many of the fifty cards are Support.
    ///
    /// Aims at `preferredSupportCount`, but takes more when there are too few
    /// bodies to fill the rest, and fewer when the pool prints too few Support
    /// cards. `nil` means the colour cannot reach a legal deck at all.
    private static func supportTarget(supports: Int, bodies: Int) -> Int? {
        let supportCapacity = supports * DeckRules.maxCopies
        let bodyCapacity = bodies * DeckRules.maxCopies
        guard supportCapacity + bodyCapacity >= DeckRules.requiredSize else { return nil }

        let minimum = max(0, DeckRules.requiredSize - bodyCapacity)
        return min(supportCapacity, max(minimum, preferredSupportCount), DeckRules.requiredSize)
    }

    /// Takes up to `limit` cards, most on-theme first and up to the copy limit
    /// of each, so the deck reads as a themed list rather than a singleton pile.
    /// Tops a deck up from `cards`, respecting copies already taken.
    ///
    /// Used when one bucket runs dry: the deck must still reach exactly the
    /// required size without exceeding the four-copy limit on any card.
    private static func copies(
        from cards: [Card],
        matching theme: StarterTheme,
        upTo limit: Int,
        excluding taken: [String]
    ) -> [String] {
        guard limit > 0 else { return [] }

        var counts: [String: Int] = [:]
        for id in taken { counts[id, default: 0] += 1 }

        let preferred = cards.enumerated().sorted { lhs, rhs in
            let left = score(lhs.element, in: theme)
            let right = score(rhs.element, in: theme)
            return left == right ? lhs.offset < rhs.offset : left > right
        }

        var picked: [String] = []
        for entry in preferred where picked.count < limit {
            let already = counts[entry.element.id, default: 0]
            let room = min(DeckRules.maxCopies - already, limit - picked.count)
            guard room > 0 else { continue }
            picked.append(contentsOf: Array(repeating: entry.element.id, count: room))
            counts[entry.element.id] = already + room
        }
        return picked
    }

    private static func copies(from cards: [Card], matching theme: StarterTheme, upTo limit: Int) -> [String] {
        guard limit > 0 else { return [] }

        // Enumerate first so ties fall back to the pool's own display order,
        // which keeps a deck identical between launches.
        let preferred = cards.enumerated().sorted { lhs, rhs in
            let left = score(lhs.element, in: theme)
            let right = score(rhs.element, in: theme)
            return left == right ? lhs.offset < rhs.offset : left > right
        }

        var picked: [String] = []
        for entry in preferred where picked.count < limit {
            let room = min(DeckRules.maxCopies, limit - picked.count)
            picked.append(contentsOf: Array(repeating: entry.element.id, count: room))
        }
        return picked
    }

    /// How much of the theme a card carries.
    private static func score(_ card: Card, in theme: StarterTheme) -> Int {
        card.traits.reduce(0) { $0 + (theme.traits.contains($1) ? 1 : 0) }
    }

    /// Sorts the finished list the way the Collection and the editor sort, so
    /// opening a copy shows a tidy deck rather than the order it was filled in.
    private static func ordered(_ cardIDs: [String], using database: CardDatabase) -> [String] {
        cardIDs.sorted { lhs, rhs in
            guard
                let left = database.card(id: lhs),
                let right = database.card(id: rhs)
            else { return lhs < rhs }
            return Card.displayOrder(left, right)
        }
    }

    // MARK: Identity

    /// A stable id per theme.
    ///
    /// Starters are rebuilt every time a view asks for them, so a random `UUID`
    /// would give SwiftUI a brand-new row on every redraw. Hashing the theme
    /// keeps the identity fixed without persisting anything.
    private static func identifier(for theme: StarterTheme) -> UUID {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325          // FNV-1a offset basis
        for byte in Array("starter:\(theme.color.rawValue):\(theme.name)".utf8) {
            hash ^= UInt64(byte)
            hash = hash &* 0x100_0000_01b3                // FNV-1a prime
        }
        let tail = hash &* 0x9e37_79b9_7f4a_7c15          // spread into the low half

        let hex = String(format: "%016llx%016llx", hash, tail)
        let grouped = [
            hex.prefix(8),
            hex.dropFirst(8).prefix(4),
            hex.dropFirst(12).prefix(4),
            hex.dropFirst(16).prefix(4),
            hex.dropFirst(20)
        ]
        return UUID(uuidString: grouped.joined(separator: "-")) ?? UUID()
    }
}

// MARK: - Debug checks

#if DEBUG
extension StarterDecks {

    /// One line per starter describing its size, Support count and legality.
    ///
    /// Trips an assertion when a starter breaks the builder's own rules: a deck
    /// the player cannot legally play is worse than offering none at all.
    static func legalityReport(using database: CardDatabase) -> [String] {
        all(using: database).map { deck in
            let problems = deck.problems(using: database)
            assert(
                problems.isEmpty,
                "Starter deck \(deck.name) is illegal: \(problems.map(\.message).joined(separator: " "))"
            )

            let supports = deck.cardIDs.reduce(0) { $0 + (database.card(id: $1)?.isChakraSink == true ? 1 : 0) }
            let verdict = problems.isEmpty
                ? "legal"
                : problems.map(\.message).joined(separator: " ")
            return "\(deck.name) — \(deck.count) cards, \(supports) support — \(verdict)"
        }
    }
}

// MARK: - Preview

#Preview("Starter legality") {
    let database = CardDatabase()

    ScrollView {
        VStack(alignment: .leading, spacing: Metrics.spacingS) {
            Text("Ready-made decks").sectionLabel()

            ForEach(StarterDecks.legalityReport(using: database), id: \.self) { line in
                Text(line)
                    .font(Typeface.body(13))
                    .foregroundStyle(Palette.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(Metrics.spacingL)
    }
    .background(Palette.backdrop)
    .environment(database)
}
#endif
