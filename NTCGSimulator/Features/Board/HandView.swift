//
//  HandView.swift
//  NTCGSimulator
//
//  The near player's hand: a horizontal strip of faces that lifts the card being
//  read, and the action panel a tap on one opens.
//
//  A card in hand has three uses, not one — SUMMON, SET AS SUPPORT and PLAY …
//  JUTSU — so the strip marks which of them are live right now and the panel
//  names, in the engine's own words, why the rest are not. That naming is the
//  whole value of the panel: "Summon already used this turn", "Wrong moment" and
//  "No valid target" are rules a player can only learn by being told them, and a
//  silently greyed button teaches nothing.
//

import SwiftUI

// MARK: - Offered modes

extension HandCard {

    /// The modes worth putting in front of the player, in printed order.
    ///
    /// SUMMON is always offered, refused or not, because its refusal is the one
    /// rule the reference teaches through the panel. SET AS SUPPORT belongs only
    /// to the twelve cards printing a SUPPORT bar — a card without one has no
    /// face-down use at all, so offering it greyed would invent a mode the card
    /// does not have — and PLAY … JUTSU only where a jutsu is printed.
    var offeredOptions: [PlayOption] {
        options.filter { option in
            switch option.mode {
            case .summon:       return true
            case .setAsSupport: return card.canSetAsSupport
            case .jutsu:        return card.hasSupportLine || card.jutsuAbility != nil
            }
        }
    }
}

// MARK: - Hand

/// The hand strip along the bottom of the board.
///
/// `HandCard.id` is the hand index every hand action addresses — `summon`,
/// `setSupport`, `activateSupportFromHand` — so a tap turns straight into an
/// action without the view tracking positions itself.
struct HandView: View {

    let cards: [HandCard]

    /// Derived from the board's slot width so cards shrink with the board.
    let cardWidth: CGFloat

    /// The hand index currently being read, lifted clear of its neighbours.
    let selectedIndex: Int?

    /// False while the other side is acting — everything dims and taps are
    /// still forwarded, so the board can explain why nothing happened.
    let isInteractive: Bool

    /// Shown when the hand is empty. Worded by the board, which knows whose
    /// hand this is.
    let emptyMessage: String

    /// Hand positions the open prompt offers, for a prompt answered from the
    /// hand rather than from the mat — the Leader's put-back is the pool's.
    ///
    /// `nil` means no prompt is choosing here and the strip behaves normally.
    /// Non-nil puts the strip into the same treatment the mat uses: the offered
    /// cards light up and everything else steps back, so a legal answer is
    /// always the lit thing wherever it happens to be sitting.
    var choiceTargets: Set<Int>? = nil

    /// Hand positions already staged for a prompt that takes several.
    var stagedTargets: Set<Int> = []

    /// A tap: open the card's action panel.
    let onPlay: (HandCard) -> Void

    /// A long press: read the card without committing to it.
    let onRead: (HandCard) -> Void

    /// How far the read card rises out of the strip.
    private let lift: CGFloat = 10

    /// Matches the dim `CardFaceView` applies to a card that cannot be played,
    /// so the mode bar fades with the face it sits on.
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
        let isChoosing = choiceTargets != nil
        let isTarget = choiceTargets?.contains(handCard.id) ?? false
        let isStaged = stagedTargets.contains(handCard.id)

        // A prompt outranks playability: while one is open the only question
        // being asked of the hand is which card answers it.
        let isDimmed = isChoosing
            ? !(isTarget || isStaged)
            : (!isInteractive || !handCard.isPlayable)

        return BoardCardFace(
            card: handCard.card,
            size: .small,
            width: cardWidth,
            isDimmed: isDimmed,
            highlight: highlight(isChoosing: isChoosing,
                                 isTarget: isTarget,
                                 isStaged: isStaged,
                                 isSelected: isSelected)
        )
        .overlay(alignment: .top) {
            // The three play modes answer a question nobody is asking while a
            // prompt is open, so the bar leaves rather than greying out.
            if !isChoosing {
                PlayModeBar(handCard: handCard, width: cardWidth)
                    .opacity(isDimmed ? dimmedOpacity : 1)
                    .allowsHitTesting(false)
            }
        }
        .overlay(alignment: .topTrailing) {
            targetMark(isTarget: isTarget, isStaged: isStaged)
        }
        .offset(y: isSelected || isStaged ? -lift : 0)
        .animation(.spring(response: 0.28, dampingFraction: 0.8), value: isSelected)
        .animation(.spring(response: 0.28, dampingFraction: 0.8), value: isStaged)
        .contentShape(Rectangle())
        .onTapGesture { onPlay(handCard) }
        .onLongPressGesture { onRead(handCard) }
        .accessibilityElement(children: .ignore)
        .accessibilityAddTraits(.isButton)
        .accessibilityLabel(label(for: handCard, isTarget: isTarget, isStaged: isStaged))
        .accessibilityHint(hint(for: handCard, isChoosing: isChoosing))
        .accessibilityAction(named: Text("Read this card")) { onRead(handCard) }
    }

    /// The ring, in the same order of commitment the mat uses: staged beats
    /// offered, offered beats the reader's own selection, and a card the open
    /// prompt does not offer wears nothing at all.
    ///
    /// One accent for everything the player may tap, exactly as on the mat —
    /// the badge is what separates chosen from choosable.
    private func highlight(
        isChoosing: Bool,
        isTarget: Bool,
        isStaged: Bool,
        isSelected: Bool
    ) -> Color? {
        if isStaged || isTarget { return Palette.accent }
        if isChoosing { return nil }
        return isSelected ? Palette.accent : nil
    }

    /// The badge the mat puts on a choosable card, repeated here so the hand
    /// and the board read the same during a prompt.
    @ViewBuilder
    private func targetMark(isTarget: Bool, isStaged: Bool) -> some View {
        if isStaged || isTarget {
            Image(systemName: isStaged ? "checkmark" : "scope")
                .font(.system(size: 9, weight: .black))
                .foregroundStyle(Palette.textOnAccent)
                .padding(3.5)
                .background(isStaged ? Palette.positive : Palette.accent, in: Circle())
                .padding(3)
                .accessibilityHidden(true)
        }
    }

    private var emptyState: some View {
        Text(emptyMessage)
            .font(Typeface.body(13))
            .foregroundStyle(Palette.textSecondary)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .notchedPanel(notch: 8, fill: Palette.panel.opacity(0.5), stroke: Palette.border)
    }

    private func label(for handCard: HandCard, isTarget: Bool, isStaged: Bool) -> String {
        let card = handCard.card
        var parts = [card.name, card.type.title]
        if let power = card.power { parts.append("power \(power)") }
        if let health = card.health { parts.append("health \(health)") }

        // While a prompt is choosing from the hand, what the card could
        // otherwise be played as is not on offer and reading it out is noise.
        guard choiceTargets == nil else {
            if isStaged {
                parts.append("staged for the open prompt")
            } else if isTarget {
                parts.append("an option for the open prompt")
            } else {
                parts.append("not an option for the open prompt")
            }
            return parts.joined(separator: ", ")
        }

        parts.append(contentsOf: handCard.offeredOptions.map(spoken))
        return parts.joined(separator: ", ")
    }

    /// One mode, spoken: what it is, what it charges, and — when it is refused —
    /// the engine's own reason. The refusal is read out rather than summarised,
    /// because it is the same sentence the action panel prints.
    private func spoken(_ option: PlayOption) -> String {
        let price = option.cost == 0 ? "free" : "\(option.cost) chakra"
        guard let refusal = option.refusal else { return "\(option.title), \(price)" }
        return "\(option.title), unavailable, \(refusal)"
    }

    private func hint(for handCard: HandCard, isChoosing: Bool) -> String {
        if isChoosing { return "Double tap to answer the open prompt with it" }
        return handCard.isPlayable
            ? "Double tap to choose how to play it"
            : "Double tap to see why it cannot be played"
    }
}

// MARK: - Mode marks

/// Which of a card's modes are live right now, drawn across the top of its face.
///
/// The number printed on a Character is not a summoning price — summoning is
/// free, and so is setting the card face-down — so this bar reports modes rather
/// than the printed cost, and carries a price only where one is actually
/// charged. A lit mark is one the engine would accept; a grey one is refused,
/// and the action panel behind the tap says why.
private struct PlayModeBar: View {

    let handCard: HandCard

    /// The card's width. A card offering all three modes has to fit three marks
    /// into it, and a third of a phone-sized hand card is not wide enough for a
    /// word — below the threshold every mark keeps only its glyph.
    let width: CGFloat

    private static let wordThreshold: CGFloat = 108

    private var showsWords: Bool { width >= Self.wordThreshold }

    var body: some View {
        HStack(spacing: 2) {
            ForEach(handCard.offeredOptions) { option in
                mark(option)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 2)
        .padding(.vertical, 1.5)
        .frame(maxWidth: .infinity)
        .background(Palette.backdrop.opacity(0.72))
        // The card's own top-trailing corner is cut, so the bar's is too.
        .clipShape(NotchedRectangle(notch: 6, corners: [.topTrailing]))
        .accessibilityHidden(true)
    }

    private func mark(_ option: PlayOption) -> some View {
        HStack(spacing: 1) {
            if showsWords {
                Text(word(for: option))
                    .font(Typeface.label(8))
                    .textCase(.uppercase)
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
            } else {
                Image(systemName: glyph(for: option.mode))
                    .font(.system(size: 6.5, weight: .bold))
                if option.cost > 0 {
                    Text("\(option.cost)")
                        .font(Typeface.numeric(7, weight: .bold))
                }
            }
        }
        .foregroundStyle(Palette.textOnAccent)
        .padding(.horizontal, 2)
        .padding(.vertical, 0.5)
        .background(tint(for: option).opacity(0.95), in: RoundedRectangle(cornerRadius: 3))
        .opacity(option.isAllowed ? 1 : 0.7)
    }

    /// The short forms. The panel prints the card's own jutsu name in full;
    /// a hand card has room for the verb and the price, and nothing more.
    private func word(for option: PlayOption) -> String {
        switch option.mode {
        case .summon:       return "Summon"
        case .setAsSupport: return "Set"
        case .jutsu:        return option.cost == 0 ? "Jutsu" : "Jutsu \(option.cost)"
        }
    }

    private func glyph(for mode: CardPlayMode) -> String {
        switch mode {
        case .summon:       return "person.fill"
        case .setAsSupport: return "square.stack.fill"
        case .jutsu:        return "sparkles"
        }
    }

    private func tint(for option: PlayOption) -> Color {
        option.isAllowed ? Palette.accent : Palette.textSecondary
    }
}

// MARK: - Action panel

/// The panel the reference opens when a card in hand is selected.
///
/// It offers the card's modes — SUMMON, SET AS SUPPORT and PLAY <NAME> JUTSU —
/// each either pressable or greyed out **with the reason printed beside it**,
/// taken from the engine rather than reworded here. "Summon already used this
/// turn", "Wrong moment" and "No valid target" are the reference's own
/// disabled-button reasons, and they are the whole point of the panel.
///
/// SET AS SUPPORT appears only for a card printing a SUPPORT bar — see
/// `HandCard.offeredOptions`.
///
/// The second question `SettingsStore.confirmJutsuSummon` asks for is asked
/// inside the panel, under the row it belongs to, rather than through a system
/// dialog. A dialog takes the player out of the game to answer a question about
/// a card it then hides, and it cannot show the price or the printed text the
/// answer depends on — the row can, because the row is already showing them.
struct HandActionPanel: View {

    let handCard: HandCard

    /// Chakra ready right now. Shown as a readout so an unaffordable price and
    /// its refusal agree with something the player can see.
    let availableChakra: Int

    /// `SettingsStore.confirmJutsuSummon`. When on, a chosen mode is confirmed
    /// once more before it is spent — the panel asks from inside itself rather
    /// than handing the question back to the board, so the two presentations can
    /// never race each other.
    let asksToConfirm: Bool

    /// A mode the player pressed and, where asked for, confirmed.
    let onChoose: (PlayOption) -> Void

    let onDismiss: () -> Void

    /// The mode waiting on its second press.
    @State private var pending: PlayOption?

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            AmbientBackground()

            VStack(alignment: .leading, spacing: Metrics.spacingM) {
                header

                ScrollView {
                    VStack(alignment: .leading, spacing: Metrics.spacingS) {
                        ForEach(handCard.offeredOptions) { option in
                            row(option)
                        }

                        if handCard.allowedOptions.isEmpty {
                            footnote
                        }
                    }
                    .padding(.bottom, Metrics.spacingS)
                }
                .scrollIndicators(.hidden)

                WideButton(title: "Cancel", style: .primary, action: onDismiss)
            }
            .padding(Metrics.spacingL)
        }
    }

    // MARK: Header

    private var header: some View {
        HStack(alignment: .top, spacing: Metrics.spacingM) {
            // `BoardCardFace` rather than a bare face: a printed face will not
            // compress past its own stat badges, so it is laid out at a width
            // its contents are comfortable in and scaled into this one.
            BoardCardFace(card: handCard.card, size: .small, width: 74)

            VStack(alignment: .leading, spacing: Metrics.spacingXS) {
                Text(handCard.card.name)
                    .font(Typeface.display(20, weight: .bold))
                    .foregroundStyle(Palette.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)

                Text("\(handCard.card.type.title) · \(handCard.card.color.title)")
                    .font(Typeface.label(10))
                    .tracking(1.2)
                    .textCase(.uppercase)
                    .foregroundStyle(Palette.accent)

                Text(chakraReadout)
                    .font(Typeface.label(10))
                    .tracking(1)
                    .textCase(.uppercase)
                    .foregroundStyle(Palette.textSecondary)
            }

            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .combine)
    }

    private var chakraReadout: String {
        availableChakra == 1 ? "1 chakra ready" : "\(availableChakra) chakra ready"
    }

    // MARK: Rows

    /// One mode, with its confirmation strip underneath when the player has
    /// asked to be asked twice.
    private func row(_ option: PlayOption) -> some View {
        VStack(alignment: .leading, spacing: Metrics.spacingS) {
            modeButton(option)
                // The other modes step back while one is waiting on its second
                // press, so the panel has one live question at a time.
                .opacity(pending == nil || pending?.id == option.id ? 1 : 0.4)

            if pending?.id == option.id {
                confirmStrip(option)
            }
        }
    }

    /// One mode. A refused row stays readable and keeps its price: a player who
    /// can see what a mode would have cost can plan the turn that unlocks it.
    private func modeButton(_ option: PlayOption) -> some View {
        Button {
            guard option.isAllowed else { return }
            guard asksToConfirm else {
                onChoose(option)
                return
            }
            withAnimation(reduceMotion ? nil : .easeOut(duration: 0.18)) {
                pending = option
            }
        } label: {
            VStack(alignment: .leading, spacing: Metrics.spacingXS) {
                HStack(alignment: .firstTextBaseline, spacing: Metrics.spacingS) {
                    Text(option.title)
                        .font(Typeface.label(13))
                        .tracking(1.4)
                        .textCase(.uppercase)
                        .foregroundStyle(option.isAllowed ? Palette.accent : Palette.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)

                    Spacer(minLength: 0)

                    Text(price(option))
                        .font(Typeface.label(11))
                        .tracking(1)
                        .textCase(.uppercase)
                        .foregroundStyle(Palette.textSecondary)
                }

                Text(detail(option))
                    .font(Typeface.body(12))
                    .foregroundStyle(option.isAllowed ? Palette.textSecondary : Palette.negative)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(Metrics.spacingM)
            .notchedPanel(
                notch: 8,
                fill: option.isAllowed ? Palette.panelActive : Palette.surface.opacity(0.6),
                stroke: option.isAllowed ? Palette.accent : Palette.border
            )
        }
        .buttonStyle(.plain)
        .disabled(!option.isAllowed)
        .opacity(option.isAllowed ? 1 : 0.7)
        .accessibilityElement(children: .ignore)
        .accessibilityAddTraits(.isButton)
        .accessibilityLabel("\(option.title), \(price(option)), \(detail(option))")
    }

    /// What the mode does, or the engine's own words for why it will not.
    private func detail(_ option: PlayOption) -> String {
        if let refusal = option.refusal { return refusal }
        switch option.mode {
        case .summon:
            return "Puts the card into your Characters row."
        case .setAsSupport:
            return "Puts it face-down in a numbered Support slot, to answer with later."
        case .jutsu:
            return handCard.card.supportText ?? "Resolves the card's jutsu and sends it to the Trash."
        }
    }

    private func price(_ option: PlayOption) -> String {
        option.cost == 0 ? "Free" : "\(option.cost) chakra"
    }

    /// Shown when every mode is refused, so the panel never reads as broken.
    private var footnote: some View {
        Text("Nothing can be done with this card right now.")
            .font(Typeface.body(12))
            .foregroundStyle(Palette.textSecondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, Metrics.spacingXS)
    }

    // MARK: Confirmation

    /// The second press, asked where the first one was made.
    ///
    /// It repeats the price rather than only the verb, because the price is
    /// what the question is actually about: "Activate Chidori" is not a
    /// decision until the two chakra it charges are beside it.
    private func confirmStrip(_ option: PlayOption) -> some View {
        VStack(alignment: .leading, spacing: Metrics.spacingS) {
            Text(confirmationMessage(for: option))
                .font(Typeface.body(12))
                .foregroundStyle(Palette.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)

            HStack(spacing: Metrics.spacingS) {
                WideButton(title: "Confirm", style: .primary) {
                    let chosen = option
                    pending = nil
                    onChoose(chosen)
                }
                WideButton(title: "Not yet") {
                    withAnimation(reduceMotion ? nil : .easeOut(duration: 0.18)) {
                        pending = nil
                    }
                }
            }
        }
        .padding(Metrics.spacingM)
        .frame(maxWidth: .infinity, alignment: .leading)
        .notchedPanel(notch: 8, fill: Palette.panelActive, stroke: Palette.accent)
        .transition(.opacity)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Confirm \(option.title)")
    }

    private func confirmationMessage(for option: PlayOption) -> String {
        "\(handCard.card.name) — \(option.title.lowercased()), \(price(option).lowercased()). \(detail(option))"
    }
}

// MARK: - Previews

#Preview("Dealt hand") {
    let database = CardDatabase()
    let engine = BoardPreview.engine(database: database)

    HandView(
        cards: engine.handCards(for: .player),
        cardWidth: 62,
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

/// One of each marked case side by side: a card whose summon is refused, a card
/// carrying a SUPPORT bar, and a plain body.
#Preview("Every mode") {
    let database = CardDatabase()
    let samples = [
        database.cards.first { $0.type.isBody && !$0.canSetAsSupport },
        database.cards.first(where: \.canSetAsSupport),
        database.cards.first { $0.type == .exCharacter }
    ].compactMap { $0 }

    HandView(
        cards: samples.enumerated().map { entry in
            HandCard(
                id: entry.offset,
                card: entry.element,
                options: BoardPreview.options(
                    for: entry.element,
                    summonRefusal: entry.offset == 0 ? "Summon already used this turn" : nil,
                    jutsuRefusal: entry.offset == 1 ? "Wrong moment" : nil
                )
            )
        },
        cardWidth: 118,
        selectedIndex: nil,
        isInteractive: true,
        emptyMessage: "Your hand is empty.",
        onPlay: { _ in },
        onRead: { _ in }
    )
    .frame(height: 190)
    .padding()
    .background(Palette.backdrop)
    .environment(database)
}

/// A prompt answered from the hand — the Leader's put-back. Two positions are
/// offered, one of them already staged, and everything else steps back.
#Preview("Choosing from the hand") {
    let database = CardDatabase()
    let engine = BoardPreview.engine(database: database)
    let cards = engine.handCards(for: .player)

    HandView(
        cards: cards,
        cardWidth: 74,
        selectedIndex: nil,
        isInteractive: false,
        emptyMessage: "Your hand is empty.",
        choiceTargets: Set(cards.prefix(3).map(\.id)),
        stagedTargets: cards.first.map { [$0.id] } ?? [],
        onPlay: { _ in },
        onRead: { _ in }
    )
    .frame(height: 120)
    .padding()
    .background(Palette.backdrop)
    .environment(database)
}

#Preview("Action panel") {
    let database = CardDatabase()
    let card = database.cards.first(where: \.canSetAsSupport) ?? database.cards[0]

    HandActionPanel(
        handCard: HandCard(
            id: 0,
            card: card,
            options: BoardPreview.options(
                for: card,
                summonRefusal: "Summon already used this turn",
                jutsuRefusal: "No valid target"
            )
        ),
        availableChakra: 2,
        asksToConfirm: false,
        onChoose: { _ in },
        onDismiss: {}
    )
    .environment(database)
}

/// The panel with the second question turned on. Pressing a mode opens the
/// confirmation under the row it belongs to instead of over the whole app.
#Preview("Action panel, confirming") {
    let database = CardDatabase()
    let card = database.cards.first(where: \.canSetAsSupport) ?? database.cards[0]

    HandActionPanel(
        handCard: HandCard(id: 0, card: card, options: BoardPreview.options(for: card)),
        availableChakra: 3,
        asksToConfirm: true,
        onChoose: { _ in },
        onDismiss: {}
    )
    .environment(database)
}
