//
//  GameEngine+Setup.swift
//  NTCGSimulator
//
//  Everything that builds a game or answers questions about one: deck
//  resolution and the opening deal, card lookups, and the validation behind
//  `legalActions(for:)`. Nothing in this file mutates the board — the rules
//  that do live in GameEngine.swift.
//

import Foundation

// MARK: - Setup

/// Pure setup helpers. Kept out of `GameEngine` because they run before the
/// engine exists, and because deck resolution is the part most likely to change
/// as new formats arrive.
enum GameSetup {

    /// A resolved deck list: one Leader plus the cards to shuffle.
    struct DeckList: Hashable {
        let leaderID: String
        let cards: [String]

        /// Colour the list ended up in, used to pick the other side's colour
        /// and the Chakra art.
        let color: CardColor
    }

    // MARK: Board

    /// Builds the full opening state: both decks resolved, shuffled and dealt,
    /// Chakra placed ready, and the first player decided by the seeded coin toss.
    static func makeState(
        configuration: GameConfiguration,
        database: CardDatabase,
        decks: DeckStore,
        seed: UInt64
    ) -> GameState {
        var rng = SeededGenerator(seed: seed)

        let playerList = deckList(
            for: .player,
            configuration: configuration,
            database: database,
            decks: decks,
            opposingColor: nil
        )
        let opponentList = deckList(
            for: .opponent,
            configuration: configuration,
            database: database,
            decks: decks,
            opposingColor: playerList.color
        )

        let player = makeSide(slot: .player, list: playerList, database: database, rng: &rng)
        let opponent = makeSide(slot: .opponent, list: opponentList, database: database, rng: &rng)

        let first: PlayerSlot = Bool.random(using: &rng) ? .player : .opponent

        return GameState(
            player: player,
            opponent: opponent,
            current: first,
            firstPlayer: first,
            phase: .refresh,
            turnNumber: 0,
            outcome: .ongoing,
            pendingAttack: nil,
            rng: rng
        )
    }

    /// Shuffles one deck, deals its opening hand and lays out its Chakra row.
    private static func makeSide(
        slot: PlayerSlot,
        list: DeckList,
        database: CardDatabase,
        rng: inout SeededGenerator
    ) -> PlayerSide {
        var deck = list.cards
        deck.shuffle(using: &rng)

        let dealt = min(GameRules.openingHandSize, deck.count)
        let hand = Array(deck.prefix(dealt))
        deck.removeFirst(dealt)

        let chakraID = chakraCardID(for: list.color, database: database)
        let chakra = (0..<GameRules.chakraCount).map { _ in
            ChakraCard(id: rng.makeIdentifier(), cardID: chakraID)
        }

        return PlayerSide(
            slot: slot,
            leaderCardID: list.leaderID,
            life: database.card(id: list.leaderID)?.life ?? GameRules.defaultLeaderLife,
            deck: deck,
            hand: hand,
            chakra: chakra
        )
    }

    // MARK: Deck resolution

    /// Works out what a side actually brings to the table.
    ///
    /// - Vanilla expands the saved deck the player chose.
    /// - Classic ignores saved decks and generates the format's fixed 30-card
    ///   list in the chosen colour, giving the other side a rival colour.
    ///
    /// Anything unresolvable — a deleted deck, an empty deck, a pool without the
    /// chosen Leader — falls through to a generated list.
    static func deckList(
        for slot: PlayerSlot,
        configuration: GameConfiguration,
        database: CardDatabase,
        decks: DeckStore,
        opposingColor: CardColor?
    ) -> DeckList {
        switch configuration.format {
        case .vanilla:
            let deckID = slot == .player ? configuration.playerDeckID : configuration.opponentDeckID
            if let deckID,
               let saved = decks.deck(id: deckID),
               !saved.cardIDs.isEmpty,
               let leader = database.card(id: saved.leaderID) {
                return DeckList(leaderID: leader.id, cards: saved.cardIDs, color: leader.color)
            }
            let colour = opposingColor.map { rival(of: $0) }
                ?? configuration.fixedDeckColor
                ?? CardColor.red
            return generatedList(color: colour, size: GameFormat.vanilla.deckSize, database: database)

        case .classic:
            // Classic is a mirror: the player picks one fixed deck and BOTH
            // sides are dealt it, which is what the deck picker promises. The
            // opposing colour is deliberately ignored here.
            let chosen = configuration.fixedDeckColor ?? .red
            return generatedList(color: chosen, size: GameFormat.classic.deckSize, database: database)
        }
    }

    /// Builds a legal list of `size` cards in one colour by taking the pool in
    /// display order, one copy per pass, up to the four-copy limit. Deterministic
    /// by construction, so both sides of a Classic game are always identical.
    static func generatedList(color: CardColor, size: Int, database: CardDatabase) -> DeckList {
        let leader = database.leaders.first { $0.color == color } ?? database.leaders.first
        let pool: [Card]
        if let leader {
            pool = database.cardsPlayable(with: leader)
        } else {
            pool = database.cards.filter { $0.type.countsTowardDeckSize }
        }

        var cards: [String] = []
        if !pool.isEmpty {
            for _ in 0..<DeckRules.maxCopies where cards.count < size {
                for card in pool where cards.count < size {
                    cards.append(card.id)
                }
            }
        }

        return DeckList(
            leaderID: leader?.id ?? "",
            cards: cards,
            color: leader?.color ?? color
        )
    }

    // MARK: Helpers

    /// The colour a generated opponent takes, so the two sides never mirror.
    static func rival(of color: CardColor) -> CardColor {
        let all = CardColor.allCases
        guard let index = all.firstIndex(of: color), !all.isEmpty else { return color }
        return all[(index + 1) % all.count]
    }

    /// Chakra art for a side: its own colour where the pool prints one,
    /// otherwise whatever Chakra card exists.
    static func chakraCardID(for color: CardColor, database: CardDatabase) -> String {
        let chakra = database.chakraCards
        return chakra.first { $0.color == color }?.id ?? chakra.first?.id ?? ""
    }
}

// MARK: - Hand card

/// A card in hand paired with the index `GameAction.playCard` expects, plus
/// whether it can be played right now. Saves every hand view recomputing it.
struct HandCard: Identifiable, Hashable {
    /// The hand index — stable for as long as the card stays in hand.
    let id: Int
    let card: Card
    let isPlayable: Bool
}

// MARK: - Lookups

extension GameEngine {

    func side(_ slot: PlayerSlot) -> PlayerSide { state[slot] }

    /// The printed card behind a collector number, if the pool still has it.
    func card(for cardID: String) -> Card? { database.card(id: cardID) }

    func card(for character: CharacterInPlay) -> Card? { database.card(id: character.cardID) }

    func card(for chakra: ChakraCard) -> Card? { database.card(id: chakra.cardID) }

    func card(for placed: PlacedCard) -> Card? { database.card(id: placed.cardID) }

    func leaderCard(for slot: PlayerSlot) -> Card? { database.card(id: state[slot].leaderCardID) }

    func cards(_ cardIDs: [String]) -> [Card] { database.cards(ids: cardIDs) }

    /// The hand, index-aligned with `GameAction.playCard(handIndex:asJutsu:)`.
    func handCards(for slot: PlayerSlot) -> [HandCard] {
        state[slot].hand.enumerated().compactMap { (index, cardID) -> HandCard? in
            guard let card = database.card(id: cardID) else { return nil }
            return HandCard(id: index, card: card, isPlayable: canPlay(handIndex: index, by: slot))
        }
    }

    /// Finds a character on either board, with the side that owns it.
    func locateCharacter(id: UUID) -> (slot: PlayerSlot, character: CharacterInPlay)? {
        for slot in PlayerSlot.allCases {
            if let character = state[slot].character(id: id) { return (slot, character) }
        }
        return nil
    }

    /// The printed card behind an ability source, or `nil` when that card is not
    /// on `slot`'s side of the board. Returning `nil` for an absent body is what
    /// lets every ability path share one "is it still there" check.
    func abilityCard(for source: AbilitySource, by slot: PlayerSlot) -> Card? {
        switch source {
        case .leader:
            return database.card(id: state[slot].leaderCardID)
        case .character(let id):
            guard let character = state[slot].character(id: id) else { return nil }
            return database.card(id: character.cardID)
        }
    }
}

// MARK: - Queries

extension GameEngine {

    /// Chakra a side can still spend this turn.
    func availableChakra(for slot: PlayerSlot) -> Int { state[slot].readyChakra }

    /// Whether the card at `handIndex` can be played at all — as a body or,
    /// where it has a support line, as a jutsu.
    func canPlay(handIndex: Int, by slot: PlayerSlot) -> Bool {
        planPlay(handIndex: handIndex, asJutsu: false, by: slot).isSuccess
            || planPlay(handIndex: handIndex, asJutsu: true, by: slot).isSuccess
    }

    func canAttack(characterID: UUID, by slot: PlayerSlot) -> Bool {
        validateAttacker(characterID, by: slot).isSuccess
    }

    /// Whether a character could be chosen to block the declared attack.
    func canBlock(characterID: UUID) -> Bool {
        guard let pending = state.pendingAttack else { return false }
        return state[pending.defendingSlot].character(id: characterID)?.isReady == true
    }

    /// Whether one specific activation would be accepted right now.
    func canUseAbility(
        source: AbilitySource,
        abilityIndex: Int,
        targetID: UUID? = nil,
        by slot: PlayerSlot
    ) -> Bool {
        planAbility(source: source, abilityIndex: abilityIndex, targetID: targetID, by: slot).isSuccess
    }

    /// Whether a "Once Per Turn" box has already been spent this turn.
    func hasUsedAbility(_ source: AbilitySource, abilityIndex: Int, by slot: PlayerSlot) -> Bool {
        state[slot].hasUsed(AbilityUse(source: source, abilityIndex: abilityIndex))
    }

    /// The standing rules a card in play is under.
    ///
    /// `.passive` boxes are always true and `.yourTurn` boxes are true while
    /// their controller is the active player. Neither ever fires — there is no
    /// moment for the engine to resolve them at — so this exists purely so the
    /// board can tell a player which printed rules are currently in force,
    /// rather than leaving them to read the card and guess.
    func standingRules(for source: AbilitySource, by slot: PlayerSlot) -> [CardAbility] {
        guard let card = abilityCard(for: source, by: slot) else { return [] }
        return card.abilities.filter { ability in
            switch ability.trigger {
            case .passive:  return true
            case .yourTurn: return slot == state.current
            default:        return false
            }
        }
    }
}

// MARK: - Validation

extension GameEngine {

    /// A validated play, ready for the engine to commit.
    struct PlayPlan {
        let handIndex: Int
        let card: Card
        let asJutsu: Bool
        let cost: Int
    }

    /// Validates a play without touching the board — shared by `apply`,
    /// `canPlay` and `legalActions` so the three can never disagree.
    func planPlay(handIndex: Int, asJutsu: Bool, by slot: PlayerSlot) -> Result<PlayPlan, GameError> {
        guard !state.isFinished else { return .failure(.gameOver) }
        guard slot == state.current else { return .failure(.notYourTurn) }
        guard state.phase == .main else { return .failure(.wrongPhase(state.phase)) }
        guard state.pendingAttack == nil else { return .failure(.attackAlreadyPending) }

        let side = state[slot]
        guard side.hand.indices.contains(handIndex) else { return .failure(.invalidHandIndex) }

        let cardID = side.hand[handIndex]
        guard let card = database.card(id: cardID) else { return .failure(.unknownCard(cardID)) }

        // Summoning a body is free. Chakra is spent only on a jutsu play or on
        // a Support card — see `ChakraCost.toPlay`.
        let cost = ChakraCost.toPlay(card, asJutsu: asJutsu)
        guard side.readyChakra >= cost else {
            return .failure(.notEnoughChakra(required: cost, available: side.readyChakra))
        }

        if asJutsu {
            guard card.hasSupportLine else { return .failure(.noSupportLine(card.name)) }
        } else {
            // Summon Requirements cards print "Cannot be summoned normally".
            // Playing one from hand for its cost is exactly what that forbids,
            // so the normal summon is refused here — the printed requirement is
            // the only door in, and the app does not yet open it.
            guard !card.cannotBeSummonedNormally else {
                return .failure(.cannotBeSummonedNormally(card.name))
            }

            switch card.type {
            case .character, .exCharacter:
                guard side.characters.count < GameRules.maxCharacters else {
                    return .failure(.charactersRowFull)
                }
                if card.type == .exCharacter,
                   side.characters.filter(\.isEX).count >= GameRules.maxEXCharacters {
                    return .failure(.exCharacterAlreadyInPlay)
                }
            case .support:
                guard side.hasFreeSupportSlot else { return .failure(.supportRowFull) }
            case .summon:
                guard side.summon == nil else { return .failure(.summonZoneOccupied) }
            case .leader, .chakra:
                return .failure(.notPlayableFromHand(card.name))
            }
        }

        return .success(PlayPlan(handIndex: handIndex, card: card, asJutsu: asJutsu, cost: cost))
    }

    /// A validated ability activation, ready for the engine to commit.
    struct ResolvedAbility {
        let source: AbilitySource
        let abilityIndex: Int
        let ability: CardAbility
        let card: Card
        let controller: PlayerSlot
        let targetID: UUID?

        /// The characters that will pay the cost's trash requirement, already
        /// checked to exist and to match the cost's trait and power filters.
        let sacrifices: [UUID]

        /// The key this activation occupies in the once-per-turn set.
        var use: AbilityUse { AbilityUse(source: source, abilityIndex: abilityIndex) }
    }

    /// Validates an activation of one printed ability box, returning everything
    /// the engine needs to commit it.
    ///
    /// Shared by `apply`, `canUseAbility` and `legalAbilities`, so a button can
    /// never be offered for an activation the engine would then refuse. The
    /// checks run in the order a player would ask them: is the game live, is it
    /// my moment, is the card here, have I already used it, can I pay, is the
    /// target legal.
    func planAbility(
        source: AbilitySource,
        abilityIndex: Int,
        targetID: UUID?,
        by slot: PlayerSlot
    ) -> Result<ResolvedAbility, GameError> {
        guard !state.isFinished else { return .failure(.gameOver) }

        // The card has to still be on the board, and on this player's side.
        guard let card = abilityCard(for: source, by: slot) else {
            return .failure(.abilitySourceNotInPlay)
        }
        guard card.abilities.indices.contains(abilityIndex) else {
            return .failure(.noSuchAbility(card.name))
        }
        let ability = card.abilities[abilityIndex]

        // The trigger decides the moment — and, for a response, who is acting.
        switch ability.trigger {
        case .activateMain, .duringYourMain:
            guard slot == state.current else { return .failure(.notYourTurn) }
            guard state.phase == .main else { return .failure(.wrongPhase(state.phase)) }
            guard state.pendingAttack == nil else { return .failure(.attackAlreadyPending) }

        case .opponentsAttack:
            // The one activation that belongs to the player who is not on turn.
            guard let pending = state.pendingAttack else { return .failure(.noAttackPending) }
            guard slot == pending.defendingSlot else { return .failure(.notYourTurn) }

        case .passive, .yourTurn, .onSummon, .whenAttacking,
             .recovery, .summonRequirement, .support:
            return .failure(.abilityNotActivated(card.name))
        }

        // "Once Per Turn" is tracked per box, not per player.
        let use = AbilityUse(source: source, abilityIndex: abilityIndex)
        if ability.oncePerTurn, state[slot].hasUsed(use) {
            return .failure(.abilityAlreadyUsed(card.name))
        }

        // The cost, in the two currencies a box can ask for.
        let available = state[slot].readyChakra
        guard available >= ability.cost.chakra else {
            return .failure(.notEnoughChakra(required: ability.cost.chakra, available: available))
        }
        let sacrifices = AbilityResolver.sacrifices(
            for: ability.cost,
            controller: slot,
            in: state,
            database: database
        )
        guard sacrifices.count >= ability.cost.trashOwnCharacters else {
            return .failure(.notEnoughCharactersToTrash(
                required: ability.cost.trashOwnCharacters,
                available: sacrifices.count
            ))
        }

        // The target, when the scope asks the player for one.
        if ability.target.needsPlayerChoice {
            let candidates = AbilityResolver.candidates(
                for: ability.target,
                controller: slot,
                in: state
            )
            guard let targetID, candidates.contains(where: { $0.id == targetID }) else {
                return .failure(.abilityNeedsTarget)
            }
        }

        return .success(ResolvedAbility(
            source: source,
            abilityIndex: abilityIndex,
            ability: ability,
            card: card,
            controller: slot,
            targetID: ability.target.needsPlayerChoice ? targetID : nil,
            sacrifices: sacrifices
        ))
    }

    /// Every activation `slot` may make right now, one action per legal target.
    ///
    /// Replaces the Leader-only list: the Leader is simply the first source
    /// considered, and every body in the Characters row is considered after it.
    /// `legalActions(for:)` folds this in, so the board and the AI are always
    /// looking at the same set.
    func legalAbilities(for slot: PlayerSlot) -> [GameAction] {
        guard !state.isFinished else { return [] }

        var sources: [AbilitySource] = [.leader]
        sources.append(contentsOf: state[slot].characters.map { AbilitySource.character($0.id) })

        var actions: [GameAction] = []
        for source in sources {
            guard let card = abilityCard(for: source, by: slot) else { continue }

            for index in card.abilities.indices where card.abilities[index].isActivated {
                let scope = card.abilities[index].target

                guard scope.needsPlayerChoice else {
                    if planAbility(source: source, abilityIndex: index, targetID: nil, by: slot).isSuccess {
                        actions.append(.useAbility(source: source, abilityIndex: index, targetID: nil))
                    }
                    continue
                }

                for candidate in AbilityResolver.candidates(for: scope, controller: slot, in: state)
                where planAbility(source: source, abilityIndex: index, targetID: candidate.id, by: slot).isSuccess {
                    actions.append(.useAbility(source: source, abilityIndex: index, targetID: candidate.id))
                }
            }
        }
        return actions
    }

    /// Validates that a character may declare an attack this turn.
    func validateAttacker(_ characterID: UUID, by slot: PlayerSlot) -> Result<CharacterInPlay, GameError> {
        guard !state.isFinished else { return .failure(.gameOver) }
        guard slot == state.current else { return .failure(.notYourTurn) }
        guard state.phase == .attack else { return .failure(.wrongPhase(state.phase)) }
        guard state.pendingAttack == nil else { return .failure(.attackAlreadyPending) }
        guard let attacker = state[slot].character(id: characterID), attacker.canAttack else {
            return .failure(.attackerUnavailable)
        }
        return .success(attacker)
    }
}

// MARK: - Legal actions

extension GameEngine {

    /// Everything `slot` may legally do right now, in a stable order. Returns an
    /// empty list once the game is decided. The board and an AI both read from
    /// this, so neither can invent a move the other cannot see.
    func legalActions(for slot: PlayerSlot) -> [GameAction] {
        guard !state.isFinished else { return [] }

        if state.isAwaitingMulligan {
            guard state.needsMulligan(slot) else { return [] }
            return [.mulligan(false), .mulligan(true), .concede]
        }

        if let pending = state.pendingAttack {
            guard slot == pending.defendingSlot else { return [.concede] }
            var blocks: [GameAction] = [.declareBlock(blockerID: nil)]
            blocks.append(contentsOf: state[slot].readyCharacters.map { GameAction.declareBlock(blockerID: $0.id) })
            // A declared attack is the window "During Your Opponent's Attack"
            // abilities open in, so the defender's activations belong here too.
            blocks.append(contentsOf: legalAbilities(for: slot))
            blocks.append(.concede)
            return blocks
        }

        guard slot == state.current else { return [.concede] }

        var actions: [GameAction] = []
        switch state.phase {
        case .main:
            for index in state[slot].hand.indices {
                if planPlay(handIndex: index, asJutsu: false, by: slot).isSuccess {
                    actions.append(.playCard(handIndex: index, asJutsu: false))
                }
                if planPlay(handIndex: index, asJutsu: true, by: slot).isSuccess {
                    actions.append(.playCard(handIndex: index, asJutsu: true))
                }
            }
            actions.append(contentsOf: legalAbilities(for: slot))
            actions.append(.endPhase)
            actions.append(.endTurn)

        case .attack:
            let defenders = state[slot.opposing].characters
            for attacker in state[slot].attackers {
                actions.append(.attack(attackerID: attacker.id, target: .leader))
                for defender in defenders {
                    actions.append(.attack(attackerID: attacker.id, target: .character(defender.id)))
                }
            }
            actions.append(.endPhase)
            actions.append(.endTurn)

        case .end:
            actions.append(.endTurn)

        case .refresh, .draw:
            break   // These resolve automatically; there is nothing to choose.
        }

        actions.append(.concede)
        return actions
    }
}

// MARK: - Result convenience

private extension Result {
    /// Lets validation be reused as a predicate without unwrapping.
    var isSuccess: Bool {
        if case .success = self { return true }
        return false
    }
}
