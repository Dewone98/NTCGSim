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

    /// Every ability box printed on the card, in print order.
    ///
    /// Replaces a single invented `LeaderAbility`: real cards print several
    /// boxes, each with its own trigger and cost, and characters carry them
    /// just as Leaders do.
    var abilities: [CardAbility] = []

    /// Illustration credit.
    var artist: String?

    /// Filename of an imported illustration in the app's card-art directory.
    /// When `nil`, the app draws a generated face from the card's own values.
    var artFilename: String?

    // MARK: Decoding

    /// Decoded leniently so a hand-authored `cards.json` may omit anything that
    /// does not apply. Swift's synthesised decoding does NOT fall back to a
    /// property's default value when its key is absent, so omitting `traits` or
    /// `effect` — which the import format documents as optional — would
    /// otherwise fail the whole file.
    init(from decoder: Decoder) throws {
        let box = try decoder.container(keyedBy: CodingKeys.self)
        id      = try box.decode(String.self, forKey: .id)
        name    = try box.decode(String.self, forKey: .name)
        type    = try box.decode(CardType.self, forKey: .type)
        color   = try box.decode(CardColor.self, forKey: .color)
        rarity  = try box.decode(Rarity.self, forKey: .rarity)
        setCode = try box.decode(String.self, forKey: .setCode)

        traits      = try box.decodeIfPresent([String].self, forKey: .traits) ?? []
        cost        = try box.decodeIfPresent(Int.self, forKey: .cost)
        power       = try box.decodeIfPresent(Int.self, forKey: .power)
        damage      = try box.decodeIfPresent(Int.self, forKey: .damage)
        health      = try box.decodeIfPresent(Int.self, forKey: .health)
        life        = try box.decodeIfPresent(Int.self, forKey: .life)
        effect      = try box.decodeIfPresent(String.self, forKey: .effect) ?? ""
        supportText = try box.decodeIfPresent(String.self, forKey: .supportText)
        artist      = try box.decodeIfPresent(String.self, forKey: .artist)
        artFilename = try box.decodeIfPresent(String.self, forKey: .artFilename)
        abilities   = try box.decodeIfPresent([CardAbility].self, forKey: .abilities) ?? []
    }

    /// Memberwise initialiser, kept because the custom decoder suppresses the
    /// synthesised one.
    init(id: String, name: String, type: CardType, color: CardColor,
         rarity: Rarity, setCode: String, traits: [String] = [],
         cost: Int? = nil, power: Int? = nil, damage: Int? = nil,
         health: Int? = nil, life: Int? = nil, effect: String = "",
         supportText: String? = nil, artist: String? = nil,
         artFilename: String? = nil, abilities: [CardAbility] = []) {
        self.id = id; self.name = name; self.type = type; self.color = color
        self.rarity = rarity; self.setCode = setCode; self.traits = traits
        self.cost = cost; self.power = power; self.damage = damage
        self.health = health; self.life = life; self.effect = effect
        self.supportText = supportText; self.artist = artist
        self.artFilename = artFilename; self.abilities = abilities
    }

    // MARK: Derived

    /// Whether the card offers the choice of summoning as a body or playing as
    /// a jutsu — the case the "confirm before summoning" setting guards.
    var hasSupportLine: Bool {
        supportText?.isEmpty == false
    }

    /// Abilities the player activates by pressing something.
    var activatedAbilities: [CardAbility] {
        abilities.filter(\.isActivated)
    }

    /// Abilities that fire by themselves when their moment arrives.
    func abilities(for trigger: AbilityTrigger) -> [CardAbility] {
        abilities.filter { $0.trigger == trigger }
    }

    /// True when the card prints rules the engine cannot yet resolve. Surfaced
    /// in the UI so a player is never misled about what the app will do.
    var hasUnimplementedRules: Bool {
        abilities.contains { !$0.isFullyImplemented }
    }

    /// Whether this card gives chakra something to be spent on: a Support card,
    /// or any card with a Support line that may be played as a jutsu.
    ///
    /// A deck holding none of these plays with a dead resource, so the deck
    /// builder and the starter decks both reason in terms of this rather than
    /// the Support type alone — a set may print no Support cards at all.
    var isChakraSink: Bool {
        type == .support || hasSupportLine
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
