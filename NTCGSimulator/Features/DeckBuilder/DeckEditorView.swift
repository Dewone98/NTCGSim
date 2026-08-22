//
//  DeckEditorView.swift
//  NTCGSimulator
//
//  Builds or edits one deck: choose the Leader, name it, then add up to four
//  copies of any card in the Leader's colour until the deck holds fifty. The
//  screen keeps its own working copy so nothing reaches the store until Save.
//

import SwiftUI
import UIKit

// MARK: - Screen

/// The deck editor. `deckID` is `nil` when starting a new deck.
struct DeckEditorView: View {
    let deckID: UUID?

    @Environment(Router.self) private var router
    @Environment(DeckStore.self) private var store
    @Environment(CardDatabase.self) private var database

    /// The working copy. Edits stay here until Save writes them to the store.
    @State private var deck = Deck(leaderID: "")

    /// What the deck looked like when it was loaded or last saved — the
    /// baseline for the unsaved-changes guard.
    @State private var savedState = Deck(leaderID: "")

    /// Loading happens once, on first appearance, when the environment exists.
    @State private var hasLoaded = false

    @State private var searchText = ""
    @State private var costFilter: Int?

    /// Narrows the pool to the cards printing a SUPPORT bar.
    ///
    /// They are the only cards that can be set face-down, and so the only cards
    /// a deck can ever answer a response window with. A builder deciding how many
    /// answers to carry needs to see them together, which the type sections alone
    /// do not give — a SUPPORT bar is printed across Characters, not on a type of
    /// its own.
    @State private var supportBarOnly = false

    /// A Leader waiting on the "this removes off-colour cards" confirmation.
    @State private var leaderPendingChange: Card?

    @State private var isConfirmingDiscard = false
    @State private var isConfirmingDelete = false

    var body: some View {
        ScreenScaffold(title: screenTitle, onBack: attemptBack) {
            content
        }
        .onAppear(perform: loadIfNeeded)
        .confirmationDialog(
            "Change the Leader?",
            isPresented: leaderChangeBinding,
            titleVisibility: .visible,
            presenting: leaderPendingChange
        ) { leader in
            Button("Change and remove \(offColourCount(for: leader)) cards", role: .destructive) {
                apply(leader: leader)
            }
            Button("Keep the current Leader", role: .cancel) { leaderPendingChange = nil }
        } message: { leader in
            Text("\(leader.name) is \(leader.color.title.lowercased()). Cards that do not match that colour will be taken out of the deck.")
        }
        .confirmationDialog(
            "Discard your changes?",
            isPresented: $isConfirmingDiscard,
            titleVisibility: .visible
        ) {
            Button("Discard and go back", role: .destructive) { router.pop() }
            Button("Keep editing", role: .cancel) { }
        } message: {
            Text("This deck has changes that have not been saved.")
        }
        .confirmationDialog(
            "Delete this deck?",
            isPresented: $isConfirmingDelete,
            titleVisibility: .visible
        ) {
            Button("Delete it", role: .destructive) { deleteDeck() }
            Button("Keep it", role: .cancel) { }
        } message: {
            Text("The deck will be removed from this device. That cannot be undone.")
        }
    }

    // MARK: Layout

    @ViewBuilder
    private var content: some View {
        if !hasLoaded {
            Spacer()
        } else if database.leaders.isEmpty {
            EmptyStatePanel(
                headline: "No Leaders in the pool",
                message: "The card pool holds no Leader cards, so there is nothing to build around. Reset the pool in Settings and try again."
            )
            Spacer()
        } else {
            VStack(spacing: Metrics.spacingM) {
                ScrollView {
                    VStack(alignment: .leading, spacing: Metrics.spacingL) {
                        leaderSection
                        nameSection
                        problemsSection
                        DeckExportPanel(code: deck.exportCode())
                        deleteSection
                        poolSection
                    }
                    .padding(.bottom, Metrics.spacingL)
                }
                .scrollIndicators(.hidden)

                saveBar
            }
        }
    }

    // MARK: Leader

    private var leaderSection: some View {
        VStack(alignment: .leading, spacing: Metrics.spacingS) {
            Text("Leader").sectionLabel()

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: Metrics.spacingS) {
                    ForEach(database.leaders) { candidate in
                        LeaderChoice(
                            leader: candidate,
                            isSelected: candidate.id == deck.leaderID,
                            action: { choose(leader: candidate) }
                        )
                    }
                }
                .padding(.vertical, 2)
            }

            if let leader {
                Text("Only \(leader.color.title.lowercased()) cards may go in this deck.")
                    .font(Typeface.body(13))
                    .foregroundStyle(Palette.textSecondary)
            }
        }
    }

    // MARK: Name

    private var nameSection: some View {
        VStack(alignment: .leading, spacing: Metrics.spacingS) {
            HStack(spacing: Metrics.spacingS) {
                Text("Deck name").sectionLabel()
                Spacer(minLength: 0)
                if isNameEmpty {
                    Text("Required")
                        .font(Typeface.label(10))
                        .tracking(1.2)
                        .textCase(.uppercase)
                        .foregroundStyle(Palette.warning)
                }
            }

            TextField("Name this deck", text: $deck.name)
                .font(Typeface.body(15))
                .foregroundStyle(Palette.textPrimary)
                .submitLabel(.done)
                .padding(.horizontal, Metrics.spacingM)
                .frame(height: Metrics.controlHeight)
                .notchedPanel(
                    notch: 8,
                    corners: .diagonal,
                    fill: Palette.surface,
                    stroke: isNameEmpty ? Palette.warning : Palette.border
                )
                .accessibilityLabel("Deck name")
        }
    }

    // MARK: Problems

    @ViewBuilder
    private var problemsSection: some View {
        if !problems.isEmpty {
            VStack(alignment: .leading, spacing: Metrics.spacingS) {
                Text("Before you can save").sectionLabel()

                ForEach(problems) { problem in
                    HStack(alignment: .top, spacing: Metrics.spacingS) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(Typeface.label(11))
                            .foregroundStyle(Palette.warning)
                        Text(problem.message)
                            .font(Typeface.body(13))
                            .foregroundStyle(Palette.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .accessibilityElement(children: .combine)
                }
            }
            .padding(Metrics.spacingM)
            .frame(maxWidth: .infinity, alignment: .leading)
            .notchedPanel()
        }
    }

    // MARK: Delete

    @ViewBuilder
    private var deleteSection: some View {
        if deckID != nil {
            WideButton(title: "Delete this deck", style: .destructive) {
                isConfirmingDelete = true
            }
        }
    }

    // MARK: Card pool

    /// The pool is split into type sections so Support cards read as their own
    /// group rather than being lost among fifty Characters.
    private var poolSection: some View {
        VStack(alignment: .leading, spacing: Metrics.spacingS) {
            // Filtered once per pass, then shared by the count and the sections.
            let sections = poolSections

            HStack(spacing: Metrics.spacingS) {
                Text("Card pool").sectionLabel()
                Spacer(minLength: 0)
                Text("\(sections.reduce(0) { $0 + $1.cards.count }) shown")
                    .font(Typeface.label(10))
                    .tracking(1)
                    .textCase(.uppercase)
                    .foregroundStyle(Palette.textSecondary)
            }

            PoolSearchField(text: $searchText)
            poolFilters

            if sections.isEmpty {
                EmptyStatePanel(
                    headline: "Nothing matches",
                    message: "Clear the search or the filters to see the rest of the Leader's colour."
                )
            } else {
                LazyVStack(alignment: .leading, spacing: Metrics.spacingS) {
                    ForEach(sections) { section in
                        PoolSectionHeader(
                            type: section.type,
                            count: section.cards.count,
                            settableCount: section.cards.filter(\.canSetAsSupport).count
                        )

                        ForEach(section.cards) { card in
                            PoolCardRow(
                                card: card,
                                copies: deck.copies(of: card.id),
                                canAdd: canAdd(card),
                                onAdd: { add(card) },
                                onRemove: { remove(card) }
                            )
                        }
                    }
                }
            }
        }
    }

    /// The two ways of narrowing the pool, with the one sentence that explains
    /// both: what a printed chakra number is actually the price of, and why a
    /// deck wants cards carrying a SUPPORT bar in it.
    private var poolFilters: some View {
        VStack(alignment: .leading, spacing: Metrics.spacingS) {
            costFilterRow
            supportFilterRow

            Text("Chakra is only ever spent flipping a face-down Support face-up, or "
                 + "playing a card as a jutsu off the same line. Summoning a Character "
                 + "and setting a card face-down are both free.")
                .font(Typeface.body(12))
                .foregroundStyle(Palette.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// Filtering by cost now means filtering by what a card can actually be
    /// played for, since summoning costs nothing at all.
    private var costFilterRow: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: Metrics.spacingS) {
                FilterChip(title: "Any chakra cost", isOn: costFilter == nil) {
                    costFilter = nil
                }
                ForEach(availableCosts, id: \.self) { cost in
                    FilterChip(title: "\(cost) chakra", isOn: costFilter == cost) {
                        costFilter = costFilter == cost ? nil : cost
                    }
                }
            }
            .padding(.vertical, 2)
        }
    }

    /// Support is a mode a card is used in, not a type it is printed as, so it
    /// cannot be reached through the type sections — the bar is printed across
    /// Characters. This is the only way to see the answers a deck could carry
    /// gathered together.
    private var supportFilterRow: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: Metrics.spacingS) {
                FilterChip(title: "Any card", isOn: !supportBarOnly) {
                    supportBarOnly = false
                }
                FilterChip(title: "Prints a support bar", isOn: supportBarOnly) {
                    supportBarOnly = true
                }
                .accessibilityHint("Shows only the cards that can be set face-down to answer with")
            }
            .padding(.vertical, 2)
        }
    }

    // MARK: Save bar

    /// Pinned under the scroll view so the count and Save stay reachable while
    /// working through a long card pool.
    private var saveBar: some View {
        VStack(spacing: Metrics.spacingS) {
            countReadout
            WideButton(
                title: "Save the deck",
                style: .primary,
                isEnabled: deck.isLegal(using: database),
                action: save
            )
        }
        .padding(.bottom, Metrics.spacingS)
    }

    private var countReadout: some View {
        HStack(alignment: .firstTextBaseline, spacing: Metrics.spacingS) {
            Text("\(deck.count)")
                .font(Typeface.numeric(26))
                .foregroundStyle(countColour)
            Text("/ \(DeckRules.requiredSize) cards")
                .font(Typeface.label(12))
                .tracking(1.4)
                .textCase(.uppercase)
                .foregroundStyle(countColour)

            Spacer(minLength: Metrics.spacingS)

            VStack(alignment: .trailing, spacing: Metrics.spacingXS) {
                Text(supportBarTitle)
                    .font(Typeface.label(10))
                    .tracking(1)
                    .textCase(.uppercase)
                    .foregroundStyle(supportBarCount == 0 ? Palette.warning : Palette.textSecondary)

                Text("Max \(DeckRules.maxCopies) per card")
                    .font(Typeface.label(10))
                    .tracking(1)
                    .textCase(.uppercase)
                    .foregroundStyle(Palette.textSecondary)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(countAccessibilityLabel)
    }

    /// Counts the bar, not a card type. "12 support" used to mean twelve cards
    /// typed Support; it now means twelve cards printing the bar, and the
    /// wording says so rather than leaving the old reading standing.
    private var supportBarTitle: String {
        supportBarCount == 0 ? "No support bars" : "\(supportBarCount) support bars"
    }

    private var countAccessibilityLabel: String {
        let answers = supportBarCount == 0
            ? "no cards printing a SUPPORT bar, so this deck can never answer a response window"
            : "\(supportBarCount) cards printing a SUPPORT bar to answer with"
        return "\(deck.count) of \(DeckRules.requiredSize) cards, \(answers), maximum \(DeckRules.maxCopies) copies per card"
    }

    // MARK: Loading and saving

    /// Pulls the deck out of the store on first appearance. A new deck starts on
    /// the first Leader in the pool so the card list is never empty.
    private func loadIfNeeded() {
        guard !hasLoaded else { return }
        hasLoaded = true

        if let deckID, let existing = store.deck(id: deckID) {
            deck = existing
        } else {
            deck = Deck(name: "", leaderID: database.leaders.first?.id ?? "")
        }
        savedState = deck
    }

    private func save() {
        var updated = deck
        updated.name = updated.name.trimmingCharacters(in: .whitespacesAndNewlines)
        store.save(updated)
        savedState = updated
        router.pop()
    }

    private func deleteDeck() {
        guard let deckID else { return }
        store.delete(id: deckID)
        router.pop()
    }

    /// The back affordance only leaves straight away when nothing would be lost.
    private func attemptBack() {
        if hasUnsavedChanges {
            isConfirmingDiscard = true
        } else {
            router.pop()
        }
    }

    // MARK: Editing

    /// Swapping to a Leader of another colour invalidates cards already picked,
    /// so that case goes through a confirmation first.
    private func choose(leader candidate: Card) {
        guard candidate.id != deck.leaderID else { return }
        if offColourCount(for: candidate) > 0 {
            leaderPendingChange = candidate
        } else {
            apply(leader: candidate)
        }
    }

    private func apply(leader candidate: Card) {
        withAnimation(.easeOut(duration: 0.2)) {
            deck.leaderID = candidate.id
            deck.cardIDs = deck.cardIDs.filter { database.card(id: $0)?.color == candidate.color }
        }
        leaderPendingChange = nil
        costFilter = nil
    }

    private func add(_ card: Card) {
        guard canAdd(card) else { return }
        deck.cardIDs.append(card.id)
    }

    private func remove(_ card: Card) {
        guard let index = deck.cardIDs.lastIndex(of: card.id) else { return }
        deck.cardIDs.remove(at: index)
    }

    // MARK: Derived state

    private var screenTitle: String {
        deckID == nil ? "New deck" : "Edit deck"
    }

    private var leader: Card? {
        database.card(id: deck.leaderID)
    }

    private var problems: [DeckProblem] {
        deck.problems(using: database)
    }

    private var isNameEmpty: Bool {
        deck.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var hasUnsavedChanges: Bool {
        deck != savedState
    }

    private var countColour: Color {
        deck.count == DeckRules.requiredSize ? Palette.positive : Palette.warning
    }

    /// Cards already in the deck that print a SUPPORT bar.
    ///
    /// They are the deck's only answers: a card can only be set face-down if it
    /// prints the bar, and a face-down card is the only thing a response window
    /// can be answered with. A deck holding none of them also has nothing to
    /// spend chakra on, since flipping one is where chakra goes.
    private var supportBarCount: Int {
        deck.cardIDs.reduce(0) { $0 + (database.card(id: $1)?.canSetAsSupport == true ? 1 : 0) }
    }

    /// Everything the current Leader can legally play, before search and filter.
    private var basePool: [Card] {
        guard let leader else { return [] }
        return database.cardsPlayable(with: leader)
    }

    /// The filtered pool grouped by type, in the printed type order.
    private var poolSections: [PoolSection] {
        let pool = filteredPool
        return CardType.allCases.compactMap { type in
            let cards = pool.filter { $0.type == type }
            return cards.isEmpty ? nil : PoolSection(type: type, cards: cards)
        }
    }

    /// What a card can actually be played for. Summoning is free and so is
    /// setting a card face-down, so the printed number is the price of its
    /// jutsu — and, on the same card, of flipping it face-up to answer.
    private func chakraCost(of card: Card) -> Int? {
        card.jutsuCost ?? card.supportFlipCost
    }

    private var availableCosts: [Int] {
        Array(Set(basePool.compactMap(chakraCost(of:)))).sorted()
    }

    private var filteredPool: [Card] {
        let needle = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return basePool.filter { card in
            if supportBarOnly, !card.canSetAsSupport { return false }
            if let costFilter, chakraCost(of: card) != costFilter { return false }
            guard !needle.isEmpty else { return true }
            return "\(card.name) \(card.id) \(card.effect)".lowercased().contains(needle)
        }
    }

    /// A card can be added while it is under the copy limit and the deck is not
    /// already full.
    private func canAdd(_ card: Card) -> Bool {
        deck.copies(of: card.id) < DeckRules.maxCopies && deck.count < DeckRules.requiredSize
    }

    private func offColourCount(for candidate: Card) -> Int {
        deck.cardIDs.filter { database.card(id: $0)?.color != candidate.color }.count
    }

    /// Drives the Leader dialog from the pending card, so any dismissal clears it.
    private var leaderChangeBinding: Binding<Bool> {
        Binding(
            get: { leaderPendingChange != nil },
            set: { if !$0 { leaderPendingChange = nil } }
        )
    }
}

// MARK: - Leader choice

/// One Leader in the horizontal picker. The current pick wears the accent ring.
private struct LeaderChoice: View {
    let leader: Card
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            CardFaceView(
                card: leader,
                size: .small,
                isDimmed: !isSelected,
                highlight: isSelected ? Palette.accent : nil
            )
            .frame(width: 78)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(leader.name), \(leader.color.title) Leader")
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
    }
}

// MARK: - Pool section

/// One type's worth of the pool, kept together under its own heading.
private struct PoolSection: Identifiable {
    let type: CardType
    let cards: [Card]

    var id: String { type.rawValue }
}

/// The heading above a type's rows. Cards printing a SUPPORT bar are called
/// out, since they are the only ones that can be set face-down to answer with —
/// and a deck holding none of them can never spend a chakra.
private struct PoolSectionHeader: View {
    let type: CardType
    let count: Int

    /// How many of this type print a SUPPORT bar.
    var settableCount: Int = 0

    var body: some View {
        HStack(spacing: Metrics.spacingS) {
            Text(type.title).sectionLabel()

            Text("\(count)")
                .font(Typeface.numeric(11, weight: .bold))
                .foregroundStyle(Palette.textSecondary)

            Spacer(minLength: 0)

            if settableCount > 0 {
                Text("\(settableCount) with a support bar")
                    .font(Typeface.label(9))
                    .tracking(1)
                    .textCase(.uppercase)
                    .foregroundStyle(Palette.accent)
            }
        }
        .padding(.top, Metrics.spacingXS)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(label)
    }

    private var label: String {
        guard settableCount > 0 else { return "\(type.title), \(count) cards" }
        return "\(type.title), \(count) cards, \(settableCount) printing a support bar"
    }
}

// MARK: - Pool row

/// One card in the pool, with the minus / count / plus control that puts copies
/// into the deck.
private struct PoolCardRow: View {
    let card: Card
    let copies: Int
    let canAdd: Bool
    let onAdd: () -> Void
    let onRemove: () -> Void

    var body: some View {
        HStack(spacing: Metrics.spacingM) {
            CardFaceView(
                card: card,
                size: .small,
                highlight: copies > 0 ? Palette.accent : nil
            )
            .frame(width: 54)

            VStack(alignment: .leading, spacing: 2) {
                Text(card.name)
                    .font(Typeface.display(14, weight: .bold))
                    .foregroundStyle(Palette.textPrimary)
                    .lineLimit(1)
                Text(kindLine)
                    .font(Typeface.label(9))
                    .tracking(1)
                    .textCase(.uppercase)
                    .foregroundStyle(card.canSetAsSupport ? Palette.accent : Palette.textSecondary)
                    .lineLimit(1)
                if !statText.isEmpty {
                    Text(statText)
                        .font(Typeface.numeric(11, weight: .bold))
                        .foregroundStyle(Palette.textSecondary)
                        .lineLimit(1)
                }
            }

            Spacer(minLength: Metrics.spacingXS)

            stepper
        }
        .padding(Metrics.spacingS)
        .notchedPanel(
            notch: 10,
            corners: .diagonal,
            fill: copies > 0 ? Palette.panelActive : Palette.panel,
            stroke: copies > 0 ? Palette.accent.opacity(0.5) : Palette.border
        )
    }

    /// Number, type, and the SUPPORT bar where the card prints one.
    ///
    /// The bar is the only thing about a card that decides whether the deck can
    /// answer with it, and it is not a type — it is printed across Characters —
    /// so it has to be said here or a builder scanning the list cannot see it.
    private var kindLine: String {
        let kind = "\(card.id) · \(card.type.title)"
        return card.canSetAsSupport ? "\(kind) · Support bar" : kind
    }

    /// The values worth scanning down a list. A printed number is only shown as
    /// a price where it is one — a jutsu played from hand, or the same number
    /// paid to flip the card face-up — because a Character costs nothing to
    /// summon and nothing to set face-down.
    private var statText: String {
        var parts: [String] = []
        if let power  = card.power  { parts.append("\(power) PWR") }
        if let damage = card.damage { parts.append("\(damage) DMG") }
        if let health = card.health { parts.append("\(health) HP") }
        if let jutsu  = card.jutsuCost { parts.append("Jutsu \(jutsu)") }
        return parts.joined(separator: " · ")
    }

    private var stepper: some View {
        HStack(spacing: Metrics.spacingXS) {
            stepButton(
                symbol: "minus",
                isEnabled: copies > 0,
                label: "Remove a copy of \(card.name)",
                action: onRemove
            )

            Text("\(copies)")
                .font(Typeface.numeric(17))
                .foregroundStyle(copies > 0 ? Palette.textPrimary : Palette.textSecondary)
                .frame(minWidth: 22)
                .accessibilityLabel("\(copies) copies of \(card.name) in the deck")

            stepButton(
                symbol: "plus",
                isEnabled: canAdd,
                label: "Add a copy of \(card.name)",
                action: onAdd
            )
        }
    }

    private func stepButton(
        symbol: String,
        isEnabled: Bool,
        label: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(Typeface.label(14))
                .foregroundStyle(isEnabled ? Palette.textPrimary : Palette.textSecondary)
                .frame(width: 44, height: 44)
                .notchedPanel(
                    notch: 6,
                    corners: .diagonal,
                    fill: isEnabled ? Palette.panel : Palette.surface,
                    stroke: Palette.border
                )
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        .opacity(isEnabled ? 1 : 0.4)
        .accessibilityLabel(label)
    }
}

// MARK: - Search field

/// The pool search box.
private struct PoolSearchField: View {
    @Binding var text: String

    var body: some View {
        HStack(spacing: Metrics.spacingS) {
            Image(systemName: "magnifyingglass")
                .font(Typeface.label(12))
                .foregroundStyle(Palette.textSecondary)

            TextField("Search by name, number or text", text: $text)
                .font(Typeface.body(14))
                .foregroundStyle(Palette.textPrimary)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
                .submitLabel(.search)

            if !text.isEmpty {
                Button {
                    text = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(Typeface.label(13))
                        .foregroundStyle(Palette.textSecondary)
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Clear the search")
            }
        }
        .padding(.leading, Metrics.spacingM)
        .frame(height: Metrics.controlHeight)
        .notchedPanel(notch: 8, corners: .diagonal, fill: Palette.surface, stroke: Palette.border)
        .accessibilityElement(children: .contain)
    }
}

// MARK: - Export panel

/// Share code output: hand the code to the share sheet, or drop it on the
/// clipboard for pasting into a chat.
private struct DeckExportPanel: View {
    let code: String

    @State private var hasCopied = false

    var body: some View {
        VStack(alignment: .leading, spacing: Metrics.spacingS) {
            Text("Share this deck").sectionLabel()

            Text(code)
                .font(Typeface.body(12))
                .foregroundStyle(Palette.textSecondary)
                .lineLimit(2)
                .truncationMode(.middle)
                .textSelection(.enabled)

            HStack(spacing: Metrics.spacingS) {
                ShareLink(item: code) {
                    actionLabel("Share", symbol: "square.and.arrow.up")
                }
                .buttonStyle(.plain)

                Button {
                    copyCode()
                } label: {
                    actionLabel("Copy code", symbol: "doc.on.doc")
                }
                .buttonStyle(.plain)
            }

            if hasCopied {
                Text("Code copied to the clipboard.")
                    .font(Typeface.body(12))
                    .foregroundStyle(Palette.positive)
            }
        }
        .padding(Metrics.spacingM)
        .frame(maxWidth: .infinity, alignment: .leading)
        .notchedPanel()
        .onChange(of: code) { _, _ in
            hasCopied = false
        }
    }

    private func copyCode() {
        UIPasteboard.general.string = code
        withAnimation(.easeOut(duration: 0.2)) { hasCopied = true }
    }

    private func actionLabel(_ title: String, symbol: String) -> some View {
        HStack(spacing: Metrics.spacingXS) {
            Image(systemName: symbol)
                .font(Typeface.label(12))
            Text(title)
                .font(Typeface.label(12))
                .tracking(1.4)
                .textCase(.uppercase)
        }
        .foregroundStyle(Palette.textPrimary)
        .frame(maxWidth: .infinity)
        .frame(height: 46)
        .notchedPanel(notch: 8, corners: .diagonal, fill: Palette.panel, stroke: Palette.border)
    }
}

// MARK: - Previews

#Preview("New deck") {
    NavigationStack {
        DeckEditorView(deckID: nil)
    }
    .environment(CardDatabase())
    .environment(DeckStore())
    .environment(Router())
}

#Preview("Existing deck") {
    let database = CardDatabase()
    let store = deckEditorPreviewStore(database)
    NavigationStack {
        DeckEditorView(deckID: store.decks.first?.id)
    }
    .environment(database)
    .environment(store)
    .environment(Router())
}

/// A store holding one part-built deck, so the preview shows real counts,
/// problems and copy counts in the pool.
private func deckEditorPreviewStore(_ database: CardDatabase) -> DeckStore {
    let store = DeckStore()
    guard let leader = database.leaders.first else { return store }

    var deck = Deck(name: "Leaf Village rush", leaderID: leader.id)
    for card in database.cardsPlayable(with: leader) {
        let room = (DeckRules.requiredSize - 8) - deck.count
        guard room > 0 else { break }
        deck.cardIDs.append(contentsOf: Array(repeating: card.id, count: min(DeckRules.maxCopies, room)))
    }
    store.save(deck)
    return store
}
