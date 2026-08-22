//
//  CardAbility.swift
//  NTCGSimulator
//
//  The ability model.
//
//  An earlier version of this app carried a single optional `LeaderAbility`
//  with four hardcoded cases. Real cards do not fit that shape at all: they
//  print several ability boxes, each with its own trigger, its own cost — a
//  chakra flipped face-down, or your own Characters trashed — and effects that
//  target. This model is derived from the printed cards rather than guessed.
//

import Foundation

// MARK: - Trigger

/// When an ability may be used, taken from the keyword tag printed on the card.
enum AbilityTrigger: String, Codable, Hashable, CaseIterable {

    /// No keyword tag: a standing rule that is always true.
    case passive

    /// Activated by the player during their own main phase.
    case activateMain

    /// Usable during your main phase, typically by spending chakra.
    case duringYourMain

    /// Resolves as the card arrives on the board.
    case onSummon

    /// Resolves as the card declares an attack.
    case whenAttacking

    /// A standing rule that applies only on its controller's turn.
    case yourTurn

    /// Resolves during the recovery step at the start of a turn.
    case recovery

    /// A condition that must be paid to summon the card at all.
    case summonRequirement

    /// The card's Support line, played as a jutsu instead of being summoned.
    case support

    /// A response window during the opponent's attack.
    case opponentsAttack

    /// Label shown on the card and in the log.
    var title: String {
        switch self {
        case .passive:          return ""
        case .activateMain:     return "Activate: Main"
        case .duringYourMain:   return "During Your Main"
        case .onSummon:         return "On Summon"
        case .whenAttacking:    return "When Attacking"
        case .yourTurn:         return "Your Turn"
        case .recovery:         return "Recovery"
        case .summonRequirement:return "Summon Requirements"
        case .support:          return "Support"
        case .opponentsAttack:  return "During Your Opponent's Attack"
        }
    }

    /// Whether the player presses a button for this, rather than it firing by
    /// itself. These are the ones the board must offer as an action.
    var isPlayerActivated: Bool {
        self == .activateMain || self == .duringYourMain || self == .opponentsAttack
    }
}

// MARK: - Cost

/// What must be paid before an ability resolves.
struct AbilityCost: Codable, Hashable {

    /// Chakra flipped face-down. This is the game's main resource cost.
    var chakra: Int = 0

    /// Your own Characters that must be placed in the trash.
    var trashOwnCharacters: Int = 0

    /// Restricts which of your Characters may pay `trashOwnCharacters`.
    var trashTrait: String?

    /// Minimum power a Character must have to pay the cost.
    var trashMinimumPower: Int?

    var isFree: Bool {
        chakra == 0 && trashOwnCharacters == 0
    }

    init(chakra: Int = 0, trashOwnCharacters: Int = 0,
         trashTrait: String? = nil, trashMinimumPower: Int? = nil) {
        self.chakra = chakra
        self.trashOwnCharacters = trashOwnCharacters
        self.trashTrait = trashTrait
        self.trashMinimumPower = trashMinimumPower
    }

    /// Decoded leniently: a hand-authored card file omits whatever does not
    /// apply, and Swift's synthesised decoding would otherwise reject it
    /// because default values are not consulted when a key is missing.
    init(from decoder: Decoder) throws {
        let box = try decoder.container(keyedBy: CodingKeys.self)
        chakra = try box.decodeIfPresent(Int.self, forKey: .chakra) ?? 0
        trashOwnCharacters = try box.decodeIfPresent(Int.self, forKey: .trashOwnCharacters) ?? 0
        trashTrait = try box.decodeIfPresent(String.self, forKey: .trashTrait)
        trashMinimumPower = try box.decodeIfPresent(Int.self, forKey: .trashMinimumPower)
    }

    /// Short description for the activation button.
    var summary: String {
        var parts: [String] = []
        if chakra > 0 { parts.append("\(chakra) chakra") }
        if trashOwnCharacters > 0 {
            var piece = "trash \(trashOwnCharacters) character"
            if trashOwnCharacters > 1 { piece += "s" }
            if let trashTrait { piece += " (\(trashTrait))" }
            if let trashMinimumPower { piece += " with \(trashMinimumPower)+ power" }
            parts.append(piece)
        }
        return parts.isEmpty ? "free" : parts.joined(separator: " + ")
    }
}

// MARK: - Target

/// Who or what an ability acts on.
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

/// One executable step. Anything the engine cannot yet resolve is carried as
/// `.unimplemented`, so a card is never silently wrong: the text still shows,
/// and the log says plainly that the step was not applied.
enum AbilityEffect: Codable, Hashable {

    case drawCards(Int)
    case placeFromHandOnDeck(Int)
    case gainLife(Int)
    case loseLife(Int)

    /// Power change lasting until end of turn.
    case buffPower(Int, AbilityTargetScope)

    /// Damage change lasting until end of turn.
    case buffDamage(Int, AbilityTargetScope)

    /// Grants Rush: the card may attack the turn it arrives.
    case grantRush(AbilityTargetScope)

    /// Sends characters to the trash outright.
    case knockOut(AbilityTargetScope)

    /// Stands the card down.
    case restSelf

    /// Turns every chakra face-up again.
    case flipAllChakraFaceUp

    /// Stops the chosen card attacking on the opponent's next turn.
    case cannotAttackNextTurn(AbilityTargetScope)

    /// The card may not be summoned by paying its normal cost.
    case cannotBeSummonedNormally

    /// A step the engine does not resolve yet. `text` is shown to the player.
    case unimplemented(String)

    /// Human-readable summary used in the journal.
    var summary: String {
        switch self {
        case .drawCards(let n):            return "draw \(n) card\(n == 1 ? "" : "s")"
        case .placeFromHandOnDeck(let n):  return "place \(n) card\(n == 1 ? "" : "s") from hand on top of the deck"
        case .gainLife(let n):             return "gain \(n) life"
        case .loseLife(let n):             return "lose \(n) life"
        case .buffPower(let n, _):         return "\(n >= 0 ? "+" : "")\(n) power this turn"
        case .buffDamage(let n, _):        return "\(n >= 0 ? "+" : "")\(n) damage this turn"
        case .grantRush:                   return "gains Rush"
        case .knockOut(let scope):         return scope == .allCharacters ? "knock out every character" : "knock out the chosen character"
        case .restSelf:                    return "rest this card"
        case .flipAllChakraFaceUp:         return "turn all chakra face-up"
        case .cannotAttackNextTurn:        return "cannot attack next turn"
        case .cannotBeSummonedNormally:    return "cannot be summoned normally"
        case .unimplemented(let text):     return text
        }
    }

    /// False when the engine only displays this step rather than applying it.
    var isExecutable: Bool {
        if case .unimplemented = self { return false }
        return true
    }
}

// MARK: - Ability

/// One printed ability box.
struct CardAbility: Codable, Hashable, Identifiable {

    var id: String { "\(trigger.rawValue)-\(text.prefix(24))" }

    let trigger: AbilityTrigger

    /// Whether the card prints an "Once Per Turn" tag.
    var oncePerTurn: Bool = false

    var cost: AbilityCost = AbilityCost()

    /// What the player must choose, if anything.
    var target: AbilityTargetScope = .none

    /// The ability as printed, shown on the card detail screen.
    var text: String

    /// The executable breakdown.
    var effects: [AbilityEffect] = []

    /// True when every step can actually be applied by the engine.
    var isFullyImplemented: Bool {
        !effects.isEmpty && effects.allSatisfy(\.isExecutable)
    }

    /// True when the player activates this by pressing something.
    var isActivated: Bool { trigger.isPlayerActivated }

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
