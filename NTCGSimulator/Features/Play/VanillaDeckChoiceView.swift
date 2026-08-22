//
//  VanillaDeckChoiceView.swift
//  NTCGSimulator
//
//  Last step of the Play flow for Vanilla: pick which deck takes the board.
//  Only decks that pass construction are offered, so an illegal deck can never
//  reach the game screen — and the ready-made decks are offered alongside them,
//  because "build fifty cards first" is no way to start a first game.
//

import SwiftUI

// MARK: - Vanilla deck choice

/// Deck chooser for the 50-card format.
struct VanillaDeckChoiceView: View {
    /// The opponent chosen two screens back. It decides whether the far side
    /// mirrors this deck or is left for the game to fill in.
    let mode: PlayMode

    @Environment(Router.self) private var router
    @Environment(CardDatabase.self) private var database
    @Environment(DeckStore.self) private var decks

    var body: some View {
        ScreenScaffold(
            title: "Choose your deck",
            subtitle: subtitle,
            onBack: { router.pop() }
        ) {
            ScrollView {
                VStack(alignment: .leading, spacing: Metrics.spacingM) {
                    if playableDecks.isEmpty {
                        emptyState
                    } else {
                        deckList
                    }

                    starterList
                }
                .padding(.bottom, Metrics.spacingXL)
            }
            .scrollIndicators(.hidden)
        }
    }

    // MARK: Sections

    private var deckList: some View {
        VStack(alignment: .leading, spacing: Metrics.spacingM) {
            Text("Legal decks").sectionLabel()

            ForEach(playableDecks) { entry in
                VanillaDeckRow(deck: entry.deck, leader: entry.leader, answers: entry.answers) {
                    start(with: entry.deck)
                }
            }
        }
    }

    /// The ready-made decks, offered whether or not the player has decks of
    /// their own — on a fresh install they are the only way to start a game
    /// without a detour through the builder.
    @ViewBuilder
    private var starterList: some View {
        if !starters.isEmpty {
            VStack(alignment: .leading, spacing: Metrics.spacingM) {
                Text("Ready-made decks").sectionLabel()

                Text("Built from your card pool. Picking one saves a copy to your decks, "
                     + "so you can edit it later in the Deck Builder.")
                    .font(Typeface.body(13))
                    .foregroundStyle(Palette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)

                ForEach(starters) { entry in
                    VanillaDeckRow(
                        deck: entry.deck,
                        leader: entry.leader,
                        answers: entry.answers,
                        isReadyMade: true
                    ) {
                        start(withReadyMade: entry.deck)
                    }
                }
            }
        }
    }

    /// Shown when nothing in the store passes `isLegal`, which is the normal
    /// state on a fresh install. The ready-made list sits underneath it, so this
    /// explains the gap rather than closing the screen off.
    private var emptyState: some View {
        VStack(spacing: Metrics.spacingM) {
            EmptyStatePanel(
                headline: "No decks of your own",
                message: "Vanilla needs a deck of exactly \(DeckRules.requiredSize) cards, "
                       + "every one of them matching its Leader's colour. Take a ready-made "
                       + "deck below to start now, or build your own and it will appear here."
            )

            WideButton(title: "Go to Deck Builder") {
                router.push(.deckBuilder)
            }
        }
    }

    // MARK: Data

    /// Legal decks paired with their resolved Leader, so the rows never have to
    /// deal with a missing card.
    private var playableDecks: [PlayableDeck] {
        decks.decks.compactMap { deck in
            guard
                deck.isLegal(using: database),
                let leader = database.card(id: deck.leaderID)
            else { return nil }
            return PlayableDeck(deck: deck, leader: leader, answers: answerCount(in: deck))
        }
    }

    /// Ready-made decks in the same shape as the saved ones.
    private var starters: [PlayableDeck] {
        StarterDecks.all(using: database).compactMap { deck in
            guard let leader = database.card(id: deck.leaderID) else { return nil }
            return PlayableDeck(deck: deck, leader: leader, answers: answerCount(in: deck))
        }
    }

    /// Cards in a deck printing a SUPPORT bar.
    ///
    /// Only those can be set face-down, and only a face-down card can answer a
    /// response window — so this is the count of answers the deck takes into the
    /// game, and the one thing about a deck list worth knowing before the game
    /// starts that the card count does not already say.
    private func answerCount(in deck: Deck) -> Int {
        deck.cardIDs.reduce(0) { $0 + (database.card(id: $1)?.canSetAsSupport == true ? 1 : 0) }
    }

    private var subtitle: String {
        mode == .soloVersusSelf
            ? "Both sides play the deck you pick."
            : "Pick the deck you will take into the game."
    }

    // MARK: Routing

    /// Solo play needs a deck on both sides of the board; against anyone else
    /// the far side is not ours to choose.
    private func start(with deck: Deck) {
        router.push(.game(GameConfiguration(
            mode: mode,
            format: .vanilla,
            playerDeckID: deck.id,
            opponentDeckID: mode == .soloVersusSelf ? deck.id : nil,
            fixedDeckColor: nil
        )))
    }

    /// Starts a game on a ready-made deck.
    ///
    /// The game resolves its list out of the store by id, so the starter has to
    /// be saved before it can be played. An identical copy already in the store
    /// is reused rather than piling up a new deck every time the player picks
    /// the same starter.
    private func start(withReadyMade starter: Deck) {
        if let existing = savedCopy(of: starter) {
            start(with: existing)
            return
        }
        let copy = StarterDecks.playerCopy(of: starter)
        decks.save(copy)
        start(with: copy)
    }

    /// A deck already saved that is this starter, card for card.
    private func savedCopy(of starter: Deck) -> Deck? {
        decks.decks.first {
            $0.name == starter.name
                && $0.leaderID == starter.leaderID
                && $0.cardIDs == starter.cardIDs
        }
    }
}

// MARK: - Row

/// A deck plus the Leader it is built around and the answers it carries.
private struct PlayableDeck: Identifiable {
    let deck: Deck
    let leader: Card

    /// Cards printing a SUPPORT bar — see `answerCount(in:)`.
    let answers: Int

    var id: UUID { deck.id }
}

/// One selectable deck: colour bar, Leader face, name, size and answers.
private struct VanillaDeckRow: View {
    let deck: Deck
    let leader: Card

    /// Cards in the list that print a SUPPORT bar, and so can be set face-down
    /// to answer a response window. A deck carrying none is legal and playable,
    /// but it can never answer anything and its chakra has nothing to buy — so
    /// the count is shown before the game rather than discovered during it.
    let answers: Int

    /// Marks the row as one of the app's decks rather than the player's, which
    /// changes the keyline and adds a badge — the choice it offers is the same.
    var isReadyMade: Bool = false

    let action: () -> Void

    /// A tiny face is about two thirds of a control tall.
    private static let thumbnailWidth = Metrics.controlHeight * 0.62

    var body: some View {
        Button(action: action) {
            HStack(spacing: Metrics.spacingM) {
                Rectangle()
                    .fill(leader.color.tint)
                    .frame(width: Metrics.spacingXS)

                CardFaceView(card: leader, size: .tiny)
                    .frame(width: Self.thumbnailWidth)
                    .padding(.vertical, Metrics.spacingS)

                VStack(alignment: .leading, spacing: 2) {
                    Text(deck.name)
                        .font(Typeface.display(15, weight: .bold))
                        .foregroundStyle(Palette.textPrimary)
                        .lineLimit(1)

                    Text("\(leader.name) · \(leader.color.title)")
                        .font(Typeface.body(12))
                        .foregroundStyle(Palette.textSecondary)
                        .lineLimit(1)

                    if isReadyMade { readyMadeBadge }
                }

                Spacer(minLength: 0)

                CountPill(label: "Cards", value: "\(deck.count)")
                CountPill(label: "Answers", value: "\(answers)")
                    .opacity(answers == 0 ? 0.7 : 1)

                Image(systemName: "chevron.right")
                    .font(Typeface.label(12))
                    .foregroundStyle(Palette.accent)
            }
            .padding(.trailing, Metrics.spacingM)
            .frame(maxWidth: .infinity, alignment: .leading)
            .frame(minHeight: Metrics.controlHeight + Metrics.spacingM)
            .notchedPanel(stroke: isReadyMade ? Palette.accent.opacity(0.5) : Palette.border)
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
        .accessibilityLabel(label)
    }

    private var readyMadeBadge: some View {
        Text("Ready-made")
            .font(Typeface.label(9))
            .tracking(1)
            .textCase(.uppercase)
            .foregroundStyle(Palette.accent)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .notchedPanel(
                notch: 4,
                corners: .diagonal,
                fill: Palette.accent.opacity(0.16),
                stroke: Palette.accent.opacity(0.6)
            )
            .padding(.top, 2)
    }

    private var label: String {
        let kind = isReadyMade ? "Ready-made deck " : ""
        let answered = answers == 0
            ? "no cards to answer a response window with"
            : "\(answers) cards to answer a response window with"
        return "\(kind)\(deck.name), led by \(leader.name), \(deck.count) cards, \(answered)"
    }
}

// MARK: - Previews

#Preview("Ready-made decks only") {
    NavigationStack {
        VanillaDeckChoiceView(mode: .soloVersusSelf)
    }
    .environment(Router())
    .environment(CardDatabase())
    .environment(DeckStore())
}

#Preview("Deck rows") {
    let database = CardDatabase()

    if let leader = database.leaders.first {
        let built = Deck(
            name: "Hidden Leaf aggro",
            leaderID: leader.id,
            cardIDs: Array(
                database.cardsPlayable(with: leader)
                    .flatMap { Array(repeating: $0.id, count: DeckRules.maxCopies) }
                    .prefix(DeckRules.requiredSize)
            )
        )

        VStack(spacing: Metrics.spacingM) {
            VanillaDeckRow(
                deck: built,
                leader: leader,
                answers: deckChoicePreviewAnswers(in: built, using: database)
            ) { }

            if let starter = StarterDecks.all(using: database).first,
               let starterLeader = database.card(id: starter.leaderID) {
                VanillaDeckRow(
                    deck: starter,
                    leader: starterLeader,
                    answers: deckChoicePreviewAnswers(in: starter, using: database),
                    isReadyMade: true
                ) { }
            }
        }
        .padding(Metrics.spacingL)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Palette.backdrop)
        .environment(database)
    }
}

/// The screen's own answer count, repeated for the row preview — which builds
/// its decks by hand and so has no screen to ask.
private func deckChoicePreviewAnswers(in deck: Deck, using database: CardDatabase) -> Int {
    deck.cardIDs.reduce(0) { $0 + (database.card(id: $1)?.canSetAsSupport == true ? 1 : 0) }
}
