//
//  AIDifficulty.swift
//  NTCGSimulator
//
//  The four strengths the computer opponent plays at, mirroring the
//  reference's difficulty table: genin is the greedy heuristic alone, the
//  middle tiers search but only over what a fair opponent could know, and
//  kage — the reference's shipped default — searches the true state, hidden
//  hands and all. Each tier is just a `GameSearch.Parameters` recipe; the
//  playing strength itself lives in GameSearch.swift and SimpleAI.swift.
//

import Foundation

// MARK: - Difficulty

/// How hard the AI opponent plays. Raw values are stable for persistence.
enum AIDifficulty: String, Codable, Hashable, CaseIterable, Identifiable {

    /// The greedy one-ply policy, no search — the reference's `genin`.
    case genin

    /// A modest search that redeals what it cannot see each iteration, so it
    /// plays the odds rather than your actual hand.
    case chunin

    /// The full-depth honest search — the reference's `jonin`: strong, but
    /// still guessing at hidden cards.
    case jonin

    /// The reference's shipped opponent: full iterations over the true state.
    /// It knows your hand, your deck order and your face-down Supports —
    /// nearly unbeatable unless you play perfectly.
    case kage

    /// What a fresh vs-AI game plays at. The reference never exposes the
    /// difficulty knob and always ships kage, so kage is the default here too.
    static let standard: AIDifficulty = .kage

    var id: String { rawValue }

    // MARK: Presentation

    /// Rank name as a menu shows it.
    var title: String {
        switch self {
        case .genin:  return "Genin"
        case .chunin: return "Chunin"
        case .jonin:  return "Jonin"
        case .kage:   return "Kage"
        }
    }

    /// One honest sentence about what the tier actually does.
    var detail: String {
        switch self {
        case .genin:  return "Plays on instinct, one move at a time."
        case .chunin: return "Reads the board a few turns ahead."
        case .jonin:  return "Searches deeply, guessing at your hidden cards."
        case .kage:   return "Searches deeply and sees your hand."
        }
    }

    // MARK: Search recipe

    /// The tier's search configuration, or `nil` for the searchless tier.
    /// Iteration counts are the reference's table (chunin is this app's
    /// intermediate step between them); only kage searches with perfect
    /// information. This is the *unconstrained baseline* — what the tier
    /// asks for on a cool, plugged-in-feeling device. What a decision may
    /// actually spend is resolved through `SearchBudget`, which scales this
    /// recipe down for heat, Low Power Mode, and long turns.
    var searchParameters: GameSearch.Parameters? {
        switch self {
        case .genin:  return nil
        case .chunin: return GameSearch.Parameters(iterations: 300, determinized: true)
        case .jonin:  return GameSearch.Parameters(iterations: 900, determinized: true)
        case .kage:   return GameSearch.Parameters(iterations: 1600, determinized: false)
        }
    }
}

// MARK: - Choosing a move

extension AIDifficulty {

    /// One decision for `slot`, off the main thread for the searching tiers —
    /// the board awaits this behind its thinking indicator. The state is
    /// snapshotted by value before the hop, the search runs on clones, and
    /// the answer is re-checked against the live engine's legal list, so a
    /// board that moved mid-think gets the greedy fallback instead of a
    /// stale action. Returns `nil` only when the game is not waiting on
    /// `slot` at all.
    ///
    /// The tier is a recipe, not a promise: what the search may actually
    /// cost is resolved through `SearchBudget` per decision, so a warming
    /// phone, Low Power Mode, or a long multi-decision turn each shrink the
    /// work — and under critical thermals every tier quietly plays greedy
    /// until the device cools. The player sees a slightly weaker opponent;
    /// they never feel the phone pay for a stronger one.
    func chooseAction(engine: GameEngine, slot: PlayerSlot) async -> GameAction? {
        guard !engine.isFinished else { return nil }
        let greedy = SimpleAI()
        guard searchParameters != nil else {
            return greedy.chooseAction(engine: engine, slot: slot)
        }

        // The ledger counts this turn's searched decisions so later ones in
        // the same turn get geometrically smaller budgets — an AI turn can
        // be ten decisions, and ten full searches is how phones cook.
        let snapshot = engine.state
        let decisionIndex = SearchBudget.TurnLedger.shared.nextDecisionIndex(
            gameSeed: engine.seed,
            turn: snapshot.turnNumber
        )
        guard let parameters = SearchBudget.resolved(for: self, decisionIndex: decisionIndex) else {
            // Critical thermals: the greedy policy is the whole AI for now.
            return greedy.chooseAction(engine: engine, slot: slot)
        }

        let searched = await GameSearch.chooseAction(
            from: snapshot,
            for: slot,
            configuration: engine.configuration,
            database: engine.database,
            parameters: parameters,
            seed: GameSearch.moveSeed(gameSeed: engine.seed, state: snapshot)
        )
        if let searched, engine.legalActions(for: slot).contains(searched) {
            return searched
        }
        return greedy.chooseAction(engine: engine, slot: slot)
    }
}
