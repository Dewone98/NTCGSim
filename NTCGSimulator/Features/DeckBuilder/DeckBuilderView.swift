//
//  DeckBuilderView.swift
//  NTCGSimulator
//
//  The deck list. Shows every deck saved on this device with its Leader, size
//  and legality, and provides the three ways of getting a new one: copying a
//  ready-made deck, building from scratch, or pasting a share code someone sent
//  you. The ready-made decks lead because an empty list is a dead end.
//

import SwiftUI

// MARK: - Screen

/// Lists the saved decks and routes into the editor.
struct DeckBuilderView: View {
    @Environment(Router.self) private var router
    @Environment(DeckStore.self) private var store
    @Environment(CardDatabase.self) private var database

    /// The share code currently typed into the import field.
    @State private var importCode = ""

    /// Result of the last import attempt, shown inline under the field.
    @State private var importFeedback: DeckImportFeedback?

    /// The deck the delete dialog is asking about. `nil` hides the dialog.
    @State private var deckPendingDeletion: Deck?

    /// The ready-made deck the copy dialog is asking about. `nil` hides it.
    @State private var starterPendingCopy: Deck?

    /// Confirmation of the last copy, shown under the ready-made list.
    @State private var starterFeedback: DeckImportFeedback?

    var body: some View {
        ScreenScaffold(
            title: "Deck Builder",
            subtitle: "Pick a Leader, fill 50 cards in its colour, name the deck and save it. Summoning is free, so pack Support cards if you want anything to spend chakra on. Saved decks stay on this device.",
            onBack: { router.pop() }
        ) {
            ScrollView {
                VStack(alignment: .leading, spacing: Metrics.spacingL) {
                    MenuTile(title: "New deck", isPrimary: true) {
                        router.push(.deckEditor(nil))
                    }

                    starterSection
                    deckSection
                    importSection
                }
                .padding(.bottom, Metrics.spacingXL)
            }
            .scrollIndicators(.hidden)
        }
        .confirmationDialog(
            "Delete this deck?",
            isPresented: deletionDialogBinding,
            titleVisibility: .visible,
            presenting: deckPendingDeletion
        ) { deck in
            Button("Delete it", role: .destructive) { confirmDeletion(of: deck) }
            Button("Keep it", role: .cancel) { deckPendingDeletion = nil }
        } message: { deck in
            Text("\(Self.displayName(of: deck)) will be removed from this device. That cannot be undone.")
        }
        .confirmationDialog(
            "Copy this deck?",
            isPresented: copyDialogBinding,
            titleVisibility: .visible,
            presenting: starterPendingCopy
        ) { starter in
            Button("Copy to my decks") { confirmCopy(of: starter) }
            Button("Not now", role: .cancel) { starterPendingCopy = nil }
        } message: { starter in
            Text("\(Self.displayName(of: starter)) is added to your decks as your own copy, ready to edit. "
                 + "The ready-made version stays here.")
        }
    }

    // MARK: Ready-made decks

    /// Ready-made decks sit above the player's own so a first-time list is never
    /// empty. They are built from the pool on the fly, never saved, and made
    /// plainly separate from anything the player owns.
    @ViewBuilder
    private var starterSection: some View {
        let starters = StarterDecks.all(using: database)

        if !starters.isEmpty {
            VStack(alignment: .leading, spacing: Metrics.spacingS) {
                Text("Ready-made decks").sectionLabel()

                Text("Built from your card pool, legal at \(DeckRules.requiredSize) cards and ready to play. "
                     + "Tap one to copy it into your decks — the copy is yours to edit.")
                    .font(Typeface.body(13))
                    .foregroundStyle(Palette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)

                ForEach(starters) { starter in
                    StarterDeckRow(
                        deck: starter,
                        leader: database.card(id: starter.leaderID),
                        supportCount: supportCount(in: starter),
                        onCopy: { starterPendingCopy = starter }
                    )
                }

                if let starterFeedback {
                    ImportFeedbackLine(feedback: starterFeedback)
                }
            }
        }
    }

    // MARK: Saved decks

    private var deckSection: some View {
        VStack(alignment: .leading, spacing: Metrics.spacingS) {
            HStack(spacing: Metrics.spacingS) {
                Text("Your decks").sectionLabel()
                Spacer(minLength: 0)
                if !store.decks.isEmpty {
                    Text("\(store.decks.count)")
                        .font(Typeface.numeric(12))
                        .foregroundStyle(Palette.textSecondary)
                }
            }

            if store.decks.isEmpty {
                EmptyStatePanel(
                    headline: "No decks yet",
                    message: "Copy one of the ready-made decks above, tap New deck to build your own, "
                           + "or paste a share code below to import a deck someone sent you."
                )
            } else {
                ForEach(store.decks) { deck in
                    DeckSummaryRow(
                        deck: deck,
                        leader: database.card(id: deck.leaderID),
                        problemCount: deck.problems(using: database).count,
                        supportCount: supportCount(in: deck),
                        onOpen: { router.push(.deckEditor(deck.id)) },
                        onDuplicate: { duplicate(deck) },
                        onDelete: { deckPendingDeletion = deck }
                    )
                }
            }
        }
    }

    // MARK: Import

    private var importSection: some View {
        VStack(alignment: .leading, spacing: Metrics.spacingS) {
            Text("Import a deck").sectionLabel()

            Text("Paste a share code. Codes start with NCG1: and carry the Leader plus every card in the deck.")
                .font(Typeface.body(13))
                .foregroundStyle(Palette.textSecondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: Metrics.spacingS) {
                DeckCodeField(code: $importCode, onSubmit: importDeck)
                importButton
            }

            if let importFeedback {
                ImportFeedbackLine(feedback: importFeedback)
            }
        }
        .padding(Metrics.spacingM)
        .frame(maxWidth: .infinity, alignment: .leading)
        .notchedPanel()
    }

    private var importButton: some View {
        Button(action: importDeck) {
            Text("Import")
                .font(Typeface.label(12))
                .tracking(1.6)
                .textCase(.uppercase)
                .foregroundStyle(Palette.textOnAccent)
                .padding(.horizontal, Metrics.spacingM)
                .frame(height: Metrics.controlHeight)
                .notchedPanel(notch: 8, corners: .diagonal, fill: Palette.accent, stroke: .clear)
        }
        .buttonStyle(.plain)
        .disabled(trimmedImportCode.isEmpty)
        .opacity(trimmedImportCode.isEmpty ? 0.4 : 1)
        .accessibilityLabel("Import the pasted deck code")
    }

    // MARK: Actions

    /// Parses the pasted code and saves it. Every failure path explains itself
    /// in the field's own error line rather than throwing up an alert.
    private func importDeck() {
        guard !trimmedImportCode.isEmpty else {
            importFeedback = .failure("Paste a share code first.")
            return
        }
        guard let parsed = Deck.from(code: trimmedImportCode) else {
            importFeedback = .failure("That is not a deck code. A code looks like NCG1:N-001|N-004x4,N-006x2.")
            return
        }
        guard let leader = database.card(id: parsed.leaderID), leader.type == .leader else {
            importFeedback = .failure("That code names a Leader this card pool does not have (\(parsed.leaderID)).")
            return
        }

        var imported = parsed
        imported.name = "\(leader.name) (imported)"
        store.save(imported)

        importCode = ""
        importFeedback = .success("Saved \(imported.name) with \(imported.count) cards. It is at the top of your decks.")
    }

    private func duplicate(_ deck: Deck) {
        store.duplicate(id: deck.id)
    }

    /// Saves a ready-made deck as the player's own. The copy takes a fresh
    /// identity so the starter it came from is untouched and can be copied again.
    private func confirmCopy(of starter: Deck) {
        let copy = StarterDecks.playerCopy(of: starter)
        store.save(copy)
        starterPendingCopy = nil
        starterFeedback = .success("Copied \(Self.displayName(of: copy)) into your decks. It is at the top of the list.")
    }

    private func confirmDeletion(of deck: Deck) {
        store.delete(id: deck.id)
        deckPendingDeletion = nil
    }

    // MARK: Helpers

    private var trimmedImportCode: String {
        importCode.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Support cards in a deck. Chakra is spent only on Support cards and on
    /// jutsu, so the count is worth seeing before opening the editor.
    private func supportCount(in deck: Deck) -> Int {
        deck.cardIDs.reduce(0) { $0 + (database.card(id: $1)?.type == .support ? 1 : 0) }
    }

    /// Drives the delete dialog from the optional deck, so dismissing by any
    /// route clears the pending deck.
    private var deletionDialogBinding: Binding<Bool> {
        Binding(
            get: { deckPendingDeletion != nil },
            set: { if !$0 { deckPendingDeletion = nil } }
        )
    }

    /// The same pattern for the copy dialog, so cancelling by any route clears
    /// the pending starter.
    private var copyDialogBinding: Binding<Bool> {
        Binding(
            get: { starterPendingCopy != nil },
            set: { if !$0 { starterPendingCopy = nil } }
        )
    }

    /// A deck saved without a name still needs something to call it.
    static func displayName(of deck: Deck) -> String {
        let trimmed = deck.name.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "Untitled deck" : trimmed
    }
}

// MARK: - Import feedback

/// The outcome of an import attempt, carried to the line under the field.
private enum DeckImportFeedback {
    case success(String)
    case failure(String)

    var isSuccess: Bool {
        if case .success = self { return true }
        return false
    }

    var message: String {
        switch self {
        case .success(let text), .failure(let text): return text
        }
    }
}

// MARK: - Deck row

/// One saved deck: a colour bar for the Leader's colour, the Leader's face, the
/// deck size, its Support count and a legality badge, plus duplicate and delete.
private struct DeckSummaryRow: View {
    let deck: Deck
    let leader: Card?
    let problemCount: Int

    /// Support cards in the deck — flagged when there are none, since chakra
    /// would then have nothing to buy.
    let supportCount: Int

    let onOpen: () -> Void
    let onDuplicate: () -> Void
    let onDelete: () -> Void

    var body: some View {
        HStack(spacing: 0) {
            Rectangle()
                .fill(tint)
                .frame(width: 5)

            Button(action: onOpen) { rowBody }
                .buttonStyle(.plain)
                .accessibilityLabel("\(title), \(deck.count) cards, \(supportTitle), \(badgeTitle)")
                .accessibilityHint("Opens the deck editor")

            actionMenu
        }
        .fixedSize(horizontal: false, vertical: true)
        .notchedPanel(
            notch: Metrics.notch,
            corners: .diagonal,
            fill: Palette.panel,
            stroke: Palette.border
        )
        .contextMenu { menuItems }
    }

    // MARK: Pieces

    private var rowBody: some View {
        HStack(spacing: Metrics.spacingM) {
            thumbnail

            VStack(alignment: .leading, spacing: Metrics.spacingXS) {
                // Wide tracking plus a fixed trailing stat column leaves little
                // room here, so the title is allowed to shrink and wrap rather
                // than truncate a name the player needs to be able to read.
                Text(title)
                    .font(Typeface.display(15, weight: .heavy))
                    .tracking(1.0)
                    .textCase(.uppercase)
                    .foregroundStyle(Palette.textPrimary)
                    .lineLimit(2)
                    .minimumScaleFactor(0.7)
                    .fixedSize(horizontal: false, vertical: true)

                Text(subtitle)
                    .font(Typeface.label(10))
                    .tracking(1)
                    .textCase(.uppercase)
                    .foregroundStyle(Palette.textSecondary)
                    .lineLimit(1)
            }

            Spacer(minLength: Metrics.spacingS)

            VStack(alignment: .trailing, spacing: Metrics.spacingXS) {
                Text("\(deck.count) / \(DeckRules.requiredSize)")
                    .font(Typeface.numeric(14))
                    .foregroundStyle(Palette.textPrimary)
                    .lineLimit(1)
                supportReadout
                legalityBadge
            }
            .fixedSize(horizontal: true, vertical: false)
        }
        .padding(.leading, Metrics.spacingM)
        .padding(.vertical, Metrics.spacingS)
        .contentShape(Rectangle())
    }

    /// The Leader's face, or a marker when the pool no longer holds that card.
    @ViewBuilder
    private var thumbnail: some View {
        if let leader {
            CardFaceView(card: leader, size: .tiny)
                .frame(width: 34)
        } else {
            Image(systemName: "questionmark")
                .font(Typeface.label(13))
                .foregroundStyle(Palette.warning)
                .frame(width: 34, height: 34 / Metrics.cardAspect)
                .notchedPanel(notch: 4, corners: .diagonal, fill: Palette.surface, stroke: Palette.border)
        }
    }

    /// Support cards are the only thing a deck's chakra can be spent on, so a
    /// deck holding none says so in the warning colour.
    private var supportReadout: some View {
        Text(supportTitle)
            .font(Typeface.label(9))
            .tracking(1)
            .textCase(.uppercase)
            .foregroundStyle(supportCount == 0 ? Palette.warning : Palette.textSecondary)
            .lineLimit(1)
    }

    private var legalityBadge: some View {
        Text(badgeTitle)
            .font(Typeface.label(9))
            .tracking(1)
            .textCase(.uppercase)
            .foregroundStyle(badgeColour)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .notchedPanel(
                notch: 4,
                corners: .diagonal,
                fill: badgeColour.opacity(0.16),
                stroke: badgeColour.opacity(0.6)
            )
    }

    private var actionMenu: some View {
        Menu {
            menuItems
        } label: {
            Image(systemName: "ellipsis")
                .font(Typeface.label(15))
                .foregroundStyle(Palette.textSecondary)
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        .accessibilityLabel("Actions for \(title)")
    }

    /// Shared by the trailing menu button and the long-press context menu.
    @ViewBuilder
    private var menuItems: some View {
        Button(action: onDuplicate) {
            Label("Duplicate", systemImage: "plus.square.on.square")
        }
        Button(role: .destructive, action: onDelete) {
            Label("Delete", systemImage: "trash")
        }
    }

    // MARK: Derived copy

    private var title: String { DeckBuilderView.displayName(of: deck) }

    private var subtitle: String {
        if let leader {
            return "\(leader.name) · \(leader.color.title)"
        }
        return "Leader \(deck.leaderID) is missing from the pool"
    }

    private var supportTitle: String {
        supportCount == 0 ? "No support" : "\(supportCount) support"
    }

    private var badgeTitle: String {
        switch problemCount {
        case 0:  return "Legal"
        case 1:  return "1 problem"
        default: return "\(problemCount) problems"
        }
    }

    private var badgeColour: Color {
        problemCount == 0 ? Palette.positive : Palette.warning
    }

    /// The colour bar reads as the deck's identity at a glance.
    private var tint: Color {
        leader?.color.tint ?? Palette.warning
    }
}

// MARK: - Ready-made deck row

/// One ready-made deck. Deliberately unlike `DeckSummaryRow`: an accent keyline,
/// a "ready-made" badge and a copy glyph rather than a menu, so nobody mistakes
/// it for something they built or looks for a delete button that cannot exist.
private struct StarterDeckRow: View {
    let deck: Deck
    let leader: Card?

    /// Support cards in the list — the reason the deck has anything to spend
    /// chakra on, and worth showing before copying it.
    let supportCount: Int

    let onCopy: () -> Void

    /// A tiny face reads at about two thirds of a control's height.
    private static let thumbnailWidth: CGFloat = 34

    var body: some View {
        Button(action: onCopy) {
            HStack(spacing: 0) {
                Rectangle()
                    .fill(tint)
                    .frame(width: 5)

                rowBody
            }
            .fixedSize(horizontal: false, vertical: true)
            .notchedPanel(
                notch: Metrics.notch,
                corners: .diagonal,
                fill: Palette.panel,
                stroke: Palette.accent.opacity(0.5)
            )
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
        .accessibilityLabel("Ready-made deck \(title), \(subtitle), \(deck.count) cards, \(supportCount) support")
        .accessibilityHint("Copies this deck into your decks")
    }

    // MARK: Pieces

    private var rowBody: some View {
        HStack(spacing: Metrics.spacingM) {
            thumbnail

            VStack(alignment: .leading, spacing: Metrics.spacingXS) {
                // Wide tracking plus a fixed trailing stat column leaves little
                // room here, so the name shrinks and wraps rather than
                // truncating to something the player cannot read.
                Text(title)
                    .font(Typeface.display(15, weight: .heavy))
                    .tracking(1.0)
                    .textCase(.uppercase)
                    .foregroundStyle(Palette.textPrimary)
                    .lineLimit(2)
                    .minimumScaleFactor(0.65)
                    .fixedSize(horizontal: false, vertical: true)

                Text(subtitle)
                    .font(Typeface.label(10))
                    .tracking(1)
                    .textCase(.uppercase)
                    .foregroundStyle(Palette.textSecondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)

                readyMadeBadge
            }

            Spacer(minLength: Metrics.spacingXS)

            // Sized to its own content so the title column can never squeeze
            // it into an unreadable sliver.
            VStack(alignment: .trailing, spacing: Metrics.spacingXS) {
                Text("\(deck.count) / \(DeckRules.requiredSize)")
                    .font(Typeface.numeric(14))
                    .foregroundStyle(Palette.textPrimary)
                    .lineLimit(1)

                Text("\(supportCount) support")
                    .font(Typeface.label(9))
                    .tracking(1)
                    .textCase(.uppercase)
                    .foregroundStyle(Palette.textSecondary)
                    .lineLimit(1)
            }
            .fixedSize(horizontal: true, vertical: false)

            Image(systemName: "plus.square.on.square")
                .font(Typeface.label(15))
                .foregroundStyle(Palette.accent)
                .frame(width: 32)
        }
        .padding(.leading, Metrics.spacingM)
        .padding(.trailing, Metrics.spacingS)
        .padding(.vertical, Metrics.spacingS)
        .contentShape(Rectangle())
    }

    /// The Leader's face, or a marker when an imported pool dropped that card.
    @ViewBuilder
    private var thumbnail: some View {
        if let leader {
            CardFaceView(card: leader, size: .tiny)
                .frame(width: Self.thumbnailWidth)
        } else {
            Image(systemName: "questionmark")
                .font(Typeface.label(13))
                .foregroundStyle(Palette.warning)
                .frame(width: Self.thumbnailWidth, height: Self.thumbnailWidth / Metrics.cardAspect)
                .notchedPanel(notch: 4, corners: .diagonal, fill: Palette.surface, stroke: Palette.border)
        }
    }

    /// Says outright that this is not one of the player's decks.
    private var readyMadeBadge: some View {
        Text("Ready-made")
            .font(Typeface.label(9))
            .tracking(1)
            .textCase(.uppercase)
            .foregroundStyle(Palette.accent)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .notchedPanel(
                notch: 4,
                corners: .diagonal,
                fill: Palette.accent.opacity(0.16),
                stroke: Palette.accent.opacity(0.6)
            )
    }

    // MARK: Derived copy

    private var title: String { DeckBuilderView.displayName(of: deck) }

    private var subtitle: String {
        if let leader {
            return "\(leader.name) · \(leader.color.title)"
        }
        return "Leader \(deck.leaderID) is missing from the pool"
    }

    private var tint: Color {
        leader?.color.tint ?? Palette.accent
    }
}

// MARK: - Import field

/// The share-code field. Kept apart so the screen body stays readable.
private struct DeckCodeField: View {
    @Binding var code: String
    let onSubmit: () -> Void

    var body: some View {
        TextField("NCG1:N-001|N-004x4", text: $code)
            .font(Typeface.body(14))
            .foregroundStyle(Palette.textPrimary)
            .autocorrectionDisabled()
            .textInputAutocapitalization(.never)
            .submitLabel(.done)
            .onSubmit(onSubmit)
            .padding(.horizontal, Metrics.spacingM)
            .frame(height: Metrics.controlHeight)
            .notchedPanel(notch: 8, corners: .diagonal, fill: Palette.surface, stroke: Palette.border)
            .accessibilityLabel("Deck share code")
    }
}

/// The success or failure line under the import field.
private struct ImportFeedbackLine: View {
    let feedback: DeckImportFeedback

    var body: some View {
        HStack(alignment: .top, spacing: Metrics.spacingS) {
            Image(systemName: feedback.isSuccess ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                .font(Typeface.label(11))
                .foregroundStyle(feedback.isSuccess ? Palette.positive : Palette.negative)
            Text(feedback.message)
                .font(Typeface.body(13))
                .foregroundStyle(feedback.isSuccess ? Palette.positive : Palette.negative)
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Previews

#Preview("No saved decks") {
    NavigationStack {
        DeckBuilderView()
    }
    .environment(CardDatabase())
    .environment(DeckStore())
    .environment(Router())
}

#Preview("With decks") {
    let database = CardDatabase()
    NavigationStack {
        DeckBuilderView()
    }
    .environment(database)
    .environment(deckBuilderPreviewStore(database))
    .environment(Router())
}

/// A store holding one legal deck and one short deck, so the preview shows both
/// legality badges.
private func deckBuilderPreviewStore(_ database: CardDatabase) -> DeckStore {
    let store = DeckStore()
    for (index, leader) in database.leaders.prefix(2).enumerated() {
        var deck = Deck(name: "\(leader.name) starter", leaderID: leader.id)
        let target = index == 0 ? DeckRules.requiredSize : 18
        for card in database.cardsPlayable(with: leader) {
            let room = target - deck.count
            guard room > 0 else { break }
            deck.cardIDs.append(contentsOf: Array(repeating: card.id, count: min(DeckRules.maxCopies, room)))
        }
        store.save(deck)
    }
    return store
}
