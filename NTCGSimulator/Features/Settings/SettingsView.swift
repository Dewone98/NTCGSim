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

    // MARK: Artwork

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
