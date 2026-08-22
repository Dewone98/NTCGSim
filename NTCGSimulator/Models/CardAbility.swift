//
//  CardAbility.swift
//  NTCGSimulator
//
//  The ability model, aligned to the reference engine's actual rules.
//
//  The reference dispatches every Support effect by pattern-matching the
//  printed text; this model carries the same vocabulary as structured cases
//  instead, so a card's behaviour is data rather than a regex. Each printed
//  box is a `CardAbility`: a trigger (which doubles as the Support timing
//  class), a cost, and a list of `AbilityEffect` steps the engine resolves in
//  print order.
//

import Foundation

// MARK: - Trigger

/// When an ability may be used, taken from the keyword tag printed on the card.
///
/// The last four cases are the Support timing strings — `During Your Main`,
/// `Quick`, `During Your Opponent's Attack` and `Support Activated` — which the
/// reference classifies into the four timing classes that decide which windows
/// a face-down card may answer. See `TimingClass` in ResponseWindow.swift.
enum AbilityTrigger: String, Codable, Hashable, CaseIterable {

    /// No keyword tag: a standing rule that is always true.
    case passive

    /// Activated by the player during their own main phase — Leader effects
    /// and Ino's team boost.
    case activateMain

    /// Resolves as the card arrives on the board, by any route.
    case onSummon

    /// Resolves as the card declares an attack, before the defender's window.
    case whenAttacking

    /// A standing rule that applies only on its controller's turn.
    case yourTurn

    /// The Recovery action printed on Leaders: rest the Leader, flip all
    /// chakra face-up, from the second game turn onwards.
    case recovery

    /// A cost that must be paid to summon the card at all — the EX door.
    case summonRequirement

    /// Support timing "During Your Main": proactive, own main phase only.
    case duringYourMain

    /// Support timing "Quick": own main phase, or inside any open window or
    /// chain, either player, subject to priority.
    case quick

    /// Support timing "During Your Opponent's Attack": only while an attack
    /// against you is pending, and only by the defender.
    case opponentsAttack

    /// Support timing "Support Activated": only in answer to another support
    /// on the chain — never a bare summon or attack declaration.
    case support

    /// Label shown on the card and in the log.
    var title: String {
        switch self {
        case .passive:           return ""
        case .activateMain:      return "Activate: Main"
        case .onSummon:          return "On Summon"
        case .whenAttacking:     return "When Attacking"
        case .yourTurn:          return "Your Turn"
        case .recovery:          return "Recovery"
        case .summonRequirement: return "Summon Requirements"
        case .duringYourMain:    return "During Your Main"
        case .quick:             return "Quick"
        case .opponentsAttack:   return "During Your Opponent's Attack"
        case .support:           return "Support Activated"
        }
    }

    /// Whether this box is the jutsu half of the card — the line activated
    /// from a Support slot or from hand, opening a chain.
    var isSupportTiming: Bool {
        switch self {
        case .duringYourMain, .quick, .opponentsAttack, .support: return true
        default: return false
        }
    }

    /// Whether the player presses a button for this, rather than it firing by
    /// itself. Support timings are pressed too, but through the activation
    /// actions rather than `useAbility`-style buttons.
    var isPlayerActivated: Bool {
        self == .activateMain || isSupportTiming
    }
}

// MARK: - Cost

/// One character the Summon Requirements ask to be placed in the trash. An
/// empty requirement accepts any of your characters; the filters narrow it.
struct TrashRequirement: Codable, Hashable {

    /// A trait the paying character must print, e.g. `The Taka`.
    var trait: String?

    /// Minimum *effective* power — buffs and doubling count, exactly as the
    /// reference checks them at payment time.
    var minimumPower: Int?

    init(trait: String? = nil, minimumPower: Int? = nil) {
        self.trait = trait
        self.minimumPower = minimumPower
    }

    /// Decoded leniently: a hand-authored card file omits whatever does not
    /// apply, and an empty object `{}` means "any character".
    init(from decoder: Decoder) throws {
        let box = try decoder.container(keyedBy: CodingKeys.self)
        trait = try box.decodeIfPresent(String.self, forKey: .trait)
        minimumPower = try box.decodeIfPresent(Int.self, forKey: .minimumPower)
    }

    /// Whether a character satisfies this slot, given its printed card and
    /// its current effective power.
    func isSatisfied(byTraits traits: [String], effectivePower: Int) -> Bool {
        if let trait, !traits.contains(trait) { return false }
        if let minimumPower, effectivePower < minimumPower { return false }
        return true
    }

    /// Short description for cost summaries.
    var summary: String {
        var piece = "1 character"
        if let trait { piece += " ({\(trait)} type)" }
        if let minimumPower { piece += " with \(minimumPower)+ power" }
        return piece
    }
}

/// What must be paid before an ability resolves.
struct AbilityCost: Codable, Hashable {

    /// Chakra flipped face-down — the game's main resource cost, never
    /// refunded, not even when the paid card is negated.
    var chakra: Int = 0

    /// The Summon Requirements: one slot per character that must be trashed,
    /// each slot with its own filters. Distinct characters pay distinct slots.
    var trashRequirements: [TrashRequirement] = []

    var isFree: Bool { chakra == 0 && trashRequirements.isEmpty }

    /// How many characters the requirements consume. Kept as a named count
    /// because several callers only need the number.
    var trashOwnCharacters: Int { trashRequirements.count }

    init(chakra: Int = 0, trashRequirements: [TrashRequirement] = []) {
        self.chakra = chakra
        self.trashRequirements = trashRequirements
    }

    /// Decoded leniently: a hand-authored card file omits whatever does not
    /// apply, and Swift's synthesised decoding would otherwise reject it
    /// because default values are not consulted when a key is missing.
    init(from decoder: Decoder) throws {
        let box = try decoder.container(keyedBy: CodingKeys.self)
        chakra = try box.decodeIfPresent(Int.self, forKey: .chakra) ?? 0
        trashRequirements = try box.decodeIfPresent(
            [TrashRequirement].self, forKey: .trashRequirements
        ) ?? []
    }

    /// Short description for the activation button.
    var summary: String {
        var parts: [String] = []
        if chakra > 0 { parts.append("\(chakra) chakra") }
        for requirement in trashRequirements { parts.append("trash \(requirement.summary)") }
        return parts.isEmpty ? "free" : parts.joined(separator: " + ")
    }
}

// MARK: - Target

/// Who or what an ability acts on, as printed. Display vocabulary: the engine
/// derives its actual targeting from the structured effects, but the card
/// screens still describe a box's reach in these terms.
enum AbilityTargetScope: String, Codable, Hashable {
    case none
    case anyCharacter
    case friendlyCharacter
    case opposingCharacter
    case restedCharacter
    case leaderOrCharacter
    case allCharacters
    case selfCard
    case ownTeam

    var needsPlayerChoice: Bool {
        switch self {
        case .none, .allCharacters, .selfCard, .ownTeam: return false
        default: return true
        }
    }

    var prompt: String {
        switch self {
        case .anyCharacter:      return "Choose a character"
        case .friendlyCharacter: return "Choose one of your characters"
        case .opposingCharacter: return "Choose an opposing character"
        case .restedCharacter:   return "Choose a rested character"
        case .leaderOrCharacter: return "Choose a Leader or character"
        default:                 return ""
        }
    }
}

// MARK: - Effect

/// One executable step, mirroring the reference engine's effect table case
/// for case. Anything the engine cannot resolve is carried as
/// `.unimplemented`, so a card is never silently wrong — with the current
/// pool that escape hatch is empty for every card.
enum AbilityEffect: Codable, Hashable {

    // MARK: Generic steps

    /// Draw N. A Leader-effect draw from an empty deck simply does nothing —
    /// the deck-out sweep decides the game at the next check instead.
    case drawCards(Int)

    /// Choose N cards from hand to put on top of the deck, in a prompt.
    case placeFromHandOnDeck(Int)

    /// The activator gains life. Uncapped.
    case gainLife(Int)

    /// The activator loses life, floored at zero. Reaching zero loses the
    /// game on the spot — the opponent wins.
    case loseLife(Int)

    // MARK: Chain answers

    /// "Negate that card": removes the chain link directly below this one.
    /// The negated card goes to its owner's trash without its effect running;
    /// its chakra stays paid. Whiffs silently on an empty chain, but any
    /// riders after this step still apply.
    case negateChainLink

    /// "Interrupt": cancels the pending attack. The attacker stays rested and
    /// keeps its spent attack. Fizzles against a support-immune attacker.
    case interruptAttack

    /// "You cannot turn your CHAKRA face-up": the activator's Recovery is
    /// blocked through their next own turn.
    case chakraLock

    // MARK: Board changes

    /// "Summon this card": the support card itself becomes a character on the
    /// activator's field, with summoning sickness, and is kept rather than
    /// trashed. Effect-driven summons open no response window.
    case summonSelf

    /// "Power is doubled": the locked target's power becomes twice its
    /// *printed* power plus its bonus — the bonus is not doubled.
    case doubleChosenPower

    /// "Will not be affected by your opponent's Support effects": the locked
    /// target becomes immune to the activator's opponent for this turn, while
    /// a support is resolving or a chain is live.
    case grantSupportImmunity

    /// "K.O. all Characters": both boards, Leaders untouched, support-immune
    /// characters skipped.
    case knockOutAll

    /// "Choose N [rested] [non-EX] Characters: K.O. the chosen cards." The
    /// choose clause is locked at activation time; `upTo` makes the targeting
    /// cancellable and allows fewer than N.
    case knockOutChosen(count: Int, upTo: Bool, restedOnly: Bool, nonEXOnly: Bool)

    /// "Return the chosen card to the owner's hand": all in-play state lost.
    case returnChosenToHand

    // MARK: Leader and character skills

    /// N-001's Leader effect: the chosen character — either side — gains
    /// power until end of turn, through a cancellable prompt.
    case boostChosenPower(Int)

    /// Ino's team boost: if every name in `requires` is on your field, each
    /// of your characters named in `boosts` gains power, damage and Rush for
    /// the turn.
    case teamBoost(requires: [String], boosts: [String], power: Int, damage: Int)

    /// Itachi's freeze: choose any Leader or character, reveal your top deck
    /// card, and if it prints `trait` the chosen card cannot attack through
    /// the opponent's next turn. The revealed card stays on the deck.
    case freezeChosenIfRevealTrait(String)

    /// Gamabunta's revive: summon one non-EX character named in `names` from
    /// your trash. Its own On Summon triggers fire again.
    case summonFromTrash(names: [String])

    /// Manda's and Jugo's reveal: reveal the top deck card and summon it if
    /// it is a non-EX character matching a listed name or trait — empty
    /// filters accept any non-EX character. A miss stays on top of the deck.
    case revealTopAndSummon(names: [String], traits: [String])

    /// The Naruto EX search: summon up to one card named `name` from your
    /// deck or trash with its effects negated. The deck is not reshuffled.
    case searchSummonNegated(name: String)

    // MARK: Standing rules

    /// The printed `[Rush]` label: exempt from summoning sickness. Suppressed
    /// while the character's effects are negated.
    case rush

    /// Minato's conditional Rush: Rush whenever effective power reaches the
    /// threshold, checked at attack declaration. Suppressed when negated.
    case conditionalRush(minimumPower: Int)

    /// The card never reaches the board through the normal summon — its
    /// Summon Requirements are the only door in.
    case cannotBeSummonedNormally

    /// The Recovery action's printed steps: rest the Leader and flip all your
    /// chakra face-up. The engine performs it through the `recovery` action.
    case recovery

    /// A step the engine does not resolve yet. `text` is shown to the player.
    case unimplemented(String)

    // MARK: Description

    /// Human-readable summary used in the journal and on card screens.
    var summary: String {
        switch self {
        case .drawCards(let n):             return "draw \(n) card\(n == 1 ? "" : "s")"
        case .placeFromHandOnDeck(let n):   return "place \(n) card\(n == 1 ? "" : "s") from hand on top of the deck"
        case .gainLife(let n):              return "gain \(n) life"
        case .loseLife(let n):              return "reduce your life by \(n)"
        case .negateChainLink:              return "negate that card"
        case .interruptAttack:              return "interrupt that attack"
        case .chakraLock:                   return "cannot turn chakra face-up until after your next turn"
        case .summonSelf:                   return "summon this card"
        case .doubleChosenPower:            return "the chosen card's power is doubled this turn"
        case .grantSupportImmunity:         return "the chosen card ignores your opponent's Support effects this turn"
        case .knockOutAll:                  return "K.O. all characters"
        case .knockOutChosen(let n, let upTo, _, _):
            return "K.O. \(upTo ? "up to " : "")\(n) chosen character\(n == 1 ? "" : "s")"
        case .returnChosenToHand:           return "return the chosen card to its owner's hand"
        case .boostChosenPower(let n):      return "the chosen card gets +\(n) power this turn"
        case .teamBoost(_, _, let p, let d): return "the team gains +\(p) power, +\(d) damage and Rush this turn"
        case .freezeChosenIfRevealTrait(let trait):
            return "reveal the top card — a {\(trait)} card freezes the chosen target"
        case .summonFromTrash:              return "summon a named character from your trash"
        case .revealTopAndSummon:           return "reveal the top card and summon it if it matches"
        case .searchSummonNegated(let name): return "summon [\(name)] from deck or trash with effects negated"
        case .rush:                          return "Rush"
        case .conditionalRush(let n):        return "gains Rush at \(n) or more power"
        case .cannotBeSummonedNormally:      return "cannot be summoned normally"
        case .recovery:                      return "rest the Leader and flip all chakra face-up"
        case .unimplemented(let text):       return text
        }
    }

    /// False when the engine only displays this step rather than applying it.
    var isExecutable: Bool {
        if case .unimplemented = self { return false }
        return true
    }
}

// MARK: - Target lock

/// The "choose N … characters:" clause parsed off a Support's printed text.
///
/// The reference locks these targets at activation time — before the response
/// window opens — so the opponent sees what is aimed where before deciding to
/// answer. Immunity is deliberately NOT checked at lock time; it fizzles the
/// effect at resolution instead.
struct TargetLockRequest: Hashable {

    /// How many distinct characters may be chosen.
    let count: Int

    /// True for "up to N": the choice is cancellable and fewer than N — even
    /// zero — is allowed.
    let upTo: Bool

    /// Only rested characters qualify.
    let restedOnly: Bool

    /// EX Characters are excluded.
    let nonEXOnly: Bool

    /// A mandatory clause blocks activation entirely when no character
    /// matches the filters — the reference's `noTarget`.
    var isMandatory: Bool { !upTo }
}

// MARK: - Ability

/// One printed ability box.
struct CardAbility: Codable, Hashable, Identifiable {

    var id: String { "\(trigger.rawValue)-\(text.prefix(24))" }

    let trigger: AbilityTrigger

    /// Whether the card prints an "Once Per Turn" tag. Its absence on an
    /// Activate: Main box means unlimited uses — N-001's Leader effect.
    var oncePerTurn: Bool = false

    var cost: AbilityCost = AbilityCost()

    /// What the player must choose, as printed. Display only — the engine
    /// derives targeting from `effects` and `targetLock`.
    var target: AbilityTargetScope = .none

    /// The ability as printed, shown on the card detail screen.
    var text: String

    /// The executable breakdown, resolved in order.
    var effects: [AbilityEffect] = []

    /// True when every step can actually be applied by the engine.
    var isFullyImplemented: Bool {
        effects.allSatisfy(\.isExecutable)
    }

    /// True when the player activates this by pressing something.
    var isActivated: Bool { trigger.isPlayerActivated }

    /// The choose clause locked at activation, when the effects print one.
    var targetLock: TargetLockRequest? {
        for effect in effects {
            switch effect {
            case .knockOutChosen(let count, let upTo, let restedOnly, let nonEXOnly):
                return TargetLockRequest(
                    count: count, upTo: upTo, restedOnly: restedOnly, nonEXOnly: nonEXOnly
                )
            case .returnChosenToHand, .doubleChosenPower, .grantSupportImmunity:
                return TargetLockRequest(count: 1, upTo: false, restedOnly: false, nonEXOnly: false)
            default:
                continue
            }
        }
        return nil
    }

    /// Whether resolving this box keeps the card on the board as a character
    /// instead of sending it to the trash — the "summon this card" effects.
    var keepsCardOnResolution: Bool {
        effects.contains(.summonSelf)
    }

    /// Whether this box answers the chain by cancelling the link below it.
    var negatesChainLink: Bool {
        effects.contains(.negateChainLink)
    }

    init(trigger: AbilityTrigger, oncePerTurn: Bool = false,
         cost: AbilityCost = AbilityCost(), target: AbilityTargetScope = .none,
         text: String, effects: [AbilityEffect] = []) {
        self.trigger = trigger
        self.oncePerTurn = oncePerTurn
        self.cost = cost
        self.target = target
        self.text = text
        self.effects = effects
    }

    /// Lenient for the same reason as `AbilityCost`.
    init(from decoder: Decoder) throws {
        let box = try decoder.container(keyedBy: CodingKeys.self)
        trigger = try box.decode(AbilityTrigger.self, forKey: .trigger)
        text = try box.decode(String.self, forKey: .text)
        oncePerTurn = try box.decodeIfPresent(Bool.self, forKey: .oncePerTurn) ?? false
        cost = try box.decodeIfPresent(AbilityCost.self, forKey: .cost) ?? AbilityCost()
        target = try box.decodeIfPresent(AbilityTargetScope.self, forKey: .target) ?? .none
        effects = try box.decodeIfPresent([AbilityEffect].self, forKey: .effects) ?? []
    }
}
