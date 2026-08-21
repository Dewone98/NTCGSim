//
//  JournalPanel.swift
//  NTCGSimulator
//
//  The game log. `Journal` is already a collection of identified entries, so the
//  panel iterates it directly rather than keeping a second copy of the history
//  that could fall out of step with the engine.
//

import SwiftUI

// MARK: - Journal panel

/// A scrolling record of the game, oldest line first, pinned to the newest.
///
/// Entries arrive in a two-column shape — who acted, then what happened — which
/// makes a long log scannable without reading every sentence.
struct JournalPanel: View {

    let journal: Journal

    /// Hidden when the panel is already inside a titled container, such as the
    /// compact sheet.
    var showsHeader: Bool = true

    /// Width of the actor column. Wide enough for "Opponent" at this type size.
    private let actorWidth: CGFloat = 62

    var body: some View {
        VStack(alignment: .leading, spacing: Metrics.spacingS) {
            if showsHeader {
                HStack(spacing: Metrics.spacingS) {
                    Text("Journal").sectionLabel()
                    Spacer(minLength: 0)
                    Text("\(journal.count)")
                        .font(Typeface.numeric(11, weight: .bold))
                        .foregroundStyle(Palette.textSecondary)
                }
            }

            entries
        }
        .padding(Metrics.spacingM)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .notchedPanel(fill: Palette.panel.opacity(0.94), stroke: Palette.border)
    }

    // MARK: Entries

    /// Auto-scrolls to the newest line whenever the engine records one, so the
    /// panel behaves like a chat log rather than something to be dragged.
    private var entries: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: Metrics.spacingXS) {
                    ForEach(journal) { entry in
                        row(for: entry)
                            .id(entry.id)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .scrollIndicators(.hidden)
            .onAppear { scrollToLatest(proxy, animated: false) }
            .onChange(of: journal.count) { _, _ in scrollToLatest(proxy, animated: true) }
        }
        .overlay {
            if journal.isEmpty { emptyState }
        }
    }

    private func row(for entry: JournalEntry) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: Metrics.spacingS) {
            Text(entry.actor)
                .font(Typeface.label(9))
                .tracking(1)
                .textCase(.uppercase)
                .foregroundStyle(entry.isSystem ? Palette.accent : Palette.textSecondary)
                .frame(width: actorWidth, alignment: .leading)
                .lineLimit(1)
                .minimumScaleFactor(0.7)

            Text(entry.message)
                .font(Typeface.body(12))
                .foregroundStyle(entry.isSystem ? Palette.textPrimary : Palette.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(entry.line)
    }

    private var emptyState: some View {
        Text("Nothing has happened yet.")
            .font(Typeface.body(12))
            .foregroundStyle(Palette.textSecondary)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func scrollToLatest(_ proxy: ScrollViewProxy, animated: Bool) {
        guard let latest = journal.latest else { return }
        if animated {
            withAnimation(.easeOut(duration: 0.2)) {
                proxy.scrollTo(latest.id, anchor: .bottom)
            }
        } else {
            proxy.scrollTo(latest.id, anchor: .bottom)
        }
    }
}

// MARK: - Journal sheet

/// The compact presentation. A phone has no room for a permanent log beside the
/// board, so the status bar's button lifts the same panel into a sheet.
struct JournalSheet: View {

    let journal: Journal
    let onDismiss: () -> Void

    var body: some View {
        ZStack {
            AmbientBackground()

            VStack(alignment: .leading, spacing: Metrics.spacingM) {
                Text("Journal").screenTitle()

                JournalPanel(journal: journal, showsHeader: false)

                WideButton(title: "Close", style: .primary, action: onDismiss)
            }
            .padding(Metrics.spacingL)
        }
    }
}

// MARK: - Previews

#Preview("Panel") {
    JournalPanel(journal: BoardPreview.journal())
        .frame(height: 240)
        .padding()
        .background(Palette.backdrop)
}

#Preview("Sheet") {
    JournalSheet(journal: BoardPreview.journal(), onDismiss: {})
}
