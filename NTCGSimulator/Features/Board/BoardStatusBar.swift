//
//  BoardStatusBar.swift
//  NTCGSimulator
//
//  The band that sits between the two halves of the board. It answers the three
//  questions a player asks between taps: what the game is waiting for, whose
//  decision it is, and how far into the game they are.
//
//  It used to draw a five-step phase track. The reference has no phases at all —
//  the turn is one undivided state prompting "Your turn, play a card or attack",
//  with END TURN as the only turn control — so there is no phase to report and no
//  step for the player to advance. What the chip carries instead is the turn
//  state: the opening mulligan, the turn itself, or a response window the other
//  player owes an answer to.
//
//  The one thing in a turn that actually runs out is the single normal summon, so
//  that is drawn as its own marker. "Summon already used this turn" is otherwise
//  only discoverable by tapping a card and being refused, which is exactly the
//  kind of silent rule this band exists to prevent.
//

import SwiftUI

// MARK: - Status bar

/// Reports the state of the turn.
///
/// Every value is handed in by `GameBoardView` rather than read from the engine
/// here, so the bar can never disagree with the board it sits between — and it
/// stays cheap to preview at both widths.
struct BoardStatusBar: View {

    /// What the game is waiting for.
    let turnState: TurnState

    /// Player turns since the mulligan, not rounds. Zero before turn one.
    let turnNumber: Int

    /// One sentence describing what the game is waiting for. Worded by the
    /// board, which knows whose device this is and what it has armed.
    let prompt: String

    /// Display name of whoever is acting, already resolved for the play mode.
    let activePlayer: String

    /// Compact folds the journal into a button and shortens every label.
    let isCompact: Bool

    /// Whether the acting player has already taken the turn's one summon.
    var hasSummoned: Bool = false

    /// Lines in the journal, shown on the compact button so the player can see
    /// the log has moved on without opening it.
    var journalCount: Int = 0

    /// Present on compact only, where the journal has no room of its own.
    var onShowJournal: (() -> Void)? = nil

    /// Present only while an ability, a jutsu or a face-down Support is waiting
    /// for a target. The band sits between the two halves, so the way out of a
    /// targeting mode is always next to the sentence explaining it.
    var onCancelTargeting: (() -> Void)? = nil

    /// A short instruction naming what is being chosen, shown while the mat is
    /// lit for a target — "Choose a target", "Choose up to 2".
    ///
    /// It sits beside the prompt rather than replacing it. The prompt is the
    /// card's own wording and can be a whole sentence; this is the three words
    /// telling the player that the answer is a tap on the board, which is the
    /// one thing the printed sentence never says.
    var targetingNote: String? = nil

    // MARK: Reserved heights

    /// Height the board reserves for this bar on a phone. Fixed rather than
    /// intrinsic so the board's slot arithmetic has a number to work from.
    static let compactHeight: CGFloat = 66

    /// Height of the middle band on a regular width, shared with the journal.
    static let regularHeight: CGFloat = 132

    var body: some View {
        Group {
            if isCompact { compactLayout } else { regularLayout }
        }
        .notchedPanel(fill: Palette.panel.opacity(0.94), stroke: Palette.border)
    }

    // MARK: Compact

    /// Two stacked lines beside a journal button, pinned to a known height so a
    /// long prompt truncates instead of pushing the board off-screen.
    private var compactLayout: some View {
        HStack(spacing: Metrics.spacingS) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: Metrics.spacingXS) {
                    stateChip
                    turnLabel
                    // While the mat is lit, the instruction takes the marker's
                    // place. "Summon ready" is not the fact a player choosing a
                    // target needs, and a phone-width row has room for one of
                    // the two — squeezing both leaves the chip as a bare icon.
                    if let targetingNote {
                        targetingChip(targetingNote)
                    } else {
                        summonMarker
                    }
                    Spacer(minLength: 0)
                    playingLabel
                }
                promptRow
            }

            if let onShowJournal {
                journalButton(onShowJournal)
            }
        }
        .padding(.horizontal, Metrics.spacingS)
        .padding(.vertical, 6)
        .frame(height: Self.compactHeight)
    }

    // MARK: Regular

    private var regularLayout: some View {
        VStack(alignment: .leading, spacing: Metrics.spacingS) {
            HStack(spacing: Metrics.spacingS) {
                stateChip
                turnLabel
                Spacer(minLength: 0)
                playingLabel
            }

            HStack(spacing: Metrics.spacingS) {
                summonMarker
                if let targetingNote {
                    targetingChip(targetingNote)
                }
                Spacer(minLength: 0)
            }

            promptRow

            Spacer(minLength: 0)
        }
        .padding(Metrics.spacingM)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
    }

    // MARK: Pieces

    private var stateChip: some View {
        Text(chipTitle)
            .font(Typeface.display(isCompact ? 12 : 15, weight: .heavy))
            .tracking(1.6)
            .textCase(.uppercase)
            .foregroundStyle(Palette.textOnAccent)
            .lineLimit(1)
            // The top row carries four labels on a phone. Every one of them can
            // give ground, so a long name — "Playing: The AI" beside a spent
            // summon — shrinks the row rather than truncating one label to a
            // word the player cannot read.
            .minimumScaleFactor(0.7)
            .padding(.horizontal, Metrics.spacingS)
            .padding(.vertical, 3)
            .notchedPanel(notch: 6, corners: .diagonal, fill: chipTint, stroke: .clear)
            .accessibilityLabel(chipTitle)
    }

    /// A window names what it is answering wherever there is room for it — the
    /// difference between answering a summon and answering an attack decides
    /// which face-down card is worth spending.
    private var chipTitle: String {
        guard !isCompact, let window = turnState.responseWindow else { return turnState.title }
        return window.kind.title
    }

    /// A response window is somebody else's decision, so it is coloured apart
    /// from the turn it interrupts.
    private var chipTint: Color {
        turnState.responseWindow == nil ? Palette.accent : Palette.negative
    }

    /// Turn zero means both opening hands are still being settled.
    private var turnLabel: some View {
        Text(turnNumber > 0 ? "Turn \(turnNumber)" : "Opening")
            .font(Typeface.label(isCompact ? 9 : 11))
            .tracking(1.2)
            .textCase(.uppercase)
            .foregroundStyle(Palette.textSecondary)
            .lineLimit(1)
            .minimumScaleFactor(0.7)
            .layoutPriority(-1)
    }

    private var playingLabel: some View {
        Text("Playing: \(activePlayer)")
            .font(Typeface.label(isCompact ? 9 : 11))
            .tracking(1)
            .foregroundStyle(Palette.textPrimary)
            .lineLimit(1)
            .minimumScaleFactor(0.7)
            .accessibilityLabel("Playing, \(activePlayer)")
    }

    /// The sentence, and the way out of it when the board is mid-decision. The
    /// instruction that goes with it sits on the row above, beside the state.
    private var promptRow: some View {
        HStack(alignment: .center, spacing: Metrics.spacingS) {
            promptText
            if let onCancelTargeting {
                cancelButton(onCancelTargeting)
            }
        }
    }

    /// The instruction, in the same accent the mat lights its legal targets
    /// with — the chip and the ring the player is being pointed at are meant to
    /// read as one thing.
    private func targetingChip(_ text: String) -> some View {
        HStack(spacing: 3) {
            Image(systemName: "target")
                .font(.system(size: isCompact ? 8 : 10, weight: .bold))
            Text(text)
                .font(Typeface.label(isCompact ? 9 : 10))
                .tracking(1)
                .textCase(.uppercase)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
        .foregroundStyle(Palette.textOnAccent)
        .padding(.horizontal, Metrics.spacingS)
        .padding(.vertical, 3)
        .notchedPanel(notch: 5, corners: .diagonal, fill: Palette.accent, stroke: .clear)
        // It shares the top row with the turn label, which gives ground first.
        .layoutPriority(1)
        .accessibilityLabel(text)
    }

    private var promptText: some View {
        Text(prompt)
            .font(Typeface.body(isCompact ? 12 : 14))
            .foregroundStyle(Palette.textSecondary)
            .lineLimit(2)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityLabel(prompt)
    }

    /// Backs out of whatever is waiting for a target.
    ///
    /// Fixed at its own width: the row it shares with the prompt and the
    /// targeting chip is tight on a phone, and a compressed button breaks
    /// "Cancel" across two lines rather than shortening the sentence beside it.
    private func cancelButton(_ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text("Cancel")
                .font(Typeface.label(isCompact ? 9 : 11))
                .tracking(1.2)
                .textCase(.uppercase)
                .lineLimit(1)
                .fixedSize()
                .foregroundStyle(Palette.textOnAccent)
                .padding(.horizontal, Metrics.spacingS)
                .frame(height: isCompact ? 28 : 34)
                .notchedPanel(notch: 5, corners: .diagonal, fill: Palette.negative, stroke: .clear)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Cancel and choose again")
    }

    /// The one thing in the turn that runs out. Everything else — setting
    /// Supports, playing jutsu, attacking — is limited only by the cards, so
    /// this is the only counter the band carries.
    ///
    /// The spent wording is the reference's own refusal, word for word, so a
    /// player reads the same sentence here that a greyed SUMMON button gives
    /// them.
    @ViewBuilder
    private var summonMarker: some View {
        if turnNumber > 0 {
            Text(summonText)
                .font(Typeface.label(isCompact ? 8 : 9))
                .tracking(1)
                .textCase(.uppercase)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                .foregroundStyle(hasSummoned ? Palette.textSecondary : Palette.textOnAccent)
                .padding(.horizontal, isCompact ? 5 : 7)
                .padding(.vertical, isCompact ? 2 : 4)
                .notchedPanel(
                    notch: 5,
                    corners: .diagonal,
                    fill: hasSummoned ? Palette.surface : Palette.accent,
                    stroke: hasSummoned ? Palette.border : .clear
                )
                .accessibilityLabel(hasSummoned
                                    ? "Summon already used this turn"
                                    : "The turn's summon is still available")
        }
    }

    /// The full refusal will not fit beside the turn number on a phone, so the
    /// compact form keeps the state and drops the sentence — the action panel
    /// still prints the whole of it against the button it refuses.
    private var summonText: String {
        if isCompact { return hasSummoned ? "Summon used" : "Summon ready" }
        return hasSummoned ? "Summon already used this turn" : "Summon available"
    }

    private func journalButton(_ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 1) {
                Image(systemName: "list.bullet.rectangle")
                    .font(Typeface.label(14))
                Text("\(journalCount)")
                    .font(Typeface.numeric(9, weight: .bold))
            }
            .foregroundStyle(Palette.accent)
            .frame(width: 44, height: 44)
            .notchedPanel(notch: 6, corners: .diagonal, fill: Palette.surface, stroke: Palette.border)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Open the journal, \(journalCount) lines")
    }
}

// MARK: - Previews

#Preview("Compact") {
    BoardStatusBar(
        turnState: .acting,
        turnNumber: 3,
        prompt: "\(TurnState.acting.prompt).",
        activePlayer: "P1",
        isCompact: true,
        journalCount: 24,
        onShowJournal: {}
    )
    .padding()
    .background(Palette.backdrop)
}

#Preview("Compact, summon spent") {
    BoardStatusBar(
        turnState: .acting,
        turnNumber: 7,
        prompt: "\(TurnState.acting.prompt).",
        activePlayer: "The AI",
        isCompact: true,
        hasSummoned: true,
        journalCount: 61,
        onShowJournal: {}
    )
    .frame(width: 393 - Metrics.spacingS * 2)
    .padding()
    .background(Palette.backdrop)
}

#Preview("Regular, summon spent") {
    BoardStatusBar(
        turnState: .acting,
        turnNumber: 6,
        prompt: "\(TurnState.acting.prompt).",
        activePlayer: "Opponent",
        isCompact: false,
        hasSummoned: true
    )
    .frame(height: BoardStatusBar.regularHeight)
    .padding()
    .background(Palette.backdrop)
}

#Preview("Answering a summon") {
    let window = ResponseWindow(
        kind: .summon,
        respondingSlot: .opponent,
        chainLength: 0
    )

    return VStack(spacing: Metrics.spacingM) {
        BoardStatusBar(
            turnState: .awaitingResponse(window),
            turnNumber: 4,
            prompt: "P2: \(window.prompt.lowercased()), or pass.",
            activePlayer: "P1",
            isCompact: true,
            journalCount: 18,
            onShowJournal: {}
        )

        BoardStatusBar(
            turnState: .awaitingResponse(window),
            turnNumber: 4,
            prompt: "P2: \(window.prompt.lowercased()), or pass.",
            activePlayer: "P1",
            isCompact: false
        )
        .frame(height: BoardStatusBar.regularHeight)
    }
    .padding()
    .background(Palette.backdrop)
}

#Preview("Choosing a target") {
    VStack(spacing: Metrics.spacingM) {
        BoardStatusBar(
            turnState: .acting,
            turnNumber: 4,
            prompt: "An opposing character loses 2 power: choose the character it acts on.",
            activePlayer: "P1",
            isCompact: true,
            journalCount: 12,
            onShowJournal: {},
            onCancelTargeting: {},
            targetingNote: "Choose a target"
        )

        BoardStatusBar(
            turnState: .acting,
            turnNumber: 4,
            prompt: "An opposing character loses 2 power: choose the character it acts on.",
            activePlayer: "P1",
            isCompact: false,
            onCancelTargeting: {},
            targetingNote: "Choose up to 2"
        )
        .frame(height: BoardStatusBar.regularHeight)
    }
    .padding()
    .background(Palette.backdrop)
}
