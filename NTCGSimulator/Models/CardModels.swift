//
//  CardModels.swift
//  NTCGSimulator
//
//  The card data model. These are the values printed on a physical card:
//  type, colour, traits, cost, power, damage and health.
//

import Foundation

// MARK: - Colour

/// A card's colour identity. A deck may only contain cards matching its
/// Leader's colour.
enum CardColor: String, Codable, CaseIterable, Identifiable, Hashable {
    case red, blue, green

    var id: String { rawValue }

    var title: String {
        switch self {
        case .red:   return "Red"
        case .blue:  return "Blue"
        case .green: return "Green"
        }
    }
}

// MARK: - Type

/// What role the card plays. Leaders anchor a deck, Characters fight, Chakra
/// pays for things, and Summons occupy their own dedicated zone.
enum CardType: String, Codable, CaseIterable, Identifiable, Hashable {
    case leader
    case character
    case exCharacter
    case support
    case chakra
    case summon

    var id: String { rawValue }

    var title: String {
        switch self {
        case .leader:      return "Leader"
        case .character:   return "Character"
        case .exCharacter: return "EX Character"
        case .support:     return "Support"
        case .chakra:      return "Chakra"
        case .summon:      return "Summon"
        }
    }

    /// Whether the card occupies a slot in the Characters row when played.
    var isBody: Bool {
        self == .character || self == .exCharacter
    }

    /// Whether copies of this card belong in the main 50-card deck.
    var countsTowardDeckSize: Bool {
        self != .leader && self != .chakra && self != .summon
    }

    /// Whether playing this card spends Chakra.
    ///
    /// Summoning a body is free — Chakra is only spent on Support cards and on
    /// cards played as a jutsu via their Support line.
    var costsChakraToPlay: Bool {
        self == .support
    }
}

// MARK: - Rarity

enum Rarity: String, Codable, CaseIterable, Identifiable, Hashable {
    case common       = "C"
    case rare         = "R"
    case superRare    = "SR"
    case leader       = "L"
    case secretBox    = "SB"

    var id: String { rawValue }

    /// The letter printed on the card.
    var code: String { rawValue }

    var title: String {
        switch self {
        case .common:    return "Common"
        case .rare:      return "Rare"
        case .superRare: return "Super Rare"
        case .leader:    return "Leader"
        case .secretBox: return "Secret Box"
        }
    }
}


// MARK: - Leader ability

/// An effect a Leader can activate, once per turn.
///
/// Card effects at large are printed text the engine does not execute, but a
/// Leader's ability is the one the player reaches for every turn — so these are
/// modelled concretely and the engine resolves them.
enum LeaderAbility: Codable, Hashable {

    /// Draw one card.
    case drawCard

    /// Restore life to your own Leader.
    case restoreLife(Int)

    /// Give one of your characters extra power until end of turn.
    case empowerCharacter(power: Int)

    /// Take power off an opposing character until end of turn.
    case weakenCharacter(power: Int)

    /// Short description shown on the Leader's activation button.
    var summary: String {
        switch self {
        case .drawCard:
            return "Draw a card"
        case .restoreLife(let amount):
            return "Restore \(amount) life"
        case .empowerCharacter(let power):
            return "Give a character +\(power) power"
        case .weakenCharacter(let power):
            return "An opposing character loses \(power) power"
        }
    }

    /// Whether the player must pick one of their own characters.
    var needsFriendlyTarget: Bool {
        if case .empowerCharacter = self { return true }
        return false
    }

    /// Whether the player must pick one of the opponent's characters.
    var needsEnemyTarget: Bool {
        if case .weakenCharacter = self { return true }
        return false
    }

    /// Whether the ability needs a target at all.
    var needsTarget: Bool { needsFriendlyTarget || needsEnemyTarget }
}

// MARK: - Chakra cost

/// Works out what a play actually costs.
enum ChakraCost {

    /// Chakra spent to put a card into play.
    ///
    /// Summoning a Character or an EX Character is free. Chakra is spent only
    /// when a card is played as a jutsu through its Support line, or when the
    /// card is a Support card in its own right.
    static func toPlay(_ card: Card, asJutsu: Bool) -> Int {
        guard asJutsu || card.type.costsChakraToPlay else { return 0 }
        return max(0, card.cost ?? 0)
    }
}

// MARK: - Card

/// One card. `id` is the printed collector number (for example `N-004`), which
/// is unique within a set and stable across imports.
struct Card: Codable, Identifiable, Hashable {

    /// Printed collector number, e.g. `N-004`. Doubles as the stable identity.
    let id: String

    let name: String
    let type: CardType
    let color: CardColor
    let rarity: Rarity

    /// Set number this card was printed in, e.g. `"01"`.
    let setCode: String

    /// Trait lines printed on the card, e.g. `["Team 7", "Hidden Leaf Village"]`.
    var traits: [String] = []

    /// Chakra required to play the card. Leaders and Chakra cards have none.
    var cost: Int?

    /// Attack value used when this character battles.
    var power: Int?

    /// Damage dealt to a Leader's life when this character connects.
    var damage: Int?

    /// How much power a character absorbs before being sent to the Trash.
    var health: Int?

    /// Starting life, Leaders only.
    var life: Int?

    /// Rules text as printed.
    var effect: String = ""

    /// The secondary line that lets a character be played as a jutsu instead of
    /// being summoned as a body.
    var supportText: String?

    /// The effect this Leader can activate once per turn. Leaders only.
    var leaderAbility: LeaderAbility?

    /// Illustration credit.
    var artist: String?

    /// Filename of an imported illustration in the app's card-art directory.
    /// When `nil`, the app draws a generated face from the card's own values.
    var artFilename: String?

    // MARK: Derived

    /// Whether the card offers the choice of summoning as a body or playing as
    /// a jutsu — the case the "confirm before summoning" setting guards.
    var hasSupportLine: Bool {
        supportText?.isEmpty == false
    }

    /// Chakra spent to summon this card as a body. Always zero — summoning is
    /// free — but expressed here so the UI never has to assume it.
    var summonCost: Int { ChakraCost.toPlay(self, asJutsu: false) }

    /// Chakra spent to play this card as a jutsu, when it can be.
    var jutsuCost: Int? {
        hasSupportLine ? ChakraCost.toPlay(self, asJutsu: true) : nil
    }

    /// The stat line shown in compact list rows, e.g. `"3 / 6000 / 2"`.
    var statLine: String {
        var parts: [String] = []
        if let cost   { parts.append("\(cost)") }
        if let power  { parts.append("\(power)") }
        if let damage { parts.append("\(damage)") }
        return parts.joined(separator: " / ")
    }
}

// MARK: - Sorting

extension Card {
    /// Collection and deck-builder ordering: by type, then cost, then number.
    static func displayOrder(_ a: Card, _ b: Card) -> Bool {
        if a.type != b.type {
            let order: [CardType] = [.leader, .character, .exCharacter, .support, .summon, .chakra]
            let ai = order.firstIndex(of: a.type) ?? order.count
            let bi = order.firstIndex(of: b.type) ?? order.count
            return ai < bi
        }
        if (a.cost ?? 0) != (b.cost ?? 0) {
            return (a.cost ?? 0) < (b.cost ?? 0)
        }
        return a.id < b.id
    }
}
