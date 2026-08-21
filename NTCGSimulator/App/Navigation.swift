//
//  Navigation.swift
//  NTCGSimulator
//
//  Every destination in the app, and the path that drives them.
//

import SwiftUI

/// A screen reachable from the main menu.
enum Route: Hashable {
    case play
    case playMode(PlayMode)
    case classicDeckChoice(PlayMode)
    case vanillaDeckChoice(PlayMode)
    case game(GameConfiguration)

    case deckBuilder
    case deckEditor(UUID?)          // nil starts a new deck

    case collection
    case cardDetail(String)         // collector number

    case settings
    case legal

    // Not built in this version — these show the "coming soon" panel.
    case sealed
    case leaderboard
    case tournaments
    case online
}

/// Which kind of opponent sits on the other side of the board.
enum PlayMode: String, Hashable, Codable, CaseIterable {
    case online
    case versusAI
    case soloVersusSelf

    var title: String {
        switch self {
        case .online:         return "Play Online"
        case .versusAI:       return "Play Against the AI"
        case .soloVersusSelf: return "Solo v Self"
        }
    }

    var detail: String {
        switch self {
        case .online:         return "Find an opponent and play a ranked game."
        case .versusAI:       return "Play against the computer."
        case .soloVersusSelf: return "Play both sides yourself."
        }
    }
}

/// The two supported formats.
enum GameFormat: String, Hashable, Codable, CaseIterable {
    case classic
    case vanilla

    var title: String {
        switch self {
        case .classic: return "Classic"
        case .vanilla: return "Vanilla format"
        }
    }

    var detail: String {
        switch self {
        case .classic: return "The 30 card game on two fixed decks."
        case .vanilla: return "The 50 card game with any of your decks."
        }
    }

    var deckSize: Int {
        switch self {
        case .classic: return DeckRules.classicSize
        case .vanilla: return DeckRules.requiredSize
        }
    }
}

/// Everything needed to start a game.
struct GameConfiguration: Hashable, Codable {
    var mode: PlayMode
    var format: GameFormat

    /// Deck for the near side. `nil` means "use the format's fixed deck".
    var playerDeckID: UUID?

    /// Deck for the far side.
    var opponentDeckID: UUID?

    /// For Classic, which of the two fixed decks was chosen.
    var fixedDeckColor: CardColor?
}

// MARK: - Router

/// Owns the navigation path so any screen can push or pop without threading
/// bindings through every view.
@Observable
final class Router {
    var path: [Route] = []

    func push(_ route: Route) {
        path.append(route)
    }

    func pop() {
        guard !path.isEmpty else { return }
        path.removeLast()
    }

    /// Returns to the main menu.
    func popToRoot() {
        path.removeAll()
    }
}
