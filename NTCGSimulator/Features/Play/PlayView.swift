//
//  PlayView.swift
//  NTCGSimulator
//
//  The first step into a game: choose who sits on the other side of the board.
//  Online is routed to the coming-soon panel; the two offline modes carry on to
//  the format chooser.
//

import SwiftUI

// MARK: - Play

/// Opponent chooser for the Play flow.
struct PlayView: View {
    @Environment(Router.self) private var router

    var body: some View {
        ScreenScaffold(
            title: "Play",
            subtitle: "A playable prototype built on the rules known so far.",
            onBack: { router.pop() }
        ) {
            ScrollView {
                VStack(alignment: .leading, spacing: Metrics.spacingL) {
                    modeList
                    rulesNote
                }
                .padding(.bottom, Metrics.spacingXL)
            }
            .scrollIndicators(.hidden)
        }
    }

    // MARK: Sections

    private var modeList: some View {
        VStack(alignment: .leading, spacing: Metrics.spacingM) {
            Text("Opponent").sectionLabel()

            ForEach(PlayMode.allCases, id: \.self) { mode in
                modeRow(for: mode)
            }
        }
    }

    /// A tile plus the mode's own one-line explanation, so the choice can be
    /// made without pushing a screen to find out what it means.
    private func modeRow(for mode: PlayMode) -> some View {
        VStack(alignment: .leading, spacing: Metrics.spacingXS) {
            MenuTile(
                title: mode.title,
                badge: badge(for: mode),
                isPrimary: mode == .versusAI
            ) {
                router.push(destination(for: mode))
            }

            Text(mode.detail)
                .font(Typeface.body(13))
                .foregroundStyle(Palette.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.leading, Metrics.spacingXS)
        }
    }

    /// The standing caveat about the rules. It sits under the modes rather than
    /// in the subtitle because it applies to every game the app can run.
    private var rulesNote: some View {
        VStack(alignment: .leading, spacing: Metrics.spacingS) {
            Text("Rules in progress").sectionLabel()

            Text("The official rulebook is not out. Combat, chakra and summoning "
                 + "follow what has been shown publicly, and will be corrected "
                 + "when the rules are published.")
                .font(Typeface.body(14))
                .foregroundStyle(Palette.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(Metrics.spacingM)
        .notchedPanel()
        .accessibilityElement(children: .combine)
    }

    // MARK: Routing

    /// Online has no matchmaking in this build, so it lands on the coming-soon
    /// screen instead of the format chooser.
    private func destination(for mode: PlayMode) -> Route {
        switch mode {
        case .online:                    return .online
        case .versusAI, .soloVersusSelf: return .playMode(mode)
        }
    }

    private func badge(for mode: PlayMode) -> String? {
        mode == .online ? "Soon" : nil
    }
}

// MARK: - Preview

#Preview {
    NavigationStack {
        PlayView()
    }
    .environment(Router())
}
