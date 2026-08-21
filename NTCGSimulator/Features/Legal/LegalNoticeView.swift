//
//  LegalNoticeView.swift
//  NTCGSimulator
//
//  The unofficial-project notice.
//
//  This is a fan-built simulator. Saying so plainly, and saying who actually
//  owns the game, is the honest thing to do and is also what keeps a project
//  like this tolerable to the rights holder.
//

import SwiftUI

struct LegalNoticeView: View {
    @Environment(Router.self) private var router
    @Environment(CardDatabase.self) private var database

    var body: some View {
        ScreenScaffold(
            title: "Legal notice",
            subtitle: "What this app is, and what it is not.",
            onBack: { router.pop() }
        ) {
            ScrollView {
                VStack(alignment: .leading, spacing: Metrics.spacingL) {
                    ForEach(Self.sections) { section in
                        LegalSection(section: section)
                    }

                    cardDataStatus

                    Spacer(minLength: Metrics.spacingXL)
                }
                .padding(.bottom, Metrics.spacingL)
            }
            .scrollIndicators(.hidden)
        }
    }

    // MARK: - Card data status

    /// States plainly where the card pool currently comes from, because the
    /// answer changes once a player imports their own.
    private var cardDataStatus: some View {
        VStack(alignment: .leading, spacing: Metrics.spacingS) {
            Text("Card data on this device").sectionLabel()

            Text(database.usingImportedData
                 ? "You have imported your own card data — \(database.cards.count) cards. "
                   + "Whatever you imported is yours to account for; it did not come with the app."
                 : "You are using the demo card set that ships with the app — "
                   + "\(database.cards.count) cards. Its stats and rules text were written "
                   + "for this project, and every card is drawn with generated art.")
                .font(Typeface.body(14))
                .foregroundStyle(Palette.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(Metrics.spacingM)
        .notchedPanel()
    }

    // MARK: - Content

    /// One block of the notice.
    struct Section: Identifiable {
        let id = UUID()
        let heading: String
        let body: String
    }

    private static let sections: [Section] = [
        Section(
            heading: "Unofficial",
            body: "This is an unofficial, fan-made simulator. It is not affiliated with, "
                + "endorsed by, sponsored by, or connected to the publisher of the card "
                + "game it simulates, or to any rights holder in the underlying series."
        ),
        Section(
            heading: "Trademarks and copyright",
            body: "All game names, card names, characters and related marks belong to their "
                + "respective owners. They are referred to here only to describe what this "
                + "simulator plays, which is a descriptive use and claims no ownership."
        ),
        Section(
            heading: "Artwork",
            body: "No card artwork is distributed with this app. Cards are drawn from "
                + "illustrations generated at runtime from each card's own values. If you "
                + "install your own images, they stay on your device — they are never "
                + "bundled into the app and never uploaded anywhere."
        ),
        Section(
            heading: "Rules",
            body: "The official rulebook for this game is not public. The rules implemented "
                + "here follow what has been shown publicly and are a best effort, not an "
                + "authority. Expect them to be corrected as official rules are published, "
                + "and do not treat this app as a reference for tournament play."
        ),
        Section(
            heading: "No warranty",
            body: "This software is provided as-is, without warranty of any kind. It is a "
                + "hobby project for playing games against yourself and a computer opponent."
        ),
    ]
}

// MARK: - Section view

private struct LegalSection: View {
    let section: LegalNoticeView.Section

    var body: some View {
        VStack(alignment: .leading, spacing: Metrics.spacingS) {
            Text(section.heading).sectionLabel()

            Text(section.body)
                .font(Typeface.body(14))
                .foregroundStyle(Palette.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(Metrics.spacingM)
        .notchedPanel()
    }
}

#Preview {
    NavigationStack {
        LegalNoticeView()
    }
    .environment(Router())
    .environment(CardDatabase())
}
