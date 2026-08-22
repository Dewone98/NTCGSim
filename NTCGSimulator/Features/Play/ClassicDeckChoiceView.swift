//
//  ClassicDeckChoiceView.swift
//  NTCGSimulator
//
//  Classic runs on two fixed decks rather than anything the player built, so
//  the only decision here is which of the two boxes both sides will play.
//

import SwiftUI

// MARK: - Classic deck choice

/// The red-or-blue choice that starts a Classic game.
///
/// Both sides are dealt the same fixed list, so the only thing left to settle
/// is who plays the other seat — which is why the chosen `PlayMode` is carried
/// through from the format screen rather than being assumed here.
struct ClassicDeckChoiceView: View {
    @Environment(Router.self) private var router
    @Environment(CardDatabase.self) private var database

    /// Who occupies the opposing seat, chosen back on the Play screen.
    let mode: PlayMode

    /// Classic ships as a red box and a blue box; green has no fixed list.
    private let colors: [CardColor] = [.red, .blue]

    /// Wide enough for a `.small` card face to sit beside the copy.
    private static let thumbnailWidth = Metrics.controlHeight * 1.4

    var body: some View {
        ScreenScaffold(
            title: "Choose the deck for both sides",
            subtitle: "This format runs on two fixed decks. Pick one.",
            onBack: { router.pop() }
        ) {
            ScrollView {
                VStack(alignment: .leading, spacing: Metrics.spacingM) {
                    ForEach(colors) { color in
                        deckPanel(for: color)
                    }

                    formatNote
                }
                .padding(.bottom, Metrics.spacingXL)
            }
            .scrollIndicators(.hidden)
        }
    }

    // MARK: Panels

    private func deckPanel(for color: CardColor) -> some View {
        // Resolved once and handed to both the pill and the spoken label:
        // building the fixed list is cheap, but doing it twice for the same
        // panel would be careless.
        let answers = answerCount(for: color)

        return Button {
            start(with: color)
        } label: {
            HStack(alignment: .top, spacing: Metrics.spacingM) {
                thumbnail(for: color)
                    .frame(width: Self.thumbnailWidth)

                VStack(alignment: .leading, spacing: Metrics.spacingXS) {
                    Text("\(color.title) deck")
                        .font(Typeface.display(17))
                        .tracking(1.6)
                        .textCase(.uppercase)
                        .foregroundStyle(Palette.textPrimary)

                    Text(subtitle(for: color))
                        .font(Typeface.body(14))
                        .foregroundStyle(Palette.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)

                    HStack(spacing: Metrics.spacingXS) {
                        CountPill(label: "Cards", value: "\(GameFormat.classic.deckSize)")
                        CountPill(label: "Answers", value: "\(answers)")
                    }
                    .padding(.top, Metrics.spacingXS)
                }

                Spacer(minLength: 0)

                Image(systemName: "chevron.right")
                    .font(Typeface.label(13))
                    .foregroundStyle(color.tint)
            }
            .padding(Metrics.spacingM)
            .frame(maxWidth: .infinity, alignment: .leading)
            .notchedPanel(
                fill: color.deepTint.opacity(0.45),
                stroke: color.tint.opacity(0.8)
            )
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
        .accessibilityLabel(label(for: color, answers: answers))
    }

    private func label(for color: CardColor, answers: Int) -> String {
        let answered = answers == 0
            ? "no cards to answer a response window with"
            : "\(answers) cards to answer a response window with"
        return "\(color.title) deck. \(subtitle(for: color)) "
             + "\(GameFormat.classic.deckSize) cards, \(answered)."
    }

    /// The Leader that fronts a box, or a card back if the pool has none in
    /// that colour after an import.
    @ViewBuilder
    private func thumbnail(for color: CardColor) -> some View {
        if let leader = leader(for: color) {
            CardFaceView(card: leader, size: .small)
        } else {
            CardBackView(tint: color.tint)
        }
    }

    private var formatNote: some View {
        VStack(alignment: .leading, spacing: Metrics.spacingS) {
            Text("About Classic").sectionLabel()

            Text("Both sides are dealt the same fixed list, so the game turns on "
                 + "draws and decisions rather than deck building.")
                .font(Typeface.body(14))
                .foregroundStyle(Palette.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(Metrics.spacingM)
        .notchedPanel()
        .accessibilityElement(children: .combine)
    }

    // MARK: Data

    private func leader(for color: CardColor) -> Card? {
        database.leaders.first { $0.color == color }
    }

    private func subtitle(for color: CardColor) -> String {
        if let leader = leader(for: color) {
            return "Led by \(leader.name)."
        }
        return "The fixed \(color.title.lowercased()) list."
    }

    /// Cards in the box that print a SUPPORT bar, and so can be set face-down to
    /// answer a response window.
    ///
    /// The list is generated rather than saved, so it is resolved through the
    /// same `GameSetup.generatedList` the game itself will use — asking the
    /// screen to count a different list from the one that gets dealt would be
    /// worse than not counting at all.
    private func answerCount(for color: CardColor) -> Int {
        GameSetup
            .generatedList(color: color, size: GameFormat.classic.deckSize, database: database)
            .cards
            .reduce(0) { $0 + (database.card(id: $1)?.canSetAsSupport == true ? 1 : 0) }
    }

    // MARK: Routing

    private func start(with color: CardColor) {
        router.push(.game(GameConfiguration(
            mode: mode,
            format: .classic,
            playerDeckID: nil,
            opponentDeckID: nil,
            fixedDeckColor: color
        )))
    }
}

// MARK: - Preview

#Preview {
    NavigationStack {
        ClassicDeckChoiceView(mode: .versusAI)
    }
    .environment(Router())
    .environment(CardDatabase())
}
