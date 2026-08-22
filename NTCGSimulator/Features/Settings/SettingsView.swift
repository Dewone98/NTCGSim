//
//  SettingsView.swift
//  NTCGSimulator
//
//  The preferences screen. Every option the simulator offers is laid out with
//  the same title / explanation / control shape, so the list reads as one
//  column no matter whether the control is a picker, a switch or a card row.
//

import SwiftUI
import UniformTypeIdentifiers

// MARK: - Screen

struct SettingsView: View {
    @Environment(Router.self) private var router
    @Environment(SettingsStore.self) private var settings
    @Environment(CardDatabase.self) private var database

    /// Local mirror of the username so the store is only written on commit,
    /// rather than on every keystroke.
    @State private var draftUsername = ""

    /// Moving focus away from the field counts as a commit, the same as Done.
    @FocusState private var isUsernameFocused: Bool

    @State private var isImporting = false
    @State private var isConfirmingReset = false

    /// How many cards the last successful import installed, for the success line.
    @State private var lastImportedCount: Int?

    /// A failure raised by the document picker itself, which never reaches
    /// `CardDatabase.lastImportError`.
    @State private var pickerError: String?

    /// Artwork import: the picker, and the outcome of the last run.
    @State private var isImportingArt = false
    @State private var artSummary: ArtImportSummary?
    @State private var artError: String?

    /// Bulk download from the configured image source.
    @State private var artProgress = ArtFetchProgress()
    @State private var fetchTask: Task<Void, Never>?
    @State private var templateError: String?

    var body: some View {
        @Bindable var settings = settings

        ScreenScaffold(
            title: "Settings",
            subtitle: "These preferences are kept on this device.",
            onBack: { router.pop() }
        ) {
            ScrollView {
                VStack(spacing: Metrics.spacingM) {
                    chakraRow(selection: $settings.chakraCardID)
                    themeRow(selection: $settings.appearance)
                    autoPassRow(selection: $settings.autoPass)
                    targetConfirmationRow(selection: $settings.targetConfirm)
                    jutsuSummonRow(isOn: $settings.confirmJutsuSummon)
                    endTurnRow(selection: $settings.endTurnConfirm)
                    soundRow(isOn: $settings.soundEnabled)
                    chatSoundRow(isOn: $settings.chatSoundEnabled)
                    usernameRow
                    cardDataRow
                    artworkRow
                }
                .padding(.bottom, Metrics.spacingXL)
            }
            .scrollDismissesKeyboard(.interactively)
        }
        .onAppear { draftUsername = settings.username }
        .fileImporter(
            isPresented: $isImporting,
            allowedContentTypes: [.json],
            allowsMultipleSelection: false
        ) { result in
            handleImport(result)
        }
        .fileImporter(
            isPresented: $isImportingArt,
            allowedContentTypes: [.image, .folder],
            allowsMultipleSelection: true
        ) { result in
            handleArtImport(result)
        }
        .onDisappear { fetchTask?.cancel() }
        .confirmationDialog(
            "Reset to the bundled set?",
            isPresented: $isConfirmingReset,
            titleVisibility: .visible
        ) {
            Button("Reset", role: .destructive) {
                lastImportedCount = nil
                pickerError = nil
                database.resetToBundledPool()
            }
            Button("Keep my cards", role: .cancel) { }
        } message: {
            Text("Your imported cards will be removed and the demo set restored. Illustrations you copied in are left alone.")
        }
    }

    // MARK: Chakra card

    /// The five Chakra on the board all use one art, picked here.
    private func chakraRow(selection: Binding<String>) -> some View {
        SettingRow(
            title: "Chakra card",
            explanation: "Pick the Chakra card art used for your five Chakra on the board."
        ) {
            if database.chakraCards.isEmpty {
                Text("This card set has no Chakra cards to choose from.")
                    .font(Typeface.body(13))
                    .foregroundStyle(Palette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: Metrics.spacingS) {
                        ForEach(database.chakraCards) { card in
                            chakraOption(card, selection: selection)
                        }
                    }
                    .padding(.vertical, Metrics.spacingXS)
                }
            }
        }
    }

    private func chakraOption(_ card: Card, selection: Binding<String>) -> some View {
        let isSelected = selection.wrappedValue == card.id

        return Button {
            withAnimation(.easeOut(duration: 0.15)) { selection.wrappedValue = card.id }
        } label: {
            CardFaceView(
                card: card,
                size: .small,
                highlight: isSelected ? Palette.accent : nil
            )
            .frame(width: 76)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(card.name)
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
    }

    // MARK: Play preferences

    private func themeRow(selection: Binding<AppearanceMode>) -> some View {
        SettingRow(title: "Theme", explanation: "System follows your device.") {
            OptionPicker(
                options: AppearanceMode.allCases.map { (value: $0, title: $0.title) },
                selection: selection
            )
        }
    }

    private func autoPassRow(selection: Binding<AutoPassMode>) -> some View {
        SettingRow(
            title: "Auto pass",
            explanation: "When you have nothing to answer with, pass for you instead of holding the window open. Faster, but it tells your opponent you had no answer."
        ) {
            OptionPicker(
                options: AutoPassMode.allCases.map { (value: $0, title: $0.title) },
                selection: selection
            )
        }
    }

    private func targetConfirmationRow(selection: Binding<TargetConfirmMode>) -> some View {
        SettingRow(
            title: "Target confirmation",
            explanation: "When an effect asks for a target, tapping it resolves the effect at once instead of asking you to confirm."
        ) {
            OptionPicker(
                options: TargetConfirmMode.allCases.map { (value: $0, title: $0.title) },
                selection: selection
            )
        }
    }

    private func jutsuSummonRow(isOn: Binding<Bool>) -> some View {
        SettingRow(
            title: "Always show the action panel",
            explanation: "A card can be summoned, set face-down as a support, or played as its jutsu. This shows all three every time, even when only one is available, so a mistap never spends a card. Off by default.",
            placement: .trailing
        ) {
            Toggle("Always show the action panel", isOn: isOn)
                .labelsHidden()
                .tint(Palette.accent)
        }
    }

    private func endTurnRow(selection: Binding<EndTurnConfirmMode>) -> some View {
        SettingRow(
            title: "Confirm end of turn",
            explanation: "Ask before your turn ends, so a stray tap cannot skip it."
        ) {
            OptionPicker(
                options: EndTurnConfirmMode.allCases.map { (value: $0, title: $0.title) },
                selection: selection
            )
        }
    }

    // MARK: Sound

    private func soundRow(isOn: Binding<Bool>) -> some View {
        SettingRow(
            title: "Sound",
            explanation: "Card, turn and effect sounds during a game.",
            placement: .trailing
        ) {
            Toggle("Sound", isOn: isOn)
                .labelsHidden()
                .tint(Palette.accent)
        }
    }

    private func chatSoundRow(isOn: Binding<Bool>) -> some View {
        SettingRow(
            title: "Chat notification sound",
            explanation: "A short tone when a message arrives in the game chat.",
            placement: .trailing
        ) {
            Toggle("Chat notification sound", isOn: isOn)
                .labelsHidden()
                .tint(Palette.accent)
        }
    }

    // MARK: Username

    private var usernameRow: some View {
        SettingRow(
            title: "Username",
            explanation: "This is the name shown during your games."
        ) {
            TextField("Player", text: $draftUsername)
                .font(Typeface.body(15))
                .foregroundStyle(Palette.textPrimary)
                .tint(Palette.accent)
                .textInputAutocapitalization(.words)
                .autocorrectionDisabled()
                .submitLabel(.done)
                .focused($isUsernameFocused)
                .padding(.horizontal, Metrics.spacingM)
                .frame(height: Metrics.controlHeight)
                .notchedPanel(
                    notch: 10,
                    corners: .diagonal,
                    fill: Palette.surface,
                    stroke: Palette.border
                )
                .onSubmit { commitUsername() }
                .onChange(of: isUsernameFocused) { _, focused in
                    if !focused { commitUsername() }
                }
                .accessibilityLabel("Username")
        }
    }

    /// Trims the draft and falls back to "Player" so a blank field never leaves
    /// the player nameless on the board.
    private func commitUsername() {
        let trimmed = draftUsername.trimmingCharacters(in: .whitespacesAndNewlines)
        settings.username = trimmed.isEmpty ? "Player" : trimmed
        draftUsername = settings.username
    }

    // MARK: Card data

    private var cardDataRow: some View {
        SettingRow(
            title: "Card data",
            explanation: "The app ships with a small demo set drawn with generated art. Import a cards.json to replace it with a real set, and drop matching illustrations into the folder below."
        ) {
            VStack(alignment: .leading, spacing: Metrics.spacingM) {
                cardDataStatus
                cardDataMessages

                WideButton(title: "Import cards.json", style: .primary) {
                    isImporting = true
                }

                WideButton(title: "Reset to the bundled set", style: .destructive) {
                    isConfirmingReset = true
                }

                artFolderPath
            }
        }
    }

    private var cardDataStatus: some View {
        HStack(spacing: Metrics.spacingS) {
            CountPill(
                label: "Source",
                value: database.usingImportedData ? "Imported" : "Bundled"
            )
            CountPill(label: "Cards loaded", value: "\(database.cards.count)")
            Spacer(minLength: 0)
        }
    }

    /// The outcome of the most recent import, whichever way it went.
    @ViewBuilder
    private var cardDataMessages: some View {
        if let failure = pickerError ?? database.lastImportError {
            statusLine(failure, tint: Palette.negative, symbol: "exclamationmark.triangle.fill")
        } else if let count = lastImportedCount {
            statusLine("Imported \(count) cards.", tint: Palette.positive, symbol: "checkmark.circle.fill")
        }
    }

    private func statusLine(_ message: String, tint: Color, symbol: String) -> some View {
        HStack(alignment: .top, spacing: Metrics.spacingS) {
            Image(systemName: symbol)
                .font(Typeface.label(12))
                .foregroundStyle(tint)
                .accessibilityHidden(true)

            Text(message)
                .font(Typeface.body(13))
                .foregroundStyle(tint)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Selectable so the path can be copied out and pasted into the Files app.
    private var artFolderPath: some View {
        VStack(alignment: .leading, spacing: Metrics.spacingXS) {
            Text("Illustrations folder").sectionLabel()

            Text(artDirectoryDescription)
                .font(Typeface.body(12))
                .foregroundStyle(Palette.textSecondary)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var artDirectoryDescription: String {
        CardDatabase.artDirectoryURL?.path(percentEncoded: false)
            ?? "This device has no storage folder available."
    }

    // MARK: Artwork

    /// Illustrations are never shipped with the app, so this is where a player
    /// brings their own — either by importing files or by pointing the app at
    /// an image source they have the right to use.
    private var artworkRow: some View {
        @Bindable var settings = settings

        return SettingRow(
            title: "Card artwork",
            explanation: "No artwork ships with the app; cards are drawn from generated art until you add your own. Images stay on this device and are matched to cards by filename, so N-004.png lands on card N-004."
        ) {
            VStack(alignment: .leading, spacing: Metrics.spacingM) {
                artworkStatus
                artworkMessages

                WideButton(title: "Import images or a folder", style: .primary) {
                    isImportingArt = true
                }

                imageSourceField(template: $settings.remoteArtTemplate)
                fetchControls

                if database.artStore.installedCount > 0 {
                    WideButton(title: "Remove all artwork", style: .destructive) {
                        database.artStore.removeAllArt()
                        artSummary = nil
                        artError = nil
                    }
                }
            }
        }
    }

    private var artworkStatus: some View {
        HStack(spacing: Metrics.spacingS) {
            CountPill(label: "Installed", value: "\(database.artStore.installedCount)")
            CountPill(
                label: "Cards covered",
                value: "\(database.cardsWithArtworkCount) / \(database.cards.count)"
            )
            Spacer(minLength: 0)
        }
    }

    @ViewBuilder
    private var artworkMessages: some View {
        if let artError {
            statusLine(artError, tint: Palette.negative, symbol: "exclamationmark.triangle.fill")
        } else if let artSummary {
            statusLine(
                artSummary.message,
                tint: artSummary.installed.isEmpty ? Palette.warning : Palette.positive,
                symbol: artSummary.installed.isEmpty ? "questionmark.circle.fill" : "checkmark.circle.fill"
            )
            // Naming the first few misses makes a mis-named batch obvious
            // rather than leaving the player to guess what went wrong.
            if !artSummary.unmatched.isEmpty {
                Text("Not matched: " + artSummary.unmatched.prefix(4).joined(separator: ", ")
                     + (artSummary.unmatched.count > 4 ? "…" : ""))
                    .font(Typeface.body(12))
                    .foregroundStyle(Palette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// The address the app downloads from. Left empty by design — the app has
    /// no default source, so the choice of where art comes from is the
    /// player's alone.
    private func imageSourceField(template: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: Metrics.spacingXS) {
            Text("Image source").sectionLabel()

            TextField("https://example.com/cards/{id}.png", text: template)
                .textFieldStyle(.plain)
                .font(Typeface.body(13))
                .foregroundStyle(Palette.textPrimary)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .keyboardType(.URL)
                .padding(Metrics.spacingS)
                .notchedPanel(notch: 6, corners: .diagonal, fill: Palette.panelActive)
                .onChange(of: template.wrappedValue) { _, _ in templateError = nil }

            Text("Use \(RemoteArtFetcher.idPlaceholder) where the card number goes. Downloads are saved to this device only.")
                .font(Typeface.body(11))
                .foregroundStyle(Palette.textSecondary)
                .fixedSize(horizontal: false, vertical: true)

            if let templateError {
                statusLine(templateError, tint: Palette.negative, symbol: "exclamationmark.triangle.fill")
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private var fetchControls: some View {
        if artProgress.isRunning {
            VStack(alignment: .leading, spacing: Metrics.spacingS) {
                ProgressView(value: artProgress.fraction)
                    .tint(Palette.accent)

                Text(artProgress.summary)
                    .font(Typeface.body(12))
                    .foregroundStyle(Palette.textSecondary)

                WideButton(title: "Stop", style: .secondary) {
                    artProgress.isCancelled = true
                }
            }
        } else {
            VStack(alignment: .leading, spacing: Metrics.spacingS) {
                WideButton(
                    title: "Download missing artwork",
                    style: .secondary,
                    isEnabled: !settings.remoteArtTemplate.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ) {
                    startFetch()
                }

                if artProgress.total > 0 {
                    Text(artProgress.summary)
                        .font(Typeface.body(12))
                        .foregroundStyle(Palette.textSecondary)
                }
            }
        }
    }

    /// Validates the template before committing to a long run, so a typo fails
    /// immediately rather than after dozens of failed requests.
    private func startFetch() {
        templateError = nil

        if case .failure(let error) = RemoteArtFetcher.validate(template: settings.remoteArtTemplate) {
            templateError = error.errorDescription
            return
        }

        let cards = database.cards
        let template = settings.remoteArtTemplate
        let store = database.artStore

        fetchTask?.cancel()
        fetchTask = Task { @MainActor in
            await RemoteArtFetcher.fetchAll(
                cards: cards,
                template: template,
                into: store,
                progress: artProgress
            )
        }
    }

    /// Copies picked images in and reports what matched.
    private func handleArtImport(_ result: Result<[URL], Error>) {
        artError = nil
        artSummary = nil

        switch result {
        case .success(let urls):
            guard !urls.isEmpty else {
                artError = "No files were chosen."
                return
            }
            artSummary = database.importArtwork(from: urls)

        case .failure(let error):
            artError = error.localizedDescription
        }
    }

    // MARK: Card data import

    /// Reads the picked file inside a security-scoped access window, which the
    /// document picker requires for files outside the app's own container.
    private func handleImport(_ result: Result<[URL], Error>) {
        pickerError = nil
        lastImportedCount = nil

        switch result {
        case .success(let urls):
            guard let url = urls.first else {
                pickerError = "No file was chosen."
                return
            }
            let didAccess = url.startAccessingSecurityScopedResource()
            defer {
                if didAccess { url.stopAccessingSecurityScopedResource() }
            }
            lastImportedCount = database.importPool(from: url)

        case .failure(let error):
            pickerError = error.localizedDescription
        }
    }
}

// MARK: - Setting row

/// One preference: an uppercase title, a short explanation, and its control.
/// Every option on the screen uses this so the column stays regular.
private struct SettingRow<Control: View>: View {

    /// Where the control sits relative to the explanation. Switches read best
    /// on the trailing edge; anything wider goes underneath.
    enum Placement { case below, trailing }

    let title: String
    let explanation: String
    var placement: Placement = .below
    @ViewBuilder var control: () -> Control

    var body: some View {
        Group {
            switch placement {
            case .below:    belowLayout
            case .trailing: trailingLayout
            }
        }
        .padding(Metrics.spacingM)
        .frame(maxWidth: .infinity, alignment: .leading)
        .notchedPanel()
    }

    private var belowLayout: some View {
        VStack(alignment: .leading, spacing: Metrics.spacingS) {
            heading
            control()
        }
    }

    private var trailingLayout: some View {
        HStack(alignment: .center, spacing: Metrics.spacingM) {
            heading
            control()
        }
    }

    private var heading: some View {
        VStack(alignment: .leading, spacing: Metrics.spacingXS) {
            Text(title).sectionLabel()

            Text(explanation)
                .font(Typeface.body(13))
                .foregroundStyle(Palette.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - Previews

#Preview("Settings") {
    NavigationStack {
        SettingsView()
    }
    .environment(Router())
    .environment(CardDatabase())
    .environment(SettingsStore())
}

#Preview("Setting row") {
    ZStack {
        AmbientBackground()

        VStack(spacing: Metrics.spacingM) {
            SettingRow(
                title: "Theme",
                explanation: "System follows your device."
            ) {
                OptionPicker(
                    options: AppearanceMode.allCases.map { (value: $0, title: $0.title) },
                    selection: .constant(AppearanceMode.dark)
                )
            }

            SettingRow(
                title: "Sound",
                explanation: "Card, turn and effect sounds during a game.",
                placement: .trailing
            ) {
                Toggle("Sound", isOn: .constant(true))
                    .labelsHidden()
                    .tint(Palette.accent)
            }
        }
        .padding(Metrics.spacingL)
    }
}
