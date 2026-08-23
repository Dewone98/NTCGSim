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


    // MARK: Persistence

    private static let key = "ncg.settings.v1"

    /// Codable mirror of the stored values.
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
    }

    /// Suppresses writes while `load()` is populating the properties.
    private var isLoading = false

    init() {
        load()
    }

    private func load() {
        isLoading = true
        defer { isLoading = false }

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
        )
        if let data = try? JSONEncoder().encode(snapshot) {
            UserDefaults.standard.set(data, forKey: Self.key)
        }
    }
}
