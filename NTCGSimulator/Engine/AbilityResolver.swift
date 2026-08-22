//
//  AbilityResolver.swift
//  NTCGSimulator
//
//  Turns the printed steps of one ability box into board changes.
//
//  This is deliberately separate from `GameEngine`. The engine decides whether
//  an ability may be used at all — whose turn it is, which phase, whether the
//  cost can be paid, whether the target is legal — and this decides what the
//  ability then does. Splitting them keeps the timing rules in one place and
//  the effect table in another, and it means the engine never grows a switch
//  over `AbilityEffect`.
//
//  Nothing here guesses. A step the app cannot resolve arrives as
//  `.unimplemented` and leaves as a journal line saying, in words a player can
//  read, that it was not applied. Silence would be worse than a missing rule:
//  a player who cannot see what was skipped cannot correct for it.
//

import Foundation

// MARK: - Board target

/// One card on the board an effect acts on, with the side that owns it. Effects
/// routinely reach across the table, so the side is carried rather than assumed.
struct BoardTarget: Hashable {
    let slot: PlayerSlot
    let id: UUID
}

// MARK: - Context

/// Everything an ability needs to know about the moment it is resolving in.
///
/// It is a value rather than a set of arguments because every effect case wants
/// most of it, and because a resolution is worth being able to describe in one
/// piece when something goes wrong.
struct AbilityContext {

    /// The card the ability is printed on.
    let source: AbilitySource

    /// The player who activated it, or whose card triggered it.
    let controller: PlayerSlot

    /// The printed card behind `source`, for names and traits.
    let card: Card

    /// The box being resolved.
    let ability: CardAbility

    /// The card the player chose, when the ability's scope asked for one.
    let targetID: UUID?

    /// Hand positions the player nominated, for a step that asks them to give
    /// cards up. Empty when nobody was asked.
    let handSelection: [Int]
}

// MARK: - Outcome

/// What a resolution did, reported back rather than acted on.
///
/// Two consequences belong to the engine and not to the effect table: ending
/// the game, and writing the log. The resolver names them and the engine acts,
/// so an ability can never end a game by a different route than the turn draw
/// or a connecting attack does.
struct AbilityOutcome {

    /// Journal lines, in the order they happened. The engine records each one
    /// against the controller.
    var lines: [String] = []

    /// A side that was asked to draw from an empty deck.
    var deckedOut: PlayerSlot?

    /// A side whose Leader ran out of life while this resolved.
    var defeated: PlayerSlot?

    /// True when at least one printed step was displayed rather than applied.
    var hadUnappliedSteps: Bool = false
}

// MARK: - Resolver

/// Applies `[AbilityEffect]` to a board.
struct AbilityResolver {

    /// Card lookups, for names, traits and printed power. Read only.
    let database: CardDatabase

    // MARK: Resolving

    /// Resolves every step of the ability in `context`, in printed order.
    ///
    /// Steps are applied one after another against the board as it stands, so a
    /// later step sees what an earlier one did — an ability that draws and then
    /// puts a card back is placing the card it just drew.
    func resolve(_ context: AbilityContext, in state: inout GameState) -> AbilityOutcome {
        var outcome = AbilityOutcome()
        for effect in context.ability.effects {
            apply(effect, context: context, in: &state, into: &outcome)
        }
        if outcome.lines.isEmpty {
            outcome.lines.append("\(context.card.name) had nothing to resolve.")
        }
        return outcome
    }

    // MARK: - Effects

    private func apply(
        _ effect: AbilityEffect,
        context: AbilityContext,
        in state: inout GameState,
        into outcome: inout AbilityOutcome
    ) {
        switch effect {

        case .drawCards(let count):
            draw(count, for: context.controller, in: &state, into: &outcome)

        case .placeFromHandOnDeck(let count):
            placeOnDeck(count, context: context, in: &state, into: &outcome)

        case .gainLife(let amount):
            guard amount > 0 else { return }
            state[context.controller].life += amount
            outcome.lines.append("Gained \(amount) life, up to \(state[context.controller].life).")

        case .loseLife(let amount):
            guard amount > 0 else { return }
            let slot = context.controller
            state[slot].life = max(0, state[slot].life - amount)
            outcome.lines.append("Lost \(amount) life, down to \(state[slot].life).")
            if state[slot].life == 0 { outcome.defeated = slot }

        case .buffPower(let amount, let scope):
            let hits = targets(for: scope, context: context, in: state)
            guard report(hits, effect: effect, into: &outcome) else { return }
            for hit in hits {
                guard let index = state[hit.slot].indexOfCharacter(id: hit.id) else { continue }
                state[hit.slot].characters[index].powerBonus += amount
            }
            outcome.lines.append("\(list(hits, in: state)) got \(signed(amount)) power for the turn.")

        case .buffDamage(let amount, let scope):
            let hits = targets(for: scope, context: context, in: state)
            guard report(hits, effect: effect, into: &outcome) else { return }
            for hit in hits {
                guard let index = state[hit.slot].indexOfCharacter(id: hit.id) else { continue }
                state[hit.slot].characters[index].damageBonus += amount
            }
            outcome.lines.append("\(list(hits, in: state)) got \(signed(amount)) damage for the turn.")

        case .grantRush(let scope):
            let hits = targets(for: scope, context: context, in: state)
            guard report(hits, effect: effect, into: &outcome) else { return }
            for hit in hits {
                guard let index = state[hit.slot].indexOfCharacter(id: hit.id) else { continue }
                state[hit.slot].characters[index].hasRush = true
            }
            outcome.lines.append("\(list(hits, in: state)) gained Rush and can attack this turn.")

        case .knockOut(let scope):
            let hits = targets(for: scope, context: context, in: state)
            guard report(hits, effect: effect, into: &outcome) else { return }
            // Names are read before the bodies leave, or there is nothing left
            // to name them from.
            let names = list(hits, in: state)
            for hit in hits {
                state[hit.slot].sendCharacterToTrash(id: hit.id)
            }
            outcome.lines.append("\(names) knocked out and sent to the Trash.")

        case .restSelf:
            rest(context: context, in: &state, into: &outcome)

        case .flipAllChakraFaceUp:
            let flipped = state[context.controller].readyAllChakra()
            outcome.lines.append(
                flipped == 0
                    ? "All chakra was already face-up."
                    : "Turned \(flipped) chakra face-up."
            )

        case .cannotAttackNextTurn(let scope):
            let hits = targets(for: scope, context: context, in: state)
            guard report(hits, effect: effect, into: &outcome) else { return }
            for hit in hits {
                guard let index = state[hit.slot].indexOfCharacter(id: hit.id) else { continue }
                state[hit.slot].characters[index].isBarredNextTurn = true
            }
            outcome.lines.append("\(list(hits, in: state)) cannot attack on its controller's next turn.")

        case .cannotBeSummonedNormally:
            // A standing rule, not a moment: the board enforces it when the
            // card is played. Saying so keeps the step from looking skipped.
            outcome.lines.append(
                "\(context.card.name) cannot be summoned normally — that is checked when it is played."
            )

        case .unimplemented(let text):
            outcome.hadUnappliedSteps = true
            outcome.lines.append(
                "NOT APPLIED — \(context.card.name) reads \"\(text)\", and the app does not resolve that step yet. Settle it between yourselves."
            )
        }
    }

    // MARK: Cards

    /// Draws one card at a time so an empty deck is caught exactly where it
    /// happens. Deciding the game is the engine's job, so the empty deck is
    /// reported rather than acted on.
    private func draw(
        _ count: Int,
        for slot: PlayerSlot,
        in state: inout GameState,
        into outcome: inout AbilityOutcome
    ) {
        guard count > 0 else { return }
        var drawn = 0
        var ranOut = false

        for _ in 0..<count {
            guard !state[slot].deck.isEmpty else {
                ranOut = true
                break
            }
            let cardID = state[slot].deck.removeFirst()
            state[slot].hand.append(cardID)
            drawn += 1
        }

        if drawn > 0 {
            // The card itself stays hidden: the journal never leaks a draw.
            outcome.lines.append("Drew \(drawn) card\(drawn == 1 ? "" : "s").")
        }
        if ranOut {
            outcome.lines.append("Could not draw from an empty deck.")
            outcome.deckedOut = slot
        }
    }

    /// Puts cards from hand back on top of the deck.
    ///
    /// The player picks. When no pick reaches the engine — a headless replay, or
    /// the AI, neither of which can be shown a hand picker — the most recently
    /// drawn cards go back, because in this pool the step always follows a draw
    /// and those are the cards the ability just handed over.
    private func placeOnDeck(
        _ count: Int,
        context: AbilityContext,
        in state: inout GameState,
        into outcome: inout AbilityOutcome
    ) {
        let slot = context.controller
        guard count > 0 else { return }
        guard !state[slot].hand.isEmpty else {
            outcome.lines.append("Had no cards in hand to place on top of the deck.")
            return
        }

        var chosen = Array(Set(context.handSelection.filter { state[slot].hand.indices.contains($0) }))
        if chosen.count > count { chosen = Array(chosen.prefix(count)) }
        if chosen.count < count {
            let fallback = state[slot].hand.indices
                .reversed()
                .filter { !chosen.contains($0) }
                .prefix(count - chosen.count)
            chosen.append(contentsOf: fallback)
        }

        // Highest index first, so each removal leaves the rest still valid.
        var moved = 0
        for index in chosen.sorted(by: >) where state[slot].hand.indices.contains(index) {
            let cardID = state[slot].hand.remove(at: index)
            state[slot].deck.insert(cardID, at: 0)
            moved += 1
        }

        if moved > 0 {
            outcome.lines.append("Placed \(moved) card\(moved == 1 ? "" : "s") from hand on top of the deck.")
        }
    }

    /// Rests the card the ability is printed on. A Leader has no in-play
    /// identity, so its own flag carries it.
    private func rest(
        context: AbilityContext,
        in state: inout GameState,
        into outcome: inout AbilityOutcome
    ) {
        switch context.source {
        case .leader:
            state[context.controller].leaderIsRested = true
        case .character(let id):
            guard state[context.controller].character(id: id) != nil else {
                outcome.lines.append("\(context.card.name) had already left the board and could not rest.")
                return
            }
            state[context.controller].rest(characterID: id)
        }
        outcome.lines.append("\(context.card.name) rested.")
    }

    // MARK: - Targeting

    /// The cards an effect's scope actually reaches, given the choice the
    /// player made.
    ///
    /// Scopes that name a whole group resolve themselves. Scopes that ask for a
    /// choice resolve to the chosen card, and to nothing at all when no legal
    /// choice reached the engine — which is honest, and is reported.
    func targets(
        for scope: AbilityTargetScope,
        context: AbilityContext,
        in state: GameState
    ) -> [BoardTarget] {
        switch scope {
        case .none:
            return []

        case .selfCard:
            guard let id = context.source.characterID,
                  state[context.controller].character(id: id) != nil else { return [] }
            return [BoardTarget(slot: context.controller, id: id)]

        case .ownTeam:
            return state[context.controller].characters.map {
                BoardTarget(slot: context.controller, id: $0.id)
            }

        case .allCharacters:
            // Both sides. "K.O. all Characters" is printed without an owner,
            // and it means the board, not your half of it.
            return PlayerSlot.allCases.flatMap { slot in
                state[slot].characters.map { BoardTarget(slot: slot, id: $0.id) }
            }

        case .anyCharacter, .friendlyCharacter, .opposingCharacter,
             .restedCharacter, .leaderOrCharacter:
            guard let targetID = context.targetID else { return [] }
            let legal = AbilityResolver.candidates(for: scope, controller: context.controller, in: state)
            return legal.filter { $0.id == targetID }
        }
    }

    /// Every card a scope would accept as a choice right now.
    ///
    /// `.leaderOrCharacter` offers characters only: a Leader has no in-play
    /// identity to name, and nothing in the implemented ruleset has a Leader
    /// attack or block, so the half of that scope the engine can honour is the
    /// character half. An ability aimed at a Leader records itself as unapplied
    /// rather than pretending.
    static func candidates(
        for scope: AbilityTargetScope,
        controller: PlayerSlot,
        in state: GameState
    ) -> [BoardTarget] {
        func bodies(_ slot: PlayerSlot) -> [BoardTarget] {
            state[slot].characters.map { BoardTarget(slot: slot, id: $0.id) }
        }

        switch scope {
        case .friendlyCharacter:
            return bodies(controller)
        case .opposingCharacter:
            return bodies(controller.opposing)
        case .anyCharacter, .leaderOrCharacter:
            return bodies(controller) + bodies(controller.opposing)
        case .restedCharacter:
            return PlayerSlot.allCases.flatMap { slot in
                state[slot].characters.filter(\.isRested).map { BoardTarget(slot: slot, id: $0.id) }
            }
        case .none, .allCharacters, .selfCard, .ownTeam:
            return []
        }
    }

    // MARK: - Costs

    /// The characters that would pay a cost's trash requirement, in board order.
    ///
    /// Which of several eligible bodies pays is immaterial to the rules, so the
    /// engine takes them in the order they were summoned. Deterministic by
    /// construction, which is what keeps a seeded game replaying identically.
    ///
    /// - Returns: fewer than `cost.trashOwnCharacters` when the cost cannot be
    ///   paid, so the caller compares counts rather than handling an optional.
    static func sacrifices(
        for cost: AbilityCost,
        controller: PlayerSlot,
        in state: GameState,
        database: CardDatabase
    ) -> [UUID] {
        guard cost.trashOwnCharacters > 0 else { return [] }
        return state[controller].characters
            .filter { character in
                guard let card = database.card(id: character.cardID) else { return false }
                if let trait = cost.trashTrait, !card.traits.contains(trait) { return false }
                if let minimum = cost.trashMinimumPower,
                   character.effectivePower(of: card) < minimum { return false }
                return true
            }
            .prefix(cost.trashOwnCharacters)
            .map(\.id)
    }

    // MARK: - Wording

    /// Records a line when a scope reached nothing, and reports whether the
    /// effect should go ahead. Keeps every scoped case from repeating the guard.
    private func report(
        _ hits: [BoardTarget],
        effect: AbilityEffect,
        into outcome: inout AbilityOutcome
    ) -> Bool {
        guard hits.isEmpty else { return true }
        outcome.lines.append("No card was in range, so \"\(effect.summary)\" did nothing.")
        return false
    }

    /// Comma-separated printed names, falling back to the collector number if
    /// the pool changed underneath a game in progress.
    private func list(_ hits: [BoardTarget], in state: GameState) -> String {
        let names = hits.map { hit -> String in
            guard let character = state[hit.slot].character(id: hit.id) else { return "a character" }
            return database.card(id: character.cardID)?.name ?? character.cardID
        }
        return names.isEmpty ? "Nothing" : names.joined(separator: ", ")
    }

    private func signed(_ amount: Int) -> String {
        amount >= 0 ? "+\(amount)" : "\(amount)"
    }
}

// MARK: - Summon requirements

extension Card {

    /// Whether the card prints "Cannot be summoned normally".
    ///
    /// These are the Summon Requirements cards: they only ever reach the board
    /// through the requirement printed alongside, never by being played from
    /// hand for their cost. `GameEngine.planPlay` refuses the normal summon on
    /// the strength of this, which is the whole of what the flag is for.
    var cannotBeSummonedNormally: Bool {
        abilities.contains { $0.effects.contains(.cannotBeSummonedNormally) }
    }
}
