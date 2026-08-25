//
//  SimpleAI.swift
//  NTCGSimulator
//
//  The computer opponent — the reference simulator's greedy heuristic,
//  expressed against this engine's action alphabet. One decision per call, no
//  lookahead, and no randomness of its own, so a seeded game against the AI
//  still replays exactly.
//
//  Every branch mirrors the reference's decision order: answer the open
//  prompt, settle the mulligan, answer or pass the counter window, then work
//  the main phase — ability, summon, set a Support, Leader effect, board
//  wipe, attacks, Recovery, end. Nothing is ever returned that the engine
//  does not itself list as legal, so a mistaken idea costs a refusal upstream
//  rather than an illegal move here.
//

import Foundation

// MARK: - Tuning

/// Every number the heuristic leans on, gathered in one place. They are the
/// reference's own constants, kept verbatim so the two opponents feel the
/// same; nothing outside this file reads them.
private enum Tuning {

    /// Sweetener on a score that helps our own side — the reference adds a
    /// flat 20 to a boost, immunity, K.O. or bounce pointed the right way.
    static let ownSideBonus = 20.0

    /// Extra worth of freezing a character over freezing a Leader: the
    /// character loses a whole attack, the Leader can often spare one.
    static let freezeCharacterBonus = 15.0

    /// Put-back score for a card that can never be played from hand, so it is
    /// always the first thing returned to the deck.
    static let deadPutBackScore = 100.0

    /// Base the put-back score subtracts a card's offence from: the weakest
    /// body goes back, the strongest stays in hand.
    static let putBackBase = 50.0

    /// Face-up chakra the Leader effect is held below — the reference keeps
    /// its last chakra in reserve rather than spending down to nothing.
    static let leaderEffectMinimumChakra = 2

    /// Hand size below which no more Supports are set: cards kept in hand
    /// stay flexible, and the reference stops setting at two cards left.
    static let setSupportMinimumHand = 3

    /// Face-up chakra at or below which the turn ends in Recovery instead of
    /// a bare END TURN, when Recovery is on offer.
    static let recoveryChakraFloor = 0
}

// MARK: - Simple AI

/// The greedy one-ply opponent. Stateless: every call reads the engine fresh,
/// decides once, and hands back at most one action from `legalActions(for:)`.
struct SimpleAI {

    init() {}

    // MARK: Entry point

    /// One decision for `slot`, or `nil` when the game is not waiting on it —
    /// the board's driver falls back to its safe answer in that case.
    func chooseAction(engine: GameEngine, slot: PlayerSlot) -> GameAction? {
        guard !engine.isFinished else { return nil }
        let legal = engine.legalActions(for: slot)
        guard !legal.isEmpty else { return nil }

        let decided: GameAction?
        if let choice = engine.pendingChoice {
            decided = choice.player == slot
                ? choiceAction(choice, engine: engine, slot: slot, legal: legal)
                : nil
        } else if engine.isAwaitingMulligan {
            decided = mulliganAction(engine: engine, slot: slot, legal: legal)
        } else if engine.step == .counter {
            decided = counterAction(engine: engine, slot: slot, legal: legal)
        } else if engine.currentPlayer == slot, engine.phase == .main {
            decided = turnAction(engine: engine, slot: slot, legal: legal)
        } else {
            decided = nil
        }
        return validated(decided, against: legal, choice: engine.pendingChoice)
    }

    // MARK: Legality gate

    /// The promise the rest of the file is built on: only actions the engine
    /// lists are returned. The one shape `legalActions` does not enumerate —
    /// a multi-key answer to a multi-target prompt — is admitted when every
    /// key is individually listed and the count fits the prompt.
    private func validated(
        _ action: GameAction?,
        against legal: [GameAction],
        choice: PendingChoice?
    ) -> GameAction? {
        guard let action else { return nil }
        if legal.contains(action) { return action }

        if case .resolveChoice(let keys) = action, let choice,
           keys.count > 1, keys.count <= choice.maxSelections,
           Set(keys).count == keys.count,
           keys.allSatisfy(legalChoiceKeys(in: legal).contains) {
            return action
        }
        return nil
    }

    /// The single option keys the legal list offers for the open prompt.
    private func legalChoiceKeys(in legal: [GameAction]) -> Set<String> {
        Set(legal.compactMap { action -> String? in
            guard case .resolveChoice(let keys) = action, keys.count == 1 else { return nil }
            return keys[0]
        })
    }

    // MARK: Mulligan

    /// Keep iff the hand holds at least one plain character — an EX Character
    /// does not count, since it cannot come down without bodies to pay it.
    private func mulliganAction(
        engine: GameEngine, slot: PlayerSlot, legal: [GameAction]
    ) -> GameAction? {
        let keep = engine.side(slot).hand.contains { engine.card(for: $0)?.type == .character }
        return .mulligan(keep: keep)
    }

    // MARK: Counter windows

    /// Holding priority: flip the first activatable face-down Support into an
    /// attack or summon window, but never on top of a live chain — the
    /// reference answers moments, not answers — and never from hand. Anything
    /// else is a pass.
    private func counterAction(
        engine: GameEngine, slot: PlayerSlot, legal: [GameAction]
    ) -> GameAction? {
        guard legal.contains(.passCounter) else { return nil }
        if engine.state.chain.isEmpty,
           let flip = legal.first(where: { action in
               if case .activateSupport = action { return true }
               return false
           }) {
            return flip
        }
        return .passCounter
    }

    // MARK: The turn

    /// The main phase, worked in the reference's strict order. Each call
    /// returns one step; the driver calls again until END TURN comes back.
    private func turnAction(
        engine: GameEngine, slot: PlayerSlot, legal: [GameAction]
    ) -> GameAction? {
        // 1. A character's Activate: Main is free value — Ino's team boost.
        if let ability = legal.first(where: { action in
            if case .activateCharacter = action { return true }
            return false
        }) {
            return ability
        }

        // 1b. Lethal on the Leader, before anything else spends the attacker.
        //
        //     This sits ahead of the summon step deliberately. Without it the
        //     greedy policy could EX Summon using the one standing attacker
        //     that had the win on board as the material, then attack a rested
        //     body because `attackAction` takes any kill before it ever looks
        //     at the face, chip the Leader for less than lethal, and pass with
        //     the opponent alive on one life. That is a game it had already won.
        //
        //     It matters beyond the Genin tier too: the search rolls out with
        //     this same policy, so a rollout that fumbles a win mis-scores the
        //     position it came from.
        if let lethal = lethalAttackAction(engine: engine, slot: slot, legal: legal) {
            return lethal
        }

        // 2. Summon the most valuable body on offer. The engine has already
        //    gated the normal summon and every EX Summon Requirement.
        if let summon = bestSummon(engine: engine, slot: slot, legal: legal) {
            return summon
        }

        // 3. Set a Support face-down while the hand can spare a card.
        if engine.side(slot).hand.count >= Tuning.setSupportMinimumHand,
           let set = legal.first(where: { action in
               if case .setSupport = action { return true }
               return false
           }) {
            return set
        }

        // 4. The Leader effect, above a chakra reserve.
        if let leader = leaderEffectAction(engine: engine, slot: slot, legal: legal) {
            return leader
        }

        // 5. A board wipe, but only when the enemy board is strictly bigger.
        if let wipe = boardWipeAction(engine: engine, slot: slot, legal: legal) {
            return wipe
        }

        // 6. Attacks: finishing blows first, then the Leader's face.
        if let attack = attackAction(engine: engine, slot: slot, legal: legal) {
            return attack
        }

        // 7. Out of chakra and out of attacks: Recovery when it is on offer.
        if engine.availableChakra(for: slot) <= Tuning.recoveryChakraFloor,
           legal.contains(.recovery) {
            return .recovery
        }

        // 8. Nothing left worth doing.
        return legal.contains(.endTurn) ? .endTurn : nil
    }

    /// The highest-value legal summon, by the reference's card worth. Ties
    /// keep the first hand index, so a seeded game stays deterministic.
    private func bestSummon(
        engine: GameEngine, slot: PlayerSlot, legal: [GameAction]
    ) -> GameAction? {
        let hand = engine.side(slot).hand
        var best: (action: GameAction, score: Double)?
        for action in legal {
            guard case .summon(let index) = action,
                  hand.indices.contains(index),
                  let card = engine.card(for: hand[index]) else { continue }
            let score = worth(of: card)
            if best == nil || score > best!.score {
                best = (action, score)
            }
        }
        return best?.action
    }

    /// The Leader effect, held back below a chakra reserve — and the targeted
    /// boost is only worth a chakra when one of our own characters can still
    /// attack to use the power.
    private func leaderEffectAction(
        engine: GameEngine, slot: PlayerSlot, legal: [GameAction]
    ) -> GameAction? {
        guard legal.contains(.leaderEffect) else { return nil }
        guard engine.availableChakra(for: slot) >= Tuning.leaderEffectMinimumChakra else {
            return nil
        }

        if let leader = engine.leaderCard(for: slot),
           let box = leader.abilities.first(where: { $0.trigger == .activateMain }),
           box.effects.contains(where: { effect in
               if case .boostChosenPower = effect { return true }
               return false
           }) {
            let anAttackerStands = engine.side(slot).characters.contains {
                engine.attackBlock(attacker: .character($0.id), by: slot) == nil
            }
            guard anAttackerStands else { return nil }
        }
        return .leaderEffect
    }

    /// A set K.O.-all Support, flipped proactively only when the enemy board
    /// outnumbers ours — a wipe that trades even or worse is held.
    private func boardWipeAction(
        engine: GameEngine, slot: PlayerSlot, legal: [GameAction]
    ) -> GameAction? {
        guard engine.side(slot.opposing).characters.count
                > engine.side(slot).characters.count else { return nil }

        for entry in engine.faceDownSupports(for: slot)
        where entry.ability.effects.contains(.knockOutAll) {
            let action = GameAction.activateSupport(slotIndex: entry.slotIndex)
            if legal.contains(action) { return action }
        }
        return nil
    }

    // MARK: Attacking

    /// The reference's legacy attack scan: attackers in board order, Leader
    /// last. The first attacker whose power finishes a rested defender takes
    /// the kill; with no kill on the table, the first attacker goes at the
    /// enemy Leader. Only rested characters ever appear as targets — the
    /// engine enumerates nothing else — and the Leader attacks like any body.
    private func attackAction(
        engine: GameEngine, slot: PlayerSlot, legal: [GameAction]
    ) -> GameAction? {
        let attacks = legal.compactMap { action -> (attacker: AttackerReference, target: AttackTarget)? in
            guard case .declareAttack(let attacker, let target) = action else { return nil }
            return (attacker, target)
        }
        guard !attacks.isEmpty else { return nil }

        for attack in attacks {
            guard case .character(let targetID) = attack.target,
                  let found = engine.locateCharacter(id: targetID),
                  found.slot == slot.opposing,
                  let targetCard = engine.card(for: found.character),
                  let power = attackerPower(attack.attacker, engine: engine, slot: slot)
            else { continue }
            if power >= found.character.remainingHealth(of: targetCard) {
                return .declareAttack(attacker: attack.attacker, target: attack.target)
            }
        }

        return attacks.first { $0.target == .leader }
            .map { .declareAttack(attacker: $0.attacker, target: $0.target) }
    }

    /// An attack on the enemy Leader that ends the game this turn.
    ///
    /// A hit on the Leader spends the attacker's DAMAGE stat, not its power —
    /// `GameEngine` line 818 onward — so this reads damage, and reads it live
    /// so a buff counts. Returns nil when nothing on the board finishes it.
    private func lethalAttackAction(
        engine: GameEngine, slot: PlayerSlot, legal: [GameAction]
    ) -> GameAction? {
        let enemyLife = engine.side(slot.opposing).life
        guard enemyLife > 0 else { return nil }

        for action in legal {
            guard case .declareAttack(let attacker, let target) = action,
                  case .leader = target,
                  let damage = attackerDamage(attacker, engine: engine, slot: slot),
                  damage >= enemyLife
            else { continue }
            return action
        }
        return nil
    }

    /// Damage at resolution time, mirroring the engine's own Leader-hit rule:
    /// a character's live damage stat including bonuses, the Leader's printed
    /// damage.
    private func attackerDamage(
        _ attacker: AttackerReference, engine: GameEngine, slot: PlayerSlot
    ) -> Int? {
        switch attacker {
        case .leader:
            return engine.leaderCard(for: slot)?.damage ?? 0
        case .character(let id):
            guard let character = engine.side(slot).character(id: id),
                  let card = engine.card(for: character) else { return nil }
            return character.damageStat(of: card)
        }
    }

    /// Power at resolution time: a character's live effective power — buffs
    /// and doubling included — and the Leader's printed power.
    private func attackerPower(
        _ attacker: AttackerReference, engine: GameEngine, slot: PlayerSlot
    ) -> Int? {
        switch attacker {
        case .leader:
            return engine.leaderCard(for: slot)?.power ?? 0
        case .character(let id):
            guard let character = engine.side(slot).character(id: id),
                  let card = engine.card(for: character) else { return nil }
            return character.effectivePower(of: card, turn: engine.turnNumber)
        }
    }

    // MARK: Prompts

    /// Answers the open prompt: score every offered option, take everything
    /// worthwhile on a multi-target lock, decline a declinable prompt with
    /// nothing good in it, and otherwise take the single best — however bad.
    private func choiceAction(
        _ choice: PendingChoice, engine: GameEngine, slot: PlayerSlot, legal: [GameAction]
    ) -> GameAction? {
        let offered = legalChoiceKeys(in: legal)
        let canCancel = legal.contains(.resolveChoice(keys: []))
        let kind = effectiveKind(of: choice, engine: engine)

        let scored = choice.options.enumerated()
            .filter { offered.contains($0.element.key) }
            .map { index, option in
                (option: option,
                 score: score(option, at: index, kind: kind, engine: engine, slot: slot))
            }
        guard !scored.isEmpty else {
            return canCancel ? .resolveChoice(keys: []) : nil
        }

        // A multi-target lock takes every positive target at once, best first.
        if choice.maxSelections > 1 {
            let positives = scored.filter { $0.score > 0 }
                .sorted { $0.score > $1.score }
                .prefix(choice.maxSelections)
            if !positives.isEmpty {
                return .resolveChoice(keys: positives.map(\.option.key))
            }
        }

        guard let best = scored.max(by: { $0.score < $1.score }) else { return nil }
        if canCancel, best.score <= 0 {
            return .resolveChoice(keys: [])
        }
        return .resolveChoice(keys: [best.option.key])
    }

    /// What a `lockTarget` prompt is really asking. Targets are locked at
    /// activation, before the effect names itself, so the underlying effect
    /// is read off the source card — a K.O. lock scores like a K.O. pick.
    private func effectiveKind(of choice: PendingChoice, engine: GameEngine) -> ChoiceKind {
        guard choice.kind == .lockTarget,
              let card = engine.card(for: choice.data.sourceCardID),
              let bar = card.supportBarAbility else { return choice.kind }
        for effect in bar.ability.effects {
            switch effect {
            case .knockOutChosen:       return .koTarget
            case .returnChosenToHand:   return .bounceTarget
            case .doubleChosenPower:    return .doublePower
            case .grantSupportImmunity: return .supportImmune
            default:                    continue
            }
        }
        return choice.kind
    }

    /// The reference's per-effect option scores, verbatim: helpful things on
    /// our side of the board score their worth plus a bonus, the same things
    /// pointed at us score negative, and payments prefer the cheapest body.
    private func score(
        _ option: ChoiceOption,
        at index: Int,
        kind: ChoiceKind,
        engine: GameEngine,
        slot: PlayerSlot
    ) -> Double {
        // Earlier options win any prompt the table below does not price.
        let byPosition = index == 0 ? 0 : -Double(index)

        switch kind {
        case .leaderBoost, .doublePower:
            guard let board = boardTarget(option.target, engine: engine, slot: slot) else {
                return byPosition
            }
            return board.isOwn ? board.worth + Tuning.ownSideBonus : -board.worth

        case .freezeTarget:
            guard let board = boardTarget(option.target, engine: engine, slot: slot) else {
                return byPosition
            }
            if board.isOwn { return -board.worth }
            return board.worth + (board.isLeader ? 0 : Tuning.freezeCharacterBonus)

        case .koTarget, .bounceTarget:
            guard let board = boardTarget(option.target, engine: engine, slot: slot) else {
                return byPosition
            }
            return board.isOwn
                ? -(board.worth + Tuning.ownSideBonus)
                : board.worth + Tuning.ownSideBonus

        case .supportImmune:
            guard let board = boardTarget(option.target, engine: engine, slot: slot) else {
                return byPosition
            }
            return board.isOwn
                ? board.worth + Tuning.ownSideBonus
                : -(board.worth + Tuning.ownSideBonus)

        case .exRequirement:
            // Sacrifices spend the cheapest body that still pays the slot.
            guard let card = card(at: option.target, engine: engine, slot: slot) else {
                return byPosition
            }
            return -worth(of: card)

        case .reviveFromTrash, .searchSummon:
            guard let card = card(at: option.target, engine: engine, slot: slot) else {
                return byPosition
            }
            return worth(of: card)

        case .leaderPutBack:
            // The weakest hand card goes back on the deck; a card that can
            // never be played from hand goes back first of all.
            guard let card = card(at: option.target, engine: engine, slot: slot) else {
                return byPosition
            }
            if card.type == .chakra || card.type == .summon {
                return Tuning.deadPutBackScore
            }
            return Tuning.putBackBase
                - (Double(card.power ?? 0) + 2 * Double(card.damage ?? 0))

        case .lockTarget:
            return byPosition
        }
    }

    // MARK: Valuing cards

    /// The reference's card worth, printed stats only: power plus twice the
    /// damage — the stat that actually shortens the game — plus half the
    /// health that buys survival through one exchange.
    private func worth(of card: Card) -> Double {
        Double(card.power ?? 0)
            + 2 * Double(card.damage ?? 0)
            + Double(card.health ?? 0) / 2
    }

    /// A board target resolved to its worth and which side it stands on.
    private func boardTarget(
        _ target: ChoiceTarget, engine: GameEngine, slot: PlayerSlot
    ) -> (worth: Double, isOwn: Bool, isLeader: Bool)? {
        switch target {
        case .character(let id):
            guard let found = engine.locateCharacter(id: id),
                  let card = engine.card(for: found.character) else { return nil }
            return (worth(of: card), found.slot == slot, false)
        case .leader(let owner):
            guard let card = engine.leaderCard(for: owner) else { return nil }
            return (worth(of: card), owner == slot, true)
        case .handCard, .trashCard, .deckCard:
            return nil
        }
    }

    /// The printed card behind any prompt target, hidden zones included.
    private func card(
        at target: ChoiceTarget, engine: GameEngine, slot: PlayerSlot
    ) -> Card? {
        switch target {
        case .character(let id):
            return engine.locateCharacter(id: id).flatMap { engine.card(for: $0.character) }
        case .leader(let owner):
            return engine.leaderCard(for: owner)
        case .handCard(let index):
            let hand = engine.side(slot).hand
            return hand.indices.contains(index) ? engine.card(for: hand[index]) : nil
        case .trashCard(let side, let index):
            let trash = engine.side(side).trash
            return trash.indices.contains(index) ? engine.card(for: trash[index]) : nil
        case .deckCard(let side, let index):
            let deck = engine.side(side).deck
            return deck.indices.contains(index) ? engine.card(for: deck[index]) : nil
        }
    }
}
