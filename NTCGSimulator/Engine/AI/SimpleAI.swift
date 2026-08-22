//
//  SimpleAI.swift
//  NTCGSimulator
//
//  The computer opponent. A greedy one-ply heuristic: it scores only the moves
//  the engine already says are legal, takes the best one, and never searches
//  ahead. It adds no randomness of its own, so a seeded game against the AI
//  still replays exactly.
//

import Foundation

// MARK: - Tuning

/// Every number the heuristic leans on, gathered in one place because this is
/// the part of the app most likely to be re-balanced. Nothing outside this file
/// reads them, so a tuning pass is a single-block edit.
private enum Tuning {

    // Valuing a body ------------------------------------------------------

    /// Printed health is worth a little less than printed power: damage heals at
    /// end of turn, so health mostly buys survival through one exchange.
    static let healthWeight = 0.75

    /// Printed damage is the only stat that actually shortens the game, so it
    /// carries more weight per point than raw power.
    static let damageWeight = 1.5

    /// How much worse losing your own body is than killing theirs. At `1.0` a
    /// one-for-one trade is worth exactly nothing, which is the honest value in
    /// a ruleset where battle damage heals every turn. Raising it makes the AI
    /// trade-averse — but be careful: much above `1.0` and every even exchange
    /// scores negative, both boards fill to the five-character cap and neither
    /// side ever attacks again, which turns most games into a deck-out.
    static let ownLossWeight = 1.0

    // Main phase ----------------------------------------------------------

    /// A play must beat this to be worth making at all.
    static let playFloor = 0.0

    /// Flat credit on every summon, on top of what the body is worth. Summoning
    /// costs nothing, so a character in the row is free value however small it
    /// is: this is set above the best a Support card can ever score, which is
    /// what makes the AI empty its bodies onto the board before it spends a
    /// single chakra.
    static let summonBase = 8.0

    /// Summon-zone cards are free to place and have no modelled effect, so they
    /// are worth a token amount — enough to be played when nothing else is,
    /// never over a body or a Support card.
    static let summonZoneValue = 1.5

    /// What a Support card is worth for simply staying on the board.
    static let supportBase = 2.0

    /// Printed cost stands in for the size of a Support card's effect: the pool
    /// prices the bigger continuous effects higher, and chakra spent this turn
    /// cannot be saved for the next one, so the AI buys the biggest it can pay
    /// for rather than the cheapest.
    static let supportEffectWeight = 0.6

    /// Charge per Support slot already taken. The row holds five, and stacking
    /// another continuous effect on a board that already has several is worth
    /// steadily less.
    static let supportSlotDecay = 0.5

    /// What playing a card as a jutsu costs in cards: the card itself, gone to
    /// the Trash. Negative, and below `playFloor`, because the engine resolves a
    /// support line to the journal rather than to the board.
    static let jutsuCardLoss = -1.0

    /// What one chakra is worth when weighing a purchase against a cheaper one.
    static let chakraWeight = 0.4

    // Abilities -----------------------------------------------------------

    /// What an extra card in hand is worth. Comfortably above `playFloor`, so a
    /// drawing ability is activated every turn it safely can be.
    static let drawValue = 2.5

    /// What a draw that is handed straight back is worth.
    ///
    /// The pool's one drawing box prints "draw 1 card and place 1 card from your
    /// hand on top of your deck", so no card is gained: what it buys is a look
    /// at the top of the deck and a card swapped for it. Small, but above
    /// `playFloor`, because the box costs nothing and a free ability left unused
    /// is a wasted turn.
    static let filterValue = 0.5

    /// Cards that must be left in the deck before an ability draw is worth
    /// taking. Below this the deck-out clock matters more than the card does.
    static let deckOutMargin = 5

    /// Credit for pointing a power bonus at a character that is about to attack.
    /// It is only paid when the bonus actually changes a trade — power that
    /// kills nothing expires with the turn having bought nothing at all.
    static let empowerBase = 0.5

    /// Credit for taking power off an opposing body at all.
    static let weakenBase = 0.5

    /// Extra credit per point of power actually removed, which is what makes the
    /// AI aim a weaken at the biggest thing on the other side of the board when
    /// no trade swings either way.
    static let weakenThreatWeight = 0.2

    // Combat --------------------------------------------------------------

    /// Value of a single point of Leader life, in the same units as a body's
    /// worth. Kept low so a real trade beats chip damage.
    static let lifeWeight = 1.2

    /// Below this much life, life becomes the scarce resource and face damage is
    /// worth `closingMultiplier` times as much — both when attacking and blocking.
    static let closingLife = 5

    /// How much more a point of life is worth once a Leader is inside
    /// `closingLife`. This is what makes the AI push for the kill, and what makes
    /// it start blocking hits it would otherwise wave through.
    static let closingMultiplier = 2.0

    /// Flat credit on every attack, for the fact that attacking is not free to
    /// answer: the defender must exert a blocker to deal with it, and a turn
    /// spent standing still is a turn closer to running out of deck. It is what
    /// tips a level exchange from "not worth it" into "worth it".
    static let initiativeBonus = 1.0

    /// An attack must beat this to be declared.
    static let attackFloor = 0.0

    /// The gentle bar for declaring an attack. Marginal swings — a one-damage
    /// poke at a full-life Leader, an even trade — fall below it, which is how
    /// gentle "skips some attacks" without needing randomness. Measured over 60
    /// mirror games it hands the standard AI a win rate near 85%; raise it to
    /// make gentle more passive still, lower it to close the gap.
    static let gentleAttackFloor = 2.5

    /// Blocking exerts the blocker, which costs it an attack next turn. Small,
    /// but enough to break ties towards taking the hit.
    static let blockRestCost = 0.5

    /// Sentinel for "this line of play loses the game outright". Any real score
    /// beats it, so it doubles as the score for an unresolvable option.
    static let lethalPenalty = -1000.0

    // Mulligan ------------------------------------------------------------

    /// Bodies a keepable opening hand needs. Summoning is free, so the only
    /// thing that stops a hand developing is having nothing to develop with.
    static let mulliganBodies = 2
}

// MARK: - Body

/// A character in play paired with the card it was summoned from. The engine
/// deliberately keeps printed values in `CardDatabase`, so every heuristic that
/// compares two bodies needs both halves together.
private struct Body {

    let character: CharacterInPlay
    let card: Card

    /// A power change the heuristic is weighing but has not made — the ability
    /// it is about to activate. Zero for a body as it actually stands.
    var pendingBonus: Int = 0

    /// The character as it would be with the pending change applied, so power is
    /// always computed by the model rather than re-derived here.
    private var projected: CharacterInPlay {
        var copy = character
        copy.powerBonus += pendingBonus
        return copy
    }

    /// Power this body fights with: printed, plus any modifier already on the
    /// board, plus whatever is being weighed up. Floored at zero exactly the way
    /// `GameEngine.resolveBattle` floors it.
    var power: Int { projected.effectivePower(of: card) }

    /// Leader damage dealt by an unblocked swing. No modelled effect changes it.
    var damage: Int { max(0, card.damage ?? 0) }

    /// Health left before this body is sent to the Trash.
    var remainingHealth: Int { character.remainingHealth(of: card) }

    /// What losing this body would cost, in heuristic units. Printed values
    /// only: a temporary bonus expires with the turn, so it is not lost with the
    /// character.
    var value: Double { bodyValue(of: card) }

    /// The same body with a power change applied, for asking what an ability
    /// would buy before it is spent.
    func adjusted(by delta: Int) -> Body {
        var copy = self
        copy.pendingBonus += delta
        return copy
    }
}

/// Scores a card as a body: power, plus discounted health, plus weighted damage.
/// Used both for "what should I summon" and "what is this worth in a trade", so
/// the two decisions can never disagree about which character is better.
private func bodyValue(of card: Card) -> Double {
    let power = Double(max(0, card.power ?? 0))
    let health = Double(max(0, card.health ?? 0))
    let damage = Double(max(0, card.damage ?? 0))
    return power + health * Tuning.healthWeight + damage * Tuning.damageWeight
}

// MARK: - Simple AI

/// A greedy heuristic opponent.
///
/// The board drives it by calling ``chooseAction(engine:slot:)`` in a loop and
/// applying whatever comes back until it returns `nil`. Each call answers one
/// question and one only:
///
/// - **Mulligan** — keep a hand with bodies in it, otherwise take the redraw.
/// - **Main phase** — develop first, then spend. Repeat calls put every body in
///   hand on the board, buy Support cards with the chakra that is left, and fit
///   the printed ability boxes on the Leader and on its own characters in
///   around them.
/// - **Attack phase** — take lethal if the maths is there; otherwise swing with
///   whichever character has the best expected outcome, and stop swinging once
///   the remaining attacks would only lose bodies.
/// - **Blocking** — answer with a "During Your Opponent's Attack" box where one
///   is worth using, otherwise block when the exchange is favourable or the hit
///   is lethal, otherwise take it on the Leader.
///
/// The economy the main phase assumes is the corrected one: summoning a
/// Character or an EX Character costs nothing, so board presence is almost
/// always right and dominates the scoring — an empty Characters row with a body
/// in hand is a mistake the weights make impossible. Chakra buys exactly two
/// things, a Support card and a card played as a jutsu through its support line,
/// and it does not bank: every Refresh stands all five back up, so chakra left
/// unspent is lost. That makes a Support card, which stays in its slot, the
/// natural home for it, and a jutsu — which `GameEngine` resolves to the journal
/// rather than to the board — a purchase the heuristic never makes.
///
/// Scoring is otherwise deliberately shallow. The one place it looks a move
/// ahead is the attack: each swing is weighed against the best block the
/// defender could make, which is enough to stop the AI running characters into
/// obvious walls without paying for a search. Everything else is a weighted sum,
/// and every weight lives in `Tuning` above.
///
/// The weights are not arbitrary — they were fitted by running mirror matches.
/// The setting that matters most is `Tuning.ownLossWeight`: push it far enough
/// above `1.0` and both AIs refuse every even trade, fill the board to the
/// five-character cap and grind every game out to a deck-out. Re-run a batch of
/// games after touching it and check that most still end on life.
///
/// The AI is also strictly defensive: whatever the heuristic picks is checked
/// against `GameEngine.legalActions(for:)` before it is returned, so a tuning
/// mistake can produce a bad move but never an illegal one.
struct SimpleAI {

    /// How hard the opponent tries.
    enum Difficulty: String, CaseIterable, Identifiable, Codable, Hashable {

        /// Deliberately weaker: keeps any opening hand, spends as little as it
        /// can and puts its weakest cards down rather than its best, skips
        /// marginal attacks, answers an attack with a body or not at all rather
        /// than with a response ability, and only blocks to stop a lethal swing.
        case gentle

        /// The full heuristic.
        case standard

        var id: String { rawValue }

        var title: String {
            switch self {
            case .gentle:   return "Gentle"
            case .standard: return "Standard"
            }
        }

        /// One-line explanation for a difficulty picker.
        var detail: String {
            switch self {
            case .gentle:   return "Plays cheaply and passes up risky attacks."
            case .standard: return "Trades efficiently and pushes for lethal."
            }
        }
    }

    var difficulty: Difficulty = .standard

    // MARK: Entry point

    /// The one action the AI wants to take right now, or `nil` when it has
    /// nothing left to do and the board should stop asking.
    ///
    /// - Parameters:
    ///   - engine: the live game. Never mutated here — the caller applies the
    ///     returned action so every move still passes the engine's validation.
    ///   - slot: the side the AI is playing.
    func chooseAction(engine: GameEngine, slot: PlayerSlot) -> GameAction? {
        let legal = engine.legalActions(for: slot)
        guard !legal.isEmpty else { return nil }

        guard let candidate = decide(engine: engine, slot: slot, legal: legal) else { return nil }

        // The heuristic is never trusted over the rules: an action the engine
        // would refuse is swapped for a safe pass rather than sent and rejected.
        guard Set(legal).contains(candidate) else { return fallback(in: legal) }
        return candidate
    }

    // MARK: Routing

    /// Works out which question is actually on the table, and hands it to the
    /// matching heuristic. Order matters: the mulligan gate and a declared
    /// attack both outrank whose turn it is.
    private func decide(engine: GameEngine, slot: PlayerSlot, legal: [GameAction]) -> GameAction? {
        if engine.isAwaitingMulligan {
            guard !engine.side(slot).mulliganResolved else { return nil }
            return mulliganAction(engine: engine, slot: slot)
        }

        if engine.pendingAttack != nil {
            // While an attack is pending the attacker may only concede, so the
            // AI simply waits unless the block decision belongs to it.
            guard engine.blockingPlayer == slot else { return nil }

            // A declared attack is the window a "During Your Opponent's Attack"
            // box opens in, and the engine offers those here alongside the
            // blocks. Answering with a card beats answering with a body — a
            // blocker is exerted for the privilege — so an activation worth
            // making is taken first, and the block decision is still waiting on
            // the next call. Gentle passes them up, as it passes up all but the
            // blocks that keep it alive.
            if difficulty != .gentle,
               let response = bestActivation(engine: engine, slot: slot, legal: legal) {
                return response.action
            }
            return blockAction(engine: engine, slot: slot, legal: legal)
        }

        guard engine.currentPlayer == slot else { return nil }

        switch engine.phase {
        case .main:
            return mainAction(engine: engine, slot: slot, legal: legal)
        case .attack:
            return attackAction(engine: engine, slot: slot, legal: legal)
        case .end:
            return .endTurn
        case .refresh, .draw:
            // These resolve inside the engine and never idle waiting on input.
            return nil
        }
    }

    /// A harmless legal move for the impossible case where the heuristic picked
    /// something the engine would refuse. Conceding is never a fallback — losing
    /// the game is a worse failure than passing the turn.
    private func fallback(in legal: [GameAction]) -> GameAction? {
        let permitted = Set(legal)
        for action in [GameAction.declareBlock(blockerID: nil), .mulligan(false), .endPhase, .endTurn]
        where permitted.contains(action) {
            return action
        }
        return nil
    }

    // MARK: Mulligan

    /// Keeps a hand it can develop from, redraws one it cannot.
    ///
    /// Summoning is free, so printed cost says nothing about how fast a hand
    /// starts — what matters is whether there are bodies in it. A hand of
    /// Support cards can spend chakra every turn and still never put a character
    /// in the row, so it goes back.
    private func mulliganAction(engine: GameEngine, slot: PlayerSlot) -> GameAction {
        guard difficulty != .gentle else { return .mulligan(false) }

        let hand = engine.side(slot).hand.compactMap { engine.card(for: $0) }
        guard !hand.isEmpty else { return .mulligan(false) }

        let bodies = hand.filter { $0.type.isBody }.count
        return .mulligan(bodies < Tuning.mulliganBodies)
    }

    // MARK: Main phase

    /// Develops the board, spends what chakra is left, and works the printed
    /// ability boxes in at the point in the turn where they do the most good.
    /// The board calls back after every move, so a turn empties the hand one
    /// card at a time.
    ///
    /// The order is deliberate. An untargeted ability — a draw, a heal — goes
    /// first, because a card drawn now can still be summoned this turn. A
    /// targeted one goes last, once every free summon is already on the board,
    /// so it picks from the best set of characters it will have all turn.
    private func mainAction(engine: GameEngine, slot: PlayerSlot, legal: [GameAction]) -> GameAction {
        let activation = bestActivation(engine: engine, slot: slot, legal: legal)

        if let activation, !activation.needsTarget { return activation.action }
        if let play = bestPlay(engine: engine, slot: slot, legal: legal) { return play }
        if let activation { return activation.action }

        return .endPhase
    }

    /// The best card to play right now, or `nil` when nothing left in hand is
    /// worth the chakra it would cost.
    private func bestPlay(engine: GameEngine, slot: PlayerSlot, legal: [GameAction]) -> GameAction? {
        let hand = engine.side(slot).hand
        var best: (action: GameAction, score: Double, cost: Int)?

        for action in legal {
            guard case .playCard(let handIndex, let asJutsu) = action,
                  hand.indices.contains(handIndex),
                  let card = engine.card(for: hand[handIndex]) else { continue }

            let score = playScore(card: card, asJutsu: asJutsu, engine: engine, slot: slot)
            guard score > Tuning.playFloor else { continue }

            let cost = ChakraCost.toPlay(card, asJutsu: asJutsu)
            guard let current = best else {
                best = (action, score, cost)
                continue
            }
            // Gentle spends as little as it can and leaves its best cards in
            // hand; standard simply takes the highest score.
            let improves = difficulty == .gentle
                ? (cost, score) < (current.cost, current.score)
                : score > current.score
            if improves { best = (action, score, cost) }
        }

        return best?.action
    }

    /// Rates one play.
    ///
    /// The row cap, the one-EX rule and the five Support slots are all the
    /// engine's business: only plays it has already declared legal reach this,
    /// so the score is purely "how much do I want this", never "may I".
    private func playScore(card: Card, asJutsu: Bool, engine: GameEngine, slot: PlayerSlot) -> Double {
        guard !asJutsu else { return jutsuScore(card: card) }

        switch card.type {
        case .character, .exCharacter:
            // Free, and the only thing on the board that wins games. `summonBase`
            // puts every body above every priced play, so the AI develops first
            // and shops afterwards.
            return Tuning.summonBase + bodyValue(of: card)

        case .support:
            return supportScore(card: card, engine: engine, slot: slot)

        case .summon:
            return Tuning.summonZoneValue

        case .leader, .chakra:
            // Never playable from hand, so this is unreachable — scored below
            // the floor rather than trusted not to happen.
            return Tuning.lethalPenalty
        }
    }

    /// Rates a Support card, the one lasting thing chakra buys.
    ///
    /// Chakra does not bank — every Refresh stands all five back up — so chakra
    /// left over at the end of a turn is simply lost, and there is no reason to
    /// hold it. The printed cost stands in for the size of the continuous
    /// effect, and each slot already taken makes the next card worth a little
    /// less.
    private func supportScore(card: Card, engine: GameEngine, slot: PlayerSlot) -> Double {
        let filled = engine.side(slot).support.filter { $0 != nil }.count
        let effect = Double(max(0, card.cost ?? 0)) * Tuning.supportEffectWeight
        return Tuning.supportBase + effect - Double(filled) * Tuning.supportSlotDecay
    }

    /// Rates playing a card through its support line.
    ///
    /// A jutsu spends the card and the chakra together, and `GameEngine`
    /// resolves the printed line to the journal rather than to the board, so
    /// nothing lands that a heuristic could bank on. Against a Support card of
    /// the same price — which stays in its slot for the rest of the game — the
    /// one-shot is the worse purchase every time, so this sits below
    /// `Tuning.playFloor` and the AI never chooses it. The two exemptions the
    /// strategy allows, a jutsu that finishes the opposing Leader and one that
    /// saves a character from a trade, are only measurable once jutsu actually
    /// move the board; their credit belongs here the day they do.
    private func jutsuScore(card: Card) -> Double {
        let cost = Double(ChakraCost.toPlay(card, asJutsu: true))
        return Tuning.jutsuCardLoss - cost * Tuning.chakraWeight
    }

    // MARK: Abilities

    /// One activation the engine is offering, resolved back to the printed box
    /// behind it.
    ///
    /// `GameAction.useAbility` carries only a source, an index into the card's
    /// printed boxes and a target, which is all the engine needs to validate it.
    /// The heuristic needs the box itself before it can have any opinion, so it
    /// is looked up once here rather than at every scoring step.
    private struct Offer {
        let action: GameAction
        let source: AbilitySource
        let card: Card
        let ability: CardAbility
        let targetID: UUID?
    }

    /// An activation the heuristic has decided is worth making, and whether it
    /// names a card — which is what decides where in the turn it is taken.
    private struct Activation {
        let action: GameAction
        let needsTarget: Bool
    }

    /// Every activation on the table right now that is worth weighing.
    ///
    /// They are read out of the list the engine is already offering — which
    /// folds in `GameEngine.legalAbilities(for:)` in both the main phase and the
    /// pending-attack window — so an activation the engine would refuse can
    /// never reach the scorer, and the AI cannot desync from the rules by
    /// building its own candidate list.
    ///
    /// One class is filtered out here rather than scored: a box that spends
    /// nothing and is not limited to once a turn. The board asks the AI for one
    /// move at a time and applies whatever comes back, so an activation the
    /// heuristic likes and that never runs out would be chosen again on the very
    /// next call and the turn would never end. Every activated box in the
    /// shipped pool either costs chakra or prints "Once Per Turn", so nothing
    /// playable is lost — but a future card that costs nothing at all cannot
    /// hang the game.
    private func offers(engine: GameEngine, slot: PlayerSlot, legal: [GameAction]) -> [Offer] {
        legal.compactMap { action in
            guard case .useAbility(let source, let index, let targetID) = action,
                  let card = engine.abilityCard(for: source, by: slot),
                  card.abilities.indices.contains(index) else { return nil }

            let ability = card.abilities[index]
            guard !ability.cost.isFree || ability.oncePerTurn else { return nil }

            return Offer(
                action: action,
                source: source,
                card: card,
                ability: ability,
                targetID: targetID
            )
        }
    }

    /// The best activation on offer, or `nil` when nothing on the board has
    /// anything worth doing. Chakra does not bank, so an ability left unused is
    /// usually a wasted turn — the only reasons to skip one are that it buys
    /// nothing right now, or that its cost is needed elsewhere.
    private func bestActivation(engine: GameEngine, slot: PlayerSlot, legal: [GameAction]) -> Activation? {
        let reserved = reservedChakra(engine: engine, slot: slot, legal: legal)
        let ready = engine.side(slot).readyChakra

        var best: (offer: Offer, score: Double)?
        for offer in offers(engine: engine, slot: slot, legal: legal) {
            // Chakra promised to a purchase is not available to an ability. A
            // Support card stays on the board for the rest of the game and a
            // jutsu resolves the moment it is played; a power bonus expires with
            // the turn, so it is the ability that gives way.
            guard ready - offer.ability.cost.chakra >= reserved else { continue }

            let score = activationScore(offer, engine: engine, slot: slot)
            guard score > Tuning.playFloor else { continue }

            guard let current = best else {
                best = (offer, score)
                continue
            }
            if score > current.score { best = (offer, score) }
        }

        guard let best else { return nil }
        return Activation(
            action: best.offer.action,
            needsTarget: best.offer.ability.target.needsPlayerChoice
        )
    }

    /// The most chakra the AI still intends to spend on a card this turn.
    ///
    /// The main phase empties the hand one card at a time, so the purchase it
    /// wants may be several calls away. Holding back the largest single price it
    /// would pay is enough: anything cheaper is still affordable underneath it,
    /// and nothing more elaborate is worth doing for a five-chakra economy.
    private func reservedChakra(engine: GameEngine, slot: PlayerSlot, legal: [GameAction]) -> Int {
        let hand = engine.side(slot).hand
        var reserved = 0

        for action in legal {
            guard case .playCard(let handIndex, let asJutsu) = action,
                  hand.indices.contains(handIndex),
                  let card = engine.card(for: hand[handIndex]) else { continue }

            let cost = ChakraCost.toPlay(card, asJutsu: asJutsu)
            guard cost > 0,
                  playScore(card: card, asJutsu: asJutsu, engine: engine, slot: slot) > Tuning.playFloor
            else { continue }

            reserved = max(reserved, cost)
        }
        return reserved
    }

    /// Rates one activation, in the same units as a play: what its printed steps
    /// are worth, less what they cost to set off.
    private func activationScore(_ offer: Offer, engine: GameEngine, slot: PlayerSlot) -> Double {
        effectsScore(offer, engine: engine, slot: slot)
            - Double(offer.ability.cost.chakra) * Tuning.chakraWeight
            - sacrificeCost(offer, engine: engine, slot: slot)
    }

    /// What the bodies a cost would trash are worth, valued exactly as losing
    /// them in a trade is.
    ///
    /// The engine picks which of several eligible characters pays, so the same
    /// static helper it uses is asked here — otherwise the heuristic would price
    /// a cost the board then charges to a different character.
    private func sacrificeCost(_ offer: Offer, engine: GameEngine, slot: PlayerSlot) -> Double {
        guard offer.ability.cost.trashOwnCharacters > 0 else { return 0 }

        return AbilityResolver
            .sacrifices(
                for: offer.ability.cost,
                controller: slot,
                in: engine.state,
                database: engine.database
            )
            .compactMap { body(engine.side(slot).character(id: $0), engine: engine) }
            .reduce(0) { $0 + $1.value * Tuning.ownLossWeight }
    }

    /// What the printed steps of one box are worth.
    ///
    /// Which cards a step reaches is asked of `AbilityResolver` rather than
    /// worked out again here, so the heuristic is always valuing the cards the
    /// board would actually change — including the scopes that resolve
    /// themselves, like the "K.O. all Characters" boxes that hit both sides.
    private func effectsScore(_ offer: Offer, engine: GameEngine, slot: PlayerSlot) -> Double {
        let resolver = AbilityResolver(database: engine.database)
        let context = AbilityContext(
            source: offer.source,
            controller: slot,
            card: offer.card,
            ability: offer.ability,
            targetID: offer.targetID,
            // The AI is never shown a hand picker, so it nominates nothing and
            // the resolver falls back to the cards just drawn.
            handSelection: []
        )

        var score = cardFlowScore(offer.ability.effects, engine: engine, slot: slot)
        for effect in offer.ability.effects {
            score += value(
                of: effect,
                source: offer.source,
                engine: engine,
                slot: slot,
                hits: { resolver.targets(for: $0, context: context, in: engine.state) }
            )
        }
        return score
    }

    /// Rates one printed step.
    ///
    /// A step the engine cannot resolve is worth exactly nothing, which is the
    /// whole of what `.unimplemented` means: the AI must not pay chakra for text
    /// the app will only write to the journal.
    private func value(
        of effect: AbilityEffect,
        source: AbilitySource,
        engine: GameEngine,
        slot: PlayerSlot,
        hits: (AbilityTargetScope) -> [BoardTarget]
    ) -> Double {
        switch effect {
        case .drawCards, .placeFromHandOnDeck:
            // Weighed together by `cardFlowScore`: a draw handed straight back
            // is not a card gained, and neither half means much alone.
            return 0

        case .gainLife(let amount):
            return Double(max(0, amount)) * Tuning.lifeWeight * urgency(of: slot, engine: engine)

        case .loseLife(let amount):
            let life = engine.side(slot).life
            guard max(0, amount) < life else { return Tuning.lethalPenalty }
            return -Double(max(0, amount)) * Tuning.lifeWeight * urgency(of: slot, engine: engine)

        case .buffPower(let amount, let scope):
            return hits(scope).reduce(0) {
                $0 + powerChangeValue(on: $1, amount: amount, engine: engine, slot: slot)
            }

        case .buffDamage(let amount, let scope):
            return hits(scope).reduce(0) {
                $0 + damageChangeValue(on: $1, amount: amount, engine: engine, slot: slot)
            }

        case .grantRush(let scope):
            return hits(scope).reduce(0) { $0 + rushValue(on: $1, engine: engine, slot: slot) }

        case .knockOut(let scope):
            return hits(scope).reduce(0) { $0 + knockOutValue(on: $1, engine: engine, slot: slot) }

        case .cannotAttackNextTurn(let scope):
            return hits(scope).reduce(0) { $0 + attackBanValue(on: $1, engine: engine, slot: slot) }

        case .restSelf:
            return restValue(source: source, engine: engine, slot: slot)

        case .flipAllChakraFaceUp:
            return Double(engine.side(slot).restedChakra) * Tuning.chakraWeight

        case .cannotBeSummonedNormally:
            // A standing rule the board enforces when the card is played, not
            // something an activation buys.
            return 0

        case .unimplemented:
            return 0
        }
    }

    /// Rates the cards a box moves between deck and hand.
    ///
    /// The two steps are weighed together because the pool prints them together:
    /// a draw paired with a card placed back gains nothing, and scoring the
    /// halves apart would either talk the AI into a free swap it values as a
    /// card or out of one it should take. An ability draw from an empty deck now
    /// loses the game — the engine finishes it exactly as the turn draw does —
    /// so a deck too short to pay for the step is refused outright.
    private func cardFlowScore(_ effects: [AbilityEffect], engine: GameEngine, slot: PlayerSlot) -> Double {
        var drawn = 0
        var returned = 0
        for effect in effects {
            switch effect {
            case .drawCards(let count):           drawn += max(0, count)
            case .placeFromHandOnDeck(let count):  returned += max(0, count)
            default:                               break
            }
        }
        guard drawn > 0 || returned > 0 else { return 0 }

        let deck = engine.side(slot).deck.count
        guard deck >= drawn else { return Tuning.lethalPenalty }

        let net = drawn - returned
        if net < 0 { return Double(net) * Tuning.drawValue }
        if net == 0 { return Tuning.filterValue }

        // A card gained is only worth having if the deck can spare it.
        guard deck > Tuning.deckOutMargin else { return 0 }
        return Double(net) * Tuning.drawValue
    }

    /// Rates a power change on one body, from the point of view of `slot`.
    ///
    /// Every power change in the pool expires during end-of-turn cleanup — the
    /// cleanup of the turn being spent right now — so none of them survives into
    /// the opponent's attack. That makes them attack-phase tools only, judged
    /// entirely on the combat that follows this main phase.
    private func powerChangeValue(
        on hit: BoardTarget,
        amount: Int,
        engine: GameEngine,
        slot: PlayerSlot
    ) -> Double {
        guard let target = body(at: hit, engine: engine) else { return 0 }
        let changed = target.adjusted(by: amount)

        if hit.slot == slot {
            // Ours: worth nothing at all on a body that is not going to attack.
            guard target.character.canAttack else { return 0 }

            let swing = engine.side(slot.opposing).characters
                .compactMap { body($0, engine: engine) }
                .map { exchange(ours: changed, theirs: $0) - exchange(ours: target, theirs: $0) }
                .max() ?? 0

            // Power that changes no trade bought nothing; power that cost us one
            // is charged for honestly.
            guard swing > 0 else { return swing }
            return Tuning.empowerBase + swing
        }

        // Theirs: it cannot blunt the swing back, so what it does is neuter a
        // blocker. The credit is the best trade it opens up for a character that
        // can attack this turn, plus a smaller amount for the raw power removed,
        // which is what aims a weaken at the biggest threat when no trade swings
        // either way — and what makes handing an opposing body power a mistake.
        let swing = engine.side(slot).attackers
            .compactMap { body($0, engine: engine) }
            .map { exchange(ours: $0, theirs: changed) - exchange(ours: $0, theirs: target) }
            .max() ?? 0

        let removed = Double(target.power - changed.power)
        return (amount < 0 ? Tuning.weakenBase : 0) + swing + removed * Tuning.weakenThreatWeight
    }

    /// Rates a damage change: straight life off the Leader the body attacks,
    /// worth more once that Leader is inside `closingLife`.
    private func damageChangeValue(
        on hit: BoardTarget,
        amount: Int,
        engine: GameEngine,
        slot: PlayerSlot
    ) -> Double {
        guard let target = body(at: hit, engine: engine), target.character.canAttack else { return 0 }
        let worth = Double(amount) * Tuning.lifeWeight * urgency(of: hit.slot.opposing, engine: engine)
        return hit.slot == slot ? worth : -worth
    }

    /// Rates granting Rush. It is worth the attack it unlocks and nothing more,
    /// so it is worth nothing on a body that could already swing.
    private func rushValue(on hit: BoardTarget, engine: GameEngine, slot: PlayerSlot) -> Double {
        guard let target = body(at: hit, engine: engine),
              target.character.summonedThisTurn,
              !target.character.isRested,
              !target.character.isBarredFromAttacking
        else { return 0 }

        let worth = Tuning.initiativeBonus
            + Double(target.damage) * Tuning.lifeWeight * urgency(of: hit.slot.opposing, engine: engine)
        return hit.slot == slot ? worth : -worth
    }

    /// Rates sending a body to the Trash. Ours are valued at the same discount a
    /// trade values them at, which is what makes a board wipe reaching both
    /// sides — the two "K.O. all Characters" boxes — a move the AI only makes
    /// when it is behind on bodies.
    private func knockOutValue(on hit: BoardTarget, engine: GameEngine, slot: PlayerSlot) -> Double {
        guard let target = body(at: hit, engine: engine) else { return 0 }
        return hit.slot == slot ? -target.value * Tuning.ownLossWeight : target.value
    }

    /// Rates holding a body back from attacking next turn: worth the swing it
    /// takes away, at the value of the life that swing would have cost.
    private func attackBanValue(on hit: BoardTarget, engine: GameEngine, slot: PlayerSlot) -> Double {
        guard let target = body(at: hit, engine: engine) else { return 0 }
        let worth = Double(target.damage) * Tuning.lifeWeight * urgency(of: hit.slot.opposing, engine: engine)
        return hit.slot == slot ? -worth : worth
    }

    /// Rates resting the card the box is printed on.
    ///
    /// On a character it costs the swing it was going to make, or — if it was
    /// never going to attack — the block it can no longer make. On a Leader it
    /// costs nothing: nothing in the implemented ruleset asks a Leader to attack
    /// or block, so `PlayerSide.leaderIsRested` is board state and no more.
    private func restValue(source: AbilitySource, engine: GameEngine, slot: PlayerSlot) -> Double {
        guard let characterID = source.characterID,
              let target = body(engine.side(slot).character(id: characterID), engine: engine)
        else { return 0 }

        guard !target.character.isRested else { return 0 }
        guard target.character.canAttack else { return -Tuning.blockRestCost }

        return -(Tuning.initiativeBonus
            + Double(target.damage) * Tuning.lifeWeight * urgency(of: slot.opposing, engine: engine))
    }

    /// How much a point of a side's life is worth right now: more once that
    /// Leader is close enough to losing for life to be the scarce resource.
    private func urgency(of slot: PlayerSlot, engine: GameEngine) -> Double {
        engine.side(slot).life <= Tuning.closingLife ? Tuning.closingMultiplier : 1.0
    }

    // MARK: Attack phase

    /// Declares the best remaining attack, or ends the phase once every
    /// remaining swing would only lose bodies. Lethal is checked first and
    /// overrides everything else, including the gentle handbrake.
    private func attackAction(engine: GameEngine, slot: PlayerSlot, legal: [GameAction]) -> GameAction {
        if let finisher = lethalAttack(engine: engine, slot: slot, legal: legal) { return finisher }

        let floor = difficulty == .gentle ? Tuning.gentleAttackFloor : Tuning.attackFloor
        var best: (action: GameAction, score: Double)?

        for action in legal {
            guard case .attack(let attackerID, let target) = action,
                  let attacker = body(engine.side(slot).character(id: attackerID), engine: engine)
            else { continue }

            let score = attackScore(engine: engine, slot: slot, attacker: attacker, target: target)
            guard score > floor else { continue }

            guard let current = best else {
                best = (action, score)
                continue
            }
            if score > current.score { best = (action, score) }
        }

        return best?.action ?? .endPhase
    }

    /// Checks whether this turn's swings finish the opposing Leader, and if so
    /// returns the swing to start with.
    ///
    /// The count is deliberately pessimistic: it assumes the defender blocks the
    /// biggest hitters, one blocker per attack, and only counts the damage that
    /// gets through regardless. If that residue still empties their life, going
    /// face is correct no matter what else the board offers.
    private func lethalAttack(engine: GameEngine, slot: PlayerSlot, legal: [GameAction]) -> GameAction? {
        let defending = engine.side(slot.opposing)
        guard defending.life > 0 else { return nil }

        let attackers = engine.side(slot).attackers.compactMap { body($0, engine: engine) }
        let damages = attackers.map(\.damage).filter { $0 > 0 }.sorted(by: >)
        guard !damages.isEmpty else { return nil }

        let absorbed = min(defending.readyCharacters.count, damages.count)
        let unstoppable = damages.dropFirst(absorbed).reduce(0, +)
        guard unstoppable >= defending.life else { return nil }

        // Lead with the hardest hitter so the biggest chunk lands even if the
        // defender finds an answer the heuristic did not model.
        var chosen: (action: GameAction, damage: Int)?
        for action in legal {
            guard case .attack(let attackerID, .leader) = action,
                  let attacker = attackers.first(where: { $0.character.id == attackerID })
            else { continue }

            guard let current = chosen else {
                chosen = (action, attacker.damage)
                continue
            }
            if attacker.damage > current.damage { chosen = (action, attacker.damage) }
        }
        return chosen?.action
    }

    /// Rates one declared attack: the outcome if it connects, discounted by the
    /// chance a blocker steps in front of it.
    ///
    /// Two observations keep this honest without a search:
    ///
    /// 1. A rational defender only blocks when the block *helps them*, so only
    ///    an exchange that comes out negative for the attacker is a block worth
    ///    fearing. A board full of bodies the attacker eats for free is not a
    ///    deterrent, and treating it as one is how a greedy AI talks itself into
    ///    never attacking at all.
    /// 2. Each ready blocker can only answer one swing. Judging every attack as
    ///    though it will be the blocked one badly over-states the risk, so the
    ///    worst case is weighted by how many blockers there are against how many
    ///    attacks are still to come.
    ///
    /// The result is an expected value between "connects" and "walks into the
    /// worst block", plus the flat initiative credit, which gives the required
    /// behaviour directly: clean kills and unanswerable face damage score high,
    /// a level trade is worth making, and a swing that simply feeds a waiting
    /// blocker scores negative and is skipped.
    private func attackScore(engine: GameEngine, slot: PlayerSlot, attacker: Body, target: AttackTarget) -> Double {
        let defending = engine.side(slot.opposing)

        let connects: Double
        switch target {
        case .leader:
            let urgency = defending.life <= Tuning.closingLife ? Tuning.closingMultiplier : 1.0
            connects = Double(attacker.damage) * Tuning.lifeWeight * urgency

        case .character(let targetID):
            guard let targeted = body(defending.character(id: targetID), engine: engine) else { return 0 }
            connects = exchange(ours: attacker, theirs: targeted)
        }

        let blockers = defending.readyCharacters.compactMap { body($0, engine: engine) }

        // The block the defender would most like to make. If none of them come
        // out ahead there is no deterrent, and the swing is judged on its own.
        let worstCase = blockers.map { exchange(ours: attacker, theirs: $0) }.min() ?? 0
        guard !blockers.isEmpty, worstCase < 0 else { return connects + Tuning.initiativeBonus }

        let swings = max(1, engine.side(slot).attackers.count)
        let likelihood = min(1.0, Double(blockers.count) / Double(swings))
        return connects * (1 - likelihood) + worstCase * likelihood + Tuning.initiativeBonus
    }

    // MARK: Blocking

    /// Answers a declared attack. Every block the engine offers is scored beside
    /// simply taking the hit, and the best is chosen; `legalActions` lists "take
    /// it" first, so an unimproved board takes the attack on the Leader.
    private func blockAction(engine: GameEngine, slot: PlayerSlot, legal: [GameAction]) -> GameAction {
        guard let pending = engine.pendingAttack,
              let attacker = body(
                engine.side(pending.attackingSlot).character(id: pending.attackerID),
                engine: engine
              )
        else { return .declareBlock(blockerID: nil) }

        // Gentle only ever interposes to stay alive, so the player's attacks
        // mostly connect.
        if difficulty == .gentle,
           !isLethal(attacker: attacker, target: pending.target, engine: engine, slot: slot) {
            return .declareBlock(blockerID: nil)
        }

        var best: (action: GameAction, score: Double)?
        for action in legal {
            guard case .declareBlock(let blockerID) = action else { continue }

            let score = blockScore(
                blockerID: blockerID,
                engine: engine,
                slot: slot,
                pending: pending,
                attacker: attacker
            )

            guard let current = best else {
                best = (action, score)
                continue
            }
            if score > current.score { best = (action, score) }
        }

        return best?.action ?? .declareBlock(blockerID: nil)
    }

    /// Whether letting this attack through ends the game.
    private func isLethal(attacker: Body, target: AttackTarget, engine: GameEngine, slot: PlayerSlot) -> Bool {
        guard target == .leader else { return false }
        return attacker.damage >= engine.side(slot).life
    }

    /// Rates one answer to a declared attack. `nil` is the cost of taking it —
    /// life for a Leader swing, or the exchange the targeted character loses —
    /// and every other option is the exchange that blocker would fight, minus
    /// the small cost of being exerted.
    private func blockScore(
        blockerID: UUID?,
        engine: GameEngine,
        slot: PlayerSlot,
        pending: PendingAttack,
        attacker: Body
    ) -> Double {
        guard let blockerID else {
            switch pending.target {
            case .leader:
                let life = engine.side(slot).life
                guard attacker.damage < life else { return Tuning.lethalPenalty }
                let urgency = life <= Tuning.closingLife ? Tuning.closingMultiplier : 1.0
                return -Double(attacker.damage) * Tuning.lifeWeight * urgency

            case .character(let targetID):
                guard let targeted = body(engine.side(slot).character(id: targetID), engine: engine) else { return 0 }
                return exchange(ours: targeted, theirs: attacker)
            }
        }

        guard let blocker = body(engine.side(slot).character(id: blockerID), engine: engine) else {
            return Tuning.lethalPenalty
        }
        return exchange(ours: blocker, theirs: attacker) - Tuning.blockRestCost
    }

    // MARK: Shared combat maths

    /// What a battle between two bodies is worth to the owner of `ours`.
    ///
    /// It mirrors `GameEngine.resolveBattle` exactly — effective power against
    /// *remaining* health, both results simultaneous — so the heuristic never
    /// predicts a trade the rules would resolve differently, including the power
    /// an ability has already granted or taken away. Damage that falls short is
    /// ignored on purpose: the engine heals every board during end-of-turn
    /// cleanup, so only deaths carry across the turn.
    private func exchange(ours: Body, theirs: Body) -> Double {
        var score = 0.0
        if ours.power >= theirs.remainingHealth { score += theirs.value }
        if theirs.power >= ours.remainingHealth { score -= ours.value * Tuning.ownLossWeight }
        return score
    }

    /// Pairs an in-play character with its printed card. Returns `nil` when the
    /// pool no longer holds the card, which lets every caller skip the body
    /// rather than guess at its stats.
    private func body(_ character: CharacterInPlay?, engine: GameEngine) -> Body? {
        guard let character, let card = engine.card(for: character) else { return nil }
        return Body(character: character, card: card)
    }

    /// The body an effect is about to change. `BoardTarget` carries the side it
    /// belongs to because effects routinely reach across the table — a scope
    /// like "all Characters" hits both boards — so the owner is read from the
    /// target rather than assumed to be the activating player.
    private func body(at target: BoardTarget, engine: GameEngine) -> Body? {
        body(engine.side(target.slot).character(id: target.id), engine: engine)
    }
}
