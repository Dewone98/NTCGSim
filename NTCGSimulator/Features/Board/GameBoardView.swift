//
//  GameBoardView.swift
//  NTCGSimulator
//
//  The board screen: it owns the `GameEngine` for one game, lays the two halves
//  out around the status band, and turns taps into `GameAction`s. Nothing here
//  touches `GameState` — every decision goes through `engine.apply(_:by:)` and
//  every refusal comes back as copy the engine already wrote.
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

    /// Slots in the Characters and Support rows.
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

    var body: some View {
        let design = designWidth

        CardFaceView(card: card, size: size, isDimmed: isDimmed, highlight: highlight)
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
        .toolbar(.hidden, for: .navigationBar)
        .navigationBarBackButtonHidden(true)
    }

    private func startNewGame() {
        engine = GameEngine(
            configuration: configuration,
            database: database,
            decks: decks,
            seed: Self.timeSeed()
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

    /// The card in the reader.
    @State private var focusedCard: Card?

    /// The hand index lifted out of the strip.
    @State private var selectedHandIndex: Int?

    /// The attacker waiting for a target.
    @State private var selectedAttacker: UUID?

    /// A Leader ability that has been chosen and is waiting for its target.
    @State private var armedAbility: LeaderAbility?

    /// A decision held back until the player confirms it.
    @State private var confirmation: BoardConfirmation?

    /// The most recent refusal, shown briefly rather than as an alert.
    @State private var banner: BoardBanner?

    @State private var showsJournal = false

    /// Bumped by every accepted action. Automation keys off it, so the AI takes
    /// exactly one move per change and the loop is visible rather than instant.
    @State private var revision = 0

    /// Long enough to watch a move land, short enough not to feel like a stall.
    private static let aiDelay: Duration = .seconds(0.7)

    /// The end step has nothing to decide, so auto-pass barely pauses.
    private static let autoPassDelay: Duration = .seconds(0.3)

    var body: some View {
        GeometryReader { geo in
            let layout = BoardLayout(
                size: geo.size,
                isCompact: horizontalSizeClass == .compact
            )

            let canvas = layout.canvasSize(in: geo.size)

            Group {
                if layout.isCompact {
                    compactBoard(layout)
                } else {
                    regularBoard(layout)
                }
            }
            .frame(width: canvas.width, height: canvas.height)
            .scaleEffect(layout.contentScale)
            .frame(width: geo.size.width, height: geo.size.height)
        }
        .overlay(alignment: .top) { bannerView }
        .overlay { resultOverlay }
        .sheet(isPresented: $showsJournal) {
            JournalSheet(journal: engine.journal) { showsJournal = false }
        }
        .confirmationDialog(
            confirmationTitle,
            isPresented: confirmationBinding,
            titleVisibility: .visible,
            presenting: confirmation
        ) { pending in
            confirmationActions(pending)
        } message: { pending in
            Text(message(for: pending))
        }
        .task(id: revision) { await advanceAutomation() }
        .task(id: banner?.id) { await fadeBanner() }
    }

    // MARK: Layouts

    /// Phone portrait: everything stacks, the journal hides behind a button and
    /// the reader becomes a bar along the bottom.
    private func compactBoard(_ layout: BoardLayout) -> some View {
        VStack(spacing: Metrics.spacingS) {
            side(farSlot, layout: layout)
            Spacer(minLength: 0)
            statusBar(layout)
            Spacer(minLength: 0)
            side(nearSlot, layout: layout)
            hand(layout)
            inspector(layout)
        }
        .padding(.horizontal, Metrics.spacingS)
        .padding(.vertical, Metrics.spacingS)
    }

    /// iPad and landscape: the reader keeps a permanent rail and the journal
    /// sits beside the status bar in the middle band.
    private func regularBoard(_ layout: BoardLayout) -> some View {
        HStack(alignment: .top, spacing: Metrics.spacingM) {
            VStack(spacing: Metrics.spacingS) {
                side(farSlot, layout: layout)
                Spacer(minLength: 0)
                middleBand(layout)
                Spacer(minLength: 0)
                side(nearSlot, layout: layout)
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

    private func side(_ slot: PlayerSlot, layout: BoardLayout) -> some View {
        BoardSideView(
            slot: slot,
            title: displayName(for: slot),
            isNear: slot == nearSlot,
            isActive: slot == engine.currentPlayer && !engine.isFinished,
            layout: layout,
            engine: engine,
            emphasis: emphasis(for: slot),
            chakraFace: chakraFace,
            onRead: { focusedCard = $0 },
            onSelectCharacter: { tapCharacter($0, on: slot) },
            onSelectLeader: { tapLeader(of: slot) }
        )
        .frame(height: layout.sideHeight)
    }

    private func statusBar(_ layout: BoardLayout) -> some View {
        BoardStatusBar(
            phase: engine.phase,
            turnNumber: engine.turnNumber,
            prompt: prompt,
            activePlayer: displayName(for: engine.currentPlayer),
            isCompact: layout.isCompact,
            journalCount: engine.journal.count,
            onShowJournal: layout.isCompact ? { showsJournal = true } : nil,
            onCancelTargeting: armedAbility == nil ? nil : { cancelAbility() }
        )
    }

    /// The hand dims whole while an ability is choosing a target — the only
    /// tap the board wants next is on a character.
    private func hand(_ layout: BoardLayout) -> some View {
        HandView(
            cards: engine.handCards(for: nearSlot),
            cardWidth: layout.handCardWidth,
            availableChakra: engine.availableChakra(for: nearSlot),
            selectedIndex: selectedHandIndex,
            isInteractive: isHumanControlled(nearSlot) && armedAbility == nil,
            emptyMessage: "\(displayName(for: nearSlot)) has no cards in hand.",
            onPlay: { tapHandCard($0) },
            onRead: { handCard in
                focusedCard = handCard.card
                selectedHandIndex = handCard.id
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
            onLeave: { confirmation = .leave }
        )
    }

    // MARK: Sides

    /// The half drawn at the bottom.
    ///
    /// Solo v Self hands the device back and forth, so the side being asked for
    /// a decision is always the one the right way up — including the blocker,
    /// who is not the player taking the turn.
    private var nearSlot: PlayerSlot {
        guard configuration.mode != .versusAI else { return .player }
        if engine.isAwaitingMulligan {
            return engine.state.needsMulligan(.player) ? .player : .opponent
        }
        if let blocking = engine.blockingPlayer { return blocking }
        return engine.currentPlayer
    }

    private var farSlot: PlayerSlot { nearSlot.opposing }

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

        if engine.isAwaitingMulligan {
            return "\(displayName(for: nearSlot)): keep this hand, or draw a new one."
        }

        if let blocking = engine.blockingPlayer {
            return isHumanControlled(blocking)
                ? "Choose a blocker, or take the attack on your Leader."
                : "\(displayName(for: blocking)) is deciding whether to block."
        }

        guard isHumanControlled(engine.currentPlayer) else {
            return "\(displayName(for: engine.currentPlayer)) is taking their turn."
        }

        if let ability = armedAbility {
            return "\(ability.summary): choose the character it acts on."
        }

        switch engine.phase {
        case .main:
            return "Play cards from your hand, then move to the attack phase."
        case .attack:
            return selectedAttacker == nil
                ? "Choose a character to attack with, or end the phase."
                : "Choose a target, or tap the attacker again to change your mind."
        case .end:
            return "End the turn to pass to \(displayName(for: engine.currentPlayer.opposing))."
        case .refresh, .draw:
            return "Refreshing chakra and drawing."
        }
    }

    // MARK: Emphasis

    private func emphasis(for slot: PlayerSlot) -> BoardEmphasis {
        var value = BoardEmphasis()
        guard !engine.isFinished else { return value }

        if let blocking = engine.blockingPlayer {
            value.blockers = slot == blocking && isHumanControlled(blocking)
            return value
        }

        guard isHumanControlled(engine.currentPlayer) else { return value }

        // The Leader is either an unspent control or a spent one, and stays
        // marked as spent for the rest of the turn either way.
        if slot == engine.currentPlayer, engine.leaderCard(for: slot)?.leaderAbility != nil {
            value.leaderIsReady = availableLeaderAbility != nil
            value.leaderIsSpent = engine.side(slot).hasUsedLeaderAbility
        }

        if armedAbility != nil {
            // Identities are unique across the whole board, so both sides can
            // be handed the same set and each will only find its own.
            value.isTargeting = true
            value.abilityTargets = armedTargetIDs
            return value
        }

        guard engine.phase == .attack else { return value }

        if slot == engine.currentPlayer {
            value.attackers = true
            value.selected = selectedAttacker
        } else if selectedAttacker != nil {
            value.targets = true
            value.leaderIsTarget = true
        }
        return value
    }

    // MARK: Taps

    /// A hand tap plays the card. An unplayable card still lands in the reader,
    /// and the engine's own refusal explains why nothing happened.
    private func tapHandCard(_ handCard: HandCard) {
        focusedCard = handCard.card
        selectedHandIndex = handCard.id

        // An armed ability owns the next tap. Reading the card is still useful,
        // so the tap lands in the reader and the board explains the rest.
        if armedAbility != nil {
            show("Choose a character for the ability, or cancel it first.")
            return
        }

        // Only a body can be either summoned or spent — a Support card played
        // through its own line has nothing to choose between.
        let wantsChoice = settings.confirmJutsuSummon
            && handCard.card.type.isBody
            && handCard.card.hasSupportLine
            && handCard.isPlayable
        if wantsChoice {
            confirmation = .jutsu(handCard)
            return
        }
        play(handCard)
    }

    /// Summons where it can and falls back to the support line where it cannot —
    /// a full Characters row should not make a jutsu unplayable.
    private func play(_ handCard: HandCard, asJutsu: Bool? = nil) {
        if let asJutsu {
            perform(.playCard(handIndex: handCard.id, asJutsu: asJutsu), by: nearSlot)
            return
        }

        if case .failure(let error) = engine.planPlay(handIndex: handCard.id, asJutsu: false, by: nearSlot) {
            if handCard.card.hasSupportLine,
               case .success = engine.planPlay(handIndex: handCard.id, asJutsu: true, by: nearSlot) {
                perform(.playCard(handIndex: handCard.id, asJutsu: true), by: nearSlot)
            } else {
                show(error.message)
            }
            return
        }
        perform(.playCard(handIndex: handCard.id, asJutsu: false), by: nearSlot)
    }

    private func tapCharacter(_ character: CharacterInPlay, on slot: PlayerSlot) {
        if let card = engine.card(for: character) { focusedCard = card }

        if let ability = armedAbility {
            guard armedTargetIDs.contains(character.id) else {
                show(GameError.abilityNeedsTarget.message)
                return
            }
            requestAbility(
                ability,
                targetID: character.id,
                targetName: engine.card(for: character)?.name ?? "that character"
            )
            return
        }

        if let blocking = engine.blockingPlayer {
            guard isHumanControlled(blocking), slot == blocking else { return }
            guard engine.canBlock(characterID: character.id) else {
                show(GameError.blockerUnavailable.message)
                return
            }
            perform(.declareBlock(blockerID: character.id), by: blocking)
            return
        }

        guard isHumanControlled(engine.currentPlayer), engine.phase == .attack else { return }

        if slot == engine.currentPlayer {
            guard engine.canAttack(characterID: character.id, by: slot) else {
                show(GameError.attackerUnavailable.message)
                return
            }
            withAnimation(.easeOut(duration: 0.15)) {
                selectedAttacker = selectedAttacker == character.id ? nil : character.id
            }
            return
        }

        guard let attackerID = selectedAttacker else {
            show("Choose one of your characters to attack with first.")
            return
        }
        requestAttack(
            attackerID: attackerID,
            target: .character(character.id),
            targetName: engine.card(for: character)?.name ?? "that character"
        )
    }

    private func tapLeader(of slot: PlayerSlot) {
        if let leader = engine.leaderCard(for: slot) { focusedCard = leader }

        // Your own Leader is the ability's button — and, once armed, its cancel.
        // The enemy Leader is only ever an attack target. A Leader that has
        // already gone this turn answers neither, and simply reads.
        if slot == engine.currentPlayer, let ability = availableLeaderAbility {
            armLeaderAbility(ability)
            return
        }

        guard engine.blockingPlayer == nil,
              isHumanControlled(engine.currentPlayer),
              engine.phase == .attack,
              slot != engine.currentPlayer,
              let attackerID = selectedAttacker
        else { return }

        requestAttack(
            attackerID: attackerID,
            target: .leader,
            targetName: engine.leaderCard(for: slot)?.name ?? "the Leader"
        )
    }

    private func requestAttack(attackerID: UUID, target: AttackTarget, targetName: String) {
        guard settings.targetConfirm == .askMe else {
            perform(.attack(attackerID: attackerID, target: target), by: engine.currentPlayer)
            return
        }
        confirmation = .attack(attackerID: attackerID, target: target, targetName: targetName)
    }

    // MARK: Contextual actions

    private var contextActions: [BoardAction] {
        if engine.isFinished {
            return [BoardAction(id: "again", title: "Play again", style: .primary, perform: onPlayAgain)]
        }

        if engine.isAwaitingMulligan {
            guard isHumanControlled(nearSlot) else { return [] }
            return [
                BoardAction(id: "keep", title: "Keep this hand", style: .primary) {
                    perform(.mulligan(false), by: nearSlot)
                },
                BoardAction(id: "mulligan", title: "Mulligan") {
                    perform(.mulligan(true), by: nearSlot)
                }
            ]
        }

        if let blocking = engine.blockingPlayer {
            guard isHumanControlled(blocking) else { return [] }
            return [
                BoardAction(id: "take", title: "Take it on the Leader", style: .primary) {
                    perform(.declareBlock(blockerID: nil), by: blocking)
                }
            ]
        }

        guard isHumanControlled(engine.currentPlayer) else { return [] }

        var actions: [BoardAction] = []
        let canEndPhase = engine.phase == .main || engine.phase == .attack
        actions.append(
            BoardAction(id: "phase", title: "End phase", style: .primary, isEnabled: canEndPhase) {
                perform(.endPhase, by: engine.currentPlayer)
            }
        )

        // A Leader ability is once a turn and easy to forget, so it sits
        // between the two phase controls rather than below them.
        if let ability = availableLeaderAbility {
            let isArmed = armedAbility != nil
            actions.append(
                BoardAction(
                    id: "ability",
                    title: isArmed ? "Cancel the ability" : ability.summary,
                    shortTitle: isArmed ? "Cancel" : "Ability"
                ) {
                    if isArmed { cancelAbility() } else { armLeaderAbility(ability) }
                }
            )
        }

        actions.append(BoardAction(id: "turn", title: "End turn") { requestEndTurn() })
        return actions
    }

    /// The current player's unspent Leader ability, when they are the one at
    /// the device. Read from `legalLeaderAbilities` so the button can never
    /// offer an activation the engine would refuse.
    private var availableLeaderAbility: LeaderAbility? {
        guard !engine.isFinished,
              engine.blockingPlayer == nil,
              isHumanControlled(engine.currentPlayer),
              !engine.legalLeaderAbilities(for: engine.currentPlayer).isEmpty
        else { return nil }
        return engine.leaderCard(for: engine.currentPlayer)?.leaderAbility
    }

    /// Resolves an untargeted ability straight away, and arms a targeted one so
    /// the next tap on a character picks its target. Arming twice cancels.
    private func armLeaderAbility(_ ability: LeaderAbility) {
        guard ability.needsTarget else {
            perform(.useLeaderAbility(targetID: nil), by: engine.currentPlayer)
            return
        }
        withAnimation(.easeOut(duration: 0.15)) {
            armedAbility = armedAbility == ability ? nil : ability
        }
    }

    private func cancelAbility() {
        withAnimation(.easeOut(duration: 0.15)) { armedAbility = nil }
    }

    /// The bodies the armed ability may legally be pointed at.
    ///
    /// Read straight off `legalLeaderAbilities`, each of which carries the
    /// target it would use, so the ringed cards and the engine's own answer are
    /// the same list rather than two guesses at it.
    private var armedTargetIDs: Set<UUID> {
        guard armedAbility != nil else { return [] }
        let actions = engine.legalLeaderAbilities(for: engine.currentPlayer)
        return Set(actions.compactMap { action -> UUID? in
            guard case .useLeaderAbility(let targetID) = action else { return nil }
            return targetID
        })
    }

    /// Picking a target resolves at once or asks first, exactly as picking an
    /// attack target does — it is the same preference either way.
    private func requestAbility(_ ability: LeaderAbility, targetID: UUID, targetName: String) {
        guard settings.targetConfirm == .askMe else {
            perform(.useLeaderAbility(targetID: targetID), by: engine.currentPlayer)
            return
        }
        confirmation = .ability(ability, targetID: targetID, targetName: targetName)
    }

    private func requestEndTurn() {
        guard settings.endTurnConfirm == .askMe else {
            perform(.endTurn, by: engine.currentPlayer)
            return
        }
        confirmation = .endTurn
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
        switch engine.apply(action, by: slot) {
        case .success:
            withAnimation(.easeOut(duration: 0.22)) {
                selectedAttacker = nil
                selectedHandIndex = nil
                armedAbility = nil
                banner = nil
            }
            revision += 1
            return true

        case .failure(let error):
            if announcesErrors { show(error.message) }
            return false
        }
    }

    // MARK: Automation

    /// Runs after every accepted action. It either passes the end step for a
    /// player who asked not to be stopped there, or takes one AI move — and
    /// then lets the next revision restart it, which is the loop.
    private func advanceAutomation() async {
        guard !engine.isFinished else { return }

        if shouldAutoPass {
            try? await Task.sleep(for: Self.autoPassDelay)
            guard !Task.isCancelled, shouldAutoPass else { return }
            perform(.endTurn, by: engine.currentPlayer, announcesErrors: false)
            return
        }

        guard aiOwesAMove else { return }
        try? await Task.sleep(for: Self.aiDelay)
        guard !Task.isCancelled, aiOwesAMove else { return }
        takeAIMove()
    }

    /// The end step is the only place a turn waits with nothing to decide, so it
    /// is the only place `SettingsStore.autoPass` applies.
    private var shouldAutoPass: Bool {
        settings.autoPass == .passForMe
            && !engine.isFinished
            && !engine.isAwaitingMulligan
            && engine.blockingPlayer == nil
            && engine.phase == .end
            && isHumanControlled(engine.currentPlayer)
    }

    private var aiOwesAMove: Bool {
        guard configuration.mode == .versusAI, !engine.isFinished else { return false }
        if let blocking = engine.blockingPlayer { return blocking == .opponent }
        if engine.isAwaitingMulligan { return engine.state.needsMulligan(.opponent) }
        return engine.currentPlayer == .opponent
    }

    /// Asks the AI for one move. A refusal is never fatal: the board falls back
    /// to the safe answer for whatever the game is waiting on, so a mistaken AI
    /// slows the game down rather than freezing it.
    private func takeAIMove() {
        let ai = SimpleAI()
        if let action = ai.chooseAction(engine: engine, slot: .opponent),
           perform(action, by: .opponent, announcesErrors: false) {
            return
        }
        passForAI()
    }

    private func passForAI() {
        if let blocking = engine.blockingPlayer, blocking == .opponent {
            perform(.declareBlock(blockerID: nil), by: .opponent, announcesErrors: false)
        } else if engine.state.needsMulligan(.opponent) {
            perform(.mulligan(false), by: .opponent, announcesErrors: false)
        } else if engine.currentPlayer == .opponent {
            perform(.endTurn, by: .opponent, announcesErrors: false)
        }
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
                .transition(.move(edge: .top).combined(with: .opacity))
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
    private enum BoardConfirmation: Identifiable {
        case jutsu(HandCard)
        case attack(attackerID: UUID, target: AttackTarget, targetName: String)
        case ability(LeaderAbility, targetID: UUID, targetName: String)
        case endTurn
        case leave

        var id: String {
            switch self {
            case .jutsu(let handCard):   return "jutsu-\(handCard.id)"
            case .attack(let id, _, _):  return "attack-\(id.uuidString)"
            case .ability(_, let id, _): return "ability-\(id.uuidString)"
            case .endTurn:               return "end-turn"
            case .leave:                 return "leave"
            }
        }
    }

    private var confirmationBinding: Binding<Bool> {
        Binding(
            get: { confirmation != nil },
            set: { if !$0 { confirmation = nil } }
        )
    }

    private var confirmationTitle: String {
        guard let confirmation else { return "" }
        switch confirmation {
        case .jutsu(let handCard): return handCard.card.name
        case .attack:              return "Declare the attack?"
        case .ability:             return "Use your Leader?"
        case .endTurn:             return "End your turn?"
        case .leave:               return "Leave the game?"
        }
    }

    private func message(for pending: BoardConfirmation) -> String {
        switch pending {
        case .jutsu(let handCard):
            return """
            Summoning \(handCard.card.name) as a Character costs no chakra. \
            Playing the support line instead is a jutsu: it costs \
            \(chakraPhrase(handCard.card.jutsuCost ?? 0)) and sends the card to the Trash.
            """
        case .attack(_, _, let targetName):
            return "Attack \(targetName)."
        case .ability(let ability, _, let targetName):
            return "\(ability.summary): \(targetName)."
        case .endTurn:
            return "Anything left in the attack phase will be given up."
        case .leave:
            return "The game is not saved, so leaving ends it."
        }
    }

    @ViewBuilder
    private func confirmationActions(_ pending: BoardConfirmation) -> some View {
        switch pending {
        case .jutsu(let handCard):
            // The two halves of the choice are priced differently now, so the
            // buttons say so rather than leaving the player to remember.
            Button("Summon as a Character (free)") { play(handCard, asJutsu: false) }
            Button("Play as a jutsu (\(chakraPhrase(handCard.card.jutsuCost ?? 0)))") {
                play(handCard, asJutsu: true)
            }
            Button("Cancel", role: .cancel) { confirmation = nil }

        case .attack(let attackerID, let target, _):
            Button("Attack") {
                perform(.attack(attackerID: attackerID, target: target), by: engine.currentPlayer)
            }
            Button("Cancel", role: .cancel) { confirmation = nil }

        case .ability(_, let targetID, _):
            Button("Use the ability") {
                perform(.useLeaderAbility(targetID: targetID), by: engine.currentPlayer)
            }
            Button("Cancel", role: .cancel) { confirmation = nil }

        case .endTurn:
            Button("End turn") { perform(.endTurn, by: engine.currentPlayer) }
            Button("Cancel", role: .cancel) { confirmation = nil }

        case .leave:
            Button("Leave the game", role: .destructive) { router.popToRoot() }
            Button("Stay", role: .cancel) { confirmation = nil }
        }
    }

    /// "1 chakra" rather than "1 chakras", and "free" rather than "0 chakra".
    private func chakraPhrase(_ amount: Int) -> String {
        amount == 0 ? "free" : "\(amount) chakra"
    }
}

// MARK: - Preview support

/// Fixtures shared by every board preview.
///
/// Previews cannot run statements beside a view, so the mulligan both sides owe
/// is answered here rather than inline in each `#Preview`.
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

    /// A game past the opening mulligan, so the board has a turn to show.
    static func engine(database: CardDatabase) -> GameEngine {
        let engine = GameEngine(
            configuration: configuration,
            database: database,
            decks: DeckStore(),
            seed: 42
        )
        engine.apply(.mulligan(false), by: .player)
        engine.apply(.mulligan(false), by: .opponent)
        return engine
    }

    /// A short log with both a system line and a player line in it.
    static func journal() -> Journal {
        var journal = Journal()
        journal.system("Classic game. You go first.")
        journal.record(actor: PlayerSlot.player.title, message: "Kept the opening hand.")
        journal.system("Turn 1 — You.")
        journal.record(actor: PlayerSlot.player.title, message: "Summoned Naruto Uzumaki.")
        journal.record(actor: PlayerSlot.player.title, message: "Played Shadow Clone Jutsu to Support for 2 chakra.")
        journal.system("Attack phase.")
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
