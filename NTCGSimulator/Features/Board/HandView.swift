//
//  HandView.swift
//  NTCGSimulator
//
//  The near player's hand: a horizontal strip of faces that lifts the card being
//  read and dims anything the board cannot play. The engine already works out
//  playability per index, so this view only has to draw the answer — and price
//  each card by what the play actually charges, which for a summon is nothing.
//

import SwiftUI

// MARK: - Hand

/// The hand strip along the bottom of the board.
///
/// `HandCard.id` is the hand index `GameAction.playCard` expects, so a tap can
/// be turned straight into an action without the view tracking positions itself.
struct HandView: View {

    let cards: [HandCard]

    /// Derived from the board's slot width so cards shrink with the board.
    let cardWidth: CGFloat

    /// Chakra this player can still spend, from `engine.availableChakra(for:)`.
    /// The cost markers use it to say what is affordable rather than only what
    /// is printed.
    let availableChakra: Int

    /// The hand index currently being read, lifted clear of its neighbours.
    let selectedIndex: Int?

    /// False while the other side is acting — everything dims and taps are
    /// still forwarded, so the board can explain why nothing happened.
    let isInteractive: Bool

    /// Shown when the hand is empty. Worded by the board, which knows whose
    /// hand this is.
    let emptyMessage: String

    /// A tap: play the card if it can be played.
    let onPlay: (HandCard) -> Void

    /// A long press: read the card without committing to it.
    let onRead: (HandCard) -> Void

    /// How far the read card rises out of the strip.
    private let lift: CGFloat = 10

    /// Matches the dim `CardFaceView` applies to a card that cannot be played,
    /// so the cost bar fades with the face it sits on.
    private let dimmedOpacity: CGFloat = 0.45

    var body: some View {
        Group {
            if cards.isEmpty {
                emptyState
            } else {
                strip
            }
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: Strip

    private var strip: some View {
        ScrollView(.horizontal) {
            HStack(alignment: .bottom, spacing: Metrics.spacingXS) {
                ForEach(cards) { handCard in
                    face(for: handCard)
                }
            }
            // Leaves room for the lift and for the selection stroke.
            .padding(.top, lift)
            .padding(.horizontal, Metrics.spacingXS)
        }
        .scrollIndicators(.hidden)
    }

    private func face(for handCard: HandCard) -> some View {
        let isSelected = handCard.id == selectedIndex
        let isDimmed = !isInteractive || !handCard.isPlayable

        return BoardCardFace(
            card: handCard.card,
            size: .small,
            width: cardWidth,
            isDimmed: isDimmed,
            highlight: isSelected ? Palette.accent : nil
        )
        .overlay(alignment: .top) {
            PlayCostBar(card: handCard.card, availableChakra: availableChakra, width: cardWidth)
                .opacity(isDimmed ? dimmedOpacity : 1)
                .allowsHitTesting(false)
        }
        .offset(y: isSelected ? -lift : 0)
        .animation(.spring(response: 0.28, dampingFraction: 0.8), value: isSelected)
        .contentShape(Rectangle())
        .onTapGesture { onPlay(handCard) }
        .onLongPressGesture { onRead(handCard) }
        .accessibilityElement(children: .ignore)
        .accessibilityAddTraits(.isButton)
        .accessibilityLabel(label(for: handCard))
        .accessibilityHint(handCard.isPlayable ? "Double tap to play" : "Cannot be played right now")
        .accessibilityAction(named: Text("Read this card")) { onRead(handCard) }
    }

    private var emptyState: some View {
        Text(emptyMessage)
            .font(Typeface.body(13))
            .foregroundStyle(Palette.textSecondary)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .notchedPanel(notch: 8, fill: Palette.panel.opacity(0.5), stroke: Palette.border)
    }

    private func label(for handCard: HandCard) -> String {
        let card = handCard.card
        var parts = [card.name, card.type.title]
        parts.append(contentsOf: costPhrases(for: card))
        if let power = card.power { parts.append("power \(power)") }
        if let health = card.health { parts.append("health \(health)") }
        return parts.joined(separator: ", ")
    }

    /// What the play charges, spoken. The printed number is never read out as a
    /// summoning price, because summoning is free.
    private func costPhrases(for card: Card) -> [String] {
        var parts: [String] = []
        if card.type.costsChakraToPlay {
            parts.append("costs \(card.cost ?? 0) chakra")
        } else {
            parts.append("free to play")
        }
        if let jutsu = card.jutsuCost {
            parts.append("or \(jutsu) chakra as a jutsu")
        }
        return parts
    }
}

// MARK: - Play cost

/// What playing one card from hand actually charges.
///
/// The number printed on a Character is not a summoning price — summoning is
/// free — so this bar covers the printed cost with the prices that are real:
/// nothing for a body, the card's cost for a Support card, and the jutsu price
/// on its own marker for a card that carries a support line.
private struct PlayCostBar: View {

    let card: Card

    /// Chakra ready right now, which decides whether a price reads as payable.
    let availableChakra: Int

    /// The card's width. A body carrying both prices has to fit two markers
    /// into it, and half of a phone-sized hand card is not wide enough for a
    /// word — below the threshold the jutsu marker keeps only its glyph.
    let width: CGFloat

    private static let wordThreshold: CGFloat = 96

    var body: some View {
        HStack(spacing: 2) {
            if card.type.costsChakraToPlay {
                chip("\(card.cost ?? 0) chakra", amount: card.cost ?? 0)
            } else {
                chip("Free", tint: Palette.positive)
            }

            Spacer(minLength: 0)

            if let jutsu = card.jutsuCost {
                jutsuChip(jutsu)
            }
        }
        .padding(.horizontal, 2)
        .padding(.vertical, 1.5)
        .frame(maxWidth: .infinity)
        .background(Palette.backdrop.opacity(0.72))
        // The card's own top-trailing corner is cut, so the bar's is too.
        .clipShape(NotchedRectangle(notch: 6, corners: [.topTrailing]))
        .accessibilityHidden(true)
    }

    /// The support line's own price, kept apart from the summon price beside it.
    private func jutsuChip(_ amount: Int) -> some View {
        let showsWord = width >= Self.wordThreshold
        return chip(
            showsWord ? "Jutsu \(amount)" : "\(amount)",
            icon: showsWord ? nil : "sparkles",
            amount: amount
        )
    }

    /// A price the player may or may not be able to meet. An unaffordable one
    /// stays legible but stops looking like an offer.
    private func chip(_ text: String, icon: String? = nil, amount: Int) -> some View {
        let isAffordable = amount <= availableChakra
        return chip(
            text,
            icon: icon,
            tint: isAffordable ? Palette.accent : Palette.textSecondary,
            isAffordable: isAffordable
        )
    }

    private func chip(
        _ text: String,
        icon: String? = nil,
        tint: Color,
        isAffordable: Bool = true
    ) -> some View {
        HStack(spacing: 1) {
            if let icon {
                Image(systemName: icon)
                    .font(.system(size: 6, weight: .bold))
            }
            Text(text)
                .font(Typeface.label(8))
                .textCase(.uppercase)
                .lineLimit(1)
                .minimumScaleFactor(0.6)
        }
        .foregroundStyle(Palette.textOnAccent)
        .padding(.horizontal, 2)
        .padding(.vertical, 0.5)
        .background(tint.opacity(0.95), in: RoundedRectangle(cornerRadius: 3))
        .opacity(isAffordable ? 1 : 0.7)
    }
}

// MARK: - Previews

#Preview("Dealt hand") {
    let database = CardDatabase()
    let engine = BoardPreview.engine(database: database)

    HandView(
        cards: engine.handCards(for: .player),
        cardWidth: 62,
        availableChakra: engine.availableChakra(for: .player),
        selectedIndex: 1,
        isInteractive: true,
        emptyMessage: "Your hand is empty.",
        onPlay: { _ in },
        onRead: { _ in }
    )
    .frame(height: 100)
    .padding()
    .background(Palette.backdrop)
    .environment(database)
}

/// One of each priced case side by side: a free summon, a card that can also be
/// spent as a jutsu, and a Support card the player cannot yet afford.
#Preview("Every price") {
    let database = CardDatabase()
    let samples = [
        database.cards.first { $0.type.isBody && !$0.hasSupportLine },
        database.cards.first { $0.hasSupportLine },
        database.cards.filter { $0.type == .support }.max { ($0.cost ?? 0) < ($1.cost ?? 0) }
    ].compactMap { $0 }

    HandView(
        cards: samples.enumerated().map { HandCard(id: $0.offset, card: $0.element, isPlayable: $0.offset != 2) },
        cardWidth: 62,
        availableChakra: 1,
        selectedIndex: nil,
        isInteractive: true,
        emptyMessage: "Your hand is empty.",
        onPlay: { _ in },
        onRead: { _ in }
    )
    .frame(height: 100)
    .padding()
    .background(Palette.backdrop)
    .environment(database)
}
