//
//  GameEngine.swift
//  NTCGSimulator
//
//  The rules, and the only code allowed to move a card. Every decision arrives
//  through `apply(_:by:)`, which validates before it mutates and journals what
//  it accepted. The questions — lookups, legality, legal actions — live in
//  GameEngine+Setup.swift. No SwiftUI, and no randomness beyond the seed.
//
//  The moving parts mirror the reference engine exactly. A turn opens with a
//  transient refresh and draw and rests in an undivided main phase. Attacks,
//  summons and Support activations open counter windows in which priority
//  bounces until two passes; activated Supports stack on a chain that then
//  resolves last-in-first-out. Prompts — target picks, hand picks, EX
//  payments — pause everything until answered, queueing first-in-first-out.
//  A central pump drives all of it, so every action handler only has to
//  change the board and let the pump carry the consequences.
//

import Foundation

@Observable
final class GameEngine {

    /// The board. Read it freely; only the engine writes to it.
    private(set) var state: GameState

    /// Human-readable record of the game so far.
    private(set) var journal: Journal

    /// The settings this game was started with.
    let configuration: GameConfiguration

    /// Seed the game was built from, so a game can be replayed or reported.
    let seed: UInt64

    /// Card lookups. The engine only ever reads from it.
    let database: CardDatabase

    /// What to do with a counter window whose priority holder cannot answer.
    ///
    /// Mirrors `SettingsStore.autoPass`, which the board keeps in step: "when
    /// you have nothing to answer with, pass for you instead of holding the
    /// window open". Held here rather than read from the store because the
    /// engine is deliberately free of SwiftUI and of app state.
    var autoPass: AutoPassMode

    /// The effect table. Stateless, so a fresh one per use is free.
    var resolver: AbilityResolver { AbilityResolver(database: database) }

    // MARK: Lifecycle

    /// Builds both sides from a configuration. Deck resolution never fails: a
    /// missing or illegal deck falls back to a generated legal one.
    init(
        configuration: GameConfiguration,
        database: CardDatabase,
        decks: DeckStore,
        seed: UInt64 = UInt64.random(in: UInt64.min...UInt64.max),
        autoPass: AutoPassMode = .holdWindow
    ) {
        self.configuration = configuration
        self.database = database
        self.seed = seed
        self.autoPass = autoPass
        self.journal = Journal()
        self.state = GameSetup.makeState(
            configuration: configuration,
            database: database,
            decks: decks,
            seed: seed
        )
        recordOpening()
    }

    private func recordOpening() {
        let opener = state.firstPlayer == .player ? "You go first." : "The opponent goes first."
        journal.system("\(configuration.format.title) game. \(opener)")
        if let second = state.awaitingMulligan {
            journal.system("\(second.title) may keep the opening hand or take one mulligan.")
        }
    }

    // MARK: Derived state

    var outcome: GameOutcome { state.outcome }
    var turnState: TurnState { state.turnState }
    var phase: GamePhase { state.phase }
    var step: GameStep { state.step }
    var currentPlayer: PlayerSlot { state.current }
    var turnNumber: Int { state.turnNumber }
    var pendingAttack: PendingAttack? { state.pendingAttack }
    var pendingChoice: PendingChoice? { state.pendingChoice }
    var responseWindow: ResponseWindow? { state.responseWindow }
    var isAwaitingMulligan: Bool { state.awaitingMulligan != nil }
    var isFinished: Bool { state.isFinished }

    /// Who the game is waiting on right now.
    var decider: PlayerSlot? { state.decider }

    /// The side that owes an answer to an open counter window.
    var respondingPlayer: PlayerSlot? { state.responseWindow?.respondingSlot }

    // MARK: Apply

    /// The single door into the rules. Validates first, mutates second, and
    /// journals whatever it accepted. After every accepted action the pump
    /// runs whatever the board now owes: auto-resolving prompts, resolving
    /// the chain, opening owed windows.
    @discardableResult
    func apply(_ action: GameAction, by slot: PlayerSlot) -> Result<Void, GameError> {
        guard !state.isFinished else { return .failure(.gameOver) }

        // Conceding is an app affordance, allowed at any moment.
        if case .concede = action {
            journal.record(actor: slot.title, message: "Conceded the game.")
            finish(winner: slot.opposing, reason: .concession)
            return .success(())
        }

        // An open prompt blocks everything but its own answer.
        if state.pendingChoice != nil {
            guard case .resolveChoice = action else { return .failure(.choicePending) }
        }

        // The opening mulligan blocks everything but itself.
        if let awaiting = state.awaitingMulligan {
            guard case .mulligan = action else { return .failure(.awaitingMulligan) }
            guard slot == awaiting else { return .failure(.mulliganUnavailable) }
        } else if case .mulligan = action {
            return .failure(.mulliganUnavailable)
        }

        let result: Result<Void, GameError>
        switch action {
        case .mulligan(let keep):
            result = resolveMulligan(keep: keep, by: slot)
        case .summon(let handIndex):
            result = summon(handIndex: handIndex, by: slot)
        case .setSupport(let handIndex):
            result = setSupport(handIndex: handIndex, by: slot)
        case .activateSupport(let slotIndex):
            result = activateSupport(slotIndex: slotIndex, by: slot)
        case .activateSupportFromHand(let handIndex):
            result = activateSupportFromHand(handIndex: handIndex, by: slot)
        case .activateCharacter(let characterID):
            result = activateCharacter(characterID, by: slot)
        case .leaderEffect:
            result = useLeaderEffect(by: slot)
        case .recovery:
            result = recover(by: slot)
        case .declareAttack(let attacker, let target):
            result = declareAttack(attacker: attacker, target: target, by: slot)
        case .passCounter:
            result = passCounter(by: slot)
        case .resolveChoice(let keys):
            result = resolveChoice(keys: keys, by: slot)
        case .endTurn:
            result = endTurn(by: slot)
        case .concede:
            result = .success(())
        }

        if case .success = result {
            pump()
            runAutoPassIfNeeded()
        }
        return result
    }

    // MARK: - The pump

    /// Carries the board through everything it owes with nobody to ask:
    /// promotes and auto-resolves prompts, finishes a paused resolution,
    /// resolves the chain when nobody holds priority, and opens an owed
    /// summon window. Stops the moment a player is actually needed.
    private func pump() {
        var safety = 0
        while !state.isFinished, safety < 10_000 {
            safety += 1

            // Prompts come first: skip empties, auto-resolve forced answers,
            // and wait on real questions.
            if let choice = state.pendingChoice {
                if choice.options.isEmpty {
                    state.pendingChoice = nil
                    continue
                }
                if choice.resolvesAutomatically {
                    performChoice(choice, chosen: [choice.options[0]])
                    state.pendingChoice = nil
                    continue
                }
                return
            }
            if !state.queuedChoices.isEmpty {
                state.pendingChoice = state.queuedChoices.removeFirst()
                continue
            }

            // A link paused on its prompts finishes disposing now.
            if state.resolvingSupport != nil {
                finishResolvingLink()
                continue
            }

            // A counter step with nobody holding priority is the chain
            // resolving — or, once it empties, the window closing.
            if state.step == .counter, state.priority == nil {
                if state.chain.isEmpty {
                    finishChain()
                } else {
                    resolveTopLink()
                }
                continue
            }

            // A summon window deferred behind prompts opens now.
            if let owed = state.owedSummonWindow {
                state.owedSummonWindow = nil
                openSummonWindow(for: owed)
                continue
            }
            return
        }
    }

    // MARK: - Mulligan

    /// The second player's one all-or-nothing redraw. Turn one begins the
    /// moment they answer; the first player never gets the option.
    private func resolveMulligan(keep: Bool, by slot: PlayerSlot) -> Result<Void, GameError> {
        if keep {
            journal.record(actor: slot.title, message: "Kept the opening hand.")
        } else {
            // The whole hand goes on top, the whole deck reshuffles, and a
            // fresh five is drawn — all-or-nothing, exactly once.
            var side = state[slot]
            side.deck.insert(contentsOf: side.hand, at: 0)
            side.hand.removeAll()
            side.deck.shuffle(using: &state.rng)
            let dealt = min(GameRules.openingHandSize, side.deck.count)
            side.hand = Array(side.deck.prefix(dealt))
            side.deck.removeFirst(dealt)
            state[slot] = side
            journal.record(actor: slot.title, message: "Took a mulligan and drew a new hand.")
        }
        state[slot].mulliganDone = true
        state.awaitingMulligan = nil
        beginTurn(for: state.firstPlayer, turn: 1)
        return .success(())
    }

    // MARK: - Turns

    /// Refresh and Draw run back to back with nobody to ask, and the turn
    /// then rests in its undivided main phase. Chakra is deliberately not
    /// flipped here — only the Recovery action does that.
    private func beginTurn(for slot: PlayerSlot, turn: Int) {
        state.current = slot
        state.turnNumber = turn
        state.phase = .refresh
        journal.system("Turn \(turn) — \(slot.title).")

        state[slot].beginTurn()

        state.phase = .draw
        drawCards(drawCount(forTurn: turn), for: slot)
        guard !state.isFinished else { return }

        state.phase = .main
    }

    /// END TURN. Battle damage and stat bonuses wipe from BOTH boards; the
    /// turn-stamped durations expire by comparison instead.
    private func endTurn(by slot: PlayerSlot) -> Result<Void, GameError> {
        guard slot == state.current else { return .failure(.notYourTurn) }
        guard state.step == .normal, state.pendingAttack == nil, state.phase == .main else {
            return .failure(.wrongMoment)
        }

        state.player.wipeEndOfTurn()
        state.opponent.wipeEndOfTurn()
        journal.record(actor: slot.title, message: "Ends the turn.")

        beginTurn(for: slot.opposing, turn: state.turnNumber + 1)
        return .success(())
    }

    /// Draws cards one at a time. Drawing from an empty deck loses the game.
    private func drawCards(_ count: Int, for slot: PlayerSlot) {
        guard count > 0 else { return }
        var drawn = 0
        for _ in 0..<count {
            guard !state.isFinished else { return }
            guard !state[slot].deck.isEmpty else {
                journal.system("\(slot.title) could not draw from an empty deck.")
                finish(winner: slot.opposing, reason: .deckOut)
                return
            }
            state[slot].hand.append(state[slot].deck.removeFirst())
            drawn += 1
        }
        journal.record(
            actor: slot.title,
            message: "Draws \(drawn), hand \(state[slot].hand.count), deck \(state[slot].deck.count)."
        )
    }

    // MARK: - Recovery

    /// Rest the Leader, flip every chakra face-up. Implicitly once per turn —
    /// the rested Leader blocks a second use — and mutually exclusive with a
    /// Leader attack in either order.
    private func recover(by slot: PlayerSlot) -> Result<Void, GameError> {
        if let block = recoveryBlock(for: slot) { return .failure(block) }
        state[slot].leaderRested = true
        let flipped = state[slot].flipAllChakraFaceUp()
        journal.record(
            actor: slot.title,
            message: "Recovery — rests the Leader and turns \(flipped) chakra face-up."
        )
        return .success(())
    }

    // MARK: - Summons

    /// SUMMON: a character through the turn's one normal summon, or an EX
    /// Character through its printed Summon Requirements.
    private func summon(handIndex: Int, by slot: PlayerSlot) -> Result<Void, GameError> {
        if let block = mainPhaseBlock(for: slot) { return .failure(block) }
        guard state[slot].hand.indices.contains(handIndex) else { return .failure(.invalidHandIndex) }
        let cardID = state[slot].hand[handIndex]
        guard let card = database.card(id: cardID) else { return .failure(.unknownCard(cardID)) }

        switch card.type {
        case .leader, .chakra, .summon:
            return .failure(.notPlayableFromHand(card.name))

        case .exCharacter:
            return startEXSummon(handIndex: handIndex, card: card, by: slot)

        case .character:
            if card.cannotBeSummonedNormally {
                guard card.summonRequirement != nil else {
                    return .failure(.summonRequirementUnpaid(card.name))
                }
                return startEXSummon(handIndex: handIndex, card: card, by: slot)
            }
            guard state[slot].summonsUsedThisTurn < GameRules.normalSummonsPerTurn else {
                return .failure(.summonAlreadyUsed)
            }
            state[slot].summonsUsedThisTurn += 1
            state[slot].summonRested = true
            commitSummon(handIndex: handIndex, card: card, by: slot)
            return .success(())
        }
    }

    /// Moves the card from hand to the board, fires its On Summon boxes and
    /// owes the summon window — deferred while those boxes ask questions.
    private func commitSummon(handIndex: Int, card: Card, by slot: PlayerSlot) {
        state[slot].hand.remove(at: handIndex)
        let characterID = resolver.placeCharacter(cardID: card.id, for: slot, in: &state)
        journal.record(actor: slot.title, message: "Summons \(card.name).")
        runOnSummon(characterID, for: slot)
        checkDeaths()
        guard !state.isFinished else { return }
        state.owedSummonWindow = slot
    }

    /// Begins the EX path: verifies an assignment of distinct characters to
    /// every requirement slot exists, then asks for the payments one slot at
    /// a time — forced picks answer themselves through the prompt machinery.
    private func startEXSummon(handIndex: Int, card: Card, by slot: PlayerSlot) -> Result<Void, GameError> {
        guard let requirement = card.summonRequirement,
              !requirement.ability.cost.trashRequirements.isEmpty else {
            // An EX card whose text yields zero requirements cannot be
            // summoned at all — the reference refuses it explicitly.
            return .failure(.summonRequirementUnpaid(card.name))
        }
        let slots = requirement.ability.cost.trashRequirements
        let candidates = resolver.requirementCandidates(for: slot, in: state)
        guard AbilityResolver.assignmentExists(slots: slots, candidates: candidates) else {
            return .failure(.summonRequirementUnpaid(card.name))
        }
        raiseEXRequirement(handIndex: handIndex, card: card, by: slot, remaining: slots, paid: [])
        return .success(())
    }

    /// One requirement slot's payment prompt. Candidates are filtered so
    /// every offer keeps a full assignment feasible.
    private func raiseEXRequirement(
        handIndex: Int,
        card: Card,
        by slot: PlayerSlot,
        remaining: [TrashRequirement],
        paid: [UUID]
    ) {
        guard let nextSlot = remaining.first else {
            commitEXSummon(handIndex: handIndex, card: card, by: slot, paying: paid)
            return
        }
        let rest = Array(remaining.dropFirst())
        let candidates = resolver.requirementCandidates(for: slot, in: state)
            .filter { !paid.contains($0.id) }
        let eligible = candidates.filter { candidate in
            nextSlot.isSatisfied(byTraits: candidate.traits, effectivePower: candidate.power)
                && AbilityResolver.assignmentExists(
                    slots: rest,
                    candidates: candidates.filter { $0.id != candidate.id }
                )
        }

        var data = ChoiceData()
        data.sourceCardID = card.id
        data.pendingSummonHandIndex = handIndex
        data.requirementSlots = rest
        data.paidCharacterIDs = paid

        enqueueChoice(PendingChoice(
            id: state.makeIdentifier(),
            kind: .exRequirement,
            player: slot,
            prompt: "Choose \(nextSlot.summary) to place in your trash for \(card.name)",
            options: eligible.map { candidate in
                ChoiceOption(
                    key: "char-\(candidate.id.uuidString)",
                    target: .character(candidate.id),
                    title: state[slot].character(id: candidate.id).map(resolver.characterName) ?? "Character"
                )
            },
            cancellable: false,
            data: data
        ))
    }

    /// Every slot is paid: the characters go to the trash, the EX card
    /// arrives, and the summon window is owed. EX summons cost no chakra and
    /// never touch the normal summon.
    private func commitEXSummon(handIndex: Int, card: Card, by slot: PlayerSlot, paying paid: [UUID]) {
        guard state[slot].hand.indices.contains(handIndex),
              state[slot].hand[handIndex] == card.id else { return }

        for characterID in paid {
            guard let trashedID = state[slot].sendCharacterToTrash(id: characterID) else { continue }
            let name = database.card(id: trashedID)?.name ?? trashedID
            journal.record(actor: slot.title, message: "Places \(name) in the trash to pay the Summon Requirements.")
        }
        commitSummon(handIndex: handIndex, card: card, by: slot)
    }

    /// Fires every On Summon box on a freshly placed body, cascading through
    /// any bodies those boxes place in turn. Negated effects never fire.
    private func runOnSummon(_ characterID: UUID, for slot: PlayerSlot) {
        guard !state.isFinished else { return }
        guard let character = state[slot].character(id: characterID),
              !character.effectsNegated,
              let card = database.card(id: character.cardID) else { return }

        for ability in card.abilities where ability.trigger == .onSummon {
            guard !state.isFinished, state[slot].character(id: characterID) != nil else { return }
            let result = resolver.runEffects(
                ability,
                source: EffectSource(card: card, controller: slot),
                in: &state
            )
            absorb(result, activator: slot)
        }
    }

    // MARK: - Setting and activating Supports

    /// SET SUPPORT: face-down into the first free numbered slot. Free,
    /// uncapped, and it opens no window — the chakra is paid on activation.
    private func setSupport(handIndex: Int, by slot: PlayerSlot) -> Result<Void, GameError> {
        if let block = mainPhaseBlock(for: slot) { return .failure(block) }
        guard state[slot].hand.indices.contains(handIndex) else { return .failure(.invalidHandIndex) }
        let cardID = state[slot].hand[handIndex]
        guard let card = database.card(id: cardID) else { return .failure(.unknownCard(cardID)) }
        guard card.supportBarAbility != nil else { return .failure(.conditionUnmet) }
        guard state[slot].hasFreeSupportSlot else { return .failure(.noSlot) }

        state[slot].hand.remove(at: handIndex)
        let placed = PlacedSupport(id: state.makeIdentifier(), cardID: card.id)
        guard let number = state[slot].setSupport(placed) else { return .failure(.noSlot) }
        journal.record(actor: slot.title, message: "Sets a card face-down in support slot \(number).")
        return .success(())
    }

    /// Activates the face-down card in a numbered slot: pays its chakra,
    /// reveals it, and pushes it onto the chain.
    private func activateSupport(slotIndex: Int, by slot: PlayerSlot) -> Result<Void, GameError> {
        guard state[slot].supports.indices.contains(slotIndex),
              let placed = state[slot].supports[slotIndex] else {
            return .failure(.supportSlotEmpty(slotIndex))
        }
        guard !placed.isRevealed else { return .failure(.alreadyUsed) }
        guard let card = database.card(id: placed.cardID),
              let bar = card.supportBarAbility else { return .failure(.conditionUnmet) }
        if let block = supportTimingBlock(for: bar.ability, by: slot) { return .failure(block) }

        state[slot].payChakra(bar.ability.cost.chakra)
        state[slot].supports[slotIndex]?.isRevealed = true

        let link = ChainLink(id: placed.id, player: slot, cardID: card.id, playedFromHand: false)
        pushOntoChain(link, ability: bar.ability, name: card.jutsuName)
        return .success(())
    }

    /// Activates a Support straight from hand — active player only. The card
    /// transits through a free slot, already revealed, and chains normally.
    private func activateSupportFromHand(handIndex: Int, by slot: PlayerSlot) -> Result<Void, GameError> {
        guard state[slot].hand.indices.contains(handIndex) else { return .failure(.invalidHandIndex) }
        let cardID = state[slot].hand[handIndex]
        guard let card = database.card(id: cardID) else { return .failure(.unknownCard(cardID)) }
        guard let bar = card.supportBarAbility else { return .failure(.conditionUnmet) }
        if let block = supportTimingBlock(for: bar.ability, by: slot) { return .failure(block) }
        // From hand needs two more things: it must be your turn, and a free
        // slot for the card to transit through.
        guard slot == state.current else { return .failure(.wrongMoment) }
        guard state[slot].hasFreeSupportSlot else { return .failure(.noSlot) }

        state[slot].payChakra(bar.ability.cost.chakra)
        state[slot].hand.remove(at: handIndex)
        let placed = PlacedSupport(id: state.makeIdentifier(), cardID: card.id, isRevealed: true)
        _ = state[slot].setSupport(placed)

        let link = ChainLink(id: placed.id, player: slot, cardID: card.id, playedFromHand: true)
        pushOntoChain(link, ability: bar.ability, name: card.jutsuName)
        return .success(())
    }

    /// Chains the activation, locks its targets when the card prints a choose
    /// clause — the opponent sees where it is aimed before responding — and
    /// then opens the response window.
    private func pushOntoChain(_ link: ChainLink, ability: CardAbility, name: String) {
        state.chain.append(link)
        state.consecutivePasses = 0
        let verb = link.playedFromHand ? "Plays" : "Activates"
        journal.record(
            actor: link.player.title,
            message: "\(verb) \(name) (chain link \(state.chain.count))."
        )

        if let lock = ability.targetLock {
            let options = resolver.characterOptions(
                restedOnly: lock.restedOnly,
                nonEXOnly: lock.nonEXOnly,
                excluding: [],
                immuneAgainst: nil,
                in: state
            )
            if !options.isEmpty {
                var data = ChoiceData()
                data.sourceCardID = link.cardID
                data.chainLinkID = link.id
                data.upTo = lock.upTo
                enqueueChoice(PendingChoice(
                    id: state.makeIdentifier(),
                    kind: .lockTarget,
                    player: link.player,
                    prompt: "Choose \(lock.upTo ? "up to " : "")\(lock.count) target\(lock.count == 1 ? "" : "s") for \(name)",
                    options: options,
                    cancellable: lock.upTo,
                    maxSelections: lock.count,
                    data: data
                ))
                return
            }
        }
        openResponseWindow(after: link.player)
    }

    // MARK: - Windows and priority

    /// Who answers next, relative to the player who just acted. The opponent
    /// gets priority for being the active player or for having *any* card in
    /// a Support slot — even a spent one, which lets them bluff a pass.
    private func nextResponder(after actor: PlayerSlot) -> PlayerSlot? {
        let opposing = actor.opposing
        if opposing == state.current || state[opposing].hasAnySupportSet {
            return opposing
        }
        if couldRespond(actor) { return actor }
        return nil
    }

    /// Whether a player holds any activation that would be legal if they were
    /// given priority right now.
    private func couldRespond(_ slot: PlayerSlot) -> Bool {
        for entry in state[slot].faceDownSupports {
            guard let card = database.card(id: entry.placed.cardID),
                  let bar = card.supportBarAbility else { continue }
            if supportTimingBlock(for: bar.ability, by: slot, assumingPriority: true) == nil {
                return true
            }
        }
        guard slot == state.current else { return false }
        for cardID in state[slot].hand {
            guard let card = database.card(id: cardID),
                  let bar = card.supportBarAbility else { continue }
            if supportTimingBlock(for: bar.ability, by: slot, assumingPriority: true) == nil,
               state[slot].hasFreeSupportSlot {
                return true
            }
        }
        return false
    }

    /// Opens — or skips — the window after a Support activation. When nobody
    /// could respond the chain resolves at once, with no window at all.
    private func openResponseWindow(after actor: PlayerSlot) {
        guard !state.isFinished else { return }
        state.step = .counter
        if let responder = nextResponder(after: actor) {
            state.priority = responder
            state.consecutivePasses = 0
            journal.system("\(responder.title) may respond.")
        } else {
            state.priority = nil
        }
    }

    /// The summon window: always opens, priority to the summoner's opponent,
    /// even when they can do nothing — passing is theirs to do.
    private func openSummonWindow(for summoner: PlayerSlot) {
        guard !state.isFinished, state.step == .normal,
              state.chain.isEmpty, state.pendingAttack == nil else { return }
        state.step = .counter
        state.priority = summoner.opposing
        state.consecutivePasses = 0
        journal.system("\(summoner.opposing.title) may answer the summon.")
    }

    /// The PASS button. Two passes in a row — or one against an empty chain,
    /// or one with nobody else able to answer — hand the moment to the pump.
    private func passCounter(by slot: PlayerSlot) -> Result<Void, GameError> {
        guard state.step == .counter else { return .failure(.noCounterWindow) }
        guard state.priority == slot else { return .failure(.notYourTurn) }

        state.consecutivePasses += 1
        journal.record(actor: slot.title, message: "Passes.")

        if !state.chain.isEmpty, state.consecutivePasses < 2,
           let next = nextResponder(after: slot), next != slot {
            state.priority = next
        } else {
            state.priority = nil
        }
        return .success(())
    }

    // MARK: - Chain resolution

    /// Pops and resolves the top link. A prompt raised mid-effect pauses the
    /// resolution in `resolvingSupport`; the pump finishes disposal after.
    private func resolveTopLink() {
        guard let link = state.chain.popLast() else { return }
        guard let card = database.card(id: link.cardID),
              let bar = card.supportBarAbility else {
            disposeLink(link, keepsCard: false)
            checkDeaths()
            return
        }

        state.resolvingSupport = ResolvingSupport(link: link)
        journal.record(actor: link.player.title, message: "\(card.jutsuName) resolves.")

        let result = resolver.runEffects(
            bar.ability,
            source: EffectSource(card: card, controller: link.player, lockedTargets: link.lockedTargets),
            in: &state
        )
        state.resolvingSupport?.keepsCard = result.keepsCard
        absorb(result, activator: link.player)
    }

    /// A paused link's prompts are answered: the card is disposed of and the
    /// board swept, and the pump carries on down the chain.
    private func finishResolvingLink() {
        guard let resolving = state.resolvingSupport else { return }
        state.resolvingSupport = nil
        disposeLink(resolving.link, keepsCard: resolving.keepsCard)
        checkDeaths()
    }

    /// The resolved card leaves its slot for its owner's trash — unless the
    /// effect self-summoned it onto the board.
    private func disposeLink(_ link: ChainLink, keepsCard: Bool) {
        state[link.player].removeSupport(id: link.id)
        if !keepsCard {
            state[link.player].trash.append(link.cardID)
        }
    }

    /// The chain has emptied: the window closes, and a surviving pending
    /// attack resolves now.
    private func finishChain() {
        state.priority = nil
        state.consecutivePasses = 0
        state.step = .normal
        if state.pendingAttack != nil {
            resolveAttack()
        }
    }

    // MARK: - Attacks

    /// Declares an attack: the attacker rests and spends its attack on the
    /// spot, "When Attacking" boxes fire, and the defender's counter window
    /// opens — always, even when they hold no answer.
    private func declareAttack(
        attacker: AttackerReference,
        target: AttackTarget,
        by slot: PlayerSlot
    ) -> Result<Void, GameError> {
        if let block = attackBlock(attacker: attacker, by: slot) { return .failure(block) }

        let defendingSlot = slot.opposing
        if case .character(let targetID) = target {
            guard let defender = state[defendingSlot].character(id: targetID) else {
                return .failure(.invalidTarget)
            }
            // Standing characters cannot be attacked — the Leader is the only
            // always-legal target.
            guard defender.isRested else { return .failure(.invalidTarget) }
        }

        let attackerName: String
        switch attacker {
        case .leader:
            state[slot].leaderRested = true
            state[slot].leaderAttacksUsed += 1
            attackerName = database.card(id: state[slot].leaderCardID)?.name ?? "Leader"
        case .character(let id):
            state[slot].rest(characterID: id)
            if let index = state[slot].indexOfCharacter(id: id) {
                state[slot].characters[index].attacksUsed += 1
            }
            attackerName = state[slot].character(id: id).map(resolver.characterName) ?? "Character"
        }

        state.pendingAttack = PendingAttack(
            id: state.makeIdentifier(),
            attackingSlot: slot,
            attacker: attacker,
            target: target
        )
        state.step = .counter
        state.chain = []
        state.consecutivePasses = 0
        state.priority = defendingSlot

        let targetName = target.characterID
            .flatMap { state[defendingSlot].character(id: $0) }
            .map(resolver.characterName) ?? "the Leader"
        journal.record(actor: slot.title, message: "\(attackerName) attacks \(targetName).")

        if case .character(let id) = attacker {
            runWhenAttacking(id, for: slot)
            checkDeaths()
        }
        return .success(())
    }

    /// Fires the attacker's When Attacking boxes — before the defender's
    /// window, which is the whole point of them. Negated effects never fire.
    private func runWhenAttacking(_ characterID: UUID, for slot: PlayerSlot) {
        guard !state.isFinished else { return }
        guard let character = state[slot].character(id: characterID),
              !character.effectsNegated,
              let card = database.card(id: character.cardID) else { return }

        for ability in card.abilities where ability.trigger == .whenAttacking {
            guard !state.isFinished else { return }
            let result = resolver.runEffects(
                ability,
                source: EffectSource(card: card, controller: slot),
                in: &state
            )
            absorb(result, activator: slot)
        }
    }

    /// Resolves the surviving attack once the window closes. Stats read at
    /// resolution time; a vanished attacker or target fizzles silently, the
    /// attack still spent. The attacker never takes combat damage back.
    private func resolveAttack() {
        guard let attack = state.pendingAttack else { return }
        state.pendingAttack = nil

        let attackingSlot = attack.attackingSlot
        let defendingSlot = attack.defendingSlot

        let damageStat: Int
        let powerStat: Int
        let attackerName: String
        switch attack.attacker {
        case .leader:
            guard let leader = database.card(id: state[attackingSlot].leaderCardID) else { return }
            damageStat = leader.damage ?? 0
            powerStat = leader.power ?? 0
            attackerName = leader.name
        case .character(let id):
            guard let character = state[attackingSlot].character(id: id),
                  let card = database.card(id: character.cardID) else { return }
            damageStat = character.damageStat(of: card)
            powerStat = character.effectivePower(of: card, turn: state.turnNumber)
            attackerName = card.name
        }

        switch attack.target {
        case .leader:
            state[defendingSlot].life = max(0, state[defendingSlot].life - damageStat)
            journal.record(
                actor: attackingSlot.title,
                message: "\(attackerName) hits the Leader for \(damageStat) — \(state[defendingSlot].life) life left."
            )
            if state[defendingSlot].life == 0 {
                finish(winner: attackingSlot, reason: .lifeDepleted)
            }

        case .character(let targetID):
            guard let index = state[defendingSlot].indexOfCharacter(id: targetID),
                  let targetCard = database.card(id: state[defendingSlot].characters[index].cardID)
            else { return }
            state[defendingSlot].characters[index].damage += powerStat
            let left = state[defendingSlot].characters[index].remainingHealth(of: targetCard)
            journal.record(
                actor: attackingSlot.title,
                message: "\(attackerName) hits \(targetCard.name) for \(powerStat) — \(left) health left."
            )
            checkDeaths()
        }
    }

    // MARK: - Activated abilities

    /// A character's printed Activate: Main — Ino's team boost is the pool's
    /// only one, but any character printing the box goes through here.
    private func activateCharacter(_ characterID: UUID, by slot: PlayerSlot) -> Result<Void, GameError> {
        if let block = characterAbilityBlock(characterID, by: slot) { return .failure(block) }
        guard let character = state[slot].character(id: characterID),
              let card = database.card(id: character.cardID),
              let index = card.abilities.firstIndex(where: { $0.trigger == .activateMain })
        else { return .failure(.conditionUnmet) }

        if let characterIndex = state[slot].indexOfCharacter(id: characterID) {
            state[slot].characters[characterIndex].activatedThisTurn = true
        }
        journal.record(actor: slot.title, message: "\(card.name) — Activate: Main.")
        let result = resolver.runEffects(
            card.abilities[index],
            source: EffectSource(card: card, controller: slot),
            in: &state
        )
        absorb(result, activator: slot)
        return .success(())
    }

    /// The Leader's printed Activate: Main. It does NOT rest the Leader, and
    /// only a box printing Once Per Turn is limited to one use.
    private func useLeaderEffect(by slot: PlayerSlot) -> Result<Void, GameError> {
        if let block = leaderEffectBlock(for: slot) { return .failure(block) }
        guard let leader = database.card(id: state[slot].leaderCardID),
              let index = leader.abilities.firstIndex(where: { $0.trigger == .activateMain })
        else { return .failure(.conditionUnmet) }
        let box = leader.abilities[index]

        if box.cost.chakra > 0 {
            state[slot].payChakra(box.cost.chakra)
            journal.record(
                actor: slot.title,
                message: "\(leader.name) — flips \(box.cost.chakra) chakra face-down."
            )
        } else {
            journal.record(actor: slot.title, message: "\(leader.name) — Activate: Main.")
        }
        state[slot].leaderUsedThisTurn = true

        let result = resolver.runEffects(
            box,
            source: EffectSource(card: leader, controller: slot),
            in: &state
        )
        absorb(result, activator: slot)
        return .success(())
    }

    // MARK: - Prompts

    /// Queues a prompt behind whatever is already open. Empty prompts are
    /// skipped silently; forced answers are the pump's to give.
    private func enqueueChoice(_ choice: PendingChoice) {
        guard !choice.options.isEmpty else { return }
        if state.pendingChoice == nil {
            state.pendingChoice = choice
        } else {
            state.queuedChoices.append(choice)
        }
    }

    /// The player's answer to the open prompt. Empty keys decline a prompt
    /// that allows declining; cancelling after a cost is paid loses the cost.
    private func resolveChoice(keys: [String], by slot: PlayerSlot) -> Result<Void, GameError> {
        guard let choice = state.pendingChoice else { return .failure(.wrongMoment) }
        guard choice.player == slot else { return .failure(.notYourChoice) }

        if keys.isEmpty {
            guard choice.cancellable else { return .failure(.invalidChoice) }
            journal.record(actor: slot.title, message: "Declines.")
            performCancel(choice)
            state.pendingChoice = nil
            return .success(())
        }

        guard keys.count <= choice.maxSelections,
              Set(keys).count == keys.count else { return .failure(.invalidChoice) }
        let chosen = keys.compactMap { choice.option(forKey: $0) }
        guard chosen.count == keys.count else { return .failure(.invalidChoice) }

        performChoice(choice, chosen: chosen)
        state.pendingChoice = nil
        return .success(())
    }

    /// A declined prompt still has consequences: a cancelled target lock
    /// proceeds with zero targets, so its window must still open.
    private func performCancel(_ choice: PendingChoice) {
        guard choice.kind == .lockTarget,
              let linkIndex = state.chain.firstIndex(where: { $0.id == choice.data.chainLinkID })
        else { return }
        openResponseWindow(after: state.chain[linkIndex].player)
    }

    /// Applies an answered prompt. `pendingChoice` stays set throughout, so
    /// any prompts this raises queue behind it in order.
    private func performChoice(_ choice: PendingChoice, chosen: [ChoiceOption]) {
        switch choice.kind {

        case .lockTarget:
            guard let linkIndex = state.chain.firstIndex(where: { $0.id == choice.data.chainLinkID })
            else { return }
            let targets = chosen.compactMap(\.target.characterID)
            state.chain[linkIndex].lockedTargets = targets
            if !targets.isEmpty {
                let names = targets
                    .compactMap { state.locateCharacter(id: $0)?.character }
                    .map(resolver.characterName)
                journal.record(
                    actor: choice.player.title,
                    message: "Aims at \(names.joined(separator: ", "))."
                )
            }
            openResponseWindow(after: state.chain[linkIndex].player)

        case .leaderBoost:
            guard let targetID = chosen.first?.target.characterID,
                  let found = state.locateCharacter(id: targetID),
                  let index = state[found.slot].indexOfCharacter(id: targetID) else { return }
            state[found.slot].characters[index].powerBonus += choice.data.amount
            journal.record(
                actor: choice.player.title,
                message: "\(resolver.characterName(found.character)) gets +\(choice.data.amount) power this turn."
            )

        case .leaderPutBack:
            let indices = chosen.compactMap { option -> Int? in
                if case .handCard(let index) = option.target { return index }
                return nil
            }
            for index in indices.sorted(by: >) where state[choice.player].hand.indices.contains(index) {
                let cardID = state[choice.player].hand.remove(at: index)
                state[choice.player].deck.insert(cardID, at: 0)
            }
            journal.record(actor: choice.player.title, message: "Places a card on top of the deck.")

        case .freezeTarget:
            guard let target = chosen.first?.target else { return }
            let lines = resolver.applyFreeze(
                target: target,
                trait: choice.data.trait,
                by: choice.player,
                in: &state
            )
            record(lines)

        case .koTarget:
            var result = EffectResult()
            if let targetID = chosen.first?.target.characterID {
                resolver.knockOut(targetID, by: choice.player, in: &state, into: &result)
            }
            absorb(result, activator: choice.player)
            checkDeaths()
            // Multi-K.O.s count down one pick at a time, re-filtered.
            if choice.data.remaining > 1, !state.isFinished {
                let options = resolver.characterOptions(
                    restedOnly: choice.data.restedOnly,
                    nonEXOnly: choice.data.nonEXOnly,
                    excluding: [],
                    immuneAgainst: choice.player,
                    in: state
                )
                if !options.isEmpty {
                    var data = choice.data
                    data.remaining -= 1
                    enqueueChoice(PendingChoice(
                        id: state.makeIdentifier(),
                        kind: .koTarget,
                        player: choice.player,
                        prompt: "Choose another character to K.O.",
                        options: options,
                        cancellable: choice.data.upTo,
                        alwaysAsk: true,
                        data: data
                    ))
                }
            }

        case .bounceTarget:
            guard let targetID = chosen.first?.target.characterID,
                  let found = state.locateCharacter(id: targetID) else { return }
            if resolver.isImmune(found.character, owner: found.slot, against: choice.player, in: state) {
                journal.record(
                    actor: found.slot.title,
                    message: "\(resolver.characterName(found.character)) was protected and stayed."
                )
            } else {
                state[found.slot].bounceCharacterToHand(id: targetID)
                journal.record(
                    actor: found.slot.title,
                    message: "\(resolver.characterName(found.character)) was returned to its owner's hand."
                )
            }

        case .doublePower, .supportImmune:
            guard let targetID = chosen.first?.target.characterID,
                  let found = state.locateCharacter(id: targetID),
                  let index = state[found.slot].indexOfCharacter(id: targetID) else { return }
            if choice.kind == .doublePower {
                state[found.slot].characters[index].powerDoubledUntilTurn = state.turnNumber
                journal.record(
                    actor: choice.player.title,
                    message: "\(resolver.characterName(found.character))'s power is doubled this turn."
                )
            } else {
                state[found.slot].characters[index].supportImmuneUntilTurn = state.turnNumber
                state[found.slot].characters[index].supportImmuneFrom = choice.player.opposing
                journal.record(
                    actor: choice.player.title,
                    message: "\(resolver.characterName(found.character)) ignores Support effects this turn."
                )
            }

        case .exRequirement:
            guard let paidID = chosen.first?.target.characterID,
                  let handIndex = choice.data.pendingSummonHandIndex,
                  let card = database.card(id: choice.data.sourceCardID) else { return }
            let paid = choice.data.paidCharacterIDs + [paidID]
            raiseEXRequirement(
                handIndex: handIndex,
                card: card,
                by: choice.player,
                remaining: choice.data.requirementSlots,
                paid: paid
            )

        case .reviveFromTrash:
            guard case .trashCard(let side, let index)? = chosen.first?.target,
                  state[side].trash.indices.contains(index) else { return }
            let cardID = state[side].trash.remove(at: index)
            let name = database.card(id: cardID)?.name ?? cardID
            journal.record(actor: choice.player.title, message: "Summons \(name) from the trash.")
            let characterID = resolver.placeCharacter(cardID: cardID, for: choice.player, in: &state)
            runOnSummon(characterID, for: choice.player)
            checkDeaths()

        case .searchSummon:
            guard let target = chosen.first?.target else { return }
            let cardID: String?
            switch target {
            case .deckCard(let side, let index) where state[side].deck.indices.contains(index):
                // The search removes the card without reshuffling — the
                // reference leaves the deck's order intact.
                cardID = state[side].deck.remove(at: index)
            case .trashCard(let side, let index) where state[side].trash.indices.contains(index):
                cardID = state[side].trash.remove(at: index)
            default:
                cardID = nil
            }
            guard let cardID else { return }
            let name = database.card(id: cardID)?.name ?? cardID
            journal.record(
                actor: choice.player.title,
                message: "Summons \(name) with its effects negated."
            )
            _ = resolver.placeCharacter(cardID: cardID, for: choice.player, negated: true, in: &state)
            checkDeaths()
        }
    }

    // MARK: - Absorbing results

    /// Journals a resolution's lines, queues its prompts, cascades its
    /// summons' triggers, and honours a fatal self-cost.
    private func absorb(_ result: EffectResult, activator: PlayerSlot) {
        record(result.lines)

        if result.activatorLifeReachedZero, !state.isFinished {
            finish(winner: activator.opposing, reason: .lifeDepleted)
            return
        }
        for choice in result.choices {
            enqueueChoice(choice)
        }
        for summoned in result.summoned {
            runOnSummon(summoned.characterID, for: summoned.slot)
        }
    }

    private func record(_ lines: [EffectLine]) {
        for line in lines {
            if let actor = line.actor {
                journal.record(actor: actor.title, message: line.message)
            } else {
                journal.system(line.message)
            }
        }
    }

    // MARK: - Deaths and defeat

    /// Sends every character whose damage has reached its printed health to
    /// the trash, then sweeps for deck-out: with nothing in flight, a player
    /// whose deck holds zero cards loses on the spot.
    private func checkDeaths() {
        guard !state.isFinished else { return }

        for side in PlayerSlot.allCases {
            for character in state[side].characters {
                guard let card = database.card(id: character.cardID) else { continue }
                if character.damage >= (card.health ?? 0) {
                    state[side].sendCharacterToTrash(id: character.id)
                    journal.record(
                        actor: side.title,
                        message: "\(card.name) was sent to the Trash."
                    )
                }
            }
        }

        guard state.pendingChoice == nil, state.queuedChoices.isEmpty,
              state.resolvingSupport == nil, !state.isFinished else { return }
        for side in PlayerSlot.allCases where state[side].deck.isEmpty {
            journal.system("\(side.title) has no cards left in the deck.")
            finish(winner: side.opposing, reason: .deckOut)
            return
        }
    }

    private func finish(winner: PlayerSlot, reason: WinReason) {
        guard !state.isFinished else { return }
        state.pendingAttack = nil
        state.pendingChoice = nil
        state.queuedChoices = []
        state.resolvingSupport = nil
        state.chain = []
        state.priority = nil
        state.owedSummonWindow = nil
        state.step = .normal
        state.outcome = .win(winner, reason: reason)
        journal.system(state.outcome.summary)
    }

    // MARK: - Auto-pass

    /// "When you have nothing to answer with, pass for you instead of holding
    /// the window open." Holding it open is still the default.
    private func runAutoPassIfNeeded() {
        guard autoPass == .passForMe else { return }
        var safety = 0
        while safety < 20, !state.isFinished,
              state.pendingChoice == nil,
              state.step == .counter,
              let holder = state.priority {
            safety += 1
            guard legalCounterActivations(for: holder).isEmpty else { return }
            _ = passCounter(by: holder)
            pump()
        }
    }
}
