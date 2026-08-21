//
//  ModelTests.swift
//  NTCGSimulatorTests
//
//  Covers the card model, deck construction rules and share codes — the parts
//  the Deck Builder relies on to decide whether a deck is legal.
//

import Testing
import Foundation
@testable import NTCGSimulator

// MARK: - Fixtures

/// A small hand-built pool, so tests never depend on the shipped card data.
private enum Fixture {

    static func leader(_ id: String, color: CardColor) -> Card {
        Card(id: id, name: "Leader \(id)", type: .leader, color: color,
             rarity: .leader, setCode: "01", traits: ["Test"], life: 15)
    }

    static func character(_ id: String, color: CardColor, cost: Int = 2) -> Card {
        Card(id: id, name: "Character \(id)", type: .character, color: color,
             rarity: .common, setCode: "01", traits: ["Test"],
             cost: cost, power: 4, damage: 1, health: 4, effect: "Does a thing.")
    }

    /// A pool with one Leader per colour and twenty characters per colour —
    /// enough to build a legal fifty-card deck in any colour.
    static var database: CardDatabase {
        var cards: [Card] = [
            leader("L-RED", color: .red),
            leader("L-BLUE", color: .blue),
            leader("L-GREEN", color: .green),
        ]
        for color in CardColor.allCases {
            for n in 1...20 {
                cards.append(character("\(color.rawValue.uppercased())-\(n)",
                                       color: color, cost: (n % 5) + 1))
            }
        }
        return CardDatabase(cards: cards)
    }

    /// A legal fifty-card red deck: thirteen distinct cards, four copies each,
    /// trimmed to exactly fifty.
    static func legalRedDeck(name: String = "Red deck") -> Deck {
        var deck = Deck(name: name, leaderID: "L-RED")
        for n in 1...13 {
            deck.cardIDs.append(contentsOf: Array(repeating: "RED-\(n)", count: 4))
        }
        deck.cardIDs = Array(deck.cardIDs.prefix(DeckRules.requiredSize))
        return deck
    }
}

// MARK: - Card

@Suite("Card")
struct CardTests {

    @Test("A character occupies a body slot; a chakra card does not")
    func bodyClassification() {
        #expect(CardType.character.isBody)
        #expect(CardType.exCharacter.isBody)
        #expect(!CardType.chakra.isBody)
        #expect(!CardType.leader.isBody)
    }

    @Test("Only characters count toward deck size")
    func deckSizeContribution() {
        #expect(CardType.character.countsTowardDeckSize)
        #expect(CardType.exCharacter.countsTowardDeckSize)
        #expect(!CardType.leader.countsTowardDeckSize)
        #expect(!CardType.chakra.countsTowardDeckSize)
        #expect(!CardType.summon.countsTowardDeckSize)
    }

    @Test("A support line is only reported when the text is non-empty")
    func supportLineDetection() {
        var card = Fixture.character("X-1", color: .red)
        #expect(!card.hasSupportLine)

        card.supportText = ""
        #expect(!card.hasSupportLine)

        card.supportText = "Support: draw a card."
        #expect(card.hasSupportLine)
    }

    @Test("Display order puts leaders first, then sorts by cost")
    func displayOrdering() {
        let leader = Fixture.leader("L-RED", color: .red)
        let cheap = Fixture.character("A", color: .red, cost: 1)
        let dear = Fixture.character("B", color: .red, cost: 7)

        #expect(Card.displayOrder(leader, cheap))
        #expect(Card.displayOrder(cheap, dear))
        #expect(!Card.displayOrder(dear, cheap))
    }

    @Test("The stat line omits values the card does not have")
    func statLineSkipsMissingValues() {
        let leader = Fixture.leader("L-RED", color: .red)
        #expect(leader.statLine.isEmpty)

        let character = Fixture.character("A", color: .red, cost: 3)
        #expect(character.statLine == "3 / 4 / 1")
    }
}

// MARK: - Deck legality

@Suite("Deck legality")
struct DeckLegalityTests {

    @Test("A well-formed fifty-card deck is legal")
    func legalDeckHasNoProblems() {
        let database = Fixture.database
        let deck = Fixture.legalRedDeck()

        #expect(deck.count == 50)
        #expect(deck.problems(using: database).isEmpty)
        #expect(deck.isLegal(using: database))
    }

    @Test("An unnamed deck is rejected")
    func nameIsRequired() {
        let database = Fixture.database
        var deck = Fixture.legalRedDeck(name: "   ")

        #expect(!deck.isLegal(using: database))

        deck.name = "Named"
        #expect(deck.isLegal(using: database))
    }

    @Test("A deck that is not exactly fifty cards is rejected", arguments: [49, 51, 0])
    func sizeMustBeExact(size: Int) {
        let database = Fixture.database
        var deck = Fixture.legalRedDeck()

        if size < deck.count {
            deck.cardIDs = Array(deck.cardIDs.prefix(size))
        } else {
            deck.cardIDs.append(contentsOf: Array(repeating: "RED-14", count: size - deck.count))
        }

        #expect(deck.count == size)
        #expect(!deck.isLegal(using: database))
    }

    @Test("Cards off the Leader's colour are rejected")
    func colourMustMatchTheLeader() {
        let database = Fixture.database
        var deck = Fixture.legalRedDeck()
        deck.cardIDs[0] = "BLUE-1"

        let problems = deck.problems(using: database)
        #expect(!problems.isEmpty)
        #expect(problems.contains { $0.message.contains("Red") })
    }

    @Test("More than four copies of a card is rejected")
    func copyLimitIsEnforced() {
        let database = Fixture.database
        var deck = Deck(name: "Too many", leaderID: "L-RED")
        deck.cardIDs = Array(repeating: "RED-1", count: 5)
        deck.cardIDs.append(contentsOf: Array(repeating: "RED-2", count: 45))

        #expect(deck.count == 50)
        let problems = deck.problems(using: database)
        #expect(problems.contains { $0.message.contains("limit is 4") })
    }

    @Test("A missing Leader is reported before anything else")
    func leaderIsRequired() {
        let database = Fixture.database
        let deck = Deck(name: "No leader", leaderID: "does-not-exist")

        let problems = deck.problems(using: database)
        #expect(problems.count == 1)
        #expect(problems[0].message.contains("Leader"))
    }

    @Test("The Classic format checks against thirty cards instead of fifty")
    func classicSizeOverride() {
        let database = Fixture.database
        var deck = Deck(name: "Classic", leaderID: "L-RED")
        for n in 1...8 {
            deck.cardIDs.append(contentsOf: Array(repeating: "RED-\(n)", count: 4))
        }
        deck.cardIDs = Array(deck.cardIDs.prefix(DeckRules.classicSize))

        #expect(deck.isLegal(using: database, requiredSize: DeckRules.classicSize))
        #expect(!deck.isLegal(using: database))
    }

    @Test("Copies and grouped counts agree with the raw card list")
    func groupingMatchesContents() {
        let deck = Fixture.legalRedDeck()
        let grouped = deck.groupedCounts

        #expect(grouped.reduce(0) { $0 + $1.count } == deck.count)
        for (cardID, count) in grouped {
            #expect(deck.copies(of: cardID) == count)
        }
    }
}

// MARK: - Share codes

@Suite("Deck share codes")
struct DeckShareCodeTests {

    @Test("A deck survives an export/import round trip")
    func roundTripPreservesContents() throws {
        let original = Fixture.legalRedDeck()
        let code = original.exportCode()

        let restored = try #require(Deck.from(code: code))
        #expect(restored.leaderID == original.leaderID)
        #expect(restored.count == original.count)
        #expect(Set(restored.cardIDs) == Set(original.cardIDs))

        for (cardID, count) in original.groupedCounts {
            #expect(restored.copies(of: cardID) == count)
        }
    }

    @Test("Export codes carry the version prefix")
    func codeIsVersioned() {
        #expect(Fixture.legalRedDeck().exportCode().hasPrefix("NCG1:"))
    }

    @Test("Malformed codes are rejected rather than half-parsed",
          arguments: ["", "nonsense", "NCG2:L-RED|RED-1x4", "NCG1:", "NCG1:L-RED|RED-1xNaN"])
    func malformedCodesReturnNil(code: String) {
        #expect(Deck.from(code: code) == nil)
    }

    @Test("Surrounding whitespace is tolerated when pasting a code")
    func whitespaceIsTrimmed() {
        let code = "  \n\(Fixture.legalRedDeck().exportCode())\t "
        #expect(Deck.from(code: code) != nil)
    }

    @Test("A leader-only code parses to an empty deck")
    func leaderOnlyCode() throws {
        let deck = try #require(Deck.from(code: "NCG1:L-RED|"))
        #expect(deck.leaderID == "L-RED")
        #expect(deck.cardIDs.isEmpty)
    }
}

// MARK: - Database

@Suite("Card database")
struct CardDatabaseTests {

    @Test("Lookups resolve by collector number")
    func lookupByID() {
        let database = Fixture.database
        #expect(database.card(id: "L-RED")?.type == .leader)
        #expect(database.card(id: "nope") == nil)
    }

    @Test("Unknown ids are dropped rather than crashing an expansion")
    func unknownIDsAreDropped() {
        let database = Fixture.database
        let cards = database.cards(ids: ["RED-1", "nope", "RED-2"])
        #expect(cards.count == 2)
    }

    @Test("Playable cards are limited to the Leader's colour")
    func playablePoolMatchesColour() throws {
        let database = Fixture.database
        let leader = try #require(database.card(id: "L-BLUE"))
        let pool = database.cardsPlayable(with: leader)

        #expect(!pool.isEmpty)
        #expect(pool.allSatisfy { $0.color == .blue })
        #expect(pool.allSatisfy { $0.type.countsTowardDeckSize })
    }

    @Test("Filters combine as an intersection")
    func filtersIntersect() {
        let database = Fixture.database

        let red = database.filtered(colors: [.red])
        #expect(red.allSatisfy { $0.color == .red })

        let redLeaders = database.filtered(colors: [.red], types: [.leader])
        #expect(redLeaders.count == 1)
        #expect(redLeaders.first?.id == "L-RED")

        let none = database.filtered(colors: [.red], types: [.leader], rarities: [.superRare])
        #expect(none.isEmpty)
    }

    @Test("Search matches name, collector number and effect text")
    func searchLooksAcrossFields() {
        let database = Fixture.database

        #expect(!database.filtered(searchText: "RED-1").isEmpty)
        #expect(!database.filtered(searchText: "does a thing").isEmpty)  // case-insensitive
        #expect(database.filtered(searchText: "zzzz").isEmpty)
    }

    @Test("Every leader in the pool is reported")
    func leadersAreListed() {
        #expect(Fixture.database.leaders.count == 3)
    }
}

// MARK: - Shipped card pool

@Suite("Shipped card pool")
struct ShippedPoolTests {

    /// Guards the demo data: if `cards.json` stops being bundled, or a card is
    /// malformed, the app has nothing to show — so fail loudly here instead.
    @Test("The bundled pool loads and can build a legal deck in every colour")
    func bundledPoolIsUsable() throws {
        let database = CardDatabase()
        try #require(!database.cards.isEmpty, "cards.json is not reaching the app bundle")

        #expect(!database.chakraCards.isEmpty, "at least one Chakra card is needed for the board")

        for leader in database.leaders {
            #expect(leader.life != nil, "\(leader.id) is a Leader with no life value")

            let pool = database.cardsPlayable(with: leader)
            let buildable = pool.count * DeckRules.maxCopies
            #expect(buildable >= DeckRules.requiredSize,
                    "\(leader.color.title) has only \(pool.count) cards — cannot reach 50")
        }
    }
}
