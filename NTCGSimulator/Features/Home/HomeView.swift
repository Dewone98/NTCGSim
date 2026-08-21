//
//  HomeView.swift
//  NTCGSimulator
//
//  The main menu. Reproduces the site's landing page: brand bar with a theme
//  toggle, a hero backed by a featured Leader, the tile menu that reaches every
//  part of the app, and the footer.
//

import SwiftUI

// MARK: - Layout constants

/// Layout values only the main menu needs. Anything reused by another screen
/// belongs in `Metrics` instead, not here.
private enum HomeMetrics {

    /// The smallest comfortable tap target; the icon-only controls are sized to it.
    static let tapTarget: CGFloat = 44

    /// Hairline rule above the footer, matching the design system's stroke width.
    static let hairline: CGFloat = 1

    /// Width of the featured Leader on compact and regular widths. Both are kept
    /// well under the narrowest phone's content width so the flourish cannot
    /// push the hero off-screen.
    static let featuredWidthCompact: CGFloat = 116
    static let featuredWidthRegular: CGFloat = 168

    /// The flourish is decoration behind the menu, so it stays faint and tilted.
    static let featuredOpacity: Double = 0.45
    static let featuredTilt: Double = 7
    static let featuredGlow: CGFloat = 26

    /// Fraction of the card's width reserved beside the heading, so the title
    /// never collides with the artwork.
    static let heroTextInset: CGFloat = 0.45

    /// Keeps the menu column readable when the app is given an iPad's width.
    static let maxContentWidth: CGFloat = 720
}

// MARK: - Menu model

/// One tile in the secondary menu grid. Declared here rather than in the
/// navigation layer because the ordering is a presentation decision.
private struct MenuDestination: Identifiable {
    let title: String
    let route: Route

    /// Marks the routes that land on `ComingSoonView`, so the player knows
    /// before tapping.
    var badge: String? = nil

    var id: String { title }
}

// MARK: - Home

/// The app's main menu, and the root of the navigation stack.
struct HomeView: View {
    @Environment(Router.self) private var router
    @Environment(CardDatabase.self) private var database
    @Environment(SettingsStore.self) private var settings

    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.colorScheme) private var colorScheme

    /// The site's wordmark. Components apply the uppercase treatment.
    private static let wordmark = "Naruto Card Game Simulator"

    /// The community server linked from the site's footer.
    private static let discordURL = URL(string: "https://discord.gg/fq9vPx6GQZ")

    /// The menu below PLAY, in the order the site lists it.
    private static let secondaryDestinations: [MenuDestination] = [
        MenuDestination(title: "Deck builder", route: .deckBuilder),
        MenuDestination(title: "Collection", route: .collection),
        MenuDestination(title: "Sealed", route: .sealed, badge: "Soon"),
        MenuDestination(title: "Leaderboard", route: .leaderboard, badge: "Soon"),
        MenuDestination(title: "Tournaments", route: .tournaments, badge: "Soon"),
        MenuDestination(title: "Settings", route: .settings)
    ]

    var body: some View {
        ZStack {
            AmbientBackground()

            ScrollView {
                VStack(alignment: .leading, spacing: Metrics.spacingL) {
                    topBar
                    hero
                    menu
                    footer
                }
                .padding(.horizontal, Metrics.spacingL)
                .padding(.top, Metrics.spacingM)
                .padding(.bottom, Metrics.spacingXL)
                .frame(maxWidth: HomeMetrics.maxContentWidth, alignment: .leading)
                .frame(maxWidth: .infinity)
            }
            .scrollIndicators(.hidden)
            .scrollBounceBehavior(.basedOnSize)
        }
        // The menu carries its own brand bar, so the stack's chrome is redundant.
        .toolbar(.hidden, for: .navigationBar)
    }

    // MARK: Top bar

    private var topBar: some View {
        HStack(spacing: Metrics.spacingS) {
            brandMark
            Spacer(minLength: Metrics.spacingS)
            themeToggle
        }
    }

    /// Accent sparkle plus the wordmark. The type scales down on compact widths
    /// so the mark stays on one line next to the toggle.
    private var brandMark: some View {
        HStack(spacing: Metrics.spacingS) {
            Image(systemName: "sparkle")
                .font(Typeface.display(isCompact ? 13 : 15, weight: .bold))
                .foregroundStyle(Palette.accent)

            Text(Self.wordmark)
                .font(Typeface.label(isCompact ? 9 : 11))
                .tracking(isCompact ? 1.4 : 2.2)
                .textCase(.uppercase)
                .foregroundStyle(Palette.textPrimary)
                .lineLimit(1)
                .minimumScaleFactor(0.6)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Self.wordmark)
        .accessibilityAddTraits(.isHeader)
    }

    /// Flips the stored appearance. `.system` resolves against whatever the
    /// device is currently showing, so the first tap always visibly changes.
    private var themeToggle: some View {
        Button {
            withAnimation(.easeInOut(duration: 0.2)) {
                settings.appearance = isShowingDark ? .light : .dark
            }
        } label: {
            Image(systemName: isShowingDark ? "sun.max.fill" : "moon.fill")
                .font(Typeface.display(15, weight: .bold))
                .foregroundStyle(Palette.accent)
                .frame(width: HomeMetrics.tapTarget, height: HomeMetrics.tapTarget)
                .notchedPanel(notch: Metrics.spacingS, corners: .diagonal)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(isShowingDark ? "Switch to the light theme"
                                          : "Switch to the dark theme")
    }

    // MARK: Hero

    private var hero: some View {
        ZStack(alignment: .topTrailing) {
            featuredLeaderArt

            VStack(alignment: .leading, spacing: Metrics.spacingS) {
                Text(Self.wordmark)
                    .screenTitle()
                    .fixedSize(horizontal: false, vertical: true)

                Text("Unofficial fan-made simulator.")
                    .font(Typeface.body(15))
                    .foregroundStyle(Palette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.trailing, featuredWidth * HomeMetrics.heroTextInset)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// A Leader from the pool, tilted and faded in behind the hero and menu.
    /// It is pure decoration: it never takes a tap and it is hidden from
    /// VoiceOver, so the tiles underneath stay reachable.
    @ViewBuilder
    private var featuredLeaderArt: some View {
        if let leader = database.leaders.first {
            CardFaceView(card: leader, size: .medium)
                .frame(width: featuredWidth, height: featuredWidth / Metrics.cardAspect)
                .rotationEffect(.degrees(HomeMetrics.featuredTilt))
                .shadow(color: Palette.accent.opacity(0.35), radius: HomeMetrics.featuredGlow)
                .opacity(HomeMetrics.featuredOpacity)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        }
    }

    // MARK: Menu

    private var menu: some View {
        VStack(spacing: Metrics.spacingM) {
            MenuTile(title: "Play", isPrimary: true) {
                router.push(.play)
            }

            LazyVGrid(columns: gridColumns, spacing: Metrics.spacingM) {
                ForEach(Self.secondaryDestinations) { destination in
                    MenuTile(title: destination.title, badge: destination.badge) {
                        router.push(destination.route)
                    }
                }
            }
        }
    }

    /// Two columns where there is room, one where there is not.
    private var gridColumns: [GridItem] {
        Array(
            repeating: GridItem(.flexible(), spacing: Metrics.spacingM),
            count: isCompact ? 1 : 2
        )
    }

    // MARK: Footer

    private var footer: some View {
        VStack(alignment: .leading, spacing: Metrics.spacingS) {
            Rectangle()
                .fill(Palette.border)
                .frame(height: HomeMetrics.hairline)

            HStack(spacing: Metrics.spacingM) {
                Text(Self.wordmark)
                    .font(Typeface.label(isCompact ? 9 : 10))
                    .tracking(1.2)
                    .textCase(.uppercase)
                    .foregroundStyle(Palette.textSecondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)

                Spacer(minLength: 0)

                discordLink
            }

            HStack(spacing: Metrics.spacingS) {
                Text("Unofficial simulator")
                    .font(Typeface.body(12))
                    .foregroundStyle(Palette.textSecondary)

                Spacer(minLength: 0)

                Button("Legal notice") { router.push(.legal) }
                    .font(Typeface.body(12))
                    .foregroundStyle(Palette.accent)
                    .buttonStyle(.plain)
            }
        }
        .padding(.top, Metrics.spacingS)
    }

    /// Leaves the app for the community server. Rendered only when the address
    /// parses, which avoids force-unwrapping a literal URL.
    @ViewBuilder
    private var discordLink: some View {
        if let url = Self.discordURL {
            Link(destination: url) {
                HStack(spacing: Metrics.spacingXS) {
                    Image(systemName: "bubble.left.and.bubble.right.fill")
                    Text("Discord")
                }
                .font(Typeface.label(11))
                .tracking(1.2)
                .textCase(.uppercase)
                .foregroundStyle(Palette.accent)
                .padding(.horizontal, Metrics.spacingS)
                .frame(height: HomeMetrics.tapTarget)
            }
            .accessibilityLabel("Discord, opens in the browser")
        }
    }

    // MARK: Derived state

    private var isCompact: Bool { horizontalSizeClass == .compact }

    private var featuredWidth: CGFloat {
        isCompact ? HomeMetrics.featuredWidthCompact : HomeMetrics.featuredWidthRegular
    }

    /// What the player is actually looking at, which is not the same as the
    /// stored preference while that preference is `.system`.
    private var isShowingDark: Bool {
        settings.appearance.colorScheme.map { $0 == .dark } ?? (colorScheme == .dark)
    }
}

// MARK: - Previews

#Preview("Main menu") {
    NavigationStack {
        HomeView()
    }
    .environment(Router())
    .environment(CardDatabase())
    .environment(SettingsStore())
    .tint(Palette.accent)
    .preferredColorScheme(.dark)
}

#Preview("Main menu, light") {
    NavigationStack {
        HomeView()
    }
    .environment(Router())
    .environment(CardDatabase())
    .environment(SettingsStore())
    .tint(Palette.accent)
    .preferredColorScheme(.light)
}
