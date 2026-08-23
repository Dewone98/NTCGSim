//
//  MusicPlayer.swift
//  NTCGSimulator
//
//  Plays the background music the owner chose, and nothing louder than that.
//
//  Three decisions shape the whole file:
//
//  Silence is the default. `MusicSelection.off` is what a fresh install holds,
//  so an app that ships with no tracks and an owner who never opens the Music
//  section both end up in the same place — no audio session, no timer, nothing
//  running.
//
//  It never takes the audio away from anyone. The session is `.ambient` with
//  `.mixWithOthers`, which is the category that yields: it is silenced by the
//  ring switch, it does not interrupt whatever the owner is already listening
//  to, and it stops on its own in the background. On top of that the player
//  watches for the secondary-audio hint and steps aside entirely when the
//  device is playing the owner's music, because mixing a game loop underneath
//  someone's album is worse than staying quiet.
//
//  Tracks hand over rather than cut. A 20 Hz timer runs only while something is
//  sounding; it walks one crossfade ramp and, in shuffle, starts the next track
//  a fade-length before the current one runs out. Two `AVAudioPlayer`s exist at
//  once for that fade and no longer.
//

import AVFoundation
import UIKit

// MARK: - Selection

/// What the music system has been asked to do.
///
/// Persisted in `SettingsStore`, so the cases are the vocabulary the Settings
/// list is built from as well as the player's own state.
enum MusicSelection: Hashable, Codable {

    /// No music at all. The default, and what an empty library falls back to.
    case off

    /// Draw a different track each time one ends.
    case shuffle

    /// One track, repeating. `id` is a `MusicTrack.id`.
    case track(id: String)
}

// MARK: - Player

@Observable
final class MusicPlayer {

    /// The app's one player.
    ///
    /// A singleton rather than an injected object because music outlives every
    /// screen: it has to keep playing across navigation, and the choice that
    /// starts it is settled in `SettingsStore`, which is not a view.
    static let shared = MusicPlayer()

    /// The tracks this player can draw from. Views read it to build the list.
    let library: MusicLibrary

    init(library: MusicLibrary = MusicLibrary()) {
        self.library = library
        observeSystemAudio()
    }

    /// `shared` never dies, but an injected player — a preview, a test — does,
    /// and block-based observers are held by the centre rather than by us, so
    /// they have to be handed back by token or they outlive the object holding
    /// the players they were meant to drive.
    deinit {
        ticker?.invalidate()
        observers.forEach(NotificationCenter.default.removeObserver)
    }

    // MARK: Observable state

    /// What was last asked for. Changed only through `apply(selection:volume:)`
    /// so the persisted setting stays the single source of truth.
    private(set) var selection: MusicSelection = .off

    /// Output level, 0...1.
    private(set) var volume: Double = 0.6

    /// The track currently sounding, or `nil` when silent.
    private(set) var nowPlaying: MusicTrack?

    /// Why the player is quiet while a track is still chosen, or `nil` when it
    /// is not being held back. Settings shows a line for `.otherAudio` so the
    /// silence does not read as a bug.
    private(set) var suspension: SuspensionReason?

    /// Why playback is being held.
    enum SuspensionReason: Hashable {
        /// The device is playing the owner's own audio.
        case otherAudio

        /// The app is in the background, where an `.ambient` session is silent.
        case background

        /// A call or another interruption took the session.
        case interruption
    }

    var isPlaying: Bool { current?.isPlaying == true }

    // MARK: Playback machinery

    @ObservationIgnored private var current: AVAudioPlayer?

    /// The outgoing player during a handover. Non-nil only mid-crossfade.
    @ObservationIgnored private var previous: AVAudioPlayer?

    /// How far through the current crossfade, 0...1. At 1 the ramp is done and
    /// `current` is simply at `volume`.
    @ObservationIgnored private var fadeProgress: Double = 1

    @ObservationIgnored private var ticker: Timer?

    @ObservationIgnored private var isSessionActive = false

    /// Tokens for the notification blocks, kept only so `deinit` can return them.
    @ObservationIgnored private var observers: [NSObjectProtocol] = []

    /// Long enough to read as a handover rather than a cut, short enough that
    /// the two tracks are not audibly fighting.
    private static let crossfadeDuration: TimeInterval = 1.5

    /// 20 Hz. Fine enough that a 1.5s ramp is inaudibly stepped, coarse enough
    /// that the timer costs nothing beside a frame of SwiftUI.
    private static let tickInterval: TimeInterval = 1.0 / 20.0

    // MARK: - Commands

    /// Adopts a choice and a level, starting, swapping or stopping as needed.
    ///
    /// The one entry point, and idempotent: re-applying the selection that is
    /// already playing only moves the volume, so a slider drag never restarts a
    /// track and `SettingsStore` can call this on every change it saves.
    func apply(selection newSelection: MusicSelection, volume newVolume: Double) {
        let selectionChanged = newSelection != selection
        selection = newSelection
        volume = min(max(newVolume, 0), 1)

        guard selectionChanged else {
            applyVolumeToPlayers()
            return
        }

        switch newSelection {
        case .off:
            fadeOutAndStop()

        case .shuffle:
            // Already sounding: let the track finish and shuffle on from there,
            // rather than cutting off what is playing to prove the mode changed.
            if let current {
                current.numberOfLoops = 0
                applyVolumeToPlayers()
                startTicking()
            } else {
                startSelected()
            }

        case .track(let id):
            if nowPlaying?.id == id, let current {
                current.numberOfLoops = -1
                applyVolumeToPlayers()
            } else {
                startSelected()
            }
        }
    }

    /// Moves the level without touching the choice.
    ///
    /// Separate from `apply` because a slider wants to be heard while it is
    /// being dragged, and the value is only worth writing to disk on release.
    func setVolume(_ newVolume: Double) {
        volume = min(max(newVolume, 0), 1)
        applyVolumeToPlayers()
    }

    /// Re-reads the folders and reconciles what is playing with what is there.
    ///
    /// Files can appear while the app is running, which is the whole point of
    /// the owner's Music folder, so this is what the Rescan button calls: a
    /// chosen track that has gone away falls silent, and shuffle that had
    /// nothing to play picks up the new files.
    func refreshLibrary() {
        library.refresh()

        switch selection {
        case .off:
            break

        case .shuffle:
            if current == nil, suspension == nil { startSelected() }

        case .track(let id):
            if library.track(id: id) == nil {
                fadeOutAndStop()
            } else if current == nil, suspension == nil {
                startSelected()
            }
        }
    }

    // MARK: - Starting and stopping

    /// Begins whatever `selection` asks for, from silence.
    ///
    /// The session is opened before the check rather than after, for two
    /// reasons: an `.ambient` mixing session takes nothing from anybody by
    /// existing, and the secondary-audio hint that says when the owner's own
    /// audio stops is only delivered to a session that is already active. So
    /// standing aside here still leaves the player able to hear that it may
    /// come back.
    private func startSelected() {
        guard selection != .off else {
            fadeOutAndStop()
            return
        }
        activateSession()

        guard !AVAudioSession.sharedInstance().isOtherAudioPlaying else {
            suspension = .otherAudio
            return
        }

        switch selection {
        case .off:
            fadeOutAndStop()
        case .shuffle:
            advanceShuffle()
        case .track(let id):
            if let track = library.track(id: id) {
                crossfade(to: track, looping: true)
            } else {
                fadeOutAndStop()
            }
        }
    }

    /// Brings `track` in while whatever is playing goes out.
    ///
    /// Returns `false` for a file that will not open, which is what lets
    /// shuffle step over a corrupt track instead of stalling on it.
    @discardableResult
    private func crossfade(to track: MusicTrack, looping: Bool) -> Bool {
        guard let player = try? AVAudioPlayer(contentsOf: track.url) else { return false }
        player.numberOfLoops = looping ? -1 : 0
        player.volume = 0
        guard player.prepareToPlay() else { return false }

        activateSession()
        guard player.play() else {
            deactivateSessionIfIdle()
            return false
        }

        // Only one fade can be in flight, so anything still fading out from a
        // previous handover is cut here rather than left as a third voice.
        previous?.stop()
        previous = current
        current = player
        nowPlaying = track
        fadeProgress = 0
        suspension = nil
        startTicking()
        return true
    }

    /// Picks the next shuffle track, stepping over files that will not open.
    private func advanceShuffle() {
        var skipping: Set<String> = []
        let repeatsItself = library.tracks.count <= 1

        while let next = library.nextShuffled(after: nowPlaying?.id, skipping: skipping) {
            if crossfade(to: next, looping: repeatsItself) { return }
            skipping.insert(next.id)
        }
        fadeOutAndStop()
    }

    /// Rides the current track down to silence and releases the session.
    private func fadeOutAndStop() {
        previous?.stop()
        previous = current
        current = nil
        nowPlaying = nil
        fadeProgress = 0

        if previous == nil {
            finishStopping()
        } else {
            startTicking()
        }
    }

    private func finishStopping() {
        previous?.stop()
        previous = nil
        current?.stop()
        current = nil
        nowPlaying = nil
        fadeProgress = 1
        suspension = nil
        stopTicking()
        deactivateSessionIfIdle()
    }

    // MARK: - The ramp

    private func startTicking() {
        guard ticker == nil else { return }
        let timer = Timer(timeInterval: Self.tickInterval, repeats: true) { [weak self] _ in
            self?.tick()
        }
        // `.common` so a scrolling list cannot stall a fade mid-ramp.
        RunLoop.main.add(timer, forMode: .common)
        ticker = timer
    }

    private func stopTicking() {
        ticker?.invalidate()
        ticker = nil
    }

    private func tick() {
        stepCrossfade()

        // Only shuffle has to watch for the end of a track: a chosen track
        // loops inside `AVAudioPlayer` and never reaches one.
        if suspension == nil, case .shuffle = selection, let current, hasReachedHandover(current) {
            advanceShuffle()
            return
        }
        stopTickingIfIdle()
    }

    private func stepCrossfade() {
        guard fadeProgress < 1 else { return }
        fadeProgress = min(1, fadeProgress + Self.tickInterval / Self.crossfadeDuration)
        applyVolumeToPlayers()

        guard fadeProgress >= 1 else { return }
        previous?.stop()
        previous = nil
        if current == nil { finishStopping() }
    }

    private func applyVolumeToPlayers() {
        current?.volume = Float(volume * fadeProgress)
        previous?.volume = Float(volume * (1 - fadeProgress))
    }

    /// Whether it is time to bring the next track in.
    ///
    /// The handover starts a fade-length early so the two overlap. A track
    /// shorter than a few fades gets no lead at all — overlapping most of a
    /// sting would just sound like a mistake — so it is swapped as it ends.
    private func hasReachedHandover(_ player: AVAudioPlayer) -> Bool {
        guard player.isPlaying else { return true }
        let lead = player.duration > Self.crossfadeDuration * 3 ? Self.crossfadeDuration : 0
        return player.currentTime >= player.duration - lead - Self.tickInterval
    }

    /// Stops the timer once there is nothing left for it to do — a finished
    /// ramp on a looping track, or silence.
    private func stopTickingIfIdle() {
        guard fadeProgress >= 1, previous == nil else { return }
        if case .shuffle = selection, current != nil, suspension == nil { return }
        stopTicking()
    }

    // MARK: - Session

    /// `.ambient` with `.mixWithOthers`: obeys the ring switch, never
    /// interrupts another app, and goes quiet in the background by itself.
    private func activateSession() {
        guard !isSessionActive else { return }
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.ambient, mode: .default, options: [.mixWithOthers])
            try session.setActive(true)
            isSessionActive = true
        } catch {
            // A session that will not activate is not worth reporting to the
            // player: the tracks simply stay silent, which is a state the whole
            // subsystem is already built to sit in.
            isSessionActive = false
        }
    }

    private func deactivateSessionIfIdle() {
        guard isSessionActive, current == nil, previous == nil else { return }
        try? AVAudioSession.sharedInstance().setActive(false, options: [.notifyOthersOnDeactivation])
        isSessionActive = false
    }

    // MARK: - Yielding

    /// Watches the three things that should take the music away and give it
    /// back: the owner's own audio, an interruption, and the background.
    private func observeSystemAudio() {
        let center = NotificationCenter.default

        observers.append(center.addObserver(
            forName: AVAudioSession.silenceSecondaryAudioHintNotification,
            object: AVAudioSession.sharedInstance(),
            queue: .main
        ) { [weak self] note in
            let raw = note.userInfo?[AVAudioSessionSilenceSecondaryAudioHintTypeKey] as? UInt
            let type = raw.flatMap(AVAudioSession.SilenceSecondaryAudioHintType.init(rawValue:))
            if type == .begin {
                self?.suspend(for: .otherAudio)
            } else {
                self?.resume(from: .otherAudio)
            }
        })

        observers.append(center.addObserver(
            forName: AVAudioSession.interruptionNotification,
            object: AVAudioSession.sharedInstance(),
            queue: .main
        ) { [weak self] note in
            let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt
            let type = raw.flatMap(AVAudioSession.InterruptionType.init(rawValue:))
            if type == .began {
                self?.suspend(for: .interruption)
            } else {
                self?.resume(from: .interruption)
            }
        })

        observers.append(center.addObserver(
            forName: UIApplication.didEnterBackgroundNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.suspend(for: .background)
        })

        observers.append(center.addObserver(
            forName: UIApplication.willEnterForegroundNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.resume(from: .background)
        })
    }

    private func suspend(for reason: SuspensionReason) {
        guard current != nil || previous != nil else { return }
        suspension = reason
        current?.pause()
        previous?.pause()
        stopTicking()
    }

    /// Picks playback back up, unless something else is still holding it.
    ///
    /// Only the reason that caused the pause may lift it, so returning from the
    /// background does not talk over music the owner started in the meantime —
    /// and the other-audio check is repeated here because two reasons can
    /// overlap and only one is remembered.
    private func resume(from reason: SuspensionReason) {
        guard suspension == reason else { return }
        guard selection != .off else {
            suspension = nil
            return
        }
        if AVAudioSession.sharedInstance().isOtherAudioPlaying {
            suspension = .otherAudio
            return
        }

        suspension = nil

        // Nothing was ever started — the owner turned music on while their own
        // audio held the device — so this is a first start, not a resume.
        guard current != nil || previous != nil else {
            startSelected()
            return
        }

        activateSession()
        current?.play()
        previous?.play()
        startTicking()
    }
}
