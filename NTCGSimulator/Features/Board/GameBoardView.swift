//
//  GameBoardView.swift
//  NTCGSimulator
//
//  The board screen: it owns the `GameEngine` for one game, lays the two halves
//  out around the status band, and turns taps into `GameAction`s. Nothing here
//  touches `GameState` — every decision goes through `engine.apply(_:by:)` and
//  every refusal comes back as copy the engine already wrote.
//
//  Three rules shape everything below. Leaders attack, once per turn, resting
//  themselves — so a Leader carries the same attack affordance a body does, with
//  its frozen, rested and already-attacked states on the mat rather than behind
//  a dead tap. An attack may only be aimed at the enemy Leader or a RESTED enemy
//  character, and there is no blocking at all, so a declaration is answered from
//  the Support row and nowhere else. And a response window offers exactly what
//  the engine would accept into it — a "Support Activated" card never lights up
//  for a bare summon, because the chain it answers is empty.
//
//  Everything the board shows *about* a move is presentation and nothing else,
//  and every piece of it is worked out after the fact by comparing the position
//  either side of `apply`: the floating damage numbers, the full-screen jutsu
//  effect, the shot that crosses the mat when an attack is declared, and the
//  beat an activated Support is held in its slot before the row lets it go.
//  None of it delays a rule, none of it takes a touch, and each piece carries a
//  backstop that clears it — so a player who taps straight through the pictures
//  plays exactly the same game as one who watches all of them.
//
//  The holograms standing over the mat follow the same discipline, and one more
//  besides. They are worked out from the position — the bodies in play and the
//  Supports both players have seen, which is an information rule and so is
//  decided here rather than in the card views — and drawn in a single overlay
//  above the whole board, from the frames the cards publish, exactly as the
//  attack shot is. Each projection is confined to its own side's rows band,
//  measured from rects the layout publishes rather than guessed, so no plane
//  ever covers the status strip, a side's name and life, or the counters. They
//  take no touches, and they get out of the way of the game rather than
//  competing with it: nothing projects while a jutsu is filling the screen or
//  while the mat is lit for a target, because in both of those moments the
//  board is the thing being read.
//
//  The cards in play are drawn as real objects on the field stage by the same
//  technique, one layer lower. `BoardCard3DLayer` takes the frames the mat
//  publishes, runs the stage camera backwards to find the world point that
//  projects onto each one, and lays a card slab there — so the slab is under
//  the tap that selects it by construction, not by tuning. It sits BELOW the
//  board's own chrome, and a card handed to it draws no printing of its own,
//  which is what keeps every badge, damage number, target ring, the shot and
//  the card viewer working over it exactly as they did over a flat face.
//  Hands stay 2D: a hand card is being read and chosen between, not looked
//  at. The whole layer collapses to nothing on any of the usual signals, and
//  the board is then precisely what it was before it existed.
//
//  This screen also owns the soundtrack's whole lifetime. `MusicPlayer` starts
//  nothing by itself and `SettingsStore` no longer nudges it, so the music is
//  exactly as long-lived as this view: it begins on appear, ends on disappear —
//  leaving for the menu, or the result overlay taking the player back there —
//  and ends again the moment the app leaves the foreground. That is what keeps
//  a soundtrack a soundtrack rather than something following the player around
//  the deck builder.
//

import SwiftUI

// MARK: - Layout

/// Every size on the board, derived from one number.
///
/// A trading-card mat is mostly fixed proportions, so the whole board is solved
/// from the width of a single Characters-row slot. That slot is whichever is
/// smaller of what the width allows and what the height allows, which is what
/// makes the cards shrink on a phone rather than the board clipping.
struct BoardLayout: Equatable {

    /// True when the inspector becomes a bottom bar instead of a rail.
    let isCompact: Bool

    /// Width of one Characters-row slot. Everything else is a ratio of it.
    let slotWidth: CGFloat

    /// Gap between slots, rows and board sections.
    let gap: CGFloat

    /// Width of the trailing inspector rail. Zero when compact.
    let railWidth: CGFloat

    /// Uniform zoom applied to the whole board on a viewport too short to hold
    /// it even at the smallest readable slot — a phone in landscape, chiefly.
    /// It is 1 on every supported orientation, so nothing is scaled needlessly.
    let contentScale: CGFloat

    // MARK: Proportions

    /// Slots printed in the Characters and Support rows. The Characters row
    /// itself is unbounded and scrolls past this once effects flood it.
    private static let columns: CGFloat = 5

    /// The Leader is printed slightly larger than the bodies it anchors.
    private static let leaderRatio: CGFloat = 1.1

    /// Cards in hand are drawn larger than cards on the board — they are the
    /// ones being read and chosen between.
    private static let handRatio: CGFloat = 1.25

    /// The Chakra row shares its width with the Summon zone, so its cards are
    /// narrower than a Characters slot.
    private static let chakraDivisor: CGFloat = 5

    /// Characters, Support and Chakra.
    private static let rowsPerSide: CGFloat = 3

    /// Fixed width for the Deck / Hand / Trash / Exclusion counters. Sized to
    /// the longest label, "Exclusion", so none of them wraps.
    private static let counterColumnWidth: CGFloat = 78

    /// Below this the board stops reading as cards. A viewport too short to
    /// hold even this is zoomed out whole rather than allowed to clip.
    private static let minimumSlot: CGFloat = 30

    /// Above this an iPad board stops looking like a mat and starts looking
    /// like a poster.
    private static let maximumSlot: CGFloat = 128

    // MARK: Reserved chrome

    /// Everything on a compact board whose height does not follow the slot: the
    /// status bar, the inspector bar, the six gaps in the stack and the padding.
    private static var compactChrome: CGFloat {
        BoardStatusBar.compactHeight
            + CardInspector.compactHeight
            + Metrics.spacingS * 6
            + Metrics.spacingS * 2
    }

    /// The middle band, the five gaps in the left column and the padding.
    private static var regularChrome: CGFloat {
        BoardStatusBar.regularHeight
            + Metrics.spacingS * 5
            + Metrics.spacingM * 2
    }

    /// Card heights stacked down the screen, expressed in slot widths: two
    /// sides of three rows, plus the hand.
    private static var slotsTall: CGFloat {
        (rowsPerSide * 2 + handRatio) / Metrics.cardAspect
    }

    init(size: CGSize, isCompact: Bool) {
        self.isCompact = isCompact

        let gap = isCompact ? Metrics.spacingXS : Metrics.spacingS
        self.gap = gap

        // Height that never shrinks with the slot: the chrome, the two gaps
        // inside each side, and the room the read hand card lifts into.
        let fixedHeight = (isCompact ? Self.compactChrome : Self.regularChrome)
            + gap * 4
            + Metrics.spacingM

        // Zoom the whole board out rather than clip it when even the smallest
        // readable slot will not fit down the screen.
        let shortestBoard = fixedHeight + Self.slotsTall * Self.minimumSlot
        let scale = min(1, size.height / max(1, shortestBoard))
        self.contentScale = scale

        // Everything below is solved in the zoomed-out coordinate space, which
        // is the real one whenever `scale` is 1.
        let width = size.width / scale
        let height = size.height / scale

        let rail: CGFloat = isCompact ? 0 : min(320, max(248, width * 0.26))
        self.railWidth = rail

        // Across: the Leader column, five slots, the counter column, and a gap
        // between each of the seven pieces.
        let horizontalPadding = (isCompact ? Metrics.spacingS : Metrics.spacingM) * 2
        let columnGap = isCompact ? 0 : Metrics.spacingM
        let boardWidth = max(240, width - rail - horizontalPadding - columnGap)
        let widthForSlots = boardWidth - Self.counterColumnWidth - gap * (Self.columns + 1)
        let byWidth = widthForSlots / (Self.columns + Self.leaderRatio)

        let byHeight = max(1, height - fixedHeight) / Self.slotsTall

        self.slotWidth = min(Self.maximumSlot, max(Self.minimumSlot, min(byWidth, byHeight)))
    }

    /// The board's own coordinate space, which `contentScale` maps onto the
    /// screen. Identical to the screen size unless the board had to zoom out.
    func canvasSize(in size: CGSize) -> CGSize {
        CGSize(width: size.width / contentScale, height: size.height / contentScale)
    }

    // MARK: Derived sizes

    var slotHeight: CGFloat { slotWidth / Metrics.cardAspect }

    var leaderWidth: CGFloat { slotWidth * Self.leaderRatio }

    /// The Leader card's own height, from the printed ratio. Named because
    /// the Leader's slot has to be pinned to it — see `BoardSideView`'s
    /// `leaderFace`, where an unpinned slot published a frame that grew
    /// whenever a corner badge appeared.
    var leaderHeight: CGFloat { leaderWidth / Metrics.cardAspect }

    /// Five Chakra cards and the Summon zone share one row's width.
    var chakraWidth: CGFloat {
        max(16, ((Self.columns - 1) * slotWidth - gap) / Self.chakraDivisor)
    }

    var handCardWidth: CGFloat { slotWidth * Self.handRatio }

    /// The strip plus the room the read card lifts into.
    var handHeight: CGFloat { handCardWidth / Metrics.cardAspect + Metrics.spacingM }

    var rowWidth: CGFloat { slotWidth * Self.columns + gap * (Self.columns - 1) }

    var sideHeight: CGFloat { slotHeight * Self.rowsPerSide + gap * (Self.rowsPerSide - 1) }

    var counterWidth: CGFloat { Self.counterColumnWidth }
}

// MARK: - Board card

/// A card drawn into a fixed board slot.
///
/// `CardFaceView` sizes itself from its own contents: its stat badges will not
/// compress past the numbers printed on them, so a face given less width than it
/// needs spills over its neighbours instead of shrinking. Board slots on a phone
/// are routinely narrower than that, so the face is laid out at a width its own
/// contents are comfortable in and then scaled into the slot — every number
/// stays on the card, just smaller. A slot wide enough already scales by one.
struct BoardCardFace: View {

    let card: Card
    var size: CardFaceSize = .tiny

    /// The slot width. Height follows from the printed card ratio.
    let width: CGFloat

    var isDimmed: Bool = false
    var highlight: Color? = nil

    /// How a card lying face down is drawn, when it is lying face down at all.
    ///
    /// Passed straight through rather than decided here, because the choice is
    /// an information rule and only the caller knows whose card this is: a
    /// player's own set Support may be shown blurred, an opponent's may not.
    var faceDown: FaceDownStyle? = nil

    /// True when the 3D card layer behind the board is drawing this card as a
    /// slab on the field stage. The printing then belongs to the slab, and
    /// this face draws nothing that would cover it.
    var rendersAsSlab: Bool = false

    var body: some View {
        if rendersAsSlab {
            slabStandIn
        } else {
            printedFace
        }
    }

    // MARK: Slab stand-in

    /// What a slot holds while its card is being drawn in 3D behind the mat.
    ///
    /// It is transparent, because the slab is UNDER the board's own chrome:
    /// anything this view filled would hide the card it stands for. What it
    /// does keep is the two things on a card face that are game state rather
    /// than picture — the ring that says "this is choosable" and the veil
    /// that steps a card back while something else is being chosen. The 2D
    /// face expresses that second one by fading itself to 45%, which a view
    /// in front of the card cannot do, so it is a veil over the slot instead.
    ///
    /// The silhouette is the SLAB's, not the mat's: rounded to the same
    /// die-cut radius `Card3DMetrics` builds the mesh's corners at, so a ring
    /// drawn here traces the card the player can actually see rather than the
    /// notched panel the 2D face wears.
    private var slabStandIn: some View {
        let shape = RoundedRectangle(
            cornerRadius: width * Card3DMetrics.cornerRadiusRatio,
            style: .continuous
        )

        return shape
            .fill(isDimmed
                  ? Palette.backdrop.opacity(BoardCard3DMetrics.steppedBackVeil)
                  : Color.clear)
            .overlay {
                if let highlight {
                    shape.strokeBorder(highlight, lineWidth: 2.5)
                }
            }
            .frame(width: width, height: width / Metrics.cardAspect)
            .accessibilityHidden(true)
    }

    // MARK: Printed face

    private var printedFace: some View {
        let design = designWidth

        return CardFaceView(
            card: card,
            size: size,
            isDimmed: isDimmed,
            highlight: highlight,
            faceDown: faceDown
        )
            .frame(width: design, height: design / Metrics.cardAspect)
            .scaleEffect(width / design, anchor: .center)
            .frame(width: width, height: width / Metrics.cardAspect)
            .clipped()
    }

    /// Stat badges are what actually set the floor, so the comfortable width is
    /// worked out from how many of them this card prints. A Chakra card has
    /// none and is never scaled at all.
    private var designWidth: CGFloat {
        let badges = [card.life, card.power, card.damage, card.health]
            .compactMap { $0 }
            .count
        let perBadge: CGFloat = size == .tiny ? 17 : 30
        let margin: CGFloat = size == .tiny ? 12 : 18
        return max(width, CGFloat(badges) * perBadge + margin)
    }
}

// MARK: - Board screen

/// Hosts one game. The engine is built once, on appear, because it needs the
/// card pool and the saved decks out of the environment — and rebuilt from
/// scratch when the player asks for another game.
struct GameBoardView: View {

    let configuration: GameConfiguration

    @Environment(CardDatabase.self) private var database
    @Environment(DeckStore.self) private var decks
    @Environment(SettingsStore.self) private var settings

    /// Watched only for the music: an app that has gone to the background is no
    /// longer a match being played, whatever the navigation stack still holds.
    @Environment(\.scenePhase) private var scenePhase

    @State private var engine: GameEngine?

    /// Counts the games played on this screen. It is the stage's identity, so
    /// "Play again" tears the board's own state down with the finished game.
    @State private var gameIndex = 0

    var body: some View {
        ZStack {
            AmbientBackground()

            if let engine {
                BoardStage(
                    configuration: configuration,
                    engine: engine,
                    onPlayAgain: startNewGame
                )
                .id(gameIndex)
            } else {
                ProgressView()
                    .tint(Palette.accent)
                    .accessibilityLabel("Dealing the opening hands")
            }
        }
        .task { if engine == nil { startNewGame() } }
        .onAppear { startMusic() }
        .onDisappear { MusicPlayer.shared.stopMatch() }
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .background:
                // Not `.inactive`: that is also the app switcher being peeked
                // at and the Control Centre being pulled down, neither of which
                // is a player who has left the game.
                MusicPlayer.shared.stopMatch()
            case .active:
                startMusic()
            default:
                break
            }
        }
        .toolbar(.hidden, for: .navigationBar)
        .navigationBarBackButtonHidden(true)
    }

    // MARK: Soundtrack

    /// Hands the saved choice to the player, which is the only way music ever
    /// starts in this app.
    ///
    /// It lives on this view rather than on the stage below because the stage
    /// is rebuilt for every rematch: "Play again" is still the same sitting at
    /// the board, and restarting the track from the top would announce a new
    /// game the player did not travel anywhere to reach. `startMatch` is safe
    /// to call twice, so returning to the foreground goes through the same door.
    private func startMusic() {
        MusicPlayer.shared.startMatch(
            selection: settings.musicSelection,
            volume: settings.musicVolume
        )
    }

    private func startNewGame() {
        engine = GameEngine(
            configuration: configuration,
            database: database,
            decks: decks,
            seed: Self.timeSeed(),
            autoPass: settings.autoPass
        )
        gameIndex += 1
    }

    /// Seeded from the clock so consecutive games differ, spread through the
    /// engine's own mixing constant because only the low bits actually move.
    private static func timeSeed() -> UInt64 {
        let millis = UInt64(max(0, Date().timeIntervalSince1970 * 1000))
        return millis &* 0x9E37_79B9_7F4A_7C15
    }
}

// MARK: - Stage

/// The board proper, once an engine exists.
private struct BoardStage: View {

    let configuration: GameConfiguration
    let engine: GameEngine
    let onPlayAgain: () -> Void

    @Environment(Router.self) private var router
    @Environment(CardDatabase.self) private var database
    @Environment(SettingsStore.self) private var settings
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// The player's switch for the 3D cards, on by default.
    ///
    /// Read straight out of `UserDefaults` for the same reason the hologram
    /// switch is: a kill switch for a decoration owns its own key, so it
    /// works — and can be flipped — without touching `SettingsStore`'s
    /// persisted format. `Card3DDefaults` is the one name for it.
    @AppStorage(Card3DDefaults.enabledKey) private var cards3DEnabled = true

    /// The card in the reader.
    @State private var focusedCard: Card?

    /// The hand index lifted out of the strip.
    @State private var selectedHandIndex: Int?

    /// The Leader or body armed as the attacker, waiting for a target. The
    /// Leader attacks like any other card, so this is a reference rather than
    /// an identity.
    @State private var armedAttacker: AttackerReference?

    /// Option keys staged for a board-picked prompt, in the order tapped.
    @State private var stagedChoiceKeys: [String] = []

    /// The card in play whose offers are being read.
    @State private var offerSheet: OfferSource?

    /// The hand card whose action panel is open: SUMMON, SET AS SUPPORT and
    /// ACTIVATE …, each either offered or refused with the engine's reason.
    @State private var handPanel: HandCard?

    /// A decision held back until the player confirms it. Answered on the
    /// board, never in a system dialog — see `BoardConfirmPanel`.
    @State private var confirmation: BoardConfirmation?

    /// The card the full-screen viewer is showing.
    @State private var zoomedCard: ZoomedCard?

    /// Hits the mat still owes a floating number for. Each removes itself when
    /// its animation reports finished.
    @State private var damageFlashes: [DamageFlash] = []

    /// Jutsu resolutions still owed an effect, oldest first.
    @State private var jutsuQueue: [JutsuPlay] = []

    /// The effect currently on screen, if any.
    @State private var jutsuPlaying: JutsuPlay?

    /// Supports the mat is still turning face-up, or still holding on screen
    /// after the engine emptied their slot. Each removes itself when its hold
    /// reports finished, exactly as a damage number does.
    @State private var supportReveals: [SupportReveal] = []

    /// The declared attack the mat is still drawing, if any.
    @State private var attackShot: AttackShot?

    /// Where every card that publishes an endpoint currently sits, in the
    /// overlay's own space. Kept so a shot can be aimed at a card the attack
    /// is about to take off the board — see `AttackShot`.
    @State private var cardCentres = CardCentres()

    /// Holograms whose card has left the field, kept on the mat for the length
    /// of the collapse so the light folds back into the card rather than
    /// blinking out of existence.
    @State private var hologramExits: [HologramExit] = []

    /// Where every card on the mat was last drawn, in the hologram overlay's
    /// space. Kept for the one question nothing on screen can answer any more:
    /// where the card a hologram is collapsing into used to be.
    @State private var hologramFrames = HologramFrames()

    /// The most recent refusal, shown briefly rather than as an alert.
    @State private var banner: BoardBanner?

    @State private var showsJournal = false

    /// Bumped by every accepted action. Automation keys off it, so the AI takes
    /// exactly one move per change and the loop is visible rather than instant.
    @State private var revision = 0

    /// Long enough to watch a move land, short enough not to feel like a stall.
    private static let aiDelay: Duration = .seconds(0.7)

    /// Effects allowed to back up behind the one playing. A chain resolving
    /// four links deep would otherwise leave the board flaring long after the
    /// position that produced it has gone, so the oldest are dropped.
    private static let jutsuQueueLimit = 2

    var body: some View {
        GeometryReader { geo in
            let layout = BoardLayout(
                size: geo.size,
                isCompact: horizontalSizeClass == .compact
            )

            let canvas = layout.canvasSize(in: geo.size)

            // Worked out once per pass and used twice: the 2D faces are told
            // which cards to stand aside for, and the layer below places the
            // slabs that replace them. One list means the two can never
            // disagree and leave a slot empty.
            let cast = card3DCast
            let slabs = Set(cast.map(\.anchor))

            Group {
                if layout.isCompact {
                    compactBoard(layout, slabs: slabs)
                } else {
                    regularBoard(layout, slabs: slabs)
                }
            }
            .frame(width: canvas.width, height: canvas.height)
            .scaleEffect(layout.contentScale)
            .frame(width: geo.size.width, height: geo.size.height)
            // The cards themselves, as slabs on the stage's ground plane —
            // behind the board's own chrome so every badge, number and target
            // mark still draws over them, and outside the zoom for the reason
            // the hologram and shot layers are: the frames the cards published
            // resolve in screen points, and a slab is placed from those.
            .backgroundPreferenceValue(BoardCardAnchorKey.self) { anchors in
                GeometryReader { proxy in
                    card3DLayer(cast, anchors: anchors, in: proxy)
                }
                // The same rect the stage covers, so the slabs and the mat
                // they lie on are projected through one camera in one space
                // rather than through the same camera in two.
                .ignoresSafeArea()
            }
            // The stage sits behind the whole board rather than inside the
            // scaled canvas: scenery should not shrink with the mat on a small
            // phone. It holds still while a jutsu plays so the frame budget
            // goes to the foreground.
            .background {
                FieldStage(isEffectPlaying: jutsuPlaying != nil)
            }
            // Above the mat and below the shot, and outside the zoom for the
            // same reason the shot is: the frames the cards published resolve
            // in screen points, so a projection stands over the card that cast
            // it even on a board that had to scale itself down.
            .overlayPreferenceValue(BoardCardAnchorKey.self) { anchors in
                GeometryReader { proxy in
                    hologramLayer(anchors, in: proxy)
                }
            }
            // Outside the zoom, so the endpoints the cards published resolve
            // in screen points and a shot drawn here lands on the card it was
            // aimed at even on a board that had to scale itself down.
            .overlayPreferenceValue(ProjectileAnchorKey.self) { anchors in
                GeometryReader { proxy in
                    projectileLayer(anchors, in: proxy)
                }
            }
        }
        .overlay { jutsuOverlay }
        .overlay(alignment: .top) { bannerView }
        .overlay(alignment: .bottom) { bottomPanel }
        .overlay { resultOverlay }
        .overlay { zoomOverlay }
        .sheet(item: $handPanel) { handCard in
            HandActionPanel(
                handCard: handCard,
                availableChakra: engine.availableChakra(for: nearSlot),
                asksToConfirm: settings.confirmJutsuSummon,
                onChoose: { option in
                    handPanel = nil
                    play(handCard, mode: option.mode)
                },
                onDismiss: { handPanel = nil }
            )
            .presentationDetents([.medium, .large])
        }
        .sheet(item: $offerSheet) { source in
            OfferSheet(
                title: offerTitle(source),
                offers: offers(for: source),
                onChoose: { offer in
                    offerSheet = nil
                    offer.perform()
                },
                onDismiss: { offerSheet = nil }
            )
            .presentationDetents([.medium, .large])
        }
        .sheet(item: listChoiceBinding) { choice in
            ChoicePanel(
                choice: choice,
                title: choiceTitle(choice),
                subtitle: choiceCardName,
                onResolve: { keys in resolveChoice(keys: keys) },
                onCancel: choice.cancellable ? { resolveChoice(keys: []) } : nil
            )
            .presentationDetents([.medium, .large])
            .interactiveDismissDisabled()
        }
        .sheet(isPresented: $showsJournal) {
            JournalSheet(journal: engine.journal) { showsJournal = false }
        }
        .task(id: revision) { await advanceAutomation() }
        .task(id: banner?.id) { await fadeBanner() }
        .task(id: attackShot?.id) { await sweepAttackShot() }
        .task(id: jutsuPlaying?.id) { await sweepJutsu() }
        .task(id: hologramExits.map(\.id)) { await sweepHologramExits() }
        // Watched rather than derived inside the overlay, because a hologram
        // that is collapsing belongs to a card the position no longer has: the
        // only place the departure is visible is the change itself.
        .onChange(of: hologramSubjects) { previous, current in
            trackHolograms(from: previous, to: current)
        }
        // The engine is Foundation-only and holds its own copy of the one
        // setting the rules care about, so the board keeps the two in step.
        .task(id: settings.autoPass) { engine.autoPass = settings.autoPass }
    }

    // MARK: Layouts

    /// Phone portrait: everything stacks, the journal hides behind a button and
    /// the reader becomes a bar along the bottom.
    private func compactBoard(_ layout: BoardLayout, slabs: Set<BoardCardAnchor>) -> some View {
        VStack(spacing: Metrics.spacingS) {
            side(farSlot, layout: layout, slabs: slabs)
            Spacer(minLength: 0)
            statusBar(layout)
            Spacer(minLength: 0)
            side(nearSlot, layout: layout, slabs: slabs)
            hand(layout)
            inspector(layout)
        }
        .padding(.horizontal, Metrics.spacingS)
        .padding(.vertical, Metrics.spacingS)
    }

    /// iPad and landscape: the reader keeps a permanent rail and the journal
    /// sits beside the status bar in the middle band.
    private func regularBoard(_ layout: BoardLayout, slabs: Set<BoardCardAnchor>) -> some View {
        HStack(alignment: .top, spacing: Metrics.spacingM) {
            VStack(spacing: Metrics.spacingS) {
                side(farSlot, layout: layout, slabs: slabs)
                Spacer(minLength: 0)
                middleBand(layout)
                Spacer(minLength: 0)
                side(nearSlot, layout: layout, slabs: slabs)
                hand(layout)
            }
            .frame(maxWidth: .infinity)

            inspector(layout)
                .frame(width: layout.railWidth)
        }
        .padding(Metrics.spacingM)
    }

    private func middleBand(_ layout: BoardLayout) -> some View {
        HStack(alignment: .top, spacing: Metrics.spacingM) {
            statusBar(layout)
            JournalPanel(journal: engine.journal)
                .frame(width: layout.railWidth)
        }
        .frame(height: BoardStatusBar.regularHeight)
    }

    // MARK: Bands

    private func side(
        _ slot: PlayerSlot,
        layout: BoardLayout,
        slabs: Set<BoardCardAnchor>
    ) -> some View {
        BoardSideView(
            slot: slot,
            title: displayName(for: slot),
            isNear: slot == nearSlot,
            isActive: slot == engine.currentPlayer && !engine.isFinished,
            layout: layout,
            engine: engine,
            emphasis: emphasis(for: slot),
            chakraFace: chakraFace,
            onRead: { read($0) },
            onSelectCharacter: { tapCharacter($0, on: slot) },
            onSelectLeader: { tapLeader(of: slot) },
            onSelectSupport: { tapSupport(at: $0, on: slot) },
            flashes: damageFlashes,
            onFlashFinished: { id in damageFlashes.removeAll { $0.id == id } },
            reveals: supportReveals.filter { $0.slot == slot },
            onRevealFinished: { id in supportReveals.removeAll { $0.id == id } },
            slabs: slabs
        )
        .frame(height: layout.sideHeight)
    }

    /// Reading a card: into the reader, and up to full size.
    ///
    /// The mat's read gesture is a long press, and "read this card in full" is
    /// exactly what the viewer is for — so one gesture does both rather than
    /// the board growing a second, quieter affordance nobody would find. The
    /// board can only ever be handed a card the side view was willing to
    /// reveal, which is what keeps an opposing face-down Support out of here.
    private func read(_ card: Card) {
        focusedCard = card
        zoomedCard = ZoomedCard(card)
    }

    private func statusBar(_ layout: BoardLayout) -> some View {
        BoardStatusBar(
            turnState: engine.turnState,
            turnNumber: engine.turnNumber,
            prompt: prompt,
            activePlayer: displayName(for: engine.currentPlayer),
            isCompact: layout.isCompact,
            hasSummoned: engine.hasSummonedThisTurn(engine.currentPlayer),
            journalCount: engine.journal.count,
            onShowJournal: layout.isCompact ? { showsJournal = true } : nil,
            onCancelTargeting: cancelTargetingAction,
            targetingNote: targetingNote
        )
        // The one piece of chrome that sits directly against a card row. The
        // hologram overlay holds the near side's projections below this frame,
        // so the band's text stays readable whatever stands on the mat.
        .boardCardAnchor(.statusBand)
    }

    /// The short instruction the band carries while the mat is lit for a
    /// target. It names what is being chosen; the prompt beside it is the
    /// card's own wording, which never says that the answer is a tap.
    private var targetingNote: String? {
        if let choice = engine.pendingChoice, isHumanControlled(choice.player) {
            guard isBoardPicked(choice) else { return nil }
            guard choice.maxSelections == 1 else { return "Choose up to \(choice.maxSelections)" }
            return handChoice == nil ? "Choose a target" : "Choose a card"
        }
        if armedAttacker != nil { return "Attack target" }
        return nil
    }

    /// Whether the hand is the thing the board is waiting on.
    ///
    /// A prompt and an armed attacker each own the next tap, so the strip greys
    /// out rather than opening a panel on top of them. A response window does
    /// not: the active player may answer their own attack's window with a jutsu
    /// straight from hand, and the panel names the refusal when they may not.
    private var handIsLive: Bool {
        guard !engine.isFinished, isHumanControlled(nearSlot) else { return false }
        guard engine.pendingChoice == nil, armedAttacker == nil else { return false }
        guard !engine.isAwaitingMulligan else { return false }
        if let window = engine.responseWindow { return window.respondingSlot == nearSlot }
        return nearSlot == engine.currentPlayer
    }

    /// The hand dims whole while something else owns the next tap — an armed
    /// attacker, or a prompt waiting on an answer.
    ///
    /// The exception is a prompt whose options ARE cards in hand: then the
    /// strip is the mat, and it lights the offered positions exactly as the
    /// board lights an offered body.
    private func hand(_ layout: BoardLayout) -> some View {
        HandView(
            cards: engine.handCards(for: nearSlot),
            cardWidth: layout.handCardWidth,
            selectedIndex: selectedHandIndex,
            isInteractive: handIsLive,
            emptyMessage: "\(displayName(for: nearSlot)) has no cards in hand.",
            choiceTargets: handChoiceTargets,
            stagedTargets: stagedHandIndices,
            onPlay: { tapHandCard($0) },
            onRead: { handCard in
                selectedHandIndex = handCard.id
                read(handCard.card)
            }
        )
        .frame(height: layout.handHeight)
    }

    private func inspector(_ layout: BoardLayout) -> some View {
        CardInspector(
            card: focusedCard,
            isCompact: layout.isCompact,
            actions: contextActions,
            soundEnabled: soundBinding,
            onLeave: { ask(.leave) }
        )
    }

    // MARK: Sides

    /// The half drawn at the bottom.
    ///
    /// Solo v Self hands the device back and forth, so the side being asked for
    /// a decision is always the one the right way up — the priority holder in a
    /// window and the answering player during a prompt included.
    private var nearSlot: PlayerSlot {
        guard configuration.mode != .versusAI else { return .player }
        return engine.decider ?? engine.currentPlayer
    }

    private var farSlot: PlayerSlot { nearSlot.opposing }

    /// The side that may act right now and is the person holding the device.
    /// Everything the board offers is addressed to this side.
    private var actingSlot: PlayerSlot? {
        guard !engine.isFinished, let decider = engine.decider else { return nil }
        return isHumanControlled(decider) ? decider : nil
    }

    /// Only the AI opponent plays itself.
    private func isHumanControlled(_ slot: PlayerSlot) -> Bool {
        configuration.mode == .versusAI ? slot == .player : true
    }

    private func displayName(for slot: PlayerSlot) -> String {
        switch configuration.mode {
        case .soloVersusSelf:
            return slot == .player ? "P1" : "P2"
        case .versusAI:
            return slot == .player ? preferredName : "The AI"
        case .online:
            return slot == .player ? preferredName : slot.title
        }
    }

    private var preferredName: String {
        let trimmed = settings.username.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? PlayerSlot.player.title : trimmed
    }

    /// The engine picks Chakra art by deck colour; the player's preference wins
    /// at render time when the pool still has that card.
    private var chakraFace: Card? {
        database.card(id: settings.chakraCardID)
    }

    // MARK: Prompt

    private var prompt: String {
        if engine.isFinished { return engine.outcome.summary }

        if let awaiting = engine.state.awaitingMulligan {
            return isHumanControlled(awaiting)
                ? "\(displayName(for: awaiting)): keep this hand, or draw a new one."
                : "\(displayName(for: awaiting)) is settling their opening hand."
        }

        // An open prompt outranks the turn it interrupts.
        if let choice = engine.pendingChoice {
            guard isHumanControlled(choice.player) else {
                return "\(displayName(for: choice.player)) is choosing."
            }
            guard choice.maxSelections > 1 else { return choice.prompt }
            return "\(choice.prompt) Up to \(choice.maxSelections), then confirm."
        }

        // An armed attacker owns the mat until it is pointed at something.
        if let armed = armedAttacker {
            return "\(attackerName(armed)) is attacking — choose the enemy Leader "
                + "or a rested character, or cancel."
        }

        if let window = engine.responseWindow {
            let who = displayName(for: window.respondingSlot)
            return isHumanControlled(window.respondingSlot)
                ? "\(who): \(window.prompt.lowercased()), or pass."
                : "\(who) may answer with a face-down card."
        }

        guard isHumanControlled(engine.currentPlayer) else {
            return "\(displayName(for: engine.currentPlayer)) is taking their turn."
        }

        // The reference's own words, and the whole of the turn: no phases, no
        // order, one control to leave it by.
        return "\(TurnState.acting.prompt)."
    }

    // MARK: Emphasis

    /// What one side should light up right now. Every set is read back off the
    /// engine's own validators, so a lit card is one `apply` will accept.
    private func emphasis(for slot: PlayerSlot) -> BoardEmphasis {
        var value = BoardEmphasis()

        if let choice = engine.pendingChoice, isHumanControlled(choice.player) {
            value.isChoosing = true
            for option in choice.options {
                mark(option.target, on: slot, staged: false, into: &value)
            }
            for key in stagedChoiceKeys {
                guard let option = choice.option(forKey: key) else { continue }
                mark(option.target, on: slot, staged: true, into: &value)
            }
            return value
        }

        guard let acting = actingSlot else { return value }

        // A window belongs to the responder alone: nothing else on the mat is
        // being asked for, so only their answerable Supports light up.
        if let window = engine.responseWindow {
            if slot == window.respondingSlot, slot == acting {
                value.answerableSupports = activatableSupportSlots(for: slot)
            }
            return value
        }

        // An armed attacker owns the whole mat, both halves: the only cards
        // still lit are the one chosen to swing with and the ones it may
        // legally be pointed at, taken from `canAttack` rather than restated.
        if let armed = armedAttacker {
            value.isTargetingAttack = true
            guard slot != acting else {
                switch armed {
                case .character(let id): value.selectedAttackerID = id
                case .leader:            value.leaderIsSelectedAttacker = true
                }
                return value
            }
            value.attackTargets = Set(
                engine.side(slot).characters
                    .filter { engine.canAttack(attacker: armed, target: .character($0.id), by: acting) }
                    .map(\.id)
            )
            value.leaderIsAttackTarget = engine.canAttack(attacker: armed, target: .leader, by: acting)
            return value
        }

        if slot == acting {
            value.answerableSupports = activatableSupportSlots(for: slot)
            value.attackers = Set(
                engine.side(slot).characters
                    .filter { engine.attackBlock(attacker: .character($0.id), by: slot) == nil }
                    .map(\.id)
            )
            value.leaderMayAttack = engine.attackBlock(attacker: .leader, by: slot) == nil

            let marks = abilityMarks(for: slot)
            value.readyAbilities = marks.ready
            value.spentAbilities = marks.spent
            value.leaderAbilityReady = engine.leaderEffectBlock(for: slot) == nil
                || engine.recoveryBlock(for: slot) == nil
            value.leaderNote = leaderNote(mayAttack: value.leaderMayAttack,
                                          abilityReady: value.leaderAbilityReady)
            return value
        }

        // With nothing armed and nothing being chosen, the far side is not
        // being asked for anything at all.
        return value
    }

    /// Records one prompt option against the side it belongs to.
    private func mark(
        _ target: ChoiceTarget,
        on slot: PlayerSlot,
        staged: Bool,
        into value: inout BoardEmphasis
    ) {
        switch target {
        case .character(let id):
            guard engine.side(slot).character(id: id) != nil else { return }
            if staged { value.stagedTargets.insert(id) } else { value.choiceTargets.insert(id) }
        case .leader(let owner):
            guard owner == slot else { return }
            if staged { value.leaderIsStaged = true } else { value.leaderIsChoiceTarget = true }
        case .handCard, .trashCard, .deckCard:
            return
        }
    }

    /// The Support slots the engine would accept an activation from right now —
    /// its own legality, so a "Support Activated" card stays dark in a summon
    /// window and lights the moment a chain exists.
    private func activatableSupportSlots(for slot: PlayerSlot) -> Set<Int> {
        Set(
            engine.side(slot).faceDownSupports
                .filter { engine.slotActivationBlock(slotIndex: $0.slotIndex, by: slot) == nil }
                .map(\.slotIndex)
        )
    }

    /// Which bodies can activate a printed box now, and which have spent one.
    private func abilityMarks(for slot: PlayerSlot) -> (ready: Set<UUID>, spent: Set<UUID>) {
        var ready: Set<UUID> = []
        var spent: Set<UUID> = []
        for character in engine.side(slot).characters {
            guard let card = engine.card(for: character),
                  card.abilities.contains(where: { $0.trigger == .activateMain }) else { continue }
            if engine.characterAbilityBlock(character.id, by: slot) == nil {
                ready.insert(character.id)
            } else if character.activatedThisTurn {
                spent.insert(character.id)
            }
        }
        return (ready, spent)
    }

    /// The line drawn under the Leader, naming what it is offering.
    ///
    /// Only offers: the states holding a Leader back — frozen, rested, its one
    /// attack spent — are already worn as chips beside the card, and saying
    /// them twice on a phone-sized column reads as two different facts.
    private func leaderNote(mayAttack: Bool, abilityReady: Bool) -> String? {
        if mayAttack && abilityReady { return "Attack and ability ready" }
        if mayAttack { return "Attack ready" }
        if abilityReady { return "Ability ready" }
        return nil
    }

    // MARK: Response window

    /// The window, drawn over the bottom of the board while it is this player's
    /// to answer.
    ///
    /// It is an overlay rather than a sheet because the mat is the other half of
    /// the decision: the attack or the summon being answered is on it, and a
    /// sheet would hide exactly the thing the player is deciding about.
    @ViewBuilder
    private var responsePanel: some View {
        if let window = engine.responseWindow,
           engine.pendingChoice == nil,
           isHumanControlled(window.respondingSlot),
           window.respondingSlot == nearSlot,
           !engine.isFinished {
            ResponseWindowPanel(
                window: window,
                subject: responseSubject(window),
                answers: responseAnswers(for: window.respondingSlot),
                availableChakra: engine.availableChakra(for: window.respondingSlot),
                isCompact: horizontalSizeClass == .compact,
                onActivate: { answer in activate(answer, by: window.respondingSlot) },
                onPass: { perform(.passCounter, by: window.respondingSlot) }
            )
            .padding(Metrics.spacingS)
            .transition(panelTransition)
        }
    }

    /// One sentence naming what the window is holding up, so the player knows
    /// what they are answering before they spend anything.
    private func responseSubject(_ window: ResponseWindow) -> String {
        if let attack = engine.pendingAttack {
            let attacker = name(of: attack.attacker, on: attack.attackingSlot)
            let target: String
            switch attack.target {
            case .leader:
                target = "\(displayName(for: attack.defendingSlot))'s Leader"
            case .character(let id):
                target = engine.locateCharacter(id: id)
                    .flatMap { engine.card(for: $0.character)?.name } ?? "a rested character"
            }
            return "\(attacker) is attacking \(target)."
        }

        if let link = engine.state.chain.last {
            let name = engine.card(for: link.cardID)?.name ?? link.cardID
            let depth = window.chainLength == 1 ? "1 card" : "\(window.chainLength) cards"
            return "\(displayName(for: link.player)) activated \(name). \(depth) on the chain."
        }

        // A summon window: the body that just arrived is the last one placed.
        let summoner = window.respondingSlot.opposing
        let arrival = engine.side(summoner).characters.last
            .flatMap { engine.card(for: $0)?.name }
        return arrival.map { "\(displayName(for: summoner)) summoned \($0)." }
            ?? "\(displayName(for: summoner)) summoned a character."
    }

    /// Everything this player could answer the window with: their face-down
    /// Supports, each with the engine's reason when it is refused, and — for
    /// the active player, who alone may play from hand — the jutsu in hand the
    /// engine would accept right now.
    private func responseAnswers(for slot: PlayerSlot) -> [ResponseAnswer] {
        var answers = engine.faceDownSupports(for: slot).map { support in
            ResponseAnswer(
                origin: .slot(support.slotIndex),
                card: support.card,
                ability: support.ability,
                chakraCost: support.chakraCost,
                refusal: engine.slotActivationBlock(slotIndex: support.slotIndex, by: slot)?.message
            )
        }

        for handCard in engine.handCards(for: slot) {
            guard let bar = handCard.card.supportBarAbility,
                  engine.handActivationBlock(handIndex: handCard.id, by: slot) == nil else { continue }
            answers.append(
                ResponseAnswer(
                    origin: .hand(handCard.id),
                    card: handCard.card,
                    ability: bar.ability,
                    chakraCost: bar.ability.cost.chakra,
                    refusal: nil
                )
            )
        }
        return answers
    }

    private func activate(_ answer: ResponseAnswer, by slot: PlayerSlot) {
        switch answer.origin {
        case .slot(let index):
            perform(.activateSupport(slotIndex: index), by: slot)
        case .hand(let index):
            perform(.activateSupportFromHand(handIndex: index), by: slot)
        }
    }

    // MARK: Taps

    /// A hand tap opens the card's action panel: SUMMON, SET AS SUPPORT and
    /// ACTIVATE …, each with the reason it is refused when it is refused. An
    /// unplayable card still lands in the reader.
    private func tapHandCard(_ handCard: HandCard) {
        focusedCard = handCard.card
        selectedHandIndex = handCard.id

        // A prompt picking from the hand is answered by tapping the card, the
        // same way a prompt picking from the mat is.
        if handChoice != nil {
            chooseFromBoard(.handCard(index: handCard.id))
            return
        }

        if engine.pendingChoice != nil {
            show("Answer the open prompt first.")
            return
        }
        if let armed = armedAttacker {
            show("\(attackerName(armed)) is waiting for a target, or cancel it first.")
            return
        }

        // The reference opens the action panel every time a card is selected,
        // refused modes included: "Summon already used this turn" is a rule a
        // player can only learn by reading it against the button it refuses.
        // It opens only while the hand is the board's to play from, though —
        // the modes are worked out from the printed rules, and a finished game
        // is not a moment any of them answer to.
        guard handIsLive else { return }
        handPanel = handCard
    }

    /// Commits a play. Targets are picked by the engine's own prompts once the
    /// activation is on the chain, so the board never has to arm the mat first.
    private func play(_ handCard: HandCard, mode: CardPlayMode) {
        switch mode {
        case .summon:       perform(.summon(handIndex: handCard.id), by: nearSlot)
        case .setAsSupport: perform(.setSupport(handIndex: handCard.id), by: nearSlot)
        case .jutsu:        perform(.activateSupportFromHand(handIndex: handCard.id), by: nearSlot)
        }
    }

    private func tapCharacter(_ character: CharacterInPlay, on slot: PlayerSlot) {
        if let card = engine.card(for: character) { focusedCard = card }

        if engine.pendingChoice != nil {
            chooseFromBoard(.character(character.id))
            return
        }

        // An open window is answered from the Support row, never from a body.
        guard engine.responseWindow == nil else { return }
        guard let acting = actingSlot else { return }

        if let armed = armedAttacker {
            guard slot != acting else {
                // Tapping the armed body again is the way back out.
                if case .character(let id) = armed, id == character.id { cancelTargeting() }
                return
            }
            guard engine.canAttack(attacker: armed, target: .character(character.id), by: acting) else {
                show("Only the enemy Leader and rested characters can be attacked.")
                return
            }
            requestAttack(
                attacker: armed,
                target: .character(character.id),
                targetName: engine.card(for: character)?.name ?? "that character"
            )
            return
        }

        guard slot == acting else {
            show("Choose one of your cards to attack with first.")
            return
        }

        // With no attack phase to be in, a body that can swing answers a tap as
        // "attack with this". One that cannot opens its offers instead.
        if engine.attackBlock(attacker: .character(character.id), by: slot) == nil {
            withAnimation(.easeOut(duration: 0.15)) {
                armedAttacker = .character(character.id)
            }
            return
        }
        offerSheet = .character(character.id)
    }

    /// A tap on a Support slot.
    ///
    /// A face-down card the engine would accept is activated on the spot — that
    /// is how a window is answered and how a "During Your Main" jutsu is played
    /// from the mat. Otherwise the tap reads the card, which on your own side is
    /// how you check what you set.
    private func tapSupport(at slotIndex: Int, on slot: PlayerSlot) {
        let supports = engine.side(slot).supports
        guard supports.indices.contains(slotIndex), let placed = supports[slotIndex] else { return }

        if let card = engine.card(for: placed), placed.isRevealed || slot == nearSlot {
            focusedCard = card
        }

        guard engine.pendingChoice == nil, isHumanControlled(slot), slot == actingSlot else { return }

        switch engine.slotActivationBlock(slotIndex: slotIndex, by: slot) {
        case nil:
            perform(.activateSupport(slotIndex: slotIndex), by: slot)
        case .some(let error):
            // A window is where a refusal is worth reading; outside one a
            // face-down card is usually just being checked.
            if engine.responseWindow != nil { show(error.message) }
        }
    }

    /// A tap on a Leader. It is a card in play like any other now: it attacks,
    /// it prints boxes, and on the far side it is always a legal attack target.
    private func tapLeader(of slot: PlayerSlot) {
        if let leader = engine.leaderCard(for: slot) { focusedCard = leader }

        if engine.pendingChoice != nil {
            chooseFromBoard(.leader(slot))
            return
        }

        guard engine.responseWindow == nil, let acting = actingSlot else { return }

        if let armed = armedAttacker {
            guard slot != acting else {
                if case .leader = armed { cancelTargeting() }
                return
            }
            requestAttack(
                attacker: armed,
                target: .leader,
                targetName: engine.leaderCard(for: slot)?.name ?? "the Leader"
            )
            return
        }

        guard slot == acting else {
            show("Choose one of your cards to attack with first.")
            return
        }
        offerSheet = .leader
    }

    /// Aims the armed attacker.
    ///
    /// With `targetConfirm` set to ask, the attacker and its target both stay
    /// lit on the mat while the panel asks — which is the whole reason the
    /// question is a panel rather than an alert.
    private func requestAttack(attacker: AttackerReference, target: AttackTarget, targetName: String) {
        guard settings.targetConfirm == .askMe else {
            perform(.declareAttack(attacker: attacker, target: target), by: engine.currentPlayer)
            return
        }
        ask(.attack(attacker: attacker, target: target, targetName: targetName))
    }

    /// Opens the in-board confirmation panel.
    private func ask(_ pending: BoardConfirmation) {
        withAnimation(.easeOut(duration: 0.2)) { confirmation = pending }
    }

    /// Closes it without acting. The armed attacker is deliberately left where
    /// it is, so backing out of a target lands the player back in targeting
    /// rather than at the start of the decision.
    private func dismissConfirmation() {
        withAnimation(.easeOut(duration: 0.2)) { confirmation = nil }
    }

    /// Backs out of the armed attacker.
    private func cancelTargeting() {
        withAnimation(.easeOut(duration: 0.15)) { armedAttacker = nil }
    }

    /// The cancel the status band offers, when there is something to back out
    /// of: an armed attacker, or targets staged for a prompt.
    private var cancelTargetingAction: (() -> Void)? {
        if armedAttacker != nil { return { cancelTargeting() } }
        if !stagedChoiceKeys.isEmpty { return { stagedChoiceKeys.removeAll() } }
        return nil
    }

    // MARK: Prompts

    /// The open prompt, when it is this player's and picked from the mat.
    private var boardChoice: PendingChoice? {
        guard let choice = engine.pendingChoice, isHumanControlled(choice.player) else { return nil }
        return isBoardPicked(choice) ? choice : nil
    }

    /// The open prompt, when it is this player's and picked from a zone the
    /// board cannot draw — the deck or the trash. The hand is not one of
    /// those: it is on screen, so it is picked from on screen.
    private var listChoice: PendingChoice? {
        guard let choice = engine.pendingChoice, isHumanControlled(choice.player) else { return nil }
        return isBoardPicked(choice) ? nil : choice
    }

    /// Sheets need a binding; a prompt is dismissed by answering it, never by
    /// swiping it away, so the setter deliberately does nothing.
    private var listChoiceBinding: Binding<PendingChoice?> {
        Binding(get: { listChoice }, set: { _ in })
    }

    /// A prompt every option of which points at something the player can see
    /// and touch: a card in play, or a card in their own hand.
    ///
    /// Deck and trash picks are the only ones the mat genuinely cannot show —
    /// there is nowhere on the board those cards are drawn — so they are the
    /// only ones that fall through to a list.
    private func isBoardPicked(_ choice: PendingChoice) -> Bool {
        choice.options.allSatisfy { option in
            switch option.target {
            case .character, .leader, .handCard: return true
            case .trashCard, .deckCard:          return false
            }
        }
    }

    /// The open prompt, when its options are cards in the near player's hand.
    private var handChoice: PendingChoice? {
        guard let choice = boardChoice else { return nil }
        return choice.options.contains { option in
            if case .handCard = option.target { return true }
            return false
        } ? choice : nil
    }

    /// Hand positions the open prompt offers, for the strip to light up.
    private var handChoiceTargets: Set<Int>? {
        guard let choice = handChoice, choice.player == nearSlot else { return nil }
        return Set(choice.options.compactMap { option in
            if case .handCard(let index) = option.target { return index }
            return nil
        })
    }

    /// Hand positions already staged for a prompt that takes several.
    private var stagedHandIndices: Set<Int> {
        guard let choice = handChoice else { return [] }
        return Set(stagedChoiceKeys.compactMap { key -> Int? in
            guard case .handCard(let index)? = choice.option(forKey: key)?.target else { return nil }
            return index
        })
    }

    /// A tap on the mat while a board-picked prompt is open.
    ///
    /// One pick resolves at once when the player asked for that, and stages for
    /// confirmation otherwise; a multi-target lock always stages, because the
    /// whole answer travels in one action.
    private func chooseFromBoard(_ target: ChoiceTarget) {
        guard let choice = boardChoice else { return }
        guard let option = choice.options.first(where: { $0.target == target }) else {
            show("That is not one of the offered options.")
            return
        }

        if let index = stagedChoiceKeys.firstIndex(of: option.key) {
            stagedChoiceKeys.remove(at: index)
            return
        }

        guard choice.maxSelections > 1 || settings.targetConfirm == .askMe else {
            resolveChoice(keys: [option.key])
            return
        }

        withAnimation(.easeOut(duration: 0.15)) {
            if stagedChoiceKeys.count >= choice.maxSelections { stagedChoiceKeys.removeFirst() }
            stagedChoiceKeys.append(option.key)
        }
        // A single-target prompt the player asked to confirm still resolves from
        // the reader's CONFIRM button, so nothing is spent on a stray tap.
    }

    private func resolveChoice(keys: [String]) {
        guard let choice = engine.pendingChoice else { return }
        stagedChoiceKeys.removeAll()
        perform(.resolveChoice(keys: keys), by: choice.player)
    }

    private func choiceTitle(_ choice: PendingChoice) -> String {
        choice.prompt
    }

    /// The card that raised the open prompt, named for the sheet's subtitle.
    private var choiceCardName: String? {
        guard let choice = engine.pendingChoice else { return nil }
        return engine.card(for: choice.data.sourceCardID)?.name
    }

    // MARK: Offers

    /// Whose offers the sheet is showing.
    private enum OfferSource: Identifiable {
        case leader
        case character(UUID)

        /// Everything the acting side controls, opened from the reader.
        case everything

        var id: String {
            switch self {
            case .leader:            return "leader"
            case .character(let id): return "character-\(id.uuidString)"
            case .everything:        return "everything"
            }
        }
    }

    private func offerTitle(_ source: OfferSource) -> String {
        guard let acting = actingSlot else { return "Abilities" }
        switch source {
        case .leader:
            return engine.leaderCard(for: acting)?.name ?? "Leader"
        case .character(let id):
            return engine.locateCharacter(id: id)
                .flatMap { engine.card(for: $0.character)?.name } ?? "Character"
        case .everything:
            return "Abilities"
        }
    }

    /// Everything the chosen card — or the whole side — can do right now, with
    /// the engine's own refusal under anything it will not accept.
    private func offers(for source: OfferSource) -> [BoardOffer] {
        guard let acting = actingSlot else { return [] }
        switch source {
        case .leader:
            return leaderOffers(for: acting)
        case .character(let id):
            return characterOffers(id, for: acting)
        case .everything:
            return leaderOffers(for: acting)
                + engine.side(acting).characters.flatMap { characterOffers($0.id, for: acting) }
        }
    }

    /// The Leader's three: its attack, its printed Activate: Main, and Recovery.
    private func leaderOffers(for slot: PlayerSlot) -> [BoardOffer] {
        guard let leader = engine.leaderCard(for: slot) else { return [] }
        var offers: [BoardOffer] = [
            BoardOffer(
                id: "leader-attack",
                headline: "Attack — rests the Leader",
                text: "Declare an attack on the enemy Leader or a rested enemy character. "
                    + "Once per turn.",
                refusal: engine.attackBlock(attacker: .leader, by: slot)?.message,
                perform: { armAttacker(.leader) }
            )
        ]

        for ability in leader.abilities where ability.trigger == .activateMain {
            offers.append(
                BoardOffer(
                    id: "leader-activate",
                    headline: ability.activationHeadline,
                    text: ability.text,
                    refusal: engine.leaderEffectBlock(for: slot)?.message,
                    perform: { perform(.leaderEffect, by: slot) }
                )
            )
        }

        for ability in leader.abilities where ability.trigger == .recovery {
            offers.append(
                BoardOffer(
                    id: "leader-recovery",
                    headline: "Recovery — rests the Leader",
                    text: ability.text,
                    refusal: engine.recoveryBlock(for: slot)?.message,
                    perform: { perform(.recovery, by: slot) }
                )
            )
        }
        return offers
    }

    /// A body's: its attack, and any printed Activate: Main.
    private func characterOffers(_ characterID: UUID, for slot: PlayerSlot) -> [BoardOffer] {
        guard let character = engine.side(slot).character(id: characterID),
              let card = engine.card(for: character) else { return [] }

        var offers: [BoardOffer] = [
            BoardOffer(
                id: "attack-\(characterID.uuidString)",
                headline: "Attack — rests \(card.name)",
                text: "Declare an attack on the enemy Leader or a rested enemy character.",
                refusal: engine.attackBlock(attacker: .character(characterID), by: slot)?.message,
                perform: { armAttacker(.character(characterID)) }
            )
        ]

        for ability in card.abilities where ability.trigger == .activateMain {
            offers.append(
                BoardOffer(
                    id: "activate-\(characterID.uuidString)",
                    headline: ability.activationHeadline,
                    text: ability.text,
                    refusal: engine.characterAbilityBlock(characterID, by: slot)?.message,
                    perform: { perform(.activateCharacter(characterID), by: slot) }
                )
            )
        }
        return offers
    }

    private func armAttacker(_ attacker: AttackerReference) {
        withAnimation(.easeOut(duration: 0.15)) { armedAttacker = attacker }
    }

    private func attackerName(_ attacker: AttackerReference) -> String {
        name(of: attacker, on: actingSlot ?? engine.currentPlayer)
    }

    private func name(of attacker: AttackerReference, on slot: PlayerSlot) -> String {
        switch attacker {
        case .leader:
            return engine.leaderCard(for: slot)?.name ?? "The Leader"
        case .character(let id):
            return engine.locateCharacter(id: id)
                .flatMap { engine.card(for: $0.character)?.name } ?? "A character"
        }
    }

    // MARK: Contextual actions

    /// What the reader offers right now, with the card viewer on the end.
    ///
    /// "Card details" is the named way into the full-screen viewer — the mat's
    /// long press is the quick one — and it is last because it never changes
    /// the game, so on a phone, where only the first three buttons fit, it
    /// gives way to anything that does.
    private var contextActions: [BoardAction] {
        if engine.isFinished {
            return [BoardAction(id: "again", title: "Play again", style: .primary, perform: onPlayAgain)]
        }
        return turnActions + detailsAction
    }

    /// The full-screen viewer, offered whenever the reader holds a card.
    private var detailsAction: [BoardAction] {
        guard let focusedCard else { return [] }
        return [
            BoardAction(id: "details", title: "Card details", shortTitle: "Details") {
                zoomedCard = ZoomedCard(focusedCard)
            }
        ]
    }

    private var turnActions: [BoardAction] {
        if let awaiting = engine.state.awaitingMulligan {
            guard isHumanControlled(awaiting) else { return [] }
            return [
                BoardAction(id: "keep", title: "Keep this hand", style: .primary) {
                    perform(.mulligan(keep: true), by: awaiting)
                },
                BoardAction(id: "mulligan", title: "Mulligan") {
                    perform(.mulligan(keep: false), by: awaiting)
                }
            ]
        }

        if let choice = boardChoice {
            var actions = [
                BoardAction(
                    id: "confirm",
                    title: confirmChoiceTitle(choice),
                    shortTitle: "Confirm",
                    style: .primary,
                    isEnabled: !stagedChoiceKeys.isEmpty
                ) {
                    resolveChoice(keys: stagedChoiceKeys)
                }
            ]
            if choice.cancellable {
                actions.append(
                    BoardAction(id: "decline", title: "Decline", shortTitle: "Decline") {
                        resolveChoice(keys: [])
                    }
                )
            }
            return actions
        }

        // A window has a panel of its own over the mat, and the prompt sheet
        // answers itself, so the reader keeps out of both.
        if engine.pendingChoice != nil || engine.responseWindow != nil { return [] }

        if armedAttacker != nil {
            return [
                BoardAction(id: "cancel", title: "Cancel the attack", shortTitle: "Cancel", style: .primary) {
                    cancelTargeting()
                }
            ]
        }

        guard let acting = actingSlot else { return [] }

        // The turn is undivided, so END TURN is the only turn control there is.
        var actions: [BoardAction] = [
            BoardAction(id: "turn", title: "End turn", style: .primary) { requestEndTurn() }
        ]
        if let abilities = abilitiesAction(for: acting) { actions.append(abilities) }
        return actions
    }

    /// A prompt over the hand is picking cards; one over the mat is picking
    /// targets. The button says which, because they are not the same thing and
    /// a player mid-effect has no other clue.
    private func confirmChoiceTitle(_ choice: PendingChoice) -> String {
        let noun = handChoice == nil ? "target" : "card"
        guard choice.maxSelections > 1 else { return "Confirm the \(noun)" }
        let count = stagedChoiceKeys.count
        return count == 1 ? "Confirm 1 \(noun)" : "Confirm \(count) \(noun)s"
    }

    /// The one control that reaches every printed box on the cards a player
    /// controls, plus the Leader's attack. It exists as well as the card taps
    /// because a tap on a body that can swing already means "attack with it".
    private func abilitiesAction(for slot: PlayerSlot) -> BoardAction? {
        let offers = offers(for: .everything)
        let live = offers.filter(\.isEnabled).count
        guard !offers.isEmpty else { return nil }
        return BoardAction(
            id: "abilities",
            title: live == 0 ? "Card actions" : "Card actions (\(live))",
            shortTitle: "Actions"
        ) {
            offerSheet = .everything
        }
    }

    private func requestEndTurn() {
        guard settings.endTurnConfirm == .askMe else {
            perform(.endTurn, by: engine.currentPlayer)
            return
        }
        ask(.endTurn)
    }

    private var soundBinding: Binding<Bool> {
        Binding(
            get: { settings.soundEnabled },
            set: { settings.soundEnabled = $0 }
        )
    }

    // MARK: Applying

    /// The single door from the UI into the rules. Everything the board does
    /// goes through here so refusals are reported the same way every time.
    @discardableResult
    private func perform(
        _ action: GameAction,
        by slot: PlayerSlot,
        announcesErrors: Bool = true
    ) -> Bool {
        let before = BoardSnapshot(engine: engine)

        // Measured before the rules run. A declaration nobody can answer rests
        // the attacker, resolves and takes the target off the mat inside this
        // single call, so the two cards have to be found while they are both
        // still on it — see `AttackShot`.
        let shot = plannedShot(for: action, by: slot)

        switch engine.apply(action, by: slot) {
        case .success:
            // The panels hold a snapshot of a board that has just moved, so
            // they close with everything else rather than offering plays that
            // may no longer be legal.
            handPanel = nil
            offerSheet = nil
            withAnimation(.easeOut(duration: 0.22)) {
                confirmation = nil
                armedAttacker = nil
                selectedHandIndex = nil
                stagedChoiceKeys.removeAll()
                banner = nil
            }
            if let shot { attackShot = shot }
            react(to: before)
            revision += 1
            return true

        case .failure(let error):
            if announcesErrors { show(error.message) }
            return false
        }
    }

    // MARK: Feedback

    /// Turns what the action changed into what the mat shows.
    ///
    /// The engine reports nothing about its own resolution — it validates,
    /// mutates and journals — so the two pieces of feedback the board owes are
    /// worked out here by comparing the position either side of `apply`. Damage
    /// and life come from the board itself; a jutsu going off comes from the
    /// one line the engine writes when a chain link resolves, because a card
    /// played from hand is created and disposed of inside a single `apply` and
    /// leaves no trace on either side of it.
    private func react(to before: BoardSnapshot) {
        // A number aimed at a body that has since left the board is drawn by
        // nothing and can therefore never report itself finished, so it is
        // swept here rather than left to pile up over a long game.
        damageFlashes.removeAll { flash in
            guard case .character(let id) = flash.target else { return false }
            return engine.locateCharacter(id: id) == nil
        }

        // A reveal whose slot the engine has refilled is drawn by nothing from
        // here on — the card set into the slot is the real occupant — so it can
        // never report itself finished either, and gets the same sweep.
        supportReveals.removeAll { reveal in
            let supports = engine.side(reveal.slot).supports
            guard reveal.slotIndex < supports.count,
                  let placed = supports[reveal.slotIndex] else { return false }
            return placed.id != reveal.supportID
        }

        damageFlashes.append(contentsOf: landedHits(since: before))
        supportReveals.append(contentsOf: turnedSupports(since: before))
        queueJutsuEffects(since: before)
    }

    /// Every Support that turned face-up in this action.
    ///
    /// Two shapes count as turning up. One is a card still sitting in its slot
    /// with its reveal flag newly set: a Support on the chain, waiting out the
    /// window it opened. The other is a card that has left its slot entirely,
    /// which is what happens when the chain resolves inside the same `apply` —
    /// and the only two ways out of a Support slot are resolving on the chain
    /// and being negated on it. Both put the card on the chain first, so a
    /// departure is always a card both players have already seen, and drawing
    /// it leaks nothing.
    ///
    /// A card that was face-up before it left is marked as such, so the hold
    /// that keeps it in the emptied slot does not blur it back down and focus
    /// it a second time.
    ///
    /// A card the pool cannot name is skipped: the slot would draw nothing for
    /// it, and a reveal nothing draws is a reveal nothing can report finished.
    private func turnedSupports(since before: BoardSnapshot) -> [SupportReveal] {
        var found: [SupportReveal] = []

        for slot in PlayerSlot.allCases {
            let was = before.supports[slot] ?? []
            let now = engine.side(slot).supports

            for index in was.indices {
                guard let held = was[index] else { continue }
                let current = index < now.count ? now[index] : nil

                let turnedUp: Bool
                let wasAlreadyUp: Bool
                if let current, current.id == held.id {
                    turnedUp = current.isRevealed && !held.isRevealed
                    wasAlreadyUp = false
                } else {
                    turnedUp = true
                    wasAlreadyUp = held.isRevealed
                }

                guard turnedUp, database.card(id: held.cardID) != nil else { continue }
                // One hold at a time per card: a Support that resolves before
                // the hold it earned on activation has run out keeps that one
                // rather than starting a second.
                guard !supportReveals.contains(where: { $0.supportID == held.id }) else { continue }

                found.append(SupportReveal(
                    supportID: held.id,
                    slot: slot,
                    slotIndex: index,
                    cardID: held.cardID,
                    wasAlreadyUp: wasAlreadyUp
                ))
            }
        }
        return found
    }

    /// Every hit worth a floating number: damage that landed on a body still in
    /// play, and life that came off — or went onto — a Leader.
    ///
    /// A body that was knocked out is deliberately absent. It is no longer on
    /// the mat by the time this runs, and leaving the row is already the
    /// treatment a knockout gets.
    private func landedHits(since before: BoardSnapshot) -> [DamageFlash] {
        var flashes: [DamageFlash] = []

        for slot in PlayerSlot.allCases {
            let side = engine.side(slot)

            if let was = before.life[slot], was != side.life {
                flashes.append(DamageFlash(
                    target: .leader(slot),
                    amount: abs(side.life - was),
                    kind: side.life < was ? .damage : .heal
                ))
            }

            for character in side.characters {
                guard let was = before.damage[character.id], character.damage > was else { continue }
                flashes.append(DamageFlash(
                    target: .character(character.id),
                    amount: character.damage - was,
                    kind: .damage
                ))
            }
        }
        return flashes
    }

    /// Reads the lines this action wrote and queues an effect for each jutsu
    /// that resolved in it.
    private func queueJutsuEffects(since before: BoardSnapshot) {
        for line in before.linesAdded(to: engine.journal) {
            guard let effect = JutsuLookup.effect(for: line, in: database) else { continue }
            jutsuQueue.append(JutsuPlay(effect: effect))
        }
        if jutsuQueue.count > Self.jutsuQueueLimit {
            jutsuQueue.removeFirst(jutsuQueue.count - Self.jutsuQueueLimit)
        }
        startNextJutsu()
    }

    /// Starts the next queued effect when nothing is playing. Effects play one
    /// at a time: two flares over the same board at once read as one long
    /// smear rather than as two jutsu.
    private func startNextJutsu() {
        guard jutsuPlaying == nil, !jutsuQueue.isEmpty else { return }
        jutsuPlaying = jutsuQueue.removeFirst()
    }

    /// The jutsu effect, over the whole board.
    ///
    /// Presentation only. The engine resolved before this was ever installed,
    /// so the overlay takes no touches at all — a player who taps through it is
    /// playing the board underneath rather than waiting on a picture, and one
    /// who never looks up loses nothing.
    @ViewBuilder
    private var jutsuOverlay: some View {
        if let play = jutsuPlaying {
            JutsuEffectView(effect: play.effect) {
                jutsuPlaying = nil
                startNextJutsu()
            }
            .id(play.id)
            .allowsHitTesting(false)
        }
    }

    /// Clears an effect that never reported itself finished.
    ///
    /// `JutsuEffectView` reports when its clock runs out, but only while it is
    /// mounted. A board torn down and rebuilt under it would otherwise leave
    /// `jutsuPlaying` set forever, and every effect queued behind it would wait
    /// on a picture that is no longer on screen. The slack is generous because
    /// this is a backstop, not the schedule.
    private func sweepJutsu() async {
        guard let current = jutsuPlaying else { return }
        try? await Task.sleep(for: .seconds(current.effect.duration + 1))
        guard !Task.isCancelled, jutsuPlaying?.id == current.id else { return }
        jutsuPlaying = nil
        startNextJutsu()
    }

    // MARK: Attack shots

    /// The declared attack, drawn over the whole mat.
    ///
    /// The endpoints the cards published resolve here, in this overlay's own
    /// space, and every resolved centre is kept in `cardCentres` so a shot can
    /// be aimed by `plannedShot(for:by:)` at cards that are about to leave.
    ///
    /// Presentation only, like the jutsu overlay above it: the rules have
    /// already decided the attack by the time a shot exists, so it takes no
    /// touches and nothing waits on it.
    @ViewBuilder
    private func projectileLayer(
        _ anchors: [ProjectileAnchor: Anchor<CGRect>],
        in proxy: GeometryProxy
    ) -> some View {
        let centres = anchors.mapValues { proxy.projectileCentre(of: $0) }

        ZStack {
            if let shot = attackShot {
                AttackProjectileView(
                    from: shot.from,
                    to: shot.to,
                    style: shot.style,
                    salt: shot.salt,
                    onFinished: { attackShot = nil }
                )
                .id(shot.id)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .allowsHitTesting(false)
        .onChange(of: centres, initial: true) { _, latest in cardCentres.points = latest }
    }

    /// The shot an action is about to throw, measured on the board as it
    /// currently stands. `nil` for anything that is not a declaration, and for
    /// a declaration whose two cards have not been measured yet.
    private func plannedShot(for action: GameAction, by slot: PlayerSlot) -> AttackShot? {
        guard case .declareAttack(let attacker, let target) = action else { return nil }
        let centres = cardCentres.points
        guard let from = centres[anchor(for: attacker, on: slot)],
              let to = centres[anchor(for: target, on: slot.opposing)] else { return nil }

        return AttackShot(
            from: from,
            to: to,
            style: shotStyle(for: attacker, on: slot),
            salt: UInt64(max(0, revision))
        )
    }

    private func anchor(for attacker: AttackerReference, on slot: PlayerSlot) -> ProjectileAnchor {
        switch attacker {
        case .leader:            return .leader(slot)
        case .character(let id): return .character(id)
        }
    }

    private func anchor(for target: AttackTarget, on slot: PlayerSlot) -> ProjectileAnchor {
        switch target {
        case .leader:            return .leader(slot)
        case .character(let id): return .character(id)
        }
    }

    /// Which of the two shots an attacker throws.
    ///
    /// Split on the printed colour, which is the one difference between cards a
    /// player already reads off the mat — so the shot repeats something they
    /// know rather than teaching them a third vocabulary. Blue arcs; red and
    /// green burn.
    private func shotStyle(
        for attacker: AttackerReference,
        on slot: PlayerSlot
    ) -> AttackProjectileView.Style {
        let card: Card?
        switch attacker {
        case .leader:
            card = engine.leaderCard(for: slot)
        case .character(let id):
            card = engine.side(slot).character(id: id).flatMap { engine.card(for: $0) }
        }
        return card?.color == .blue ? .energy : .fireball
    }

    /// Clears a shot the projectile itself never reported.
    ///
    /// The view reports when it has landed, but only while it is mounted, and a
    /// board that re-laid itself out from under the shot would otherwise leave
    /// `attackShot` set and swallow every declaration after it.
    private func sweepAttackShot() async {
        guard let current = attackShot else { return }
        try? await Task.sleep(for: .seconds(ProjectileTiming.total + 0.8))
        guard !Task.isCancelled, attackShot?.id == current.id else { return }
        attackShot = nil
    }

    // MARK: 3D cards

    /// The cards in play the board is drawing as slabs on the field stage.
    ///
    /// Empty is the whole fallback: every 2D face draws its printing exactly
    /// as it did before this layer existed, so a device that has asked for
    /// less — the player's switch, Reduce Motion, Low Power Mode, a warm
    /// chassis — gets the flat board with nothing missing and nothing
    /// misplaced. The reasoning for each of those is in `BoardCard3DBudget`,
    /// and it is asked here, once, so the faces and the scene are told the
    /// same thing in the same pass.
    ///
    /// What it is deliberately NOT emptied by is the card viewer or a jutsu:
    /// the board stays visible behind both, and a card that swapped renderer
    /// under a dim scrim would read as the mat glitching. Those hold the
    /// slabs STILL instead — `isPaused` below — which is where the cost
    /// actually is.
    private var card3DCast: [BoardCard3DSubject] {
        guard BoardCard3DBudget.rendersSlabs(
            isEnabled: cards3DEnabled,
            reduceMotion: reduceMotion
        ) else { return [] }

        return BoardCard3DCast.subjects(
            engine: engine,
            // The same lookup the Chakra row draws its marker from, so the
            // slab and the card under it are one decision.
            summonCard: BoardPoolLookup.summon(in: engine.database),
            reveals: supportReveals
        )
    }

    /// The slab layer, mounted between the field stage and the board.
    ///
    /// Nothing is mounted at all when the cast is empty: an idle `SCNView` is
    /// still a Metal layer and a drawable pool, and the cheapest 3D card is
    /// the one that is not there.
    @ViewBuilder
    private func card3DLayer(
        _ cast: [BoardCard3DSubject],
        anchors: [BoardCardAnchor: Anchor<CGRect>],
        in proxy: GeometryProxy
    ) -> some View {
        if !cast.isEmpty {
            BoardCard3DLayer(
                subjects: cast,
                frames: anchors.mapValues { proxy[$0] },
                stageSize: proxy.size,
                // Still while a jutsu fills the screen, while the viewer has
                // a card up, and once the game is over: in all three the mat
                // is not the thing being looked at, and a still scene renders
                // one frame per change instead of thirty a second.
                isPaused: jutsuPlaying != nil || zoomedCard != nil || engine.isFinished
            )
        }
    }

    // MARK: Holograms

    /// The projections standing over the mat, in one overlay above the whole
    /// board.
    ///
    /// One layer rather than an overlay inside each card view, for three
    /// reasons that all point the same way: a projection stands more than a
    /// card's height above its slot and would clip at the slot's bounds; it
    /// would shrink with the board's own zoom, which the stage behind it does
    /// not; and holograms have to layer against each other and against that
    /// stage, which cards in separate subtrees cannot do.
    ///
    /// Decoration, and the least load-bearing thing on the screen. It takes no
    /// touches at all, and `HologramLayer` answers to the player's master
    /// switch, to Low Power Mode, to the thermal state and to its own
    /// simultaneous ceiling before it draws anything — so on a phone that is
    /// working hard this costs exactly nothing.
    private func hologramLayer(
        _ anchors: [BoardCardAnchor: Anchor<CGRect>],
        in proxy: GeometryProxy
    ) -> some View {
        let frames = anchors.mapValues { proxy[$0] }

        return HologramLayer(candidates: hologramCandidates(in: frames))
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .allowsHitTesting(false)
            .onChange(of: frames, initial: true) { _, latest in
                // Merged rather than replaced, so a card that has just left the
                // field still has a frame for its hologram to collapse into.
                // It cannot grow without bound: the keys are the cards of one
                // game, and the whole board is rebuilt for the next.
                hologramFrames.rects.merge(latest) { _, newest in newest }
            }
    }

    /// Every hologram the board wants on screen, live ones and the ones still
    /// folding away.
    ///
    /// Hiding is `isPresented`, not absence. A candidate dropped from the list
    /// ceases to exist between two frames; one flipped to false folds down over
    /// the collapse and then costs nothing at all, and the same flag back to
    /// true stands it up again. So a jutsu filling the screen, or a target
    /// being chosen, puts the holograms away rather than blinking them out.
    private func hologramCandidates(in frames: [BoardCardAnchor: CGRect]) -> [HologramCandidate] {
        let isShowing = hologramsAreShowing

        var candidates = hologramSubjects.compactMap { subject -> HologramCandidate? in
            guard let rect = frames[subject.anchor],
                  let region = hologramRegion(for: subject.slot, in: frames),
                  // A card whose centre has left its side's band casts nothing:
                  // the only way that happens is the Characters row scrolling a
                  // body past its own edge, and a projection leaning back in
                  // from off-row would point at nothing the player can see.
                  region.contains(CGPoint(x: rect.midX, y: rect.midY))
            else { return nil }
            return HologramCandidate(
                id: subject.id,
                card: subject.card,
                anchorRect: rect,
                isPresented: isShowing,
                region: region
            )
        }

        candidates += hologramExits.map { exit in
            HologramCandidate(
                id: exit.id,
                card: exit.card,
                anchorRect: exit.rect,
                isPresented: false,
                region: exit.region
            )
        }
        return candidates
    }

    /// The band `slot`'s holograms may occupy right now, worked out from the
    /// frames the layout itself published — see `BoardHologramRegion` for the
    /// derivation and the reasoning.
    private func hologramRegion(
        for slot: PlayerSlot,
        in frames: [BoardCardAnchor: CGRect]
    ) -> CGRect? {
        BoardHologramRegion.region(
            rows: frames[.playRegion(slot)],
            statusBand: frames[.statusBand],
            isNear: slot == nearSlot
        )
    }

    /// Whether the mat may carry holograms at all this instant.
    ///
    /// They are decoration, so they lose every argument they are in. A jutsu
    /// filling the screen is the picture the player is meant to be watching. A
    /// prompt or an armed attacker means the mat itself is the question being
    /// asked, and a lit plane standing over the row being chosen from is
    /// exactly the wrong thing to add to it — during targeting the board has to
    /// stay legible. The card viewer and the result overlay cover the board
    /// outright, and a hologram ticking behind either of them is heat with
    /// nothing to show for it.
    private var hologramsAreShowing: Bool {
        jutsuPlaying == nil
            && zoomedCard == nil
            && armedAttacker == nil
            && engine.pendingChoice == nil
            && !engine.isFinished
    }

    /// Every card on the field that casts a hologram, in a stable order: the
    /// bodies in play, and the Supports both players have seen.
    ///
    /// This list is an information rule written out, which is why it is worked
    /// out here and not in the card views. Characters are face-up by
    /// definition, but a Support is on this list only once it is public. The
    /// near player's own set card is not public: the mat blurs it for them as
    /// a convenience, and a hologram over it would be a second, brighter copy
    /// of a card the opponent is entitled to not see. Hands, decks and trashes
    /// are not the field, so nothing in them is here.
    ///
    /// Two face-up cards are deliberately absent, and both absences were
    /// measured on a device rather than guessed. The Leaders live in the
    /// label column — the side's name above the card, the life readout below —
    /// so every placement of a projection there covers state: full size it
    /// reached the status strip and the life pill, and shrunk into the column
    /// it sat on the name. The Summon marker sits in the edge row of its
    /// half, so its plane stood a full plane-height away on the Support row,
    /// visibly detached from the marker casting it; a plane small enough to
    /// stay off that row is a speck. For both, the cheapest hologram is the
    /// one that is not there — the same answer thermal pressure gives.
    ///
    /// Identity is the in-play instance rather than the printing, so two copies
    /// of one card never rise, bob or flicker in step — and so a hologram
    /// survives every change to the position except the one that matters, its
    /// own card leaving.
    private var hologramSubjects: [HologramSubject] {
        var subjects: [HologramSubject] = []

        for slot in PlayerSlot.allCases {
            for character in engine.side(slot).characters {
                guard let card = engine.card(for: character) else { continue }
                subjects.append(HologramSubject(
                    id: character.id.uuidString,
                    slot: slot,
                    anchor: .character(character.id),
                    card: card
                ))
            }

            subjects.append(contentsOf: faceUpSupports(on: slot))
        }
        return subjects
    }

    /// The Supports on one side that both players have seen.
    ///
    /// It mirrors the slot's own reckoning exactly: a card the engine still
    /// holds is public once it is revealed, and a card the engine has already
    /// disposed of goes on projecting for as long as the mat is holding it in
    /// the emptied slot. Both of those states put the card on the chain first,
    /// so nothing drawn here was ever hidden from anybody.
    private func faceUpSupports(on slot: PlayerSlot) -> [HologramSubject] {
        let supports = engine.side(slot).supports

        return supports.indices.compactMap { index -> HologramSubject? in
            let placed = supports[index]

            if let reveal = supportReveals.first(where: { $0.slot == slot && $0.slotIndex == index }),
               placed == nil || placed?.id == reveal.supportID,
               let card = database.card(id: reveal.cardID) {
                return HologramSubject(
                    id: reveal.supportID.uuidString,
                    slot: slot,
                    anchor: .support(slot, index),
                    card: card
                )
            }

            guard let placed, placed.isRevealed, let card = engine.card(for: placed) else { return nil }
            return HologramSubject(
                id: placed.id.uuidString,
                slot: slot,
                anchor: .support(slot, index),
                card: card
            )
        }
    }

    /// Keeps the collapse list in step with the field.
    ///
    /// The frame comes from `hologramFrames` rather than from the overlay,
    /// because by the time a departure is visible the card is already off the
    /// mat and has no frame left to publish.
    private func trackHolograms(from previous: [HologramSubject], to current: [HologramSubject]) {
        let live = Set(current.map(\.id))

        // A card that came straight back stands its hologram up again rather
        // than finishing a collapse it has no reason to play.
        hologramExits.removeAll { live.contains($0.id) }

        for subject in previous where !live.contains(subject.id) {
            guard !hologramExits.contains(where: { $0.id == subject.id }),
                  let rect = hologramFrames.rects[subject.anchor],
                  let region = hologramRegion(for: subject.slot, in: hologramFrames.rects)
            else { continue }
            hologramExits.append(
                HologramExit(id: subject.id, card: subject.card, rect: rect, region: region)
            )
        }
    }

    /// Drops collapses that have finished.
    ///
    /// Driven by the list itself, so a board wipe that ends five holograms at
    /// once is swept in a single pass and anything that started later is swept
    /// by the run the change kicks off. The loop is the backstop for the case
    /// where nothing was old enough to remove and the list therefore never
    /// changed — without it those holograms would sit collapsed forever.
    private func sweepHologramExits() async {
        while !hologramExits.isEmpty {
            try? await Task.sleep(for: .seconds(HologramMetrics.collapseDuration + 0.05))
            guard !Task.isCancelled else { return }
            let cutoff = Date.now.addingTimeInterval(-HologramMetrics.collapseDuration)
            hologramExits.removeAll { $0.startedAt <= cutoff }
        }
    }

    /// The full-screen card viewer.
    @ViewBuilder
    private var zoomOverlay: some View {
        if let request = zoomedCard {
            CardZoomOverlay(card: request.card) { zoomedCard = nil }
                .id(request.id)
        }
    }

    // MARK: Automation

    /// Runs after every accepted action: takes one AI move and lets the next
    /// revision restart it, which is the loop. Auto-pass is the engine's own —
    /// it closes a window nobody can answer before the board ever sees it.
    private func advanceAutomation() async {
        guard aiOwesAMove else { return }
        try? await Task.sleep(for: Self.aiDelay)
        guard !Task.isCancelled, aiOwesAMove else { return }
        await takeAIMove()
    }

    private var aiOwesAMove: Bool {
        configuration.mode == .versusAI && !engine.isFinished && engine.decider == .opponent
    }

    /// Asks the AI for one move, at the strength the player chose.
    ///
    /// The tier is read here rather than captured when the game was built, so
    /// the choice made before the game — and any change made in Settings during
    /// it — lands on the AI's very next decision. Everything above genin
    /// searches off the main actor, so the board is re-checked afterwards: a
    /// game that finished or moved on while the search ran gets nothing rather
    /// than a stale action.
    ///
    /// A refusal is never fatal: the board falls back to the first legal
    /// action, so a mistaken AI slows the game down rather than freezing it.
    private func takeAIMove() async {
        let chosen = await settings.aiDifficulty.chooseAction(engine: engine, slot: .opponent)
        guard !Task.isCancelled, aiOwesAMove else { return }

        if let chosen, perform(chosen, by: .opponent, announcesErrors: false) { return }

        for action in engine.legalActions(for: .opponent) where !isConcede(action) {
            if perform(action, by: .opponent, announcesErrors: false) { return }
        }
    }

    private func isConcede(_ action: GameAction) -> Bool {
        if case .concede = action { return true }
        return false
    }

    // MARK: Banner

    /// A refusal is information, not an emergency: it slides in over the board
    /// and clears itself rather than stacking alerts.
    private struct BoardBanner: Equatable, Identifiable {
        let id = UUID()
        let message: String
    }

    @ViewBuilder
    private var bannerView: some View {
        if let banner {
            Text(banner.message)
                .font(Typeface.body(13))
                .foregroundStyle(Palette.textPrimary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, Metrics.spacingM)
                .padding(.vertical, Metrics.spacingS)
                .notchedPanel(notch: 8, fill: Palette.panelActive, stroke: Palette.negative)
                .padding(.top, Metrics.spacingS)
                .transition(reduceMotion ? .opacity : .move(edge: .top).combined(with: .opacity))
                .allowsHitTesting(false)
                .accessibilityAddTraits(.isStaticText)
        }
    }

    private func show(_ message: String) {
        withAnimation(.easeOut(duration: 0.18)) {
            banner = BoardBanner(message: message)
        }
    }

    private func fadeBanner() async {
        guard let current = banner else { return }
        try? await Task.sleep(for: .seconds(2.6))
        guard !Task.isCancelled, banner?.id == current.id else { return }
        withAnimation(.easeIn(duration: 0.25)) { banner = nil }
    }

    // MARK: Result

    @ViewBuilder
    private var resultOverlay: some View {
        if engine.isFinished {
            ZStack {
                Palette.backdrop.opacity(0.86)
                    .ignoresSafeArea()

                VStack(spacing: Metrics.spacingM) {
                    Text("Game over").sectionLabel()

                    Text(resultHeadline)
                        .font(Typeface.display(26))
                        .tracking(2)
                        .textCase(.uppercase)
                        .foregroundStyle(Palette.accent)
                        .multilineTextAlignment(.center)

                    Text(resultDetail)
                        .font(Typeface.body(15))
                        .foregroundStyle(Palette.textSecondary)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)

                    WideButton(title: "Play again", style: .primary, action: onPlayAgain)
                    WideButton(title: "Back to the menu") { router.popToRoot() }
                }
                .padding(Metrics.spacingL)
                .frame(maxWidth: 420)
                .notchedPanel(fill: Palette.panel, stroke: Palette.accentMuted)
                .padding(Metrics.spacingL)
            }
            .transition(.opacity)
            .accessibilityAddTraits(.isModal)
        }
    }

    private var resultHeadline: String {
        guard let winner = engine.outcome.winner else { return "Game over" }
        return "\(displayName(for: winner)) wins"
    }

    private var resultDetail: String {
        guard case .win(_, let reason) = engine.outcome else {
            return engine.outcome.summary
        }
        return "\(reason.title) — \(reason.detail)."
    }

    // MARK: Confirmations

    /// A decision the board holds until the player says yes.
    ///
    /// Playing a card is not one of these: its three modes are offered by
    /// `HandActionPanel`, which has room to name why each of them is or is not
    /// available, and which asks its own second question when the player has
    /// turned `SettingsStore.confirmJutsuSummon` on.
    private enum BoardConfirmation: Identifiable {

        case attack(attacker: AttackerReference, target: AttackTarget, targetName: String)
        case endTurn
        case leave

        var id: String {
            switch self {
            case .attack(let attacker, let target, _):
                let who = attacker.characterID?.uuidString ?? "leader"
                let what = target.characterID?.uuidString ?? "leader"
                return "attack-\(who)-\(what)"
            case .endTurn: return "end-turn"
            case .leave:   return "leave"
            }
        }
    }

    /// Everything the board draws along the bottom, in order of urgency.
    ///
    /// A held decision outranks an open response window: the window is a
    /// question the player has already started answering, and stacking two
    /// panels on the same edge would hide half of each.
    @ViewBuilder
    private var bottomPanel: some View {
        if let confirmation {
            BoardConfirmPanel(
                title: title(for: confirmation),
                message: message(for: confirmation),
                confirmTitle: confirmTitle(for: confirmation),
                confirmStyle: confirmStyle(for: confirmation),
                cancelTitle: cancelTitle(for: confirmation),
                isCompact: horizontalSizeClass == .compact,
                onConfirm: { commit(confirmation) },
                onCancel: { dismissConfirmation() }
            )
            .padding(Metrics.spacingS)
            .transition(panelTransition)
        } else {
            responsePanel
        }
    }

    /// How a panel arrives at the bottom edge. Reduce Motion keeps the fade
    /// and drops the travel, which is the whole of the difference.
    private var panelTransition: AnyTransition {
        reduceMotion ? .opacity : .move(edge: .bottom).combined(with: .opacity)
    }

    private func title(for pending: BoardConfirmation) -> String {
        switch pending {
        case .attack:  return "Declare the attack?"
        case .endTurn: return "End your turn?"
        case .leave:   return "Leave the game?"
        }
    }

    private func confirmTitle(for pending: BoardConfirmation) -> String {
        switch pending {
        case .attack:  return "Attack"
        case .endTurn: return "End turn"
        case .leave:   return "Leave the game"
        }
    }

    private func confirmStyle(for pending: BoardConfirmation) -> WideButton.Style {
        switch pending {
        case .attack, .endTurn: return .primary
        case .leave:            return .destructive
        }
    }

    private func cancelTitle(for pending: BoardConfirmation) -> String {
        switch pending {
        case .attack:  return "Cancel"
        case .endTurn: return "Not yet"
        case .leave:   return "Stay"
        }
    }

    private func commit(_ pending: BoardConfirmation) {
        switch pending {
        case .attack(let attacker, let target, _):
            perform(.declareAttack(attacker: attacker, target: target), by: engine.currentPlayer)
        case .endTurn:
            perform(.endTurn, by: engine.currentPlayer)
        case .leave:
            confirmation = nil
            router.popToRoot()
        }
    }

    private func message(for pending: BoardConfirmation) -> String {
        switch pending {
        case .attack(let attacker, _, let targetName):
            // The Leader rests to attack, which costs it the turn's Recovery —
            // the one thing worth saying before the tap is spent.
            let mover = attackerName(attacker)
            guard case .leader = attacker else {
                return "\(mover) attacks \(targetName) and rests."
            }
            return "\(mover) attacks \(targetName). Attacking rests your Leader, "
                + "so it cannot also take Recovery this turn."

        case .endTurn:
            // The reference's own wording, and only when it is actually true.
            return engine.hasActionsRemaining(for: engine.currentPlayer)
                ? "You still have actions available."
                : "The turn passes to \(displayName(for: engine.currentPlayer.opposing))."

        case .leave:
            return "The game is not saved, so leaving ends it."
        }
    }
}

// MARK: - Held decisions

/// One jutsu resolution the board still owes an effect.
///
/// The identity is per play rather than per effect: `JutsuEffectView` starts
/// its clock when it is installed, so two plays of the same effect need two
/// identities or the second one inherits the first one's finished timeline.
private struct JutsuPlay: Identifiable, Equatable {
    let id = UUID()
    let effect: JutsuEffect
}

/// One declared attack the mat is still drawing.
///
/// It carries two points rather than the two cards' endpoints, and that is the
/// whole reason it exists as a type. A declaration nobody can answer opens its
/// window, auto-passes, resolves and knocks the target out inside a single
/// `apply` — so by the time the first frame of the shot is drawn there may be
/// nothing left at the far end to aim at. The points are read off the mat at
/// the moment of the declaration, while both cards are still on it.
private struct AttackShot: Identifiable, Equatable {

    /// Per shot, so a second declaration in the same turn restarts the clock
    /// rather than inheriting the first one's finished flight.
    let id = UUID()

    let from: CGPoint
    let to: CGPoint
    let style: AttackProjectileView.Style

    /// Seeds the spray, so two shots in a turn do not throw the identical one.
    let salt: UInt64
}

/// Where the cards on the mat currently are, in the projectile overlay's space.
///
/// A box rather than a value in `@State`, because nothing on screen depends on
/// it: the board writes it on every layout pass and reads it exactly once, at
/// the instant an attack is declared. Held as state it would invalidate the
/// whole mat every time a card moved — a full re-render per frame of every
/// summon and every rest, to keep a figure no view draws.
@MainActor
private final class CardCentres {
    var points: [ProjectileAnchor: CGPoint] = [:]
}

// MARK: - Holograms

/// Works out the band one side's holograms may occupy, from the frames the
/// layout published.
///
/// The previous attempt clamped projections to the whole overlay, and that
/// was the wrong region twice over: the overlay spans the chrome — the status
/// strip, the side labels, the life pills, the counters — so "on screen"
/// never stopped a plane from standing on any of them. The right region is
/// the side's own rows band, stretched only across space nothing else owns:
/// down to the status strip's edge for the far half, up from it for the near
/// half. Both rects come from the layout itself, resolved in the same pass
/// and the same coordinate space as the card frames they constrain, so the
/// region can never disagree with the cards about where anything is.
///
/// A plain enum of pure functions so the derivation is testable without a
/// running board.
enum BoardHologramRegion {

    /// Air kept between a projection and the status strip's edge, points.
    static let bandClearance: CGFloat = Metrics.spacingXS

    /// The region for one side, or nil while the layout has not published its
    /// rows yet — a candidate without a region simply does not cast this
    /// frame, which is also what keeps a projection from drawing unclamped
    /// against a layout that has not settled.
    static func region(rows: CGRect?, statusBand: CGRect?, isNear: Bool) -> CGRect? {
        guard let rows, !rows.isEmpty, !rows.isNull,
              rows.origin.x.isFinite, rows.origin.y.isFinite,
              rows.width.isFinite, rows.height.isFinite
        else { return nil }

        // Without a band to measure against, the rows themselves are the
        // whole of the safe space.
        guard let statusBand, !statusBand.isEmpty else { return rows }

        if isNear {
            // The near half sits below the strip: its holograms may rise into
            // the slack air above the rows, but no further than the strip.
            let top = min(rows.minY, statusBand.maxY + bandClearance)
            return CGRect(
                x: rows.minX, y: top,
                width: rows.width, height: rows.maxY - top
            )
        }

        // The far half sits above the strip: the overlay's top edge is
        // already inside the safe area, so everything from it down to the
        // strip is free.
        let top = min(rows.minY, 0)
        let bottom = max(rows.maxY, statusBand.minY - bandClearance)
        return CGRect(
            x: rows.minX, y: top,
            width: rows.width, height: bottom - top
        )
    }
}

/// One face-up card on the field, and where its frame can be found.
private struct HologramSubject: Equatable {

    /// The in-play instance rather than the printing — a character's board
    /// identity, or a Support's. Two copies of one card therefore get two
    /// identities, which is what keeps their holograms from bobbing and
    /// flickering in step, and an identity that survives a change to the
    /// position is what keeps a hologram from re-entering every time the
    /// board redraws.
    let id: String

    /// The side the card stands on, which names the region its hologram is
    /// confined to.
    let slot: PlayerSlot

    /// Which published frame this card is drawn in.
    let anchor: BoardCardAnchor

    let card: Card
}

/// One hologram whose card has left the field, still folding away.
private struct HologramExit: Identifiable, Equatable {

    /// The departed subject's identity, so a card that comes straight back
    /// reclaims its own hologram instead of standing up a second one.
    let id: String

    let card: Card

    /// The last frame the card published. It is not on the mat any more, so
    /// there is nowhere else left to ask.
    let rect: CGRect

    /// The band the hologram was confined to while it stood, kept so the
    /// collapse folds down inside the same limits it rose inside.
    let region: CGRect

    /// When the collapse began. Held rather than counted down, so one sweep
    /// can retire several collapses that started at different moments.
    let startedAt = Date.now
}

/// Where every card on the mat was last drawn, in the hologram overlay's space.
///
/// A box rather than a value in `@State`, for exactly the reason `CardCentres`
/// is one: the board writes it on every layout pass, and held as state it would
/// invalidate the whole mat every time a card moved. Live holograms never read
/// it — they are built from the frames the overlay already has in hand — so the
/// only question it answers is where the card that has just left used to be,
/// which is the one question nothing on screen can answer any more.
@MainActor
private final class HologramFrames {
    var rects: [BoardCardAnchor: CGRect] = [:]
}

/// What the board has to remember about a position in order to tell what an
/// accepted action changed.
private struct BoardSnapshot {

    /// Damage on every body in play, by in-play identity.
    let damage: [UUID: Int]

    /// Life on both Leaders.
    let life: [PlayerSlot: Int]

    /// Both Support rows as they stood. A card can be revealed, resolved and
    /// taken off the mat inside one `apply`, so this is the only place the
    /// board can still find out that it was ever there.
    let supports: [PlayerSlot: [PlacedSupport?]]

    /// How long the journal was, so only the lines this action wrote are read.
    let journalCount: Int

    /// The last line before the action. The journal drops its head once it
    /// passes its cap, so a position is safer than a count.
    let journalMark: UUID?

    init(engine: GameEngine) {
        var damage: [UUID: Int] = [:]
        var life: [PlayerSlot: Int] = [:]
        var supports: [PlayerSlot: [PlacedSupport?]] = [:]
        for slot in PlayerSlot.allCases {
            let side = engine.side(slot)
            life[slot] = side.life
            supports[slot] = side.supports
            for character in side.characters {
                damage[character.id] = character.damage
            }
        }
        self.damage = damage
        self.life = life
        self.supports = supports
        self.journalCount = engine.journal.count
        self.journalMark = engine.journal.latest?.id
    }

    /// The lines written since this snapshot was taken. Found by position where
    /// the marker survives, and by the change in length where it does not.
    func linesAdded(to journal: Journal) -> [String] {
        if let journalMark,
           let index = journal.entries.lastIndex(where: { $0.id == journalMark }) {
            return journal.entries[(index + 1)...].map(\.message)
        }
        return journal.entries.suffix(max(0, journal.count - journalCount)).map(\.message)
    }
}

// MARK: - Jutsu art direction

/// Which effect a resolving jutsu plays.
///
/// The pool names its jutsu in the SUPPORT line — `Card.jutsuName` is the half
/// before the dash — and the engine journals "<name> resolves." when a chain
/// link goes off. That line is the board's only signal that a jutsu happened at
/// all, because a card played from hand is created and disposed of inside a
/// single `apply`, so the table is keyed by the whole sentence.
///
/// Two of the pool's jutsu are named effects and the rest flare. Sasuke's
/// "Chidori: One Thousand Birds" is the one electric jutsu, and Shisui's "Koto
/// Amatsukami" is a Sharingan genjutsu — an eye, not an arc. Both are matched
/// on the jutsu name printed in the card's SUPPORT bar rather than on a
/// collector number, because a reprint keeps the name and changes the number.
///
/// Both play over the whole screen, above both halves of the field. A jutsu
/// that empties the board of Characters, or that shuts a player's chakra down
/// for a turn and a half, is an event on the table rather than something that
/// happened to one card.
@MainActor
private enum JutsuLookup {

    /// The pool the table was built from. Starts at a revision no database can
    /// hold, so the first ask always fills it.
    private static var revision = -1
    private static var table: [String: JutsuEffect] = [:]

    static func effect(for line: String, in database: CardDatabase) -> JutsuEffect? {
        if revision != database.poolRevision {
            table = Dictionary(
                database.cards.compactMap { card -> (String, JutsuEffect)? in
                    guard card.supportBarAbility != nil else { return nil }
                    return ("\(card.jutsuName) resolves.", effect(named: card.jutsuName))
                },
                uniquingKeysWith: { first, _ in first }
            )
            revision = database.poolRevision
        }
        return table[line]
    }

    private static func effect(named jutsuName: String) -> JutsuEffect {
        if jutsuName.localizedCaseInsensitiveContains("chidori") { return .chidori }
        if jutsuName.localizedCaseInsensitiveContains("amatsukami") { return .sharingan }
        return .generic
    }
}

// MARK: - Confirmation panel

/// A decision held over the board until the player says yes.
///
/// It is a panel on the mat rather than a system dialog for the same reason the
/// response window is one: what is being confirmed — the lit attacker, the lit
/// target, the board a turn is about to be handed over on — is on the mat, and
/// an alert covers exactly the thing the player is deciding about. It also lets
/// the two answers carry the words that belong to them, so "End turn" and
/// "Not yet" replace an OK and a Cancel that mean nothing on their own.
struct BoardConfirmPanel: View {

    /// The question, as a question.
    let title: String

    /// What saying yes will do, and anything it costs that is not obvious.
    let message: String

    let confirmTitle: String
    var confirmStyle: WideButton.Style = .primary
    let cancelTitle: String

    /// Compact stacks the two answers, which a phone has no room for side by
    /// side once either of them carries more than a word.
    let isCompact: Bool

    let onConfirm: () -> Void
    let onCancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: Metrics.spacingS) {
            Text(title)
                .font(Typeface.display(isCompact ? 15 : 18, weight: .bold))
                .foregroundStyle(Palette.textPrimary)
                .fixedSize(horizontal: false, vertical: true)

            Text(message)
                .font(Typeface.body(isCompact ? 12 : 13))
                .foregroundStyle(Palette.textSecondary)
                .fixedSize(horizontal: false, vertical: true)

            answers
        }
        .padding(Metrics.spacingM)
        .frame(maxWidth: 520)
        .notchedPanel(fill: Palette.panel.opacity(0.97), stroke: Palette.accent)
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .contain)
        .accessibilityAddTraits(.isModal)
        .accessibilityLabel(title)
    }

    @ViewBuilder
    private var answers: some View {
        if isCompact {
            VStack(spacing: Metrics.spacingS) {
                WideButton(title: confirmTitle, style: confirmStyle, action: onConfirm)
                WideButton(title: cancelTitle, action: onCancel)
            }
        } else {
            HStack(spacing: Metrics.spacingS) {
                WideButton(title: confirmTitle, style: confirmStyle, action: onConfirm)
                WideButton(title: cancelTitle, action: onCancel)
            }
        }
    }
}

// MARK: - Response window

/// One card offered as an answer to the open window.
///
/// The board fills these in from the engine — `faceDownSupports` and
/// `handCards` for the cards, `slotActivationBlock` and `handActivationBlock`
/// for the refusals — so a row the panel offers is one the engine will accept,
/// and a row it refuses carries the engine's own reason rather than a rewording.
struct ResponseAnswer: Identifiable {

    /// Where the answer is played from. The non-active player can only ever
    /// answer from a slot; from hand belongs to the active player alone.
    enum Origin: Hashable {
        case slot(Int)
        case hand(Int)
    }

    let origin: Origin

    let card: Card

    /// The box inside the card's SUPPORT bar — what activating it resolves.
    let ability: CardAbility

    /// Chakra printed on the left of that bar: the price of the answer.
    let chakraCost: Int

    /// Why this card cannot answer, in the engine's own words. `nil` when it can.
    let refusal: String?

    var id: String {
        switch origin {
        case .slot(let index): return "slot-\(index)"
        case .hand(let index): return "hand-\(index)"
        }
    }

    /// The badge drawn at the head of the row: the slot number a player reads
    /// on the mat, or the hand it is coming out of.
    var badge: String {
        switch origin {
        case .slot(let index): return "\(index + 1)"
        case .hand:            return "H"
        }
    }

    var isAllowed: Bool { refusal == nil }
}

/// The response window, as the reference presents it.
///
/// "You may answer with a face-down card", with PASS. The panel adds the three
/// things the sentence leaves out: what is being answered, which of the
/// player's own cards could answer it, and what each of them charges.
///
/// The list is the engine's own legality, which is what keeps a "Support
/// Activated" card — Shisui, Kakashi — greyed out with "Wrong moment" while
/// only a summon is on the table, and lets it in the moment a chain exists.
struct ResponseWindowPanel: View {

    let window: ResponseWindow

    /// One sentence naming the attack, summon or chain being held up.
    let subject: String

    /// Every card this player could answer with, offered or refused.
    let answers: [ResponseAnswer]

    /// Chakra ready right now, so an unaffordable price and its refusal agree
    /// with something the player can see.
    let availableChakra: Int

    /// Compact drops the printed ability text, which a phone has no room for.
    let isCompact: Bool

    /// A row the player pressed.
    let onActivate: (ResponseAnswer) -> Void

    /// The reference's PASS button.
    let onPass: () -> Void

    /// How much of a phone the panel may take before the mat stops being
    /// readable. The list scrolls inside whatever is left.
    private var maximumHeight: CGFloat { isCompact ? 260 : 340 }

    var body: some View {
        VStack(alignment: .leading, spacing: Metrics.spacingS) {
            header

            if answers.isEmpty {
                emptyNote
            } else {
                ScrollView {
                    VStack(spacing: Metrics.spacingXS) {
                        ForEach(answers) { answer in
                            row(answer)
                        }
                    }
                }
                .scrollIndicators(.hidden)
            }

            WideButton(title: "Pass", style: .primary, action: onPass)
        }
        .padding(Metrics.spacingM)
        .frame(maxWidth: 520)
        .frame(maxHeight: maximumHeight)
        .notchedPanel(fill: Palette.panel.opacity(0.97), stroke: Palette.negative)
        .frame(maxWidth: .infinity)
        .accessibilityAddTraits(.isModal)
    }

    // MARK: Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: Metrics.spacingS) {
                Text(window.kind.title)
                    .font(Typeface.label(10))
                    .tracking(1.4)
                    .textCase(.uppercase)
                    .foregroundStyle(Palette.negative)

                Spacer(minLength: 0)

                Text(chakraReadout)
                    .font(Typeface.label(10))
                    .tracking(1)
                    .textCase(.uppercase)
                    .foregroundStyle(Palette.textSecondary)
            }

            Text(window.prompt)
                .font(Typeface.display(isCompact ? 14 : 17, weight: .bold))
                .foregroundStyle(Palette.textPrimary)
                .fixedSize(horizontal: false, vertical: true)

            Text(subject)
                .font(Typeface.body(isCompact ? 11 : 13))
                .foregroundStyle(Palette.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }

    private var chakraReadout: String {
        availableChakra == 1 ? "1 chakra ready" : "\(availableChakra) chakra ready"
    }

    /// The honest empty state. Only twelve cards in the pool print a SUPPORT
    /// bar, so holding nothing is the ordinary case rather than a fault.
    private var emptyNote: some View {
        Text("You have nothing that can answer this.")
            .font(Typeface.body(12))
            .foregroundStyle(Palette.textSecondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, Metrics.spacingXS)
    }

    // MARK: Rows

    /// One card: where it is played from, its name, the chakra it costs, and
    /// either what it does or why it cannot be used.
    private func row(_ answer: ResponseAnswer) -> some View {
        Button {
            guard answer.isAllowed else { return }
            onActivate(answer)
        } label: {
            HStack(alignment: .top, spacing: Metrics.spacingS) {
                originBadge(answer)

                VStack(alignment: .leading, spacing: 2) {
                    Text(answer.card.name)
                        .font(Typeface.label(12))
                        .tracking(0.8)
                        .foregroundStyle(answer.isAllowed ? Palette.textPrimary : Palette.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)

                    Text(detail(answer))
                        .font(Typeface.body(11))
                        .foregroundStyle(answer.isAllowed ? Palette.textSecondary : Palette.negative)
                        .lineLimit(isCompact ? 2 : 4)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer(minLength: 0)

                costBadge(answer)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(Metrics.spacingS)
            .notchedPanel(
                notch: 8,
                fill: answer.isAllowed ? Palette.panelActive : Palette.surface.opacity(0.6),
                stroke: answer.isAllowed ? Palette.positive : Palette.border
            )
        }
        .buttonStyle(.plain)
        .disabled(!answer.isAllowed)
        .opacity(answer.isAllowed ? 1 : 0.7)
        .accessibilityElement(children: .ignore)
        .accessibilityAddTraits(.isButton)
        .accessibilityLabel(spoken(answer))
    }

    private func detail(_ answer: ResponseAnswer) -> String {
        answer.refusal ?? answer.ability.text
    }

    private func originBadge(_ answer: ResponseAnswer) -> some View {
        Text(answer.badge)
            .font(Typeface.numeric(12, weight: .bold))
            .foregroundStyle(Palette.textOnAccent)
            .frame(width: 24, height: 24)
            .background(
                answer.isAllowed ? Palette.accentMuted : Palette.textSecondary,
                in: RoundedRectangle(cornerRadius: 4)
            )
            .accessibilityHidden(true)
    }

    private func costBadge(_ answer: ResponseAnswer) -> some View {
        HStack(spacing: 2) {
            Image(systemName: "drop.fill")
                .font(.system(size: 8, weight: .bold))
            Text("\(answer.chakraCost)")
                .font(Typeface.numeric(11, weight: .bold))
        }
        .foregroundStyle(Palette.textOnAccent)
        .padding(.horizontal, 5)
        .padding(.vertical, 2)
        .background(
            answer.chakraCost <= availableChakra ? Palette.positive : Palette.textSecondary,
            in: RoundedRectangle(cornerRadius: 4)
        )
        .accessibilityHidden(true)
    }

    private func spoken(_ answer: ResponseAnswer) -> String {
        let where_: String
        switch answer.origin {
        case .slot(let index): where_ = "Support slot \(index + 1)"
        case .hand:            where_ = "From your hand"
        }
        var parts = [
            where_,
            answer.card.name,
            answer.chakraCost == 0 ? "free" : "\(answer.chakraCost) chakra"
        ]
        parts.append(answer.refusal ?? answer.ability.text)
        return parts.joined(separator: ", ")
    }
}

// MARK: - Prompt sheet

/// The panel for a prompt over a zone the board cannot draw: a body in the
/// trash to revive, a search through deck and trash.
///
/// Nothing the player can see reaches here. A pick over the mat or over their
/// own hand is answered by tapping the card itself, which is the whole reason
/// those cards light up — a list of names beside a board that shows the same
/// cards is asking the player to match one to the other for no reason.
struct ChoicePanel: View {

    let choice: PendingChoice

    /// The question, as the engine worded it.
    let title: String

    /// The card that raised the prompt, when the engine named one.
    let subtitle: String?

    /// The answer: one key, or several for a prompt that takes several.
    let onResolve: ([String]) -> Void

    /// Present only on a prompt that may be declined.
    let onCancel: (() -> Void)?

    /// Keys picked so far, in the order tapped.
    @State private var staged: [String] = []

    private var isMultiple: Bool { choice.maxSelections > 1 }

    var body: some View {
        ZStack {
            AmbientBackground()

            VStack(alignment: .leading, spacing: Metrics.spacingM) {
                header

                ScrollView {
                    VStack(spacing: Metrics.spacingXS) {
                        ForEach(choice.options) { option in
                            row(option)
                        }
                    }
                    .padding(.bottom, Metrics.spacingS)
                }
                .scrollIndicators(.hidden)

                if isMultiple {
                    WideButton(title: confirmTitle, style: .primary, isEnabled: !staged.isEmpty) {
                        onResolve(staged)
                    }
                }

                if let onCancel {
                    WideButton(title: "Decline", style: .secondary, action: onCancel)
                }
            }
            .padding(Metrics.spacingL)
        }
    }

    // MARK: Header

    /// The card's name carries the heading and the printed question sits under
    /// it. A prompt is a whole sentence — set at title size it would push the
    /// options themselves off a phone-sized sheet.
    private var header: some View {
        VStack(alignment: .leading, spacing: Metrics.spacingXS) {
            Text(subtitle ?? "Choose")
                .font(Typeface.display(20, weight: .bold))
                .foregroundStyle(Palette.textPrimary)
                .fixedSize(horizontal: false, vertical: true)

            Text(title)
                .font(Typeface.body(13))
                .foregroundStyle(Palette.textSecondary)
                .fixedSize(horizontal: false, vertical: true)

            if isMultiple {
                Text("Pick up to \(choice.maxSelections).")
                    .font(Typeface.label(10))
                    .tracking(1.2)
                    .textCase(.uppercase)
                    .foregroundStyle(Palette.accent)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }

    private var confirmTitle: String {
        staged.count == 1 ? "Confirm 1 card" : "Confirm \(staged.count) cards"
    }

    // MARK: Rows

    private func row(_ option: ChoiceOption) -> some View {
        let isStaged = staged.contains(option.key)

        return Button {
            choose(option)
        } label: {
            HStack(spacing: Metrics.spacingS) {
                Text(option.title)
                    .font(Typeface.label(13))
                    .tracking(0.8)
                    .foregroundStyle(Palette.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)

                Spacer(minLength: 0)

                if isStaged {
                    Image(systemName: "checkmark")
                        .font(Typeface.label(12))
                        .foregroundStyle(Palette.accent)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(Metrics.spacingM)
            .notchedPanel(
                notch: 8,
                fill: isStaged ? Palette.panelActive : Palette.surface.opacity(0.6),
                stroke: isStaged ? Palette.accent : Palette.border
            )
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .ignore)
        .accessibilityAddTraits(.isButton)
        .accessibilityLabel(isStaged ? "\(option.title), chosen" : option.title)
    }

    /// A single-pick prompt answers on the tap; a multi-pick one stages until
    /// the player confirms, because the whole answer travels in one action.
    private func choose(_ option: ChoiceOption) {
        guard isMultiple else {
            onResolve([option.key])
            return
        }
        if let index = staged.firstIndex(of: option.key) {
            staged.remove(at: index)
        } else if staged.count < choice.maxSelections {
            staged.append(option.key)
        }
    }
}

// MARK: - Preview support

/// Fixtures shared by every board preview.
///
/// Previews cannot run statements beside a view, so the mulligan the second
/// player owes is answered here rather than inline in each `#Preview`.
enum BoardPreview {

    static let configuration = GameConfiguration(
        mode: .soloVersusSelf,
        format: .classic,
        playerDeckID: nil,
        opponentDeckID: nil,
        fixedDeckColor: .red
    )

    static let compactLayout = BoardLayout(
        size: CGSize(width: 393, height: 759),
        isCompact: true
    )

    static let wideLayout = BoardLayout(
        size: CGSize(width: 1024, height: 1300),
        isCompact: false
    )

    /// A game past the opening mulligan, so the board has a turn to show. Only
    /// the player going second is ever asked, so both answers are offered and
    /// whichever one belongs to this seed is the one that lands.
    static func engine(database: CardDatabase) -> GameEngine {
        let engine = GameEngine(
            configuration: configuration,
            database: database,
            decks: DeckStore(),
            seed: 42
        )
        engine.apply(.mulligan(keep: true), by: .player)
        engine.apply(.mulligan(keep: true), by: .opponent)
        return engine
    }

    /// A game with one card set face-down in a Support slot, and the side it
    /// was set on.
    ///
    /// Only the player taking the turn may set a card, and which of the two
    /// that is depends on the mulligan this seed produced — so the side is
    /// reported back rather than assumed. A hand with nothing settable in it
    /// leaves the row empty, which the mat draws just as happily.
    static func engineWithASetSupport(
        database: CardDatabase
    ) -> (engine: GameEngine, slot: PlayerSlot) {
        let engine = self.engine(database: database)
        let slot = engine.currentPlayer
        for handCard in engine.handCards(for: slot) {
            if case .success = engine.apply(.setSupport(handIndex: handCard.id), by: slot) {
                break
            }
        }
        return (engine, slot)
    }

    /// The three-mode action panel for one card, built by hand.
    ///
    /// A preview cannot reach a board where a summon has already been spent or
    /// a jutsu's moment has passed, so the refusals a hand card wears are handed
    /// in rather than played for. The words are the engine's own — `GameError`
    /// quotes the reference verbatim — so a preview never shows copy the game
    /// would not.
    static func options(
        for card: Card,
        summonRefusal: String? = nil,
        jutsuRefusal: String? = nil
    ) -> [PlayOption] {
        let bar = card.supportBarAbility
        return [
            PlayOption(mode: .summon, title: "Summon", cost: 0, refusal: summonRefusal),
            PlayOption(
                mode: .setAsSupport,
                title: "Set as support",
                cost: 0,
                refusal: bar == nil ? GameError.conditionUnmet.message : nil
            ),
            PlayOption(
                mode: .jutsu,
                title: "Activate \(card.jutsuName)",
                cost: bar?.ability.cost.chakra ?? 0,
                refusal: bar == nil ? GameError.conditionUnmet.message : jutsuRefusal
            )
        ]
    }

    /// A window opened by a summon, which is the case the reference was
    /// actually watched producing: an empty chain, so only a Quick card could
    /// answer it.
    static let summonWindow = ResponseWindow(
        kind: .summon,
        respondingSlot: .opponent,
        chainLength: 0
    )

    /// The box inside a card's SUPPORT bar, with the printed line standing in
    /// where a pool has the bar flagged but no box behind it.
    static func supportBox(of card: Card) -> CardAbility {
        card.supportBarAbility?.ability
            ?? CardAbility(trigger: .support, text: card.supportText ?? card.effect)
    }

    /// A short log with a system line, a summon and the window it opened.
    static func journal() -> Journal {
        var journal = Journal()
        journal.system("Classic game. You go first.")
        journal.record(actor: PlayerSlot.player.title, message: "Kept the opening hand.")
        journal.system("Turn 1 — You.")
        journal.record(actor: PlayerSlot.player.title, message: "Draws 1, hand 6, deck 24.")
        journal.record(actor: PlayerSlot.player.title, message: "Summons Choji Akimichi.")
        journal.system("Opponent may answer with a face-down card.")
        journal.record(actor: PlayerSlot.opponent.title, message: "Passes.")
        journal.record(actor: PlayerSlot.player.title, message: "Sets a card face-down in support slot 1.")
        return journal
    }
}

// MARK: - Previews

#Preview("Solo v self") {
    NavigationStack {
        GameBoardView(configuration: BoardPreview.configuration)
    }
    .environment(Router())
    .environment(CardDatabase())
    .environment(DeckStore())
    .environment(SettingsStore())
}

#Preview("Against the AI") {
    NavigationStack {
        GameBoardView(
            configuration: GameConfiguration(
                mode: .versusAI,
                format: .vanilla,
                playerDeckID: nil,
                opponentDeckID: nil,
                fixedDeckColor: .blue
            )
        )
    }
    .environment(Router())
    .environment(CardDatabase())
    .environment(DeckStore())
    .environment(SettingsStore())
}

/// A summon window with the pair worth looking at: a Quick card that can answer
/// it, and a "Support Activated" card that cannot, because the chain is empty.
#Preview("Answering a summon") {
    let database = CardDatabase()
    let quick = database.cards.first { $0.supportBarAbility?.ability.trigger == .quick }
    let response = database.cards.first { $0.supportBarAbility?.ability.trigger == .support }
    let held = [quick, response].compactMap { $0 }

    return ResponseWindowPanel(
        window: BoardPreview.summonWindow,
        subject: "P1 summoned Choji Akimichi.",
        answers: held.enumerated().map { entry in
            ResponseAnswer(
                origin: .slot(entry.offset),
                card: entry.element,
                ability: BoardPreview.supportBox(of: entry.element),
                chakraCost: entry.element.supportBarAbility?.ability.cost.chakra ?? 0,
                refusal: entry.offset == 1 ? GameError.wrongMoment.message : nil
            )
        },
        availableChakra: 2,
        isCompact: true,
        onActivate: { _ in },
        onPass: {}
    )
    .frame(width: 393 - Metrics.spacingS * 2)
    .padding()
    .background(Palette.backdrop)
    .environment(database)
}

/// Nothing to answer with — the ordinary case. With `autoPass` set to pass for
/// you the engine closes this window itself and the panel is never drawn.
#Preview("Nothing to answer with") {
    let database = CardDatabase()

    return ResponseWindowPanel(
        window: ResponseWindow(kind: .attack, respondingSlot: .player, chainLength: 0),
        subject: "Kakashi Hatake is attacking your Leader.",
        answers: [],
        availableChakra: 3,
        isCompact: false,
        onActivate: { _ in },
        onPass: {}
    )
    .padding()
    .background(Palette.backdrop)
    .environment(database)
}

/// The two confirmations the board holds, in place of the system dialog they
/// replace. Both are drawn over the mat, so the attacker and the target the
/// first one is about stay visible behind it.
#Preview("Confirming in-board") {
    VStack(spacing: Metrics.spacingM) {
        BoardConfirmPanel(
            title: "Declare the attack?",
            message: "Kakashi Hatake attacks the Opponent's Leader and rests.",
            confirmTitle: "Attack",
            cancelTitle: "Cancel",
            isCompact: true,
            onConfirm: {},
            onCancel: {}
        )

        BoardConfirmPanel(
            title: "Leave the game?",
            message: "The game is not saved, so leaving ends it.",
            confirmTitle: "Leave the game",
            confirmStyle: .destructive,
            cancelTitle: "Stay",
            isCompact: false,
            onConfirm: {},
            onCancel: {}
        )
    }
    .padding()
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .background(AmbientBackground())
}

/// A prompt over a zone the mat cannot draw. Hand and board picks are answered
/// by tapping the card itself now, so the trash is the case left for the sheet:
/// there is nowhere on the board a card in the trash is shown.
#Preview("Choosing from the trash") {
    let database = CardDatabase()
    let buried = Array(database.cards.filter { $0.type == .character }.prefix(4))

    return ChoicePanel(
        choice: PendingChoice(
            id: UUID(),
            kind: .reviveFromTrash,
            player: .player,
            prompt: "Summon 1 Character from your trash.",
            options: buried.enumerated().map { entry in
                ChoiceOption(
                    key: "trash-\(entry.offset)",
                    target: .trashCard(slot: .player, index: entry.offset),
                    title: entry.element.name
                )
            },
            cancellable: true
        ),
        title: "Summon 1 Character from your trash.",
        subtitle: "Gamabunta",
        onResolve: { _ in },
        onCancel: {}
    )
    .environment(database)
}
