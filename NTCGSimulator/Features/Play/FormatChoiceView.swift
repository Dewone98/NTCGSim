//
//  FormatChoiceView.swift
//  NTCGSimulator
//
//  Second step of the Play flow: Classic on two fixed decks, or Vanilla on a
//  deck the player built. The chosen mode is carried through to the Vanilla
//  route because it decides who holds the second deck.
//

import SwiftUI

// MARK: - Format choice

/// Format chooser for a given `PlayMode`.
struct FormatChoiceView: View {
    /// The opponent chosen on the previous screen, passed on to Vanilla.
    let mode: PlayMode

    @Environment(Router.self) private var router
    @Environment(CardDatabase.self) private var database

    /// Wide enough for a `.small` card face to stay readable beside the copy.
    private static let thumbnailWidth = Metrics.controlHeight * 1.4

    var body: some View {
        ScreenScaffold(
            title: mode.title,
            subtitle: mode.detail,
            onBack: { router.pop() }
        ) {
            ScrollView {
                VStack(alignment: .leading, spacing: Metrics.spacingM) {
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

// MARK: - Preview

#Preview {
    NavigationStack {
        FormatChoiceView(mode: .versusAI)
    }
    .environment(Router())
    .environment(CardDatabase())
}
