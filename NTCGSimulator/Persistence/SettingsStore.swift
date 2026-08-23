//
//  SettingsStore.swift
//  NTCGSimulator
//
//  Player preferences. These mirror the options the simulator's Settings
//  screen offers and are kept on the device.
//

import SwiftUI

/// How a response window the player cannot answer is handled.
enum AutoPassMode: String, Codable, CaseIterable {
    case holdWindow, passForMe

    var title: String {
        switch self {
        case .holdWindow: return "Hold the window"
        case .passForMe:  return "Pass for me"
        }
    }
}

/// Whether picking a target resolves immediately or asks first.
enum TargetConfirmMode: String, Codable, CaseIterable {
    case askMe, resolveOnTap

    var title: String {
        switch self {
        case .askMe:        return "Ask me to confirm"
        case .resolveOnTap: return "Resolve on tap"
        }
    }
}

/// Whether ending a turn asks for confirmation.
enum EndTurnConfirmMode: String, Codable, CaseIterable {
    case askMe, endImmediately

    var title: String {
        switch self {
        case .askMe:          return "Ask me"
        case .endImmediately: return "End it straight away"
        }
    }
}

@Observable
final class SettingsStore {

    // MARK: Stored preferences

    var appearance: AppearanceMode = .dark            { didSet { save() } }
    var chakraCardID: String = "C-001"                { didSet { save() } }
    var autoPass: AutoPassMode = .holdWindow          { didSet { save() } }
    var targetConfirm: TargetConfirmMode = .askMe     { didSet { save() } }

    /// A card in hand has three modes: summon, set face-down as a Support, and
    /// play its jutsu. When on, the app shows the action panel every time, even
    /// where only one mode is available — so a misplaced tap never spends a
    /// card. Off by default, matching the reference.
    var confirmJutsuSummon: Bool = false              { didSet { save() } }

    var endTurnConfirm: EndTurnConfirmMode = .askMe   { didSet { save() } }
    var soundEnabled: Bool = true                     { didSet { save() } }
    var chatSoundEnabled: Bool = false                { didSet { save() } }
    var username: String = "Player"                   { didSet { save() } }

    /// How hard the computer opponent plays.
    ///
    /// The reference never exposed this knob and always shipped kage, so kage
    /// is the default here; the tiers below it exist because an opponent that
    /// reads your hand is not what everybody wants from a first game.
    var aiDifficulty: AIDifficulty = .standard        { didSet { save() } }

    // MARK: Music

    /// Which background track plays, if any. Off is the default: the app ships
    /// with no music, and an app that starts making noise on first launch has
    /// made a decision that was not its to make.
    var musicSelection: MusicSelection = .off  { didSet { save(); syncMusic() } }

    /// Music level, 0...1, independent of the device volume.
    var musicVolume: Double = 0.6              { didSet { save(); syncMusic() } }

    /// Hands the current music choice to the player.
    ///
    /// The store drives the player rather than the other way round because the
    /// choice is settled here — it is what gets persisted, and what the Play
    /// screen and Settings both write to — so this is the one place that knows
    /// when it changed. `apply` is idempotent, so calling it on every write
    /// costs nothing when only the volume moved.
    private func syncMusic() {
        guard !isLoading else { return }
        MusicPlayer.shared.apply(selection: musicSelection, volume: musicVolume)
    }


    // MARK: Persistence

    private static let key = "ncg.settings.v1"

    /// Codable mirror of the stored values.
    ///
    /// Preferences added after the first release are optional here on purpose.
    /// One missing key would otherwise throw out of `decode` and take every
    /// other setting the player had chosen with it, so a snapshot written
    /// before a preference existed decodes into that preference's default
    /// instead of resetting the screen.
    private struct Snapshot: Codable {
        var appearance: AppearanceMode
        var chakraCardID: String
        var autoPass: AutoPassMode
        var targetConfirm: TargetConfirmMode
        var confirmJutsuSummon: Bool
        var endTurnConfirm: EndTurnConfirmMode
        var soundEnabled: Bool
        var chatSoundEnabled: Bool
        var username: String
        var aiDifficulty: AIDifficulty?
        var musicSelection: MusicSelection?
        var musicVolume: Double?
    }

    /// Suppresses writes while `load()` is populating the properties.
    private var isLoading = false

    init() {
        load()
    }

    private func load() {
        isLoading = true
        defer {
            isLoading = false
            // The player is told once, after every value is in place, so a
            // restored choice starts playing at the restored volume rather
            // than at whatever the previous property happened to set.
            syncMusic()
        }

        guard
            let data = UserDefaults.standard.data(forKey: Self.key),
            let snapshot = try? JSONDecoder().decode(Snapshot.self, from: data)
        else { return }

        appearance         = snapshot.appearance
        chakraCardID       = snapshot.chakraCardID
        autoPass           = snapshot.autoPass
        targetConfirm      = snapshot.targetConfirm
        confirmJutsuSummon = snapshot.confirmJutsuSummon
        endTurnConfirm     = snapshot.endTurnConfirm
        soundEnabled       = snapshot.soundEnabled
        chatSoundEnabled   = snapshot.chatSoundEnabled
        username           = snapshot.username
        aiDifficulty       = snapshot.aiDifficulty   ?? .standard
        musicSelection     = snapshot.musicSelection ?? .off
        musicVolume        = snapshot.musicVolume    ?? 0.6
    }

    private func save() {
        guard !isLoading else { return }
        let snapshot = Snapshot(
            appearance: appearance,
            chakraCardID: chakraCardID,
            autoPass: autoPass,
            targetConfirm: targetConfirm,
            confirmJutsuSummon: confirmJutsuSummon,
            endTurnConfirm: endTurnConfirm,
            soundEnabled: soundEnabled,
            chatSoundEnabled: chatSoundEnabled,
            username: username,
            aiDifficulty: aiDifficulty,
            musicSelection: musicSelection,
            musicVolume: musicVolume,
        )
        if let data = try? JSONEncoder().encode(snapshot) {
            UserDefaults.standard.set(data, forKey: Self.key)
        }
    }
}
