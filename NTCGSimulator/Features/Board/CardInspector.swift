//
//  CardInspector.swift
//  NTCGSimulator
//
//  The card reader, the contextual controls beneath it, and the picker that
//  offers a card's printed ability boxes.
//
//  The simulator this follows invites you to "hover a card to read it in full";
//  on a touch screen focus arrives from a tap or a long press instead, so the
//  same panel doubles as the board's action bar.
//
//  Abilities are read here as well as used here. A card prints several boxes,
//  each with its own trigger and its own price, and some of them the app can
//  only display rather than resolve. So every box names the moment it answers
//  to, names what it charges before anything is committed, and says plainly
//  when the app will not apply all of it — being quietly wrong is the failure
//  this screen exists to prevent.
//

import SwiftUI

// MARK: - Contextual action

/// One button in the inspector's action stack.
///
/// The board decides what is offered — mulligan answers, phase controls, a block
/// response — and hands the buttons over already wired, so the inspector never
/// needs to know the rules.
struct BoardAction: Identifiable {

    /// Stable across rebuilds of the same offer, so SwiftUI keeps the button.
    let id: String

    let title: String

    /// Used on a phone, where three buttons share one row and a full title —
    /// a Leader ability reads "Give a character +2 power" — will not fit.
    var shortTitle: String? = nil

    var style: WideButton.Style = .secondary
    var isEnabled: Bool = true
    let perform: () -> Void
}

// MARK: - Ability wording

extension CardAbility {

    /// "Activate: Main — 1 chakra": the moment the box answers to and what it
    /// charges. Together they are everything a player needs before pressing
    /// anything, which is why they are one line rather than two.
    var activationHeadline: String {
        let moment = trigger.title.isEmpty ? "Passive" : trigger.title
        return cost.isFree ? moment : "\(moment) — \(cost.summary)"
    }

    /// Whether the box asks the player to give cards up out of hand.
    ///
    /// `GameAction` carries a target on the board but no choice from hand, so
    /// the board nominates the card lifted out of the hand strip instead. That
    /// is worth saying out loud on the button: a step that quietly picks for
    /// you is exactly what this screen is meant to avoid.
    var takesCardsFromHand: Bool {
        effects.contains {
            if case .placeFromHandOnDeck = $0 { return true }
            return false
        }
    }
}

// MARK: - Ability offer

/// One printed ability box, offered to the player for activation.
///
/// The board fills these in from the engine's own answers — `legalAbilities`
/// for the targets, `planAbility` for the refusal — so the picker can never
/// present an activation the engine would then turn down, and never withholds
/// one without being able to say why.
struct AbilityOffer: Identifiable {

    /// The card the box is printed on.
    let source: AbilitySource

    /// Position in the card's printed order, which is what `GameAction` carries.
    let index: Int

    let ability: CardAbility

    /// Board identities this box may legally be pointed at. Empty when its
    /// scope asks the player for nothing — and also when nothing legal is on
    /// the board, which `refusal` is what distinguishes.
    let targets: Set<UUID>

    /// Why the box cannot be used right now, in the engine's own words.
    /// `nil` when it can.
    let refusal: String?

    var id: String { "\(source.key)-\(index)" }

    var isEnabled: Bool { refusal == nil }
}

/// Every activated box on one card in play, with the standing rules it is under.
struct AbilityGroup: Identifiable {

    let source: AbilitySource
    let card: Card
    let offers: [AbilityOffer]

    /// Passive and "Your Turn" boxes: always in force, never pressed. Shown so
    /// a player can see the rules governing a card without leaving the board.
    let standingRules: [CardAbility]

    var id: String { source.key }
}

// MARK: - Ability box

/// One printed ability box as the player reads it: the trigger and the price on
/// a headline, the text exactly as printed underneath, and a plain warning when
/// the app will show the box without resolving all of it.
struct AbilityBoxView: View {

    let ability: CardAbility

    /// Lights the panel for a box that can be pressed right now. A box being
    /// read rather than offered stays quiet, so the two never look alike.
    var isOffered: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: Metrics.spacingXS) {
            headline

            Text(ability.text)
                .font(Typeface.body(12))
                .foregroundStyle(Palette.textPrimary)
                .fixedSize(horizontal: false, vertical: true)

            if !ability.isFullyImplemented {
                partialNote
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(Metrics.spacingS)
        .notchedPanel(
            notch: 8,
            fill: isOffered ? Palette.panelActive : Palette.surface.opacity(0.6),
            stroke: isOffered ? Palette.accent : Palette.border
        )
    }

    private var headline: some View {
        HStack(alignment: .firstTextBaseline, spacing: Metrics.spacingXS) {
            Text(ability.activationHeadline)
                .font(Typeface.label(10))
                .tracking(1)
                .textCase(.uppercase)
                .foregroundStyle(isOffered ? Palette.accent : Palette.textSecondary)
                .fixedSize(horizontal: false, vertical: true)

            if ability.oncePerTurn {
                tag("Once per turn", tint: Palette.textSecondary)
            }

            Spacer(minLength: 0)
        }
    }

    /// The honest line. A box the engine cannot resolve in full is still
    /// printed on the card, so it is still shown — and marked, because a player
    /// who is not told what the app skipped cannot settle it themselves.
    private var partialNote: some View {
        HStack(alignment: .top, spacing: 4) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(Typeface.label(9))
            Text("The app shows this box but does not apply every step. Settle the rest between yourselves.")
                .font(Typeface.body(11))
                .fixedSize(horizontal: false, vertical: true)
        }
        .foregroundStyle(Palette.warning)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func tag(_ text: String, tint: Color) -> some View {
        Text(text)
            .font(Typeface.label(8))
            .tracking(0.8)
            .textCase(.uppercase)
            .foregroundStyle(tint)
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
            .background(Capsule().stroke(tint.opacity(0.6), lineWidth: 0.75))
            .fixedSize()
    }
}

// MARK: - Ability picker

/// The sheet that offers the printed ability boxes on the cards a player holds.
///
/// Every box shows its price before it can be pressed, and a box that cannot be
/// paid for is disabled with the engine's own reason under it. A control that
/// refuses silently is worse than one that is not offered at all.
struct AbilitySheet: View {

    /// Named by the board: one card, or everything the player controls.
    let title: String

    let groups: [AbilityGroup]

    /// A box the player pressed. The board decides whether it resolves at once
    /// or arms the mat for a target.
    let onChoose: (AbilityOffer) -> Void

    let onDismiss: () -> Void

    var body: some View {
        ZStack {
            AmbientBackground()

            VStack(alignment: .leading, spacing: Metrics.spacingM) {
                Text(title).screenTitle()

                if groups.isEmpty {
                    EmptyStatePanel(
                        headline: "Nothing to activate",
                        message: "None of the cards you control prints an ability you can use right now."
                    )
                    Spacer(minLength: 0)
                } else {
                    ScrollView {
                        VStack(alignment: .leading, spacing: Metrics.spacingM) {
                            ForEach(groups) { group in
                                section(group)
                            }
                        }
                        .padding(.bottom, Metrics.spacingS)
                    }
                    .scrollIndicators(.hidden)
                }

                WideButton(title: "Close", style: .primary, action: onDismiss)
            }
            .padding(Metrics.spacingL)
        }
    }

    // MARK: One card

    private func section(_ group: AbilityGroup) -> some View {
        VStack(alignment: .leading, spacing: Metrics.spacingS) {
            header(group)

            ForEach(group.offers) { offer in
                offerRow(offer)
            }

            if !group.standingRules.isEmpty {
                standingRules(group.standingRules)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(Metrics.spacingM)
        .notchedPanel(fill: Palette.panel.opacity(0.94), stroke: Palette.border)
    }

    private func header(_ group: AbilityGroup) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: Metrics.spacingS) {
            Text(group.card.name)
                .font(Typeface.display(15, weight: .bold))
                .foregroundStyle(Palette.textPrimary)
                .fixedSize(horizontal: false, vertical: true)

            Text(group.source.title)
                .font(Typeface.label(9))
                .tracking(1.2)
                .textCase(.uppercase)
                .foregroundStyle(Palette.accent)

            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .combine)
    }

    /// One box, pressable when the engine would accept it. The refusal sits
    /// under the box rather than replacing it, so a player can still read what
    /// they are being kept from.
    private func offerRow(_ offer: AbilityOffer) -> some View {
        Button {
            onChoose(offer)
        } label: {
            VStack(alignment: .leading, spacing: Metrics.spacingXS) {
                AbilityBoxView(ability: offer.ability, isOffered: offer.isEnabled)

                if let refusal = offer.refusal {
                    footnote(refusal, tint: Palette.negative)
                } else if offer.ability.target.needsPlayerChoice {
                    footnote("\(offer.ability.target.prompt) on the board next.",
                             tint: Palette.textSecondary)
                }

                if offer.ability.takesCardsFromHand {
                    footnote(
                        "The card lifted out of your hand goes back on the deck. Lift one before using this, or the newest card goes.",
                        tint: Palette.textSecondary
                    )
                }
            }
        }
        .buttonStyle(.plain)
        .disabled(!offer.isEnabled)
        .opacity(offer.isEnabled ? 1 : 0.55)
        .accessibilityElement(children: .ignore)
        .accessibilityAddTraits(.isButton)
        .accessibilityLabel(description(of: offer))
    }

    private func standingRules(_ rules: [CardAbility]) -> some View {
        VStack(alignment: .leading, spacing: Metrics.spacingXS) {
            Text("Always in force").sectionLabel()

            ForEach(Array(rules.enumerated()), id: \.offset) { entry in
                AbilityBoxView(ability: entry.element)
            }
        }
    }

    private func footnote(_ text: String, tint: Color) -> some View {
        Text(text)
            .font(Typeface.body(11))
            .foregroundStyle(tint)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, Metrics.spacingXS)
    }

    private func description(of offer: AbilityOffer) -> String {
        var parts = [offer.ability.activationHeadline, offer.ability.text]
        if offer.ability.oncePerTurn { parts.append("once per turn") }
        if !offer.ability.isFullyImplemented {
            parts.append("the app does not apply every step of this box")
        }
        parts.append(offer.refusal ?? "available")
        return parts.joined(separator: ", ")
    }
}

// MARK: - Inspector

/// Reads one card in full and offers whatever the board can do right now.
struct CardInspector: View {

    /// The focused card. `nil` shows the reader's resting prompt.
    let card: Card?

    /// Compact folds the rail into a bottom bar with icon-only chrome.
    let isCompact: Bool

    let actions: [BoardAction]

    /// Bound straight to `SettingsStore.soundEnabled`.
    @Binding var soundEnabled: Bool

    /// Confirmed by the board before it pops back to the menu.
    let onLeave: () -> Void

    /// Height the board reserves for the compact bottom bar.
    static let compactHeight: CGFloat = 146

    /// Width of the card thumbnail in the compact bar. Small enough to leave the
    /// effect text room, large enough to recognise the art.
    private let compactFaceWidth: CGFloat = 46

    /// Buttons that fit side by side on a phone before they stop being readable.
    private let compactActionLimit = 3

    /// Floor the rules text keeps on the rail.
    ///
    /// A card's ability boxes are long — several of them, each with its printed
    /// text — so the reader takes whatever the rail has spare above the action
    /// stack and scrolls the rest. This is only the height it refuses to give
    /// up, so the controls can never be pushed off the bottom.
    private let minimumDetailHeight: CGFloat = 150

    var body: some View {
        if isCompact { compactBar } else { rail }
    }

    // MARK: Regular rail

    private var rail: some View {
        VStack(alignment: .leading, spacing: Metrics.spacingM) {
            Text("Card reader").sectionLabel()

            face

            details

            VStack(spacing: Metrics.spacingS) {
                ForEach(actions) { action in
                    WideButton(title: action.title, style: action.style, isEnabled: action.isEnabled) {
                        action.perform()
                    }
                }
            }

            soundRow

            WideButton(title: "Leave the game", style: .destructive, action: onLeave)
        }
        .padding(Metrics.spacingM)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .notchedPanel(fill: Palette.panel.opacity(0.94), stroke: Palette.border)
    }

    @ViewBuilder
    private var face: some View {
        if let card {
            CardFaceView(card: card, size: .large)
                .frame(maxWidth: .infinity)
        } else {
            restingPrompt
        }
    }

    /// The reader's empty state, phrased as the original simulator phrases it.
    private var restingPrompt: some View {
        VStack(spacing: Metrics.spacingS) {
            Image(systemName: "rectangle.on.rectangle.angled")
                .font(Typeface.display(24, weight: .regular))
                .foregroundStyle(Palette.accentMuted)

            Text("Hover a card to read it in full")
                .font(Typeface.body(13))
                .foregroundStyle(Palette.textSecondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, Metrics.spacingL)
        .notchedPanel(fill: Palette.surface.opacity(0.6), stroke: Palette.border)
    }

    @ViewBuilder
    private var details: some View {
        if let card {
            ScrollView {
                VStack(alignment: .leading, spacing: Metrics.spacingS) {
                    Text(card.name)
                        .font(Typeface.display(17, weight: .bold))
                        .foregroundStyle(Palette.textPrimary)
                        .fixedSize(horizontal: false, vertical: true)

                    Text("\(card.type.title) · \(card.color.title) · \(card.id)")
                        .font(Typeface.label(10))
                        .tracking(1)
                        .textCase(.uppercase)
                        .foregroundStyle(Palette.accent)

                    if let price = playCostText(for: card) {
                        Text(price)
                            .font(Typeface.label(10))
                            .tracking(1)
                            .textCase(.uppercase)
                            .foregroundStyle(Palette.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    // The printed blob and the ability boxes are the same words
                    // twice — the boxes are that text broken up — so only the
                    // boxes are shown wherever a card has them.
                    if card.abilities.isEmpty, !card.effect.isEmpty {
                        Text(card.effect)
                            .font(Typeface.body(13))
                            .foregroundStyle(Palette.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    if !card.abilities.isEmpty {
                        abilityPanel(card)
                    }

                    if let support = card.supportText, !support.isEmpty {
                        supportLine(support)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .scrollIndicators(.hidden)
            .frame(minHeight: minimumDetailHeight, maxHeight: .infinity)
        } else {
            // Nothing to read: the space still belongs to the reader, so the
            // action stack stays where it was rather than jumping up the rail.
            Spacer(minLength: 0)
        }
    }

    private func supportLine(_ text: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("Support").sectionLabel()
            Text(text)
                .font(Typeface.body(13))
                .foregroundStyle(Palette.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(Metrics.spacingS)
        .notchedPanel(notch: 8, fill: Palette.panelActive, stroke: Palette.accentMuted)
    }

    /// Every box printed on the focused card, in printed order.
    ///
    /// This replaces a single invented "Leader ability" line. Real cards print
    /// several boxes, characters carry them as often as Leaders do, and some of
    /// them the app can only display — so each box says which of those it is
    /// rather than leaving the player to find out mid-game.
    private func abilityPanel(_ card: Card) -> some View {
        VStack(alignment: .leading, spacing: Metrics.spacingXS) {
            Text(card.abilities.count == 1 ? "Ability" : "Abilities").sectionLabel()

            ForEach(Array(card.abilities.enumerated()), id: \.offset) { entry in
                AbilityBoxView(ability: entry.element)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: Cost

    /// What the card charges to put into play.
    ///
    /// Summoning is free, so a body's printed number is never presented as a
    /// price. It is only ever the cost of a Support card or of a jutsu play.
    private func playCostText(for card: Card) -> String? {
        switch card.type {
        case .leader, .chakra:
            return nil
        case .support:
            return "Play · \(chakraPhrase(card.cost ?? 0))"
        case .summon:
            return "Place · free"
        case .character, .exCharacter:
            guard let jutsu = card.jutsuCost else { return "Summon · free" }
            // Two prices, one per line — a middot between them would read as a
            // single price with two halves.
            return "Summon · free\nJutsu · \(chakraPhrase(jutsu))"
        }
    }

    /// The same line, condensed for the compact bar's one-line stat readout.
    private func statLine(for card: Card) -> String {
        var parts: [String] = []
        if card.type.costsChakraToPlay, let cost = card.cost {
            parts.append("\(cost) chakra")
        } else if let jutsu = card.jutsuCost {
            parts.append("jutsu \(jutsu)")
        }
        if let power  = card.power  { parts.append("\(power) power") }
        if let damage = card.damage { parts.append("\(damage) damage") }
        if let health = card.health { parts.append("\(health) health") }
        if let life   = card.life   { parts.append("\(life) life") }
        return parts.isEmpty ? card.id : parts.joined(separator: " · ")
    }

    /// "1 chakra" rather than "1 chakras", and "free" rather than "0 chakra".
    private func chakraPhrase(_ amount: Int) -> String {
        amount == 0 ? "free" : "\(amount) chakra"
    }

    /// A labelled row rather than an icon, because the rail has the width for it
    /// and a labelled toggle is the clearer control.
    private var soundRow: some View {
        Toggle(isOn: $soundEnabled) {
            Text("Sound")
                .font(Typeface.label(11))
                .tracking(1.2)
                .textCase(.uppercase)
                .foregroundStyle(Palette.textPrimary)
        }
        .tint(Palette.accent)
        .padding(.horizontal, Metrics.spacingS)
        .frame(minHeight: 44)
    }

    // MARK: Compact bar

    private var compactBar: some View {
        VStack(spacing: Metrics.spacingS) {
            HStack(spacing: Metrics.spacingM) {
                compactFace
                compactSummary
                Spacer(minLength: 0)
                soundButton
                leaveButton
            }

            compactActions
        }
        .padding(Metrics.spacingS)
        .frame(height: Self.compactHeight)
        .notchedPanel(fill: Palette.panel.opacity(0.94), stroke: Palette.border)
    }

    @ViewBuilder
    private var compactFace: some View {
        if let card {
            BoardCardFace(card: card, size: .small, width: compactFaceWidth)
        } else {
            CardBackView(tint: Palette.accentMuted)
                .frame(width: compactFaceWidth)
                .accessibilityLabel("No card is being read")
        }
    }

    private var compactSummary: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 4) {
                Text(card?.name ?? "Hover a card to read it in full")
                    .font(Typeface.display(13, weight: .bold))
                    .foregroundStyle(Palette.textPrimary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)

                // Two lines of rules text cannot carry the caveat, so the bar
                // carries it as a mark: this card prints something the app
                // will show and not fully apply.
                if card?.hasUnimplementedRules == true {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(Typeface.label(10))
                        .foregroundStyle(Palette.warning)
                        .accessibilityLabel("prints rules the app does not fully apply")
                }
            }

            if let card {
                Text("\(card.type.title) · \(statLine(for: card))")
                    .font(Typeface.label(9))
                    .tracking(1)
                    .textCase(.uppercase)
                    .foregroundStyle(Palette.accent)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)

                Text(compactRulesText(for: card))
                    .font(Typeface.body(11))
                    .foregroundStyle(Palette.textSecondary)
                    .lineLimit(2)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }

    /// The two lines the compact bar has room for. An activated box wins over
    /// the rest of the card, because it is the part that can be pressed; a card
    /// with none falls back to its first printed box, then to its effect text.
    private func compactRulesText(for card: Card) -> String {
        if let ability = card.activatedAbilities.first {
            return "\(ability.activationHeadline). \(ability.text)"
        }
        if let ability = card.abilities.first {
            return "\(ability.activationHeadline). \(ability.text)"
        }
        if !card.effect.isEmpty { return card.effect }
        return card.supportText ?? "No rules text."
    }

    /// Keeps a fixed-height row even with nothing to offer, so the board above
    /// never shifts when the turn passes.
    @ViewBuilder
    private var compactActions: some View {
        if actions.isEmpty {
            Text("Waiting for the other side.")
                .font(Typeface.body(12))
                .foregroundStyle(Palette.textSecondary)
                .frame(maxWidth: .infinity, minHeight: Metrics.controlHeight)
        } else {
            HStack(spacing: Metrics.spacingS) {
                ForEach(Array(actions.prefix(compactActionLimit))) { action in
                    WideButton(
                        title: action.shortTitle ?? action.title,
                        style: action.style,
                        isEnabled: action.isEnabled
                    ) {
                        action.perform()
                    }
                }
            }
        }
    }

    private var soundButton: some View {
        Button {
            soundEnabled.toggle()
        } label: {
            Image(systemName: soundEnabled ? "speaker.wave.2.fill" : "speaker.slash.fill")
                .font(Typeface.label(14))
                .foregroundStyle(soundEnabled ? Palette.accent : Palette.textSecondary)
                .frame(width: 44, height: 44)
                .notchedPanel(notch: 6, corners: .diagonal, fill: Palette.surface, stroke: Palette.border)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(soundEnabled ? "Sound is on" : "Sound is off")
        .accessibilityAddTraits(soundEnabled ? [.isSelected] : [])
    }

    private var leaveButton: some View {
        Button(action: onLeave) {
            Image(systemName: "rectangle.portrait.and.arrow.right")
                .font(Typeface.label(14))
                .foregroundStyle(Palette.negative)
                .frame(width: 44, height: 44)
                .notchedPanel(notch: 6, corners: .diagonal, fill: Palette.surface, stroke: Palette.border)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Leave the game")
    }
}

// MARK: - Preview support

/// Two cards from the pool dressed as an offer list, so the picker preview does
/// not need a running game behind it. The second card is refused, because a
/// disabled row with its reason under it is the case worth looking at.
private func previewAbilityGroups(_ database: CardDatabase) -> [AbilityGroup] {
    let cards = database.cards.filter { !$0.activatedAbilities.isEmpty }.prefix(2)

    return cards.enumerated().map { position, card in
        let source: AbilitySource = position == 0 ? .leader : .character(UUID())
        let offers = card.abilities.indices
            .filter { card.abilities[$0].isActivated }
            .map { index in
                AbilityOffer(
                    source: source,
                    index: index,
                    ability: card.abilities[index],
                    targets: [],
                    refusal: position == 0 ? nil : "That costs 2 chakra and you have 1 ready."
                )
            }

        return AbilityGroup(
            source: source,
            card: card,
            offers: offers,
            standingRules: card.abilities.filter { $0.trigger == .passive }
        )
    }
}

// MARK: - Previews

#Preview("Rail") {
    let database = CardDatabase()

    CardInspector(
        card: database.cards.first { $0.hasSupportLine } ?? database.cards.first,
        isCompact: false,
        actions: [
            BoardAction(id: "phase", title: "End phase", style: .primary) {},
            BoardAction(id: "turn", title: "End turn") {}
        ],
        soundEnabled: .constant(true),
        onLeave: {}
    )
    .frame(width: 300, height: 720)
    .padding()
    .background(Palette.backdrop)
    .environment(database)
}

#Preview("Reading a card with abilities") {
    let database = CardDatabase()

    CardInspector(
        card: database.cards.first { !$0.activatedAbilities.isEmpty } ?? database.cards.first,
        isCompact: false,
        actions: [
            BoardAction(id: "phase", title: "End phase", style: .primary) {},
            BoardAction(id: "ability", title: "Use an ability", shortTitle: "Abilities") {},
            BoardAction(id: "turn", title: "End turn") {}
        ],
        soundEnabled: .constant(true),
        onLeave: {}
    )
    .frame(width: 300, height: 720)
    .padding()
    .background(Palette.backdrop)
    .environment(database)
}

#Preview("Ability picker") {
    let database = CardDatabase()

    AbilitySheet(
        title: "Abilities",
        groups: previewAbilityGroups(database),
        onChoose: { _ in },
        onDismiss: {}
    )
    .environment(database)
}

#Preview("Compact bar") {
    let database = CardDatabase()

    CardInspector(
        card: database.cards.first { $0.type == .support } ?? database.cards.first,
        isCompact: true,
        actions: [
            BoardAction(id: "keep", title: "Keep this hand", style: .primary) {},
            BoardAction(id: "mull", title: "Mulligan") {}
        ],
        soundEnabled: .constant(false),
        onLeave: {}
    )
    .frame(width: 377)
    .padding()
    .background(Palette.backdrop)
    .environment(database)
}
