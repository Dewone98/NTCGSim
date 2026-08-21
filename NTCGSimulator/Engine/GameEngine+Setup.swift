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

    /// Validates a Leader activation, returning the ability to resolve.
    ///
    /// Shared by `apply` and `legalActions`, so a Leader button can never be
    /// offered for an activation the engine would then refuse.
    func planLeaderAbility(targetID: UUID?, by slot: PlayerSlot) -> Result<LeaderAbility, GameError> {
        guard !state.isFinished else { return .failure(.gameOver) }
        guard slot == state.current else { return .failure(.notYourTurn) }
        guard state.phase == .main else { return .failure(.wrongPhase(state.phase)) }
        guard state.pendingAttack == nil else { return .failure(.attackAlreadyPending) }

        let side = state[slot]
        guard !side.hasUsedLeaderAbility else { return .failure(.leaderAbilityAlreadyUsed) }

        guard let leader = database.card(id: side.leaderCardID) else {
            return .failure(.unknownCard(side.leaderCardID))
        }
        guard let ability = leader.leaderAbility else {
            return .failure(.leaderHasNoAbility(leader.name))
        }

        if ability.needsFriendlyTarget {
            guard let targetID, side.character(id: targetID) != nil else {
                return .failure(.abilityNeedsTarget)
            }
        }
        if ability.needsEnemyTarget {
            guard let targetID, state[slot.opposing].character(id: targetID) != nil else {
                return .failure(.abilityNeedsTarget)
            }
        }

        return .success(ability)
    }

    /// Every Leader activation available right now: one action per legal
    /// target for a targeted ability, or a single untargeted action.
    func legalLeaderAbilities(for slot: PlayerSlot) -> [GameAction] {
        guard
            let leader = database.card(id: state[slot].leaderCardID),
            let ability = leader.leaderAbility
        else { return [] }

        guard ability.needsTarget else {
            return planLeaderAbility(targetID: nil, by: slot).isSuccess
                ? [.useLeaderAbility(targetID: nil)]
                : []
        }

        let candidates = ability.needsFriendlyTarget
            ? state[slot].characters
            : state[slot.opposing].characters

        return candidates
            .filter { planLeaderAbility(targetID: $0.id, by: slot).isSuccess }
            .map { .useLeaderAbility(targetID: $0.id) }
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
            actions.append(contentsOf: legalLeaderAbilities(for: slot))
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
