//
//  CardFaceView.swift
//  NTCGSimulator
//
//  Draws a card, from one of two sources that must never be mixed.
//
//  Imported artwork is the printed card: the damage banner, the power and
//  health cells, the name bar, the trait line and the type are already in the
//  picture. So an installed illustration is shown edge to edge with nothing
//  drawn over it — anything we added would print every number twice, in the
//  wrong place. Only a card with no artwork gets a face built from its own
//  values, and that face is laid out where the printed card puts things, so the
//  two kinds read the same way side by side in a hand.
//
//  The generated illustration is art direction rather than a stand-in: a colour
//  identity ground and a motif picked by card type, shaped by a seed hashed out
//  of the collector number. It rasterises once through `drawingGroup()`, drops
//  most of its elements at board sizes and caches its recipe, because a
//  collection grid redraws every face it scrolls past.
//

import Foundation
import SwiftUI

// MARK: - Size

/// How much chrome a card face shows. Small sizes drop text that would be
/// unreadable anyway; `.tiny` keeps only the printed numbers, which is all that
/// survives a 44pt-wide board slot.
enum CardFaceSize {
    case tiny     // board slots and deck-list rows
    case small    // hand, collection grid
    case medium   // deck builder
    case large    // full-card inspector

    var showsEffectText: Bool { self == .large }
    var showsTraits: Bool { self == .medium || self == .large }
    var showsName: Bool { self != .tiny }

    /// The type line, the rarity mark, the keylines and the ability badge —
    /// everything that needs more room than a board slot has.
    var showsChrome: Bool { self != .tiny }

    /// "DMG", "POW", "HP" above their figures. A board slot has room for the
    /// number or the word, never both, and the number is the one that matters.
    var showsStatLabels: Bool { self != .tiny }

    var nameSize: CGFloat {
        switch self {
        case .tiny: return 6
        case .small: return 9.5
        case .medium: return 12
        case .large: return 19
        }
    }

    var statSize: CGFloat {
        switch self {
        case .tiny: return 8
        case .small: return 11
        case .medium: return 14
        case .large: return 22
        }
    }

    /// Type line, rarity code, stat labels and the other micro-lettering.
    var microSize: CGFloat {
        switch self {
        case .tiny: return 5.5
        case .small: return 7
        case .medium: return 9
        case .large: return 11
        }
    }

    var padding: CGFloat {
        switch self {
        case .tiny: return 3
        case .small: return 5
        case .medium: return 8
        case .large: return 14
        }
    }

    /// Diagonal cut on the card's own outline.
    var notch: CGFloat {
        switch self {
        case .tiny: return 4
        case .small: return 7
        case .medium: return 9
        case .large: return 14
        }
    }

    /// How far the printed keyline sits inside the card edge.
    var frameInset: CGFloat {
        switch self {
        case .tiny: return 2
        case .small: return 3
        case .medium: return 4
        case .large: return 6
        }
    }

    /// Cut on the name bar behind the title.
    var plateNotch: CGFloat {
        switch self {
        case .tiny: return 3
        case .small: return 5
        case .medium: return 6
        case .large: return 10
        }
    }

    /// How far the damage banner's trailing edge is cut back, which is what
    /// makes it read as a banner rather than another badge.
    var bannerSlant: CGFloat {
        switch self {
        case .tiny: return 3
        case .small: return 5
        case .medium: return 6
        case .large: return 9
        }
    }
}

// MARK: - Card face

/// A single card, at a given size.
struct CardFaceView: View {
    let card: Card
    var size: CardFaceSize = .small

    /// Dims the card when it cannot legally be acted on right now.
    var isDimmed: Bool = false

    /// Draws the accent ring used for selection and legal-target highlighting.
    var highlight: Color? = nil

    @Environment(CardDatabase.self) private var database

    var body: some View {
        // Asked once per face: the answer decides the whole composition, and
        // the store behind it can reach the disk.
        let artwork = database.artwork(for: card)

        ZStack {
            if let artwork {
                printedFace(artwork)
            } else {
                generatedFace
            }
        }
        .aspectRatio(Metrics.cardAspect, contentMode: .fit)
        .notchedPanel(
            notch: size.notch,
            corners: notchCorners,
            fill: .clear,
            stroke: edgeStroke(hasArtwork: artwork != nil),
            lineWidth: highlight == nil ? 1 : 2.5
        )
        .opacity(isDimmed ? 0.45 : 1)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityDescription)
    }

    // MARK: Printed face

    /// Real artwork already carries the banner, the stat cells, the name bar,
    /// the trait line and the type, printed where the card prints them. The
    /// only thing this face adds is the selection ring, which is not printed on
    /// anything.
    private func printedFace(_ image: UIImage) -> some View {
        Image(uiImage: image)
            .resizable()
            .aspectRatio(contentMode: .fill)
            .allowsHitTesting(false)
    }

    /// A keyline is printed chrome too, so a card whose artwork already has one
    /// gets nothing but the highlight.
    private func edgeStroke(hasArtwork: Bool) -> Color {
        if let highlight { return highlight }
        return hasArtwork ? .clear : frameAccent.opacity(0.7)
    }

    // MARK: Generated face

    /// Illustration, legibility scrim, printed furniture, printed values — in
    /// that order, because every layer above the art has to survive being read
    /// against whatever colour landed underneath it.
    private var generatedFace: some View {
        ZStack {
            GeneratedCardArt(card: card)
                .environment(\.cardArtDetail, ArtDetail(size))
            scrim
            frameOrnament
            printedValues
        }
    }

    /// One gradient rather than two: the top has to carry the banner and the
    /// stat cells, the bottom a whole name bar, and the middle is left alone so
    /// the illustration still shows through.
    private var scrim: some View {
        LinearGradient(
            stops: [
                .init(color: .black.opacity(0.55), location: 0),
                .init(color: .clear, location: 0.30),
                .init(color: .clear, location: 0.46),
                .init(color: .black.opacity(0.52), location: 0.76),
                .init(color: .black.opacity(0.88), location: 1)
            ],
            startPoint: .top,
            endPoint: .bottom
        )
        .allowsHitTesting(false)
    }

    /// The printed furniture: keylines, the foil edge premium rarities get, and
    /// the colour spine that marks a Support card out from a body.
    private var frameOrnament: some View {
        ZStack {
            if size.showsChrome {
                NotchedRectangle(notch: max(2, size.notch - size.frameInset),
                                 corners: notchCorners)
                    .stroke(.white.opacity(0.20), lineWidth: 0.5)
                    .padding(size.frameInset)

                // Leaders carry a second, warmer keyline — the most ornate
                // frame in the set, because there is only ever one in play.
                if card.type == .leader {
                    NotchedRectangle(notch: max(2, size.notch - size.frameInset - 2),
                                     corners: notchCorners)
                        .stroke(Palette.warning.opacity(0.6), lineWidth: 0.75)
                        .padding(size.frameInset + 2)
                }

                // The sweep is an angular gradient, so it stays off the board:
                // a 44pt slot cannot show it and would only pay for it.
                if card.rarity.isPremium {
                    NotchedRectangle(notch: max(2, size.notch - 1), corners: notchCorners)
                        .stroke(card.rarity.foilSweep, lineWidth: 1.75)
                        .padding(1)
                }
            }

            // A Support card is the one thing in hand that spends chakra, so it
            // gets a spine no body ever has — legible even at board size.
            if card.type == .support {
                HStack(spacing: 0) {
                    LinearGradient(
                        colors: [card.color.tint, Palette.accent],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                    .frame(width: spineWidth)
                    Spacer(minLength: 0)
                }
            }
        }
        .allowsHitTesting(false)
    }

    // MARK: Printed values

    /// Everything the printed card prints, in the places it prints it: damage
    /// on a banner at the top-leading corner, power and health at the
    /// top-trailing, and the name bar along the bottom.
    private var printedValues: some View {
        VStack(spacing: 0) {
            topBand
            Spacer(minLength: 0)
            if size.showsName {
                namePlate
            }
        }
        .padding(.leading, card.type == .support ? spineWidth : 0)
        .allowsHitTesting(false)
    }

    /// Damage leads, power and health close the row.
    ///
    /// The same `.small` face is asked to fit a 72pt format tile and a 110pt
    /// hand card, so the band gives ground in a fixed order — the words above
    /// the figures go first, all of them together — rather than letting a
    /// banner be squeezed until its number disappears.
    private var topBand: some View {
        ViewThatFits(in: .horizontal) {
            topBandContent(showsLabels: size.showsStatLabels)
            topBandContent(showsLabels: false)
        }
        .padding(.horizontal, size.padding)
        .padding(.top, size.padding)
    }

    private func topBandContent(showsLabels: Bool) -> some View {
        HStack(alignment: .top, spacing: 2) {
            VStack(alignment: .leading, spacing: size == .large ? 4 : 2) {
                damageBanner(showsLabels: showsLabels)
                chakraToken
            }
            Spacer(minLength: 0)
            combatCells(showsLabels: showsLabels)
        }
    }

    /// DMG rides the top-leading corner on an angled banner, label above the
    /// figure. A Leader only gets one when it actually prints damage.
    @ViewBuilder
    private func damageBanner(showsLabels: Bool) -> some View {
        if let damage = card.damage {
            statStack(label: "DMG", value: "\(damage)", tint: .white, showsLabel: showsLabels)
                .padding(.leading, size == .tiny ? 2 : 3)
                .padding(.trailing, (size == .tiny ? 2 : 3) + size.bannerSlant)
                .padding(.vertical, size == .tiny ? 1 : 2)
                .background(
                    BannerTag(slant: size.bannerSlant)
                        .fill(
                            LinearGradient(
                                colors: [Palette.negative, Palette.negative.opacity(0.72)],
                                startPoint: .top,
                                endPoint: .bottom
                            )
                        )
                )
        }
    }

    /// POW and HP as two adjacent cells on one printed plate — LIFE in place of
    /// HP on a Leader, which has life and no health.
    @ViewBuilder
    private func combatCells(showsLabels: Bool) -> some View {
        let readouts = combatReadouts
        if !readouts.isEmpty {
            HStack(spacing: 0) {
                ForEach(readouts) { readout in
                    statStack(label: readout.label, value: readout.value,
                              tint: readout.tint, showsLabel: showsLabels)
                        .padding(.horizontal, size == .tiny ? 2 : 3)
                        .padding(.vertical, size == .tiny ? 1 : 2)
                        // The rule between the cells is an overlay, not a view
                        // in the row: a bare `Rectangle` is flexible in height,
                        // and would stretch the whole plate down the card.
                        .overlay(alignment: .leading) {
                            if readout.id != readouts.first?.id {
                                Rectangle()
                                    .fill(.white.opacity(0.2))
                                    .frame(width: 0.5)
                            }
                        }
                }
            }
            .background(
                NotchedRectangle(notch: size.plateNotch * 0.7, corners: [.bottomLeading])
                    .fill(.black.opacity(0.55))
            )
        }
    }

    /// The cells a card actually prints. A Support card prints none of them.
    private var combatReadouts: [CombatReadout] {
        var readouts: [CombatReadout] = []
        if let power = card.power {
            readouts.append(CombatReadout(label: "POW", value: "\(power)", tint: .white))
        }
        if card.type == .leader, let life = card.life {
            readouts.append(CombatReadout(label: "LIFE", value: "\(life)", tint: Palette.warning))
        } else if let health = card.health {
            readouts.append(CombatReadout(label: "HP", value: "\(health)", tint: Palette.positive))
        }
        return readouts
    }

    /// Label above number, the way the printed card stacks them.
    private func statStack(label: String,
                           value: String,
                           tint: Color,
                           showsLabel: Bool) -> some View {
        VStack(spacing: size == .large ? 0 : -1) {
            if showsLabel {
                Text(label)
                    .font(Typeface.label(size.microSize))
                    .tracking(0.3)
                    .foregroundStyle(.white.opacity(0.75))
                    .lineLimit(1)
                    // The word is worth less than the figure under it, so it is
                    // the one allowed to shrink furthest before anything clips.
                    .minimumScaleFactor(0.5)
            }
            Text(value)
                .font(Typeface.numeric(size.statSize))
                .foregroundStyle(tint)
                .lineLimit(1)
                // A face is routinely given less width than the numbers printed
                // on it: shrink the figure rather than clip it.
                .minimumScaleFactor(0.5)
        }
    }

    /// Chakra is round, orange and carries a drop — nothing like the angular
    /// banner and cells the combat numbers sit in, because the two are never
    /// the same kind of number. Summoning a body is free, so this appears only
    /// on a Support card and on a card that can be paid for as a jutsu.
    @ViewBuilder
    private var chakraToken: some View {
        if let cost = chakraCost {
            HStack(spacing: 1.5) {
                Image(systemName: "drop.fill")
                    .font(.system(size: size.statSize * 0.6, weight: .black))
                Text("\(cost.amount)")
                    .font(Typeface.numeric(size.statSize * 0.9))
                    .lineLimit(1)
                    .minimumScaleFactor(0.5)
                if size == .large {
                    Text(cost.isJutsu ? "Jutsu" : "Chakra")
                        .font(Typeface.label(size.microSize))
                        .tracking(1)
                        .textCase(.uppercase)
                }
            }
            .foregroundStyle(Palette.textOnAccent)
            .padding(.horizontal, size == .tiny ? 3 : 5)
            .padding(.vertical, size == .tiny ? 0.5 : 2)
            .background(Palette.accent, in: Capsule())
        }
    }

    /// The only chakra a card ever costs: a Support card's own price, or the
    /// jutsu price on a card that prints a Support line. A body with neither is
    /// summoned for free and prints no chakra at all.
    private var chakraCost: (amount: Int, isJutsu: Bool)? {
        if card.type.costsChakraToPlay {
            return (ChakraCost.toPlay(card, asJutsu: false), false)
        }
        if let jutsu = card.jutsuCost {
            return (jutsu, true)
        }
        return nil
    }

    // MARK: Name bar

    /// The bar across the bottom: name, then the trait line under it with the
    /// card type closing it out at the trailing end.
    private var namePlate: some View {
        VStack(alignment: .leading, spacing: size == .large ? 3 : 1) {
            Text(card.name)
                .font(Typeface.display(size.nameSize, weight: .bold))
                .foregroundStyle(.white)
                .lineLimit(size == .large ? 2 : 1)
                .minimumScaleFactor(0.6)

            traitLine

            if size.showsEffectText, !card.effect.isEmpty {
                Text(card.effect)
                    .font(Typeface.body(12))
                    .foregroundStyle(.white.opacity(0.9))
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 2)
            }

            if size.showsEffectText, !card.activatedAbilities.isEmpty {
                abilityLines
            }
        }
        .padding(.horizontal, size == .large ? 8 : 4)
        .padding(.vertical, size == .large ? 6 : 2.5)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(namePlateBackground)
    }

    /// The band behind the title. Support cards get a solid colour bar where a
    /// body gets a neutral scrim, so the two never blur together in hand.
    @ViewBuilder
    private var namePlateBackground: some View {
        let shape = NotchedRectangle(notch: size.plateNotch, corners: [.topTrailing])

        switch card.type {
        case .support:
            shape.fill(
                LinearGradient(
                    colors: [card.color.deepTint.opacity(0.96), card.color.deepTint.opacity(0.7)],
                    startPoint: .leading,
                    endPoint: .trailing
                )
            )
        case .leader:
            shape
                .fill(
                    LinearGradient(
                        colors: [.black.opacity(0.82), .black.opacity(0.45)],
                        startPoint: .leading,
                        endPoint: .trailing
                    )
                )
                .overlay(alignment: .top) {
                    Rectangle()
                        .fill(Palette.warning.opacity(0.8))
                        .frame(height: 1)
                }
        case .character, .exCharacter, .chakra, .summon:
            shape.fill(.black.opacity(0.52))
        }
    }

    /// Traits in small text directly under the name, with the rarity letter and
    /// the type closing the line at the bottom-trailing corner.
    private var traitLine: some View {
        HStack(spacing: 3) {
            if size.showsTraits, !card.traits.isEmpty {
                Text(card.traits.joined(separator: " · "))
                    .font(Typeface.label(size == .large ? 10 : 7))
                    .foregroundStyle(.white.opacity(0.72))
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
            }

            Spacer(minLength: 0)

            if !card.activatedAbilities.isEmpty {
                abilityBadge
            }
            if size.showsTraits {
                rarityMark
            }
            typeMark
        }
    }

    private var typeMark: some View {
        Text(card.type.title)
            .font(Typeface.label(size.microSize))
            .tracking(size == .large ? 1.6 : 0.6)
            .textCase(.uppercase)
            .foregroundStyle(typeLineTint)
            .lineLimit(1)
            .minimumScaleFactor(0.6)
    }

    private var rarityMark: some View {
        Text(card.rarity.code)
            .font(Typeface.label(size.microSize))
            .tracking(0.6)
            .foregroundStyle(card.rarity.isPremium ? .black.opacity(0.82) : .white.opacity(0.9))
            .padding(.horizontal, size == .large ? 5 : 3)
            .padding(.vertical, size == .large ? 2 : 1)
            .background {
                if card.rarity.isPremium {
                    Capsule().fill(card.rarity.foilSweep)
                } else {
                    Capsule().fill(.black.opacity(0.45))
                }
            }
    }

    /// Marks a card carrying a box the player can press a button for, so the
    /// play is discoverable from the card and not only from the board.
    ///
    /// It is the activated boxes and only those: a passive rule or an On Summon
    /// trigger fires on its own and needs no invitation, and badging every card
    /// that prints anything at all would badge almost the whole set.
    private var abilityBadge: some View {
        HStack(spacing: 2) {
            Image(systemName: "sparkles")
                .font(.system(size: size.microSize, weight: .black))
            if size == .large {
                Text("Ability")
                    .font(Typeface.label(size.microSize))
                    .tracking(1)
                    .textCase(.uppercase)
            }
        }
        .foregroundStyle(Palette.textOnAccent)
        .padding(.horizontal, size == .large ? 5 : 2.5)
        .padding(.vertical, size == .large ? 2 : 1)
        .background(Palette.accent, in: Capsule())
    }

    /// One line per box the player can activate, at inspector size only.
    ///
    /// It states the terms rather than the rules: the printed text is already
    /// set out in full directly above, and repeating it here would fill the
    /// name bar with the same sentence twice.
    private var abilityLines: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(Array(card.activatedAbilities.enumerated()), id: \.offset) { box in
                abilityLine(box.element)
            }
        }
        .padding(.top, 2)
    }

    private func abilityLine(_ ability: CardAbility) -> some View {
        HStack(spacing: 4) {
            Image(systemName: "sparkles")
                .font(.system(size: 11, weight: .bold))
            Text(activationTerms(ability))
                .font(Typeface.label(11))
                .fixedSize(horizontal: false, vertical: true)
        }
        .foregroundStyle(Palette.warning)
    }

    /// "Activate: Main · 1 chakra · once per turn" — when the box may be used
    /// and what using it costs, in that order, because the first thing a player
    /// asks of an ability is whether they can reach it at all.
    private func activationTerms(_ ability: CardAbility) -> String {
        var parts = [ability.trigger.title]
        parts.append(ability.cost.isFree ? "no cost" : ability.cost.summary)
        if ability.oncePerTurn { parts.append("once per turn") }
        return parts.joined(separator: " · ")
    }

    private var typeLineTint: Color {
        switch card.type {
        case .leader:  return Palette.warning
        case .support: return Palette.accent
        case .character, .exCharacter, .chakra, .summon: return .white.opacity(0.78)
        }
    }

    // MARK: Trim

    /// Support cards are cut on all four corners, so the silhouette alone tells
    /// them apart from a body at board size.
    private var notchCorners: NotchedCorners {
        card.type == .support ? .all : .diagonal
    }

    /// The colour the frame is trimmed in.
    private var frameAccent: Color {
        switch card.type {
        case .leader:      return Palette.warning
        case .support:     return Palette.accent
        case .summon:      return Palette.positive
        case .chakra:      return Palette.textSecondary
        case .character, .exCharacter: return card.color.tint
        }
    }

    private var spineWidth: CGFloat {
        size == .tiny ? 2.5 : 4
    }

    // MARK: Accessibility

    /// Spoken in full at every size and from either source: a board slot prints
    /// almost nothing, and an imported illustration prints everything in pixels
    /// VoiceOver cannot read.
    private var accessibilityDescription: String {
        var parts = [card.name, card.id, card.type.title, card.color.title, card.rarity.title]
        if !card.traits.isEmpty {
            parts.append(card.traits.joined(separator: ", "))
        }
        if let chakraDescription { parts.append(chakraDescription) }
        if let power = card.power { parts.append("power \(power)") }
        if let damage = card.damage { parts.append("damage \(damage)") }
        if let health = card.health { parts.append("health \(health)") }
        if let life = card.life { parts.append("life \(life)") }
        for ability in card.activatedAbilities {
            parts.append("activated ability, \(activationTerms(ability))")
        }
        if !card.effect.isEmpty { parts.append(card.effect) }
        return parts.joined(separator: ", ")
    }

    /// Worded for what the rules actually charge: only a Support card and a
    /// jutsu play spend chakra, so a body is spoken as free to summon.
    private var chakraDescription: String? {
        var phrases: [String] = []
        if card.type.costsChakraToPlay {
            phrases.append("costs \(ChakraCost.toPlay(card, asJutsu: false)) chakra")
        } else if card.type.isBody {
            phrases.append("free to summon")
        }
        if let jutsu = card.jutsuCost {
            phrases.append("\(jutsu) chakra as a jutsu")
        }
        return phrases.isEmpty ? nil : phrases.joined(separator: ", ")
    }
}

// MARK: - Printed stat cell

/// One printed combat cell: the word above the figure, and the ink the figure
/// is set in.
private struct CombatReadout: Identifiable {
    let label: String
    let value: String
    let tint: Color

    var id: String { label }
}

/// The damage banner: square where it meets the card's leading edge, cut back
/// on the diagonal at its trailing edge so it hangs like a ribbon.
private struct BannerTag: Shape {
    var slant: CGFloat

    func path(in rect: CGRect) -> Path {
        let cut = min(slant, rect.width / 2)
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX - cut, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
        path.closeSubpath()
        return path
    }
}

// MARK: - Rarity trim

private extension Rarity {

    /// Rarities printed on foil stock, which the frame imitates with a swept
    /// metallic keyline rather than relying on the letter alone.
    var isPremium: Bool {
        self == .superRare || self == .leader || self == .secretBox
    }

    /// The metal each premium rarity is struck in. Non-premium rarities never
    /// reach the sweep, but return a usable pair so the gradient is always
    /// well formed.
    var foilStops: [Color] {
        switch self {
        case .leader, .superRare:
            return [Palette.adaptive(dark: 0xC9932F, light: 0xB8811F),
                    Palette.adaptive(dark: 0xFFF0C0, light: 0xFFE9A8),
                    Palette.adaptive(dark: 0xE8C071, light: 0xD9A63F),
                    Palette.adaptive(dark: 0xFFFAE6, light: 0xFFF3CC)]
        case .secretBox:
            return [Palette.adaptive(dark: 0x8E7BD6, light: 0x6E58C4),
                    Palette.adaptive(dark: 0xE6DEFF, light: 0xD6CBFF),
                    Palette.adaptive(dark: 0x6FB6D8, light: 0x4E93B8),
                    Palette.adaptive(dark: 0xF2ECFF, light: 0xE4DBFF)]
        case .common, .rare:
            return [Palette.border, Palette.border]
        }
    }

    /// A full turn of the metal, closed on itself so the sweep has no seam.
    var foilSweep: AngularGradient {
        let stops = foilStops
        return AngularGradient(colors: stops + [stops[0]], center: .center)
    }
}

// MARK: - Art detail

/// How much of the generated illustration is worth drawing at a given size.
///
/// A 44pt board slot cannot show a second ring, a flourish or a grain tile, so
/// it is not asked to pay for them: the cheapest bucket draws a ground, one
/// figure and a vignette, where the inspector draws the full stack.
private enum ArtDetail: Int {
    case minimal = 0   // board slots
    case reduced = 1   // hand cards, collection and deck-builder grids
    case full    = 2   // the inspector

    init(_ size: CardFaceSize) {
        switch size {
        case .tiny:            self = .minimal
        case .small, .medium:  self = .reduced
        case .large:           self = .full
        }
    }

    var isAtLeastReduced: Bool { self != .minimal }
    var isFull: Bool { self == .full }

    /// Caps on the repeated elements in a motif. The seed still picks the same
    /// number at every size — it is clamped afterwards, so a card keeps its
    /// character when it changes size instead of becoming a different picture.
    var spokeCap: Int {
        switch self {
        case .minimal: return 6
        case .reduced: return 12
        case .full:    return 20
        }
    }

    var bladeCap: Int {
        switch self {
        case .minimal: return 3
        case .reduced: return 5
        case .full:    return 8
        }
    }

    var bandCap: Int {
        switch self {
        case .minimal: return 3
        case .reduced: return 5
        case .full:    return 7
        }
    }

    var facetCap: Int {
        switch self {
        case .minimal: return 5
        case .reduced: return 7
        case .full:    return 10
        }
    }

    /// Samples along the Chakra spiral. Ninety-six segments is a curve; at
    /// board size twenty-four is indistinguishable and a quarter of the path.
    var spiralSegments: Int {
        switch self {
        case .minimal: return 24
        case .reduced: return 48
        case .full:    return 96
        }
    }
}

private struct CardArtDetailKey: EnvironmentKey {
    static let defaultValue: ArtDetail = .full
}

private extension EnvironmentValues {
    /// Set by `CardFaceView`, so `GeneratedCardArt` can thin itself out without
    /// taking a parameter every caller would have to pass.
    var cardArtDetail: ArtDetail {
        get { self[CardArtDetailKey.self] }
        set { self[CardArtDetailKey.self] = newValue }
    }
}

// MARK: - Generated art

/// A deterministic illustration derived from the card's own identity.
///
/// The card type picks the motif — a Leader draws a crest, a Support card draws
/// banded strata, a Chakra card draws a spiral — and a seed hashed out of the
/// collector number decides how many elements it has, how they are turned,
/// weighted and offset.
///
/// Everything is plain shapes and gradients over a single `GeometryReader`, and
/// none of it animates, so the whole face is flattened once by `drawingGroup()`
/// and scrolled as a bitmap after that. The recipe behind it is cached, and how
/// much of it is drawn depends on the size the face was asked for.
struct GeneratedCardArt: View {
    let card: Card

    @Environment(\.cardArtDetail) private var detail

    var body: some View {
        let recipe = ArtRecipeCache.recipe(for: card, detail: detail)

        ZStack {
            ground(recipe)
            wash(recipe)
            if recipe.detail.isAtLeastReduced {
                bloom(recipe)
            }
            motifLayer(recipe)
            if recipe.detail.isFull {
                sheen(recipe)
            }
            vignette
            if recipe.detail.isAtLeastReduced {
                ArtTexture.grain
                    .resizable(resizingMode: .tile)
                    .opacity(0.48)
            }
        }
        .drawingGroup()
    }

    // MARK: Ground

    /// The colour-identity gradient, run along a diagonal the seed picked.
    private func ground(_ recipe: ArtRecipe) -> some View {
        LinearGradient(
            stops: [
                .init(color: card.color.deepTint, location: 0),
                .init(color: card.color.tint.opacity(0.82), location: recipe.groundMid),
                .init(color: card.color.deepTint.opacity(0.95), location: 1)
            ],
            startPoint: recipe.gradientStart,
            endPoint: recipe.gradientEnd
        )
    }

    /// A whisper of black or white over the ground. Three colours across a
    /// sixty-nine card pool is not much range, so each card is pushed a shade
    /// lighter or darker than its neighbours.
    private func wash(_ recipe: ArtRecipe) -> some View {
        (recipe.wash < 0 ? Color.black : Color.white).opacity(abs(recipe.wash))
    }

    /// A soft light source behind the motif, so the figure has something to sit
    /// against rather than floating on a flat field.
    private func bloom(_ recipe: ArtRecipe) -> some View {
        EllipticalGradient(
            colors: [card.color.tint.opacity(0.65), .clear],
            center: recipe.bloom,
            startRadiusFraction: 0,
            endRadiusFraction: recipe.bloomRadius
        )
    }

    /// A single raking highlight and its shadow, angled by the seed.
    private func sheen(_ recipe: ArtRecipe) -> some View {
        LinearGradient(
            stops: [
                .init(color: .clear, location: 0),
                .init(color: .black.opacity(0.12), location: 0.34),
                .init(color: .white.opacity(0.20), location: 0.5),
                .init(color: .white.opacity(0.05), location: 0.6),
                .init(color: .clear, location: 1)
            ],
            startPoint: .top,
            endPoint: .bottom
        )
        .rotationEffect(.degrees(recipe.sheenAngle))
        .scaleEffect(1.9)
    }

    private var vignette: some View {
        EllipticalGradient(
            stops: [
                .init(color: .clear, location: 0.32),
                .init(color: .black.opacity(0.5), location: 1)
            ],
            center: .center,
            startRadiusFraction: 0,
            endRadiusFraction: 0.82
        )
    }

    // MARK: Motif

    /// One `GeometryReader` for the whole figure: every stroke weight and
    /// radius below is expressed against the card's own short side, so the face
    /// looks the same at 44pt as it does in the inspector.
    private func motifLayer(_ recipe: ArtRecipe) -> some View {
        GeometryReader { geo in
            figure(recipe, in: geo.size)
                .frame(width: geo.size.width, height: geo.size.height)
        }
    }

    private func figure(_ recipe: ArtRecipe, in size: CGSize) -> some View {
        let unit = min(size.width, size.height)
        let origin = recipe.centre.point(in: CGRect(origin: .zero, size: size))

        return ZStack {
            primaryFigure(recipe, unit: unit, origin: origin, in: size)
                .scaleEffect(recipe.figureScale, anchor: recipe.centre)
            if recipe.detail.isFull {
                flourish(recipe, unit: unit, in: size)
            }
        }
    }

    /// One extra mark, chosen by the seed and laid over the motif, so two cards
    /// of the same type never resolve to the same picture. It is the first
    /// thing dropped below inspector size: it is the layer that differentiates
    /// two cards you are looking at side by side, not one you scroll past.
    @ViewBuilder
    private func flourish(_ recipe: ArtRecipe, unit: CGFloat, in size: CGSize) -> some View {
        switch recipe.flourish {
        case .plain:
            EmptyView()
        case .halo:
            Circle()
                .stroke(.white.opacity(0.13), lineWidth: unit * 0.01)
                .frame(width: unit * recipe.flourishScale, height: unit * recipe.flourishScale)
                .position(x: size.width * recipe.flourishCentre.x,
                          y: size.height * recipe.flourishCentre.y)
        case .strata:
            BandStack(count: recipe.bands, thickness: 0.16,
                      skew: recipe.skew, phase: recipe.phase)
                .fill(.black.opacity(0.13))
        case .shard:
            SigilPolygon(sides: 3, rotation: recipe.secondRotation,
                         radiusRatio: recipe.flourishScale * 0.5,
                         centre: recipe.flourishCentre)
                .fill(.white.opacity(0.09))
        }
    }

    /// Every motif is built in the same order at every size — the extra passes
    /// are gated in place rather than reordered, so the cheap version is the
    /// expensive one with layers lifted off it.
    @ViewBuilder
    private func primaryFigure(_ recipe: ArtRecipe,
                               unit: CGFloat,
                               origin: CGPoint,
                               in size: CGSize) -> some View {
        switch recipe.motif {
        case .crest:
            ZStack {
                RadiatingSpokes(count: recipe.spokes, rotation: recipe.rotation,
                                spread: recipe.spread, innerRatio: recipe.innerRatio,
                                centre: recipe.centre)
                    .fill(.white.opacity(0.15))
                if recipe.detail.isFull {
                    RadiatingSpokes(count: max(3, recipe.spokes / 3), rotation: recipe.secondRotation,
                                    spread: recipe.spread * 3.2, innerRatio: recipe.innerRatio * 1.8,
                                    centre: recipe.centre)
                        .fill(.black.opacity(0.16))
                }
                Circle()
                    .stroke(.white.opacity(0.32), lineWidth: unit * 0.02)
                    .frame(width: unit * 0.56, height: unit * 0.56)
                    .position(origin)
                if recipe.detail.isFull {
                    Circle()
                        .stroke(.white.opacity(0.16), lineWidth: unit * 0.007)
                        .frame(width: unit * (0.56 + recipe.ringGap),
                               height: unit * (0.56 + recipe.ringGap))
                        .position(origin)
                }
                if recipe.detail.isAtLeastReduced {
                    SigilPolygon(sides: recipe.facets, rotation: recipe.rotation,
                                 radiusRatio: 0.17, centre: recipe.centre)
                        .fill(.white.opacity(0.22))
                }
                if recipe.detail.isFull {
                    SigilPolygon(sides: recipe.facets,
                                 rotation: recipe.rotation + 180 / Double(recipe.facets),
                                 radiusRatio: 0.24, centre: recipe.centre)
                        .stroke(.black.opacity(0.22), lineWidth: unit * 0.012)
                }
            }

        case .nova:
            ZStack {
                BladeFan(count: recipe.blades, rotation: recipe.rotation,
                         sweep: recipe.sweep, innerRatio: recipe.innerRatio,
                         centre: recipe.centre)
                    .fill(.white.opacity(0.18))
                if recipe.detail.isFull {
                    RadiatingSpokes(count: recipe.spokes, rotation: recipe.secondRotation,
                                    spread: recipe.spread * 0.6, innerRatio: 0.3,
                                    centre: recipe.centre)
                        .fill(.white.opacity(0.11))
                }
                if recipe.detail.isAtLeastReduced {
                    Circle()
                        .stroke(.white.opacity(0.28), lineWidth: unit * 0.03)
                        .frame(width: unit * 0.42, height: unit * 0.42)
                        .position(origin)
                }
                if recipe.detail.isFull {
                    Circle()
                        .fill(.white.opacity(0.14))
                        .frame(width: unit * 0.17, height: unit * 0.17)
                        .position(origin)
                }
            }

        case .shuriken:
            ZStack {
                BladeFan(count: recipe.blades, rotation: recipe.rotation,
                         sweep: recipe.sweep, innerRatio: recipe.innerRatio,
                         centre: recipe.centre)
                    .fill(.white.opacity(0.17))
                if recipe.detail.isFull {
                    BladeFan(count: recipe.blades,
                             rotation: recipe.rotation + 180 / Double(recipe.blades),
                             sweep: recipe.sweep * 0.7, innerRatio: recipe.innerRatio * 2,
                             centre: recipe.centre)
                        .fill(.black.opacity(0.15))
                }
                if recipe.detail.isAtLeastReduced {
                    Circle()
                        .stroke(.white.opacity(0.24), lineWidth: unit * 0.022)
                        .frame(width: unit * 0.28, height: unit * 0.28)
                        .position(origin)
                }
            }

        case .scroll:
            let seal = unit * (0.24 + recipe.flourishScale * 0.16)
            ZStack {
                BandStack(count: recipe.bands, thickness: recipe.bandWeight,
                          skew: recipe.skew, phase: recipe.phase)
                    .fill(.white.opacity(0.13))
                if recipe.detail.isFull {
                    BandStack(count: recipe.bands + 2, thickness: 0.2,
                              skew: recipe.skew, phase: recipe.phase + 0.4)
                        .fill(.black.opacity(0.16))
                }
                // A seal stamped off-centre: the one motif in the set with no
                // radial symmetry, so Support reads instantly in a hand.
                if recipe.detail.isAtLeastReduced {
                    Circle()
                        .stroke(.white.opacity(0.3), lineWidth: unit * 0.025)
                        .frame(width: seal, height: seal)
                        .position(x: size.width * recipe.centre.x,
                                  y: size.height * recipe.sealDrop)
                }
                if recipe.detail.isFull {
                    SigilPolygon(sides: recipe.facets, rotation: recipe.rotation,
                                 radiusRatio: Double(seal / unit) * 0.26,
                                 centre: UnitPoint(x: recipe.centre.x, y: recipe.sealDrop))
                        .fill(.white.opacity(0.24))
                }
            }

        case .spiral:
            ZStack {
                ChakraSpiral(turns: recipe.turns, rotation: recipe.rotation,
                             startRatio: 0.08, centre: recipe.centre,
                             segments: recipe.spiralSegments)
                    .stroke(.white.opacity(0.3), style: StrokeStyle(lineWidth: unit * 0.03,
                                                                    lineCap: .round))
                if recipe.detail.isFull {
                    ChakraSpiral(turns: recipe.turns * 0.8, rotation: recipe.secondRotation,
                                 startRatio: 0.16, centre: recipe.centre,
                                 segments: recipe.spiralSegments)
                        .stroke(.black.opacity(0.2), style: StrokeStyle(lineWidth: unit * 0.016,
                                                                        lineCap: .round))
                }
                if recipe.detail.isAtLeastReduced {
                    Circle()
                        .fill(.white.opacity(0.16))
                        .frame(width: unit * 0.18, height: unit * 0.18)
                        .position(origin)
                }
            }

        case .sigil:
            ZStack {
                SigilPolygon(sides: recipe.facets, rotation: recipe.rotation,
                             radiusRatio: 0.44, centre: recipe.centre)
                    .fill(.white.opacity(0.12))
                if recipe.detail.isFull {
                    SigilPolygon(sides: 3, rotation: recipe.secondRotation,
                                 radiusRatio: 0.4, centre: recipe.centre)
                        .fill(.black.opacity(0.16))
                    SigilPolygon(sides: 5, rotation: recipe.rotation * 0.5,
                                 radiusRatio: 0.3, centre: recipe.centre)
                        .fill(.white.opacity(0.16))
                }
                if recipe.detail.isAtLeastReduced {
                    SigilPolygon(sides: recipe.facets, rotation: recipe.rotation,
                                 radiusRatio: 0.52, centre: recipe.centre)
                        .stroke(.white.opacity(0.26), lineWidth: unit * 0.014)
                }
            }
        }
    }
}

// MARK: - Recipe cache

/// Recipes are cheap to draw with and needlessly expensive to rebuild: a
/// collection grid asks for the same faces every time the player scrolls back
/// up. They are held per card and per detail bucket, and the cache is bounded
/// so an imported pool of any size cannot grow it without limit.
private enum ArtRecipeCache {

    /// Comfortably more than the shipped pool across all three buckets, and
    /// small enough that a big imported set still evicts.
    private static let limit = 512

    private static let store: NSCache<NSString, RecipeBox> = {
        let cache = NSCache<NSString, RecipeBox>()
        cache.countLimit = limit
        return cache
    }()

    static func recipe(for card: Card, detail: ArtDetail) -> ArtRecipe {
        let key = "\(card.id)|\(card.name)|\(detail.rawValue)" as NSString
        if let hit = store.object(forKey: key) {
            return hit.recipe
        }
        let built = ArtRecipe(card: card, detail: detail)
        store.setObject(RecipeBox(built), forKey: key)
        return built
    }
}

/// `NSCache` only holds objects, and a recipe is a value.
private final class RecipeBox {
    let recipe: ArtRecipe

    init(_ recipe: ArtRecipe) {
        self.recipe = recipe
    }
}

// MARK: - Art recipe

/// Which figure a card type draws.
private enum ArtMotif {
    case crest      // Leaders
    case nova       // EX Characters
    case shuriken   // Characters
    case scroll     // Support
    case spiral     // Chakra
    case sigil      // Summons

    init(_ type: CardType) {
        switch type {
        case .leader:      self = .crest
        case .exCharacter: self = .nova
        case .character:   self = .shuriken
        case .support:     self = .scroll
        case .chakra:      self = .spiral
        case .summon:      self = .sigil
        }
    }
}

/// The extra mark laid over a motif, so cards sharing a type still part company.
private enum ArtFlourish {
    case plain
    case halo
    case strata
    case shard

    init(_ index: Int) {
        switch index {
        case 0:  self = .plain
        case 1:  self = .halo
        case 2:  self = .strata
        default: self = .shard
        }
    }
}

/// Every decision the generated face makes, taken once at init from the card's
/// own collector number so the same card always draws identically.
private struct ArtRecipe {
    let detail: ArtDetail
    let motif: ArtMotif
    let flourish: ArtFlourish
    let spokes: Int
    let blades: Int
    let bands: Int
    /// Sides of the polygon at the heart of the crest and the summon sigil.
    let facets: Int
    let spiralSegments: Int
    let rotation: Double
    let secondRotation: Double
    let spread: Double
    let sweep: Double
    let innerRatio: Double
    let centre: UnitPoint
    let figureScale: CGFloat
    let flourishCentre: UnitPoint
    let flourishScale: Double
    let bloom: UnitPoint
    let bloomRadius: CGFloat
    let sheenAngle: Double
    let turns: Double
    let skew: Double
    /// How much of each Support band's slice is inked.
    let bandWeight: Double
    let phase: Double
    /// Where the Support seal sits down the face.
    let sealDrop: Double
    /// Gap between the crest's two rings.
    let ringGap: Double
    let groundMid: Double
    /// Signed lift on the ground: negative darkens, positive lightens.
    let wash: Double
    let gradientStart: UnitPoint
    let gradientEnd: UnitPoint

    init(card: Card, detail: ArtDetail) {
        // Name as well as number, so two cards printed with the same name at
        // different numbers still part company.
        var seed = CardSeed(card.id + "/" + card.name)

        self.detail = detail
        motif = ArtMotif(card.type)
        flourish = ArtFlourish(seed.int(0...3))

        // Every value below is drawn from the seed in the same order whatever
        // the detail bucket, and only then clamped, so the small face is the
        // large one with elements taken away — not a different card.
        spokes = min(seed.int(6...20), detail.spokeCap)
        blades = min(seed.int(3...8), detail.bladeCap)
        bands = min(seed.int(3...7), detail.bandCap)
        facets = min(seed.int(5...10), detail.facetCap)
        spiralSegments = detail.spiralSegments

        rotation = seed.double(0...360)
        secondRotation = seed.double(0...360)
        spread = seed.double(1.2...5)
        sweep = seed.double(26...70)
        innerRatio = seed.double(0.06...0.32)
        centre = UnitPoint(x: seed.double(0.26...0.74), y: seed.double(0.22...0.56))
        figureScale = CGFloat(seed.double(0.62...1.2))
        flourishCentre = UnitPoint(x: seed.double(0.15...0.85), y: seed.double(0.15...0.8))
        flourishScale = seed.double(0.3...1.1)
        bloom = UnitPoint(x: seed.double(0.24...0.76), y: seed.double(0.16...0.5))
        bloomRadius = CGFloat(seed.double(0.45...1))
        sheenAngle = seed.double((-52)...(-4))
        turns = seed.double(1.8...4)
        skew = seed.double((-0.42)...0.42)
        bandWeight = seed.double(0.3...0.8)
        phase = seed.double(0...1)
        sealDrop = seed.double(0.56...0.78)
        ringGap = seed.double(0.12...0.4)
        groundMid = seed.double(0.34...0.72)
        wash = seed.double((-0.14)...0.1)

        let (start, end) = Self.diagonal(seed.int(0...3))
        gradientStart = start
        gradientEnd = end
    }

    private static func diagonal(_ corner: Int) -> (UnitPoint, UnitPoint) {
        switch corner {
        case 0:  return (.topLeading, .bottomTrailing)
        case 1:  return (.topTrailing, .bottomLeading)
        case 2:  return (.top, .bottom)
        default: return (.bottomLeading, .topTrailing)
        }
    }
}

// MARK: - Seeded generator

/// A deterministic generator. `hashValue` is salted per process, so the digest
/// is computed here instead and a card looks the same across launches.
private struct CardSeed {
    private var state: UInt64

    /// FNV-1a over the string, then SplitMix64 for the stream itself.
    init(_ source: String) {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in source.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01b3
        }
        state = hash == 0 ? 0x9E37_79B9_7F4A_7C15 : hash
    }

    private mutating func next() -> UInt64 {
        state = state &+ 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }

    /// A value in `0..<1`.
    mutating func unit() -> Double {
        Double(next() >> 11) * (1.0 / 9_007_199_254_740_992.0)
    }

    mutating func double(_ range: ClosedRange<Double>) -> Double {
        range.lowerBound + unit() * (range.upperBound - range.lowerBound)
    }

    mutating func int(_ range: ClosedRange<Int>) -> Int {
        let span = range.upperBound - range.lowerBound + 1
        guard span > 1 else { return range.lowerBound }
        return range.lowerBound + Int(next() % UInt64(span))
    }
}

// MARK: - Grain

/// One small tile of static noise, built once and shared by every face. Tiling
/// a bitmap is the only way to get real grain without doing per-pixel work at
/// draw time.
private enum ArtTexture {
    static let grain = Image(uiImage: makeGrain())

    private static func makeGrain() -> UIImage {
        let side = 48
        var seed = CardSeed("ntcg.grain")
        let format = UIGraphicsImageRendererFormat.preferred()
        format.scale = 1
        format.opaque = false

        let renderer = UIGraphicsImageRenderer(
            size: CGSize(width: side, height: side),
            format: format
        )
        return renderer.image { context in
            let cg = context.cgContext
            for y in 0..<side {
                for x in 0..<side {
                    let value = seed.unit()
                    cg.setFillColor(gray: value > 0.5 ? 1 : 0,
                                    alpha: abs(value - 0.5) * 0.34)
                    cg.fill(CGRect(x: x, y: y, width: 1, height: 1))
                }
            }
        }
    }
}

// MARK: - Motif shapes

/// Straight spokes fired out of a point.
private struct RadiatingSpokes: Shape {
    var count: Int
    var rotation: Double
    /// Half-width of one spoke, in degrees.
    var spread: Double
    /// Where the spokes begin, as a fraction of their length.
    var innerRatio: Double
    var centre: UnitPoint

    func path(in rect: CGRect) -> Path {
        var path = Path()
        guard count > 0, rect.width > 0, rect.height > 0 else { return path }

        let origin = centre.point(in: rect)
        let radius = Double(hypot(rect.width, rect.height))
        let inner = radius * innerRatio
        let step = 360 / Double(count)

        for index in 0..<count {
            let middle = rotation + step * Double(index)
            let leading = (middle - spread).radians
            let trailing = (middle + spread).radians
            path.move(to: origin.offset(by: inner, at: leading))
            path.addLine(to: origin.offset(by: radius, at: leading))
            path.addLine(to: origin.offset(by: radius, at: trailing))
            path.addLine(to: origin.offset(by: inner, at: trailing))
            path.closeSubpath()
        }
        return path
    }
}

/// Curved blades turning about a point — the shuriken silhouette.
private struct BladeFan: Shape {
    var count: Int
    var rotation: Double
    /// Degrees of arc one blade covers.
    var sweep: Double
    var innerRatio: Double
    var centre: UnitPoint

    func path(in rect: CGRect) -> Path {
        var path = Path()
        guard count > 0, rect.width > 0, rect.height > 0 else { return path }

        let origin = centre.point(in: rect)
        let radius = Double(min(rect.width, rect.height)) * 0.78
        let inner = radius * innerRatio
        let step = 360 / Double(count)

        for index in 0..<count {
            let base = rotation + step * Double(index)
            let tip = base + sweep
            path.move(to: origin.offset(by: inner, at: base.radians))
            path.addQuadCurve(
                to: origin.offset(by: radius, at: tip.radians),
                control: origin.offset(by: radius * 0.72, at: (base + sweep * 0.15).radians)
            )
            path.addLine(to: origin.offset(by: radius * 0.8, at: (tip + sweep * 0.32).radians))
            path.addQuadCurve(
                to: origin.offset(by: inner, at: (base + sweep * 0.5).radians),
                control: origin.offset(by: radius * 0.42, at: (base + sweep * 0.9).radians)
            )
            path.closeSubpath()
        }
        return path
    }
}

/// An Archimedean spiral, sampled finely enough to read as a curve at the size
/// it is actually drawn.
private struct ChakraSpiral: Shape {
    var turns: Double
    var rotation: Double
    /// Radius the spiral starts at, as a fraction of its final radius.
    var startRatio: Double
    var centre: UnitPoint
    var segments: Int = 96

    func path(in rect: CGRect) -> Path {
        var path = Path()
        guard segments > 1, rect.width > 0, rect.height > 0 else { return path }

        let origin = centre.point(in: rect)
        let radius = Double(min(rect.width, rect.height)) * 0.62

        for step in 0...segments {
            let progress = Double(step) / Double(segments)
            let angle = (rotation + progress * turns * 360).radians
            let distance = radius * (startRatio + (1 - startRatio) * progress)
            let point = origin.offset(by: distance, at: angle)
            if step == 0 {
                path.move(to: point)
            } else {
                path.addLine(to: point)
            }
        }
        return path
    }
}

/// Diagonal strata laid across the whole face.
private struct BandStack: Shape {
    var count: Int
    /// How much of each band's slice is inked, `0...1`.
    var thickness: Double
    /// Horizontal drift over the full height, as a fraction of the width.
    var skew: Double
    /// Where the first band starts within its slice.
    var phase: Double

    func path(in rect: CGRect) -> Path {
        var path = Path()
        guard count > 0, rect.width > 0, rect.height > 0 else { return path }

        let spacing = Double(rect.height) / Double(count)
        let drift = Double(rect.width) * skew
        let band = spacing * thickness
        let offset = phase.truncatingRemainder(dividingBy: 1) * spacing

        for index in 0..<count {
            let top = Double(rect.minY) + spacing * Double(index) + offset - band
            path.move(to: CGPoint(x: Double(rect.minX) - drift, y: top))
            path.addLine(to: CGPoint(x: Double(rect.maxX) + drift, y: top - drift))
            path.addLine(to: CGPoint(x: Double(rect.maxX) + drift, y: top - drift + band))
            path.addLine(to: CGPoint(x: Double(rect.minX) - drift, y: top + band))
            path.closeSubpath()
        }
        return path
    }
}

/// A regular polygon, used on its own and stacked into the Summon sigil.
private struct SigilPolygon: Shape {
    var sides: Int
    var rotation: Double
    /// Circumradius as a fraction of the short side.
    var radiusRatio: Double
    var centre: UnitPoint

    func path(in rect: CGRect) -> Path {
        var path = Path()
        guard sides >= 3, rect.width > 0, rect.height > 0 else { return path }

        let origin = centre.point(in: rect)
        let radius = Double(min(rect.width, rect.height)) * radiusRatio
        let step = 360 / Double(sides)

        for index in 0...sides {
            let point = origin.offset(by: radius, at: (rotation + step * Double(index)).radians)
            if index == 0 {
                path.move(to: point)
            } else {
                path.addLine(to: point)
            }
        }
        path.closeSubpath()
        return path
    }
}

// MARK: - Geometry helpers

private extension UnitPoint {
    /// This unit point resolved inside a rectangle.
    func point(in rect: CGRect) -> CGPoint {
        CGPoint(x: rect.minX + rect.width * x, y: rect.minY + rect.height * y)
    }
}

private extension CGPoint {
    /// The point `distance` away at `angle`, measured in radians.
    func offset(by distance: Double, at angle: Double) -> CGPoint {
        CGPoint(x: Double(x) + distance * cos(angle), y: Double(y) + distance * sin(angle))
    }
}

private extension Double {
    var radians: Double { self * .pi / 180 }
}

// MARK: - Card back

/// The reverse of a card, used for opponent hands and face-down chakra. Drawn
/// with the same passes as a generated face — ground, motif, sheen, vignette,
/// grain — so a face-down card belongs to the same set as a face-up one, and
/// flattened the same way, because a deck stack draws a great many of them.
struct CardBackView: View {
    var tint: Color = Palette.accent

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [Palette.adaptive(dark: 0x2A2033, light: 0x3A2E44),
                         Palette.adaptive(dark: 0x160F1C, light: 0x241A2C)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )

            EllipticalGradient(
                colors: [tint.opacity(0.35), .clear],
                center: .center,
                startRadiusFraction: 0,
                endRadiusFraction: 0.75
            )

            GeometryReader { geo in
                let unit = min(geo.size.width, geo.size.height)
                let middle = CGPoint(x: geo.size.width / 2, y: geo.size.height / 2)

                ZStack {
                    RadiatingSpokes(count: 12, rotation: 15, spread: 3.4,
                                    innerRatio: 0.2, centre: .center)
                        .fill(tint.opacity(0.2))
                    Circle()
                        .stroke(tint.opacity(0.55), lineWidth: unit * 0.035)
                        .frame(width: unit * 0.54, height: unit * 0.54)
                        .position(middle)
                    SigilPolygon(sides: 4, rotation: 45, radiusRatio: 0.27, centre: .center)
                        .stroke(tint.opacity(0.35), lineWidth: unit * 0.014)
                    SigilPolygon(sides: 4, rotation: 45, radiusRatio: 0.15, centre: .center)
                        .fill(tint.opacity(0.75))
                }
                .frame(width: geo.size.width, height: geo.size.height)
            }

            LinearGradient(
                stops: [
                    .init(color: .clear, location: 0),
                    .init(color: .white.opacity(0.12), location: 0.5),
                    .init(color: .clear, location: 1)
                ],
                startPoint: .top,
                endPoint: .bottom
            )
            .rotationEffect(.degrees(-28))
            .scaleEffect(1.9)

            EllipticalGradient(
                stops: [
                    .init(color: .clear, location: 0.35),
                    .init(color: .black.opacity(0.5), location: 1)
                ],
                center: .center,
                startRadiusFraction: 0,
                endRadiusFraction: 0.82
            )

            ArtTexture.grain
                .resizable(resizingMode: .tile)
                .opacity(0.45)

            NotchedRectangle(notch: 4, corners: .diagonal)
                .stroke(tint.opacity(0.3), lineWidth: 0.75)
                .padding(4)
        }
        .drawingGroup()
        .aspectRatio(Metrics.cardAspect, contentMode: .fit)
        .notchedPanel(notch: 6, corners: .diagonal, fill: .clear,
                      stroke: tint.opacity(0.45), lineWidth: 1)
    }
}

// MARK: - Previews

/// A hand-built pool, so the previews do not depend on what happens to be in
/// `cards.json` or on the player's imported set.
///
/// The two cards that carry abilities carry their real printings, so the badge
/// and the activation line are exercised against the shape live data actually
/// has. The Support cards are invented, because the shipped set prints none and
/// the Support face treatment would otherwise never be seen.
private func previewPool() -> [Card] {
    [
        Card(id: "N-001", name: "Naruto Uzumaki", type: .leader, color: .red,
             rarity: .leader, setCode: "01",
             traits: ["Wind", "Jinchuriki", "Hidden Leaf Village", "Team 7"],
             power: 3, damage: 1, life: 15,
             effect: "[Activate: Main] Flip 1 of your CHAKRA face-down and choose 1 Character: The chosen card gets +3 power during this turn.",
             abilities: [
                CardAbility(
                    trigger: .activateMain,
                    cost: AbilityCost(chakra: 1),
                    target: .anyCharacter,
                    text: "Flip 1 of your CHAKRA face-down and choose 1 Character: The chosen card gets +3 power during this turn.",
                    effects: [.buffPower(3, .anyCharacter)]
                )
             ]),
        Card(id: "N-004", name: "Naruto Uzumaki", type: .character, color: .red,
             rarity: .common, setCode: "01",
             traits: ["Special", "Jinchuriki", "Hidden Leaf Village", "Team 7"],
             cost: 2, power: 5, damage: 1, health: 4,
             effect: "[During Your Main] K.O. all Characters.",
             supportText: "Support: may be played as a jutsu instead of being summoned.",
             abilities: [
                CardAbility(
                    trigger: .duringYourMain,
                    cost: AbilityCost(chakra: 2),
                    text: "K.O. all Characters.",
                    effects: [.knockOut(.allCharacters)]
                )
             ]),
        Card(id: "N-030", name: "Sakura Haruno", type: .exCharacter, color: .blue,
             rarity: .rare, setCode: "01",
             traits: ["Team 7", "Medical"],
             cost: 3, power: 4, damage: 1, health: 5,
             effect: "Blocks for your Leader once per turn.",
             supportText: "Play as a jutsu: restore 2 life."),
        Card(id: "SP-R03", name: "Nine-Tails Chakra", type: .support, color: .red,
             rarity: .superRare, setCode: "01",
             traits: ["Jinchuriki"],
             cost: 4,
             effect: "While this is in Support, your Characters have +2 power."),
        Card(id: "SP-G01", name: "Byakugan Sight", type: .support, color: .green,
             rarity: .common, setCode: "01",
             traits: ["Hyuga Clan", "Special"],
             cost: 2,
             effect: "While this is in Support, your Characters have +1 power."),
        Card(id: "C-001", name: "Chakra Card", type: .chakra, color: .blue,
             rarity: .common, setCode: "01",
             traits: ["Special"],
             effect: "Turn this face up during Refresh to pay for a card."),
        Card(id: "S-001", name: "Summon Card", type: .summon, color: .green,
             rarity: .secretBox, setCode: "01",
             traits: ["Special"],
             cost: 3,
             effect: "Place in the Summon zone.")
    ]
}

#Preview("Faces at every size") {
    let pool = previewPool()

    ScrollView {
        VStack(alignment: .leading, spacing: Metrics.spacingM) {
            ForEach([("Tiny · 44pt", CardFaceSize.tiny, CGFloat(44)),
                     ("Small · 78pt", .small, 78),
                     ("Medium · 124pt", .medium, 124)], id: \.0) { row in
                Text(row.0).sectionLabel()
                ScrollView(.horizontal) {
                    HStack(alignment: .top, spacing: Metrics.spacingS) {
                        ForEach(pool) { card in
                            CardFaceView(card: card, size: row.1)
                                .frame(width: row.2)
                        }
                    }
                }
                .scrollIndicators(.hidden)
            }
        }
        .padding(Metrics.spacingM)
    }
    .background(AmbientBackground())
    .environment(CardDatabase(cards: pool))
}

#Preview("Leader and Support, large") {
    let pool = previewPool()

    HStack(spacing: Metrics.spacingM) {
        ForEach(pool.filter { $0.type == .leader || $0.type == .support }) { card in
            CardFaceView(card: card, size: .large)
                .frame(width: 200)
        }
    }
    .padding(Metrics.spacingL)
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .background(AmbientBackground())
    .environment(CardDatabase(cards: pool))
}

#Preview("Generated art, three budgets") {
    let card = previewPool()[1]

    VStack(alignment: .leading, spacing: Metrics.spacingM) {
        Text("Board · hand · inspector").sectionLabel()
        HStack(spacing: Metrics.spacingS) {
            ForEach([ArtDetail.minimal, .reduced, .full], id: \.rawValue) { detail in
                GeneratedCardArt(card: card)
                    .environment(\.cardArtDetail, detail)
                    .frame(width: 130, height: 130 / Metrics.cardAspect)
                    .clipShape(NotchedRectangle(notch: 9, corners: .diagonal))
            }
        }
    }
    .padding(Metrics.spacingL)
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .background(AmbientBackground())
}

#Preview("Card back") {
    HStack(spacing: Metrics.spacingM) {
        CardBackView().frame(width: 44)
        CardBackView(tint: Palette.textSecondary).frame(width: 78)
        CardBackView(tint: Palette.border).frame(width: 140)
    }
    .padding(Metrics.spacingL)
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .background(AmbientBackground())
}
