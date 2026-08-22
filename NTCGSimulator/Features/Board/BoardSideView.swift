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

        return ZStack(alignment: .bottomTrailing) {
            Group {
                if let card {
                    BoardCardFace(
                        card: card,
                        width: layout.slotWidth,
                        isDimmed: character.isRested || isPushedBack(character),
                        highlight: highlight(for: character)
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

            if let card, character.damage > 0 {
                healthBadge(character.remainingHealth(of: card))
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
        }
        .frame(width: layout.slotWidth, height: layout.slotHeight)
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

    /// One numbered Support slot. `nil` keeps the empty treatment, so an
    /// unused zone still reads as a zone rather than as a gap in the mat.
    ///
    /// A face-down card shows its back, because that is what it is: the answer
    /// it holds is hidden until it is activated. It rings when the open window
    /// could legally be answered with it — the engine's own list, so a
    /// response-timing card stays dark in a summon window — and carries the
    /// chakra printed on its SUPPORT bar so the price of answering is on the
    /// mat rather than only in the response panel.
    private func supportSlot(_ placed: PlacedSupport?, index: Int) -> some View {
        let number = index + 1
        let entry: (placed: PlacedSupport, card: Card)? = placed.flatMap { held in
            engine.card(for: held).map { (placed: held, card: $0) }
        }

        return ZStack(alignment: .topLeading) {
            Group {
                if let entry {
                    supportFace(entry.placed, card: entry.card, index: index)
                } else {
                    emptySlot(width: layout.slotWidth, label: "Support slot \(number), empty")
                }
            }
            .frame(width: layout.slotWidth, height: layout.slotHeight)

            slotNumber(number, isOccupied: entry != nil)

            if let cost = activationCost(at: index) {
                activationCostBadge(cost)
            }
        }
        .frame(width: layout.slotWidth, height: layout.slotHeight)
        .contentShape(Rectangle())
        .onTapGesture { onSelectSupport(index) }
        .onLongPressGesture {
            if let entry, canInspect(entry.placed) { onRead(entry.card) }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityAddTraits(entry == nil ? [] : .isButton)
        .accessibilityLabel(
            entry.map { supportDescription($0.placed, card: $0.card, number: number) }
                ?? "Support slot \(number), empty"
        )
    }

    /// The card itself: a back while it is face-down, its printed face once
    /// its activation has revealed it on the chain.
    @ViewBuilder
    private func supportFace(_ placed: PlacedSupport, card: Card, index: Int) -> some View {
        if placed.isRevealed {
            BoardCardFace(
                card: card,
                width: layout.slotWidth,
                isDimmed: emphasis.isChoosing || emphasis.isTargetingAttack,
                highlight: supportTint(index)
            )
        } else {
            CardBackView(tint: supportTint(index) ?? Palette.accentMuted)
                .frame(width: layout.slotWidth)
                .overlay {
                    if let tint = supportTint(index) {
                        NotchedRectangle(notch: 4, corners: .diagonal)
                            .stroke(tint, lineWidth: 2)
                    }
                }
        }
    }

    /// Whether a long press should send this card to the reader.
    ///
    /// A player may check what they set — a face-down Support is hidden from
    /// the other side of the table, not from its owner — but the opposing
    /// side's backs stay backs. `isNear` is the half drawn the right way up,
    /// which in every mode is the half belonging to whoever holds the device.
    private func canInspect(_ placed: PlacedSupport) -> Bool {
        placed.isRevealed || isNear
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

    private func supportDescription(_ placed: PlacedSupport, card: Card, number: Int) -> String {
        var parts = ["Support slot \(number)"]

        if placed.isRevealed {
            parts.append("\(card.name), activated")
        } else {
            parts.append(isNear ? "your face-down \(card.name)" : "a face-down card")
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
        if let card = engine.database.cards.first(where: { $0.type == .summon }) {
            BoardCardFace(
                card: card,
                width: layout.slotWidth,
                isDimmed: side.summonRested || emphasis.isChoosing || emphasis.isTargetingAttack
            )
            .rotationEffect(.degrees(side.summonRested ? 90 : 0))
            .scaleEffect(side.summonRested ? Metrics.cardAspect : 1)
            .animation(.easeOut(duration: 0.22), value: side.summonRested)
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
                    highlight: leaderHighlight
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
            }
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
            return !emphasis.leaderIsAttackTarget
        }
        return false
    }

    /// A staged or armed ring beats an option ring, an option ring beats a
    /// target ring, and readiness comes last — the more committed a decision
    /// is, the louder it draws.
    private var leaderHighlight: Color? {
        if emphasis.leaderIsStaged { return Palette.accent }
        if emphasis.leaderIsChoiceTarget { return Palette.warning }
        if emphasis.leaderIsSelectedAttacker { return Palette.accent }
        if emphasis.isChoosing { return nil }
        if emphasis.leaderIsAttackTarget { return Palette.negative }
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

    /// Remaining health after this turn's battle damage. Damage heals at end
    /// of turn, so the badge only ever appears mid-turn.
    private func healthBadge(_ remaining: Int) -> some View {
        Text("\(remaining)")
            .font(Typeface.numeric(9, weight: .bold))
            .foregroundStyle(Palette.textOnAccent)
            .padding(.horizontal, 3)
            .padding(.vertical, 1)
            .background(Palette.negative, in: RoundedRectangle(cornerRadius: 3))
            .padding(2)
            .accessibilityHidden(true)
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

    /// The ring a body wears, from most to least committed: staged for the
    /// open prompt, an option for it, the armed attacker, a legal attack
    /// target, ready to attack, ready to activate.
    private func highlight(for character: CharacterInPlay) -> Color? {
        if emphasis.stagedTargets.contains(character.id) { return Palette.accent }
        if emphasis.choiceTargets.contains(character.id) { return Palette.warning }
        if emphasis.selectedAttackerID == character.id { return Palette.accent }
        if emphasis.isChoosing { return nil }
        if emphasis.attackTargets.contains(character.id) { return Palette.negative }
        if emphasis.attackers.contains(character.id) { return Palette.accentMuted }
        if emphasis.readyAbilities.contains(character.id) { return Palette.accent }
        return nil
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
