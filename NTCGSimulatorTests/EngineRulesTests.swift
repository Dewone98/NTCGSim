//
//  EngineRulesTests.swift
//  NTCGSimulatorTests
//
//  Pins the corrected rules onto the rewritten engine — the turn machine, the
//  attack bar, combat's two stats, the counter windows and the chain — as the
//  reference engine actually plays them.
//
//  Two of these rules were reported broken and are guarded by name here. A
//  Shisui-style negate is a *response*: it answers a jutsu or Support
//  activation on the chain, never a bare summon or attack. And Leaders DO
//  attack — once per turn, resting the Leader — with the no-attack bar
//  covering game turn 1 only, so the second player's Leader may swing on
//  turn 2 while the first player's waits for turn 3.
//
//  Most suites run on small hand-built pools rather than the shipped cards:
//  the engine is data-driven, so a pool of identical bodies makes every deal
//  equivalent and the asserts exact, with no board-building back door into the
//  engine. Where a scenario needs specific cards in specific hands, a seed
//  search replays the engine's own deterministic setup until one fits. The
//  shipped `cards.json` is pinned separately, so the real Shisui, Kakashi and
//  the EX doors keep the timings the rules give them.
//

import Testing
import Foundation
@testable import NTCGSimulator

// MARK: - Fixture pools

/// Hand-built card pools, one per family of tests. Classic-format games deal
/// both sides the same generated list, so a pool is the whole experiment.
private enum Pool {

    // MARK: Builders

    /// A test Leader. Damage is the stat a connecting Leader attack takes off
    /// the defending Leader's life, so each pool picks it deliberately.
    static func leader(
        _ id: String,
        color: CardColor,
        damage: Int,
        abilities: [CardAbility] = []
    ) -> Card {
        Card(id: id, name: "Test Leader \(color.title)", type: .leader, color: color,
             rarity: .leader, setCode: "T1", traits: ["Test"],
             power: 3, damage: damage, life: 15, abilities: abilities)
    }

    /// A test character. A `supportText` marks the card as settable, exactly
    /// as the shipped pool's SUPPORT bars do.
    static func body(
        _ id: String,
        named name: String,
        color: CardColor,
        power: Int,
        damage: Int,
        health: Int,
        cost: Int? = nil,
        supportText: String? = nil,
        abilities: [CardAbility] = []
    ) -> Card {
        Card(id: id, name: name, type: .character, color: color,
             rarity: .common, setCode: "T1", traits: ["Test"],
             cost: cost, power: power, damage: damage, health: health,
             supportText: supportText, canSetAsSupport: supportText != nil,
             abilities: abilities)
    }

    /// A test EX Character: barred from the normal summon, paid for through
    /// its printed Summon Requirements.
    static func ex(
        _ id: String,
        named name: String,
        color: CardColor,
        power: Int,
        damage: Int,
        health: Int,
        requirements: [TrashRequirement],
        onSummon: [AbilityEffect] = []
    ) -> Card {
        var abilities: [CardAbility] = [
            CardAbility(trigger: .passive,
                        text: "Cannot be summoned normally.",
                        effects: [.cannotBeSummonedNormally]),
            CardAbility(trigger: .summonRequirement,
                        cost: AbilityCost(trashRequirements: requirements),
                        text: "Place \(requirements.count) of your Characters in your trash."),
        ]
        if !onSummon.isEmpty {
            abilities.append(CardAbility(trigger: .onSummon, text: "On Summon.", effects: onSummon))
        }
        return Card(id: id, name: name, type: .exCharacter, color: color,
                    rarity: .superRare, setCode: "T1", traits: ["Test"],
                    power: power, damage: damage, health: health,
                    abilities: abilities)
    }

    // MARK: The pools

    /// Every deck card is the same 4-power, 1-damage, 6-health body, so any
    /// deal produces the same combat arithmetic: a hit never kills outright,
    /// two hits do, and the Leader's damage of 2 is distinguishable from a
    /// character's 1. The Leader also prints a 2-chakra Activate: Main so the
    /// Recovery tests have something to spend chakra on.
    static let combat: [Card] = {
        var cards = [leader("L-CBT", color: .red, damage: 2, abilities: [
            CardAbility(trigger: .activateMain, oncePerTurn: true,
                        cost: AbilityCost(chakra: 2),
                        text: "Flip 2 of your CHAKRA face-down: You gain 2 Life.",
                        effects: [.gainLife(2)]),
        ])]
        for n in 1...8 {
            cards.append(body("CBT-\(n)", named: "Test Tank \(n)", color: .red,
                              power: 4, damage: 1, health: 6))
        }
        return cards
    }()

    /// One Support card of each timing class beside plain bodies, for the
    /// window and chain tests. Every character deals 1 damage, so a resolved
    /// attack always costs the defending Leader exactly one life.
    static let jutsuIDs = ["WJ-1", "WJ-2"]
    static let negateIDs = ["WN-1", "WN-2"]
    static let trapIDs = ["WT-1", "WT-2"]
    static let quickIDs = ["WQ-1", "WQ-2"]

    static let windows: [Card] = {
        var cards = [leader("L-WIN", color: .blue, damage: 1)]
        for n in 1...4 {
            cards.append(body("WV-\(n)", named: "Test Vanguard \(n)", color: .blue,
                              power: 4, damage: 1, health: 6))
        }
        for id in jutsuIDs {
            cards.append(body(id, named: "Test Sage", color: .blue,
                              power: 3, damage: 1, health: 3, cost: 1,
                              supportText: "Surge — During Your Main: You gain 2 Life.",
                              abilities: [CardAbility(trigger: .duringYourMain,
                                                      cost: AbilityCost(chakra: 1),
                                                      text: "You gain 2 Life.",
                                                      effects: [.gainLife(2)])]))
        }
        for id in negateIDs {
            cards.append(body(id, named: "Test Silencer", color: .blue,
                              power: 3, damage: 1, health: 3, cost: 1,
                              supportText: "Veto — Support Activated: Negate that card.",
                              abilities: [CardAbility(trigger: .support,
                                                      cost: AbilityCost(chakra: 1),
                                                      text: "Negate that card.",
                                                      effects: [.negateChainLink])]))
        }
        for id in trapIDs {
            cards.append(body(id, named: "Test Sentinel", color: .blue,
                              power: 3, damage: 1, health: 3, cost: 1,
                              supportText: "Snare — During Your Opponent's Attack: Summon this card and interrupt that attack.",
                              abilities: [CardAbility(trigger: .opponentsAttack,
                                                      cost: AbilityCost(chakra: 1),
                                                      text: "Summon this card and interrupt that attack.",
                                                      effects: [.interruptAttack, .summonSelf])]))
        }
        for id in quickIDs {
            cards.append(body(id, named: "Test Flicker", color: .blue,
                              power: 3, damage: 1, health: 3, cost: 1,
                              supportText: "Flicker — Quick: You gain 1 Life.",
                              abilities: [CardAbility(trigger: .quick,
                                                      cost: AbilityCost(chakra: 1),
                                                      text: "You gain 1 Life.",
                                                      effects: [.gainLife(1)])]))
        }
        return cards
    }()

    /// Every deck card is a free Quick jutsu that summons itself, so one turn
    /// can flood the board far past the mat's five printed slots.
    static let clones: [Card] = {
        var cards = [leader("L-CLN", color: .red, damage: 1)]
        for n in 1...8 {
            cards.append(body("CLN-\(n)", named: "Test Copy \(n)", color: .red,
                              power: 3, damage: 1, health: 3, cost: 0,
                              supportText: "Copy — Quick: Summon this card.",
                              abilities: [CardAbility(trigger: .quick,
                                                      text: "Summon this card.",
                                                      effects: [.summonSelf])]))
        }
        return cards
    }()

    /// Two EX doors beside plain bodies: one pays and arrives, the other
    /// searches out a "Shadow Clone" that lands with its effects negated. The
    /// clone prints Rush and an On Summon life gain, so a negated arrival has
    /// two visibly dead effects to check.
    static let exBig = "XB-1"
    static let exSeeker = "XS-1"

    static let exPool: [Card] = {
        var cards = [leader("L-EXP", color: .red, damage: 1)]
        for n in 1...4 {
            cards.append(body("XV-\(n)", named: "Test Genin \(n)", color: .red,
                              power: 4, damage: 1, health: 6))
        }
        for n in 1...2 {
            cards.append(body("XT-\(n)", named: "Shadow Clone", color: .red,
                              power: 5, damage: 1, health: 5,
                              abilities: [
                                  CardAbility(trigger: .passive,
                                              text: "(This card can attack on the turn in which it is summoned.)",
                                              effects: [.rush]),
                                  CardAbility(trigger: .onSummon,
                                              text: "You gain 3 Life.",
                                              effects: [.gainLife(3)]),
                              ]))
        }
        cards.append(ex(exBig, named: "Great Beast", color: .red,
                        power: 10, damage: 3, health: 10,
                        requirements: [TrashRequirement()]))
        cards.append(ex(exSeeker, named: "Clone Master", color: .red,
                        power: 8, damage: 2, health: 9,
                        requirements: [TrashRequirement()],
                        onSummon: [.searchSummonNegated(name: "Shadow Clone")]))
        return cards
    }()
}

// MARK: - Harness

/// Builds games on the fixture pools and walks them to the moments the tests
/// assert on. Everything goes through `GameEngine.apply`, so a scenario can
/// only exist if the rules allow the route to it.
private enum Harness {

    /// A Classic game on a fixture pool: both sides are dealt the same
    /// generated list, and every shuffle comes off the given seed.
    static func engine(pool: [Card], color: CardColor, seed: UInt64) -> GameEngine {
        let configuration = GameConfiguration(
            mode: .soloVersusSelf,
            format: .classic,
            playerDeckID: nil,
            opponentDeckID: nil,
            fixedDeckColor: color
        )
        return GameEngine(
            configuration: configuration,
            database: CardDatabase(cards: pool),
            decks: DeckStore(),
            seed: seed
        )
    }

    /// Settles the opening mulligan — the second player keeps — so the game
    /// stands at the top of turn 1 with the first player to act.
    static func started(pool: [Card], color: CardColor, seed: UInt64) -> GameEngine {
        let engine = engine(pool: pool, color: color, seed: seed)
        if let second = engine.state.awaitingMulligan {
            engine.apply(.mulligan(keep: true), by: second)
        }
        return engine
    }

    /// Replays the deterministic setup over consecutive seeds until `build`
    /// produces a scenario. Deterministic: the same seed always deals the
    /// same hands, so the first fitting seed never changes between runs.
    static func scenario<T>(seeds: ClosedRange<UInt64> = 1...200, _ build: (UInt64) -> T?) -> T? {
        for seed in seeds {
            if let built = build(seed) { return built }
        }
        return nil
    }

    /// Where any of the named cards sits in a hand right now. Asked fresh
    /// after every play because indices shift as cards leave.
    static func handIndex(ofAny ids: [String], for slot: PlayerSlot, in engine: GameEngine) -> Int? {
        engine.state[slot].hand.firstIndex { ids.contains($0) }
    }

    /// Passes every open counter window until none is left, from whichever
    /// side holds priority — the tests' stand-in for two players declining.
    static func settleWindows(_ engine: GameEngine) {
        var safety = 0
        while let window = engine.responseWindow, safety < 12 {
            safety += 1
            guard engine.apply(.passCounter, by: window.respondingSlot).isSuccess else { return }
        }
    }

    /// Summons the first plain character in `slot`'s hand and settles the
    /// summon window it opens.
    /// - Returns: the new body's in-play identity, or `nil` if nothing could
    ///   be summoned.
    @discardableResult
    static func summonBody(in engine: GameEngine, by slot: PlayerSlot) -> UUID? {
        guard let index = engine.state[slot].hand.firstIndex(where: {
            engine.card(for: $0)?.type == .character
        }) else { return nil }
        guard engine.apply(.summon(handIndex: index), by: slot).isSuccess else { return nil }
        let summoned = engine.state[slot].characters.last?.id
        settleWindows(engine)
        return summoned
    }

    // MARK: Combat board

    /// A mid-game board on the all-identical combat pool, at the top of
    /// turn 4: `a1` is rested from its turn-3 leader attack, `a2` and `b1`
    /// stand, and it is the second player's turn.
    struct CombatBoard {
        let engine: GameEngine
        let first: PlayerSlot
        let second: PlayerSlot

        /// First player's body from turn 1 — rested, one life already taken.
        let a1: UUID

        /// First player's body from turn 3 — standing, an illegal target.
        let a2: UUID

        /// Second player's body from turn 2 — standing, about to act.
        let b1: UUID
    }

    static func combatBoard(seed: UInt64 = 21) -> CombatBoard? {
        let engine = started(pool: Pool.combat, color: .red, seed: seed)
        let first = engine.state.firstPlayer
        let second = first.opposing
        guard let a1 = summonBody(in: engine, by: first),
              engine.apply(.endTurn, by: first).isSuccess,
              let b1 = summonBody(in: engine, by: second),
              engine.apply(.endTurn, by: second).isSuccess,
              let a2 = summonBody(in: engine, by: first),
              engine.apply(.declareAttack(attacker: .character(a1), target: .leader),
                           by: first).isSuccess
        else { return nil }
        settleWindows(engine)
        guard engine.apply(.endTurn, by: first).isSuccess else { return nil }
        return CombatBoard(engine: engine, first: first, second: second, a1: a1, a2: a2, b1: b1)
    }

    // MARK: Window scenarios

    /// A game paused on an open summon window: the setter laid a face-down
    /// card on turn 1, and the summoner's turn-2 summon is waiting on them.
    struct SummonWindow {
        let engine: GameEngine
        let setter: PlayerSlot
        let summoner: PlayerSlot
        let summonedID: UUID
    }

    static func summonWindow(setting ids: [String]) -> SummonWindow? {
        scenario { seed in
            let engine = started(pool: Pool.windows, color: .blue, seed: seed)
            let setter = engine.state.firstPlayer
            let summoner = setter.opposing
            guard let index = handIndex(ofAny: ids, for: setter, in: engine),
                  engine.apply(.setSupport(handIndex: index), by: setter).isSuccess,
                  engine.apply(.endTurn, by: setter).isSuccess,
                  engine.apply(.summon(handIndex: 0), by: summoner).isSuccess,
                  engine.responseWindow?.kind == .summon,
                  let summoned = engine.state[summoner].characters.last?.id
            else { return nil }
            return SummonWindow(engine: engine, setter: setter,
                                summoner: summoner, summonedID: summoned)
        }
    }

    /// A game one action short of a live chain: the setter holds a face-down
    /// answer, and the caster holds a main-timing jutsu ready to play.
    struct ChainStage {
        let engine: GameEngine
        let setter: PlayerSlot
        let caster: PlayerSlot
        let jutsuIndex: Int
    }

    static func chainStage() -> ChainStage? {
        scenario { seed in
            let engine = started(pool: Pool.windows, color: .blue, seed: seed)
            let setter = engine.state.firstPlayer
            let caster = setter.opposing
            guard let setIndex = handIndex(ofAny: Pool.negateIDs, for: setter, in: engine),
                  engine.apply(.setSupport(handIndex: setIndex), by: setter).isSuccess,
                  engine.apply(.endTurn, by: setter).isSuccess,
                  let jutsuIndex = handIndex(ofAny: Pool.jutsuIDs, for: caster, in: engine)
            else { return nil }
            return ChainStage(engine: engine, setter: setter, caster: caster, jutsuIndex: jutsuIndex)
        }
    }

    /// A game paused on an open attack window: the defender set the named
    /// card on their turn, and the attacker's turn-3 body is now swinging at
    /// their Leader.
    struct AttackWindow {
        let engine: GameEngine
        let attacker: PlayerSlot
        let defender: PlayerSlot
        let attackerID: UUID
    }

    static func attackWindow(setting ids: [String]) -> AttackWindow? {
        scenario { seed in
            let engine = started(pool: Pool.windows, color: .blue, seed: seed)
            let attacker = engine.state.firstPlayer
            let defender = attacker.opposing
            guard let attackerID = summonBody(in: engine, by: attacker),
                  engine.apply(.endTurn, by: attacker).isSuccess,
                  let setIndex = handIndex(ofAny: ids, for: defender, in: engine),
                  engine.apply(.setSupport(handIndex: setIndex), by: defender).isSuccess,
                  engine.apply(.endTurn, by: defender).isSuccess,
                  engine.apply(.declareAttack(attacker: .character(attackerID), target: .leader),
                               by: attacker).isSuccess,
                  engine.responseWindow?.kind == .attack
            else { return nil }
            return AttackWindow(engine: engine, attacker: attacker,
                                defender: defender, attackerID: attackerID)
        }
    }

    // MARK: EX scenarios

    /// A game whose first player holds the named EX card and something plain
    /// to summon beside it.
    static func exBoard(holding exID: String) -> (engine: GameEngine, slot: PlayerSlot)? {
        scenario { seed in
            let engine = started(pool: Pool.exPool, color: .red, seed: seed)
            let slot = engine.state.firstPlayer
            guard handIndex(ofAny: [exID], for: slot, in: engine) != nil,
                  engine.state[slot].hand.contains(where: {
                      engine.card(for: $0)?.type == .character
                  })
            else { return nil }
            return (engine, slot)
        }
    }

    /// A game paused on the seeker's search prompt, with at least one deck
    /// card on offer so the test can watch the deck afterwards.
    static func searchChoice() -> (engine: GameEngine, slot: PlayerSlot)? {
        scenario { seed in
            let engine = started(pool: Pool.exPool, color: .red, seed: seed)
            let slot = engine.state.firstPlayer
            guard handIndex(ofAny: [Pool.exSeeker], for: slot, in: engine) != nil,
                  summonBody(in: engine, by: slot) != nil,
                  let seekIndex = handIndex(ofAny: [Pool.exSeeker], for: slot, in: engine),
                  engine.apply(.summon(handIndex: seekIndex), by: slot).isSuccess,
                  engine.pendingChoice?.kind == .searchSummon,
                  engine.pendingChoice?.options.contains(where: {
                      if case .deckCard = $0.target { return true }
                      return false
                  }) == true
            else { return nil }
            return (engine, slot)
        }
    }
}

// MARK: - Opening mulligan

@Suite("Opening mulligan")
struct MulliganTests {

    @Test("Only the player going second may mulligan, exactly once")
    func secondPlayerOnly() throws {
        let engine = Harness.engine(pool: Pool.combat, color: .red, seed: 7)
        let first = engine.state.firstPlayer
        let second = first.opposing

        #expect(engine.isAwaitingMulligan)
        #expect(engine.state.awaitingMulligan == second)
        #expect(engine.decider == second)

        // The first player never gets the option, and nothing else may happen
        // until the second player answers.
        #expect(engine.apply(.mulligan(keep: true), by: first).error == .mulliganUnavailable)
        #expect(engine.apply(.summon(handIndex: 0), by: second).error == .awaitingMulligan)
        #expect(engine.apply(.endTurn, by: first).error == .awaitingMulligan)

        #expect(engine.apply(.mulligan(keep: true), by: second).isSuccess)
        #expect(engine.state[second].mulliganDone)
        #expect(engine.state.awaitingMulligan == nil)

        // Turn 1 begins the moment they answer: the first player has drawn
        // their opening one and stands in the main phase.
        #expect(engine.currentPlayer == first)
        #expect(engine.turnNumber == 1)
        #expect(engine.phase == .main)
        #expect(engine.state[first].hand.count == GameRules.openingHandSize + GameRules.firstTurnDraw)

        // The option never comes back, for either player.
        #expect(engine.apply(.mulligan(keep: true), by: second).error == .mulliganUnavailable)
        #expect(engine.apply(.mulligan(keep: false), by: first).error == .mulliganUnavailable)
    }

    @Test("Keeping leaves the hand exactly as dealt")
    func keepLeavesHandUntouched() {
        let engine = Harness.engine(pool: Pool.combat, color: .red, seed: 9)
        let second = engine.state.firstPlayer.opposing
        let dealt = engine.state[second].hand

        #expect(engine.apply(.mulligan(keep: true), by: second).isSuccess)
        #expect(engine.state[second].hand == dealt)
    }

    @Test("Redrawing reshuffles the whole deck and deals five new")
    func redrawIsAllOrNothing() {
        let engine = Harness.engine(pool: Pool.combat, color: .red, seed: 9)
        let second = engine.state.firstPlayer.opposing
        let handBefore = engine.state[second].hand
        let deckBefore = engine.state[second].deck
        #expect(handBefore.count == GameRules.openingHandSize)

        #expect(engine.apply(.mulligan(keep: false), by: second).isSuccess)

        // Five cards in hand, the rest in the deck, and not a card lost: the
        // hand went back in before the reshuffle.
        #expect(engine.state[second].hand.count == GameRules.openingHandSize)
        #expect(engine.state[second].deck.count == deckBefore.count)
        #expect((engine.state[second].hand + engine.state[second].deck).sorted()
                    == (handBefore + deckBefore).sorted())
        #expect(engine.state[second].mulliganDone)
    }
}

// MARK: - Turn machine

@Suite("Turn machine")
struct TurnMachineTests {

    @Test("Turn 1 draws one card, every later turn draws two")
    func openingDraws() {
        let engine = Harness.started(pool: Pool.combat, color: .red, seed: 3)
        let first = engine.state.firstPlayer
        let second = first.opposing

        #expect(engine.drawCount(forTurn: 1) == GameRules.firstTurnDraw)
        #expect(engine.drawCount(forTurn: 2) == GameRules.normalDraw)
        #expect(engine.state[first].hand.count == GameRules.openingHandSize + 1)

        // The second player draws two on their own first turn — turn 2.
        #expect(engine.apply(.endTurn, by: first).isSuccess)
        #expect(engine.turnNumber == 2)
        #expect(engine.currentPlayer == second)
        #expect(engine.state[second].hand.count == GameRules.openingHandSize + 2)
        #expect(engine.phase == .main)
        #expect(engine.step == .normal)

        // And so does the first player on turn 3.
        #expect(engine.apply(.endTurn, by: second).isSuccess)
        #expect(engine.turnNumber == 3)
        #expect(engine.state[first].hand.count == GameRules.openingHandSize + 1 + 2)
    }

    @Test("One normal summon a turn, back again next turn")
    func oneNormalSummonPerTurn() throws {
        let engine = Harness.started(pool: Pool.combat, color: .red, seed: 3)
        let first = engine.state.firstPlayer

        try #require(Harness.summonBody(in: engine, by: first) != nil)
        #expect(engine.hasSummonedThisTurn(first))
        #expect(engine.state[first].summonRested)
        #expect(engine.state[first].summonsUsedThisTurn == 1)

        // A second body is refused by the allowance, not by the board.
        #expect(engine.apply(.summon(handIndex: 0), by: first).error == .summonAlreadyUsed)
        #expect(engine.state[first].characters.count == 1)

        // The allowance returns with the player's next turn.
        #expect(engine.apply(.endTurn, by: first).isSuccess)
        #expect(engine.apply(.endTurn, by: first.opposing).isSuccess)
        #expect(!engine.hasSummonedThisTurn(first))
        #expect(!engine.state[first].summonRested)
        try #require(Harness.summonBody(in: engine, by: first) != nil)
        #expect(engine.state[first].characters.count == 2)
    }

    @Test("A summon opens a window the opponent must answer")
    func summonOpensAWindow() throws {
        let engine = Harness.started(pool: Pool.combat, color: .red, seed: 5)
        let first = engine.state.firstPlayer

        #expect(engine.apply(.summon(handIndex: 0), by: first).isSuccess)

        let window = try #require(engine.responseWindow, "a summon must be answerable")
        #expect(window.kind == .summon)
        #expect(window.respondingSlot == first.opposing)
        #expect(engine.decider == first.opposing)
        #expect(engine.step == .counter)

        // The summoner can do nothing while it is open — including passing a
        // window that is not theirs to pass.
        #expect(engine.apply(.endTurn, by: first).error == .wrongMoment)
        #expect(engine.apply(.summon(handIndex: 0), by: first).error == .wrongMoment)
        #expect(engine.apply(.passCounter, by: first).error == .notYourTurn)

        // One pass against an empty chain closes it, and the turn carries on.
        #expect(engine.apply(.passCounter, by: first.opposing).isSuccess)
        #expect(engine.responseWindow == nil)
        #expect(engine.step == .normal)
        #expect(engine.currentPlayer == first)
        #expect(engine.turnNumber == 1)
    }
}

// MARK: - The first-turn attack bar

/// The reported Leader bug, pinned: the no-attack bar covers game turn 1
/// only, Leaders attack like anything else, and a Leader attack rests the
/// Leader and is spent for the turn.
@Suite("First-turn attack bar")
struct AttackBarTests {

    @Test("Nobody attacks on game turn 1 — not even with a fresh body")
    func noAttacksOnTurnOne() throws {
        let engine = Harness.started(pool: Pool.combat, color: .red, seed: 9)
        let first = engine.state.firstPlayer
        #expect(engine.turnNumber == 1)

        #expect(engine.apply(.declareAttack(attacker: .leader, target: .leader),
                             by: first).error == .tooEarly)
        #expect(engine.attackBlock(attacker: .leader, by: first) == .tooEarly)

        // A summoned body is refused for the turn, not for its summoning
        // sickness — the bar is checked first.
        let body = try #require(Harness.summonBody(in: engine, by: first))
        #expect(engine.attackBlock(attacker: .character(body), by: first) == .tooEarly)

        // And no attack is ever offered.
        #expect(!engine.legalActions(for: first).contains { action in
            if case .declareAttack = action { return true }
            return false
        })
    }

    @Test("The second player's Leader attacks on turn 2, resting and spending itself")
    func secondPlayerLeaderAttacksOnTurnTwo() throws {
        let engine = Harness.started(pool: Pool.combat, color: .red, seed: 9)
        let first = engine.state.firstPlayer
        let second = first.opposing

        #expect(engine.apply(.endTurn, by: first).isSuccess)
        #expect(engine.turnNumber == 2)

        // Turn 2 is attackable: only summoning sickness holds a fresh body
        // back now, which proves the bar itself has lifted.
        let fresh = try #require(Harness.summonBody(in: engine, by: second))
        #expect(engine.attackBlock(attacker: .character(fresh), by: second) == .summoningSickness)

        #expect(engine.apply(.declareAttack(attacker: .leader, target: .leader),
                             by: second).isSuccess)
        #expect(engine.state[second].leaderRested)
        #expect(engine.state[second].leaderAttacksUsed == 1)

        let window = try #require(engine.responseWindow)
        #expect(window.kind == .attack)
        #expect(window.respondingSlot == first)
        #expect(engine.apply(.passCounter, by: first).isSuccess)

        // The Leader's DAMAGE stat comes off the defending Leader's life.
        #expect(engine.state[first].life == 15 - 2)

        // Once per turn, and mutually exclusive with Recovery: both are
        // refused off the rested Leader.
        #expect(engine.apply(.declareAttack(attacker: .leader, target: .leader),
                             by: second).error == .rested)
        #expect(engine.state[second].leaderAttacksUsed == 1)
        #expect(engine.recoveryBlock(for: second) == .rested)
    }

    @Test("The first player's Leader waits until turn 3")
    func firstPlayerLeaderWaitsUntilTurnThree() {
        let engine = Harness.started(pool: Pool.combat, color: .red, seed: 9)
        let first = engine.state.firstPlayer
        let second = first.opposing

        #expect(engine.apply(.endTurn, by: first).isSuccess)

        // Turn 2 belongs to the second player.
        #expect(engine.apply(.declareAttack(attacker: .leader, target: .leader),
                             by: first).error == .notYourTurn)

        #expect(engine.apply(.endTurn, by: second).isSuccess)
        #expect(engine.turnNumber == 3)
        #expect(engine.apply(.declareAttack(attacker: .leader, target: .leader),
                             by: first).isSuccess)
        Harness.settleWindows(engine)
        #expect(engine.state[second].life == 15 - 2)
    }
}

// MARK: - Combat

/// The two stats, the one legal shape of target, and the end-of-turn wipe —
/// on a pool where every body is the same 4-power, 1-damage, 6-health card.
@Suite("Combat")
struct CombatTests {

    @Test("Targets are the Leader or rested characters; hits use power and never bounce back")
    func targetsAndStats() throws {
        let board = try #require(Harness.combatBoard(), "the scripted opening fell through")
        let engine = board.engine

        // The turn-3 leader attack landed the attacker's DAMAGE stat.
        #expect(engine.state[board.second].life == 15 - 1)
        #expect(engine.state[board.first].character(id: board.a1)?.isRested == true)

        // A standing character is not a legal target, and the refusal costs
        // the attacker nothing.
        #expect(!engine.canAttack(attacker: .character(board.b1),
                                  target: .character(board.a2), by: board.second))
        #expect(engine.apply(.declareAttack(attacker: .character(board.b1),
                                            target: .character(board.a2)),
                             by: board.second).error == .invalidTarget)
        #expect(engine.state[board.second].character(id: board.b1)?.isRested == false)
        #expect(engine.state[board.second].character(id: board.b1)?.attacksUsed == 0)

        // The rested body is legal, and takes the attacker's POWER as damage.
        #expect(engine.apply(.declareAttack(attacker: .character(board.b1),
                                            target: .character(board.a1)),
                             by: board.second).isSuccess)
        Harness.settleWindows(engine)

        let a1 = try #require(engine.state[board.first].character(id: board.a1))
        let a1Card = try #require(engine.card(for: a1))
        #expect(a1.damage == 4)
        #expect(a1.remainingHealth(of: a1Card) == 2)

        // No back-damage, no life involved: the attacker is rested and spent
        // but untouched, and neither Leader felt a character fight.
        let b1 = try #require(engine.state[board.second].character(id: board.b1))
        #expect(b1.damage == 0)
        #expect(b1.isRested)
        #expect(b1.attacksUsed == 1)
        #expect(engine.state[board.first].life == 15)

        // Damage heals at end of turn — it only ever matters inside the turn.
        #expect(engine.apply(.endTurn, by: board.second).isSuccess)
        #expect(engine.state[board.first].character(id: board.a1)?.damage == 0)
    }

    @Test("Damage accumulates within a turn and kills through printed health")
    func accumulatedDamageKills() throws {
        let board = try #require(Harness.combatBoard(), "the scripted opening fell through")
        let engine = board.engine
        let b1CardID = try #require(engine.state[board.second].character(id: board.b1)?.cardID)

        // Turn 4: b1 trades into the rested a1 — 4 damage, not lethal — and
        // rests itself doing it.
        #expect(engine.apply(.declareAttack(attacker: .character(board.b1),
                                            target: .character(board.a1)),
                             by: board.second).isSuccess)
        Harness.settleWindows(engine)
        #expect(engine.apply(.endTurn, by: board.second).isSuccess)

        // Turn 5: both of the first player's bodies stand again, b1 is still
        // rested from its own attack, and two 4-power hits beat 6 health.
        #expect(engine.apply(.declareAttack(attacker: .character(board.a1),
                                            target: .character(board.b1)),
                             by: board.first).isSuccess)
        Harness.settleWindows(engine)
        #expect(engine.state[board.second].character(id: board.b1)?.damage == 4)

        #expect(engine.apply(.declareAttack(attacker: .character(board.a2),
                                            target: .character(board.b1)),
                             by: board.first).isSuccess)
        Harness.settleWindows(engine)

        #expect(engine.state[board.second].character(id: board.b1) == nil,
                "8 damage against 6 health must K.O.")
        #expect(engine.state[board.second].trash.contains(b1CardID))
    }
}

// MARK: - Response windows and the chain

@Suite("Response windows and the chain")
struct ResponseWindowTests {

    @Test("A Shisui-style negate cannot answer a summon")
    func negateRefusedAtSummonWindow() throws {
        let game = try #require(Harness.summonWindow(setting: Pool.negateIDs),
                                "no seed set a negate before a summon")
        let engine = game.engine

        // The window is open and the setter holds priority — but a response-
        // class card needs a chain to respond to, and a summon opens none.
        #expect(engine.responseWindow?.kind == .summon)
        #expect(engine.decider == game.setter)
        #expect(engine.state.chain.isEmpty)

        #expect(engine.slotActivationBlock(slotIndex: 0, by: game.setter) == .wrongMoment)
        #expect(engine.apply(.activateSupport(slotIndex: 0), by: game.setter).error == .wrongMoment)
        #expect(engine.legalCounterActivations(for: game.setter).isEmpty,
                "nothing the setter holds can answer a bare summon")

        // Passing lets the summon through untouched.
        #expect(engine.apply(.passCounter, by: game.setter).isSuccess)
        #expect(engine.state[game.summoner].character(id: game.summonedID) != nil)
        #expect(engine.step == .normal)
    }

    @Test("A Quick support may answer the same summon window")
    func quickAnswersSummonWindow() throws {
        let game = try #require(Harness.summonWindow(setting: Pool.quickIDs),
                                "no seed set a Quick card before a summon")
        let engine = game.engine
        let lifeBefore = engine.state[game.setter].life

        #expect(engine.slotActivationBlock(slotIndex: 0, by: game.setter) == nil)
        #expect(engine.apply(.activateSupport(slotIndex: 0), by: game.setter).isSuccess)
        Harness.settleWindows(engine)

        // The jutsu resolved — one life gained, one chakra paid, the card in
        // the trash — and the summoned body stands untouched.
        #expect(engine.state[game.setter].life == lifeBefore + 1)
        #expect(engine.state[game.setter].faceUpChakra == GameRules.chakraCount - 1)
        #expect(engine.state[game.setter].trash.contains { Pool.quickIDs.contains($0) })
        #expect(engine.state[game.setter].supports.allSatisfy { $0 == nil })
        #expect(engine.state[game.summoner].character(id: game.summonedID) != nil)
        #expect(engine.step == .normal)
        #expect(engine.currentPlayer == game.summoner)
    }

    @Test("A negate answers a jutsu activation and cancels it outright")
    func negateAnswersTheChain() throws {
        let stage = try #require(Harness.chainStage(),
                                 "no seed dealt a negate to one side and a jutsu to the other")
        let engine = stage.engine
        let lifeBefore = engine.state[stage.caster].life

        // The caster plays the jutsu from hand: it chains, and the setter —
        // face-down card waiting — gets priority to respond.
        #expect(engine.apply(.activateSupportFromHand(handIndex: stage.jutsuIndex),
                             by: stage.caster).isSuccess)
        #expect(engine.state.chain.count == 1)
        #expect(engine.responseWindow?.kind == .chain)
        #expect(engine.decider == stage.setter)

        // The response-class negate is legal here — this is exactly the
        // window it exists for.
        #expect(engine.apply(.activateSupport(slotIndex: 0), by: stage.setter).isSuccess)
        #expect(engine.state.chain.count == 2)
        Harness.settleWindows(engine)

        // LIFO: the negate resolved first and removed the link below it. The
        // jutsu went to its owner's trash having done nothing, and neither
        // card's chakra came back.
        #expect(engine.state[stage.caster].life == lifeBefore,
                "the negated jutsu must not resolve its life gain")
        #expect(engine.state[stage.caster].trash.contains { Pool.jutsuIDs.contains($0) })
        #expect(engine.state[stage.setter].trash.contains { Pool.negateIDs.contains($0) })
        #expect(engine.state[stage.caster].faceUpChakra == GameRules.chakraCount - 1)
        #expect(engine.state[stage.setter].faceUpChakra == GameRules.chakraCount - 1)
        #expect(engine.state[stage.caster].supports.allSatisfy { $0 == nil })
        #expect(engine.state[stage.setter].supports.allSatisfy { $0 == nil })
        #expect(engine.state.chain.isEmpty)
        #expect(engine.step == .normal)
        #expect(engine.currentPlayer == stage.caster)
    }

    @Test("A negate cannot answer a bare attack, and there is no block action")
    func negateRefusedAtAttackWindow() throws {
        let game = try #require(Harness.attackWindow(setting: Pool.negateIDs),
                                "no seed set a negate before an attack")
        let engine = game.engine

        // The attack window has an empty chain, so the response-class card
        // has nothing to respond to.
        #expect(engine.slotActivationBlock(slotIndex: 0, by: game.defender) == .wrongMoment)
        #expect(engine.legalCounterActivations(for: game.defender).isEmpty)

        // No blocking exists: the defender's whole vocabulary is pass or
        // concede, and declaring an attack back is not theirs to do.
        #expect(engine.legalActions(for: game.defender) == [.passCounter, .concede])
        #expect(engine.legalActions(for: game.attacker) == [.concede])
        #expect(engine.apply(.declareAttack(attacker: .leader, target: .leader),
                             by: game.defender).error == .notYourTurn)

        // Passing lets the attack land for the attacker's damage stat.
        #expect(engine.apply(.passCounter, by: game.defender).isSuccess)
        #expect(engine.state[game.defender].life == 15 - 1)
    }

    @Test("An interrupted attack is cancelled but stays spent")
    func interruptCancelsButSpends() throws {
        let game = try #require(Harness.attackWindow(setting: Pool.trapIDs),
                                "no seed set an interrupt before an attack")
        let engine = game.engine
        #expect(engine.pendingAttack != nil)

        // The counter-class trap is legal in exactly this window.
        #expect(engine.apply(.activateSupport(slotIndex: 0), by: game.defender).isSuccess)
        Harness.settleWindows(engine)

        // The attack never resolved, but the attacker got nothing back.
        #expect(engine.pendingAttack == nil)
        #expect(engine.state[game.defender].life == 15, "the interrupted attack must not land")
        let attacker = try #require(engine.state[game.attacker].character(id: game.attackerID))
        #expect(attacker.isRested)
        #expect(attacker.attacksUsed == 1)
        #expect(engine.apply(.declareAttack(attacker: .character(game.attackerID), target: .leader),
                             by: game.attacker).error == .rested)

        // "Summon this card" kept the trap on the board instead of trashing
        // it — a fresh body with summoning sickness.
        let trap = try #require(engine.state[game.defender].characters.first {
            Pool.trapIDs.contains($0.cardID)
        })
        let trapCard = try #require(engine.card(for: trap))
        #expect(trap.summonedOnTurn == engine.turnNumber)
        #expect(!trap.canAttack(card: trapCard, turn: engine.turnNumber))
        #expect(!engine.state[game.defender].trash.contains { Pool.trapIDs.contains($0) })
        #expect(engine.state[game.defender].supports.allSatisfy { $0 == nil })
        #expect(engine.step == .normal)
    }
}

// MARK: - Board size

@Suite("Board size")
struct BoardSizeTests {

    @Test("The characters row grows past the mat's five printed slots")
    func charactersRowIsUnbounded() throws {
        let engine = Harness.started(pool: Pool.clones, color: .red, seed: 4)
        let slot = engine.state.firstPlayer

        // One normal summon, then every remaining clone plays itself through
        // its free Quick jutsu — effect summons are uncapped and open no
        // summon window.
        try #require(Harness.summonBody(in: engine, by: slot) != nil)
        while !engine.state[slot].hand.isEmpty {
            #expect(engine.apply(.activateSupportFromHand(handIndex: 0), by: slot).isSuccess)
            Harness.settleWindows(engine)
            #expect(engine.responseWindow == nil,
                    "an effect-driven summon must not open a summon window")
        }

        #expect(engine.state[slot].characters.count == 6)
        #expect(engine.state[slot].characters.count > GameRules.maxCharacters,
                "the row must grow past the mat's printed slots")

        // Every self-summoned card was kept, not trashed, and each slot it
        // transited through is free again.
        #expect(engine.state[slot].trash.isEmpty)
        #expect(engine.state[slot].supports.allSatisfy { $0 == nil })
        #expect(engine.state[slot].characters.allSatisfy { !$0.effectsNegated })
    }
}

// MARK: - EX Characters

@Suite("EX Characters")
struct EXCharacterTests {

    @Test("An EX Character is refused while its Summon Requirements cannot be paid")
    func refusedWithoutPayment() throws {
        let (engine, slot) = try #require(Harness.exBoard(holding: Pool.exBig),
                                          "no seed dealt the EX card")
        let index = try #require(Harness.handIndex(ofAny: [Pool.exBig], for: slot, in: engine))

        // An empty board cannot pay "place 1 of your Characters in your
        // trash", so the only door this card comes in by is shut.
        #expect(engine.state[slot].characters.isEmpty)
        #expect(engine.apply(.summon(handIndex: index), by: slot).error
                    == .summonRequirementUnpaid("Great Beast"))
        #expect(!engine.hasSummonedThisTurn(slot))
    }

    @Test("An EX summon pays its price, skips the summon limit, and opens the window")
    func paysAndIgnoresTheLimit() throws {
        let (engine, slot) = try #require(Harness.exBoard(holding: Pool.exBig),
                                          "no seed dealt the EX card")

        // Spend the turn's one normal summon first — the moment every plain
        // card is refused in.
        let sacrifice = try #require(Harness.summonBody(in: engine, by: slot))
        let sacrificeCardID = try #require(engine.state[slot].character(id: sacrifice)?.cardID)
        #expect(engine.hasSummonedThisTurn(slot))

        let index = try #require(Harness.handIndex(ofAny: [Pool.exBig], for: slot, in: engine))
        #expect(engine.apply(.summon(handIndex: index), by: slot).isSuccess)

        // The single candidate paid the single requirement without a prompt,
        // and the body arrived.
        #expect(engine.pendingChoice == nil)
        #expect(engine.state[slot].character(id: sacrifice) == nil)
        #expect(engine.state[slot].trash.contains(sacrificeCardID))
        #expect(engine.state[slot].characters.contains { $0.cardID == Pool.exBig && $0.isEX })

        // The EX summon never touched the normal allowance, and it is just
        // as answerable as any other summon.
        #expect(engine.state[slot].summonsUsedThisTurn == 1)
        #expect(engine.responseWindow?.kind == .summon)
        #expect(engine.responseWindow?.respondingSlot == slot.opposing)
        Harness.settleWindows(engine)
    }

    @Test("A search summon arrives with its effects dead but its stats alive")
    func searchSummonArrivesNegated() throws {
        let (engine, slot) = try #require(Harness.searchChoice(),
                                          "no seed reached the seeker's search prompt")
        let choice = try #require(engine.pendingChoice)
        #expect(choice.kind == .searchSummon)
        #expect(choice.cancellable, "the search is 'up to 1' and may be declined")

        let option = try #require(choice.options.first {
            if case .deckCard = $0.target { return true }
            return false
        })
        guard case .deckCard(_, let deckIndex) = option.target else {
            Issue.record("the chosen option stopped pointing at the deck")
            return
        }
        let deckBefore = engine.state[slot].deck
        let lifeBefore = engine.state[slot].life
        let chosenCardID = deckBefore[deckIndex]

        #expect(engine.apply(.resolveChoice(keys: [option.key]), by: slot).isSuccess)
        Harness.settleWindows(engine)

        // The body is on the board — a negated summon still arrives — but
        // with every printed effect dead: no On Summon life gain, no Rush.
        let clone = try #require(engine.state[slot].characters.first { $0.effectsNegated })
        let cloneCard = try #require(engine.card(for: clone))
        #expect(clone.cardID == chosenCardID)
        #expect(engine.state[slot].life == lifeBefore,
                "a negated On Summon must not fire")
        #expect(!clone.hasRush(card: cloneCard, turn: engine.turnNumber))
        #expect(!clone.canAttack(card: cloneCard, turn: engine.turnNumber))

        // The same card without the negation would have Rush — the stats and
        // printed text are intact, only the effects are dead.
        let twin = CharacterInPlay(id: UUID(), cardID: cloneCard.id, isEX: false,
                                   summonedOnTurn: engine.turnNumber)
        #expect(twin.hasRush(card: cloneCard, turn: engine.turnNumber))

        // The search took one card out of the deck and left the rest exactly
        // where they lay — no reshuffle.
        var expected = deckBefore
        expected.remove(at: deckIndex)
        #expect(engine.state[slot].deck == expected)
    }
}

// MARK: - Recovery

@Suite("Recovery")
struct RecoveryTests {

    @Test("Recovery is barred on the game's opening turn")
    func barredOnTurnOne() {
        let engine = Harness.started(pool: Pool.combat, color: .red, seed: 3)
        let first = engine.state.firstPlayer

        #expect(engine.recoveryBlock(for: first) == .tooEarly)
        #expect(engine.apply(.recovery, by: first).error == .tooEarly)
    }

    @Test("Recovery rests the Leader and turns every chakra face-up")
    func restsLeaderAndFlipsChakra() {
        let engine = Harness.started(pool: Pool.combat, color: .red, seed: 3)
        let first = engine.state.firstPlayer
        let second = first.opposing

        // Spend chakra through the Leader's printed box. The box never rests
        // the Leader, and Once Per Turn holds it to one use.
        #expect(engine.apply(.leaderEffect, by: first).isSuccess)
        #expect(engine.state[first].faceUpChakra == GameRules.chakraCount - 2)
        #expect(!engine.state[first].leaderRested)
        #expect(engine.apply(.leaderEffect, by: first).error == .alreadyUsed)
        #expect(engine.apply(.endTurn, by: first).isSuccess)

        // The second player recovers on their own first turn — turn 2 is the
        // first turn Recovery exists on.
        #expect(engine.apply(.leaderEffect, by: second).isSuccess)
        #expect(engine.state[second].faceUpChakra == GameRules.chakraCount - 2)
        #expect(engine.apply(.recovery, by: second).isSuccess)
        #expect(engine.state[second].faceUpChakra == GameRules.chakraCount)
        #expect(engine.state[second].chakra.allSatisfy { $0.isFaceUp })
        #expect(engine.state[second].leaderRested)

        // Implicitly once per turn: the rested Leader refuses a second one,
        // and a Leader attack besides.
        #expect(engine.apply(.recovery, by: second).error == .rested)
        #expect(engine.apply(.declareAttack(attacker: .leader, target: .leader),
                             by: second).error == .rested)
        #expect(engine.apply(.endTurn, by: second).isSuccess)

        // Nothing recovers on its own: the first player's spent chakra is
        // still face-down until they take the action themselves.
        #expect(engine.state[first].faceUpChakra == GameRules.chakraCount - 2)
        #expect(engine.apply(.recovery, by: first).isSuccess)
        #expect(engine.state[first].faceUpChakra == GameRules.chakraCount)
    }
}

// MARK: - Shipped pool timings

/// The real cards, decoded straight from the bundled `cards.json` so an
/// imported pool on the test device can never redirect these assertions.
private enum Shipped {
    static func database() -> CardDatabase? {
        guard let url = Bundle.main.url(forResource: "cards", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let pool = try? JSONDecoder().decode([Card].self, from: data) else { return nil }
        return CardDatabase(cards: pool)
    }
}

@Suite("Shipped pool timings")
struct ShippedTimingTests {

    @Test("Shisui and Kakashi negate the chain, and only the chain")
    func negatesAreResponseClass() throws {
        let database = try #require(Shipped.database(), "cards.json is not reaching the bundle")
        for id in ["N-016", "K-039"] {
            let card = try #require(database.card(id: id))
            let bar = try #require(card.supportBarAbility, "\(id) lost its SUPPORT bar")
            #expect(bar.ability.trigger == .support,
                    "\(id) must print Support Activated timing")
            #expect(bar.ability.trigger.timingClass == .response,
                    "\(id) must class as a response — chain answers only")
            #expect(bar.ability.negatesChainLink)
        }
    }

    @Test("The defensive jutsus keep their printed timing classes")
    func supportTimingsMatchThePrint() throws {
        let database = try #require(Shipped.database(), "cards.json is not reaching the bundle")

        // "During Your Opponent's Attack" — defender-only, attack window only.
        for id in ["N-006", "N-008", "N-010", "SMP-02", "SMP-04", "SMP-15"] {
            let card = try #require(database.card(id: id))
            #expect(card.supportBarAbility?.ability.trigger.timingClass == .counter,
                    "\(id) must class as a counter")
        }
        // "Quick" — any open window, or your own main phase.
        for id in ["N-021", "SMP-01"] {
            let card = try #require(database.card(id: id))
            #expect(card.supportBarAbility?.ability.trigger.timingClass == .quick,
                    "\(id) must class as quick")
        }
        // "During Your Main" — proactive only.
        for id in ["N-004", "N-015"] {
            let card = try #require(database.card(id: id))
            #expect(card.supportBarAbility?.ability.trigger.timingClass == .main,
                    "\(id) must class as main")
        }
    }

    @Test("Every EX door is a Summon Requirement, never the normal summon")
    func exDoorsAreRequirements() throws {
        let database = try #require(Shipped.database(), "cards.json is not reaching the bundle")
        for id in ["N-005", "N-014", "N-022", "SMP-03"] {
            let card = try #require(database.card(id: id))
            #expect(card.cannotBeSummonedNormally)
            let requirement = try #require(card.summonRequirement,
                                           "\(id) prints no Summon Requirements")
            #expect(!requirement.ability.cost.trashRequirements.isEmpty)
        }
    }

    @Test("Naruto's Leader box repeats; Sasuke's is once per turn")
    func leaderOncePerTurnFlags() throws {
        let database = try #require(Shipped.database(), "cards.json is not reaching the bundle")

        let naruto = try #require(database.card(id: "N-001"))
        let narutoBox = try #require(naruto.abilities.first { $0.trigger == .activateMain })
        #expect(!narutoBox.oncePerTurn,
                "N-001's boost is limited only by chakra, not by a once-per-turn tag")

        let sasuke = try #require(database.card(id: "N-012"))
        let sasukeBox = try #require(sasuke.abilities.first { $0.trigger == .activateMain })
        #expect(sasukeBox.oncePerTurn)
    }

    @Test("Refusals carry the reference's own button copy")
    func refusalCopy() {
        #expect(GameError.wrongMoment.message == "Wrong moment")
        #expect(GameError.noValidTarget.message == "No valid target")
        #expect(GameError.summonAlreadyUsed.message == "Summon already used this turn")
    }
}

// MARK: - Result conveniences

private extension Result {
    var isSuccess: Bool { if case .success = self { return true }; return false }

    /// The refusal, or `nil` — for asserting *which* rule turned an action down.
    var error: Failure? { if case .failure(let e) = self { return e }; return nil }
}
