//
//  CardDetailView.swift
//  NTCGSimulator
//
//  The full printing of a single card: the large face, every value on it, what
//  it actually costs to put into play, the effect and support lines, a Leader's
//  ability, and the illustration credit.
//

import SwiftUI

// MARK: - Card detail

/// Inspects one card by collector number. The number is carried in the route
/// rather than the card itself, so the screen survives a pool being reimported
/// underneath it — it simply reports the card as missing.
struct CardDetailView: View {

    /// Printed collector number, e.g. `N-030`.
    let cardID: String

    @Environment(CardDatabase.self) private var database
    @Environment(Router.self) private var router

    /// A card face any wider than this stops reading as a card on iPad and
    /// starts reading as a poster.
    private let maxFaceWidth: CGFloat = 320

    var body: some View {
        ScreenScaffold(
            title: "Card",
            subtitle: "The full printing, exactly as the card is written."
        ) {
            ScrollView {
                if let card = database.card(id: cardID) {
                    content(for: card)
                } else {
                    missingCard
                }
            }
            .scrollIndicators(.hidden)
        }
    }

    // MARK: Body

    private func content(for card: Card) -> some View {
        VStack(alignment: .leading, spacing: Metrics.spacingL) {
            face(card)
            titleBlock(card)
            statRow(card)
            factRows(card)
            costPanel(card)
            leaderAbilityPanel(card)
            traitBlock(card)
            effectPanel(card)
            supportPanel(card)
            artistCredit(card)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.bottom, Metrics.spacingXL)
    }

    /// Centred so the face stays the hero of the screen at every width.
    private func face(_ card: Card) -> some View {
        HStack {
            Spacer(minLength: 0)
            CardFaceView(card: card, size: .large)
                .frame(maxWidth: maxFaceWidth)
            Spacer(minLength: 0)
        }
    }

    private func titleBlock(_ card: Card) -> some View {
        VStack(alignment: .leading, spacing: Metrics.spacingXS) {
            Text(card.name)
                .font(Typeface.display(24))
                .tracking(1.2)
                .foregroundStyle(Palette.textPrimary)
                .fixedSize(horizontal: false, vertical: true)

            Text(card.id)
                .font(Typeface.label(12))
                .tracking(1.6)
                .foregroundStyle(Palette.accent)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(card.name), collector number \(card.id)")
    }

    // MARK: Stats

    /// Only the values actually printed on the card get a pill — a Leader has
    /// life and no power, a Chakra card has neither.
    private func statRow(_ card: Card) -> some View {
        HStack(spacing: Metrics.spacingS) {
            ForEach(statReadouts(for: card), id: \.label) { readout in
                CountPill(label: readout.label, value: readout.value)
            }
            Spacer(minLength: 0)
        }
    }

    private func statReadouts(for card: Card) -> [(label: String, value: String)] {
        var readouts: [(label: String, value: String)] = []
        if let chakra = chakraReadout(for: card) { readouts.append(chakra) }
        if let power  = card.power  { readouts.append(("Power", "\(power)")) }
        if let damage = card.damage { readouts.append(("Damage", "\(damage)")) }
        if let health = card.health { readouts.append(("Health", "\(health)")) }
        if let life   = card.life   { readouts.append(("Life", "\(life)")) }
        return readouts
    }

    /// The printed number is a chakra price only for a Support card or for a
    /// jutsu play, so it is labelled as whichever of those the card can do. A
    /// body that can only be summoned gets no pill at all — summoning is free.
    private func chakraReadout(for card: Card) -> (label: String, value: String)? {
        if card.type.costsChakraToPlay, let cost = card.cost {
            return ("Cost", "\(cost)")
        }
        if let jutsu = card.jutsuCost {
            return ("Jutsu", "\(jutsu)")
        }
        return nil
    }

    // MARK: Facts

    private func factRows(_ card: Card) -> some View {
        VStack(alignment: .leading, spacing: Metrics.spacingM) {
            labelledRow("Type") {
                factText(card.type.title)
            }

            labelledRow("Colour") {
                HStack(spacing: Metrics.spacingS) {
                    RoundedRectangle(cornerRadius: 3)
                        .fill(card.color.tint)
                        .frame(width: 14, height: 14)
                        .accessibilityHidden(true)
                    factText(card.color.title)
                }
            }

            labelledRow("Rarity") {
                factText("\(card.rarity.code) — \(card.rarity.title)")
            }

            labelledRow("Set") {
                factText("Set \(card.setCode)")
            }
        }
    }

    /// Label on the left, value on the right, so the rows line up as a table.
    private func labelledRow<Value: View>(
        _ label: String,
        @ViewBuilder value: () -> Value
    ) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: Metrics.spacingM) {
            Text(label)
                .sectionLabel()
                .frame(minWidth: 72, alignment: .leading)
            value()
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .combine)
    }

    private func factText(_ text: String) -> some View {
        Text(text)
            .font(Typeface.body(15))
            .foregroundStyle(Palette.textPrimary)
            .fixedSize(horizontal: false, vertical: true)
    }

    // MARK: Traits

    /// Traits are shown as chips for consistency with the Collection filters,
    /// but they do nothing here — this screen is a reference, not a control.
    @ViewBuilder
    private func traitBlock(_ card: Card) -> some View {
        VStack(alignment: .leading, spacing: Metrics.spacingS) {
            Text("Traits").sectionLabel()

            if card.traits.isEmpty {
                Text("This card has no traits.")
                    .font(Typeface.body(14))
                    .foregroundStyle(Palette.textSecondary)
            } else {
                ScrollView(.horizontal) {
                    HStack(spacing: Metrics.spacingS) {
                        ForEach(card.traits, id: \.self) { name in
                            StaticChip(title: name)
                        }
                    }
                    // Keeps the chip strokes off the clipping edge.
                    .padding(.vertical, 2)
                }
                .scrollIndicators(.hidden)
            }
        }
    }

    // MARK: Rules text

    @ViewBuilder
    private func effectPanel(_ card: Card) -> some View {
        if card.effect.isEmpty {
            textPanel(heading: "Effect", body: "This card has no effect text.", isMuted: true)
        } else {
            textPanel(heading: "Effect", body: card.effect)
        }
    }

    /// The Support line, when the card has one. A card with a Support line can
    /// be summoned as a body for free, or spent as a jutsu for its cost.
    @ViewBuilder
    private func supportPanel(_ card: Card) -> some View {
        if let support = card.supportText, !support.isEmpty {
            supportPanelBody(card, support: support)
        }
    }

    private func supportPanelBody(_ card: Card, support: String) -> some View {
        VStack(alignment: .leading, spacing: Metrics.spacingS) {
            Text("Support").sectionLabel()

            Text(support)
                .font(Typeface.body(15))
                .foregroundStyle(Palette.textPrimary)
                .fixedSize(horizontal: false, vertical: true)

            Text(supportLineExplanation(card))
                .font(Typeface.body(13))
                .foregroundStyle(Palette.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(Metrics.spacingM)
        .notchedPanel(fill: Palette.panelActive, stroke: Palette.accentMuted)
    }

    /// The Support line in plain words: two ways to play one card, only one of
    /// which costs anything.
    private func supportLineExplanation(_ card: Card) -> String {
        let price = card.jutsuCost ?? 0
        return """
        You choose one or the other when you play it. Summoning \(card.name) \
        as a Character costs no chakra. Playing this Support line instead is a \
        jutsu: it costs \(chakraPhrase(price)) and the card goes straight to \
        the Trash rather than onto the board.
        """
    }

    // MARK: Cost

    /// What the card costs to put into play.
    ///
    /// This deliberately never presents a Character's printed number as a
    /// summoning price. Summoning is free; the printed cost is what the card
    /// costs played as a jutsu, or played as a Support card.
    @ViewBuilder
    private func costPanel(_ card: Card) -> some View {
        switch card.type {
        case .leader, .chakra:
            EmptyView()

        case .support:
            textPanel(heading: "Cost", body: supportCostDescription(card))

        case .character, .exCharacter:
            textPanel(heading: "Cost", body: summonCostDescription(card))

        case .summon:
            textPanel(
                heading: "Cost",
                body: "Place: free — the Summon zone takes no chakra to fill."
            )
        }
    }

    /// Wording for a card that is summoned rather than paid for.
    private func summonCostDescription(_ card: Card) -> String {
        var lines = ["Summon: free — putting a body on the board costs no chakra."]
        if let jutsu = card.jutsuCost {
            lines.append("As a jutsu: \(chakraPhrase(jutsu)), then it goes to the Trash.")
        }
        return lines.joined(separator: "\n")
    }

    /// Wording for the one card type that is genuinely bought with chakra.
    private func supportCostDescription(_ card: Card) -> String {
        """
        Play: \(chakraPhrase(card.cost ?? 0)). It fills one of your \
        \(GameRules.supportSlots) Support slots and stays there.
        """
    }

    /// "2 chakra", or "no chakra" when the play is free.
    private func chakraPhrase(_ amount: Int) -> String {
        amount == 0 ? "no chakra" : "\(amount) chakra"
    }

    // MARK: Leader ability

    /// A Leader's activated ability. Unlike other printed effects, this one the
    /// engine actually resolves, so it is worth calling out separately.
    @ViewBuilder
    private func leaderAbilityPanel(_ card: Card) -> some View {
        if let ability = card.leaderAbility {
            VStack(alignment: .leading, spacing: Metrics.spacingS) {
                Text("Leader ability").sectionLabel()

                Text(ability.summary)
                    .font(Typeface.body(15))
                    .foregroundStyle(Palette.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)

                Text(leaderAbilityFootnote(ability))
                    .font(Typeface.body(13))
                    .foregroundStyle(Palette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(Metrics.spacingM)
            .notchedPanel(fill: Palette.panelActive, stroke: Palette.accent)
        }
    }

    private func leaderAbilityFootnote(_ ability: LeaderAbility) -> String {
        var text = "Activate once per turn during your main phase. It costs no chakra."
        if ability.needsFriendlyTarget {
            text += " Choose one of your own characters as the target."
        } else if ability.needsEnemyTarget {
            text += " Choose one of your opponent's characters as the target."
        } else {
            text += " It needs no target."
        }
        return text
    }

    private func textPanel(heading: String, body text: String, isMuted: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: Metrics.spacingS) {
            Text(heading).sectionLabel()

            Text(text)
                .font(Typeface.body(15))
                .foregroundStyle(isMuted ? Palette.textSecondary : Palette.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(Metrics.spacingM)
        .notchedPanel()
    }

    // MARK: Credit

    private func artistCredit(_ card: Card) -> some View {
        Text(card.artist.map { "Illustration by \($0)" } ?? "Illustration uncredited")
            .font(Typeface.body(12))
            .foregroundStyle(Palette.textSecondary)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: Missing card

    /// An imported pool can be swapped out while a card route is on the stack,
    /// which leaves the collector number pointing at nothing.
    private var missingCard: some View {
        VStack(spacing: Metrics.spacingM) {
            EmptyStatePanel(
                headline: "Card not found",
                message: "No card numbered \(cardID) is in the pool right now. It may have come from a set that has since been replaced."
            )
            WideButton(title: "Back to the collection", style: .primary) {
                router.pop()
            }
        }
        .padding(.top, Metrics.spacingM)
    }
}

// MARK: - Static chip

/// A chip that only reports — the read-only twin of `FilterChip`, used for
/// trait lines that must not look tappable.
private struct StaticChip: View {
    let title: String

    var body: some View {
        Text(title)
            .font(Typeface.label(11))
            .tracking(1.2)
            .textCase(.uppercase)
            .foregroundStyle(Palette.textSecondary)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .notchedPanel(notch: 6, corners: .diagonal)
    }
}

// MARK: - Previews

#Preview("Character with support") {
    NavigationStack {
        CardDetailView(cardID: "N-030")
    }
    .environment(CardDatabase())
    .environment(Router())
}

#Preview("Support card") {
    NavigationStack {
        CardDetailView(cardID: "SP-R01")
    }
    .environment(CardDatabase())
    .environment(Router())
}

#Preview("Leader with an ability") {
    NavigationStack {
        CardDetailView(cardID: "N-001")
    }
    .environment(CardDatabase())
    .environment(Router())
}

#Preview("Unknown number") {
    NavigationStack {
        CardDetailView(cardID: "ZZ-999")
    }
    .environment(CardDatabase())
    .environment(Router())
}
