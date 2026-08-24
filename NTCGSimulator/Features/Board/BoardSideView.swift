//
//  BoardSideView.swift
//  NTCGSimulator
//
//  One player's half of the mat: Leader and life, the Characters row, the five
//  Support slots, the Chakra row with the Summon marker, and the zone counters.
//  The far side draws the same zones mirrored, so the two halves meet at the
//  Characters rows the way a physical mat does.
//
//  The Characters row is drawn five slots wide but holds an UNBOUNDED number of
//  bodies — effects can flood the board past the printed mat — so the row
//  scrolls horizontally once a sixth body arrives rather than clipping it.
//
//  Two things drawn here are rules rather than decoration. A face-down Support
//  follows the information rule set out in `FaceDownStyle`: its owner's copy is
//  the real printing behind a blur, because a player may look at what they set,
//  and the other side's is a back, because a blur is no redaction when thirty-
//  five printings are told apart by colour and silhouette alone. `isNear` is
//  the whole of the test, and it is the half belonging to whoever is holding
//  the device — the solo game hands the phone over, so the far half is always
//  somebody else's.
//
//  And every card that can attack or be attacked publishes its frame as a
//  projectile endpoint, so the board can fire a shot between two cards without
//  either of them having to know where the other one is.
//
//  Every card on the field publishes its frame a second time, as a
//  `BoardCardAnchor`. Two layers above the mat read those frames: the
//  holograms standing over the cards, and the 3D card layer standing the
//  cards themselves as slabs on the field stage behind the board. A card the
//  board has handed to that layer draws no printing here — `slabs` says which
//  — and keeps only the ring and the veil that are game state, so every
//  badge, number and target mark on this file goes on being drawn over the
//  top of the slab exactly as it was over the flat face.
//
//  That set differs from the projectile's — Supports never attack or get shot
//  at, while a Leader publishes a frame but casts no hologram — and it
//  carries the whole frame rather than a centre point, because a projection
//  has to stand on a card's top edge and take its width from the card's, and
//  a slab has to be scaled to the card's own width. Each
//  half also publishes its three zone rows as one `playRegion` band: the space
//  its holograms are allowed to occupy, measured by the layout that owns it
//  rather than guessed from screen proportions. Publishing frames is all this
//  file does; whether a card is entitled to a hologram at all is an
//  information rule, and it is decided by the board, next to every other rule
//  of that kind.
//

import SwiftUI

// MARK: - Emphasis

/// What a side should light up right now.
///
/// The board works this out once per side from the engine's own legality
/// checks, so a highlighted card is always one the engine will actually accept:
/// the attackers come from `attackBlock`, the attack targets from `canAttack`,
/// the answerable Supports from `legalCounterActivations` — which is what keeps
/// a response-timing card dark in a summon window — and the choice targets from
/// the open prompt's own option list.
struct BoardEmphasis: Equatable {

    // MARK: Attacking

    /// Bodies on this side that may declare an attack right now.
    var attackers: Set<UUID> = []

    /// This side's Leader may declare an attack — once per turn, resting it.
    var leaderMayAttack = false

    /// The body armed as the attacker, waiting for a target.
    var selectedAttackerID: UUID? = nil

    /// The Leader is the armed attacker.
    var leaderIsSelectedAttacker = false

    /// An attacker is armed and this side is the one being aimed at, so
    /// everything that is not a legal target steps back.
    var isTargetingAttack = false

    /// Bodies on this side a declared attack may be aimed at — only the
    /// RESTED ones, because standing characters cannot be attacked.
    var attackTargets: Set<UUID> = []

    /// This side's Leader is a legal attack target — it always is, once an
    /// attacker is armed.
    var leaderIsAttackTarget = false

    // MARK: Choices

    /// An open prompt is picking from the board, so everything that is not an
    /// option steps back.
    var isChoosing = false

    /// Bodies on this side the open prompt offers.
    var choiceTargets: Set<UUID> = []

    /// This side's Leader is one of the prompt's options — Itachi's freeze.
    var leaderIsChoiceTarget = false

    /// Bodies already staged for a multi-target prompt.
    var stagedTargets: Set<UUID> = []

    /// The Leader is staged for the open prompt.
    var leaderIsStaged = false

    // MARK: Windows

    /// Support slots holding a face-down card the engine would accept as an
    /// answer to the open window — `legalCounterActivations`, so a Shisui
    /// never lights up for a bare summon.
    var answerableSupports: Set<Int> = []

    // MARK: Abilities

    /// Bodies whose printed Activate: Main is legal right now.
    var readyAbilities: Set<UUID> = []

    /// Bodies that have already spent their Activate: Main this turn.
    var spentAbilities: Set<UUID> = []

    /// The Leader can use an Activate: Main or Recovery right now.
    var leaderAbilityReady = false

    /// The line drawn under the Leader: attack and ability readiness, or the
    /// state holding the Leader back.
    var leaderNote: String? = nil
}

// MARK: - Damage feedback

/// One hit the mat is currently drawing a number for.
///
/// The board works these out by comparing the board either side of an accepted
/// action: damage that landed on a body still in play, and life that came off a
/// Leader. A body that was knocked out is deliberately never in this list — its
/// treatment is leaving the row, and a "-4" floating over an empty slot says
/// nothing a player can use.
struct DamageFlash: Identifiable, Equatable {

    /// Which card the number is thrown off.
    enum Target: Hashable {
        case character(UUID)
        case leader(PlayerSlot)
    }

    /// Unique per hit rather than per card, so a second hit in the same slot
    /// replays the animation instead of reusing the one already running.
    let id = UUID()

    let target: Target

    /// Always positive. `kind` carries the sign and the colour.
    let amount: Int

    let kind: DamageNumberView.Kind
}

// MARK: - Support reveals

/// One face-down Support caught in the act of turning face-up.
///
/// The engine reveals a Support and resolves it inside a single `apply`: the
/// flag goes up, the box runs, and `disposeLink` empties the slot before the
/// board is ever asked to draw a frame. Nobody can read a card that arrives and
/// leaves between two frames — so the mat keeps its own note of it and goes on
/// drawing it in a slot the engine has already cleared.
///
/// This is presentation and only presentation. The rules have finished with the
/// card by the time one of these exists, so holding it on the mat delays no
/// decision, blocks no tap and changes no outcome.
///
/// Nothing here leaks. A card only ever leaves a Support slot by resolving on
/// the chain or by being negated on it, and both of those made it public first,
/// so every card a reveal draws is one both players have already seen.
struct SupportReveal: Identifiable, Equatable {

    /// Unique per reveal rather than per card.
    ///
    /// One card can need two of these. A Support that opens a response window
    /// is revealed when it goes on the chain and then sits in its slot until
    /// the window is answered, so it is held a second time when it finally
    /// leaves — and the second hold needs a clock of its own, not the spent
    /// remains of the first one's.
    let id = UUID()

    /// The `PlacedSupport` this speaks for, which is what a slot is matched
    /// on — so a second card set into the same slot cannot inherit the reveal
    /// belonging to the one it replaced.
    let supportID: UUID

    /// Which half of the mat the slot belongs to.
    let slot: PlayerSlot

    /// Zero-based Support slot, which is where the card is drawn.
    let slotIndex: Int

    /// Collector number rather than a `Card`, because the board's copy has to
    /// outlive the engine's and the engine's is already gone.
    let cardID: String

    /// Whether the card was already face-up on the mat when this reveal began.
    ///
    /// It is the difference between the two holds. The first turns a set card
    /// up and is a focus pull; the second only keeps a card that is already
    /// legible on screen a moment longer, and blurring it back down so it can
    /// sharpen a second time would read as a fault rather than as an effect.
    let wasAlreadyUp: Bool

    /// How long the card stays readable once it has turned up. The reference
    /// holds an activated Support about this long before the slot empties —
    /// long enough to read a name and an effect line, short enough that the
    /// answer to it does not feel held back.
    static let hold: Duration = .seconds(1.5)

    /// How long the blur takes to clear. The card is coming into focus, not
    /// travelling, so it is over quickly.
    static let turn: Double = 0.32
}

// MARK: - Card anchors

/// A frame the mat publishes for the hologram overlay: a card that may carry
/// a projection, or a region a projection must respect.
///
/// This is the attack projectile's technique — `anchorPreference` up to one
/// place that can see every card at once — asked a different question, and it
/// is a second key rather than more cases on `ProjectileAnchor` for two
/// reasons. A shot only ever flies between cards that can attack or be
/// attacked, so Supports have no business in that vocabulary; and a shot
/// wants a centre point where anything standing over a card wants the card's
/// whole frame.
///
/// The region cases ride the same key as the card frames deliberately: both
/// resolve through the same `GeometryProxy` in the same pass, so a card and
/// the region that constrains its hologram can never disagree about what
/// coordinate space they are in. Inferring the regions from screen
/// proportions — the mistake a previous fix made by clamping to the whole
/// overlay — is exactly what this replaces: the layout is the only party
/// that knows where the rows end and the chrome begins, so the layout says.
///
/// Leaders and the Summon marker publish a frame but cast no hologram; the
/// reasoning lives with the cast list in `GameBoardView.hologramSubjects`.
/// They publish anyway because a frame answers two questions on this board,
/// and the other one — where the 3D card layer has to stand this card's slab,
/// per `BoardCard3DProjection` — takes a wider cast than the holograms do.
enum BoardCardAnchor: Hashable {

    case character(UUID)

    /// A numbered Support slot, by its zero-based index. The slot rather than
    /// the card, because the slot is what stays put while cards pass through
    /// it — the board pairs the frame with the card it is currently drawing.
    case support(PlayerSlot, Int)

    /// One side's Leader, which lives in the label column rather than in the
    /// zone rows. It casts no hologram — a projection there would cover the
    /// side's name or its life readout — but it is a card on the field and it
    /// gets a slab like any other.
    case leader(PlayerSlot)

    /// One side's Summon marker, drawn in the edge of the Chakra row.
    case summon(PlayerSlot)

    /// One side's three zone rows — Characters, Supports and Chakra — as a
    /// single band. This is the space that side's holograms may occupy: it
    /// excludes the Leader column (name label, Leader, life readout), the
    /// counter column, the central status band and the hand, all of which are
    /// game state a decoration must never cover.
    case playRegion(PlayerSlot)

    /// The central status strip between the two halves. Published so the
    /// board can hold the near side's holograms below its bottom edge — the
    /// strip is the one piece of chrome that sits directly against a row of
    /// cards, and its frame moves with the layout.
    case statusBand
}

/// Collects the frames of every card on the mat, so one overlay above the
/// whole board can decorate them.
///
/// One overlay rather than one per card, and this key is what makes that
/// possible: an overlay mounted inside a slot clips at the slot's bounds and
/// is scaled by the board's own zoom, and a hologram has to stand more than a
/// card's height above its slot, in screen points, and layer correctly against
/// its neighbours and against the stage behind them.
struct BoardCardAnchorKey: PreferenceKey {
    static var defaultValue: [BoardCardAnchor: Anchor<CGRect>] { [:] }

    static func reduce(
        value: inout [BoardCardAnchor: Anchor<CGRect>],
        nextValue: () -> [BoardCardAnchor: Anchor<CGRect>]
    ) {
        value.merge(nextValue()) { _, latest in latest }
    }
}

extension View {
    /// Publishes this view's frame under `anchor` for the hologram overlay.
    ///
    /// `transformAnchorPreference` rather than `anchorPreference`, and the
    /// difference is load-bearing: `anchorPreference` REPLACES the subtree's
    /// accumulated value, so a container publishing its own frame — the rows
    /// band publishing `playRegion` — would silently erase every card anchor
    /// inside it. Transforming merges this entry into whatever the children
    /// already published, which makes the modifier safe on leaves and
    /// containers alike.
    func boardCardAnchor(_ anchor: BoardCardAnchor) -> some View {
        transformAnchorPreference(key: BoardCardAnchorKey.self, value: .bounds) { value, bounds in
            value[anchor] = bounds
        }
    }
}

// MARK: - Pool lookups

/// Answers about the pool that the mat would otherwise work out again on every
/// render.
///
/// `BoardSideView.body` runs again on every engine mutation — a draw, a summon,
/// a chakra flip, a highlight changing — and it runs twice, once per side.
/// Finding the Summon card by scanning the pool inside that path meant a linear
/// search per side per pass for an answer that only changes when the pool is
/// replaced. `poolRevision` is exactly the signal for that, so the scan happens
/// once per pool and an integer comparison happens per render instead.
///
@MainActor
enum BoardPoolLookup {

    /// The pool the cached answers belong to. Starts at a revision no database
    /// can hold, so the first ask always fills the cache.
    private static var revision = -1
    private static var summonCard: Card?

    /// The single physical Summon card, if the pool prints one.
    static func summon(in database: CardDatabase) -> Card? {
        if revision != database.poolRevision {
            summonCard = database.cards.first { $0.type == .summon }
            revision = database.poolRevision
        }
        return summonCard
    }
}

// MARK: - Side

/// Draws every zone belonging to one `PlayerSlot`.
///
/// The view reads the engine but never mutates it: taps are reported upwards
/// and `GameBoardView` decides what, if anything, they mean.
struct BoardSideView: View {

    let slot: PlayerSlot

    /// Display name for this side — "You", "Opponent", or "P1"/"P2" in solo.
    let title: String

    /// True for the half drawn the right way up at the bottom of the screen.
    let isNear: Bool

    /// Whether this side is taking the turn, used to light the name.
    let isActive: Bool

    let layout: BoardLayout
    let engine: GameEngine
    let emphasis: BoardEmphasis

    /// Art substituted for the Chakra row. The engine picks Chakra by deck
    /// colour; the player's `SettingsStore.chakraCardID` preference is
    /// honoured here, at render time, rather than by changing the rules.
    let chakraFace: Card?

    /// A long press anywhere on the side sends the card to the reader.
    let onRead: (Card) -> Void

    /// A tap on a body — attacker choice, attack target, ability offer or
    /// prompt answer, depending on what the board is waiting for.
    let onSelectCharacter: (CharacterInPlay) -> Void

    /// A tap on the Leader: its attack and ability offers, an attack target,
    /// or a prompt answer.
    let onSelectLeader: () -> Void

    /// A tap on a Support slot, by its zero-based index. Face-down cards are
    /// what a response window is answered with, so this is how an answer is
    /// chosen from the mat itself.
    var onSelectSupport: (Int) -> Void = { _ in }

    /// Hits to draw over this side's cards right now. The board hands both
    /// sides the whole list and each picks out its own, so a single comparison
    /// of the board before and after an action feeds both halves.
    var flashes: [DamageFlash] = []

    /// Reported once a floating number has finished playing, so the board can
    /// drop it rather than leaving a spent animation mounted.
    var onFlashFinished: (UUID) -> Void = { _ in }

    /// Supports on this side that are turning face-up, or that the engine has
    /// already taken out of their slot and the mat is still holding. The board
    /// hands each half only its own, the way it does with `flashes`.
    var reveals: [SupportReveal] = []

    /// Reported once a reveal's hold is over, so the board can drop it and let
    /// the slot go back to being the engine's — or empty.
    var onRevealFinished: (UUID) -> Void = { _ in }

    /// The cards the 3D layer behind the board is drawing as slabs.
    ///
    /// A slot in this set draws no printing at all: the slab underneath is
    /// the card, and the 2D face keeps only the things that are game state —
    /// its ring and its stepped-back veil — so badges, damage numbers and
    /// target marks go on being drawn over the top of it. Empty is the
    /// board's whole 2D rendering, unchanged, which is what every fallback in
    /// `BoardCard3DBudget` collapses to.
    ///
    /// The board decides this from the position rather than from geometry, so
    /// the face is told to stand aside in the same render pass that publishes
    /// the frame the slab is placed from.
    var slabs: Set<BoardCardAnchor> = []

    /// Points to device pixels, for working out how much of a printed
    /// illustration the mat is actually able to show.
    @Environment(\.displayScale) private var displayScale

    private var side: PlayerSide { engine.side(slot) }

    /// How far back anything that is not a legal target fades while a prompt
    /// or an armed attacker is choosing one.
    private static let pushedBackOpacity: CGFloat = 0.45

    var body: some View {
        HStack(alignment: .top, spacing: layout.gap) {
            if isNear {
                leaderColumn
                zoneRows
                counterColumn
            } else {
                counterColumn
                zoneRows
                leaderColumn
            }
        }
        .frame(maxWidth: .infinity, alignment: .center)
        .task(id: engine.database.poolRevision) { warmArtwork() }
    }

    // MARK: Artwork

    /// Decodes the pool's illustrations before the mat needs them.
    ///
    /// Every card face on the board is a decode the first time it is drawn, and
    /// a decode of this artwork costs more than a whole frame — so a hand being
    /// dealt, a body being summoned or a chakra being flipped all landed a
    /// visible stall on the main thread at the exact moment something moved.
    /// The store warms them on a utility queue instead, so the face finds a
    /// decoded bitmap waiting for it.
    ///
    /// Both sizes the board draws are warmed: the mat's own slots, and the
    /// larger faces the hand and the inspector bar put on the same screen.
    /// Warming a bucket the screen never asks for would be wasted work, so the
    /// sizes come from `CardFaceView` rather than being restated here. Both
    /// sides call this and the store does the work once.
    private func warmArtwork() {
        let ids = engine.database.cards.map(\.id)
        let store = engine.database.artStore

        for size in [CardFaceSize.tiny, .small] {
            store.prewarm(
                cardIDs: ids,
                maxPixelSize: CardFaceView.artPixelSize(for: size, displayScale: displayScale)
            )
        }
    }

    // MARK: Rows

    /// Characters sit nearest the middle of the screen on both halves, so the
    /// two battle lines face each other.
    private var zoneRows: some View {
        VStack(spacing: layout.gap) {
            if isNear {
                characterRow
                supportRow
                chakraRow
            } else {
                chakraRow
                supportRow
                characterRow
            }
        }
        .frame(width: layout.rowWidth)
        // The band this side's holograms are confined to. Published from the
        // rows themselves rather than worked out from screen proportions, so
        // the region is right on every device, both orientations, and both
        // halves of a solo board that has just flipped.
        .boardCardAnchor(.playRegion(slot))
    }

    /// The unbounded battle line. Five printed slots, and a horizontal scroll
    /// once effects push the row past them — the mat never clips a body.
    private var characterRow: some View {
        ScrollView(.horizontal) {
            HStack(spacing: layout.gap) {
                ForEach(side.characters) { character in
                    characterSlot(character)
                }
                if side.characters.count < GameRules.maxCharacters {
                    ForEach(0..<(GameRules.maxCharacters - side.characters.count), id: \.self) { _ in
                        emptySlot(width: layout.slotWidth, label: "Empty character slot")
                    }
                }
            }
        }
        .scrollIndicators(.hidden)
        .frame(width: layout.rowWidth, height: layout.slotHeight)
    }

    /// The five numbered Support slots. A card set from hand lies face-down in
    /// the first free one until its owner activates it to answer a window.
    private var supportRow: some View {
        HStack(spacing: layout.gap) {
            ForEach(Array(side.supports.enumerated()), id: \.offset) { entry in
                supportSlot(entry.element, index: entry.offset)
            }
        }
        .frame(height: layout.slotHeight)
    }

    /// The Summon marker shares this row rather than taking a row of its own —
    /// one card never justifies a third of the half.
    private var chakraRow: some View {
        HStack(spacing: layout.gap) {
            if isNear { summonSlot }

            ForEach(side.chakra) { chakra in
                chakraSlot(chakra)
            }

            if !isNear { summonSlot }
        }
        .frame(height: layout.slotHeight)
    }

    // MARK: Character slots

    private func characterSlot(_ character: CharacterInPlay) -> some View {
        let card = engine.card(for: character)
        let remaining = card.map { character.remainingHealth(of: $0) }

        return ZStack(alignment: .bottomTrailing) {
            Group {
                if let card {
                    BoardCardFace(
                        card: card,
                        width: layout.slotWidth,
                        isDimmed: character.isRested || isPushedBack(character),
                        highlight: highlight(for: character),
                        rendersAsSlab: slabs.contains(.character(character.id))
                    )
                } else {
                    CardBackView(tint: Palette.border)
                        .frame(width: layout.slotWidth)
                        .opacity(isPushedBack(character) ? Self.pushedBackOpacity : 1)
                }
            }
            // A rested body lies on its side, and shrinks to the aspect ratio
            // so the turned card still occupies exactly one slot.
            .rotationEffect(.degrees(character.isRested ? 90 : 0))
            .scaleEffect(character.isRested ? Metrics.cardAspect : 1)
            .animation(.easeOut(duration: 0.22), value: character.isRested)
            // Red over the whole silhouette for the instant the hit lands, so
            // a body taking damage is visible from across the mat rather than
            // only in the figure that changed.
            .damageFlash(for: remaining ?? 0, in: NotchedRectangle(notch: 4, corners: .diagonal))

            if let remaining, card?.health != nil {
                healthBadge(remaining, isRevealed: character.damage > 0)
            }

            if let card {
                modifierStrip(character, card: card)
            }

            if let card, isSummoningSick(character, card: card) {
                sicknessMark
            }

            if emphasis.readyAbilities.contains(character.id) {
                abilityMark
                    .padding(2)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
            }

            // Readiness and choosability never appear together — a side with a
            // target being chosen on it publishes no ready marks — so the two
            // badges share the corner without colliding.
            targetMark(for: character)

            floatingNumber(for: .character(character.id))
        }
        .frame(width: layout.slotWidth, height: layout.slotHeight)
        // Published on the slot rather than on the face, so a rested body —
        // turned on its side and scaled to the card ratio — is still aimed at
        // where it sits rather than at where its untransformed face would be.
        .projectileAnchor(.character(character.id))
        // Published on the slot for the same reason, so a hologram stands over
        // where a rested body actually lies rather than over its upright frame.
        .boardCardAnchor(.character(character.id))
        .contentShape(Rectangle())
        .onTapGesture { onSelectCharacter(character) }
        .onLongPressGesture { if let card { onRead(card) } }
        .accessibilityElement(children: .ignore)
        .accessibilityAddTraits(.isButton)
        .accessibilityLabel(description(of: character, card: card))
    }

    /// Arrived this turn with no way past summoning sickness.
    private func isSummoningSick(_ character: CharacterInPlay, card: Card) -> Bool {
        character.summonedOnTurn == engine.turnNumber
            && !character.hasRush(card: card, turn: engine.turnNumber)
    }

    /// Frozen while the global turn has not passed the stamp.
    private func isFrozen(_ character: CharacterInPlay) -> Bool {
        engine.turnNumber <= character.cannotAttackUntilTurn
    }

    // MARK: Support slots

    /// What one Support slot is currently drawing.
    ///
    /// A reveal outranks the engine's own slot, because it is the only thing
    /// that can still draw a card the engine has already taken away.
    private struct SupportContent {

        let card: Card

        /// The reveal playing over this slot, if one is.
        let reveal: SupportReveal?

        /// The card the engine still holds here. `nil` once it has resolved and
        /// only the reveal is keeping it on the mat.
        let placed: PlacedSupport?

        /// Whether both players have seen this card. Drives the reader, the
        /// spoken description and the printing itself.
        var isPublic: Bool { reveal != nil || placed?.isRevealed == true }
    }

    /// One numbered Support slot. `nil` keeps the empty treatment, so an
    /// unused zone still reads as a zone rather than as a gap in the mat.
    ///
    /// A face-down card is drawn by the rule in `FaceDownStyle`: your own is
    /// its real printing behind a blur, because you may look at what you set,
    /// and the opponent's is a back, because a blur is not a redaction. It
    /// rings when the open window could legally be answered with it — the
    /// engine's own list, so a response-timing card stays dark in a summon
    /// window — and carries the chakra printed on its SUPPORT bar so the price
    /// of answering is on the mat rather than only in the response panel.
    private func supportSlot(_ placed: PlacedSupport?, index: Int) -> some View {
        let number = index + 1
        let content = supportContent(placed, index: index)

        return ZStack(alignment: .topLeading) {
            Group {
                if let content {
                    supportFace(content, index: index)
                } else {
                    emptySlot(width: layout.slotWidth, label: "Support slot \(number), empty")
                }
            }
            .frame(width: layout.slotWidth, height: layout.slotHeight)

            slotNumber(number, isOccupied: content != nil)

            if let cost = activationCost(at: index) {
                activationCostBadge(cost)
            }
        }
        .frame(width: layout.slotWidth, height: layout.slotHeight)
        // The slot publishes its frame whatever is in it — including nothing.
        // What may be projected from it is the board's decision, and a slot
        // that stopped publishing while it held a face-down card would say
        // that it held one.
        .boardCardAnchor(.support(slot, index))
        .contentShape(Rectangle())
        .onTapGesture { onSelectSupport(index) }
        .onLongPressGesture {
            if let content, content.isPublic || isNear { onRead(content.card) }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityAddTraits(content == nil ? [] : .isButton)
        .accessibilityLabel(
            content.map { supportDescription($0, number: number) }
                ?? "Support slot \(number), empty"
        )
    }

    /// Works out which card a slot speaks for.
    ///
    /// The reveal wins while the slot is otherwise free, which is what keeps a
    /// resolved Support on the mat for its beat and a half. It stands down the
    /// moment the engine puts something else in the slot: a card set into the
    /// freed space is the real occupant, and the reveal it displaced is stale.
    private func supportContent(_ placed: PlacedSupport?, index: Int) -> SupportContent? {
        if let reveal = reveals.first(where: { $0.slotIndex == index }),
           placed == nil || placed?.id == reveal.supportID,
           let card = engine.card(for: reveal.cardID) {
            return SupportContent(card: card, reveal: reveal, placed: placed)
        }
        guard let placed, let card = engine.card(for: placed) else { return nil }
        return SupportContent(card: card, reveal: nil, placed: placed)
    }

    /// The card itself, at whichever of the three states it is in: turning up,
    /// already up, or still set.
    @ViewBuilder
    private func supportFace(_ content: SupportContent, index: Int) -> some View {
        if let reveal = content.reveal {
            RevealingSupportFace(
                card: content.card,
                width: layout.slotWidth,
                highlight: supportTint(index),
                startsClear: reveal.wasAlreadyUp,
                onFinished: { onRevealFinished(reveal.id) }
            )
            .id(reveal.id)
        } else if content.isPublic {
            BoardCardFace(
                card: content.card,
                width: layout.slotWidth,
                isDimmed: emphasis.isChoosing || emphasis.isTargetingAttack,
                highlight: supportTint(index),
                // Only a Support that is SIMPLY face-up gets a slab: the
                // branch above is a reveal, whose blur clearing belongs to
                // the 2D face, and the branch below is a card lying face
                // down, whose treatment is the information rule this file's
                // header sets out and has exactly one implementation.
                rendersAsSlab: slabs.contains(.support(slot, index))
            )
        } else {
            // The information rule, and the one line in this file where getting
            // it wrong would decide games: `.blurredKnown` may only ever be
            // handed a card this viewer is entitled to see. `isNear` is the
            // half drawn the right way up, which in every mode — including the
            // hand-the-device-over solo game — is the half belonging to
            // whoever is holding the phone.
            BoardCardFace(
                card: content.card,
                width: layout.slotWidth,
                isDimmed: emphasis.isChoosing || emphasis.isTargetingAttack,
                highlight: supportTint(index),
                faceDown: isNear ? .blurredKnown(reveal: 0) : .hidden
            )
        }
    }

    /// The ring a Support slot wears while it is one of the answers on offer.
    private func supportTint(_ index: Int) -> Color? {
        emphasis.answerableSupports.contains(index) ? Palette.positive : nil
    }

    /// The chakra printed on the left of a face-down card's SUPPORT bar —
    /// what activating it to answer the open window costs.
    ///
    /// Drawn only on the near half. The opposing player's face-down cards stay
    /// hidden, and a price on one of them would narrow down what is under it.
    private func activationCost(at index: Int) -> Int? {
        guard isNear, emphasis.answerableSupports.contains(index) else { return nil }
        return engine.faceDownSupports(for: slot).first { $0.slotIndex == index }?.chakraCost
    }

    /// The number printed on the mat beside the slot.
    private func slotNumber(_ number: Int, isOccupied: Bool) -> some View {
        Text("\(number)")
            .font(Typeface.numeric(layout.slotWidth < 52 ? 7 : 9, weight: .bold))
            .foregroundStyle(isOccupied ? Palette.textOnAccent : Palette.textSecondary)
            .padding(.horizontal, 3)
            .padding(.vertical, 1)
            .background(
                isOccupied ? Palette.accentMuted.opacity(0.9) : Palette.surface.opacity(0.7),
                in: RoundedRectangle(cornerRadius: 3)
            )
            .padding(2)
            .accessibilityHidden(true)
    }

    /// What activating this card costs, in the same currency the chakra row
    /// draws.
    private func activationCostBadge(_ cost: Int) -> some View {
        HStack(spacing: 1) {
            Image(systemName: "drop.fill")
                .font(.system(size: 6, weight: .bold))
            Text("\(cost)")
                .font(Typeface.numeric(8, weight: .bold))
        }
        .foregroundStyle(Palette.textOnAccent)
        .padding(.horizontal, 3)
        .padding(.vertical, 1)
        .background(Palette.positive, in: RoundedRectangle(cornerRadius: 3))
        .padding(2)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
        .accessibilityHidden(true)
    }

    private func supportDescription(_ content: SupportContent, number: Int) -> String {
        var parts = ["Support slot \(number)"]

        if content.reveal != nil {
            parts.append("\(content.card.name), activating")
        } else if content.isPublic {
            parts.append("\(content.card.name), activated")
        } else {
            parts.append(isNear ? "your face-down \(content.card.name)" : "a face-down card")
        }

        if emphasis.answerableSupports.contains(number - 1) {
            parts.append("can answer the open window")
            if let cost = activationCost(at: number - 1) {
                parts.append(cost == 0 ? "free" : "for \(cost) chakra")
            }
        }
        return parts.joined(separator: ", ")
    }

    // MARK: Chakra and Summon

    private func chakraSlot(_ chakra: ChakraCard) -> some View {
        Group {
            if !chakra.isFaceUp {
                CardBackView(tint: Palette.textSecondary)
                    .frame(width: layout.chakraWidth)
            } else if let face = chakraFace ?? engine.card(for: chakra) {
                BoardCardFace(card: face, width: layout.chakraWidth)
            } else {
                CardBackView(tint: Palette.accent)
                    .frame(width: layout.chakraWidth)
            }
        }
        .opacity(emphasis.isChoosing || emphasis.isTargetingAttack ? Self.pushedBackOpacity : 1)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(chakra.isFaceUp ? "Chakra, face-up" : "Chakra, face-down")
    }

    /// The single physical Summon card: rested once the turn's one normal
    /// summon is spent, standing again at the owner's next turn start. It is
    /// a marker — the engine's real gate is the per-turn counter — but it is
    /// how the mat says "the summon is spent" without a word.
    @ViewBuilder
    private var summonSlot: some View {
        if let card = BoardPoolLookup.summon(in: engine.database) {
            BoardCardFace(
                card: card,
                width: layout.slotWidth,
                isDimmed: side.summonRested || emphasis.isChoosing || emphasis.isTargetingAttack,
                rendersAsSlab: slabs.contains(.summon(slot))
            )
            .rotationEffect(.degrees(side.summonRested ? 90 : 0))
            .scaleEffect(side.summonRested ? Metrics.cardAspect : 1)
            .animation(.easeOut(duration: 0.22), value: side.summonRested)
            // The frame is the marker's own size, so adding it changes no
            // layout — but it gives the anchor below something that stays
            // put while the card inside it turns, exactly as a character
            // slot does. A frame published on the rotated face would report
            // the bounding box of a card lying on its side.
            .frame(width: layout.slotWidth, height: layout.slotHeight)
            .boardCardAnchor(.summon(slot))
            .contentShape(Rectangle())
            .onTapGesture { onRead(card) }
            .accessibilityElement(children: .ignore)
            .accessibilityAddTraits(.isButton)
            .accessibilityLabel(side.summonRested
                                ? "Summon card, rested — the turn's summon is spent"
                                : "Summon card, standing")
        } else {
            emptySlot(width: layout.slotWidth, label: "Summon zone")
        }
    }

    /// A dashed outline. Empty zones still have to read as zones, otherwise
    /// the board looks broken rather than uncontested.
    private func emptySlot(width: CGFloat, label: String) -> some View {
        NotchedRectangle(notch: 4, corners: .diagonal)
            .stroke(Palette.border.opacity(0.7), style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
            .frame(width: width, height: width / Metrics.cardAspect)
            .accessibilityLabel(label)
    }

    // MARK: Leader

    private var leaderColumn: some View {
        VStack(spacing: layout.gap) {
            nameLabel
            leaderFace
            lifeReadout
            leaderStateChips
            leaderBadge
            Spacer(minLength: 0)
        }
        .frame(width: layout.leaderWidth)
    }

    private var nameLabel: some View {
        Text(title)
            .font(Typeface.label(10))
            .tracking(1.2)
            .textCase(.uppercase)
            .foregroundStyle(isActive ? Palette.accent : Palette.textSecondary)
            .lineLimit(1)
            .minimumScaleFactor(0.6)
            .accessibilityLabel(isActive ? "\(title), taking their turn" : title)
    }

    @ViewBuilder
    private var leaderFace: some View {
        // A pool imported without a Leader leaves the side anchored to
        // nothing, so the card back stands in rather than the board collapsing.
        if let leader = engine.leaderCard(for: slot) {
            ZStack(alignment: .topTrailing) {
                BoardCardFace(
                    card: leader,
                    width: layout.leaderWidth,
                    isDimmed: leaderIsPushedBack,
                    highlight: leaderHighlight,
                    rendersAsSlab: slabs.contains(.leader(slot))
                )
                // The Recovery action and a Leader attack both rest the
                // Leader, so it turns on its side exactly as a body does —
                // the mat already has one way of saying rested.
                .rotationEffect(.degrees(side.leaderRested ? 90 : 0))
                .scaleEffect(side.leaderRested ? Metrics.cardAspect : 1)
                .animation(.easeOut(duration: 0.22), value: side.leaderRested)

                if emphasis.leaderMayAttack || emphasis.leaderAbilityReady {
                    leaderReadyMark
                        .padding(2)
                }

                leaderTargetMark

                floatingNumber(for: .leader(slot))
            }
            // Pinned to the card's own size before anything is published from
            // it, exactly as a character slot is — and for a reason that was
            // measured rather than guessed. The badges inside this stack lay
            // themselves out with `maxWidth`/`maxHeight: .infinity` to reach
            // their corner, so on an unpinned `ZStack` inside a `VStack` with
            // room to spare, the stack GREW the moment a target crosshair
            // appeared. Both anchors below are read as "where the card is", so
            // an inflated frame aimed the attack shot low and stood the
            // Leader's 3D slab half a card beneath its own slot.
            .frame(width: layout.leaderWidth, height: layout.leaderHeight)
            // Leaders attack and are attacked like anything else on the mat,
            // so the Leader publishes an endpoint exactly as a body does.
            .projectileAnchor(.leader(slot))
            // And a card frame, published on the column's ZStack rather than
            // on the face, so a rested Leader — turned on its side and scaled
            // to the card ratio — is placed by where its slot is rather than
            // by the bounding box of the turned card. The frame is what the
            // 3D layer stands its slab on; it casts no hologram.
            .boardCardAnchor(.leader(slot))
            .contentShape(Rectangle())
            .onTapGesture { onSelectLeader() }
            .onLongPressGesture { onRead(leader) }
            .accessibilityElement(children: .ignore)
            .accessibilityAddTraits(.isButton)
            .accessibilityLabel(leaderDescription(leader))
        } else {
            CardBackView(tint: Palette.border)
                .frame(width: layout.leaderWidth)
                .accessibilityLabel("\(title) has no Leader in the pool")
        }
    }

    /// The Leader steps back with everything else that is not being asked
    /// for — unless it is itself an option or a target.
    private var leaderIsPushedBack: Bool {
        if emphasis.isChoosing {
            return !(emphasis.leaderIsChoiceTarget || emphasis.leaderIsStaged)
        }
        if emphasis.isTargetingAttack {
            // The armed Leader is on the attacking side, where nothing is a
            // target — it stays lit anyway, so the player can see what they
            // chose to swing with.
            return !(emphasis.leaderIsAttackTarget || emphasis.leaderIsSelectedAttacker)
        }
        return false
    }

    /// The same order a body's ring follows: anything choosable wears the
    /// accent, and readiness comes last.
    private var leaderHighlight: Color? {
        if emphasis.leaderIsStaged { return Palette.accent }
        if emphasis.leaderIsChoiceTarget { return Palette.accent }
        if emphasis.leaderIsSelectedAttacker { return Palette.accent }
        if emphasis.isChoosing { return nil }
        if emphasis.leaderIsAttackTarget { return Palette.accent }
        if emphasis.leaderMayAttack { return Palette.accentMuted }
        if emphasis.leaderAbilityReady { return Palette.accent }
        return nil
    }

    /// Marks the Leader as holding something pressable: an attack, an
    /// Activate: Main, or Recovery.
    private var leaderReadyMark: some View {
        Image(systemName: emphasis.leaderMayAttack ? "burst.fill" : "sparkles")
            .font(.system(size: 7, weight: .bold))
            .foregroundStyle(Palette.textOnAccent)
            .padding(.horizontal, 3)
            .padding(.vertical, 2)
            .background(Palette.accent, in: Capsule())
            .accessibilityHidden(true)
    }

    /// Marks a body whose printed Activate: Main is legal right now.
    private var abilityMark: some View {
        Image(systemName: "sparkles")
            .font(.system(size: 7, weight: .bold))
            .foregroundStyle(Palette.textOnAccent)
            .padding(.horizontal, 3)
            .padding(.vertical, 2)
            .background(Palette.accent, in: Capsule())
            .accessibilityHidden(true)
    }

    /// The states holding the Leader back, worn as chips so "why can it not
    /// attack" is on the mat rather than only in a refusal: frozen by a
    /// skill, rested by Recovery or its own attack, or its one attack spent.
    @ViewBuilder
    private var leaderStateChips: some View {
        let chips = leaderChips
        if !chips.isEmpty {
            HStack(spacing: 2) {
                ForEach(chips) { chip in
                    stateChip(chip)
                }
            }
            .frame(maxWidth: .infinity)
        }
    }

    private var leaderChips: [StateChip] {
        var chips: [StateChip] = []
        if engine.turnNumber <= side.leaderCannotAttackUntilTurn {
            chips.append(StateChip(id: "frozen", symbol: "snowflake",
                                   word: "Frozen", tint: Palette.negative))
        }
        if side.leaderRested {
            chips.append(StateChip(id: "rested", symbol: "moon.zzz.fill",
                                   word: "Rested", tint: Palette.textSecondary))
        } else if side.leaderAttacksUsed >= GameRules.leaderAttacksPerTurn {
            chips.append(StateChip(id: "attacked", symbol: "burst",
                                   word: "Attacked", tint: Palette.textSecondary))
        }
        return chips
    }

    /// Says what the Leader is offering — or what is holding it back — under
    /// the card, where the board put it there is room for a word.
    @ViewBuilder
    private var leaderBadge: some View {
        if let text = emphasis.leaderNote {
            let isLive = emphasis.leaderMayAttack || emphasis.leaderAbilityReady
            Text(text)
                .font(Typeface.label(layout.leaderWidth < 64 ? 8 : 10))
                .tracking(0.6)
                .textCase(.uppercase)
                .foregroundStyle(isLive ? Palette.textOnAccent : Palette.textSecondary)
                .multilineTextAlignment(.center)
                .lineLimit(3)
                .minimumScaleFactor(0.55)
                .padding(.horizontal, 3)
                .padding(.vertical, 3)
                .frame(maxWidth: .infinity)
                .background(
                    isLive ? Palette.accent : Palette.surface,
                    in: NotchedRectangle(notch: 5, corners: .diagonal)
                )
                .accessibilityHidden(true)
        }
    }

    private func leaderDescription(_ leader: Card) -> String {
        var parts = ["\(title) Leader", leader.name, "\(side.life) life"]
        if engine.turnNumber <= side.leaderCannotAttackUntilTurn { parts.append("frozen, cannot attack") }
        if side.leaderRested { parts.append("rested") }
        if side.leaderAttacksUsed >= GameRules.leaderAttacksPerTurn { parts.append("attacked this turn") }
        if emphasis.leaderIsSelectedAttacker { parts.append("armed as the attacker") }
        if emphasis.leaderMayAttack { parts.append("may attack") }
        if emphasis.leaderAbilityReady { parts.append("ability ready") }
        if emphasis.leaderIsAttackTarget { parts.append("legal attack target") }
        if emphasis.leaderIsChoiceTarget { parts.append("an option for the open prompt") }
        if let note = emphasis.leaderNote { parts.append(note.lowercased()) }
        return parts.joined(separator: ", ")
    }

    private var lifeReadout: some View {
        HStack(spacing: 3) {
            Image(systemName: "heart.fill")
                .font(.system(size: 9))
            Text("\(side.life)")
                .font(Typeface.numeric(13))
        }
        .foregroundStyle(Palette.textOnAccent)
        .padding(.vertical, 3)
        .frame(maxWidth: .infinity)
        .background(
            Palette.negative.opacity(0.9),
            in: NotchedRectangle(notch: 5, corners: .diagonal)
        )
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(title) life, \(side.life)")
    }

    // MARK: Counters

    /// The counters wrap onto two lines if they are allowed to, which throws
    /// the column out of alignment.
    private func counterPill(_ label: String, _ value: Int) -> some View {
        CountPill(label: label, value: "\(value)")
            .lineLimit(1)
    }

    private var counterColumn: some View {
        VStack(alignment: .leading, spacing: layout.gap) {
            counterPill("Deck", side.deck.count)
            counterPill("Hand", side.hand.count)
            counterPill("Trash", side.trash.count)
            counterPill("Exclusion", side.exclusion.count)
            Spacer(minLength: 0)
        }
        .frame(width: layout.counterWidth, alignment: .leading)
    }

    // MARK: Badges

    /// Remaining health after this turn's battle damage.
    ///
    /// Damage heals at end of turn, so the readout is only ever *shown*
    /// mid-turn — but it is mounted the whole time and hidden with opacity
    /// rather than being added when the first hit lands. `HealthCounterView`
    /// counts from wherever it already was, so a readout that only appears
    /// once the damage is done would have nothing to count down from and
    /// would snap to the new figure, which is the exact thing it exists to
    /// avoid.
    ///
    /// It sits on the surface colour rather than on red, because the counter
    /// draws its own red flash and prints its figure in the primary text
    /// colour — which on a red pill is unreadable in the light appearance.
    private func healthBadge(_ remaining: Int, isRevealed: Bool) -> some View {
        HealthCounterView(value: remaining, size: layout.slotWidth < 52 ? 9 : 11)
            .padding(.horizontal, 3)
            .padding(.vertical, 1)
            .background(Palette.surface.opacity(0.95), in: RoundedRectangle(cornerRadius: 3))
            .overlay {
                RoundedRectangle(cornerRadius: 3)
                    .stroke(Palette.negative, lineWidth: 1)
            }
            .padding(2)
            .opacity(isRevealed ? 1 : 0)
            .accessibilityHidden(true)
    }

    /// The floating combat number thrown off a card that was just hit.
    ///
    /// Scaled off the slot rather than fixed, so a phone-sized mat does not
    /// wear a figure wider than the card it belongs to.
    @ViewBuilder
    private func floatingNumber(for target: DamageFlash.Target) -> some View {
        if let flash = flashes.first(where: { $0.target == target }) {
            DamageNumberView(
                amount: flash.amount,
                kind: flash.kind,
                size: max(13, layout.slotWidth * 0.4),
                onFinished: { onFlashFinished(flash.id) }
            )
            .id(flash.id)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .allowsHitTesting(false)
        }
    }

    /// Arrived this turn without Rush, so it cannot attack yet.
    private var sicknessMark: some View {
        Image(systemName: "hourglass")
            .font(.system(size: 7, weight: .bold))
            .foregroundStyle(Palette.textOnAccent)
            .padding(2.5)
            .background(Palette.textSecondary, in: Circle())
            .padding(2)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .accessibilityHidden(true)
    }

    // MARK: Modifier chips

    /// One temporary state, drawn as a chip on the body it belongs to.
    private struct ModifierChip: Identifiable {
        let id: String
        let symbol: String?
        let text: String?
        let tint: Color
    }

    /// A Leader state, drawn as a chip under the Leader.
    private struct StateChip: Identifiable {
        let id: String
        let symbol: String
        let word: String
        let tint: Color
    }

    /// Everything the rules did to a body that the printed face cannot show:
    /// negated effects, a freeze, Rush, doubling, and the turn's stat
    /// bonuses. All of it expires or persists by rules a player cannot see —
    /// so it is worn on the card instead.
    @ViewBuilder
    private func modifierStrip(_ character: CharacterInPlay, card: Card) -> some View {
        let chips = modifierChips(character, card: card)
        if !chips.isEmpty {
            VStack(alignment: .leading, spacing: 1) {
                ForEach(chips) { chip in
                    modifierChip(chip)
                }
            }
            .padding(2)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
            .accessibilityHidden(true)
        }
    }

    private func modifierChips(_ character: CharacterInPlay, card: Card) -> [ModifierChip] {
        var chips: [ModifierChip] = []
        let turn = engine.turnNumber

        // A body summoned "with its effects negated" keeps its stats and
        // nothing else — the marker is the only way the player can tell.
        if character.effectsNegated {
            chips.append(ModifierChip(id: "negated", symbol: "nosign",
                                      text: "Negated", tint: Palette.warning))
        }
        if isFrozen(character) {
            chips.append(ModifierChip(id: "frozen", symbol: "snowflake",
                                      text: nil, tint: Palette.negative))
        }
        if character.hasRush(card: card, turn: turn), character.summonedOnTurn == turn {
            chips.append(ModifierChip(id: "rush", symbol: "bolt.fill",
                                      text: nil, tint: Palette.accent))
        }
        if character.powerDoubledUntilTurn >= turn {
            chips.append(ModifierChip(
                id: "doubled",
                symbol: nil,
                text: "P\(character.effectivePower(of: card, turn: turn)) ×2",
                tint: Palette.positive
            ))
        }
        if character.powerBonus != 0 {
            chips.append(ModifierChip(
                id: "power",
                symbol: nil,
                text: "P\(character.effectivePower(of: card, turn: turn)) \(signed(character.powerBonus))",
                tint: character.powerBonus > 0 ? Palette.positive : Palette.negative
            ))
        }
        if character.damageBonus != 0 {
            chips.append(ModifierChip(
                id: "damage",
                symbol: nil,
                text: "D\(character.damageStat(of: card)) \(signed(character.damageBonus))",
                tint: character.damageBonus > 0 ? Palette.positive : Palette.negative
            ))
        }
        return chips
    }

    private func modifierChip(_ chip: ModifierChip) -> some View {
        HStack(spacing: 1) {
            if let symbol = chip.symbol {
                Image(systemName: symbol)
                    .font(.system(size: 6, weight: .bold))
            }
            if let text = chip.text {
                Text(text)
                    .font(Typeface.numeric(7, weight: .bold))
            }
        }
        .foregroundStyle(Palette.textOnAccent)
        .padding(.horizontal, 3)
        .padding(.vertical, 1)
        .background(chip.tint.opacity(0.95), in: RoundedRectangle(cornerRadius: 3))
    }

    private func stateChip(_ chip: StateChip) -> some View {
        HStack(spacing: 1) {
            Image(systemName: chip.symbol)
                .font(.system(size: 6, weight: .bold))
            Text(chip.word)
                .font(Typeface.label(7))
                .textCase(.uppercase)
        }
        .foregroundStyle(Palette.textOnAccent)
        .padding(.horizontal, 3)
        .padding(.vertical, 1.5)
        .background(chip.tint.opacity(0.9), in: RoundedRectangle(cornerRadius: 3))
        .lineLimit(1)
        .minimumScaleFactor(0.7)
        .accessibilityHidden(true)
    }

    private func signed(_ value: Int) -> String {
        value > 0 ? "+\(value)" : "\(value)"
    }

    // MARK: Highlights

    /// The ring a body wears.
    ///
    /// Everything the player may tap right now wears the accent, whichever
    /// question is being asked: an option for the open prompt, one already
    /// staged for it, the armed attacker, a legal attack target. One colour
    /// means "this is choosable", and there is no second colour for the player
    /// to learn — the difference between the states is carried by
    /// `targetMark`, which a colour-blind player can read and a ring cannot.
    ///
    /// Readiness — a body that could attack, a box that could be activated —
    /// is a quieter thing and keeps its own muted treatment, and is never
    /// published while a target is being chosen anyway.
    private func highlight(for character: CharacterInPlay) -> Color? {
        if emphasis.stagedTargets.contains(character.id) { return Palette.accent }
        if emphasis.choiceTargets.contains(character.id) { return Palette.accent }
        if emphasis.selectedAttackerID == character.id { return Palette.accent }
        if emphasis.isChoosing { return nil }
        if emphasis.attackTargets.contains(character.id) { return Palette.accent }
        if emphasis.attackers.contains(character.id) { return Palette.accentMuted }
        if emphasis.readyAbilities.contains(character.id) { return Palette.accent }
        return nil
    }

    /// The badge on a card the board is waiting for a tap on: a crosshair on
    /// something choosable, a check on something already chosen.
    @ViewBuilder
    private func targetMark(for character: CharacterInPlay) -> some View {
        if emphasis.stagedTargets.contains(character.id) {
            pickMark(symbol: "checkmark", tint: Palette.positive)
        } else if emphasis.choiceTargets.contains(character.id)
                    || emphasis.attackTargets.contains(character.id) {
            pickMark(symbol: "scope", tint: Palette.accent)
        }
    }

    /// The same badge for the Leader, which is an option and a target as often
    /// as a body is.
    @ViewBuilder
    private var leaderTargetMark: some View {
        if emphasis.leaderIsStaged {
            pickMark(symbol: "checkmark", tint: Palette.positive)
        } else if emphasis.leaderIsChoiceTarget || emphasis.leaderIsAttackTarget {
            pickMark(symbol: "scope", tint: Palette.accent)
        }
    }

    private func pickMark(symbol: String, tint: Color) -> some View {
        Image(systemName: symbol)
            .font(.system(size: 8, weight: .black))
            .foregroundStyle(Palette.textOnAccent)
            .padding(3)
            .background(tint, in: Circle())
            .padding(2)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
            .accessibilityHidden(true)
    }

    /// Anything the open question cannot legally be pointed at steps back, so
    /// the legal answers are the only lit cards on the mat. The armed
    /// attacker stays where it is, so the player can see what they chose.
    private func isPushedBack(_ character: CharacterInPlay) -> Bool {
        if emphasis.isChoosing {
            return !(emphasis.choiceTargets.contains(character.id)
                     || emphasis.stagedTargets.contains(character.id))
        }
        if emphasis.isTargetingAttack {
            return !(emphasis.attackTargets.contains(character.id)
                     || emphasis.selectedAttackerID == character.id)
        }
        return false
    }

    // MARK: Accessibility

    private func description(of character: CharacterInPlay, card: Card?) -> String {
        var parts = [card?.name ?? character.cardID]
        let turn = engine.turnNumber
        if let card {
            if card.power != nil {
                parts.append("power \(character.effectivePower(of: card, turn: turn))")
            }
            if character.powerBonus != 0 {
                parts.append("\(signed(character.powerBonus)) power this turn")
            }
            if card.damage != nil { parts.append("damage \(character.damageStat(of: card))") }
            if character.damageBonus != 0 {
                parts.append("\(signed(character.damageBonus)) damage this turn")
            }
            parts.append("health \(character.remainingHealth(of: card))")
            if character.hasRush(card: card, turn: turn) { parts.append("has Rush") }
            if isSummoningSick(character, card: card) { parts.append("summoned this turn, cannot attack") }
        }
        parts.append(character.isRested ? "rested" : "standing")
        if character.effectsNegated { parts.append("its effects are negated") }
        if isFrozen(character) { parts.append("frozen, cannot attack") }

        if emphasis.selectedAttackerID == character.id {
            parts.append("armed as the attacker")
        } else if emphasis.attackers.contains(character.id) {
            parts.append("may attack")
        }
        if emphasis.attackTargets.contains(character.id) {
            parts.append("legal attack target")
        }
        if emphasis.stagedTargets.contains(character.id) {
            parts.append("staged for the open prompt")
        } else if emphasis.choiceTargets.contains(character.id) {
            parts.append("an option for the open prompt")
        }
        if emphasis.readyAbilities.contains(character.id) {
            parts.append("ability ready")
        } else if emphasis.spentAbilities.contains(character.id) {
            parts.append("ability used this turn")
        }
        return parts.joined(separator: ", ")
    }
}

// MARK: - Revealing support

/// A Support coming into focus in its slot, and staying there for a beat after
/// the engine has finished with it.
///
/// It owns the turn and the hold rather than the board, for the same reason
/// `DamageNumberView` owns its own animation: SwiftUI interpolates a value that
/// changes *after* a view is installed, and a board that set the reveal to 1 in
/// the same pass that added the card would get a cut instead of a focus pull.
/// `onAppear` is the first moment there is something to animate from.
///
/// It reports back when the hold is over. The board then drops the reveal and
/// the slot goes back to being the engine's — which, by then, usually means
/// empty. Under Reduce Motion the card simply arrives readable; the hold is a
/// pause rather than a movement, so it is kept.
///
/// `startsClear` covers the second of the two holds a card can be given: one
/// that was already face-up on the mat is only being kept there a moment
/// longer, so it is drawn as the plain printing with no turn at all.
private struct RevealingSupportFace: View {

    let card: Card

    /// The slot width. The face works its own height out from the card ratio.
    let width: CGFloat

    /// The ring the slot is wearing, if the open window can be answered here.
    let highlight: Color?

    /// True when the card was already face-up before this hold began.
    let startsClear: Bool

    let onFinished: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// 0 is the card as it was set, 1 the clear printing.
    @State private var reveal: Double = 0

    var body: some View {
        BoardCardFace(
            card: card,
            width: width,
            highlight: highlight,
            faceDown: startsClear ? nil : .blurredKnown(reveal: reveal)
        )
        .onAppear {
            guard !startsClear else { return }
            guard !reduceMotion else {
                reveal = 1
                return
            }
            withAnimation(.easeOut(duration: SupportReveal.turn)) { reveal = 1 }
        }
        .task {
            try? await Task.sleep(for: SupportReveal.hold)
            // A cancelled sleep means the board tore the slot down itself —
            // a new game, a card set into the slot — so there is nothing to
            // report back to it.
            guard !Task.isCancelled else { return }
            onFinished()
        }
    }
}

// MARK: - Previews

#Preview("Near side") {
    let database = CardDatabase()
    let engine = BoardPreview.engine(database: database)

    BoardSideView(
        slot: .player,
        title: "P1",
        isNear: true,
        isActive: true,
        layout: BoardPreview.compactLayout,
        engine: engine,
        emphasis: BoardEmphasis(
            attackers: Set(engine.side(.player).characters.map(\.id)),
            leaderMayAttack: true,
            leaderNote: "Attack ready"
        ),
        chakraFace: database.chakraCards.first,
        onRead: { _ in },
        onSelectCharacter: { _ in },
        onSelectLeader: {}
    )
    .padding()
    .background(Palette.backdrop)
    .environment(database)
}

#Preview("Leader rested") {
    let database = CardDatabase()
    let engine = BoardPreview.engine(database: database)

    BoardSideView(
        slot: .player,
        title: "P1",
        isNear: true,
        isActive: true,
        layout: BoardPreview.wideLayout,
        engine: engine,
        emphasis: BoardEmphasis(leaderNote: "Rested — recovers next turn"),
        chakraFace: database.chakraCards.first,
        onRead: { _ in },
        onSelectCharacter: { _ in },
        onSelectLeader: {}
    )
    .padding()
    .background(Palette.backdrop)
    .environment(database)
}

#Preview("Far side, targeted") {
    let database = CardDatabase()
    let engine = BoardPreview.engine(database: database)

    BoardSideView(
        slot: .opponent,
        title: "P2",
        isNear: false,
        isActive: false,
        layout: BoardPreview.wideLayout,
        engine: engine,
        emphasis: BoardEmphasis(
            isTargetingAttack: true,
            attackTargets: Set(engine.side(.opponent).characters.filter(\.isRested).map(\.id)),
            leaderIsAttackTarget: true
        ),
        chakraFace: database.chakraCards.first,
        onRead: { _ in },
        onSelectCharacter: { _ in },
        onSelectLeader: {}
    )
    .padding()
    .background(Palette.backdrop)
    .environment(database)
}

/// A prompt choosing from the mat: every offered card lit and marked, one of
/// them staged, and everything else pushed back.
#Preview("Choosing a target") {
    let database = CardDatabase()
    let engine = BoardPreview.engine(database: database)
    let bodies = engine.side(.player).characters.map(\.id)

    BoardSideView(
        slot: .player,
        title: "P1",
        isNear: true,
        isActive: true,
        layout: BoardPreview.wideLayout,
        engine: engine,
        emphasis: BoardEmphasis(
            isChoosing: true,
            choiceTargets: Set(bodies.dropFirst()),
            leaderIsChoiceTarget: true,
            stagedTargets: Set(bodies.prefix(1))
        ),
        chakraFace: database.chakraCards.first,
        onRead: { _ in },
        onSelectCharacter: { _ in },
        onSelectLeader: {}
    )
    .padding()
    .background(Palette.backdrop)
    .environment(database)
}

/// Damage landing: a floating number over the body that was hit and over the
/// Leader that lost life, with the health readout counting down under it.
#Preview("Damage landing") {
    let database = CardDatabase()
    let engine = BoardPreview.engine(database: database)

    BoardSideView(
        slot: .player,
        title: "P1",
        isNear: true,
        isActive: false,
        layout: BoardPreview.wideLayout,
        engine: engine,
        emphasis: BoardEmphasis(),
        chakraFace: database.chakraCards.first,
        onRead: { _ in },
        onSelectCharacter: { _ in },
        onSelectLeader: {},
        flashes: engine.side(.player).characters.first.map {
            [
                DamageFlash(target: .character($0.id), amount: 3, kind: .damage),
                DamageFlash(target: .leader(.player), amount: 2, kind: .damage)
            ]
        } ?? [DamageFlash(target: .leader(.player), amount: 2, kind: .damage)]
    )
    .padding()
    .background(Palette.backdrop)
    .environment(database)
}

/// The information rule, on the mat: the same set Support, from both sides of
/// the table. The owner sees the printing behind a blur, because they may look
/// at what they set. The other player sees a back — a blur would be no
/// redaction at all when thirty-five printings are told apart by colour and
/// silhouette alone.
#Preview("Face-down: mine, then theirs") {
    let database = CardDatabase()
    let board = BoardPreview.engineWithASetSupport(database: database)

    return VStack(alignment: .leading, spacing: Metrics.spacingM) {
        Text("The owner's half").sectionLabel()
        BoardSideView(
            slot: board.slot,
            title: "P1",
            isNear: true,
            isActive: true,
            layout: BoardPreview.wideLayout,
            engine: board.engine,
            emphasis: BoardEmphasis(),
            chakraFace: database.chakraCards.first,
            onRead: { _ in },
            onSelectCharacter: { _ in },
            onSelectLeader: {}
        )

        Text("The other side of the table").sectionLabel()
        BoardSideView(
            slot: board.slot,
            title: "P2",
            isNear: false,
            isActive: false,
            layout: BoardPreview.wideLayout,
            engine: board.engine,
            emphasis: BoardEmphasis(),
            chakraFace: database.chakraCards.first,
            onRead: { _ in },
            onSelectCharacter: { _ in },
            onSelectLeader: {}
        )
    }
    .padding()
    .background(Palette.backdrop)
    .environment(database)
}

/// A Support activating: the card comes into focus in its slot and stays there
/// for a beat and a half, whether or not the engine has already emptied the
/// slot underneath it.
#Preview("A support activating") {
    let database = CardDatabase()
    let board = BoardPreview.engineWithASetSupport(database: database)
    let set = board.engine.side(board.slot).supports
        .enumerated()
        .compactMap { index, placed in placed.map { (index: index, placed: $0) } }
        .first

    return BoardSideView(
        slot: board.slot,
        title: "P1",
        isNear: true,
        isActive: true,
        layout: BoardPreview.wideLayout,
        engine: board.engine,
        emphasis: BoardEmphasis(),
        chakraFace: database.chakraCards.first,
        onRead: { _ in },
        onSelectCharacter: { _ in },
        onSelectLeader: {},
        reveals: set.map {
            [SupportReveal(
                supportID: $0.placed.id,
                slot: board.slot,
                slotIndex: $0.index,
                cardID: $0.placed.cardID,
                wasAlreadyUp: false
            )]
        } ?? []
    )
    .padding()
    .background(Palette.backdrop)
    .environment(database)
}
