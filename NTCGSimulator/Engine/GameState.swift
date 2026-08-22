//
//  GameState.swift
//  NTCGSimulator
//
//  The board itself: both players' zones, whose turn it is, which phase that
//  turn sits in, and whether the game has been decided. Everything here is a
//  plain value type carrying its own random generator, so a whole game replays
//  exactly from the seed it started with.
//

import Foundation

// MARK: - Player slot

/// Which side of the board a thing belongs to. The near side is always
/// `.player`, even in Solo v Self where one person drives both.
enum PlayerSlot: String, Codable, Hashable, CaseIterable, Identifiable {
    case player
    case opponent

    var id: String { rawValue }

    /// The other side. Used constantly by combat and turn passing, so it lives
    /// here rather than being recomputed inline.
    var opposing: PlayerSlot {
        self == .player ? .opponent : .player
    }

    /// Label used in the journal and on the board.
    var title: String {
        switch self {
        case .player:   return "You"
        case .opponent: return "Opponent"
        }
    }
}

// MARK: - Phases

/// The five steps of a turn, in order. `refresh` and `draw` resolve without
/// player input, so a player normally only ever sees `main`, `attack` and `end`.
enum GamePhase: String, Codable, Hashable, CaseIterable, Identifiable {
    case refresh
    case draw
    case main
    case attack
    case end

    var id: String { rawValue }

    var title: String {
        switch self {
        case .refresh: return "Refresh"
        case .draw:    return "Draw"
        case .main:    return "Main"
        case .attack:  return "Attack"
        case .end:     return "End"
        }
    }

    /// The phase that follows within the same turn. `nil` after `end`, which is
    /// where the turn passes to the other player instead.
    var next: GamePhase? {
        switch self {
        case .refresh: return .draw
        case .draw:    return .main
        case .main:    return .attack
        case .attack:  return .end
        case .end:     return nil
        }
    }
}

// MARK: - Rules constants

/// Every fixed number the rules engine leans on. Kept together so a rules
/// correction is a one-line edit rather than a hunt through the engine.
enum GameRules {
    /// Cards drawn at the start of a game, and again after a mulligan.
    static let openingHandSize = 5

    /// Chakra cards placed ready during setup.
    static let chakraCount = 5

    /// Bodies allowed in the Characters row at one time.
    static let maxCharacters = 5

    /// EX Characters allowed in the Characters row at one time.
    static let maxEXCharacters = 1

    /// Fixed Support slots printed on the mat.
    static let supportSlots = 5

    /// Life used when a Leader card is missing from the pool, so a broken or
    /// partial import degrades into a playable game rather than a crash.
    static let defaultLeaderLife = 15
}

// MARK: - Cards in play

/// A Chakra card in the Chakra row. Resting one is how costs are paid.
struct ChakraCard: Identifiable, Hashable, Codable {
    let id: UUID
    let cardID: String
    var isRested: Bool = false
}

/// A card occupying a fixed zone — a Support slot or the Summon zone. It has no
/// battle state of its own, only identity and the card it represents.
struct PlacedCard: Identifiable, Hashable, Codable {
    let id: UUID
    let cardID: String
}

/// A body in the Characters row: the card it was played from plus the battle
/// state that only exists while it is on the board.
struct CharacterInPlay: Identifiable, Hashable, Codable {

    let id: UUID

    /// Collector number, resolved against `CardDatabase` for printed values.
    let cardID: String

    /// Cached from the card so the state can enforce the one-EX-at-a-time rule
    /// without reaching for the database.
    let isEX: Bool

    /// Power absorbed so far this turn. Cleared during end-of-turn cleanup.
    var damageTaken: Int = 0

    /// Rested characters cannot attack or block until the next refresh.
    var isRested: Bool = false

    /// Summoning sickness: cleared by the owner's next refresh.
    var summonedThisTurn: Bool = true

    /// Power added or removed until the end of the turn, from abilities and
    /// other temporary effects. Cleared during end-of-turn cleanup.
    var powerBonus: Int = 0

    /// Damage added or removed until the end of the turn. The mirror of
    /// `powerBonus` for the value a connecting attack takes off a Leader.
    var damageBonus: Int = 0

    /// Rush: the card may attack on the turn it arrived. Granted by abilities
    /// and cleared with the rest of the turn's temporary modifiers.
    var hasRush: Bool = false

    /// Announced by a `cannotAttackNextTurn` effect. The owner's next refresh
    /// promotes it into `isBarredFromAttacking`, which is what actually bites —
    /// a ban declared during one turn only takes hold on the next one.
    var isBarredNextTurn: Bool = false

    /// True while an attack ban is in force. Set at refresh from
    /// `isBarredNextTurn`, and cleared by the refresh after that.
    var isBarredFromAttacking: Bool = false

    /// Health left before the character is sent to the Trash.
    func remainingHealth(of card: Card) -> Int {
        max(0, (card.health ?? 0) - damageTaken)
    }

    /// Power for combat purposes: what is printed, plus any temporary
    /// modifier, never below zero.
    func effectivePower(of card: Card) -> Int {
        max(0, (card.power ?? 0) + powerBonus)
    }

    /// Damage for combat purposes: what is printed, plus any temporary
    /// modifier, never below zero.
    func effectiveDamage(of card: Card) -> Int {
        max(0, (card.damage ?? 0) + damageBonus)
    }

    /// Ready characters may block.
    var isReady: Bool { !isRested }

    /// A character may attack once per turn, never on the turn it arrived
    /// unless it has Rush, and never while an ability is holding it back.
    var canAttack: Bool {
        guard !isRested, !isBarredFromAttacking else { return false }
        return !summonedThisTurn || hasRush
    }
}

// MARK: - Ability use

/// One printed ability box on one card in play.
///
/// "Once Per Turn" is a property of the box, not of the player: two characters
/// each carrying their own once-per-turn ability must both be usable in the
/// same turn, and a card printing two boxes must be able to use each of them.
/// Keying the used set this way is what makes that true.
struct AbilityUse: Hashable, Codable {
    let source: AbilitySource
    let abilityIndex: Int
}

// MARK: - Player side

/// One player's half of the board: every zone, plus their Leader's life.
struct PlayerSide: Codable, Hashable {

    let slot: PlayerSlot

    /// Collector number of the Leader anchoring this side.
    var leaderCardID: String

    /// Life remaining on the Leader. Reaching zero loses the game.
    var life: Int

    /// Face-down draw pile, top card first.
    var deck: [String]

    /// Cards held. `GameAction.playCard` addresses these by index.
    var hand: [String]

    /// The five Chakra cards, ready or rested.
    var chakra: [ChakraCard]

    /// Bodies in play, in the order they were summoned.
    var characters: [CharacterInPlay] = []

    /// Five fixed Support slots. Nothing in the implemented ruleset fills them
    /// — jutsu resolve straight to the Trash — but the zone exists so a rules
    /// correction can place continuous cards here without reshaping the board.
    var support: [PlacedCard?] = Array(repeating: nil, count: GameRules.supportSlots)

    /// The single Summon zone.
    var summon: PlacedCard? = nil

    /// Discard pile, most recently added last.
    var trash: [String] = []

    /// Cards removed from the game entirely.
    var exclusion: [String] = []

    /// Whether this side's Leader is rested. Nothing in the implemented ruleset
    /// asks a Leader to attack or block, so this is board state the abilities
    /// that say "rest this card" need in order to mean anything, and the board
    /// draws it.
    var leaderIsRested: Bool = false

    /// Every ability box this side has used this turn. Cleared at the start of
    /// each of their turns, so "Once Per Turn" resets with the refresh.
    var usedAbilities: Set<AbilityUse> = []

    /// Whether this player used their one mulligan.
    var hasMulliganed: Bool = false

    /// Whether this player has taken their mulligan decision at all. Turn one
    /// cannot begin until both sides have.
    var mulliganResolved: Bool = false

    // MARK: Derived

    /// Chakra still available to pay costs.
    var readyChakra: Int { chakra.lazy.filter { !$0.isRested }.count }

    /// Chakra already spent this turn.
    var restedChakra: Int { chakra.count - readyChakra }

    /// The EX Character in play, if any.
    var exCharacter: CharacterInPlay? { characters.first { $0.isEX } }

    /// Characters able to block, or to be chosen as blockers.
    var readyCharacters: [CharacterInPlay] { characters.filter(\.isReady) }

    /// Characters able to declare an attack this turn.
    var attackers: [CharacterInPlay] { characters.filter(\.canAttack) }

    func character(id: UUID) -> CharacterInPlay? {
        characters.first { $0.id == id }
    }

    func indexOfCharacter(id: UUID) -> Int? {
        characters.firstIndex { $0.id == id }
    }

    /// Whether a particular ability box has already been used this turn.
    func hasUsed(_ use: AbilityUse) -> Bool { usedAbilities.contains(use) }

    // MARK: Mutation

    /// Rests the first `count` ready Chakra. Deterministic order keeps replays
    /// identical; which Chakra pays is otherwise immaterial.
    mutating func restChakra(_ count: Int) {
        var remaining = count
        for index in chakra.indices where remaining > 0 {
            guard !chakra[index].isRested else { continue }
            chakra[index].isRested = true
            remaining -= 1
        }
    }

    /// Turns every Chakra card face-up again, which several cards print as an
    /// effect in its own right rather than only as part of the refresh step.
    /// - Returns: how many were face-down, so the log can say what changed.
    @discardableResult
    mutating func readyAllChakra() -> Int {
        let wasRested = restedChakra
        for index in chakra.indices { chakra[index].isRested = false }
        return wasRested
    }

    /// Marks an ability box used for the rest of this turn.
    mutating func markUsed(_ use: AbilityUse) { usedAbilities.insert(use) }

    /// Refresh step: stand everything up and clear summoning sickness.
    mutating func readyAll() {
        for index in chakra.indices { chakra[index].isRested = false }
        for index in characters.indices {
            characters[index].isRested = false
            characters[index].summonedThisTurn = false
            // A ban announced last turn is what bites now, and only for now.
            characters[index].isBarredFromAttacking = characters[index].isBarredNextTurn
            characters[index].isBarredNextTurn = false
        }
        leaderIsRested = false
        usedAbilities.removeAll()
    }

    /// End-of-turn cleanup: temporary modifiers expire.
    mutating func clearTemporaryModifiers() {
        for index in characters.indices {
            characters[index].powerBonus = 0
            characters[index].damageBonus = 0
            characters[index].hasRush = false
        }
    }

    /// Places a card in the first free Support slot.
    /// - Returns: `false` when every slot is occupied.
    mutating func placeInSupport(_ placed: PlacedCard) -> Bool {
        guard let free = support.firstIndex(where: { $0 == nil }) else { return false }
        support[free] = placed
        return true
    }

    /// Whether any Support slot is free.
    var hasFreeSupportSlot: Bool { support.contains { $0 == nil } }

    mutating func rest(characterID: UUID) {
        guard let index = indexOfCharacter(id: characterID) else { return }
        characters[index].isRested = true
    }

    mutating func applyDamage(_ amount: Int, to characterID: UUID) {
        guard amount > 0, let index = indexOfCharacter(id: characterID) else { return }
        characters[index].damageTaken += amount
    }

    /// Clears accumulated battle damage — characters heal during end-of-turn
    /// cleanup, so damage only matters within the turn it was dealt.
    mutating func healAllCharacters() {
        for index in characters.indices { characters[index].damageTaken = 0 }
    }

    /// Removes a character from the row and puts its card in the Trash.
    /// - Returns: the card number that left play, for the journal line.
    @discardableResult
    mutating func sendCharacterToTrash(id: UUID) -> String? {
        guard let index = indexOfCharacter(id: id) else { return nil }
        let removed = characters.remove(at: index)
        trash.append(removed.cardID)
        return removed.cardID
    }
}

// MARK: - Pending attack

/// An attack that has been declared and is waiting on the defender's block
/// decision. Combat only resolves once this is answered.
struct PendingAttack: Identifiable, Hashable, Codable {
    let id: UUID

    /// The attacking character.
    let attackerID: UUID

    /// The side that declared the attack.
    let attackingSlot: PlayerSlot

    /// What the attack was aimed at before any block.
    let target: AttackTarget

    /// The side that must answer with `GameAction.declareBlock`.
    var defendingSlot: PlayerSlot { attackingSlot.opposing }
}

// MARK: - Outcome

/// Why a game ended.
enum WinReason: String, Codable, Hashable, CaseIterable {
    case lifeDepleted
    case deckOut
    case concession

    var title: String {
        switch self {
        case .lifeDepleted: return "Life"
        case .deckOut:      return "Deck out"
        case .concession:   return "Concession"
        }
    }

    /// Phrase completing "X wins — …".
    var detail: String {
        switch self {
        case .lifeDepleted: return "a Leader ran out of life"
        case .deckOut:      return "a player could not draw from an empty deck"
        case .concession:   return "the other side conceded"
        }
    }
}

/// Whether the game is still running, and if not, who took it.
enum GameOutcome: Hashable, Codable {
    case ongoing
    case win(PlayerSlot, reason: WinReason)

    var winner: PlayerSlot? {
        if case .win(let slot, _) = self { return slot }
        return nil
    }

    var loser: PlayerSlot? { winner?.opposing }

    var isFinished: Bool { winner != nil }

    /// One-line result, ready to show on the end-of-game panel.
    var summary: String {
        switch self {
        case .ongoing:
            return "The game is in progress."
        case .win(let slot, let reason):
            let who = slot == .player ? "You win" : "The opponent wins"
            return "\(who) — \(reason.detail)."
        }
    }
}

// MARK: - Game state

/// The complete board. Only `GameEngine` should mutate this; the UI reads it.
struct GameState: Codable, Hashable {

    var player: PlayerSide
    var opponent: PlayerSide

    /// Whose turn it is.
    var current: PlayerSlot

    /// Who took the first turn — they skip their draw on turn one.
    var firstPlayer: PlayerSlot

    var phase: GamePhase = .refresh

    /// Counts player turns, not rounds: turn 1 is the first player's first turn,
    /// turn 2 is their opponent's. Zero until both mulligans are answered.
    var turnNumber: Int = 0

    var outcome: GameOutcome = .ongoing

    /// Set between an attack declaration and the defender's block decision.
    var pendingAttack: PendingAttack? = nil

    /// Carried in the state so every shuffle after setup stays reproducible.
    var rng: SeededGenerator

    // MARK: Access

    subscript(slot: PlayerSlot) -> PlayerSide {
        get { slot == .player ? player : opponent }
        set {
            if slot == .player { player = newValue } else { opponent = newValue }
        }
    }

    /// The side that would answer an attack right now.
    var defender: PlayerSlot { current.opposing }

    var isFinished: Bool { outcome.isFinished }

    /// True until both players have kept or redrawn their opening hand.
    var isAwaitingMulligan: Bool {
        !player.mulliganResolved || !opponent.mulliganResolved
    }

    func needsMulligan(_ slot: PlayerSlot) -> Bool {
        !self[slot].mulliganResolved
    }

    /// Draws a reproducible identity for a new board entity.
    mutating func makeIdentifier() -> UUID {
        rng.makeIdentifier()
    }
}

// MARK: - Seeded randomness

/// SplitMix64: a four-line generator with good distribution and a tiny state.
/// Storing it in `GameState` is what makes a game reproducible — the same seed
/// always produces the same shuffles, hands and coin toss.
struct SeededGenerator: RandomNumberGenerator, Codable, Hashable {

    private var state: UInt64

    init(seed: UInt64) {
        state = seed
    }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

extension RandomNumberGenerator {
    /// Builds a UUID from the generator rather than the system source, so board
    /// identities are part of the reproducible replay instead of noise.
    mutating func makeIdentifier() -> UUID {
        let high = next()
        let low = next()
        func byte(_ value: UInt64, _ index: Int) -> UInt8 {
            UInt8(truncatingIfNeeded: value >> UInt64(8 * index))
        }
        return UUID(uuid: (
            byte(high, 0), byte(high, 1), byte(high, 2), byte(high, 3),
            byte(high, 4), byte(high, 5), byte(high, 6), byte(high, 7),
            byte(low, 0), byte(low, 1), byte(low, 2), byte(low, 3),
            byte(low, 4), byte(low, 5), byte(low, 6), byte(low, 7)
        ))
    }
}
