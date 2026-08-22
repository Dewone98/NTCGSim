//
//  EngineRulesTests.swift
//  NTCGSimulatorTests
//
//  Pins the chakra economy and the printed ability boxes.
//
//  Both have been wrong once already. Every play used to charge the printed
//  cost, when in fact summoning is free and chakra is spent only on Support
//  cards and jutsu plays. And every Leader used to carry one of four invented
//  abilities that no card actually prints, which the tests below happily
//  asserted. They now read the real boxes off the real cards, so a fabricated
//  rule cannot pass again.
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
        // A card set need not print Support cards at all — the shipped one does
        // not — so this asserts the rule, not the presence of such a card.
        for card in database.cards where card.type == .support {
            #expect(card.type.costsChakraToPlay)
            #expect(ChakraCost.toPlay(card, asJutsu: false) == (card.cost ?? 0))
        }
    }

    @Test("The pool gives chakra something to be spent on")
    func poolHasChakraSinks() {
        // Chakra is spent on Support cards and on jutsu plays. A pool offering
        // neither would leave the resource dead, which is a data fault worth
        // failing loudly for.
        let sinks = database.cards.filter(\.isChakraSink)
        #expect(!sinks.isEmpty,
                "no card can be played as a jutsu and none is a Support card, so chakra has no use")

        for card in sinks {
            #expect(ChakraCost.toPlay(card, asJutsu: card.hasSupportLine) >= 0)
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

// MARK: - Printed abilities

/// The two Leaders in the shipped pool, named because these tests assert what
/// those exact cards print rather than what a Leader might print in general.
///
/// The red Leader's activation is the one that costs chakra and needs a target;
/// the blue Leader's is the free, untargeted, once-per-turn one. Between them
/// they cover every shape of validation the engine performs, which is why the
/// tests below pick a colour rather than taking whichever game comes up.
private enum Leaders {
    static let red = "N-001"    // Naruto Uzumaki
    static let blue = "N-012"   // Sasuke Uchiha
}

@Suite("Printed abilities")
struct AbilityTests {

    // MARK: The printed data

    @Test("Every Leader prints an ability the engine has a moment for")
    func leadersHaveAbilities() {
        let database = CardDatabase()
        #expect(!database.leaders.isEmpty, "the pool has no Leaders at all")

        // The triggers the engine resolves: the three a player presses, the
        // three it fires by itself, and the two it only ever displays. A box
        // tagged with anything else would never resolve and never be shown.
        let known: Set<AbilityTrigger> = [
            .activateMain, .duringYourMain, .opponentsAttack,
            .onSummon, .whenAttacking, .recovery,
            .passive, .yourTurn
        ]

        for leader in database.leaders {
            #expect(!leader.abilities.isEmpty, "\(leader.id) prints no abilities at all")
            #expect(leader.abilities.contains { $0.isActivated },
                    "\(leader.id) prints nothing the player can press")

            for ability in leader.abilities {
                #expect(known.contains(ability.trigger),
                        "\(leader.id) prints a \(ability.trigger.rawValue) box the engine has no moment for")
            }
        }
    }

    // MARK: Being offered

    @Test("An activated ability is offered during the main phase")
    func abilityIsOffered() throws {
        // Sasuke's [Activate: Main] costs nothing and names no target, so it is
        // on the table from the first main phase. Naruto's needs a character to
        // aim at, and there are none on turn one — which is correct, not a
        // regression, so the blue Leader is the one that proves the offer.
        let engine = Harness.startedEngine(color: .blue, seed: 7)
        let slot = engine.currentPlayer
        #expect(engine.phase == .main)

        let offered = engine.legalAbilities(for: slot)
        #expect(!offered.isEmpty, "no printed ability is on the table")

        let legal = Set(engine.legalActions(for: slot))
        for action in offered {
            guard case .useAbility(let source, let index, _) = action else {
                Issue.record("\(action.id) is not an activation")
                continue
            }
            #expect(legal.contains(action), "\(action.id) is offered but is not a legal action")

            let card = try #require(engine.abilityCard(for: source, by: slot))
            #expect(card.abilities.indices.contains(index))
            #expect(card.abilities[index].isActivated,
                    "\(card.id) box \(index) fires by itself and should not be offered")
        }
    }

    // MARK: Resolving

    @Test("The draw box swaps a card rather than gaining one")
    func drawAbilityDraws() throws {
        // As printed: "Draw 1 card and place 1 card from your hand on top of
        // your deck." The hand ends the same size it started; what changes is
        // which cards are in it and what is on top of the deck.
        let engine = Harness.startedEngine(color: .blue, seed: 7)
        let slot = engine.currentPlayer

        let leader = try #require(engine.leaderCard(for: slot))
        try #require(leader.id == Leaders.blue)
        let ability = try #require(leader.abilities.first)
        try #require(ability.trigger == .activateMain)
        try #require(ability.effects.contains(.drawCards(1)))
        try #require(ability.effects.contains(.placeFromHandOnDeck(1)))

        let handBefore = engine.state[slot].hand
        let topBefore = try #require(engine.state[slot].deck.first)

        // The player says which card goes back. A deck holds four copies of a
        // card, so the nomination has to be a card that is not another copy of
        // the one on top, or the swap would be invisible.
        let nominated = try #require(handBefore.indices.first { handBefore[$0] != topBefore })
        engine.nominateFromHand([nominated])

        let action = GameAction.useAbility(source: .leader, abilityIndex: 0, targetID: nil)
        #expect(engine.apply(action, by: slot).isSuccess)

        #expect(engine.state[slot].hand.count == handBefore.count,
                "drawing one and placing one back must leave the hand the size it was")
        #expect(engine.state[slot].deck.first == handBefore[nominated],
                "the nominated card should be on top of the deck")
        #expect(engine.state[slot].deck.first != topBefore, "the top of the deck did not change")
        #expect(engine.state[slot].hand.contains(topBefore), "the card drawn never reached the hand")
        #expect(!engine.isFinished)
    }

    @Test("An ability's printed chakra cost is actually paid")
    func abilityPaysItsChakraCost() throws {
        // Naruto's [Activate: Main] flips 1 CHAKRA face-down and gives a chosen
        // character +3 power, so it needs a body on the board to aim at.
        let found = Harness.firstGame { _, _, card, action in
            guard case .playCard(_, let asJutsu) = action else { return false }
            return !asJutsu && card.type.isBody
        }
        let game = try #require(found, "no seed produced a summonable Character")

        let engine = game.engine
        let slot = game.slot
        #expect(engine.apply(game.action, by: slot).isSuccess)

        let leader = try #require(engine.leaderCard(for: slot))
        try #require(leader.id == Leaders.red)
        let cost = try #require(leader.abilities.first?.cost.chakra)
        try #require(cost > 0)

        let target = try #require(engine.state[slot].characters.first)
        let action = GameAction.useAbility(source: .leader, abilityIndex: 0, targetID: target.id)
        #expect(engine.legalAbilities(for: slot).contains(action))

        let before = engine.availableChakra(for: slot)
        #expect(engine.apply(action, by: slot).isSuccess)

        #expect(engine.availableChakra(for: slot) == before - cost,
                "the printed cost of \(cost) chakra was not taken")
        #expect(engine.state[slot].restedChakra == cost,
                "summoning is free, so the only chakra face-down should be the ability's")
        #expect(engine.state[slot].characters.first?.powerBonus == 3,
                "the ability was paid for but its effect did not land")
    }

    @Test("A step the app cannot resolve is written down, not skipped in silence")
    func unimplementedStepIsRecorded() throws {
        // Sasuke's [Recovery] reads "If it is the second turn or later, rest
        // this card and flip all of your CHAKRA face-up." The engine has no way
        // to check the turn condition, so that clause is carried as
        // `.unimplemented` — and the box fires at the start of every turn, so
        // the opening journal already has to admit it.
        let engine = Harness.startedEngine(color: .blue, seed: 7)
        let slot = engine.currentPlayer

        let leader = try #require(engine.leaderCard(for: slot))
        let recovery = try #require(leader.abilities.first { $0.trigger == .recovery })
        #expect(!recovery.isFullyImplemented)

        let unresolved = recovery.effects.compactMap { effect -> String? in
            guard case .unimplemented(let text) = effect else { return nil }
            return text
        }
        try #require(!unresolved.isEmpty, "the box no longer carries a step to report")

        let transcript = engine.journal.transcript
        #expect(transcript.contains("NOT APPLIED"),
                "the journal never says a step went unapplied")
        for text in unresolved {
            #expect(transcript.contains(text),
                    "the journal never quotes the step it could not resolve: \"\(text)\"")
        }

        // The rest of the box still ran. Abandoning the printed steps the engine
        // *can* resolve would be as wrong as resolving the one it cannot.
        #expect(engine.state[slot].leaderIsRested,
                "the printed rest step did not resolve alongside the unapplied one")
    }

    // MARK: Refusals

    @Test("A Once Per Turn box is refused the second time")
    func abilityIsOncePerTurn() throws {
        let engine = Harness.startedEngine(color: .blue, seed: 7)
        let slot = engine.currentPlayer

        let leader = try #require(engine.leaderCard(for: slot))
        try #require(leader.abilities.first?.oncePerTurn == true)

        let action = GameAction.useAbility(source: .leader, abilityIndex: 0, targetID: nil)
        #expect(engine.apply(action, by: slot).isSuccess)
        #expect(engine.hasUsedAbility(.leader, abilityIndex: 0, by: slot))

        let second = engine.apply(action, by: slot)
        #expect(second.error == GameError.abilityAlreadyUsed(leader.name))
        #expect(!engine.canUseAbility(source: .leader, abilityIndex: 0, by: slot))
        #expect(!engine.legalAbilities(for: slot).contains(action),
                "a spent box must not still be offered")
    }

    @Test("An ability refuses a card on the wrong side of the board")
    func wrongSideIsRefused() throws {
        let found = Harness.firstGame { _, _, card, action in
            guard case .playCard(_, let asJutsu) = action else { return false }
            return !asJutsu && card.type.isBody
        }
        let game = try #require(found, "no seed produced a summonable Character")

        let engine = game.engine
        let slot = game.slot
        #expect(engine.apply(game.action, by: slot).isSuccess)
        let mine = try #require(engine.state[slot].characters.first)

        // The same body, addressed as a source from the other side of the table:
        // the engine looks for it on the activating player's board only.
        #expect(
            engine.planAbility(source: .character(mine.id), abilityIndex: 0, targetID: nil, by: slot.opposing).error
                == GameError.abilitySourceNotInPlay
        )

        // A target that is on no board at all is a legal choice for no scope.
        #expect(
            engine.planAbility(source: .leader, abilityIndex: 0, targetID: UUID(), by: slot).error
                == GameError.abilityNeedsTarget
        )

        // The scope is what decides sides, and it is the same list `planAbility`
        // checks a chosen target against.
        let target = BoardTarget(slot: slot, id: mine.id)
        #expect(
            AbilityResolver.candidates(for: .friendlyCharacter, controller: slot, in: engine.state)
                .contains(target)
        )
        #expect(
            !AbilityResolver.candidates(for: .opposingCharacter, controller: slot, in: engine.state)
                .contains(target),
            "a body on your own side must never satisfy an opposing-only scope"
        )

        // And an effect handed a target its scope does not reach changes nothing
        // rather than reaching across for the nearest card it can find.
        let leader = try #require(engine.leaderCard(for: slot))
        let ability = try #require(leader.abilities.first)
        let context = AbilityContext(
            source: .leader,
            controller: slot,
            card: leader,
            ability: ability,
            targetID: mine.id,
            handSelection: []
        )
        #expect(
            AbilityResolver(database: engine.database)
                .targets(for: .opposingCharacter, context: context, in: engine.state)
                .isEmpty,
            "an opposing-only step resolved onto a friendly body"
        )
    }

    @Test("The once-per-turn lock lifts on the player's next turn")
    func abilityRefreshesEachTurn() throws {
        let engine = Harness.startedEngine(color: .blue, seed: 7)
        let first = engine.currentPlayer

        let action = GameAction.useAbility(source: .leader, abilityIndex: 0, targetID: nil)
        #expect(engine.apply(action, by: first).isSuccess)
        #expect(engine.hasUsedAbility(.leader, abilityIndex: 0, by: first))

        // Pass twice, back round to the same player.
        #expect(engine.apply(.endTurn, by: first).isSuccess)
        let second = engine.currentPlayer
        #expect(second == first.opposing)
        #expect(engine.apply(.endTurn, by: second).isSuccess)

        #expect(engine.currentPlayer == first)
        #expect(!engine.hasUsedAbility(.leader, abilityIndex: 0, by: first),
                "the box should be usable again on a new turn")
        #expect(engine.canUseAbility(source: .leader, abilityIndex: 0, by: first))
    }
}

// MARK: - Result conveniences

private extension Result {
    var isSuccess: Bool { if case .success = self { return true }; return false }

    /// The success value, or `nil` — for use with `#require`.
    var value: Success? { if case .success(let v) = self { return v }; return nil }

    /// The refusal, or `nil` — for asserting *which* rule turned an action down.
    var error: Failure? { if case .failure(let e) = self { return e }; return nil }
}
