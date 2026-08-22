//
//  ResponseWindow.swift
//  NTCGSimulator
//
//  The whole vocabulary of the reference's counter step: the timing classes
//  that decide which face-down cards may answer which windows, the chain that
//  activations stack onto, and the prompts — target picks, hand picks, EX
//  payments — that pause everything until they are answered.
//
//  Three moments open a window. An attack declaration always opens one, with
//  priority to the defender. A summon always opens one, with priority to the
//  summoner's opponent — deferred while the summon's own prompts resolve. A
//  support activation opens one only when somebody could actually respond;
//  otherwise the chain resolves at once. Responses stack: every activation
//  re-opens priority, and the chain resolves strictly last-in-first-out once
//  both players stop answering.
//

import Foundation

// MARK: - Timing classes

/// Which windows a Support may be activated into, classified from its printed
/// timing line exactly as the reference classifies them.
enum TimingClass: Hashable {

    /// "During Your Main": your turn, main phase, no attack pending. Also
    /// usable mid-chain when you hold priority.
    case main

    /// "Quick": anywhere `main` works, or inside ANY open window or chain —
    /// an attack window, a summon window, a support chain — either player.
    case quick

    /// "During Your Opponent's Attack": only while an attack against you is
    /// pending, and only by the defender.
    case counter

    /// "Support Activated": only while the chain is non-empty — strictly an
    /// answer to another support or jutsu activation, never to a bare summon
    /// or attack declaration.
    case response

    /// Not a Support timing at all; never activatable through the chain.
    case none
}

extension AbilityTrigger {

    /// The timing class this trigger belongs to when printed as a Support
    /// line. Non-support triggers class as `.none`.
    var timingClass: TimingClass {
        switch self {
        case .duringYourMain:  return .main
        case .quick:           return .quick
        case .opponentsAttack: return .counter
        case .support:         return .response
        default:               return .none
        }
    }
}

// MARK: - Chain

/// One activated Support waiting to resolve: who played it, which card, where
/// it sits, and the targets locked when it was activated.
struct ChainLink: Identifiable, Hashable, Codable {

    /// The identity of the `PlacedSupport` occupying the slot — a card played
    /// from hand transits through a slot too, so every link has one.
    let id: UUID

    /// The player who activated it.
    let player: PlayerSlot

    /// Collector number of the card, for its effects and its name.
    let cardID: String

    /// True when the card came from hand mid-window rather than from a
    /// face-down slot — the journal names the two differently.
    let playedFromHand: Bool

    /// Characters chosen at activation time, before the response window
    /// opened. Immunity is checked at resolution, not here.
    var lockedTargets: [UUID] = []
}

/// The chain link currently mid-resolution, paused on a prompt. `keepsCard`
/// remembers whether the effect self-summoned the card, so disposal after the
/// prompt sends it to the right place.
struct ResolvingSupport: Hashable, Codable {
    var link: ChainLink
    var keepsCard: Bool = false
}

// MARK: - Window

/// What kind of moment a counter step is answering.
enum ResponseWindowKind: String, Hashable, Codable {

    /// An attack was declared; the defender answers first.
    case attack

    /// A character was summoned; the summoner's opponent answers.
    case summon

    /// A Support was activated; priority is bouncing over a live chain.
    case chain

    var title: String {
        switch self {
        case .attack: return "Answer the attack"
        case .summon: return "Answer the summon"
        case .chain:  return "Answer the chain"
        }
    }
}

/// One open response window, derived from the board rather than stored, so it
/// can never disagree with the step and priority that define it.
struct ResponseWindow: Hashable, Codable {

    /// What opened it, or is currently on top of it.
    let kind: ResponseWindowKind

    /// The player who holds priority and may activate or pass.
    let respondingSlot: PlayerSlot

    /// How many Supports are stacked waiting to resolve.
    let chainLength: Int

    /// The sentence shown on the status strip.
    var prompt: String {
        chainLength > 0
            ? "You may answer with a Support, or pass"
            : "You may answer with a face-down card"
    }
}

extension GameState {

    /// The open response window, when a counter step is live.
    var responseWindow: ResponseWindow? {
        guard step == .counter, let priority else { return nil }
        let kind: ResponseWindowKind
        if !chain.isEmpty {
            kind = .chain
        } else if pendingAttack != nil {
            kind = .attack
        } else {
            kind = .summon
        }
        return ResponseWindow(kind: kind, respondingSlot: priority, chainLength: chain.count)
    }
}

// MARK: - Choices

/// A thing an open prompt can point at. Characters and Leaders live on the
/// board; hand, trash and deck references address hidden zones by position.
enum ChoiceTarget: Hashable, Codable {
    case character(UUID)
    case leader(PlayerSlot)
    case handCard(index: Int)
    case trashCard(slot: PlayerSlot, index: Int)
    case deckCard(slot: PlayerSlot, index: Int)

    /// The character's in-play identity, when the target is a body.
    var characterID: UUID? {
        if case .character(let id) = self { return id }
        return nil
    }
}

/// One selectable option in a prompt, keyed for `GameAction.resolveChoice`.
struct ChoiceOption: Identifiable, Hashable, Codable {

    /// Stable key the resolving action names. Unique within its choice.
    let key: String

    /// What the key points at.
    let target: ChoiceTarget

    /// The option as the player reads it — a card name, usually.
    let title: String

    var id: String { key }
}

/// Which prompt is open, which decides how the engine applies the answer.
enum ChoiceKind: String, Codable, Hashable {

    /// Targets locked at activation time for a Support with a choose clause.
    /// Multi-select up to the clause's count; cancellable only for "up to".
    case lockTarget

    /// N-001's +power pick, over all characters on either board. Cancelling
    /// still spends the chakra.
    case leaderBoost

    /// N-012's put-back: one hand card goes on top of the deck.
    case leaderPutBack

    /// Itachi's freeze target: any Leader or character, either side.
    case freezeTarget

    /// A K.O. pick. Multi-K.O.s chain one pick at a time.
    case koTarget

    /// A bounce pick raised at resolution when no target was locked.
    case bounceTarget

    /// A double-power pick raised at resolution when no target was locked.
    case doublePower

    /// A support-immunity pick raised at resolution when no target was locked.
    case supportImmune

    /// One slot of an EX Summon Requirement: which character pays it.
    case exRequirement

    /// Gamabunta's revive: a named character card in the trash.
    case reviveFromTrash

    /// The Naruto EX search over deck and trash.
    case searchSummon
}

/// The context a prompt carries so the engine can finish what raised it — the
/// reference's `data{}` bag, typed.
struct ChoiceData: Hashable, Codable {

    /// The card whose effect raised the prompt.
    var sourceCardID: String = ""

    /// A trait gate — the freeze's reveal condition.
    var trait: String = ""

    /// A numeric payload — the leader boost amount.
    var amount: Int = 0

    /// Picks still owed after this one — multi-K.O.s count down.
    var remaining: Int = 0

    /// Filters for re-raised K.O. picks.
    var restedOnly: Bool = false
    var nonEXOnly: Bool = false
    var upTo: Bool = false

    /// The chain link a `lockTarget` prompt is aiming for.
    var chainLinkID: UUID?

    /// EX payment bookkeeping: the hand card being summoned, the requirement
    /// slots still unpaid, and the characters already committed.
    var pendingSummonHandIndex: Int?
    var requirementSlots: [TrashRequirement] = []
    var paidCharacterIDs: [UUID] = []

    init() {}
}

/// An open prompt: who answers, what they pick from, and how. Blocks every
/// action except `GameAction.resolveChoice` until it is answered.
///
/// A prompt with a single option that is neither cancellable nor `alwaysAsk`
/// resolves itself; one with zero options is skipped silently. Prompts raised
/// while one is open queue first-in-first-out.
struct PendingChoice: Identifiable, Hashable, Codable {

    let id: UUID

    let kind: ChoiceKind

    /// The player who answers.
    let player: PlayerSlot

    /// The question as the player reads it.
    let prompt: String

    /// What may be picked.
    let options: [ChoiceOption]

    /// Whether the prompt may be declined — resolving with no keys.
    let cancellable: Bool

    /// Forces the prompt in front of the player even with one option — every
    /// K.O. pick does this, so a kill is always confirmed.
    let alwaysAsk: Bool

    /// Distinct keys one answer may carry. One for everything but a
    /// multi-target lock.
    let maxSelections: Int

    /// The context the engine needs to finish what raised the prompt.
    var data: ChoiceData

    init(
        id: UUID,
        kind: ChoiceKind,
        player: PlayerSlot,
        prompt: String,
        options: [ChoiceOption],
        cancellable: Bool = false,
        alwaysAsk: Bool = false,
        maxSelections: Int = 1,
        data: ChoiceData = ChoiceData()
    ) {
        self.id = id
        self.kind = kind
        self.player = player
        self.prompt = prompt
        self.options = options
        self.cancellable = cancellable
        self.alwaysAsk = alwaysAsk
        self.maxSelections = maxSelections
        self.data = data
    }

    /// Whether the engine may answer this itself: exactly one option, no
    /// permission to decline, and no insistence on asking.
    var resolvesAutomatically: Bool {
        options.count == 1 && !cancellable && !alwaysAsk
    }

    func option(forKey key: String) -> ChoiceOption? {
        options.first { $0.key == key }
    }
}

// MARK: - The Support half

extension Card {

    /// The box printed inside the card's SUPPORT bar — the jutsu half that a
    /// face-down slot or a from-hand play activates. Exactly one per card in
    /// the shipped pool.
    var supportBarAbility: (index: Int, ability: CardAbility)? {
        guard let index = abilities.firstIndex(where: { $0.trigger.isSupportTiming }) else {
            return nil
        }
        return (index, abilities[index])
    }
}
