//
//  RootView.swift
//  NTCGSimulator
//
//  Hosts the navigation stack and resolves each route to its screen.
//

import SwiftUI

struct RootView: View {
    @State private var router = Router()
    @State private var database = CardDatabase()
    @State private var decks = DeckStore()
    @State private var settings = SettingsStore()

    var body: some View {
        NavigationStack(path: $router.path) {
            HomeView()
                .navigationDestination(for: Route.self) { route in
                    destination(for: route)
                }
        }
        .environment(router)
        .environment(database)
        .environment(decks)
        .environment(settings)
        .preferredColorScheme(settings.appearance.colorScheme)
        .tint(Palette.accent)
    }

    @ViewBuilder
    private func destination(for route: Route) -> some View {
        switch route {
        case .play:
            PlayView()

        case .playMode(let mode):
            FormatChoiceView(mode: mode)

        case .classicDeckChoice(let mode):
            ClassicDeckChoiceView(mode: mode)

        case .vanillaDeckChoice(let mode):
            VanillaDeckChoiceView(mode: mode)

        case .game(let configuration):
            GameBoardView(configuration: configuration)

        case .deckBuilder:
            DeckBuilderView()

        case .deckEditor(let id):
            DeckEditorView(deckID: id)

        case .collection:
            CollectionView()

        case .cardDetail(let cardID):
            CardDetailView(cardID: cardID)

        case .settings:
            SettingsView()

        case .legal:
            LegalNoticeView()

        case .sealed:
            ComingSoonView(title: "Sealed")

        case .leaderboard:
            ComingSoonView(title: "Leaderboard")

        case .tournaments:
            ComingSoonView(title: "Tournaments")

        case .online:
            ComingSoonView(
                title: "Play Online",
                message: "Online play needs an account and a matchmaking server. It is not part of this build."
            )
        }
    }
}
