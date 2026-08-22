//
//  CardInspector.swift
//  NTCGSimulator
//
//  The card reader, the contextual controls beneath it, and the offer sheet a
//  tap on a card in play opens.
//
//  The simulator this follows invites you to "hover a card to read it in full";
//  on a touch screen focus arrives from a tap or a long press instead, so the
//  same panel doubles as the board's action bar.
//
//  Offers are read here as well as used here. A Leader holds up to three at
//  once — its attack, its Activate: Main and its Recovery — and a body may
//  hold an attack beside a printed ability. Every offer names the moment it
//  answers to, names what it charges before anything is committed, and where
//  it is refused prints the engine's own reason: "Wrong moment", "That card is
//  rested", "That card cannot attack right now". A control that refuses
//  silently teaches nothing, and silent rules are the failure this screen
//  exists to prevent.
//

import SwiftUI

// MARK: - Contextual action

/// One button in the inspector's action stack.
///
/// The board decides what is offered — mulligan answers, END TURN, Recovery,
/// a cancel — and hands the buttons over already wired, so the inspector never
/// needs to know the rules.
struct BoardAction: Identifiable {

    /// Stable across rebuilds of the same offer, so SwiftUI keeps the button.
    let id: String

    let title: String

    /// Used on a phone, where three buttons share one row and a full title
    /// will not fit.
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
}

// MARK: - Board offer

/// One thing a card in play offers the acting player right now: an attack,
/// an Activate: Main, or Recovery.
///
/// The board fills these in from the engine's own validators — `attackBlock`,
/// `characterAbilityBlock`, `leaderEffectBlock`, `recoveryBlock` — so the
/// sheet can never present a press the engine would then turn down, and never
/// withholds one without being able to say why.
struct BoardOffer: Identifiable {

    let id: String

    /// The moment and the price on one line — "Attack — rests the Leader",
    /// "Activate: Main — 1 chakra".
    let headline: String

    /// What pressing it does, in the card's own printed words where it has
    /// them.
    let text: String

    /// Why the offer cannot be taken right now, in the engine's own words.
    /// `nil` when it can.
    let refusal: String?

    /// Wired by the board. Only ever called while `refusal` is nil.
    let perform: () -> Void

    var isEnabled: Bool { refusal == nil }
}

// MARK: - Ability box

/// One printed ability box as the player reads it: the trigger and the price
/// on a headline, the text exactly as printed underneath, and a plain warning
/// when the app will show the box without resolving all of it.
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
    /// printed on the card, so it is still shown — and marked, because a
    /// player who is not told what the app skipped cannot settle it
    /// themselves.
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

// MARK: - Offer sheet

/// The sheet that offers what one card in play can do right now.
///
/// Every offer shows its price before it can be pressed, and one that cannot
/// be taken is disabled with the engine's own reason under it — which is how
/// a Leader's frozen, rested and already-attacked states are made visible
/// rather than discovered through a dead tap.
struct OfferSheet: View {

    /// The card's name, put there by the board.
    let title: String

    let offers: [BoardOffer]

    /// A chosen offer closes the sheet before it performs; the board owns
    /// what happens next.
    let onChoose: (BoardOffer) -> Void

    let onDismiss: () -> Void

    var body: some View {
        ZStack {
            AmbientBackground()

            VStack(alignment: .leading, spacing: Metrics.spacingM) {
                Text(title).screenTitle()

                if offers.isEmpty {
                    EmptyStatePanel(
                        headline: "Nothing to do",
                        message: "This card offers nothing the rules allow right now."
                    )
                    Spacer(minLength: 0)
                } else {
                    ScrollView {
                        VStack(alignment: .leading, spacing: Metrics.spacingS) {
                            ForEach(offers) { offer in
                                row(offer)
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

    /// One offer, pressable when the engine would accept it. The refusal sits
    /// under the words rather than replacing them, so a player can still read
    /// what they are being kept from.
    private func row(_ offer: BoardOffer) -> some View {
        Button {
            onChoose(offer)
        } label: {
            VStack(alignment: .leading, spacing: Metrics.spacingXS) {
                HStack(alignment: .firstTextBaseline, spacing: Metrics.spacingS) {
                    Text(offer.headline)
                        .font(Typeface.label(12))
                        .tracking(1.2)
                        .textCase(.uppercase)
                        .foregroundStyle(offer.isEnabled ? Palette.accent : Palette.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                }

                Text(offer.text)
                    .font(Typeface.body(12))
                    .foregroundStyle(Palette.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)

                if let refusal = offer.refusal {
                    Text(refusal)
                        .font(Typeface.body(11))
                        .foregroundStyle(Palette.negative)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(Metrics.spacingM)
            .notchedPanel(
                notch: 8,
                fill: offer.isEnabled ? Palette.panelActive : Palette.surface.opacity(0.6),
                stroke: offer.isEnabled ? Palette.accent : Palette.border
            )
        }
        .buttonStyle(.plain)
        .disabled(!offer.isEnabled)
        .opacity(offer.isEnabled ? 1 : 0.55)
        .accessibilityElement(children: .ignore)
        .accessibilityAddTraits(.isButton)
        .accessibilityLabel(spoken(offer))
    }

    private func spoken(_ offer: BoardOffer) -> String {
        var parts = [offer.headline, offer.text]
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

    /// Width of the card thumbnail in the compact bar. Small enough to leave
    /// the effect text room, large enough to recognise the art.
    private let compactFaceWidth: CGFloat = 46

    /// Buttons that fit side by side on a phone before they stop being
    /// readable.
    private let compactActionLimit = 3

    /// Floor the rules text keeps on the rail.
    ///
    /// A card's ability boxes are long — several of them, each with its
    /// printed text — so the reader takes whatever the rail has spare above
    /// the action stack and scrolls the rest. This is only the height it
    /// refuses to give up, so the controls can never be pushed off the bottom.
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

                    // The printed blob and the ability boxes are the same
                    // words twice — the boxes are that text broken up — so
                    // only the boxes are shown wherever a card has them.
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

    /// Every box printed on the focused card, in printed order. Characters
    /// carry them as often as Leaders do, and some the app can only display —
    /// so each box says which of those it is rather than leaving the player
    /// to find out mid-game.
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

    /// What each of the card's three modes charges.
    ///
    /// Summoning is free and so is setting a card face-down, so a body's
    /// printed number is never presented as a price to put it on the board.
    /// It is the price of its jutsu, and the chakra on its SUPPORT bar.
    private func playCostText(for card: Card) -> String? {
        switch card.type {
        case .leader, .chakra:
            return nil
        case .summon:
            return "Place · free"
        case .character, .exCharacter:
            // One price per line — a middot between them would read as a
            // single price with several halves.
            var lines = ["Summon · free"]
            if card.canSetAsSupport {
                lines.append("Set as support · free")
                lines.append("Activate to answer · \(chakraPhrase(card.supportFlipCost ?? 0))")
            }
            if let jutsu = card.jutsuCost {
                lines.append("Jutsu · \(chakraPhrase(jutsu))")
            }
            return lines.joined(separator: "\n")
        }
    }

    /// The same line, condensed for the compact bar's one-line stat readout.
    private func statLine(for card: Card) -> String {
        var parts: [String] = []
        if let jutsu = card.jutsuCost {
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

    /// A labelled row rather than an icon, because the rail has the width for
    /// it and a labelled toggle is the clearer control.
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
    /// the rest of the card, because it is the part that can be pressed; a
    /// card with none falls back to its first printed box, then to its effect
    /// text.
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

    /// Keeps a fixed-height row even with nothing to offer, so the board
    /// above never shifts when the turn passes.
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

/// A Leader's three offers dressed by hand, so the sheet preview does not
/// need a running game behind it. The refused rows carry the engine's own
/// words — `GameError` quotes the reference's block codes — because a
/// disabled row with its reason under it is the case worth looking at.
private func previewLeaderOffers() -> [BoardOffer] {
    [
        BoardOffer(
            id: "attack",
            headline: "Attack — rests the Leader",
            text: "Declare an attack at the enemy Leader or a rested enemy character. Once per turn.",
            refusal: nil,
            perform: {}
        ),
        BoardOffer(
            id: "activate",
            headline: "Activate: Main — 1 chakra",
            text: "Flip 1 of your CHAKRA face-down and choose 1 Character: The chosen card gets +3 power during this turn.",
            refusal: GameError.noChakra(required: 1, available: 0).message,
            perform: {}
        ),
        BoardOffer(
            id: "recovery",
            headline: "Recovery — rests the Leader",
            text: "If it is the second turn or later, rest this card and flip all of your CHAKRA face-up.",
            refusal: GameError.rested.message,
            perform: {}
        )
    ]
}

// MARK: - Previews

#Preview("Rail") {
    let database = CardDatabase()

    CardInspector(
        card: database.cards.first { $0.hasSupportLine } ?? database.cards.first,
        isCompact: false,
        actions: [
            BoardAction(id: "turn", title: "End turn", style: .primary) {},
            BoardAction(id: "recovery", title: "Recovery") {}
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
            BoardAction(id: "turn", title: "End turn", style: .primary) {},
            BoardAction(id: "pass", title: "Pass") {}
        ],
        soundEnabled: .constant(true),
        onLeave: {}
    )
    .frame(width: 300, height: 720)
    .padding()
    .background(Palette.backdrop)
    .environment(database)
}

#Preview("Leader offers") {
    OfferSheet(
        title: "Naruto Uzumaki",
        offers: previewLeaderOffers(),
        onChoose: { _ in },
        onDismiss: {}
    )
    .environment(CardDatabase())
}

#Preview("Compact bar") {
    let database = CardDatabase()

    CardInspector(
        card: database.cards.first(where: \.canSetAsSupport) ?? database.cards.first,
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
