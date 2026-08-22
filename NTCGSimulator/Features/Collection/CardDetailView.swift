//
//  CardDetailView.swift
//  NTCGSimulator
//
//  The full printing of a single card: the large face, every value on it, what
//  it actually costs to put into play, every ability box it prints, the support
//  line, and the illustration credit.
//
//  The ability boxes are the point of this screen. A real card prints several of
//  them, each with its own trigger, its own cost and its own target, and the app
//  resolves some steps and not others. So every box says which of the two it is.
//  A player told that a step will not be applied can settle it at the table; a
//  player who is not told will believe the board.
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
            traitBlock(card)
            abilitySection(card)
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

    /// The printed number is a chakra price only for a jutsu play, or for
    /// flipping the card face-up off its SUPPORT bar. A body that can do
    /// neither gets no pill at all — summoning is free.
    private func chakraReadout(for card: Card) -> (label: String, value: String)? {
        if let jutsu = card.jutsuCost {
            return ("Jutsu", "\(jutsu)")
        }
        if let flip = card.supportFlipCost {
            return ("Support", "\(flip)")
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

    // MARK: Abilities

    /// Every ability box the card prints, in print order.
    ///
    /// The card's `effect` string is these same boxes run together with their
    /// keyword tags, so it is deliberately not printed a second time — that
    /// would set every rule on this screen twice, once broken down and once not.
    /// An imported pool may carry the string without the breakdown, and that
    /// case falls back to printing it whole and saying so.
    @ViewBuilder
    private func abilitySection(_ card: Card) -> some View {
        VStack(alignment: .leading, spacing: Metrics.spacingS) {
            Text("Abilities").sectionLabel()

            if !card.abilities.isEmpty {
                ForEach(Array(card.abilities.enumerated()), id: \.offset) { box in
                    AbilityPanel(ability: box.element)
                }
            } else if !card.effect.isEmpty {
                unbrokenRules(card.effect)
            } else {
                Text("This card has no printed ability.")
                    .font(Typeface.body(14))
                    .foregroundStyle(Palette.textSecondary)
            }
        }
    }

    /// An imported card can carry printed rules without the box breakdown the
    /// bundled pool has. The text is worth showing whole, marked as something
    /// the app reads and cannot act on rather than quietly dropped.
    private func unbrokenRules(_ text: String) -> some View {
        VStack(alignment: .leading, spacing: Metrics.spacingS) {
            Text(text)
                .font(Typeface.body(15))
                .foregroundStyle(Palette.textPrimary)
                .fixedSize(horizontal: false, vertical: true)

            Text("""
            These rules are not broken into steps the app can resolve, so none \
            of them are applied. Settle them between yourselves.
            """)
                .font(Typeface.body(13))
                .foregroundStyle(Palette.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(Metrics.spacingM)
        .notchedPanel(fill: Palette.panel, stroke: Palette.warning)
        .accessibilityElement(children: .combine)
    }

    // MARK: Support line

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
    /// summoning price. Summoning is free, and so is setting the card face-down
    /// as a Support; the printed cost is what its jutsu charges, and what
    /// flipping it face-up to answer charges.
    @ViewBuilder
    private func costPanel(_ card: Card) -> some View {
        switch card.type {
        case .leader, .chakra:
            EmptyView()

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
    ///
    /// A card printing "Cannot be summoned normally" is not free to summon — it
    /// cannot be summoned at all, and the engine refuses the play. Saying
    /// "Summon: free" there would be the one thing this panel exists to avoid.
    private func summonCostDescription(_ card: Card) -> String {
        var lines: [String] = []
        if card.cannotBeSummonedNormally {
            lines.append("""
            Summon: pay the Summon Requirements printed alongside. This card \
            never spends your one normal summon for the turn — the requirement \
            is the only door in.
            """)
        } else {
            lines.append("""
            Summon: free — but only once a turn. After it, every other card is \
            refused with "Summon already used this turn".
            """)
        }
        if card.canSetAsSupport {
            lines.append(supportCostDescription(card))
        }
        if let jutsu = card.jutsuCost {
            lines.append("As a jutsu: \(chakraPhrase(jutsu)), then it goes to the Trash.")
        }
        return lines.joined(separator: "\n\n")
    }

    /// Wording for the SUPPORT bar: setting is free, and the printed chakra is
    /// what turning the card face-up again to answer costs.
    private func supportCostDescription(_ card: Card) -> String {
        """
        Set as support: free. It lies face-down in one of your \
        \(GameRules.supportSlots) Support slots until you flip it to answer, \
        which costs \(chakraPhrase(card.supportFlipCost ?? 0)).
        """
    }

    /// "2 chakra", or "no chakra" when the play is free.
    private func chakraPhrase(_ amount: Int) -> String {
        amount == 0 ? "no chakra" : "\(amount) chakra"
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

// MARK: - Ability panel

/// One printed ability box.
///
/// The trigger and the once-per-turn tag lead, because between them they decide
/// when the box may be used at all. The printed text follows exactly as written.
/// The cost and the target are then stated in plain words, since a scope such as
/// "every character on the board" reaches both sides of the table and the
/// printed line rarely says so.
private struct AbilityPanel: View {
    let ability: CardAbility

    var body: some View {
        VStack(alignment: .leading, spacing: Metrics.spacingS) {
            tagRow
            printedText
            terms

            if !ability.isFullyImplemented {
                rule
                unappliedNote
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(Metrics.spacingM)
        .notchedPanel(fill: fill, stroke: stroke)
        .accessibilityElement(children: .combine)
    }

    // MARK: Tags

    private var tagRow: some View {
        HStack(spacing: Metrics.spacingXS) {
            StaticChip(title: triggerTitle, tint: Palette.accent)
            if ability.oncePerTurn {
                StaticChip(title: "Once per turn")
            }
            Spacer(minLength: 0)
        }
    }

    /// `.passive` prints no keyword tag on the card at all, so the panel names
    /// the box for what the model says it is rather than showing an empty chip.
    private var triggerTitle: String {
        ability.trigger.title.isEmpty ? "Standing rule" : ability.trigger.title
    }

    // MARK: Printed text

    private var printedText: some View {
        Text(ability.text)
            .font(Typeface.body(15))
            .foregroundStyle(Palette.textPrimary)
            .fixedSize(horizontal: false, vertical: true)
    }

    // MARK: Terms

    /// What the box charges and what it reaches. A free box with no target
    /// prints neither line rather than two ways of saying "nothing".
    @ViewBuilder
    private var terms: some View {
        if !ability.cost.isFree || targetDescription != nil {
            VStack(alignment: .leading, spacing: Metrics.spacingXS) {
                if !ability.cost.isFree {
                    term("Cost", ability.cost.summary)
                }
                if let target = targetDescription {
                    term("Targets", target)
                }
            }
        }
    }

    private func term(_ label: String, _ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: Metrics.spacingS) {
            Text(label)
                .font(Typeface.label(10))
                .tracking(1.2)
                .textCase(.uppercase)
                .foregroundStyle(Palette.textSecondary)
                .frame(minWidth: 52, alignment: .leading)

            Text(text)
                .font(Typeface.body(13))
                .foregroundStyle(Palette.textSecondary)
                .fixedSize(horizontal: false, vertical: true)

            Spacer(minLength: 0)
        }
    }

    /// What the scope acts on, in words.
    ///
    /// The scopes that ask the player to pick already carry the question they
    /// ask, so those print their own prompt. The scopes that resolve themselves
    /// carry no wording, and are described here by what the resolver actually
    /// reaches — `.allCharacters` in particular means the whole board, not your
    /// half of it.
    private var targetDescription: String? {
        switch ability.target {
        case .none:
            return nil
        case .selfCard:
            return "This card"
        case .ownTeam:
            return "Your own characters"
        case .allCharacters:
            return "Every character on the board, both sides"
        case .anyCharacter, .friendlyCharacter, .opposingCharacter,
             .restedCharacter, .leaderOrCharacter:
            return ability.target.prompt
        }
    }

    // MARK: Unapplied steps

    /// A hairline, so the app's own note about itself is never mistaken for
    /// something printed on the card.
    private var rule: some View {
        Rectangle()
            .fill(Palette.border)
            .frame(height: 1)
            .padding(.vertical, Metrics.spacingXS)
    }

    /// Marked plainly rather than politely. The card is shown in full either
    /// way; what changes is whether the player knows the board will not do it.
    private var unappliedNote: some View {
        VStack(alignment: .leading, spacing: Metrics.spacingXS) {
            HStack(spacing: Metrics.spacingXS) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 11, weight: .bold))
                Text("Shown, not applied in full")
                    .font(Typeface.label(11))
                    .tracking(1.2)
                    .textCase(.uppercase)
            }
            .foregroundStyle(Palette.warning)

            Text(unappliedExplanation)
                .font(Typeface.body(13))
                .foregroundStyle(Palette.textSecondary)
                .fixedSize(horizontal: false, vertical: true)

            ForEach(Array(unappliedSteps.enumerated()), id: \.offset) { step in
                Text("— \(step.element)")
                    .font(Typeface.body(13))
                    .foregroundStyle(Palette.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// The printed steps the engine displays and does not resolve, in the words
    /// the card data carries them in.
    private var unappliedSteps: [String] {
        ability.effects.compactMap { effect in
            guard case .unimplemented(let text) = effect else { return nil }
            return text
        }
    }

    private var unappliedExplanation: String {
        if ability.effects.isEmpty {
            return """
            The app carries this box as printed but has no steps for it, so \
            none of it is applied. Settle it between yourselves.
            """
        }
        if unappliedSteps.count == ability.effects.count {
            return """
            The app displays this rule and applies none of it. Settle it \
            between yourselves.
            """
        }
        let isSingle = unappliedSteps.count == 1
        return """
        The app applies the rest of this box, but not the \
        step\(isSingle ? "" : "s") below. Settle \(isSingle ? "it" : "them") \
        between yourselves.
        """
    }

    // MARK: Trim

    private var fill: Color {
        ability.isActivated ? Palette.panelActive : Palette.panel
    }

    /// Outlined in the warning colour whenever a step is not applied, so the
    /// panel is marked before a word of it has been read. Otherwise the accent
    /// marks the boxes the player can actually press a button for.
    private var stroke: Color {
        if !ability.isFullyImplemented { return Palette.warning }
        return ability.isActivated ? Palette.accent : Palette.border
    }
}

// MARK: - Static chip

/// A chip that only reports — the read-only twin of `FilterChip`, used for
/// trait lines and ability tags, which must not look tappable.
private struct StaticChip: View {
    let title: String

    /// Colours the lettering and the outline. The default is the quiet
    /// treatment a trait gets; an ability's trigger takes the accent so that it
    /// leads its panel.
    var tint: Color? = nil

    var body: some View {
        Text(title)
            .font(Typeface.label(11))
            .tracking(1.2)
            .textCase(.uppercase)
            .foregroundStyle(tint ?? Palette.textSecondary)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .notchedPanel(notch: 6, corners: .diagonal,
                          fill: Palette.panel, stroke: tint ?? Palette.border)
    }
}

// MARK: - Previews

#Preview("Leader, two ability boxes") {
    NavigationStack {
        CardDetailView(cardID: "N-001")
    }
    .environment(CardDatabase())
    .environment(Router())
}

#Preview("Every box a card can print") {
    NavigationStack {
        CardDetailView(cardID: "N-014")
    }
    .environment(CardDatabase())
    .environment(Router())
}

#Preview("Character with a Support line") {
    NavigationStack {
        CardDetailView(cardID: "K-039")
    }
    .environment(CardDatabase())
    .environment(Router())
}

#Preview("No printed ability") {
    NavigationStack {
        CardDetailView(cardID: "SMP-05")
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
