//
//  EngineRulesTests.swift
//  NTCGSimulatorTests
//
//  Pins the chakra economy and Leader abilities.
//
//  The cost rule was wrong once already — every play charged the printed cost,
//  when in fact summoning is free and chakra is spent only on Support cards and
//  jutsu plays. These tests exist so that regression cannot happen quietly.
//

import Testing
import Foundation
@testable import NTCGSimulator

// MARK: - Helpers

private enum Harness {

    /// A Classic game on generated fixed decks, so no saved deck is needed.
    static func engine(color: CardColor = .red, seed: UInt64) -> GameEngine {
        let configuration = GameConfiguration(
            mode: .soloVersusSelf,
            format: .classic,
            playerDeckID: nil,
            opponentDeckID: nil,
            fixedDeckColor: color
        )
        return GameEngine(
            configuration: configuration,
            database: CardDatabase(),
            decks: DeckStore(),
            seed: seed
        )
    }

    /// Settles both opening hands so the game reaches the first main phase.
    static func startedEngine(color: CardColor = .red, seed: UInt64) -> GameEngine {
        let engine = engine(color: color, seed: seed)
        engine.apply(.mulligan(false), by: .player)
        engine.apply(.mulligan(false), by: .opponent)
        return engine
    }

    /// Searches seeds until the current player's hand offers a play matching
    /// `predicate`. Keeps tests deterministic without hand-crafting board state,
    /// which the engine deliberately does not expose.
    static func firstGame(
        matching predicate: (GameEngine, PlayerSlot, Card, GameAction) -> Bool
    ) -> (engine: GameEngine, slot: PlayerSlot, card: Card, action: GameAction)? {
        for seed in UInt64(1)...UInt64(60) {
            let engine = startedEngine(seed: seed)
            let slot = engine.currentPlayer
            for action in engine.legalActions(for: slot) {
                guard case .playCard(let index, _) = action else { continue }
                let hand = engine.state[slot].hand
                guard hand.indices.contains(index),
                      let card = engine.database.card(id: hand[index]) else { continue }
                if predicate(engine, slot, card, action) {
                    return (engine, slot, card, action)
                }
            }
        }
        return nil
    }
}

// MARK: - The cost rule, in isolation

@Suite("Chakra cost rule")
struct ChakraCostTests {

    private let database = CardDatabase()

    @Test("Summoning any Character or EX Character is free")
    func summoningCostsNothing() {
        let bodies = database.cards.filter { $0.type.isBody }
        #expect(!bodies.isEmpty)

        for card in bodies {
            #expect(ChakraCost.toPlay(card, asJutsu: false) == 0,
                    "\(card.id) charged chakra to summon")
            #expect(card.summonCost == 0)
        }
    }

    @Test("Playing a card as a jutsu charges its printed cost")
    func jutsuChargesPrintedCost() {
        let withSupport = database.cards.filter(\.hasSupportLine)
        #expect(!withSupport.isEmpty, "the pool needs cards with a Support line")

        for card in withSupport {
            #expect(ChakraCost.toPlay(card, asJutsu: true) == (card.cost ?? 0))
            #expect(card.jutsuCost == card.cost)
        }
    }

    @Test("A Support card charges its printed cost even when summoned normally")
    func supportCardsAlwaysCost() {
        let supports = database.cards.filter { $0.type == .support }
        #expect(!supports.isEmpty, "the pool needs Support cards")

        for card in supports {
            #expect(card.type.costsChakraToPlay)
            #expect(ChakraCost.toPlay(card, asJutsu: false) == (card.cost ?? 0))
        }
    }

    @Test("Only Support cards charge chakra on a non-jutsu play")
    func onlySupportCostsOnPlay() {
        for type in CardType.allCases {
            #expect(type.costsChakraToPlay == (type == .support),
                    "\(type.title) has the wrong cost behaviour")
        }
    }

    @Test("A card with no printed cost never charges anything")
    func missingCostIsFree() {
        var card = Card(id: "X-1", name: "No cost", type: .support, color: .red,
                        rarity: .common, setCode: "01")
        #expect(ChakraCost.toPlay(card, asJutsu: false) == 0)

        card.cost = -3      // defensive: bad data must not create negative cost
        #expect(ChakraCost.toPlay(card, asJutsu: false) == 0)
    }
}

// MARK: - The cost rule, through a real game

@Suite("Chakra spending in play")
struct ChakraSpendingTests {

    @Test("Summoning a Character leaves every Chakra ready")
    func summoningSpendsNoChakra() throws {
        let found = Harness.firstGame { _, _, card, action in
            guard case .playCard(_, let asJutsu) = action else { return false }
            return !asJutsu && card.type.isBody
        }
        let game = try #require(found, "no seed produced a summonable Character")

        let before = game.engine.availableChakra(for: game.slot)
        #expect(before == GameRules.chakraCount)

        let result = game.engine.apply(game.action, by: game.slot)
        #expect(result.isSuccess)

        #expect(game.engine.availableChakra(for: game.slot) == before,
                "summoning \(game.card.id) spent chakra — summoning must be free")
        #expect(game.engine.state[game.slot].characters.count == 1)
    }

    @Test("Playing a card as a jutsu spends exactly its printed cost")
    func jutsuSpendsPrintedCost() throws {
        let found = Harness.firstGame { engine, slot, card, action in
            guard case .playCard(_, let asJutsu) = action, asJutsu else { return false }
            return (card.cost ?? 0) > 0
                && engine.availableChakra(for: slot) >= (card.cost ?? 0)
        }
        let game = try #require(found, "no seed produced an affordable jutsu play")

        let before = game.engine.availableChakra(for: game.slot)
        let cost = game.card.cost ?? 0

        #expect(game.engine.apply(game.action, by: game.slot).isSuccess)
        #expect(game.engine.availableChakra(for: game.slot) == before - cost)

        // A jutsu resolves and goes to the Trash rather than becoming a body.
        #expect(game.engine.state[game.slot].trash.contains(game.card.id))
    }

    @Test("The engine itself prices a summon at zero")
    func enginePricesSummonsAtZero() throws {
        // Asserted through the engine's own validator rather than the pure cost
        // function, so a regression inside `planPlay` is caught too.
        let found = Harness.firstGame { _, _, card, action in
            guard case .playCard(_, let asJutsu) = action else { return false }
            return !asJutsu && card.type.isBody
        }
        let game = try #require(found)
        guard case .playCard(let index, _) = game.action else {
            Issue.record("expected a playCard action")
            return
        }

        let plan = try #require(
            game.engine.planPlay(handIndex: index, asJutsu: false, by: game.slot).value
        )
        #expect(plan.cost == 0, "the engine priced summoning \(game.card.id) at \(plan.cost)")
    }

    @Test("The engine charges a Support card its printed cost")
    func enginePricesSupportCards() throws {
        let found = Harness.firstGame { engine, slot, card, action in
            guard case .playCard(_, let asJutsu) = action, !asJutsu else { return false }
            return card.type == .support
                && engine.availableChakra(for: slot) >= (card.cost ?? 0)
        }

        // Support cards are only four of twenty-one cards per colour, so a
        // opening hand may legitimately not contain one. Skip rather than fail.
        guard let game = found else { return }
        guard case .playCard(let index, _) = game.action else { return }

        let plan = try #require(
            game.engine.planPlay(handIndex: index, asJutsu: false, by: game.slot).value
        )
        #expect(plan.cost == (game.card.cost ?? 0))

        let before = game.engine.availableChakra(for: game.slot)
        #expect(game.engine.apply(game.action, by: game.slot).isSuccess)
        #expect(game.engine.availableChakra(for: game.slot) == before - plan.cost)
        #expect(game.engine.state[game.slot].support.compactMap { $0 }.count == 1)
    }
}

// MARK: - Leader abilities

@Suite("Leader abilities")
struct LeaderAbilityTests {

    @Test("Every Leader in the pool has an ability the player can press")
    func leadersHaveAbilities() {
        let database = CardDatabase()
        for leader in database.leaders {
            #expect(leader.leaderAbility != nil,
                    "\(leader.id) has no activated ability, so the player cannot use it")
        }
    }

    @Test("A Leader ability is offered during the main phase")
    func abilityIsOffered() {
        let engine = Harness.startedEngine(seed: 7)
        let slot = engine.currentPlayer

        #expect(engine.phase == .main)
        #expect(!engine.legalLeaderAbilities(for: slot).isEmpty,
                "the Leader offers no activation, so it cannot be used")
    }

    @Test("A Leader may only be activated once per turn")
    func abilityIsOncePerTurn() throws {
        let engine = Harness.startedEngine(seed: 7)
        let slot = engine.currentPlayer

        let action = try #require(engine.legalLeaderAbilities(for: slot).first)
        #expect(engine.apply(action, by: slot).isSuccess)
        #expect(engine.state[slot].hasUsedLeaderAbility)

        // The second attempt must be refused, and nothing further offered.
        let second = engine.apply(action, by: slot)
        #expect(second.isFailure)
        #expect(engine.legalLeaderAbilities(for: slot).isEmpty)
    }

    @Test("Activating a draw ability adds a card to hand without ending the game")
    func drawAbilityDraws() throws {
        // N-001 (red Leader) draws a card.
        let engine = Harness.startedEngine(color: .red, seed: 7)
        let slot = engine.currentPlayer
        let leader = try #require(engine.database.card(id: engine.state[slot].leaderCardID))
        try #require(leader.leaderAbility == .drawCard)

        let handBefore = engine.state[slot].hand.count
        #expect(engine.apply(.useLeaderAbility(targetID: nil), by: slot).isSuccess)
        #expect(engine.state[slot].hand.count == handBefore + 1)
        #expect(!engine.isFinished)
    }

    @Test("A Leader ability costs no chakra")
    func abilityIsFree() throws {
        let engine = Harness.startedEngine(seed: 7)
        let slot = engine.currentPlayer

        let before = engine.availableChakra(for: slot)
        let action = try #require(engine.legalLeaderAbilities(for: slot).first)
        #expect(engine.apply(action, by: slot).isSuccess)
        #expect(engine.availableChakra(for: slot) == before)
    }

    @Test("The ability lock lifts on the player's next turn")
    func abilityRefreshesEachTurn() throws {
        let engine = Harness.startedEngine(seed: 7)
        let first = engine.currentPlayer

        let action = try #require(engine.legalLeaderAbilities(for: first).first)
        #expect(engine.apply(action, by: first).isSuccess)
        #expect(engine.state[first].hasUsedLeaderAbility)

        // Pass twice, back round to the same player.
        #expect(engine.apply(.endTurn, by: first).isSuccess)
        let second = engine.currentPlayer
        #expect(second == first.opposing)
        #expect(engine.apply(.endTurn, by: second).isSuccess)

        #expect(engine.currentPlayer == first)
        #expect(!engine.state[first].hasUsedLeaderAbility,
                "the Leader should be usable again on a new turn")
    }
}

// MARK: - Result conveniences

private extension Result {
    var isSuccess: Bool { if case .success = self { return true }; return false }
    var isFailure: Bool { !isSuccess }

    /// The success value, or `nil` — for use with `#require`.
    var value: Success? { if case .success(let v) = self { return v }; return nil }
}
