//
//  GameState.swift
//  NTCGSimulator
//
//  The board itself: both players' zones, the turn machine, the chain, and any
//  open prompt or window. Everything here is a plain value type carrying its
//  own random generator, so a whole game replays exactly from the seed it
//  started with. Only `GameEngine` mutates it; the UI reads it.
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

// MARK: - Phases and steps

/// The turn's phase. `refresh` and `draw` are transient — the engine sets and
/// passes through them inside a single turn hand-off with nobody to ask — and
/// the player only ever acts in `main`. The reference declares an `end` phase
/// in its constants but never enters it, so it is deliberately absent here.
enum GamePhase: String, Codable, Hashable {

    /// The active player's cards stand and their per-turn counters reset.
    case refresh

    /// The turn's draw: one card on game turn 1, two on every later turn.
    case draw

    /// The playable turn: summon, set Supports, activate, attack, in any
    /// order, until END TURN.
    case main

    var title: String {
        switch self {
        case .refresh: return "Refresh"
        case .draw:    return "Draw"
        case .main:    return "Main"
        }
    }
}

/// Whether a response window is open. `counter` means somebody holds priority
/// and may answer with a Support — after an attack declaration, a summon, or
/// a support activation.
enum GameStep: String, Codable, Hashable {
    case normal
    case counter

    var title: String {
        switch self {
        case .normal:  return "Main"
        case .counter: return "Counter Step"
        }
    }
}

// MARK: - Rules constants

/// Every fixed number the rules engine leans on. Kept together so a rules
/// correction is a one-line edit rather than a hunt through the engine.
enum GameRules {

    /// Cards drawn at the start of a game, and again after a mulligan.
    static let openingHandSize = 5

    /// Chakra cards placed face-up during setup.
    static let chakraCount = 5

    /// Character slots printed on the mat. Display only: the row itself is
    /// unbounded and simply grows past five when effects flood the board.
    static let maxCharacters = 5

    /// Fixed Support slots printed on the mat. This one is a real cap.
    static let supportSlots = 5

    /// Life used when a Leader card is missing from the pool, so a broken or
    /// partial import degrades into a playable game rather than a crash.
    static let defaultLeaderLife = 15

    /// Normal summons a player may make in one turn. EX Characters are exempt
    /// and pay their printed Summon Requirements instead, without limit.
    static let normalSummonsPerTurn = 1

    /// Cards the first player draws on game turn 1.
    static let firstTurnDraw = 1

    /// Cards drawn at the start of every other turn — the second player draws
    /// two on their very first turn.
    static let normalDraw = 2

    /// The first game turn on which the Recovery action is available, so the
    /// first player can never recover on the game's opening turn.
    static let recoveryFromTurn = 2

    /// Attacks each character may declare per turn.
    static let attacksPerCharacter = 1

    /// Attacks the Leader may declare per turn.
    static let leaderAttacksPerTurn = 1

    /// The only game turn on which attacking is barred. The second player may
    /// attack — Leader included — on turn 2; the first player's own next
    /// chance is turn 3.
    static let noAttackOnTurn = 1
}

// MARK: - Cards in play

/// A Chakra card in the Chakra row. Costs flip the first face-up ones
/// face-down; only the Recovery action turns them face-up again.
struct ChakraCard: Identifiable, Hashable, Codable {
    let id: UUID
    let cardID: String
    var isFaceUp: Bool = true
}

/// A card sitting in a numbered Support slot. It lies face-down from the
/// moment it is set until its owner activates it; while its activation waits
/// on the chain it sits revealed, and it leaves the slot when the chain
/// resolves it.
struct PlacedSupport: Identifiable, Hashable, Codable {

    let id: UUID
    let cardID: String

    /// True once the card has been activated — it is on the chain, or came in
    /// from hand mid-window, and can no longer be activated again.
    var isRevealed: Bool = false
}

/// A body in the Characters row: the card it was played from plus the battle
/// state that only exists while it is on the board.
///
/// The turn-stamped fields expire by comparison against the global turn
/// number rather than being wiped: a value stamped with the current turn lasts
/// the rest of that turn, and a freeze stamped `turn + 1` bites through the
/// opponent's next turn.
struct CharacterInPlay: Identifiable, Hashable, Codable {

    let id: UUID

    /// Collector number, resolved against `CardDatabase` for printed values.
    let cardID: String

    /// Cached from the card so target filters can exclude EX Characters
    /// without reaching for the database.
    let isEX: Bool

    /// The global turn this body arrived on. Summoning sickness is simply
    /// `summonedOnTurn == turn` without Rush.
    var summonedOnTurn: Int

    /// Rested characters cannot attack, and are the only characters an enemy
    /// may attack.
    var isRested: Bool = false

    /// Power absorbed so far. Wiped for both players at end of every turn, so
    /// damage only matters inside the turn it was dealt.
    var damage: Int = 0

    /// Power added until end of turn. Applied after doubling, never doubled.
    var powerBonus: Int = 0

    /// Damage added until end of turn — the stat a connecting attack takes
    /// off a Leader.
    var damageBonus: Int = 0

    /// Attacks declared this turn. Reset at the owner's turn start.
    var attacksUsed: Int = 0

    /// Frozen while `turn <= cannotAttackUntilTurn` — a freeze stamped during
    /// the opponent's turn blocks the owner's whole next turn.
    var cannotAttackUntilTurn: Int = 0

    /// Temporary Rush while `rushUntilTurn >= turn`. Granted by Ino's boost;
    /// works even on a character whose own effects are negated.
    var rushUntilTurn: Int = 0

    /// Whether this character's Activate: Main was used this turn.
    var activatedThisTurn: Bool = false

    /// Doubled power while `powerDoubledUntilTurn >= turn`: twice *printed*
    /// power plus `powerBonus` — the bonus is not doubled.
    var powerDoubledUntilTurn: Int = 0

    /// Support immunity while `supportImmuneUntilTurn >= turn`, against the
    /// player in `supportImmuneFrom`, and only while a support is resolving
    /// or the chain is live.
    var supportImmuneUntilTurn: Int = 0
    var supportImmuneFrom: PlayerSlot?

    /// Set on a body summoned "with its effects negated": no On Summon, no
    /// When Attacking, no Activate: Main, no printed or conditional Rush —
    /// stats intact, and temporary `rushUntilTurn` still works.
    var effectsNegated: Bool = false

    init(id: UUID, cardID: String, isEX: Bool, summonedOnTurn: Int, effectsNegated: Bool = false) {
        self.id = id
        self.cardID = cardID
        self.isEX = isEX
        self.summonedOnTurn = summonedOnTurn
        self.effectsNegated = effectsNegated
    }

    // MARK: Derived stats

    /// Power for combat purposes. While doubled: twice printed power plus the
    /// bonus — the reference doubles the printed value only.
    func effectivePower(of card: Card, turn: Int) -> Int {
        let printed = card.power ?? 0
        let base = powerDoubledUntilTurn >= turn ? printed * 2 : printed
        return base + powerBonus
    }

    /// Damage stat: what a connecting attack takes off a Leader's life.
    func damageStat(of card: Card) -> Int {
        (card.damage ?? 0) + damageBonus
    }

    /// Health left before `GameEngine.checkDeaths` sends the body to the
    /// Trash. K.O. happens at `damage >= printed health`.
    func remainingHealth(of card: Card) -> Int {
        max(0, (card.health ?? 0) - damage)
    }

    /// Whether the character may attack on `turn`, given its printed card.
    /// Rush — temporary, printed, or conditional — is the only way past
    /// summoning sickness, and printed Rush dies with negated effects.
    func canAttack(card: Card, turn: Int) -> Bool {
        guard !isRested else { return false }
        guard attacksUsed < GameRules.attacksPerCharacter else { return false }
        guard turn > cannotAttackUntilTurn else { return false }
        guard summonedOnTurn == turn else { return true }
        return hasRush(card: card, turn: turn)
    }

    /// Whether Rush applies right now, from any of its three sources.
    func hasRush(card: Card, turn: Int) -> Bool {
        if rushUntilTurn >= turn { return true }
        guard !effectsNegated else { return false }
        for ability in card.abilities {
            for effect in ability.effects {
                switch effect {
                case .rush:
                    return true
                case .conditionalRush(let minimum):
                    if effectivePower(of: card, turn: turn) >= minimum { return true }
                default:
                    continue
                }
            }
        }
        return false
    }
}

// MARK: - Player side

/// One player's half of the board: every zone, plus their Leader's state.
struct PlayerSide: Codable, Hashable {

    let slot: PlayerSlot

    /// Collector number of the Leader anchoring this side.
    var leaderCardID: String

    /// Life remaining on the Leader. Reaching zero loses the game.
    var life: Int

    /// Face-down draw pile, top card first.
    var deck: [String]

    /// Cards held. Actions address these by index.
    var hand: [String]

    /// The five Chakra cards, face-up or face-down.
    var chakra: [ChakraCard]

    /// Bodies in play, in the order they were summoned. Unbounded: the mat
    /// draws five slots, and the row simply grows past them.
    var characters: [CharacterInPlay] = []

    /// Five numbered Support slots, each holding one face-down card. Setting
    /// one is free and unlimited; the chakra is paid on activation.
    var supports: [PlacedSupport?] = Array(repeating: nil, count: GameRules.supportSlots)

    /// Discard pile, most recently added last.
    var trash: [String] = []

    /// Cards removed from the game entirely. The reference initialises this
    /// zone and never touches it — reserved for a future EX mechanic — so it
    /// is modelled as an always-empty list the board can still draw.
    var exclusion: [String] = []

    // MARK: Leader state

    /// A rested Leader cannot attack and blocks the Recovery action.
    var leaderRested: Bool = false

    /// Attacks the Leader has declared this turn.
    var leaderAttacksUsed: Int = 0

    /// The Leader is frozen while `turn <= leaderCannotAttackUntilTurn` —
    /// only Itachi's On Summon can stamp this.
    var leaderCannotAttackUntilTurn: Int = 0

    /// Whether the Leader's Activate: Main was used this turn. Only boxes
    /// printing Once Per Turn actually check it.
    var leaderUsedThisTurn: Bool = false

    // MARK: Per-turn counters

    /// The single physical Summon card: rested when the turn's one normal
    /// summon is spent, standing again at the owner's next turn start.
    /// Cosmetic — the real gate is `summonsUsedThisTurn`.
    var summonRested: Bool = false

    /// Normal summons taken this turn. EX summons do not count.
    var summonsUsedThisTurn: Int = 0

    /// Whether this player has settled their one mulligan. Only the player
    /// going second ever gets the option.
    var mulliganDone: Bool = false

    /// The Recovery action is blocked while `turn < chakraLockedUntilTurn` —
    /// the rider on the negate jutsu that costs you your next Recovery.
    var chakraLockedUntilTurn: Int = 0

    // MARK: Derived

    /// Chakra still available to pay costs.
    var faceUpChakra: Int { chakra.lazy.filter(\.isFaceUp).count }

    /// Chakra already spent.
    var faceDownChakra: Int { chakra.count - faceUpChakra }

    func character(id: UUID) -> CharacterInPlay? {
        characters.first { $0.id == id }
    }

    func indexOfCharacter(id: UUID) -> Int? {
        characters.firstIndex { $0.id == id }
    }

    /// Whether any Support slot is free.
    var hasFreeSupportSlot: Bool { supports.contains { $0 == nil } }

    /// The face-down, not-yet-activated cards in Support slots, with the slot
    /// each occupies. These are what a response window is answered from.
    var faceDownSupports: [(slotIndex: Int, placed: PlacedSupport)] {
        supports.enumerated().compactMap { index, entry in
            guard let entry, !entry.isRevealed else { return nil }
            return (index, entry)
        }
    }

    /// Whether any card at all — even a revealed one — sits in a Support
    /// slot. The reference grants priority on exactly this test, so a player
    /// holding nothing but a spent card still gets offered the window.
    var hasAnySupportSet: Bool { supports.contains { $0 != nil } }

    // MARK: Mutation

    /// Flips the first `cost` face-up Chakra face-down. Deterministic order
    /// keeps replays identical; which Chakra pays is otherwise immaterial.
    /// - Returns: false when fewer than `cost` are face-up; nothing is paid.
    @discardableResult
    mutating func payChakra(_ cost: Int) -> Bool {
        guard faceUpChakra >= cost else { return false }
        var remaining = cost
        for index in chakra.indices where remaining > 0 {
            guard chakra[index].isFaceUp else { continue }
            chakra[index].isFaceUp = false
            remaining -= 1
        }
        return true
    }

    /// Turns every Chakra card face-up — the Recovery action's payoff.
    /// - Returns: how many were face-down, so the log can say what changed.
    @discardableResult
    mutating func flipAllChakraFaceUp() -> Int {
        let wasDown = faceDownChakra
        for index in chakra.indices { chakra[index].isFaceUp = true }
        return wasDown
    }

    /// Turn start for the active player: characters stand and per-turn
    /// counters reset. Chakra is deliberately untouched — only the Recovery
    /// action flips it face-up.
    mutating func beginTurn() {
        for index in characters.indices {
            characters[index].isRested = false
            characters[index].attacksUsed = 0
            characters[index].activatedThisTurn = false
        }
        leaderRested = false
        leaderAttacksUsed = 0
        leaderUsedThisTurn = false
        summonRested = false
        summonsUsedThisTurn = 0
    }

    /// End-of-turn wipe, applied to BOTH players: battle damage heals and the
    /// turn's stat bonuses expire. Turn-stamped fields expire by comparison
    /// instead, so they are left alone.
    mutating func wipeEndOfTurn() {
        for index in characters.indices {
            characters[index].damage = 0
            characters[index].powerBonus = 0
            characters[index].damageBonus = 0
        }
    }

    /// Places a card face-down in the first free Support slot.
    /// - Returns: the slot's number as the journal prints it — one-based — or
    ///   `nil` when every slot is occupied.
    mutating func setSupport(_ placed: PlacedSupport) -> Int? {
        guard let free = supports.firstIndex(where: { $0 == nil }) else { return nil }
        supports[free] = placed
        return free + 1
    }

    /// Removes the placed card with `id` from whichever slot holds it.
    /// - Returns: the card number that left the slot.
    @discardableResult
    mutating func removeSupport(id: UUID) -> String? {
        guard let index = supports.firstIndex(where: { $0?.id == id }),
              let placed = supports[index] else { return nil }
        supports[index] = nil
        return placed.cardID
    }

    mutating func rest(characterID: UUID) {
        guard let index = indexOfCharacter(id: characterID) else { return }
        characters[index].isRested = true
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

    /// Removes a character from the row and puts its card back in its
    /// owner's hand, dropping all in-play state.
    /// - Returns: the card number bounced, for the journal line.
    @discardableResult
    mutating func bounceCharacterToHand(id: UUID) -> String? {
        guard let index = indexOfCharacter(id: id) else { return nil }
        let removed = characters.remove(at: index)
        hand.append(removed.cardID)
        return removed.cardID
    }
}

// MARK: - Pending attack

/// The card doing the attacking — the Leader attacks too, once per turn.
enum AttackerReference: Hashable, Codable {
    case leader
    case character(UUID)

    var characterID: UUID? {
        if case .character(let id) = self { return id }
        return nil
    }
}

/// An attack that has been declared and is waiting on the defender's counter
/// window. The attacker rested and spent its attack at declaration, and gets
/// neither back even if the attack is interrupted.
struct PendingAttack: Identifiable, Hashable, Codable {
    let id: UUID

    /// The side that declared the attack.
    let attackingSlot: PlayerSlot

    /// Who is swinging: the Leader, or a character by in-play identity.
    let attacker: AttackerReference

    /// What the attack was aimed at: the enemy Leader — always legal — or a
    /// rested enemy character.
    let target: AttackTarget

    /// The side that holds priority in the counter window.
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
        case .deckOut:      return "a deck ran out of cards"
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

// MARK: - Turn state

/// What the game is waiting for, as the player sees it. Derived rather than
/// stored so it can never drift out of step with the board it describes.
enum TurnState: Hashable {

    /// The player going second is keeping or redrawing their opening hand.
    case openingMulligan(PlayerSlot)

    /// A prompt is open — a target pick, a hand pick, an EX payment — and
    /// nothing else may happen until it is answered.
    case choosing(PendingChoice)

    /// A response window is open: the priority holder may activate a Support
    /// or pass.
    case awaitingResponse(ResponseWindow)

    /// The undivided main phase. Summon, set Supports, activate, attack, in
    /// any order, until END TURN.
    case acting

    /// The game has been decided.
    case finished

    /// Short label for the status bar.
    var title: String {
        switch self {
        case .openingMulligan:  return "Refresh"
        case .choosing:         return "Choose"
        case .awaitingResponse: return "Counter Step"
        case .acting:           return "Main"
        case .finished:         return "Game over"
        }
    }

    /// The sentence shown on the status strip.
    var prompt: String {
        switch self {
        case .openingMulligan:
            return "Keep this hand, or draw a new one"
        case .choosing(let choice):
            return choice.prompt
        case .awaitingResponse(let window):
            return window.prompt
        case .acting:
            return "Your turn, play a card or attack"
        case .finished:
            return "The game has finished"
        }
    }

    /// The window, when one is open.
    var responseWindow: ResponseWindow? {
        if case .awaitingResponse(let window) = self { return window }
        return nil
    }
}

// MARK: - Game state

/// The complete board. Only `GameEngine` should mutate this; the UI reads it.
struct GameState: Codable, Hashable {

    var player: PlayerSide
    var opponent: PlayerSide

    /// The active player — whose turn it is.
    var current: PlayerSlot

    /// Who took the first turn, which sizes the opening draw.
    var firstPlayer: PlayerSlot

    /// The global turn counter, starting at 1: turn 1 is the first player's
    /// first turn, turn 2 their opponent's, and so on. Every turn-stamped
    /// duration on the board compares against this number.
    var turnNumber: Int = 1

    var phase: GamePhase = .refresh
    var step: GameStep = .normal

    /// Who may act in a counter step. Nil outside one.
    var priority: PlayerSlot? = nil

    /// Back-to-back passes: two in a row resolve the chain.
    var consecutivePasses: Int = 0

    /// The chain of activated Supports, top last. Resolves strictly LIFO once
    /// both players stop responding.
    var chain: [ChainLink] = []

    /// The chain link currently mid-resolution, paused on a prompt.
    var resolvingSupport: ResolvingSupport? = nil

    /// Set between an attack declaration and its resolution.
    var pendingAttack: PendingAttack? = nil

    /// An open prompt. Blocks every action except answering it.
    var pendingChoice: PendingChoice? = nil

    /// Prompts raised while one was already open, answered in order.
    var queuedChoices: [PendingChoice] = []

    /// A summon window deferred until the summon's own prompts resolve.
    var owedSummonWindow: PlayerSlot? = nil

    /// The player going second, until they keep or redraw. The first player
    /// never gets the option.
    var awaitingMulligan: PlayerSlot? = nil

    var outcome: GameOutcome = .ongoing

    /// Carried in the state so every shuffle after setup stays reproducible.
    var rng: SeededGenerator

    // MARK: Access

    subscript(slot: PlayerSlot) -> PlayerSide {
        get { slot == .player ? player : opponent }
        set {
            if slot == .player { player = newValue } else { opponent = newValue }
        }
    }

    var isFinished: Bool { outcome.isFinished }

    /// Who the game is waiting on: the chooser, the mulliganing player, the
    /// priority holder, or the active player — in that order of urgency.
    var decider: PlayerSlot? {
        guard !isFinished else { return nil }
        if let pendingChoice { return pendingChoice.player }
        if let awaitingMulligan { return awaitingMulligan }
        if step == .counter { return priority }
        return current
    }

    /// What the game is waiting for, as the player sees it.
    var turnState: TurnState {
        if isFinished { return .finished }
        if let awaitingMulligan { return .openingMulligan(awaitingMulligan) }
        if let pendingChoice { return .choosing(pendingChoice) }
        if let window = responseWindow { return .awaitingResponse(window) }
        return .acting
    }

    /// Finds a character on either board, with the side that owns it.
    func locateCharacter(id: UUID) -> (slot: PlayerSlot, character: CharacterInPlay)? {
        for slot in PlayerSlot.allCases {
            if let character = self[slot].character(id: id) { return (slot, character) }
        }
        return nil
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
