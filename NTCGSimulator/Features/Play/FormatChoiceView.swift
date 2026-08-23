//
//  FormatChoiceView.swift
//  NTCGSimulator
//
//  Second step of the Play flow: Classic on two fixed decks, or Vanilla on a
//  deck the player built. The chosen mode is carried through to the Vanilla
//  route because it decides who holds the second deck.
//
//  It is also the last screen before a game against the computer, which is why
//  the AI difficulty is offered here as well as in Settings: the strength of
//  the opponent is a decision about the game you are about to play, and burying
//  it behind the menu means it is only ever found after losing to kage.
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

                    Text("Format").sectionLabel()

                    ForEach(GameFormat.allCases, id: \.self) { format in
                        formatPanel(for: format)
                    }
                }
                .padding(.bottom, Metrics.spacingXL)
            }
            .scrollIndicators(.hidden)
        }
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
