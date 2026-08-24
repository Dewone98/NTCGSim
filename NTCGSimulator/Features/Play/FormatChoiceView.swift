//
//  FormatChoiceView.swift
//  NTCGSimulator
//
//  Second step of the Play flow: Classic on two fixed decks, or Vanilla on a
//  deck the player built. The chosen mode is carried through to the Vanilla
//  route because it decides who holds the second deck.
//
//  It is also the last screen before a game, which is why two decisions about
//  the game itself are made here rather than in Settings: how hard the computer
//  plays, and what the soundtrack is. Both are answers to "what do I want from
//  the match I am about to start", and both are only ever found after the fact
//  when they are buried behind the menu — the difficulty after losing to kage,
//  and the music after playing a whole game in silence.
//
//  The music choice belongs here for a second reason as well: the soundtrack
//  exists only while the board is on screen, so this is the last moment at
//  which the question can be asked of a player who is about to hear the answer.
//

import SwiftUI

// MARK: - Format choice

/// Format chooser for a given `PlayMode`.
struct FormatChoiceView: View {
    /// The opponent chosen on the previous screen, passed on to Vanilla.
    let mode: PlayMode

    @Environment(Router.self) private var router
    @Environment(CardDatabase.self) private var database
    @Environment(SettingsStore.self) private var settings

    /// The app's one music player, read here only for its library — the list of
    /// tracks to offer. Starting and stopping is the board's job entirely.
    private let music = MusicPlayer.shared

    /// Wide enough for a `.small` card face to stay readable beside the copy.
    private static let thumbnailWidth = Metrics.controlHeight * 1.4

    var body: some View {
        @Bindable var settings = settings

        ScreenScaffold(
            title: mode.title,
            subtitle: mode.detail,
            onBack: { router.pop() }
        ) {
            ScrollView {
                VStack(alignment: .leading, spacing: Metrics.spacingM) {
                    if mode == .versusAI {
                        difficultyPanel(selection: $settings.aiDifficulty)
                    }

                    musicPanel(selection: $settings.musicSelection)

                    Text("Format").sectionLabel()

                    ForEach(GameFormat.allCases, id: \.self) { format in
                        formatPanel(for: format)
                    }
                }
                .padding(.bottom, Metrics.spacingXL)
            }
            .scrollIndicators(.hidden)
        }
        .onAppear { reconcileMusicChoice() }
    }

    // MARK: Difficulty

    /// The opponent's strength, shown as it stands and changeable in place.
    ///
    /// It is seeded from the saved setting and writes straight back to it
    /// rather than being carried in `GameConfiguration`, so there is exactly
    /// one answer to "how hard is the AI" — the board reads the same setting.
    /// Only Classic and Vanilla against the computer see it; Solo v Self has no
    /// opponent to tune.
    private func difficultyPanel(selection: Binding<AIDifficulty>) -> some View {
        VStack(alignment: .leading, spacing: Metrics.spacingS) {
            Text("AI difficulty").sectionLabel()

            // Horizontally scrollable so four chips still fit on a 393pt phone
            // once the type scales up, rather than being squeezed or clipped.
            ScrollView(.horizontal, showsIndicators: false) {
                OptionPicker(
                    options: AIDifficulty.allCases.map { (value: $0, title: $0.title) },
                    selection: selection
                )
                .padding(.vertical, Metrics.spacingXS)
            }

            Text(selection.wrappedValue.detail)
                .font(Typeface.body(14))
                .foregroundStyle(Palette.textSecondary)
                .fixedSize(horizontal: false, vertical: true)

            Text("This is the same setting the Settings screen holds, so it stays "
                 + "chosen for your next game too.")
                .font(Typeface.body(12))
                .foregroundStyle(Palette.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(Metrics.spacingM)
        .notchedPanel()
    }

    // MARK: Music

    /// What the game about to start sounds like: the four shipped tracks by
    /// name, Shuffle, and Off.
    ///
    /// Built from the same chip row as the difficulty above it so the two read
    /// as one column of "settings for this match", and scrollable sideways for
    /// the same reason — six labels, one of them a song title, never fit across
    /// a 393pt phone once the type scales. The choice writes straight to
    /// `SettingsStore`, so it is remembered for the next game as well.
    private func musicPanel(selection: Binding<MusicSelection>) -> some View {
        VStack(alignment: .leading, spacing: Metrics.spacingS) {
            Text("Music").sectionLabel()

            if music.library.isEmpty {
                Text("This build shipped without any music, so the board stays quiet.")
                    .font(Typeface.body(14))
                    .foregroundStyle(Palette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    OptionPicker(options: musicOptions, selection: selection)
                        .padding(.vertical, Metrics.spacingXS)
                }

                Text(musicDetail(for: selection.wrappedValue))
                    .font(Typeface.body(14))
                    .foregroundStyle(Palette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)

                Text("It plays only while the board is on screen and stops when you "
                     + "leave, and it stays chosen for your next game. How loud it is "
                     + "lives in Settings.")
                    .font(Typeface.body(12))
                    .foregroundStyle(Palette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(Metrics.spacingM)
        .notchedPanel()
    }

    /// Off, Shuffle, then every track by name — the order a player looks for
    /// them in, with the two modes first because they are what most people pick.
    private var musicOptions: [(value: MusicSelection, title: String)] {
        [(value: MusicSelection.off, title: "Off"),
         (value: MusicSelection.shuffle, title: "Shuffle")]
        + music.library.tracks.map { (value: MusicSelection.track(id: $0.id), title: $0.title) }
    }

    /// The line under the chips, which is where the difference between the
    /// modes is actually explained — "Shuffle" and a song title look alike as
    /// labels and do quite different things.
    private func musicDetail(for selection: MusicSelection) -> String {
        switch selection {
        case .off:
            return "No music. Card, turn and effect sounds are unaffected."
        case .shuffle:
            return "A different track each time one ends, faded from one into the next."
        case .track(let id):
            let name = music.library.track(id: id)?.title ?? "The chosen track"
            return "\(name), on repeat for the whole game."
        }
    }

    /// Re-reads the music folder, and repairs a choice that is no longer there.
    ///
    /// A track is remembered by filename, so one renamed or removed between
    /// games would otherwise leave the row with nothing selected and the board
    /// silent for a reason nothing on screen explains. Shuffle is the repair
    /// because the game ships its own tracks — there is always something to
    /// play — and Off only when the build genuinely has none.
    private func reconcileMusicChoice() {
        music.refreshLibrary()

        guard case .track(let id) = settings.musicSelection,
              music.library.track(id: id) == nil
        else { return }

        settings.musicSelection = music.library.isEmpty ? .off : .shuffle
    }

    // MARK: Panels

    private func formatPanel(for format: GameFormat) -> some View {
        Button {
            router.push(destination(for: format))
        } label: {
            HStack(alignment: .top, spacing: Metrics.spacingM) {
                thumbnail(for: format)
                    .frame(width: Self.thumbnailWidth)

                VStack(alignment: .leading, spacing: Metrics.spacingXS) {
                    Text(format.title)
                        .font(Typeface.display(17))
                        .tracking(1.6)
                        .textCase(.uppercase)
                        .foregroundStyle(Palette.textPrimary)

                    Text(format.detail)
                        .font(Typeface.body(14))
                        .foregroundStyle(Palette.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)

                    CountPill(label: "Deck", value: "\(format.deckSize)")
                        .padding(.top, Metrics.spacingXS)
                }

                Spacer(minLength: 0)

                Image(systemName: "chevron.right")
                    .font(Typeface.label(13))
                    .foregroundStyle(Palette.accent)
            }
            .padding(Metrics.spacingM)
            .frame(maxWidth: .infinity, alignment: .leading)
            .notchedPanel()
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
        .accessibilityLabel("\(format.title). \(format.detail) \(format.deckSize) cards per deck.")
    }

    /// A face from the pool so each panel is recognisable at a glance. Falls
    /// back to a card back when the pool holds no Leaders, which happens if an
    /// import replaced the bundled set with something incomplete.
    @ViewBuilder
    private func thumbnail(for format: GameFormat) -> some View {
        if let leader = representativeLeader(for: format) {
            CardFaceView(card: leader, size: .small)
        } else {
            CardBackView()
        }
    }

    // MARK: Data

    /// Classic is shown by its red box, Vanilla by a different colour, so the
    /// two panels never illustrate themselves with the same card.
    private func representativeLeader(for format: GameFormat) -> Card? {
        let leaders = database.leaders
        switch format {
        case .classic: return leaders.first { $0.color == .red } ?? leaders.first
        case .vanilla: return leaders.first { $0.color == .blue } ?? leaders.last
        }
    }

    // MARK: Routing

    private func destination(for format: GameFormat) -> Route {
        switch format {
        case .classic: return .classicDeckChoice(mode)
        case .vanilla: return .vanillaDeckChoice(mode)
        }
    }
}

// MARK: - Previews

#Preview("Against the AI") {
    NavigationStack {
        FormatChoiceView(mode: .versusAI)
    }
    .environment(Router())
    .environment(CardDatabase())
    .environment(SettingsStore())
}

#Preview("Solo — no difficulty panel") {
    NavigationStack {
        FormatChoiceView(mode: .soloVersusSelf)
    }
    .environment(Router())
    .environment(CardDatabase())
    .environment(SettingsStore())
}
