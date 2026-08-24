//
//  MusicPlayer.swift
//  NTCGSimulator
//
//  The soundtrack for a match, and nothing else.
//
//  Three decisions shape the whole file:
//
//  The game owns the audio. The session is `.playback`, which is the category a
//  game that ships its own music uses: it sounds through the ring/silent switch
//  and it does not stand aside for whatever the device happened to be playing.
//  An earlier version asked for `.ambient` with `.mixWithOthers` and then
//  refused to start at all while `AVAudioSession.isOtherAudioPlaying` was true.
//  The result was the opposite of polite — starting a match left our four
//  bundled tracks silent while somebody else's album carried on, which reads
//  from the player's seat as the game handing them off to another app. That
//  deferral is gone. Nothing in this file opens another app, offers a system
//  music picker, or plays anything but the files `MusicLibrary` found on disk.
//
//  The music belongs to the match, not to the app. `startMatch` and `stopMatch`
//  are the only doors in, and `GameBoardView` calls them from its own lifecycle
//  — appear, disappear, and scene phase. Nothing here starts audio on its own,
//  and `SettingsStore` no longer pokes the player when a preference is written,
//  so the menu, the deck builder, the collection and Settings are silent by
//  construction rather than by remembering to stop.
//
//  Tracks hand over rather than cut, and that ramp is the only CPU this file
//  spends — decoding is the hardware's job, a repeating timer is not. So the
//  timer runs at the fine rate only while a fade is actually in flight, drops
//  to a slow watch rate between tracks, and halves both again on a warm phone
//  or in Low Power Mode. Two `AVAudioPlayer`s exist at once for a fade and no
//  longer.
//

import AVFoundation
import Foundation

// MARK: - Selection

/// What the music system has been asked to play for a match.
///
/// Persisted in `SettingsStore`, so the cases are also the vocabulary the
/// pre-game chooser is built from.
enum MusicSelection: Hashable, Codable {

    /// No music at all.
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
    /// A singleton because `AVAudioSession` is process-wide and two players
    /// would be two owners of one session — emphatically *not* so that music
    /// can outlive a screen. The only thing that ever starts it is
    /// `startMatch`, and the only caller of that is the board.
    static let shared = MusicPlayer()

    /// The tracks this player can draw from. The pre-game screen reads it to
    /// build its list.
    let library: MusicLibrary

    init(library: MusicLibrary = MusicLibrary()) {
        self.library = library
        observeInterruptions()
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

    /// What the current match asked for. Changed only through `startMatch`.
    private(set) var selection: MusicSelection = .off

    /// Output level, 0...1.
    private(set) var volume: Double = 0.6

    /// The track currently sounding, or `nil` when silent.
    private(set) var nowPlaying: MusicTrack?

    /// Whether a match owns the player right now.
    ///
    /// This is the gate every path that could make noise passes through, so a
    /// stray notification arriving after the board has gone can never start the
    /// soundtrack up again on the menu.
    private(set) var isMatchRunning = false

    var isPlaying: Bool { current?.isPlaying == true }

    // MARK: Playback machinery

    @ObservationIgnored private var current: AVAudioPlayer?

    /// The outgoing player during a handover. Non-nil only mid-crossfade.
    @ObservationIgnored private var previous: AVAudioPlayer?

    /// How far through the current crossfade, 0...1. At 1 the ramp is done and
    /// `current` is simply at `volume`.
    @ObservationIgnored private var fadeProgress: Double = 1

    /// Whether a call or another interruption has the session. Not observable:
    /// no screen shows it, because a match that is interrupted is a match
    /// nobody is looking at.
    @ObservationIgnored private var isInterrupted = false

    @ObservationIgnored private var ticker: Timer?

    /// The rate `ticker` was built at, so `syncTicker` can tell a timer that is
    /// already correct from one that has to be replaced — and so the ramp maths
    /// steps by the interval actually in use rather than a nominal one.
    @ObservationIgnored private var tickerInterval: TimeInterval = 0

    @ObservationIgnored private var isSessionActive = false

    /// Tokens for the notification blocks, kept only so `deinit` can return them.
    @ObservationIgnored private var observers: [NSObjectProtocol] = []

    /// Long enough to read as a handover rather than a cut, short enough that
    /// the two tracks are not audibly fighting.
    private static let crossfadeDuration: TimeInterval = 1.5

    // MARK: - Commands

    /// Starts the soundtrack for a match that has just come on screen.
    ///
    /// The board calls this on appear and again when the app returns to the
    /// foreground, so it has to be safe to call twice: a second call naming the
    /// selection already running only moves the level. It deliberately does not
    /// clear an interruption — a phone call is lifted by the session's own
    /// `.ended` notification, not by the scene becoming active while the call
    /// is still up.
    func startMatch(selection newSelection: MusicSelection, volume newVolume: Double) {
        let wasAlreadyRunning = isMatchRunning && newSelection == selection

        isMatchRunning = true
        selection = newSelection
        volume = min(max(newVolume, 0), 1)

        guard !wasAlreadyRunning else {
            applyVolumeToPlayers()
            return
        }

        isInterrupted = false
        startSelected()
    }

    /// Ends the soundtrack: the board has gone, or the app has.
    ///
    /// Silence is immediate rather than faded, on purpose. A ramp needs a run
    /// loop, and both callers are moments where the run loop is about to stop
    /// being ours — a screen being torn down, or the app leaving the foreground
    /// — so a fade would either be cut off partway or trail audibly onto the
    /// menu, which is precisely the thing this rewrite exists to prevent.
    func stopMatch() {
        isMatchRunning = false
        isInterrupted = false
        finishStopping()
    }

    /// Moves the level without touching the choice.
    ///
    /// Separate from `startMatch` because a slider wants to be heard while it
    /// is being dragged, and the value is only worth writing to disk on
    /// release. Harmless while nothing is playing: it sets the level the next
    /// match will start at.
    func setVolume(_ newVolume: Double) {
        volume = min(max(newVolume, 0), 1)
        applyVolumeToPlayers()
    }

    /// Re-reads the folders and reconciles a running match with what is left.
    ///
    /// The pre-game screen calls this every time it appears, so a file dropped
    /// into the owner's Music folder joins the list without a rebuild and
    /// without a Rescan button. A chosen track that has gone away falls silent
    /// rather than being replaced by something the player did not pick.
    func refreshLibrary() {
        library.refresh()

        guard isMatchRunning,
              case .track(let id) = selection,
              library.track(id: id) == nil
        else { return }

        finishStopping()
    }

    // MARK: - Starting and stopping

    /// Begins whatever `selection` asks for, from silence.
    private func startSelected() {
        switch selection {
        case .off:
            finishStopping()

        case .shuffle:
            advanceShuffle()

        case .track(let id):
            if let track = library.track(id: id) {
                crossfade(to: track, looping: true)
            } else {
                finishStopping()
            }
        }
    }

    /// Brings `track` in while whatever is playing goes out.
    ///
    /// Returns `false` for a file that will not open, which is what lets
    /// shuffle step over a corrupt track instead of stalling on it. The
    /// `isMatchRunning` guard is the one that makes "no music outside the
    /// board" a property of the class rather than a promise its callers keep.
    @discardableResult
    private func crossfade(to track: MusicTrack, looping: Bool) -> Bool {
        guard isMatchRunning else { return false }
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
        syncTicker()
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
        finishStopping()
    }

    /// Cuts everything, forgets the track, and hands the session back.
    private func finishStopping() {
        previous?.stop()
        previous = nil
        current?.stop()
        current = nil
        nowPlaying = nil
        fadeProgress = 1
        syncTicker()
        deactivateSessionIfIdle()
    }

    // MARK: - The ramp

    /// The fine step rate, used only while a fade is actually in flight. 20 Hz
    /// is fine enough that a 1.5s ramp is inaudibly stepped.
    private static let rampTick: TimeInterval = 1.0 / 20.0

    /// The same ramp on a phone that has asked for less. Half the wakeups, and
    /// a 15-step fade is still smooth enough not to read as a staircase.
    private static let easedRampTick: TimeInterval = 1.0 / 10.0

    /// Between fades, only shuffle needs a timer at all — and all it is doing
    /// is watching for the end of a track, which four looks a second answers
    /// with room to spare. A chosen track loops inside `AVAudioPlayer` and
    /// needs no timer whatsoever.
    private static let watchTick: TimeInterval = 0.25

    /// The watch rate on a warm or conserving phone. Still well inside the
    /// crossfade's own lead, so a handover started late is a shorter overlap
    /// rather than a missed one.
    private static let easedWatchTick: TimeInterval = 0.5

    /// What the timer needs to be doing right now, or `nil` for "nothing".
    ///
    /// This is the whole thermal story for the audio subsystem. Playing a file
    /// is hardware-assisted and costs nothing worth governing; a repeating main
    /// run-loop timer is the only thing here that keeps the CPU awake, so the
    /// timer is what degrades. `SearchBudget` draws its warm/cool line at
    /// `.serious` for the same reason — that is where the OS starts throttling
    /// clocks — and this file uses the same line so the two never disagree
    /// about what "the phone is warm" means.
    private var neededTickInterval: TimeInterval? {
        guard !isInterrupted else { return nil }

        let conditions = DeviceConditions.current
        let isEased = conditions.isLowPowerModeEnabled || Self.isWarm(conditions.thermalState)

        if fadeProgress < 1 || previous != nil {
            return isEased ? Self.easedRampTick : Self.rampTick
        }
        if case .shuffle = selection, current != nil {
            return isEased ? Self.easedWatchTick : Self.watchTick
        }
        return nil
    }

    private static func isWarm(_ state: ProcessInfo.ThermalState) -> Bool {
        switch state {
        case .nominal, .fair:
            return false
        case .serious, .critical:
            return true
        @unknown default:
            // A rung Apple adds later is by definition not nominal.
            return true
        }
    }

    /// Brings the timer into line with what the player is doing: builds one,
    /// re-rates one, or takes it away. Called after every state change, so
    /// "is a timer running, and how fast" is answered in exactly one place.
    private func syncTicker() {
        guard let interval = neededTickInterval else {
            stopTicking()
            return
        }
        guard ticker == nil || tickerInterval != interval else { return }

        stopTicking()
        let timer = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            self?.tick()
        }
        // `.common` so a scrolling list cannot stall a fade mid-ramp.
        RunLoop.main.add(timer, forMode: .common)
        ticker = timer
        tickerInterval = interval
    }

    private func stopTicking() {
        ticker?.invalidate()
        ticker = nil
        tickerInterval = 0
    }

    private func tick() {
        stepCrossfade()

        // Only shuffle has to watch for the end of a track: a chosen track
        // loops inside `AVAudioPlayer` and never reaches one.
        if case .shuffle = selection, let current, hasReachedHandover(current) {
            // `advanceShuffle` re-syncs the timer whichever way it goes.
            advanceShuffle()
            return
        }
        syncTicker()
    }

    /// Advances the ramp by one step of whatever rate the timer is actually
    /// running at, so an eased tick makes the fade coarser rather than longer.
    private func stepCrossfade() {
        guard fadeProgress < 1, tickerInterval > 0 else { return }
        fadeProgress = min(1, fadeProgress + tickerInterval / Self.crossfadeDuration)
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
    /// sting would just sound like a mistake — so it is swapped as it ends. The
    /// tolerance is the live tick interval, so a slowed watch rate still
    /// catches the end rather than sailing past it.
    private func hasReachedHandover(_ player: AVAudioPlayer) -> Bool {
        guard player.isPlaying else { return true }
        let lead = player.duration > Self.crossfadeDuration * 3 ? Self.crossfadeDuration : 0
        return player.currentTime >= player.duration - lead - tickerInterval
    }

    // MARK: - Session

    /// `.playback`: heard through the ring/silent switch, and not mixed.
    ///
    /// The absence of `.mixWithOthers` is the point rather than an oversight.
    /// The four bundled tracks *are* this game's audio, and a match the player
    /// started should be the thing they hear.
    private func activateSession() {
        guard !isSessionActive else { return }
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.playback, mode: .default)
            try session.setActive(true)
            isSessionActive = true
        } catch {
            // A session that will not activate is not worth reporting to the
            // player: the tracks simply stay silent, which is a state the whole
            // subsystem is already built to sit in.
            isSessionActive = false
        }
    }

    /// Handing the session back matters more under `.playback` than it did
    /// under `.ambient`. This category interrupts other apps, so leaving the
    /// board has to tell whoever was interrupted that they may carry on — which
    /// is what `.notifyOthersOnDeactivation` is for.
    private func deactivateSessionIfIdle() {
        guard isSessionActive, current == nil, previous == nil else { return }
        try? AVAudioSession.sharedInstance().setActive(false, options: [.notifyOthersOnDeactivation])
        isSessionActive = false
    }

    // MARK: - Interruptions

    /// A phone call, an alarm, Siri: the one thing that is allowed to take the
    /// audio away, and the one thing that gives it back.
    ///
    /// This is the only observer the player keeps. Backgrounding is handled by
    /// the board's scene phase instead, because the board is what owns the
    /// match — a notification observer here could only ever guess at whether
    /// there was a game to come back to.
    private func observeInterruptions() {
        observers.append(NotificationCenter.default.addObserver(
            forName: AVAudioSession.interruptionNotification,
            object: AVAudioSession.sharedInstance(),
            queue: .main
        ) { [weak self] note in
            let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt
            switch raw.flatMap(AVAudioSession.InterruptionType.init(rawValue:)) {
            case .began: self?.handleInterruptionBegan()
            case .ended: self?.handleInterruptionEnded()
            default:     break
            }
        })
    }

    private func handleInterruptionBegan() {
        guard current != nil || previous != nil else { return }
        isInterrupted = true
        current?.pause()
        previous?.pause()
        syncTicker()
    }

    /// Picks playback back up where the call left it.
    ///
    /// The gate is "a match still owns paused players", not the `.shouldResume`
    /// option: that flag is advisory, and a soundtrack that stayed silent for
    /// the rest of a game because the OS omitted it would be the same class of
    /// bug this file was rewritten to remove. The session itself was taken
    /// away, so it is claimed again before the players are asked to sound. If
    /// the board has gone in the meantime, `isMatchRunning` is false and
    /// nothing restarts.
    private func handleInterruptionEnded() {
        isInterrupted = false

        guard isMatchRunning, current != nil || previous != nil else { return }

        isSessionActive = false
        activateSession()
        current?.play()
        previous?.play()
        syncTicker()
    }
}
