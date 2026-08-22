//
//  GameEngine+Setup.swift
//  NTCGSimulator
//
//  Everything that builds a game or answers questions about one: deck
//  resolution and the opening deal, card lookups, and the validation behind
//  `legalActions(for:)`. Nothing in this file mutates the board — the rules
//  that do live in GameEngine.swift.
//
//  The validation here is written to be asked the same question twice: once by
//  the board, to decide whether to offer a button and what to print on it when
//  it is refused, and once by `apply`, to decide whether to accept the tap.
//  That is why every refusal is a `GameError` carrying the reference's own
//  block code rather than a bare `false`.
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
    /// Chakra placed face-up, the first player decided by the seeded coin
    /// toss, and the mulligan waiting on the player going second — the first
    /// player never gets the option.
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
            turnNumber: 1,
            phase: .refresh,
            step: .normal,
            awaitingMulligan: first.opposing,
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

/// One of the three things a card in hand can be used for, and whether it can
/// be used for it right now — the action panel in data. The board draws
/// exactly what is here, so a button can never promise something
/// `GameEngine.apply` would then refuse.
struct PlayOption: Identifiable, Hashable {

    let mode: CardPlayMode

    /// The button's words, with the card's own jutsu name folded in.
    let title: String

    /// Chakra the play charges. Zero for a summon and for setting a Support.
    let cost: Int

    /// Why the option is refused, in the engine's own words. `nil` when it is
    /// on offer.
    let refusal: String?

    var id: String { mode.rawValue }

    var isAllowed: Bool { refusal == nil }
}

/// A card in hand paired with the index the play actions expect, plus the
/// three modes it could be used in. Saves every hand view recomputing them.
struct HandCard: Identifiable, Hashable {

    /// The hand index — stable for as long as the card stays in hand.
    let id: Int

    let card: Card

    /// SUMMON, SET AS SUPPORT and ACTIVATE SUPPORT, in that order.
    let options: [PlayOption]

    /// Whether any of the three is on offer.
    var isPlayable: Bool { options.contains(where: \.isAllowed) }

    /// The modes actually available, for a board that only wants those.
    var allowedOptions: [PlayOption] { options.filter(\.isAllowed) }

    func option(for mode: CardPlayMode) -> PlayOption? {
        options.first { $0.mode == mode }
    }
}

/// A face-down Support a player could activate, resolved back to the printed
/// card and the box inside its SUPPORT bar.
struct FaceDownSupport: Identifiable, Hashable {

    /// Position in `PlayerSide.supports`, and the number the journal prints.
    let slotIndex: Int

    let placed: PlacedSupport

    /// The printed card lying face-down there.
    let card: Card

    /// The box inside the SUPPORT bar, and its position in the printed order.
    let abilityIndex: Int
    let ability: CardAbility

    var id: Int { slotIndex }

    /// The chakra printed on the left of the SUPPORT bar — what activating
    /// this card costs.
    var chakraCost: Int { ability.cost.chakra }

    /// The number a player reads on the mat, which is one-based.
    var slotNumber: Int { slotIndex + 1 }
}

// MARK: - Lookups

extension GameEngine {

    func side(_ slot: PlayerSlot) -> PlayerSide { state[slot] }

    /// The printed card behind a collector number, if the pool still has it.
    func card(for cardID: String) -> Card? { database.card(id: cardID) }

    func card(for character: CharacterInPlay) -> Card? { database.card(id: character.cardID) }

    func card(for chakra: ChakraCard) -> Card? { database.card(id: chakra.cardID) }

    func card(for placed: PlacedSupport) -> Card? { database.card(id: placed.cardID) }

    func leaderCard(for slot: PlayerSlot) -> Card? { database.card(id: state[slot].leaderCardID) }

    func cards(_ cardIDs: [String]) -> [Card] { database.cards(ids: cardIDs) }

    /// Finds a character on either board, with the side that owns it.
    func locateCharacter(id: UUID) -> (slot: PlayerSlot, character: CharacterInPlay)? {
        state.locateCharacter(id: id)
    }

    /// The hand, index-aligned with the play actions.
    func handCards(for slot: PlayerSlot) -> [HandCard] {
        state[slot].hand.enumerated().compactMap { (index, cardID) -> HandCard? in
            guard let card = database.card(id: cardID) else { return nil }
            return HandCard(id: index, card: card, options: playOptions(handIndex: index, by: slot))
        }
    }

    /// The action panel for one card in hand: SUMMON, SET AS SUPPORT and
    /// ACTIVATE SUPPORT, each on offer or carrying its refusal.
    func playOptions(handIndex: Int, by slot: PlayerSlot) -> [PlayOption] {
        guard state[slot].hand.indices.contains(handIndex),
              let card = database.card(id: state[slot].hand[handIndex]) else { return [] }

        return CardPlayMode.allCases.map { mode in
            let refusal: GameError?
            switch mode {
            case .summon:       refusal = summonBlock(handIndex: handIndex, by: slot)
            case .setAsSupport: refusal = setSupportBlock(handIndex: handIndex, by: slot)
            case .jutsu:        refusal = handActivationBlock(handIndex: handIndex, by: slot)
            }
            let title: String
            switch mode {
            case .summon:       title = "Summon"
            case .setAsSupport: title = "Set as support"
            case .jutsu:        title = "Activate \(card.jutsuName)"
            }
            return PlayOption(
                mode: mode,
                title: title,
                cost: mode == .jutsu ? (card.supportBarAbility?.ability.cost.chakra ?? 0) : 0,
                refusal: refusal?.message
            )
        }
    }

    /// The face-down cards `slot` could activate, resolved back to the
    /// printed card and the box inside its SUPPORT bar.
    func faceDownSupports(for slot: PlayerSlot) -> [FaceDownSupport] {
        state[slot].faceDownSupports.compactMap { entry in
            guard let card = database.card(id: entry.placed.cardID),
                  let bar = card.supportBarAbility else { return nil }
            return FaceDownSupport(
                slotIndex: entry.slotIndex,
                placed: entry.placed,
                card: card,
                abilityIndex: bar.index,
                ability: bar.ability
            )
        }
    }

    /// Chakra a side can still spend.
    func availableChakra(for slot: PlayerSlot) -> Int { state[slot].faceUpChakra }

    /// Whether `slot` has already taken the turn's one normal summon.
    func hasSummonedThisTurn(_ slot: PlayerSlot) -> Bool {
        state[slot].summonsUsedThisTurn >= GameRules.normalSummonsPerTurn
    }

    /// How many cards the draw step takes at the start of a turn: one on the
    /// game's opening turn, two ever after — so the second player draws two
    /// on their own first turn.
    func drawCount(forTurn turn: Int) -> Int {
        turn == 1 ? GameRules.firstTurnDraw : GameRules.normalDraw
    }
}

// MARK: - Validation

extension GameEngine {

    /// The gate on every proactive main-phase action: your turn, main phase,
    /// no window, no pending attack.
    func mainPhaseBlock(for slot: PlayerSlot) -> GameError? {
        guard state.awaitingMulligan == nil else { return .awaitingMulligan }
        guard slot == state.current else { return .notYourTurn }
        guard state.phase == .main, state.step == .normal, state.pendingAttack == nil else {
            return .wrongMoment
        }
        return nil
    }

    /// Whether the card at `handIndex` could be summoned right now.
    func summonBlock(handIndex: Int, by slot: PlayerSlot) -> GameError? {
        if let block = mainPhaseBlock(for: slot) { return block }
        guard state[slot].hand.indices.contains(handIndex) else { return .invalidHandIndex }
        let cardID = state[slot].hand[handIndex]
        guard let card = database.card(id: cardID) else { return .unknownCard(cardID) }

        switch card.type {
        case .leader, .chakra, .summon:
            return .notPlayableFromHand(card.name)
        case .exCharacter:
            return exSummonBlock(card: card, by: slot)
        case .character:
            if card.cannotBeSummonedNormally {
                guard card.summonRequirement != nil else { return .summonRequirementUnpaid(card.name) }
                return exSummonBlock(card: card, by: slot)
            }
            guard state[slot].summonsUsedThisTurn < GameRules.normalSummonsPerTurn else {
                return .summonAlreadyUsed
            }
            return nil
        }
    }

    /// Whether the printed Summon Requirements can be paid: some assignment
    /// of distinct on-field characters must satisfy every slot at once.
    private func exSummonBlock(card: Card, by slot: PlayerSlot) -> GameError? {
        guard let requirement = card.summonRequirement,
              !requirement.ability.cost.trashRequirements.isEmpty else {
            return .summonRequirementUnpaid(card.name)
        }
        let candidates = resolver.requirementCandidates(for: slot, in: state)
        guard AbilityResolver.assignmentExists(
            slots: requirement.ability.cost.trashRequirements,
            candidates: candidates
        ) else {
            return .summonRequirementUnpaid(card.name)
        }
        return nil
    }

    /// Whether the card at `handIndex` could be set face-down right now.
    func setSupportBlock(handIndex: Int, by slot: PlayerSlot) -> GameError? {
        if let block = mainPhaseBlock(for: slot) { return block }
        guard state[slot].hand.indices.contains(handIndex) else { return .invalidHandIndex }
        let cardID = state[slot].hand[handIndex]
        guard let card = database.card(id: cardID) else { return .unknownCard(cardID) }
        guard card.supportBarAbility != nil else { return .conditionUnmet }
        guard state[slot].hasFreeSupportSlot else { return .noSlot }
        return nil
    }

    /// The timing gate every Support activation passes through, mirroring the
    /// reference's classifier: the timing class decides which windows admit
    /// the card, and a counter step additionally demands priority.
    ///
    /// - Parameter assumingPriority: skip the priority check — used when
    ///   asking "could this player respond if we handed them the window".
    func supportTimingBlock(
        for ability: CardAbility,
        by slot: PlayerSlot,
        assumingPriority: Bool = false
    ) -> GameError? {
        guard state.awaitingMulligan == nil else { return .awaitingMulligan }
        guard ability.trigger.isSupportTiming else { return .conditionUnmet }

        let mainLegal = state.pendingAttack == nil
            && slot == state.current
            && state.phase == .main
        let windowOpen = state.step == .counter || !state.chain.isEmpty

        switch ability.trigger.timingClass {
        case .main:
            guard mainLegal else { return .wrongMoment }
        case .quick:
            guard mainLegal || windowOpen else { return .wrongMoment }
        case .counter:
            guard let attack = state.pendingAttack,
                  state.step == .counter,
                  slot == attack.defendingSlot else { return .wrongMoment }
        case .response:
            guard !state.chain.isEmpty else { return .wrongMoment }
        case .none:
            return .conditionUnmet
        }

        if state.step == .counter, !assumingPriority {
            guard state.priority == slot else { return .wrongMoment }
        }

        guard state[slot].faceUpChakra >= ability.cost.chakra else {
            return .noChakra(required: ability.cost.chakra, available: state[slot].faceUpChakra)
        }

        // A mandatory choose clause with nothing on the board to choose
        // blocks the activation outright. Immunity is ignored at this stage.
        if let lock = ability.targetLock, lock.isMandatory {
            let candidates = resolver.characterOptions(
                restedOnly: lock.restedOnly,
                nonEXOnly: lock.nonEXOnly,
                excluding: [],
                immuneAgainst: nil,
                in: state
            )
            guard !candidates.isEmpty else { return .noValidTarget }
        }
        return nil
    }

    /// Whether the face-down card in `slotIndex` could be activated now.
    func slotActivationBlock(slotIndex: Int, by slot: PlayerSlot) -> GameError? {
        guard state[slot].supports.indices.contains(slotIndex),
              let placed = state[slot].supports[slotIndex] else {
            return .supportSlotEmpty(slotIndex)
        }
        guard !placed.isRevealed else { return .alreadyUsed }
        guard let card = database.card(id: placed.cardID),
              let bar = card.supportBarAbility else { return .conditionUnmet }
        return supportTimingBlock(for: bar.ability, by: slot)
    }

    /// Whether the card at `handIndex` could be activated from hand now:
    /// the timing gate, plus being the active player, plus a free slot for
    /// the card to transit through.
    func handActivationBlock(handIndex: Int, by slot: PlayerSlot) -> GameError? {
        guard state[slot].hand.indices.contains(handIndex) else { return .invalidHandIndex }
        let cardID = state[slot].hand[handIndex]
        guard let card = database.card(id: cardID) else { return .unknownCard(cardID) }
        guard let bar = card.supportBarAbility else { return .conditionUnmet }
        if let block = supportTimingBlock(for: bar.ability, by: slot) { return block }
        guard slot == state.current else { return .wrongMoment }
        guard state[slot].hasFreeSupportSlot else { return .noSlot }
        return nil
    }

    /// Whether a character's Activate: Main could be used right now — the
    /// reference's `characterAbilityBlock`, generalised off the printed box.
    func characterAbilityBlock(_ characterID: UUID, by slot: PlayerSlot) -> GameError? {
        if let block = mainPhaseBlock(for: slot) { return block }
        guard let character = state[slot].character(id: characterID),
              let card = database.card(id: character.cardID) else { return .invalidTarget }
        guard let index = card.abilities.firstIndex(where: { $0.trigger == .activateMain }) else {
            return .conditionUnmet
        }
        let box = card.abilities[index]
        guard !character.effectsNegated else { return .conditionUnmet }
        if box.oncePerTurn, character.activatedThisTurn { return .alreadyUsed }

        // A team boost needs its named teammates on the field.
        for effect in box.effects {
            if case .teamBoost(let requires, _, _, _) = effect {
                let fieldNames = Set(state[slot].characters.compactMap {
                    database.card(id: $0.cardID)?.name
                })
                guard requires.allSatisfy(fieldNames.contains) else { return .conditionUnmet }
            }
        }
        return nil
    }

    /// Whether the Leader's Activate: Main could be used right now.
    func leaderEffectBlock(for slot: PlayerSlot) -> GameError? {
        if let block = mainPhaseBlock(for: slot) { return block }
        guard let leader = database.card(id: state[slot].leaderCardID),
              let index = leader.abilities.firstIndex(where: { $0.trigger == .activateMain })
        else { return .conditionUnmet }
        let box = leader.abilities[index]

        if box.oncePerTurn, state[slot].leaderUsedThisTurn { return .alreadyUsed }
        guard state[slot].faceUpChakra >= box.cost.chakra else {
            return .noChakra(required: box.cost.chakra, available: state[slot].faceUpChakra)
        }
        // The targeted boost needs at least one character on either board.
        for effect in box.effects {
            if case .boostChosenPower = effect {
                let anyCharacter = !state.player.characters.isEmpty
                    || !state.opponent.characters.isEmpty
                guard anyCharacter else { return .noValidTarget }
            }
        }
        return nil
    }

    /// Whether the Recovery action is available: your turn, main phase, game
    /// turn 2 or later, a standing Leader, and no chakra lock.
    func recoveryBlock(for slot: PlayerSlot) -> GameError? {
        if let block = mainPhaseBlock(for: slot) { return block }
        guard state.turnNumber >= GameRules.recoveryFromTurn else { return .tooEarly }
        guard !state[slot].leaderRested else { return .rested }
        guard state.turnNumber >= state[slot].chakraLockedUntilTurn else { return .chakraLocked }
        return nil
    }

    /// Whether an attacker may declare at all: the gates in the reference's
    /// order — turn, step, first-turn bar, rest, spent attacks, freezes, and
    /// summoning sickness for a body without Rush.
    func attackBlock(attacker: AttackerReference, by slot: PlayerSlot) -> GameError? {
        if let block = mainPhaseBlock(for: slot) { return block }
        guard state.turnNumber > GameRules.noAttackOnTurn else { return .tooEarly }

        switch attacker {
        case .leader:
            guard !state[slot].leaderRested else { return .rested }
            guard state[slot].leaderAttacksUsed < GameRules.leaderAttacksPerTurn else {
                return .noAttackLeft
            }
            guard state.turnNumber > state[slot].leaderCannotAttackUntilTurn else { return .frozen }
            return nil

        case .character(let id):
            guard let character = state[slot].character(id: id),
                  let card = database.card(id: character.cardID) else { return .invalidTarget }
            guard !character.isRested else { return .rested }
            guard character.attacksUsed < GameRules.attacksPerCharacter else { return .noAttackLeft }
            guard state.turnNumber > character.cannotAttackUntilTurn else { return .frozen }
            if character.summonedOnTurn == state.turnNumber {
                guard character.hasRush(card: card, turn: state.turnNumber) else {
                    return .summoningSickness
                }
            }
            return nil
        }
    }

    /// Whether one specific attack declaration would be accepted.
    func canAttack(attacker: AttackerReference, target: AttackTarget, by slot: PlayerSlot) -> Bool {
        guard attackBlock(attacker: attacker, by: slot) == nil else { return false }
        switch target {
        case .leader:
            return true
        case .character(let targetID):
            return state[slot.opposing].character(id: targetID)?.isRested == true
        }
    }
}

// MARK: - Legal actions

extension GameEngine {

    /// Every activation `slot` could make into the open counter window. An
    /// empty list is exactly the condition auto-pass describes as "nothing to
    /// answer with".
    func legalCounterActivations(for slot: PlayerSlot) -> [GameAction] {
        guard !state.isFinished, state.step == .counter, state.priority == slot else { return [] }

        var actions: [GameAction] = []
        for entry in state[slot].faceDownSupports
        where slotActivationBlock(slotIndex: entry.slotIndex, by: slot) == nil {
            actions.append(.activateSupport(slotIndex: entry.slotIndex))
        }
        for index in state[slot].hand.indices
        where handActivationBlock(handIndex: index, by: slot) == nil {
            actions.append(.activateSupportFromHand(handIndex: index))
        }
        return actions
    }

    /// Everything `slot` may legally do right now, in a stable order. Returns
    /// an empty list once the game is decided. The board and an AI both read
    /// from this, so neither can invent a move the other cannot see.
    func legalActions(for slot: PlayerSlot) -> [GameAction] {
        guard !state.isFinished else { return [] }

        if let awaiting = state.awaitingMulligan {
            guard slot == awaiting else { return [.concede] }
            return [.mulligan(keep: true), .mulligan(keep: false), .concede]
        }

        if let choice = state.pendingChoice {
            guard slot == choice.player else { return [.concede] }
            var actions = choice.options.map { GameAction.resolveChoice(keys: [$0.key]) }
            if choice.cancellable {
                actions.append(.resolveChoice(keys: []))
            }
            actions.append(.concede)
            return actions
        }

        if state.step == .counter {
            guard slot == state.priority else { return [.concede] }
            return legalCounterActivations(for: slot) + [.passCounter, .concede]
        }

        guard slot == state.current, state.phase == .main else { return [.concede] }

        var actions: [GameAction] = []

        for index in state[slot].hand.indices {
            if summonBlock(handIndex: index, by: slot) == nil {
                actions.append(.summon(handIndex: index))
            }
            if setSupportBlock(handIndex: index, by: slot) == nil {
                actions.append(.setSupport(handIndex: index))
            }
            if handActivationBlock(handIndex: index, by: slot) == nil {
                actions.append(.activateSupportFromHand(handIndex: index))
            }
        }

        for entry in state[slot].faceDownSupports
        where slotActivationBlock(slotIndex: entry.slotIndex, by: slot) == nil {
            actions.append(.activateSupport(slotIndex: entry.slotIndex))
        }

        for character in state[slot].characters
        where characterAbilityBlock(character.id, by: slot) == nil {
            actions.append(.activateCharacter(character.id))
        }

        if leaderEffectBlock(for: slot) == nil {
            actions.append(.leaderEffect)
        }
        if recoveryBlock(for: slot) == nil {
            actions.append(.recovery)
        }

        let restedDefenders = state[slot.opposing].characters.filter(\.isRested)
        var attackers: [AttackerReference] = state[slot].characters.map { .character($0.id) }
        attackers.append(.leader)
        for attacker in attackers where attackBlock(attacker: attacker, by: slot) == nil {
            actions.append(.declareAttack(attacker: attacker, target: .leader))
            for defender in restedDefenders {
                actions.append(.declareAttack(attacker: attacker, target: .character(defender.id)))
            }
        }

        actions.append(.endTurn)
        actions.append(.concede)
        return actions
    }

    /// Whether the player still has something to do besides ending the turn —
    /// the question behind "End your turn? You still have actions available."
    func hasActionsRemaining(for slot: PlayerSlot) -> Bool {
        legalActions(for: slot).contains { action in
            switch action {
            case .endTurn, .concede: return false
            default:                 return true
            }
        }
    }
}
