//
//  GameSearch.swift
//  NTCGSimulator
//
//  The strong opponent — the reference simulator's Monte Carlo tree search,
//  ported to this engine. Where SimpleAI answers each moment greedily, the
//  search plays whole games ahead: a forced-win scan catches lethal outright,
//  UCB1 grows a tree over the actions the engine itself lists, and rollouts
//  play both sides with the greedy policy plus a little seeded noise.
//
//  Everything runs on detached engine clones. `GameState` is a pure value
//  graph, so a copy is one assignment and mutating a clone can never touch
//  the live game; the clones' journals are muted so a 1,600-iteration search
//  writes nothing. All randomness comes from one generator seeded off the
//  position, so a seeded game against the search still replays exactly. The
//  only actions ever returned are drawn from `legalActions(for:)`.
//
//  How much a search may cost is not decided here: callers hand in
//  `Parameters`, and the shipping path resolves those through SearchBudget
//  so a warm or conserving phone searches less. This file's own thermal
//  duties are the mechanics: iterations bind before the wall clock, the
//  worker runs at utility QoS on efficiency cores, and a cancelled caller
//  stops the loop within one iteration.
//

import Foundation

// MARK: - Parameters

extension GameSearch {

    /// The search's knobs, defaulted to the reference's shipped configuration.
    /// The difficulty tiers vary only `iterations` and `determinized`; tests
    /// additionally shrink the budgets to stay fast.
    struct Parameters {

        /// Tree iterations per decision.
        var iterations: Int

        /// Whether each iteration redeals what the opponent could not have
        /// seen — hand, deck order, face-down Supports — before searching.
        /// False means the search reads the true hidden state.
        var determinized: Bool

        /// UCB1 exploration constant.
        var explorationConstant = 1.1

        /// Chance a rollout step ignores the greedy policy for a uniformly
        /// random legal action, so rollouts sample replies the greedy line
        /// would never play.
        var rolloutNoise = 0.15

        /// Actions a rollout may take before the position is scored as-is.
        var rolloutStepCap = 160

        /// Actions a selection descent may take before rolling out.
        var selectionPlyCap = 40

        /// Plies the forced-win scan looks ahead from each attack.
        var forcedWinDepth = 4

        /// Positions the forced-win scan may expand per attack.
        var forcedWinBudget = 600

        /// Divisor on the score difference inside the terminal sigmoid.
        var evaluationScale = 14.0

        /// Wall-clock ceiling per decision — a hard cap on burn, not a
        /// target. A build fast enough to finish its `iterations` early goes
        /// idle rather than spending the window regardless; a build too slow
        /// to finish keeps the best answer so far, so a hard tier can never
        /// hang the game. Measured in a Debug simulator run this engine does
        /// roughly 190–290 MCTS iterations per second, which makes an
        /// uncapped kage decision 5–9 seconds of solid core time — exactly
        /// the burn this cap exists to forbid. 0.6s (down from the
        /// reference's 1.0s cadence) trims every decision's worst case by
        /// 40% and still reads as a natural thinking beat at the table.
        var timeLimit: TimeInterval = 0.6

        init(iterations: Int, determinized: Bool) {
            self.iterations = iterations
            self.determinized = determinized
        }
    }
}

// MARK: - Evaluation weights

/// The reference's position score, verbatim — these weights are tuned, so
/// they are pinned here rather than derived. A position's value is the
/// sigmoid of the two sides' score difference.
private enum Evaluation {

    /// Life is the game: three points per point of life…
    static let life = 3.0

    /// …and a quadratic penalty as it falls through six, so the search fears
    /// being put in range long before it is dead.
    static let lowLifeThreshold = 6.0
    static let lowLifePenalty = 6.0

    /// Per character: live effective power…
    static let power = 1.0

    /// …the damage stat that actually shortens the game…
    static let damage = 1.5

    /// …a flat body bonus, a rested malus, and a malus per damage counter.
    static let body = 1.5
    static let rested = -0.8
    static let damageCounter = -0.5

    /// Cards in hand and face-down Supports are answers not yet spent.
    static let handCard = 1.5
    static let setSupport = 1.2

    /// Face-up chakra, a standing Summon card, and even trash size — the
    /// reference scores a stocked trash for the cards that revive from it.
    static let faceUpChakra = 0.5
    static let summonStanding = 1.0
    static let trashCard = 0.1
}

// MARK: - Game search

/// One decision's worth of Monte Carlo tree search. Build it, run it once,
/// throw it away — the tree is not reused between decisions, matching the
/// reference, and the struct carries the run's seeded generator.
struct GameSearch {

    /// The seat being played for. Values everywhere are from this player's
    /// perspective: 1 is their win, 0 their loss.
    let player: PlayerSlot

    let configuration: GameConfiguration
    let database: CardDatabase
    let parameters: Parameters

    /// The run's only randomness. Seeded from the position, so the same
    /// game replays the same searches.
    private var rng: SeededGenerator

    /// Polled between iterations of every expensive loop. When it flips, the
    /// search stops where it stands and answers with its best line so far —
    /// a search whose game has ended, whose board has navigated away, or
    /// whose app has left the foreground is pure waste, so it must not run
    /// to its deadline in the background. `chooseAction` wires this to Swift
    /// task cancellation; the synchronous entry defaults it to "never".
    private let isCancelled: () -> Bool

    private init(
        player: PlayerSlot,
        configuration: GameConfiguration,
        database: CardDatabase,
        parameters: Parameters,
        seed: UInt64,
        isCancelled: @escaping () -> Bool
    ) {
        self.player = player
        self.configuration = configuration
        self.database = database
        self.parameters = parameters
        self.rng = SeededGenerator(seed: seed)
        self.isCancelled = isCancelled
    }

    // MARK: Entry points

    /// One searched decision, synchronously, on the caller's thread. Only
    /// ever returns an action from `legalActions(for:)` of the given state,
    /// or `nil` when the game is not waiting on `player`.
    static func bestAction(
        from state: GameState,
        for player: PlayerSlot,
        configuration: GameConfiguration,
        database: CardDatabase,
        parameters: Parameters,
        seed: UInt64,
        isCancelled: @escaping () -> Bool = { false }
    ) -> GameAction? {
        var search = GameSearch(
            player: player,
            configuration: configuration,
            database: database,
            parameters: parameters,
            seed: seed,
            isCancelled: isCancelled
        )
        return search.run(from: state)
    }

    /// The same decision off the calling thread, for the board: the state is
    /// already a value snapshot, so the search races nothing while the UI
    /// shows its thinking indicator.
    ///
    /// Runs at `.utility`, not `.userInitiated`. Utility work is scheduled
    /// onto efficiency cores where possible, which is markedly cooler and
    /// cheaper per iteration of a sustained loop like this — exactly the
    /// load an AI turn is. The AI's move already sits behind the board's
    /// deliberate thinking delay, and the iteration budget (not the wall
    /// clock) is what should bind, so trading peak single-core speed for
    /// heat is the right side of the bargain; if an E-core run can't finish
    /// the iterations, `timeLimit` still caps the wait at well under a
    /// second, so the pace of play is preserved either way.
    ///
    /// Swift task cancellation is bridged into the search through a latch:
    /// the GCD block itself cannot observe `Task.isCancelled`, so the
    /// cancellation handler flips a flag the iteration loop polls. A board
    /// task cancelled by SwiftUI (view gone, game over, next revision)
    /// therefore stops the worker within one iteration instead of letting
    /// it burn to its deadline unobserved.
    static func chooseAction(
        from state: GameState,
        for player: PlayerSlot,
        configuration: GameConfiguration,
        database: CardDatabase,
        parameters: Parameters,
        seed: UInt64
    ) async -> GameAction? {
        let latch = CancellationLatch()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                DispatchQueue.global(qos: .utility).async {
                    continuation.resume(returning: bestAction(
                        from: state,
                        for: player,
                        configuration: configuration,
                        database: database,
                        parameters: parameters,
                        seed: seed,
                        isCancelled: { latch.isCancelled }
                    ))
                }
            }
        } onCancel: {
            latch.cancel()
        }
    }

    /// A deterministic per-position seed, mirroring the reference's habit of
    /// hashing the game seed with how far the game has come — the same
    /// position in the same game always searches identically, and successive
    /// positions search differently.
    static func moveSeed(gameSeed: UInt64, state: GameState) -> UInt64 {
        var mixed = scramble(gameSeed)
        let counters = [
            state.turnNumber,
            state.chain.count,
            state.player.hand.count, state.player.deck.count,
            state.player.trash.count, state.player.characters.count,
            state.player.life, state.player.faceUpChakra,
            state.opponent.hand.count, state.opponent.deck.count,
            state.opponent.trash.count, state.opponent.characters.count,
            state.opponent.life, state.opponent.faceUpChakra,
            state.pendingChoice == nil ? 0 : 1,
            state.pendingAttack == nil ? 0 : 1,
        ]
        for counter in counters {
            mixed = scramble(mixed ^ UInt64(truncatingIfNeeded: counter))
        }
        return mixed
    }

    /// One SplitMix64 step — the same mixer `SeededGenerator` runs on.
    private static func scramble(_ value: UInt64) -> UInt64 {
        var z = value &+ 0x9E37_79B9_7F4A_7C15
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }

    // MARK: The run

    /// The reference's decision order: trivial answers first, then any move
    /// that wins on the spot, then an attack that provably forces the win,
    /// then — with the instantly-losing moves filtered out — the tree search.
    private mutating func run(from rootState: GameState) -> GameAction? {
        guard rootState.decider == player else { return nil }
        let legal = actionable(engine(over: rootState), for: player)
        guard !legal.isEmpty else { return nil }
        guard legal.count > 1 else { return legal[0] }

        // Any action that ends the game in our favour the moment it applies
        // is taken without any search at all. The same pass remembers which
        // actions hand the opponent the game instead.
        var safe: [GameAction] = []
        for action in legal {
            let probe = engine(over: rootState)
            guard applies(action, by: player, to: probe) else { continue }
            if probe.state.outcome.winner == player { return action }
            if probe.state.outcome.winner != player.opposing {
                safe.append(action)
            }
        }

        // An attack that wins against every reply is as good as an instant
        // win — this is what lets the AI see lethal through a pass. Each
        // proof can expand hundreds of positions, so a cancelled search
        // bails between attacks rather than finishing the scan for nobody.
        for action in legal {
            guard !isCancelled() else { break }
            guard case .declareAttack = action else { continue }
            let probe = engine(over: rootState)
            guard applies(action, by: player, to: probe) else { continue }
            var budget = parameters.forcedWinBudget
            if provesWin(from: probe.state, depth: parameters.forcedWinDepth, budget: &budget) {
                return action
            }
        }

        // Suicidal moves are filtered — unless everything is, in which case
        // the search picks the least bad way to lose.
        let candidates = safe.isEmpty ? legal : safe
        guard candidates.count > 1 else { return candidates.first ?? legal[0] }

        return searchTree(rootState: rootState, rootActions: candidates) ?? candidates[0]
    }

    // MARK: Forced-win scan

    /// AND/OR proof search: from our own decisions any winning line will do,
    /// from anyone else's every reply must still lose. Depth and budget caps
    /// keep it honest — an unproven position counts as not winning.
    private func provesWin(from state: GameState, depth: Int, budget: inout Int) -> Bool {
        if let winner = state.outcome.winner { return winner == player }
        guard depth > 0, budget > 0 else { return false }
        guard let decider = state.decider else { return false }
        let legal = actionable(engine(over: state), for: decider)
        guard !legal.isEmpty else { return false }

        for action in legal {
            guard budget > 0 else { return false }
            budget -= 1
            let probe = engine(over: state)
            guard applies(action, by: decider, to: probe) else { continue }
            let proven = provesWin(from: probe.state, depth: depth - 1, budget: &budget)
            if decider == player, proven { return true }
            if decider != player, !proven { return false }
        }
        return decider != player
    }

    // MARK: The tree

    /// One node per action taken from its parent's position. Stats are stored
    /// from `player`'s perspective and flipped at selection time for nodes
    /// where the opponent decides. A class on purpose: nodes are shared
    /// between the path list and the tree, and never leave the search.
    private final class Node {
        let action: GameAction
        var visits = 0.0
        var total = 0.0
        var children: [Node] = []

        /// Actions already expanded from this node, across determinizations.
        var expanded: Set<GameAction> = []

        var mean: Double { visits > 0 ? total / visits : 0 }

        init(action: GameAction) {
            self.action = action
        }
    }

    /// UCT with per-iteration determinization. Each iteration redeals the
    /// hidden information (when the tier asks for it), replays the tree path
    /// on a fresh clone, expands one node, rolls the rest out greedily and
    /// backs the value up the path. The answer is the most-visited root
    /// child, ties broken by mean value.
    private mutating func searchTree(rootState: GameState, rootActions: [GameAction]) -> GameAction? {
        let root = Node(action: .endTurn)   // Placeholder; the root's action is never read.
        let deadline = Date().addingTimeInterval(parameters.timeLimit)

        var iteration = 0
        while iteration < parameters.iterations {
            iteration += 1
            // Cancellation is polled here, inside the loop, on purpose: an
            // iteration is a handful of milliseconds, so a search whose
            // caller has moved on stops within one — not after a full
            // deadline of work the game will never see.
            if isCancelled() || Date() >= deadline { break }

            var startState = rootState
            if parameters.determinized {
                determinize(&startState)
            }
            let engine = engine(over: startState)

            // Selection and expansion.
            var path = [root]
            var node = root
            var plies = 0
            descent: while plies < parameters.selectionPlyCap, !engine.isFinished {
                guard let decider = engine.state.decider else { break }
                let legal = node === root
                    ? rootActions
                    : actionable(engine, for: decider)

                if let untried = legal.first(where: { !node.expanded.contains($0) }) {
                    node.expanded.insert(untried)
                    guard applies(untried, by: decider, to: engine) else { continue }
                    let child = Node(action: untried)
                    node.children.append(child)
                    path.append(child)
                    break descent
                }

                // Fully expanded here: pick by UCB1 among the children this
                // determinization still allows.
                let candidates = node.children.filter { legal.contains($0.action) }
                guard let chosen = select(from: candidates, parentVisits: node.visits, decider: decider),
                      applies(chosen.action, by: decider, to: engine) else { break }
                path.append(chosen)
                node = chosen
                plies += 1
            }

            // Rollout and backpropagation.
            let value = rollout(engine)
            for visited in path {
                visited.visits += 1
                visited.total += value
            }
        }

        var best: Node?
        for child in root.children {
            guard let current = best else {
                best = child
                continue
            }
            if child.visits > current.visits
                || (child.visits == current.visits && child.mean > current.mean) {
                best = child
            }
        }
        return best?.action
    }

    /// UCB1 with the exploitation term flipped to whoever decides at the
    /// parent — the opponent's nodes chase our worst values, not our best.
    private func select(from candidates: [Node], parentVisits: Double, decider: PlayerSlot) -> Node? {
        guard !candidates.isEmpty else { return nil }
        let logParent = log(Swift.max(parentVisits, 1))

        var best: (node: Node, score: Double)?
        for candidate in candidates {
            guard candidate.visits > 0 else { return candidate }
            let mean = decider == player ? candidate.mean : 1 - candidate.mean
            let score = mean
                + parameters.explorationConstant * (logParent / candidate.visits).squareRoot()
            if best == nil || score > best!.score {
                best = (candidate, score)
            }
        }
        return best?.node
    }

    // MARK: Rollout

    /// Plays the position out with the greedy policy on both seats, replaced
    /// by a random legal action at the noise rate, and scores where it lands.
    /// The greedy path is taken without ever materialising the legal list —
    /// rollouts are where all the time goes — and a refused pick falls back
    /// to a random legal one, so a rollout can stall only by reaching a
    /// position with nothing to do.
    private mutating func rollout(_ engine: GameEngine) -> Double {
        let greedy = SimpleAI()
        var steps = 0
        while steps < parameters.rolloutStepCap, !engine.isFinished {
            guard let decider = engine.state.decider else { break }

            let wantsNoise = Double.random(in: 0..<1, using: &rng) < parameters.rolloutNoise
            if !wantsNoise,
               let preferred = greedy.chooseAction(engine: engine, slot: decider),
               applies(preferred, by: decider, to: engine) {
                steps += 1
                continue
            }
            let legal = actionable(engine, for: decider)
            guard let picked = legal.randomElement(using: &rng),
                  applies(picked, by: decider, to: engine) else { break }
            steps += 1
        }
        return value(of: engine.state)
    }

    // MARK: Evaluation

    /// A finished game is 1 or 0; anything else is the sigmoid of the score
    /// difference, so small edges land near a half and big ones saturate.
    private func value(of state: GameState) -> Double {
        if let winner = state.outcome.winner {
            return winner == player ? 1 : 0
        }
        let difference = score(of: state[player], turn: state.turnNumber)
            - score(of: state[player.opposing], turn: state.turnNumber)
        return 1 / (1 + exp(-difference / parameters.evaluationScale))
    }

    /// One side's worth, on the reference's tuned weights.
    private func score(of side: PlayerSide, turn: Int) -> Double {
        let life = Double(side.life)
        let shortfall = Swift.max(0, Evaluation.lowLifeThreshold - life)
        var total = life * Evaluation.life - shortfall * shortfall * Evaluation.lowLifePenalty

        for character in side.characters {
            guard let card = database.card(id: character.cardID) else { continue }
            total += Double(character.effectivePower(of: card, turn: turn)) * Evaluation.power
            total += Double(character.damageStat(of: card)) * Evaluation.damage
            total += Evaluation.body
            total += Double(character.damage) * Evaluation.damageCounter
            if character.isRested { total += Evaluation.rested }
        }

        total += Double(side.hand.count) * Evaluation.handCard
        total += Double(side.faceDownSupports.count) * Evaluation.setSupport
        total += Double(side.faceUpChakra) * Evaluation.faceUpChakra
        total += Double(side.trash.count) * Evaluation.trashCard
        if !side.summonRested { total += Evaluation.summonStanding }
        return total
    }

    // MARK: Determinization

    /// Redeals what `player` could not legitimately know: the opponent's
    /// hand, deck order and face-down Supports pool together, shuffle off the
    /// run's generator, and deal back into the same shapes — same hand size,
    /// same slots refilled, the rest becoming the deck. Our own deck is
    /// shuffled too, since its order is just as unseen.
    private mutating func determinize(_ state: inout GameState) {
        let hiddenSlot = player.opposing
        var side = state[hiddenSlot]

        var pool = side.deck + side.hand
        var refillable: [Int] = []
        for (index, placed) in side.supports.enumerated() {
            guard let placed, !placed.isRevealed else { continue }
            pool.append(placed.cardID)
            refillable.append(index)
        }
        pool.shuffle(using: &rng)

        let handSize = side.hand.count
        side.hand = Array(pool.prefix(handSize))
        pool.removeFirst(Swift.min(handSize, pool.count))
        for index in refillable {
            guard let placed = side.supports[index], !pool.isEmpty else { continue }
            side.supports[index] = PlacedSupport(id: placed.id, cardID: pool.removeFirst())
        }
        side.deck = pool

        state[hiddenSlot] = side
        state[player].deck.shuffle(using: &rng)
    }

    // MARK: Clones and legality

    /// A detached, journal-muted engine over a copy of `state`. Cheap by
    /// design: the state is a value graph, so this is an allocation and an
    /// assignment.
    private func engine(over state: GameState) -> GameEngine {
        GameEngine(
            searchState: state,
            configuration: configuration,
            database: database,
            seed: 0
        )
    }

    /// The engine's own legal list, minus concede — the search never gives
    /// up, and the reference's action alphabet has no concede to consider.
    private func actionable(_ engine: GameEngine, for slot: PlayerSlot) -> [GameAction] {
        engine.legalActions(for: slot).filter { $0 != .concede }
    }

    /// Applies to a clone, reduced to a Bool — the search only cares whether
    /// the move went through, never why a probe was refused.
    private func applies(_ action: GameAction, by slot: PlayerSlot, to engine: GameEngine) -> Bool {
        if case .success = engine.apply(action, by: slot) { return true }
        return false
    }
}

// MARK: - Cancellation latch

/// Bridges Swift task cancellation to the GCD worker the search runs on.
/// The worker cannot see `Task.isCancelled` (it is not a task), so the
/// cancellation handler flips this flag and the search polls it between
/// iterations. A plain lock rather than an atomic on purpose: the latch is
/// read at most a couple of thousand times per decision, so the lock's cost
/// is noise, and it keeps the file dependency-free.
private final class CancellationLatch: @unchecked Sendable {

    private let lock = NSLock()
    private var cancelled = false

    func cancel() {
        lock.lock()
        cancelled = true
        lock.unlock()
    }

    var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelled
    }
}
