//
//  ComingSoonView.swift
//  NTCGSimulator
//
//  The placeholder screen behind the routes this build does not implement —
//  Sealed, Leaderboard, Tournaments and online play.
//

import SwiftUI

/// A screen that owns a route but has nothing behind it yet. It says so plainly
/// and offers the way back, rather than dead-ending the player on a blank page.
struct ComingSoonView: View {

    /// Shown as the screen heading, so the player can see which menu entry they
    /// arrived from.
    let title: String

    /// Overridden where a route needs to explain *why* it is missing.
    var message: String = "This part of the simulator is not built yet. It will be added later."

    @Environment(Router.self) private var router

    var body: some View {
        ScreenScaffold(title: title) {
            VStack(spacing: Metrics.spacingL) {
                EmptyStatePanel(headline: "Coming soon", message: message)

                WideButton(title: "Back to the menu", style: .primary) {
                    router.popToRoot()
                }

                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity)
            .padding(.top, Metrics.spacingM)
        }
    }
}

// MARK: - Previews

#Preview("Default message") {
    NavigationStack {
        ComingSoonView(title: "Sealed")
    }
    .environment(Router())
    .environment(CardDatabase())
    .environment(SettingsStore())
    .tint(Palette.accent)
    .preferredColorScheme(.dark)
}

#Preview("Custom message") {
    NavigationStack {
        ComingSoonView(
            title: "Play Online",
            message: "Online play needs an account and a matchmaking server. It is not part of this build."
        )
    }
    .environment(Router())
    .environment(CardDatabase())
    .environment(SettingsStore())
    .tint(Palette.accent)
    .preferredColorScheme(.dark)
}
