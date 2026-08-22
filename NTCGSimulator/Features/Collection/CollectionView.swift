//
//  CollectionView.swift
//  NTCGSimulator
//
//  Browses the whole card pool. Search and the filter chips narrow the grid;
//  tapping any card opens its full printing in the inspector.
//

import SwiftUI

// MARK: - Collection

/// The card browser. Every filter lives in view state rather than in the
/// database, so leaving and returning to the screen starts from a clean slate.
struct CollectionView: View {

    @Environment(CardDatabase.self) private var database
    @Environment(Router.self) private var router

    /// Matched against name, collector number and effect text by the database.
    @State private var searchText = ""

    /// What the grid is actually filtered by. Trails `searchText` by a beat so
    /// a typed word filters the pool once instead of once per letter.
    @State private var debouncedSearch = ""

    /// Remembers the last filter run. `body` is re-evaluated constantly while
    /// the grid scrolls, and re-filtering the whole pool each time is what made
    /// scrolling stutter.
    @State private var memo = FilterResultsMemo()

    // Multi-select filters — an empty set means "no restriction".
    @State private var colors: Set<CardColor> = []
    @State private var types: Set<CardType> = []
    @State private var rarities: Set<Rarity> = []

    // Single-select filters — `nil` means "no restriction".
    @State private var trait: String?
    @State private var setCode: String?

    /// Narrows the grid to the cards printing a SUPPORT bar.
    ///
    /// Support used to be one of the type chips, back when the app modelled it
    /// as a card type. It is a *mode*: a card carrying the bar may be set
    /// face-down in a Support slot instead of being summoned, and the very same
    /// card can still be summoned as a body. Twelve of the pool print one, they
    /// are the only cards that can ever answer a response window, and losing the
    /// type chip would otherwise have left no way to find them.
    @State private var supportBarOnly = false

    /// The chip rows are hidden by default: six of them would push the grid
    /// off the bottom of a phone before a single card was visible.
    @State private var isShowingFilters = false

    /// Roughly three columns on a phone, more as the window grows.
    private let columns = [GridItem(.adaptive(minimum: 104, maximum: 150),
                                    spacing: Metrics.spacingS)]

    var body: some View {
        ScreenScaffold(
            title: "Collection",
            subtitle: "Every card we have, with the values printed on it: type, colour, traits, damage, power and health, plus the effect text and the artist."
        ) {
            VStack(alignment: .leading, spacing: Metrics.spacingM) {
                searchField
                filterBar

                ScrollView {
                    // Filtered once per pass, then shared by the count and grid.
                    let matches = results

                    VStack(alignment: .leading, spacing: Metrics.spacingM) {
                        if isShowingFilters {
                            filterRows
                        }
                        countLine(showing: matches.count)
                        resultsBody(matches)
                    }
                    .padding(.bottom, Metrics.spacingXL)
                }
                .scrollIndicators(.hidden)
                .scrollDismissesKeyboard(.immediately)
            }
            .task(id: searchText) { await debounceSearch() }
        }
    }

    /// Lets a burst of keystrokes settle before refiltering. Cancelled and
    /// restarted by `task(id:)` on every edit, so only the last one lands.
    ///
    /// Clearing is exempt: emptying the field should snap straight back to the
    /// full pool rather than pause first.
    private func debounceSearch() async {
        guard searchText != debouncedSearch else { return }
        guard !searchText.isEmpty else {
            debouncedSearch = ""
            return
        }
        try? await Task.sleep(for: .milliseconds(Self.searchDebounceMilliseconds))
        guard !Task.isCancelled else { return }
        debouncedSearch = searchText
    }

    /// Long enough to swallow a fast typist's keystrokes, short enough that the
    /// grid still feels like it is answering the field.
    private static let searchDebounceMilliseconds = 200

    // MARK: Search

    private var searchField: some View {
        HStack(spacing: Metrics.spacingS) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(Palette.textSecondary)
                .accessibilityHidden(true)

            TextField("Name, number or effect", text: $searchText)
                .font(Typeface.body(15))
                .foregroundStyle(Palette.textPrimary)
                .tint(Palette.accent)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .submitLabel(.search)

            if !searchText.isEmpty {
                Button {
                    searchText = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(Palette.textSecondary)
                        .frame(width: 44, height: 44, alignment: .trailing)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Clear the search")
            }
        }
        .padding(.horizontal, Metrics.spacingM)
        .frame(height: Metrics.controlHeight)
        .notchedPanel(notch: 10, corners: .diagonal)
    }

    // MARK: Filter bar

    /// The disclosure that reveals the chip rows, plus the reset control.
    private var filterBar: some View {
        HStack(spacing: Metrics.spacingS) {
            Button {
                withAnimation(.easeOut(duration: 0.18)) { isShowingFilters.toggle() }
            } label: {
                HStack(spacing: Metrics.spacingS) {
                    Image(systemName: "line.3.horizontal.decrease")
                        .font(Typeface.label(12))

                    Text("Filters")
                        .font(Typeface.label(12))
                        .tracking(1.6)
                        .textCase(.uppercase)

                    if activeFilterCount > 0 {
                        Text("\(activeFilterCount)")
                            .font(Typeface.numeric(11, weight: .bold))
                            .foregroundStyle(Palette.textOnAccent)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Palette.accent, in: Capsule())
                    }

                    Spacer(minLength: 0)

                    Image(systemName: "chevron.down")
                        .font(Typeface.label(11))
                        .rotationEffect(.degrees(isShowingFilters ? 180 : 0))
                }
                .foregroundStyle(Palette.textPrimary)
                .padding(.horizontal, Metrics.spacingM)
                .frame(height: 44)
                .frame(maxWidth: .infinity, alignment: .leading)
                .notchedPanel(notch: 8, corners: .diagonal)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(filterBarAccessibilityLabel)
            .accessibilityHint(isShowingFilters ? "Hides the filter chips" : "Shows the filter chips")

            if canClear {
                Button(action: clearEverything) {
                    Text("Clear")
                        .font(Typeface.label(11))
                        .tracking(1.4)
                        .textCase(.uppercase)
                        .foregroundStyle(Palette.accent)
                        .padding(.horizontal, Metrics.spacingM)
                        .frame(height: 44)
                        .notchedPanel(notch: 8, corners: .diagonal,
                                      fill: Palette.panel, stroke: Palette.accentMuted)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Clear the search and every filter")
            }
        }
    }

    private var filterBarAccessibilityLabel: String {
        activeFilterCount == 0
            ? "Filters"
            : "Filters, \(activeFilterCount) active"
    }

    // MARK: Filter rows

    private var filterRows: some View {
        VStack(alignment: .leading, spacing: Metrics.spacingM) {
            setRow
            colorRow
            typeRow
            supportRow
            rarityRow
            traitRow
        }
        .transition(.opacity.combined(with: .move(edge: .top)))
    }

    /// Only one set can be inspected at a time; tapping the active chip again
    /// clears it.
    private var setRow: some View {
        chipRow("Set") {
            ForEach(database.allSets, id: \.self) { code in
                FilterChip(title: "Set \(code)", isOn: setCode == code) {
                    withAnimation(.easeOut(duration: 0.15)) {
                        setCode = (setCode == code) ? nil : code
                    }
                }
            }
        }
    }

    private var colorRow: some View {
        chipRow("Colour") {
            ForEach(CardColor.allCases) { color in
                FilterChip(title: color.title,
                           isOn: colors.contains(color),
                           tint: color.tint) {
                    withAnimation(.easeOut(duration: 0.15)) { colors.toggle(color) }
                }
            }
        }
    }

    private var typeRow: some View {
        chipRow("Type") {
            ForEach(CardType.allCases) { type in
                FilterChip(title: type.title, isOn: types.contains(type)) {
                    withAnimation(.easeOut(duration: 0.15)) { types.toggle(type) }
                }
            }
        }
    }

    /// Support is a mode, not a type, so it sits in its own row rather than
    /// among the type chips. The two chips are exclusive: a card either prints
    /// the bar or it does not, and the pool is small enough that "everything
    /// else" is better reached by simply clearing the filter.
    private var supportRow: some View {
        chipRow("Support") {
            FilterChip(title: "Any card", isOn: !supportBarOnly) {
                withAnimation(.easeOut(duration: 0.15)) { supportBarOnly = false }
            }
            FilterChip(title: "Prints a support bar", isOn: supportBarOnly) {
                withAnimation(.easeOut(duration: 0.15)) { supportBarOnly = true }
            }
            .accessibilityHint("Shows only the cards that can be set face-down to answer with")
        }
    }

    /// Rarity chips show the printed letter, so the label is spoken in full.
    private var rarityRow: some View {
        chipRow("Rarity") {
            ForEach(Rarity.allCases) { rarity in
                FilterChip(title: rarity.code, isOn: rarities.contains(rarity)) {
                    withAnimation(.easeOut(duration: 0.15)) { rarities.toggle(rarity) }
                }
                .accessibilityLabel(rarity.title)
            }
        }
    }

    /// Traits are exclusive: a card must carry the chosen trait, so combining
    /// two of them would almost always return nothing.
    private var traitRow: some View {
        chipRow("Trait") {
            FilterChip(title: "Any trait", isOn: trait == nil) {
                withAnimation(.easeOut(duration: 0.15)) { trait = nil }
            }
            ForEach(database.allTraits, id: \.self) { name in
                FilterChip(title: name, isOn: trait == name) {
                    withAnimation(.easeOut(duration: 0.15)) {
                        trait = (trait == name) ? nil : name
                    }
                }
            }
        }
    }

    /// A labelled row of chips that scrolls sideways when it overflows.
    private func chipRow<Content: View>(
        _ label: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: Metrics.spacingS) {
            Text(label).sectionLabel()

            ScrollView(.horizontal) {
                HStack(spacing: Metrics.spacingS) {
                    content()
                }
                // Keeps the chip strokes off the clipping edge.
                .padding(.vertical, 2)
            }
            .scrollIndicators(.hidden)
        }
    }

    // MARK: Results

    /// Everything that decides what the grid shows, gathered so the memo can
    /// tell a real change from another render pass. `poolRevision` is in here
    /// so an import invalidates the cached results too.
    private var query: FilterQuery {
        FilterQuery(
            searchText: debouncedSearch,
            colors: colors,
            types: types,
            rarities: rarities,
            trait: trait,
            setCode: setCode,
            supportBarOnly: supportBarOnly,
            poolRevision: database.poolRevision
        )
    }

    private var results: [Card] {
        memo.results(for: query, in: database)
    }

    private func countLine(showing count: Int) -> some View {
        Text("\(count) of \(database.cards.count) cards")
            .sectionLabel()
            .accessibilityLabel("Showing \(count) of \(database.cards.count) cards")
    }

    @ViewBuilder
    private func resultsBody(_ matches: [Card]) -> some View {
        if matches.isEmpty {
            VStack(spacing: Metrics.spacingM) {
                EmptyStatePanel(
                    headline: "Nothing matches",
                    message: "No card in the pool answers to that search and those filters."
                )
                WideButton(title: "Clear the filters", style: .primary, action: clearEverything)
            }
            .padding(.top, Metrics.spacingS)
        } else {
            LazyVGrid(columns: columns, spacing: Metrics.spacingM) {
                ForEach(matches) { card in
                    gridCell(card)
                }
            }
        }
    }

    private func gridCell(_ card: Card) -> some View {
        Button {
            router.push(.cardDetail(card.id))
        } label: {
            VStack(spacing: Metrics.spacingXS) {
                CardFaceView(card: card, size: .small)
                Text(card.id)
                    .font(Typeface.label(9))
                    .tracking(0.8)
                    .foregroundStyle(Palette.textSecondary)
                    .lineLimit(1)
            }
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(label(for: card))
        .accessibilityHint("Opens the full card")
    }

    /// The bar is called out because it is not a value printed anywhere else on
    /// the face a screen reader can reach, and it is what decides whether the
    /// card can be set face-down to answer with.
    private func label(for card: Card) -> String {
        var parts = [card.name, card.id, card.type.title]
        if card.canSetAsSupport { parts.append("prints a support bar") }
        return parts.joined(separator: ", ")
    }

    // MARK: Filter state

    /// Chip selections only — the badge on the Filters disclosure.
    private var activeFilterCount: Int {
        colors.count
            + types.count
            + rarities.count
            + (trait == nil ? 0 : 1)
            + (setCode == nil ? 0 : 1)
            + (supportBarOnly ? 1 : 0)
    }

    /// The Clear control also covers the search field, so it appears whenever
    /// anything at all is narrowing the grid.
    private var canClear: Bool {
        activeFilterCount > 0 || !searchText.isEmpty
    }

    private func clearEverything() {
        withAnimation(.easeOut(duration: 0.2)) {
            searchText = ""
            colors.removeAll()
            types.removeAll()
            rarities.removeAll()
            trait = nil
            setCode = nil
            supportBarOnly = false
        }
    }
}

// MARK: - Result memoisation

/// Every input the filtered grid depends on, in one comparable value.
private struct FilterQuery: Equatable {
    var searchText: String
    var colors: Set<CardColor>
    var types: Set<CardType>
    var rarities: Set<Rarity>
    var trait: String?
    var setCode: String?
    var supportBarOnly: Bool
    var poolRevision: Int
}

/// A one-entry cache in front of `CardDatabase.filtered(...)`.
///
/// SwiftUI re-evaluates `body` for reasons that have nothing to do with the
/// filters — a scroll offset, a keyboard, a rotation — and filtering the pool
/// is far too expensive to repeat for those. A class rather than a value so the
/// view can record a result without that counting as a state change.
private final class FilterResultsMemo {

    private var lastQuery: FilterQuery?
    private var lastResults: [Card] = []

    func results(for query: FilterQuery, in database: CardDatabase) -> [Card] {
        if lastQuery == query { return lastResults }

        var matches = database.filtered(
            searchText: query.searchText,
            colors: query.colors,
            types: query.types,
            rarities: query.rarities,
            trait: query.trait,
            setCode: query.setCode
        )
        // Applied here rather than in `CardDatabase`: the SUPPORT bar is a
        // property of the printing, not one of the indexed columns the database
        // filters on, and the pool is small enough that one more pass costs
        // nothing behind the memo.
        if query.supportBarOnly {
            matches = matches.filter(\.canSetAsSupport)
        }

        lastResults = matches
        lastQuery = query
        return lastResults
    }
}

// MARK: - Set toggling

private extension Set {
    /// Adds the element if missing, removes it if present — the multi-select
    /// chip behaviour used by the colour, type and rarity rows.
    mutating func toggle(_ member: Element) {
        if contains(member) {
            remove(member)
        } else {
            insert(member)
        }
    }
}

// MARK: - Preview

#Preview {
    NavigationStack {
        CollectionView()
    }
    .environment(CardDatabase())
    .environment(Router())
}
