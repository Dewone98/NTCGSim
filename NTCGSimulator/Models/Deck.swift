//
//  Deck.swift
//  NTCGSimulator
//
//  A saved deck plus the construction rules the Deck Builder enforces.
//

import Foundation

/// Deck construction limits. Kept in one place so a rules change is a one-line
/// edit rather than a hunt through the builder UI.
enum DeckRules {
    /// A legal deck holds exactly this many cards, excluding the Leader.
    static let requiredSize = 50

    /// No more than this many copies of any one card number.
    static let maxCopies = 4

    /// The Classic format runs on smaller fixed decks.
    static let classicSize = 30
}

/// A player-built deck: one Leader plus a main deck of card IDs.
struct Deck: Codable, Identifiable, Hashable {
    var id: UUID = UUID()
    var name: String = ""

    /// Collector number of the Leader that anchors this deck.
    var leaderID: String

    /// Main-deck card IDs. Repeats represent copies, so this array's length is
    /// the deck size.
    var cardIDs: [String] = []

    /// Set when the deck ships with the app rather than being user-built.
    var isPreconstructed: Bool = false

    var createdAt: Date = Date()
    var updatedAt: Date = Date()

    var count: Int { cardIDs.count }

    /// Copies of a given card currently in the deck.
    func copies(of cardID: String) -> Int {
        cardIDs.filter { $0 == cardID }.count
    }

    /// Unique card IDs with their counts, in a stable order.
    var groupedCounts: [(cardID: String, count: Int)] {
        var order: [String] = []
        var counts: [String: Int] = [:]
        for id in cardIDs {
            if counts[id] == nil { order.append(id) }
            counts[id, default: 0] += 1
        }
        return order.map { ($0, counts[$0] ?? 0) }
    }
}

// MARK: - Validation

/// A single reason a deck is not yet legal.
struct DeckProblem: Identifiable, Hashable {
    let id = UUID()
    let message: String
}

extension Deck {
    /// Every rule the deck currently breaks, ready to list in the builder.
    /// An empty array means the deck is legal.
    func problems(using database: CardDatabase, requiredSize: Int = DeckRules.requiredSize) -> [DeckProblem] {
        var found: [DeckProblem] = []

        if name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            found.append(DeckProblem(message: "Give the deck a name."))
        }

        guard let leader = database.card(id: leaderID), leader.type == .leader else {
            found.append(DeckProblem(message: "Pick a Leader for the deck."))
            return found
        }

        if count != requiredSize {
            found.append(DeckProblem(message: "A deck holds exactly \(requiredSize) cards. This one has \(count)."))
        }

        // Colour match against the Leader.
        let offColour = Set(cardIDs)
            .compactMap { database.card(id: $0) }
            .filter { $0.color != leader.color }
        if !offColour.isEmpty {
            let names = offColour.prefix(3).map(\.name).joined(separator: ", ")
            let suffix = offColour.count > 3 ? " and \(offColour.count - 3) more" : ""
            found.append(DeckProblem(
                message: "Every card must match the Leader's colour (\(leader.color.title)). Remove \(names)\(suffix)."
            ))
        }

        // Copy limit.
        for (cardID, n) in groupedCounts where n > DeckRules.maxCopies {
            let cardName = database.card(id: cardID)?.name ?? cardID
            found.append(DeckProblem(
                message: "\(cardName) appears \(n) times. The limit is \(DeckRules.maxCopies)."
            ))
        }

        return found
    }

    /// Convenience for enabling the Save button.
    func isLegal(using database: CardDatabase, requiredSize: Int = DeckRules.requiredSize) -> Bool {
        problems(using: database, requiredSize: requiredSize).isEmpty
    }
}

// MARK: - Share codes

extension Deck {
    /// A compact, human-pasteable representation: `leaderID|cardID×count,...`
    /// Used by Export and Copy Link in the builder.
    func exportCode() -> String {
        let body = groupedCounts
            .map { "\($0.cardID)x\($0.count)" }
            .joined(separator: ",")
        return "NCG1:\(leaderID)|\(body)"
    }

    /// Parses a code produced by `exportCode()`. Returns `nil` if malformed.
    static func from(code: String, name: String = "Imported deck") -> Deck? {
        let trimmed = code.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("NCG1:") else { return nil }

        let payload = String(trimmed.dropFirst("NCG1:".count))
        let halves = payload.split(separator: "|", maxSplits: 1, omittingEmptySubsequences: false)
        guard let leaderPart = halves.first, !leaderPart.isEmpty else { return nil }

        var deck = Deck(name: name, leaderID: String(leaderPart))

        if halves.count == 2, !halves[1].isEmpty {
            for entry in halves[1].split(separator: ",") {
                let pieces = entry.split(separator: "x")
                guard pieces.count == 2, let n = Int(pieces[1]), n > 0 else { return nil }
                deck.cardIDs.append(contentsOf: Array(repeating: String(pieces[0]), count: n))
            }
        }
        return deck
    }
}
