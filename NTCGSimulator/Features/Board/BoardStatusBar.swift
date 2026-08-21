//
//  BoardStatusBar.swift
//  NTCGSimulator
//
//  The band that sits between the two halves of the board. It answers the three
//  questions a player asks between taps: which phase the turn is in, what the
//  game is waiting for, and whose decision it is.
//

import SwiftUI

// MARK: - Status bar

/// Reports the state of the turn.
///
/// Every value is handed in by `GameBoardView` rather than read from the engine
/// here, so the bar can never disagree with the board it sits between — and it
/// stays cheap to preview at both widths.
struct BoardStatusBar: View {

    /// The phase the current turn sits in.
    let phase: GamePhase

    /// Player turns since the mulligan, not rounds. Zero before turn one.
    let turnNumber: Int

    /// One sentence describing what the game is waiting for.
    let prompt: String

    /// Display name of whoever is acting, already resolved for the play mode.
    let activePlayer: String

    /// Compact drops the phase track and folds the journal into a button.
    let isCompact: Bool

    /// Lines in the journal, shown on the compact button so the player can see
    /// the log has moved on without opening it.
    var journalCount: Int = 0

    /// Present on compact only, where the journal has no room of its own.
    var onShowJournal: (() -> Void)? = nil

    /// Present only while a Leader ability is waiting for a target. The band
    /// sits between the two halves, so the way out of a targeting mode is
    /// always next to the sentence explaining it.
    var onCancelTargeting: (() -> Void)? = nil

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
                    phaseChip
                    turnLabel
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
                phaseChip
                turnLabel
                Spacer(minLength: 0)
                playingLabel
            }

            phaseTrack

            promptRow

            Spacer(minLength: 0)
        }
        .padding(Metrics.spacingM)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
    }

    // MARK: Pieces

    private var phaseChip: some View {
        Text(phase.title)
            .font(Typeface.display(isCompact ? 12 : 15, weight: .heavy))
            .tracking(1.6)
            .textCase(.uppercase)
            .foregroundStyle(Palette.textOnAccent)
            .padding(.horizontal, Metrics.spacingS)
            .padding(.vertical, 3)
            .notchedPanel(notch: 6, corners: .diagonal, fill: Palette.accent, stroke: .clear)
            .accessibilityLabel("\(phase.title) phase")
    }

    /// Turn zero means both opening hands are still being settled.
    private var turnLabel: some View {
        Text(turnNumber > 0 ? "Turn \(turnNumber)" : "Opening")
            .font(Typeface.label(isCompact ? 9 : 11))
            .tracking(1.2)
            .textCase(.uppercase)
            .foregroundStyle(Palette.textSecondary)
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

    /// The sentence, and the way out of it when the board is mid-decision.
    private var promptRow: some View {
        HStack(alignment: .center, spacing: Metrics.spacingS) {
            promptText
            if let onCancelTargeting {
                cancelButton(onCancelTargeting)
            }
        }
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

    /// Backs out of a Leader ability that is waiting for a target.
    private func cancelButton(_ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text("Cancel")
                .font(Typeface.label(isCompact ? 9 : 11))
                .tracking(1.2)
                .textCase(.uppercase)
                .foregroundStyle(Palette.textOnAccent)
                .padding(.horizontal, Metrics.spacingS)
                .frame(height: isCompact ? 28 : 34)
                .notchedPanel(notch: 5, corners: .diagonal, fill: Palette.negative, stroke: .clear)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Cancel the Leader ability")
    }

    /// The whole turn at a glance. Refresh and draw never wait for input, but
    /// showing them keeps the sequence honest.
    private var phaseTrack: some View {
        HStack(spacing: Metrics.spacingXS) {
            ForEach(GamePhase.allCases) { step in
                Text(step.title)
                    .font(Typeface.label(9))
                    .tracking(1)
                    .textCase(.uppercase)
                    .foregroundStyle(step == phase ? Palette.textOnAccent : Palette.textSecondary)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 4)
                    .notchedPanel(
                        notch: 5,
                        corners: .diagonal,
                        fill: step == phase ? Palette.accent : Palette.surface,
                        stroke: step == phase ? .clear : Palette.border
                    )
            }
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Turn sequence, currently the \(phase.title.lowercased()) phase")
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
        phase: .main,
        turnNumber: 3,
        prompt: "Play cards from your hand, then move to the attack phase.",
        activePlayer: "P1",
        isCompact: true,
        journalCount: 24,
        onShowJournal: {}
    )
    .padding()
    .background(Palette.backdrop)
}

#Preview("Regular") {
    BoardStatusBar(
        phase: .attack,
        turnNumber: 6,
        prompt: "Choose a character to attack with, or end the phase.",
        activePlayer: "Opponent",
        isCompact: false
    )
    .frame(height: BoardStatusBar.regularHeight)
    .padding()
    .background(Palette.backdrop)
}

#Preview("Choosing a target") {
    VStack(spacing: Metrics.spacingM) {
        BoardStatusBar(
            phase: .main,
            turnNumber: 4,
            prompt: "An opposing character loses 2 power: choose the character it acts on.",
            activePlayer: "P1",
            isCompact: true,
            journalCount: 12,
            onShowJournal: {},
            onCancelTargeting: {}
        )

        BoardStatusBar(
            phase: .main,
            turnNumber: 4,
            prompt: "An opposing character loses 2 power: choose the character it acts on.",
            activePlayer: "P1",
            isCompact: false,
            onCancelTargeting: {}
        )
        .frame(height: BoardStatusBar.regularHeight)
    }
    .padding()
    .background(Palette.backdrop)
}
