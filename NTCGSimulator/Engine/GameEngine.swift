//
//  GameEngine.swift
//  NTCGSimulator
//
//  The rules, and the only code allowed to move a card. Every decision arrives
//  through `apply(_:by:)`, which validates before it mutates and journals what
//  it accepted. The questions — lookups, legality, legal actions — live in
//  GameEngine+Setup.swift. No SwiftUI, and no randomness beyond the seed.
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

    // MARK: Lifecycle

    /// Builds both sides from a configuration. Deck resolution never fails: a
    /// missing or illegal deck falls back to a generated legal one.
    init(
        configuration: GameConfiguration,
        database: CardDatabase,
        decks: DeckStore,
        seed: UInt64 = UInt64.random(in: UInt64.min...UInt64.max)
    ) {
        self.configuration = configuration
        self.database = database
        self.seed = seed
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
        journal.system("Keep your opening hand, or take your one mulligan.")
    }

    // MARK: Derived state

    var outcome: GameOutcome { state.outcome }
    var phase: GamePhase { state.phase }
    var currentPlayer: PlayerSlot { state.current }
    var turnNumber: Int { state.turnNumber }
    var pendingAttack: PendingAttack? { state.pendingAttack }
    var isAwaitingMulligan: Bool { state.isAwaitingMulligan }
    var isFinished: Bool { state.isFinished }

    /// The side that must answer a declared attack, if one is waiting.
    var blockingPlayer: PlayerSlot? { state.pendingAttack?.defendingSlot }

    // MARK: Apply

    /// The single door into the rules. Validates first, mutates second, and
    /// journals whatever it accepted.
    @discardableResult
    func apply(_ action: GameAction, by slot: PlayerSlot) -> Result<Void, GameError> {
        guard !state.isFinished else { return .failure(.gameOver) }

        if state.isAwaitingMulligan {
            switch action {
            case .mulligan, .concede: break
            default: return .failure(.awaitingMulligan)
            }
        }

        switch action {
        case .mulligan(let redraw):
            return resolveMulligan(redraw: redraw, by: slot)
        case .playCard(let index, let asJutsu):
            return playCard(handIndex: index, asJutsu: asJutsu, by: slot)
        case .attack(let attackerID, let target):
            return declareAttack(attackerID: attackerID, target: target, by: slot)
        case .declareBlock(let blockerID):
            return declareBlock(blockerID: blockerID, by: slot)
        case .useLeaderAbility(let targetID):
            return useLeaderAbility(targetID: targetID, by: slot)
        case .endPhase:
            return endPhase(by: slot)
        case .endTurn:
            return endTurn(by: slot)
        case .concede:
            journal.record(actor: slot.title, message: "Conceded the game.")
            finish(winner: slot.opposing, reason: .concession)
            return .success(())
        }
    }

    // MARK: Mulligan

    /// Keeps or redraws an opening hand. Turn one begins the moment both sides
    /// have answered.
    private func resolveMulligan(redraw: Bool, by slot: PlayerSlot) -> Result<Void, GameError> {
        guard state.needsMulligan(slot) else { return .failure(.mulliganUnavailable) }

        var side = state[slot]
        if redraw {
            side.deck.append(contentsOf: side.hand)
            side.hand.removeAll()
            side.deck.shuffle(using: &state.rng)
            let dealt = min(GameRules.openingHandSize, side.deck.count)
            side.hand = Array(side.deck.prefix(dealt))
            side.deck.removeFirst(dealt)
            side.hasMulliganed = true
        }
        side.mulliganResolved = true
        state[slot] = side

        journal.record(
            actor: slot.title,
            message: redraw ? "Took a mulligan and drew a new hand." : "Kept the opening hand."
        )

        if !state.isAwaitingMulligan {
            beginTurn(for: state.firstPlayer, turn: 1)
        }
        return .success(())
    }

    // MARK: Playing cards

    /// Commits a play the validator has already approved: the card leaves hand,
    /// Chakra rests for its cost, and the card reaches the zone it belongs in.
    private func playCard(handIndex: Int, asJutsu: Bool, by slot: PlayerSlot) -> Result<Void, GameError> {
        let plan: PlayPlan
        switch planPlay(handIndex: handIndex, asJutsu: asJutsu, by: slot) {
        case .success(let value): plan = value
        case .failure(let error): return .failure(error)
        }

        var side = state[slot]
        side.hand.remove(at: plan.handIndex)
        side.restChakra(plan.cost)

        if plan.asJutsu {
            side.trash.append(plan.card.id)
        } else if plan.card.type.isBody {
            side.characters.append(
                CharacterInPlay(
                    id: state.makeIdentifier(),
                    cardID: plan.card.id,
                    isEX: plan.card.type == .exCharacter
                )
            )
        } else if plan.card.type == .support {
            _ = side.placeInSupport(
                PlacedCard(id: state.makeIdentifier(), cardID: plan.card.id)
            )
        } else {
            side.summon = PlacedCard(id: state.makeIdentifier(), cardID: plan.card.id)
        }
        state[slot] = side

        journal.record(actor: slot.title, message: playMessage(for: plan))
        if plan.asJutsu { resolveJutsu(plan.card, by: slot) }
        return .success(())
    }

    private func playMessage(for plan: PlayPlan) -> String {
        let price = plan.cost == 0 ? "for free" : "for \(plan.cost) chakra"
        if plan.asJutsu {
            return "Played \(plan.card.name) as a jutsu \(price)."
        }
        if plan.card.type.isBody {
            return "Summoned \(plan.card.name)."
        }
        if plan.card.type == .support {
            return "Played \(plan.card.name) to Support \(price)."
        }
        return "Placed \(plan.card.name) in the Summon zone \(price)."
    }

    /// Resolves a jutsu's support line. The published rulebook does not define
    /// individual jutsu effects, so resolution is currently the journal line and
    /// the card reaching the Trash — this is the one place a corrected effect
    /// system should hook in.
    private func resolveJutsu(_ card: Card, by slot: PlayerSlot) {
        guard let text = card.supportText, !text.isEmpty else { return }
        journal.record(actor: slot.title, message: "\(card.name) resolves: \(text)")
    }

    // MARK: Leader ability

    /// Activates the current player's Leader, once per turn.
    ///
    /// Unlike the printed text on other cards, a Leader's ability is modelled
    /// concretely (`LeaderAbility`) and resolved here, because it is the effect
    /// a player reaches for every single turn.
    private func useLeaderAbility(targetID: UUID?, by slot: PlayerSlot) -> Result<Void, GameError> {
        let ability: LeaderAbility
        switch planLeaderAbility(targetID: targetID, by: slot) {
        case .success(let value): ability = value
        case .failure(let error): return .failure(error)
        }

        var side = state[slot]
        side.hasUsedLeaderAbility = true
        state[slot] = side

        let leaderName = database.card(id: state[slot].leaderCardID)?.name ?? "The Leader"
        var detail = ability.summary

        switch ability {
        case .drawCard:
            // `draw` ends the game on an empty deck, so check before calling it
            // rather than turning a Leader activation into a loss.
            if state[slot].deck.isEmpty {
                detail = "had no cards left to draw"
            } else {
                draw(1, for: slot)
            }

        case .restoreLife(let amount):
            var side = state[slot]
            side.life += amount
            state[slot] = side

        case .empowerCharacter(let power):
            if let targetID, let index = state[slot].indexOfCharacter(id: targetID) {
                var side = state[slot]
                side.characters[index].powerBonus += power
                state[slot] = side
                let name = database.card(id: side.characters[index].cardID)?.name ?? "a character"
                detail = "gave \(name) +\(power) power this turn"
            }

        case .weakenCharacter(let power):
            let enemy = slot.opposing
            if let targetID, let index = state[enemy].indexOfCharacter(id: targetID) {
                var side = state[enemy]
                side.characters[index].powerBonus -= power
                state[enemy] = side
                let name = database.card(id: side.characters[index].cardID)?.name ?? "a character"
                detail = "left \(name) with \(power) less power this turn"
            }
        }

        journal.record(actor: slot.title, message: "\(leaderName) activated: \(detail).")
        return .success(())
    }

    // MARK: Attacking

    /// Declares an attack. The attacker rests immediately, then the defender is
    /// asked for a block — unless they have nobody ready, in which case the
    /// attack resolves at once rather than waiting on a one-option decision.
    private func declareAttack(attackerID: UUID, target: AttackTarget, by slot: PlayerSlot) -> Result<Void, GameError> {
        let attacker: CharacterInPlay
        switch validateAttacker(attackerID, by: slot) {
        case .success(let value): attacker = value
        case .failure(let error): return .failure(error)
        }

        let defendingSlot = slot.opposing
        if let targetID = target.characterID,
           state[defendingSlot].character(id: targetID) == nil {
            return .failure(.invalidTarget)
        }

        state[slot].rest(characterID: attackerID)
        state.pendingAttack = PendingAttack(
            id: state.makeIdentifier(),
            attackerID: attackerID,
            attackingSlot: slot,
            target: target
        )

        let targetName = target.characterID
            .flatMap { state[defendingSlot].character(id: $0) }
            .map { name(of: $0) } ?? "the Leader"
        journal.record(actor: slot.title, message: "\(name(of: attacker)) attacks \(targetName).")

        if state[defendingSlot].readyCharacters.isEmpty {
            resolvePendingAttack(blockerID: nil)
        }
        return .success(())
    }

    /// Answers a declared attack. Blocking exerts the blocker, mirroring the
    /// cost the attacker paid to swing.
    private func declareBlock(blockerID: UUID?, by slot: PlayerSlot) -> Result<Void, GameError> {
        guard let pending = state.pendingAttack else { return .failure(.noAttackPending) }
        guard slot == pending.defendingSlot else { return .failure(.notYourTurn) }

        if let blockerID {
            guard state[slot].character(id: blockerID)?.isReady == true else {
                return .failure(.blockerUnavailable)
            }
        }
        resolvePendingAttack(blockerID: blockerID)
        return .success(())
    }

    private func resolvePendingAttack(blockerID: UUID?) {
        guard let pending = state.pendingAttack else { return }
        state.pendingAttack = nil

        let attackingSlot = pending.attackingSlot
        let defendingSlot = pending.defendingSlot

        guard let attacking = state[attackingSlot].character(id: pending.attackerID),
              let attackerCard = database.card(id: attacking.cardID) else { return }

        if let blockerID {
            let blockerName = state[defendingSlot].character(id: blockerID).map { name(of: $0) } ?? "a character"
            journal.record(actor: defendingSlot.title, message: "\(blockerName) blocks.")
            state[defendingSlot].rest(characterID: blockerID)
            resolveBattle(
                attackerSlot: attackingSlot,
                attackerID: pending.attackerID,
                defenderSlot: defendingSlot,
                defenderID: blockerID
            )
            return
        }

        switch pending.target {
        case .leader:
            journal.record(actor: defendingSlot.title, message: "Took the attack on the Leader.")
            applyLeaderDamage(max(0, attackerCard.damage ?? 0), to: defendingSlot)
        case .character(let targetID):
            resolveBattle(
                attackerSlot: attackingSlot,
                attackerID: pending.attackerID,
                defenderSlot: defendingSlot,
                defenderID: targetID
            )
        }
    }

    /// Two bodies trade: each compares its power against the other's remaining
    /// health, and both results apply simultaneously.
    private func resolveBattle(attackerSlot: PlayerSlot, attackerID: UUID, defenderSlot: PlayerSlot, defenderID: UUID) {
        guard let attacker = state[attackerSlot].character(id: attackerID),
              let defender = state[defenderSlot].character(id: defenderID),
              let attackerCard = database.card(id: attacker.cardID),
              let defenderCard = database.card(id: defender.cardID) else { return }

        let attackerPower = attacker.effectivePower(of: attackerCard)
        let defenderPower = defender.effectivePower(of: defenderCard)
        let defenderFalls = attackerPower >= defender.remainingHealth(of: defenderCard)
        let attackerFalls = defenderPower >= attacker.remainingHealth(of: attackerCard)

        if defenderFalls {
            state[defenderSlot].sendCharacterToTrash(id: defenderID)
            journal.record(actor: defenderSlot.title, message: "\(defenderCard.name) was sent to the Trash.")
        } else {
            state[defenderSlot].applyDamage(attackerPower, to: defenderID)
            journal.record(actor: defenderSlot.title, message: "\(defenderCard.name) took \(attackerPower) damage.")
        }

        if attackerFalls {
            state[attackerSlot].sendCharacterToTrash(id: attackerID)
            journal.record(actor: attackerSlot.title, message: "\(attackerCard.name) was sent to the Trash.")
        } else if defenderPower > 0 {
            state[attackerSlot].applyDamage(defenderPower, to: attackerID)
            journal.record(actor: attackerSlot.title, message: "\(attackerCard.name) took \(defenderPower) damage.")
        }
    }

    private func applyLeaderDamage(_ amount: Int, to slot: PlayerSlot) {
        guard amount > 0 else { return }
        state[slot].life = max(0, state[slot].life - amount)
        let leaderName = leaderCard(for: slot)?.name ?? "The Leader"
        journal.record(actor: slot.title, message: "\(leaderName) lost \(amount) life, down to \(state[slot].life).")
        if state[slot].life == 0 {
            finish(winner: slot.opposing, reason: .lifeDepleted)
        }
    }

    // MARK: Phases and turns

    private func endPhase(by slot: PlayerSlot) -> Result<Void, GameError> {
        guard slot == state.current else { return .failure(.notYourTurn) }
        guard state.pendingAttack == nil else { return .failure(.attackAlreadyPending) }

        switch state.phase {
        case .main:
            enter(.attack)
        case .attack:
            enter(.end)
        case .refresh, .draw, .end:
            return .failure(.wrongPhase(state.phase))
        }
        return .success(())
    }

    private func endTurn(by slot: PlayerSlot) -> Result<Void, GameError> {
        guard slot == state.current else { return .failure(.notYourTurn) }
        guard state.pendingAttack == nil else { return .failure(.attackAlreadyPending) }
        guard !state.isAwaitingMulligan else { return .failure(.awaitingMulligan) }

        if state.phase != .end { enter(.end) }
        cleanUpEndOfTurn()
        journal.record(actor: slot.title, message: "Ended the turn.")

        guard !state.isFinished else { return .success(()) }
        beginTurn(for: slot.opposing, turn: state.turnNumber + 1)
        return .success(())
    }

    private func enter(_ phase: GamePhase) {
        state.phase = phase
        journal.system("\(phase.title) phase.")
    }

    /// Refresh and draw take no input, so a turn always lands the player in main.
    private func beginTurn(for slot: PlayerSlot, turn: Int) {
        state.current = slot
        state.turnNumber = turn
        state.phase = .refresh
        journal.system("Turn \(turn) — \(slot.title).")

        state[slot].readyAll()
        journal.record(actor: slot.title, message: "Refreshed chakra and characters.")

        state.phase = .draw
        if turn == 1 && slot == state.firstPlayer {
            journal.record(actor: slot.title, message: "Skipped the first draw for going first.")
        } else {
            draw(1, for: slot)
        }

        guard !state.isFinished else { return }
        enter(.main)
    }

    /// End-of-turn cleanup: battle damage heals on both boards, so damage only
    /// ever matters inside the turn it was dealt.
    private func cleanUpEndOfTurn() {
        state.pendingAttack = nil
        state.player.healAllCharacters()
        state.opponent.healAllCharacters()

        // Power granted or removed by Leader abilities lasts only for the turn.
        state.player.clearTemporaryModifiers()
        state.opponent.clearTemporaryModifiers()
    }

    // MARK: Drawing and defeat

    /// Draws cards one at a time. Drawing from an empty deck loses the game.
    private func draw(_ count: Int, for slot: PlayerSlot) {
        for _ in 0..<count {
            guard !state.isFinished else { return }
            guard !state[slot].deck.isEmpty else {
                journal.record(actor: slot.title, message: "Could not draw from an empty deck.")
                finish(winner: slot.opposing, reason: .deckOut)
                return
            }
            let cardID = state[slot].deck.removeFirst()
            state[slot].hand.append(cardID)
            // The card itself stays hidden: the journal never leaks a draw.
            journal.record(actor: slot.title, message: "Drew a card.")
        }
    }

    private func finish(winner: PlayerSlot, reason: WinReason) {
        guard !state.isFinished else { return }
        state.pendingAttack = nil
        state.outcome = .win(winner, reason: reason)
        journal.system(state.outcome.summary)
    }

    // MARK: Naming

    /// A character's printed name, falling back to its number if the pool has
    /// changed underneath a game in progress.
    private func name(of character: CharacterInPlay) -> String {
        database.card(id: character.cardID)?.name ?? character.cardID
    }
}
