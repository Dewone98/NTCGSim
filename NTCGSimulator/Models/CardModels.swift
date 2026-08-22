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
///
/// There is deliberately no `support` case. Support is a *mode* a card is used
/// in, not a type it is printed as: a card carrying a SUPPORT bar may be set
/// face-down in a Support slot instead of being summoned, and the very same card
/// can still be summoned as a body. `Card.canSetAsSupport` is what decides that,
/// and no card in the pool was ever typed `support` — the case was the app's
/// own invention.
enum CardType: String, Codable, CaseIterable, Identifiable, Hashable {
    case leader
    case character
    case exCharacter
    case chakra
    case summon

    var id: String { rawValue }

    var title: String {
        switch self {
        case .leader:      return "Leader"
        case .character:   return "Character"
        case .exCharacter: return "EX Character"
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

    /// Chakra spent to use a card from hand in one of its three modes.
    ///
    /// Summoning a body is free, and so is setting a card face-down as a
    /// Support — the reference charges nothing for either. The printed number is
    /// the price of the card's jutsu, and it is also the chakra printed on the
    /// left of a SUPPORT bar, paid later when the face-down card is flipped to
    /// answer a response window.
    static func toPlay(_ card: Card, mode: CardPlayMode) -> Int {
        guard mode == .jutsu else { return 0 }
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

    /// Whether the card prints a SUPPORT bar across its lower third, and so may
    /// be set face-down in a numbered Support slot.
    ///
    /// Twelve of the thirty-five shipped cards print one. The bar reads
    /// `CHAKRA n | SUPPORT | <jutsu name>` with the box's own trigger inside it,
    /// which is why the bar is a container and not a trigger — an earlier audit
    /// mistook the two and under-counted the settable cards at six.
    var canSetAsSupport: Bool = false

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
        canSetAsSupport = try box.decodeIfPresent(Bool.self, forKey: .canSetAsSupport) ?? false
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
         supportText: String? = nil, canSetAsSupport: Bool = false,
         artist: String? = nil, artFilename: String? = nil,
         abilities: [CardAbility] = []) {
        self.id = id; self.name = name; self.type = type; self.color = color
        self.rarity = rarity; self.setCode = setCode; self.traits = traits
        self.cost = cost; self.power = power; self.damage = damage
        self.health = health; self.life = life; self.effect = effect
        self.supportText = supportText; self.canSetAsSupport = canSetAsSupport
        self.artist = artist
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

    /// Whether this card gives chakra something to be spent on: its jutsu, or
    /// the SUPPORT bar it is flipped face-up through.
    ///
    /// A deck holding none of these plays with a dead resource, so the deck
    /// builder and the starter decks both reason in terms of this rather than
    /// counting a card type that no longer exists.
    var isChakraSink: Bool {
        hasSupportLine || canSetAsSupport
    }

    /// Chakra spent to summon this card as a body. Always zero — summoning is
    /// free — but expressed here so the UI never has to assume it.
    var summonCost: Int { ChakraCost.toPlay(self, mode: .summon) }

    /// Chakra spent to play this card as a jutsu, when it can be.
    var jutsuCost: Int? {
        hasSupportLine ? ChakraCost.toPlay(self, mode: .jutsu) : nil
    }

    /// Chakra printed on the left of the SUPPORT bar: what flipping this card
    /// face-up to answer a response window costs. `nil` when it prints no bar.
    var supportFlipCost: Int? {
        canSetAsSupport ? max(0, cost ?? 0) : nil
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
            let order: [CardType] = [.leader, .character, .exCharacter, .summon, .chakra]
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
