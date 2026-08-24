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
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// The app's one music player, read here for the level and the folder it
    /// scans — never to start anything. Only the board starts music; see
    /// `MusicPlayer.shared`.
    private let music = MusicPlayer.shared

    /// Local mirror of the username so the store is only written on commit,
    /// rather than on every keystroke.
    @State private var draftUsername = ""

    /// Local mirror of the music level. A slider wants to be heard while it is
    /// being dragged but is only worth writing to disk on release, so the drag
    /// goes straight to the player and the store is set when the thumb is let
    /// go.
    @State private var draftVolume: Double = 0.6

    /// Moving focus away from the field counts as a commit, the same as Done.
    @FocusState private var isUsernameFocused: Bool

    @State private var isImporting = false
    @State private var isConfirmingReset = false

    /// How many cards the last successful import installed, for the success line.
    @State private var lastImportedCount: Int?

    /// A failure raised by the document picker itself, which never reaches
    /// `CardDatabase.lastImportError`.
    @State private var pickerError: String?

    /// The board's hologram switch.
    ///
    /// Read straight out of `UserDefaults` rather than from `SettingsStore`,
    /// because that is where the board reads it: a kill switch for an effect
    /// has to work without a schema change, so the effect owns its own key and
    /// this screen simply binds to it. `HologramDefaults` is the one name for
    /// it, and the default is on.
    @AppStorage(HologramDefaults.enabledKey) private var hologramsEnabled = true

    /// The board's 3D card switch, bound the same way and for the same
    /// reason. `Card3DDefaults` owns the key; the default is on.
    @AppStorage(Card3DDefaults.enabledKey) private var cards3DEnabled = true

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
                    cards3DRow(isOn: $cards3DEnabled)
                    hologramRow(isOn: $hologramsEnabled)
                    autoPassRow(selection: $settings.autoPass)
                    targetConfirmationRow(selection: $settings.targetConfirm)
                    jutsuSummonRow(isOn: $settings.confirmJutsuSummon)
                    endTurnRow(selection: $settings.endTurnConfirm)
                    aiDifficultyRow(selection: $settings.aiDifficulty)
                    soundRow(isOn: $settings.soundEnabled)
                    chatSoundRow(isOn: $settings.chatSoundEnabled)
                    musicRow
                    usernameRow
                    cardDataRow
                }
                .padding(.bottom, Metrics.spacingXL)
            }
            .scrollDismissesKeyboard(.interactively)
        }
        .onAppear {
            draftUsername = settings.username
            draftVolume = settings.musicVolume
        }
        .onChange(of: settings.musicVolume) { _, level in
            // Kept in step in case the level is changed anywhere but this
            // slider, so the thumb never shows a stale position.
            draftVolume = level
        }
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

    /// The board's 3D cards, on by default.
    ///
    /// It sits directly above the hologram switch because the two are the
    /// same kind of thing — the board's two decorations, each with its own
    /// cost — and the copy says the same three things about both: what it
    /// does, that it changes no rule, and that a warm device is the reason to
    /// turn it off. Cards in hand are named explicitly, because "3D cards"
    /// otherwise sounds like it might soften the cards a player is reading.
    private func cards3DRow(isOn: Binding<Bool>) -> some View {
        SettingRow(
            title: "3D cards on the field",
            explanation: "Cards in play are drawn as real card objects lying on the field, catching the light as it moves. Cards in your hand stay flat and sharp. It is decoration only and changes no rule, so turn it off if your device runs warm.",
            placement: .trailing
        ) {
            Toggle("3D cards on the field", isOn: isOn)
                .labelsHidden()
                .tint(Palette.accent)
        }
    }

    /// The board's holograms, on by default.
    ///
    /// It says what turning it off costs — nothing — and why anybody would,
    /// because "it makes my phone warm" is the only real reason to and a player
    /// should not have to guess that the switch is there for it. The board
    /// already sheds holograms on its own under Low Power Mode and a hot
    /// chassis; this is the deliberate version of the same decision.
    private func hologramRow(isOn: Binding<Bool>) -> some View {
        SettingRow(
            title: "Card holograms",
            explanation: "Face-up cards on the field cast their artwork above them, the way a duel looks in the anime. It is decoration only and changes no rule, so turn it off if your device runs warm.",
            placement: .trailing
        ) {
            Toggle("Card holograms", isOn: isOn)
                .labelsHidden()
                .tint(Palette.accent)
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

    // MARK: AI difficulty

    /// The four tiers, each with the line that says what it actually does.
    ///
    /// Listed rather than reduced to a chip row because the names are ranks
    /// and rank names carry no information on their own — "Jonin" tells nobody
    /// that it searches but cannot see your hand. The same choice is offered
    /// again on the screen a game starts from, which is where most players will
    /// meet it; both write here.
    private func aiDifficultyRow(selection: Binding<AIDifficulty>) -> some View {
        SettingRow(
            title: "AI difficulty",
            explanation: "How hard the computer opponent plays. It can also be changed on the screen where a game starts."
        ) {
            VStack(alignment: .leading, spacing: Metrics.spacingS) {
                ForEach(AIDifficulty.allCases) { tier in
                    ChoiceRow(
                        title: tier.title,
                        subtitle: tier.detail,
                        isSelected: selection.wrappedValue == tier
                    ) {
                        withAnimation(reduceMotion ? nil : .easeOut(duration: 0.15)) {
                            selection.wrappedValue = tier
                        }
                    }
                }

                Text("Genin never searches — it takes the best move in front of it. "
                     + "Kage is the opponent the reference ships: it searches the true "
                     + "state, your hand included, and is close to unbeatable.")
                    .font(Typeface.body(12))
                    .foregroundStyle(Palette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
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

    // MARK: Music

    /// The music section — how loud, and nothing else.
    ///
    /// The list of tracks used to live here and does not any more. Music plays
    /// only while a match is on the board, so a song list in Settings was a list
    /// of buttons that could not do the thing they looked like they did: tapping
    /// one from the preferences screen started nothing, because there was no
    /// game to score. The choice now sits beside the AI difficulty on the screen
    /// a game starts from, where it is a decision about the game about to be
    /// played. What is left here is the level, which is a preference in the
    /// ordinary sense — set once, true of every game after it.
    private var musicRow: some View {
        SettingRow(
            title: "Music",
            explanation: "The soundtrack plays while you are on the board and stops the moment you leave it. Which track plays is chosen on the screen a game starts from; this is how loud it is."
        ) {
            VStack(alignment: .leading, spacing: Metrics.spacingM) {
                musicVolumeControl
                musicOffNote
                musicFolderNote
            }
        }
    }

    private var musicVolumeControl: some View {
        VStack(alignment: .leading, spacing: Metrics.spacingXS) {
            Text("Volume").sectionLabel()

            HStack(spacing: Metrics.spacingS) {
                Image(systemName: "speaker.fill")
                    .font(Typeface.label(11))
                    .foregroundStyle(Palette.textSecondary)
                    .accessibilityHidden(true)

                Slider(value: $draftVolume, in: 0...1) { isEditing in
                    if !isEditing { settings.musicVolume = draftVolume }
                }
                .tint(Palette.accent)
                .accessibilityLabel("Music volume")

                Image(systemName: "speaker.wave.3.fill")
                    .font(Typeface.label(11))
                    .foregroundStyle(Palette.textSecondary)
                    .accessibilityHidden(true)
            }
        }
        .onChange(of: draftVolume) { _, level in
            // Told to the player as well as the store so a level changed while
            // something is sounding is heard at once. Nothing is sounding on
            // this screen, so in practice this only sets where the next match
            // starts — but the two can never drift apart.
            music.setVolume(level)
        }
    }

    /// Says so when the level is moot, rather than letting a live-looking
    /// slider imply music that has been switched off.
    @ViewBuilder
    private var musicOffNote: some View {
        if settings.musicSelection == .off {
            statusLine(
                "Music is switched off for your next game. Turn it back on where a game starts.",
                tint: Palette.textSecondary,
                symbol: "speaker.slash.fill"
            )
        }
    }

    /// Where extra tracks go.
    ///
    /// The app ships four of its own, so this is an addition rather than the
    /// only way to get any — but the folder is still the one place a replacement
    /// or an extra track can be dropped without a rebuild. There is no Rescan
    /// button because the screen that lists the tracks re-reads the folder every
    /// time it appears.
    private var musicFolderNote: some View {
        VStack(alignment: .leading, spacing: Metrics.spacingXS) {
            Text("Extra music").sectionLabel()

            Text("Put mp3, m4a, aac or wav files in this folder and they join the list you choose from before a game.")
                .font(Typeface.body(13))
                .foregroundStyle(Palette.textSecondary)
                .fixedSize(horizontal: false, vertical: true)

            Text(music.library.addedTracksPath)
                .font(Typeface.body(11).monospaced())
                .foregroundStyle(Palette.textSecondary)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .padding(Metrics.spacingS)
                .frame(maxWidth: .infinity, alignment: .leading)
                .notchedPanel(
                    notch: 8,
                    corners: .diagonal,
                    fill: Palette.panelActive.opacity(0.5),
                    stroke: Palette.border
                )
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

// MARK: - Choice row

/// One item in a vertical list of mutually exclusive options: a name, a line
/// about what it does, and a mark on the one in force.
///
/// The chip row handles two or three short labels; this handles the cases that
/// outgrow it — four AI tiers that need explaining, and a music list whose
/// length is whatever the owner's folder holds.
private struct ChoiceRow: View {
    let title: String
    var subtitle: String? = nil
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(alignment: .top, spacing: Metrics.spacingS) {
                Image(systemName: isSelected ? "largecircle.fill.circle" : "circle")
                    .font(Typeface.label(15))
                    .foregroundStyle(isSelected ? Palette.accent : Palette.textSecondary)
                    .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(Typeface.body(14))
                        .foregroundStyle(Palette.textPrimary)
                        .fixedSize(horizontal: false, vertical: true)

                    if let subtitle {
                        Text(subtitle)
                            .font(Typeface.body(12))
                            .foregroundStyle(Palette.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }

                Spacer(minLength: 0)
            }
            .padding(Metrics.spacingS)
            .frame(maxWidth: .infinity, alignment: .leading)
            .frame(minHeight: 44)
            // Tinted rather than merely stroked when selected: these rows sit
            // on `panel`, which is white in the light theme, so a fill drawn
            // from `surface` would be invisible there.
            .notchedPanel(
                notch: 8,
                corners: .diagonal,
                fill: isSelected ? Palette.accent.opacity(0.16) : Palette.panelActive.opacity(0.5),
                stroke: isSelected ? Palette.accent.opacity(0.7) : Palette.border
            )
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : [.isButton])
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

#Preview("Choice rows") {
    ZStack {
        AmbientBackground()

        SettingRow(
            title: "AI difficulty",
            explanation: "How hard the computer opponent plays."
        ) {
            VStack(alignment: .leading, spacing: Metrics.spacingS) {
                ForEach(AIDifficulty.allCases) { tier in
                    ChoiceRow(
                        title: tier.title,
                        subtitle: tier.detail,
                        isSelected: tier == .kage
                    ) { }
                }
            }
        }
        .padding(Metrics.spacingL)
    }
}
