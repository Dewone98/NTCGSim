//
//  StarterDecks.swift
//  NTCGSimulator
//
//  The four ready-made decks, transcribed from the reference simulator's own
//  prebuilt lists — Team 10, Mount Myoboku, The Taka and Uchiha Illusion —
//  with the reference's placeholder card numbers mapped onto this pool's ids
//  by name and stat line.
//
//  Each list is data, not derivation: fifty exact cards per deck, in the
//  order the reference prints them. The only construction logic left is the
//  safety net for an imported pool that no longer carries a listed number —
//  the gap is filled with the nearest same-colour bodies the pool does print,
//  so the deck stays legal at fifty cards and four copies, or is withheld
//  entirely when even that cannot be done.
//

import Foundation
import SwiftUI

// MARK: - List

/// One ready-made deck exactly as the reference ships it: a stable key, the
/// menu name, the Leader that fronts it, and every card number with its copy
/// count in the reference's printed order.
private struct StarterList {

    /// The reference's own deck key — `teamTen`, `mountMyoboku`, `theTaka`,
    /// `uchihaIllusion`. Hashed into the deck's stable identity.
    let key: String

    let name: String

    /// Collector number of the Leader that anchors the deck.
    let leaderID: String

    /// Card numbers with copy counts, in the reference's listed order.
    let counts: [(cardID: String, copies: Int)]
}

// MARK: - Provider

/// The reference's four prebuilt decks, resolved against the active pool.
enum StarterDecks {

    /// Every ready-made deck the current pool can field, in menu order.
    static func all(using database: CardDatabase) -> [Deck] {
        lists.compactMap { deck(for: $0, using: database) }
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

    // MARK: The reference lists

    /// The reference's `PREBUILT_DECKS`, verbatim apart from the id mapping:
    /// `N-choji`→SMP-01, `N-hinata`→SMP-02, `N-naruto-ex`→SMP-03,
    /// `N-orochimaru`→SMP-04, `N-sakura`→SMP-15, and `N-reveal-01…09` onto
    /// the SMP vanilla 3/6/6 bodies by name and traits. The reference slips
    /// its blue Sakura vanilla into the red Team 10 list; this pool prints
    /// SMP-13 red, so the same fifty cards are legal here.
    private static let lists: [StarterList] = [
        StarterList(
            key: "teamTen",
            name: "Team 10, Shadow and Expansion",
            leaderID: "N-001",
            counts: [
                ("N-011", 4), ("N-008", 4), ("SMP-01", 4), ("N-004", 4),
                ("K-039", 4), ("SMP-02", 4), ("N-006", 4), ("N-007", 4),
                ("N-005", 3), ("SMP-03", 3),
                ("SMP-13", 4), ("SMP-07", 4), ("SMP-06", 4)
            ]
        ),
        StarterList(
            key: "mountMyoboku",
            name: "Mount Myoboku Summons",
            leaderID: "N-001",
            counts: [
                ("N-005", 4), ("SMP-03", 4), ("N-004", 4), ("N-006", 4),
                ("N-007", 4), ("K-039", 4), ("N-008", 4), ("N-011", 4),
                ("SMP-01", 3), ("SMP-02", 3),
                ("SMP-12", 4), ("SMP-09", 4), ("SMP-07", 4)
            ]
        ),
        StarterList(
            key: "theTaka",
            name: "The Taka",
            leaderID: "N-012",
            counts: [
                ("N-010", 4), ("N-019", 4), ("N-021", 4), ("N-014", 4),
                ("N-015", 4), ("N-013", 4), ("N-016", 4), ("SMP-15", 4),
                ("SMP-04", 3), ("N-022", 3),
                ("SMP-11", 4), ("SMP-08", 4), ("SMP-05", 4)
            ]
        ),
        StarterList(
            key: "uchihaIllusion",
            name: "Uchiha Illusion",
            leaderID: "N-012",
            counts: [
                ("N-013", 4), ("N-016", 4), ("N-015", 4), ("N-014", 4),
                ("SMP-04", 4), ("SMP-15", 4), ("N-022", 4), ("N-010", 4),
                ("N-019", 3), ("N-021", 3),
                ("SMP-10", 4), ("SMP-08", 4), ("SMP-05", 4)
            ]
        )
    ]

    // MARK: Construction

    /// Resolves one list against the pool, or returns `nil` when the pool
    /// cannot field a legal fifty in the Leader's colour at all.
    private static func deck(for list: StarterList, using database: CardDatabase) -> Deck? {
        guard let leader = leader(for: list, using: database) else { return nil }

        // Take every listed card the pool still prints in the Leader's
        // colour, clamped to the copy limit. An id the pool lacks — or now
        // prints off-colour — leaves a gap for the substitution pass.
        var cardIDs: [String] = []
        var copies: [String: Int] = [:]
        for entry in list.counts {
            guard let card = database.card(id: entry.cardID),
                  card.color == leader.color,
                  card.type.countsTowardDeckSize else { continue }
            let taken = min(entry.copies, DeckRules.maxCopies - copies[card.id, default: 0])
            guard taken > 0 else { continue }
            cardIDs.append(contentsOf: Array(repeating: card.id, count: taken))
            copies[card.id, default: 0] += taken
        }

        // Substitution: fill any shortfall with the nearest same-colour
        // bodies the pool does print, in display order, up to the copy limit
        // on each — so an imported pool still yields a legal deck.
        if cardIDs.count < DeckRules.requiredSize {
            for card in database.cardsPlayable(with: leader) where cardIDs.count < DeckRules.requiredSize {
                let room = min(
                    DeckRules.maxCopies - copies[card.id, default: 0],
                    DeckRules.requiredSize - cardIDs.count
                )
                guard room > 0 else { continue }
                cardIDs.append(contentsOf: Array(repeating: card.id, count: room))
                copies[card.id, default: 0] += room
            }
        }
        guard cardIDs.count == DeckRules.requiredSize else { return nil }

        return Deck(
            id: identifier(for: list),
            name: list.name,
            leaderID: leader.id,
            cardIDs: ordered(cardIDs, using: database),
            isPreconstructed: true
        )
    }

    /// The listed Leader, or the pool's first Leader in the same colour when
    /// an imported pool renamed it. No Leader at all withholds the deck.
    private static func leader(for list: StarterList, using database: CardDatabase) -> Card? {
        if let exact = database.card(id: list.leaderID), exact.type == .leader {
            return exact
        }
        let wantedColor = database.card(id: list.leaderID)?.color
        return database.leaders.first { wantedColor == nil || $0.color == wantedColor }
            ?? database.leaders.first
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

    /// A stable id per list.
    ///
    /// Starters are rebuilt every time a view asks for them, so a random
    /// `UUID` would give SwiftUI a brand-new row on every redraw. Hashing the
    /// reference's own deck key keeps the identity fixed without persisting
    /// anything.
    private static func identifier(for list: StarterList) -> UUID {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325          // FNV-1a offset basis
        for byte in Array("starter:\(list.key)".utf8) {
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
#endif

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
