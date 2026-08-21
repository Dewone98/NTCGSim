//
//  CardInspector.swift
//  NTCGSimulator
//
//  The card reader and the contextual controls beneath it. The simulator this
//  follows invites you to "hover a card to read it in full"; on a touch screen
//  focus arrives from a tap or a long press instead, so the same panel doubles
//  as the board's action bar.
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

    /// Caps the rules text so a wordy card cannot push the action stack off the
    /// bottom of the rail.
    private let detailHeight: CGFloat = 190

    var body: some View {
        if isCompact { compactBar } else { rail }
    }

    // MARK: Regular rail

    private var rail: some View {
        VStack(alignment: .leading, spacing: Metrics.spacingM) {
            Text("Card reader").sectionLabel()

            face

            details

            Spacer(minLength: 0)

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

                    if !card.effect.isEmpty {
                        Text(card.effect)
                            .font(Typeface.body(13))
                            .foregroundStyle(Palette.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    if let ability = card.leaderAbility {
                        abilityLine(ability)
                    }

                    if let support = card.supportText, !support.isEmpty {
                        supportLine(support)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .scrollIndicators(.hidden)
            .frame(maxHeight: detailHeight)
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

    /// A Leader's activated ability. It is the one printed effect the engine
    /// actually resolves, and the board turns the Leader itself into its
    /// button, so the reader spells out what that button will do.
    private func abilityLine(_ ability: LeaderAbility) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("Leader ability").sectionLabel()
            Text(ability.summary)
                .font(Typeface.body(13))
                .foregroundStyle(Palette.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
            Text(abilityFootnote(ability))
                .font(Typeface.body(11))
                .foregroundStyle(Palette.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(Metrics.spacingS)
        .notchedPanel(notch: 8, fill: Palette.panelActive, stroke: Palette.accent)
    }

    private func abilityFootnote(_ ability: LeaderAbility) -> String {
        var text = "Tap your Leader once per turn during your main phase."
        if ability.needsFriendlyTarget {
            text += " Then choose one of your own characters."
        } else if ability.needsEnemyTarget {
            text += " Then choose one of the opponent's characters."
        }
        return text
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
            Text(card?.name ?? "Hover a card to read it in full")
                .font(Typeface.display(13, weight: .bold))
                .foregroundStyle(Palette.textPrimary)
                .lineLimit(1)
                .minimumScaleFactor(0.8)

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

    /// The two lines the compact bar has room for. A Leader's activated ability
    /// wins over its printed text, because it is the part that can be used.
    private func compactRulesText(for card: Card) -> String {
        if let ability = card.leaderAbility { return "Ability: \(ability.summary)" }
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

#Preview("Leader ability") {
    let database = CardDatabase()

    CardInspector(
        card: database.leaders.first { $0.leaderAbility != nil } ?? database.cards.first,
        isCompact: false,
        actions: [
            BoardAction(id: "phase", title: "End phase", style: .primary) {},
            BoardAction(id: "ability", title: "Draw a card", shortTitle: "Ability") {},
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
