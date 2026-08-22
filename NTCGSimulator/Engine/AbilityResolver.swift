//
//  AbilityResolver.swift
//  NTCGSimulator
//
//  Turns the structured steps of one ability box into board changes.
//
//  This is deliberately separate from `GameEngine`. The engine decides whether
//  an ability may be used at all — timing, priority, cost, targets — and runs
//  the windows and prompts around it; this decides what the ability then does.
//  A resolution reports what it needs the engine to carry on with: journal
//  lines, prompts to raise, freshly summoned bodies whose own On Summon boxes
//  must fire, and whether the resolving card stays on the board.
//
//  Support immunity lives here too, with the reference's exact shape: it only
//  protects while a support is resolving or the chain is live, only for the
//  turn it was granted, and only against the player it was granted against.
//

import Foundation

// MARK: - Effect lines

/// One journal line produced by a resolution: who it belongs to — `nil` for
/// the engine's own voice — and what happened.
struct EffectLine: Hashable {
    let actor: PlayerSlot?
    let message: String
}

// MARK: - Result

/// What a resolution did, reported back rather than acted on. Ending the
/// game, journalling, cascading On Summon triggers and opening prompts all
/// belong to the engine; the resolver names them and the engine acts.
struct EffectResult {

    /// Journal lines, in the order they happened.
    var lines: [EffectLine] = []

    /// Prompts the effects raised, in order. The engine queues them.
    var choices: [PendingChoice] = []

    /// Bodies the effects put on the board. The engine runs each one's
    /// On Summon boxes — unless its effects arrived negated — in order.
    var summoned: [SummonedCharacter] = []

    /// True when the resolving card self-summoned and must not be trashed.
    var keepsCard: Bool = false

    /// True when a self-cost took the activator to zero life — the opponent
    /// wins on the spot.
    var activatorLifeReachedZero: Bool = false

    mutating func say(_ actor: PlayerSlot?, _ message: String) {
        lines.append(EffectLine(actor: actor, message: message))
    }
}

/// A body a resolution placed, so the engine can fire its triggers.
struct SummonedCharacter: Hashable {
    let slot: PlayerSlot
    let characterID: UUID
}

// MARK: - Source

/// The moment an effect list is resolving in: whose card, and which targets
/// were locked when it was activated.
struct EffectSource {
    let card: Card
    let controller: PlayerSlot
    var lockedTargets: [UUID] = []
}

// MARK: - Resolver

/// Applies `[AbilityEffect]` to a board and answers targeting questions.
struct AbilityResolver {

    /// Card lookups, for names, traits and printed stats. Read only.
    let database: CardDatabase

    // MARK: - Immunity

    /// The reference's immunity gate, exactly: active only while a support is
    /// resolving or the chain is non-empty, only for the turn it was granted,
    /// and only against the recorded opponent — any non-owner as a fallback.
    /// Nothing outside that gate — combat, leader effects, EX payments — ever
    /// consults it.
    func isImmune(
        _ character: CharacterInPlay,
        owner: PlayerSlot,
        against actor: PlayerSlot,
        in state: GameState
    ) -> Bool {
        guard state.resolvingSupport != nil || !state.chain.isEmpty else { return false }
        guard character.supportImmuneUntilTurn >= state.turnNumber else { return false }
        if let from = character.supportImmuneFrom { return actor == from }
        return actor != owner
    }

    // MARK: - Running effects

    /// Resolves every step in `ability`, in printed order, against the board
    /// as it stands — a later step sees what an earlier one did.
    func runEffects(
        _ ability: CardAbility,
        source: EffectSource,
        in state: inout GameState
    ) -> EffectResult {
        var result = EffectResult()
        for effect in ability.effects {
            guard !state.isFinished, !result.activatorLifeReachedZero else { break }
            apply(effect, source: source, in: &state, into: &result)
        }
        return result
    }

    // MARK: - Effect table

    private func apply(
        _ effect: AbilityEffect,
        source: EffectSource,
        in state: inout GameState,
        into result: inout EffectResult
    ) {
        let slot = source.controller
        let name = source.card.name

        switch effect {

        case .drawCards(let count):
            // A Leader-effect draw: raw, so an empty deck simply yields no
            // card — the deck-out sweep decides the game at the next check.
            var drawn = 0
            for _ in 0..<count where !state[slot].deck.isEmpty {
                state[slot].hand.append(state[slot].deck.removeFirst())
                drawn += 1
            }
            if drawn > 0 {
                result.say(slot, "Draws \(drawn), hand \(state[slot].hand.count), deck \(state[slot].deck.count).")
            }

        case .placeFromHandOnDeck(let count):
            guard !state[slot].hand.isEmpty else { return }
            result.choices.append(PendingChoice(
                id: state.makeIdentifier(),
                kind: .leaderPutBack,
                player: slot,
                prompt: "Place a card from your hand on top of your deck",
                options: handOptions(for: slot, in: state),
                cancellable: false,
                maxSelections: count,
                data: choiceData(sourceCardID: source.card.id)
            ))

        case .gainLife(let amount):
            guard amount > 0 else { return }
            state[slot].life += amount
            result.say(slot, "Gained \(amount) life, up to \(state[slot].life).")

        case .loseLife(let amount):
            guard amount > 0 else { return }
            state[slot].life = max(0, state[slot].life - amount)
            result.say(slot, "Paid \(amount) life, down to \(state[slot].life).")
            if state[slot].life == 0 { result.activatorLifeReachedZero = true }

        case .negateChainLink:
            negateTopChainLink(by: slot, negatorName: name, in: &state, into: &result)

        case .interruptAttack:
            interruptAttack(by: slot, in: &state, into: &result)

        case .chakraLock:
            // Blocks the activator's next own Recovery: through the end of
            // their next turn when it is their turn now, one turn less when
            // it is not — the same net effect either way.
            let lockedUntil = state.turnNumber + (slot == state.current ? 3 : 2)
            state[slot].chakraLockedUntilTurn = max(state[slot].chakraLockedUntilTurn, lockedUntil)
            result.say(slot, "Cannot turn chakra face-up until after their next turn.")

        case .summonSelf:
            let id = placeCharacter(cardID: source.card.id, for: slot, in: &state)
            result.keepsCard = true
            result.summoned.append(SummonedCharacter(slot: slot, characterID: id))
            result.say(slot, "Summons \(name).")

        case .doubleChosenPower:
            applyToLockedTarget(source, in: &state, into: &result) { state, owner, index in
                state[owner].characters[index].powerDoubledUntilTurn = state.turnNumber
                let cardName = self.characterName(state[owner].characters[index])
                return "\(cardName)'s power is doubled this turn."
            }

        case .grantSupportImmunity:
            applyToLockedTarget(source, in: &state, into: &result) { state, owner, index in
                state[owner].characters[index].supportImmuneUntilTurn = state.turnNumber
                state[owner].characters[index].supportImmuneFrom = slot.opposing
                let cardName = self.characterName(state[owner].characters[index])
                return "\(cardName) ignores \(slot.opposing.title)'s Support effects this turn."
            }

        case .knockOutAll:
            for side in PlayerSlot.allCases {
                for character in state[side].characters {
                    guard !isImmune(character, owner: side, against: slot, in: state) else {
                        result.say(side, "\(characterName(character)) was protected and survived.")
                        continue
                    }
                    state[side].sendCharacterToTrash(id: character.id)
                    result.say(side, "\(characterName(character)) was sent to the Trash.")
                }
            }
            result.say(slot, "\(name) K.O.s all characters.")

        case .knockOutChosen(let count, let upTo, let restedOnly, let nonEXOnly):
            if source.lockedTargets.isEmpty {
                // No targets were locked — possible only for an "up to" card
                // activated bare, or a K.O. raised by an On Summon box. Ask
                // now, immunity-filtered, one pick at a time.
                let options = characterOptions(
                    restedOnly: restedOnly, nonEXOnly: nonEXOnly,
                    excluding: [], immuneAgainst: slot, in: state
                )
                guard !options.isEmpty else { return }
                var data = choiceData(sourceCardID: source.card.id)
                data.remaining = count
                data.restedOnly = restedOnly
                data.nonEXOnly = nonEXOnly
                data.upTo = upTo
                result.choices.append(PendingChoice(
                    id: state.makeIdentifier(),
                    kind: .koTarget,
                    player: slot,
                    prompt: "Choose a character to K.O.",
                    options: options,
                    cancellable: upTo,
                    alwaysAsk: true,
                    data: data
                ))
                return
            }
            for targetID in source.lockedTargets {
                knockOut(targetID, by: slot, in: &state, into: &result)
            }

        case .returnChosenToHand:
            for targetID in source.lockedTargets {
                guard let found = state.locateCharacter(id: targetID) else {
                    result.say(slot, "The chosen card had already left the board.")
                    continue
                }
                guard !isImmune(found.character, owner: found.slot, against: slot, in: state) else {
                    result.say(found.slot, "\(characterName(found.character)) was protected and stayed.")
                    continue
                }
                state[found.slot].bounceCharacterToHand(id: targetID)
                result.say(found.slot, "\(characterName(found.character)) was returned to its owner's hand.")
            }

        case .boostChosenPower(let amount):
            let options = characterOptions(
                restedOnly: false, nonEXOnly: false,
                excluding: [], immuneAgainst: nil, in: state
            )
            guard !options.isEmpty else { return }
            var data = choiceData(sourceCardID: source.card.id)
            data.amount = amount
            result.choices.append(PendingChoice(
                id: state.makeIdentifier(),
                kind: .leaderBoost,
                player: slot,
                prompt: "Choose a character to get +\(amount) power this turn",
                options: options,
                cancellable: true,
                data: data
            ))

        case .teamBoost(_, let boosts, let power, let damage):
            var boosted: [String] = []
            for index in state[slot].characters.indices {
                let character = state[slot].characters[index]
                guard let card = database.card(id: character.cardID),
                      boosts.contains(card.name) else { continue }
                state[slot].characters[index].powerBonus += power
                state[slot].characters[index].damageBonus += damage
                state[slot].characters[index].rushUntilTurn = state.turnNumber
                boosted.append(card.name)
            }
            if !boosted.isEmpty {
                result.say(slot, "\(boosted.joined(separator: ", ")) gain +\(power) power, +\(damage) damage and Rush this turn.")
            }

        case .freezeChosenIfRevealTrait(let trait):
            var options: [ChoiceOption] = []
            for side in PlayerSlot.allCases {
                let leaderName = database.card(id: state[side].leaderCardID)?.name ?? "Leader"
                options.append(ChoiceOption(
                    key: "leader-\(side.rawValue)",
                    target: .leader(side),
                    title: "\(leaderName) (\(side.title) Leader)"
                ))
            }
            options.append(contentsOf: characterOptions(
                restedOnly: false, nonEXOnly: false,
                excluding: [], immuneAgainst: nil, in: state
            ))
            var data = choiceData(sourceCardID: source.card.id)
            data.trait = trait
            result.choices.append(PendingChoice(
                id: state.makeIdentifier(),
                kind: .freezeTarget,
                player: slot,
                prompt: "Choose a Leader or character to freeze",
                options: options,
                cancellable: false,
                alwaysAsk: true,
                data: data
            ))

        case .summonFromTrash(let names):
            let options = trashCharacterOptions(names: names, for: slot, in: state)
            guard !options.isEmpty else { return }
            result.choices.append(PendingChoice(
                id: state.makeIdentifier(),
                kind: .reviveFromTrash,
                player: slot,
                prompt: "Choose a character in your trash to summon",
                options: options,
                cancellable: false,
                data: choiceData(sourceCardID: source.card.id)
            ))

        case .revealTopAndSummon(let names, let traits):
            revealTopAndSummon(names: names, traits: traits, for: slot, in: &state, into: &result)

        case .searchSummonNegated(let searchName):
            let options = deckAndTrashOptions(name: searchName, for: slot, in: state)
            guard !options.isEmpty else { return }
            result.choices.append(PendingChoice(
                id: state.makeIdentifier(),
                kind: .searchSummon,
                player: slot,
                prompt: "Summon up to 1 [\(searchName)] with its effects negated",
                options: options,
                cancellable: true,
                data: choiceData(sourceCardID: source.card.id)
            ))

        case .rush, .conditionalRush, .cannotBeSummonedNormally, .recovery:
            // Standing rules and engine-level actions: nothing fires here.
            return

        case .unimplemented(let text):
            result.say(slot, "NOT APPLIED — \(name) reads \"\(text)\", and the app does not resolve that step yet.")
        }
    }

    // MARK: - Chain answers

    /// "Negate that card": the top remaining link is cancelled outright — its
    /// card leaves its slot for its owner's trash having done nothing, and
    /// its chakra stays paid. Whiffs silently on an empty chain.
    private func negateTopChainLink(
        by slot: PlayerSlot,
        negatorName: String,
        in state: inout GameState,
        into result: inout EffectResult
    ) {
        guard let negated = state.chain.popLast() else { return }
        state[negated.player].removeSupport(id: negated.id)
        state[negated.player].trash.append(negated.cardID)
        let negatedName = database.card(id: negated.cardID)?.name ?? negated.cardID
        result.say(slot, "\(negatorName) negates \(negatedName) — it goes to the Trash having done nothing.")
    }

    /// "Interrupt": the pending attack is cancelled, but the attacker stays
    /// rested and keeps its spent attack. A support-immune attacker shrugs
    /// the interrupt off entirely.
    private func interruptAttack(
        by slot: PlayerSlot,
        in state: inout GameState,
        into result: inout EffectResult
    ) {
        guard let attack = state.pendingAttack else { return }
        if let attackerID = attack.attacker.characterID,
           let attacker = state[attack.attackingSlot].character(id: attackerID),
           isImmune(attacker, owner: attack.attackingSlot, against: slot, in: state) {
            result.say(slot, "The attacker was protected — the attack goes ahead.")
            return
        }
        state.pendingAttack = nil
        result.say(slot, "The attack is interrupted. The attacker stays rested.")
    }

    // MARK: - Board changes

    /// Places a fresh body on `slot`'s field, with summoning sickness. The
    /// caller owns running its On Summon boxes and journalling the arrival.
    func placeCharacter(
        cardID: String,
        for slot: PlayerSlot,
        negated: Bool = false,
        in state: inout GameState
    ) -> UUID {
        let card = database.card(id: cardID)
        let character = CharacterInPlay(
            id: state.makeIdentifier(),
            cardID: cardID,
            isEX: card?.type == .exCharacter,
            summonedOnTurn: state.turnNumber,
            effectsNegated: negated
        )
        state[slot].characters.append(character)
        return character.id
    }

    /// K.O.s one character, respecting immunity and vanished targets.
    func knockOut(
        _ targetID: UUID,
        by actor: PlayerSlot,
        in state: inout GameState,
        into result: inout EffectResult
    ) {
        guard let found = state.locateCharacter(id: targetID) else {
            result.say(actor, "The chosen card had already left the board.")
            return
        }
        guard !isImmune(found.character, owner: found.slot, against: actor, in: state) else {
            result.say(found.slot, "\(characterName(found.character)) was protected and survived.")
            return
        }
        state[found.slot].sendCharacterToTrash(id: targetID)
        result.say(found.slot, "\(characterName(found.character)) was K.O.'d and sent to the Trash.")
    }

    /// Itachi's freeze payoff: reveal the summoner's top deck card — it stays
    /// on the deck — and freeze the chosen target if the reveal prints the
    /// gating trait. Immunity is deliberately not consulted, exactly as the
    /// reference never routes the freeze through its immunity gate.
    func applyFreeze(
        target: ChoiceTarget,
        trait: String,
        by slot: PlayerSlot,
        in state: inout GameState
    ) -> [EffectLine] {
        var lines: [EffectLine] = []
        guard let topID = state[slot].deck.first else {
            lines.append(EffectLine(actor: slot, message: "Had no deck card to reveal."))
            return lines
        }
        let revealed = database.card(id: topID)
        let revealedName = revealed?.name ?? topID
        lines.append(EffectLine(actor: slot, message: "Reveals \(revealedName) — it stays on top of the deck."))

        guard revealed?.traits.contains(trait) == true else {
            lines.append(EffectLine(actor: slot, message: "It has no {\(trait)} type — nothing is frozen."))
            return lines
        }

        switch target {
        case .leader(let side):
            state[side].leaderCannotAttackUntilTurn = state.turnNumber + 1
            lines.append(EffectLine(actor: side, message: "The Leader cannot attack next turn."))
        case .character(let id):
            if let found = state.locateCharacter(id: id),
               let index = state[found.slot].indexOfCharacter(id: id) {
                state[found.slot].characters[index].cannotAttackUntilTurn = state.turnNumber + 1
                lines.append(EffectLine(
                    actor: found.slot,
                    message: "\(characterName(found.character)) cannot attack next turn."
                ))
            }
        default:
            break
        }
        return lines
    }

    /// Manda's and Jugo's reveal: the top deck card is shown, and summoned
    /// only when it is a non-EX character matching the filters — empty
    /// filters accept any non-EX character. A miss stays on top of the deck.
    private func revealTopAndSummon(
        names: [String],
        traits: [String],
        for slot: PlayerSlot,
        in state: inout GameState,
        into result: inout EffectResult
    ) {
        guard let topID = state[slot].deck.first else {
            result.say(slot, "Had no deck card to reveal.")
            return
        }
        guard let revealed = database.card(id: topID) else { return }
        result.say(slot, "Reveals \(revealed.name).")

        let isPlainCharacter = revealed.type == .character
        let matchesFilters = (names.isEmpty && traits.isEmpty)
            || names.contains(revealed.name)
            || revealed.traits.contains(where: traits.contains)

        guard isPlainCharacter, matchesFilters else {
            result.say(slot, "It does not match — it stays on top of the deck.")
            return
        }

        state[slot].deck.removeFirst()
        let id = placeCharacter(cardID: topID, for: slot, in: &state)
        result.summoned.append(SummonedCharacter(slot: slot, characterID: id))
        result.say(slot, "Summons \(revealed.name).")
    }

    /// Applies a closure to the single locked target, fizzling politely when
    /// it vanished or is immune. Shared by double-power and immunity.
    private func applyToLockedTarget(
        _ source: EffectSource,
        in state: inout GameState,
        into result: inout EffectResult,
        change: (inout GameState, PlayerSlot, Int) -> String
    ) {
        guard let targetID = source.lockedTargets.first else { return }
        guard let found = state.locateCharacter(id: targetID),
              let index = state[found.slot].indexOfCharacter(id: targetID) else {
            result.say(source.controller, "The chosen card had already left the board.")
            return
        }
        guard !isImmune(found.character, owner: found.slot, against: source.controller, in: state) else {
            result.say(found.slot, "\(characterName(found.character)) was protected — no effect.")
            return
        }
        let line = change(&state, found.slot, index)
        result.say(source.controller, line)
    }

    // MARK: - Option lists

    /// Characters on both boards, near side first, optionally filtered by
    /// rest state, EX status and immunity against `immuneAgainst`.
    func characterOptions(
        restedOnly: Bool,
        nonEXOnly: Bool,
        excluding: [UUID],
        immuneAgainst actor: PlayerSlot?,
        in state: GameState
    ) -> [ChoiceOption] {
        var options: [ChoiceOption] = []
        for side in PlayerSlot.allCases {
            for character in state[side].characters {
                if excluding.contains(character.id) { continue }
                if restedOnly, !character.isRested { continue }
                if nonEXOnly, character.isEX { continue }
                if let actor, isImmune(character, owner: side, against: actor, in: state) { continue }
                options.append(ChoiceOption(
                    key: "char-\(character.id.uuidString)",
                    target: .character(character.id),
                    title: "\(characterName(character)) (\(side.title))"
                ))
            }
        }
        return options
    }

    /// The chooser's whole hand, by position.
    func handOptions(for slot: PlayerSlot, in state: GameState) -> [ChoiceOption] {
        state[slot].hand.enumerated().map { index, cardID in
            ChoiceOption(
                key: "hand-\(index)",
                target: .handCard(index: index),
                title: database.card(id: cardID)?.name ?? cardID
            )
        }
    }

    /// Non-EX character cards in `slot`'s trash whose names are listed.
    func trashCharacterOptions(names: [String], for slot: PlayerSlot, in state: GameState) -> [ChoiceOption] {
        state[slot].trash.enumerated().compactMap { index, cardID in
            guard let card = database.card(id: cardID),
                  card.type == .character,
                  names.contains(card.name) else { return nil }
            return ChoiceOption(
                key: "trash-\(slot.rawValue)-\(index)",
                target: .trashCard(slot: slot, index: index),
                title: "\(card.name) (trash)"
            )
        }
    }

    /// Every character or EX Character named `name` in `slot`'s deck or
    /// trash — the Naruto EX search pool.
    func deckAndTrashOptions(name: String, for slot: PlayerSlot, in state: GameState) -> [ChoiceOption] {
        var options: [ChoiceOption] = []
        for (index, cardID) in state[slot].deck.enumerated() {
            guard let card = database.card(id: cardID),
                  card.type == .character || card.type == .exCharacter,
                  card.name == name else { continue }
            options.append(ChoiceOption(
                key: "deck-\(slot.rawValue)-\(index)",
                target: .deckCard(slot: slot, index: index),
                title: "\(card.name) (deck)"
            ))
        }
        for (index, cardID) in state[slot].trash.enumerated() {
            guard let card = database.card(id: cardID),
                  card.type == .character || card.type == .exCharacter,
                  card.name == name else { continue }
            options.append(ChoiceOption(
                key: "trash-\(slot.rawValue)-\(index)",
                target: .trashCard(slot: slot, index: index),
                title: "\(card.name) (trash)"
            ))
        }
        return options
    }

    // MARK: - Summon Requirements

    /// Whether `slots` can all be paid by distinct members of `candidates` —
    /// the assignment problem behind an EX summon. Sizes are tiny, so a
    /// straightforward backtrack is the honest solution.
    static func assignmentExists(
        slots: [TrashRequirement],
        candidates: [(id: UUID, traits: [String], power: Int)]
    ) -> Bool {
        guard let slot = slots.first else { return true }
        let rest = Array(slots.dropFirst())
        for candidate in candidates
        where slot.isSatisfied(byTraits: candidate.traits, effectivePower: candidate.power) {
            let remaining = candidates.filter { $0.id != candidate.id }
            if assignmentExists(slots: rest, candidates: remaining) { return true }
        }
        return false
    }

    /// `slot`'s characters as requirement-payment candidates, with the
    /// effective power the requirement checks.
    func requirementCandidates(for slot: PlayerSlot, in state: GameState) -> [(id: UUID, traits: [String], power: Int)] {
        state[slot].characters.compactMap { character in
            guard let card = database.card(id: character.cardID) else { return nil }
            return (
                id: character.id,
                traits: card.traits,
                power: character.effectivePower(of: card, turn: state.turnNumber)
            )
        }
    }

    // MARK: - Naming

    /// A character's printed name, falling back to its number if the pool has
    /// changed underneath a game in progress.
    func characterName(_ character: CharacterInPlay) -> String {
        database.card(id: character.cardID)?.name ?? character.cardID
    }

    private func choiceData(sourceCardID: String) -> ChoiceData {
        var data = ChoiceData()
        data.sourceCardID = sourceCardID
        return data
    }
}

// MARK: - Summon requirements on the card

extension Card {

    /// Whether the card prints "Cannot be summoned normally" — every EX
    /// Character in the shipped pool. Their printed Summon Requirements are
    /// the only door onto the board.
    var cannotBeSummonedNormally: Bool {
        abilities.contains { $0.effects.contains(.cannotBeSummonedNormally) }
    }

    /// The card's printed Summon Requirements box, and where it sits in the
    /// printed order.
    var summonRequirement: (index: Int, ability: CardAbility)? {
        guard let index = abilities.firstIndex(where: { $0.trigger == .summonRequirement }) else {
            return nil
        }
        return (index, abilities[index])
    }

    /// The box the card's Support activation resolves — an alias kept beside
    /// `supportBarAbility` because the two are the same printed line read
    /// from hand and from a slot.
    var jutsuAbility: (index: Int, ability: CardAbility)? {
        supportBarAbility
    }

    /// The name shown on the activation button. The pool's own jutsu names
    /// live in `supportText`; the card's name stands in when it has none.
    var jutsuName: String {
        guard let supportText, let dash = supportText.firstIndex(of: "—") else { return name }
        let prefix = supportText[..<dash].trimmingCharacters(in: .whitespaces)
        return prefix.isEmpty ? name : prefix
    }
}
