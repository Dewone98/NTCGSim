//
//  BoardSideView.swift
//  NTCGSimulator
//
//  One player's half of the mat: Leader and life, the Characters row, the five
//  Support slots, the Chakra row with the Summon zone, and the zone counters.
//  The far side draws the same zones mirrored, so the two halves meet at the
//  Characters rows the way a physical mat does.
//

import SwiftUI

// MARK: - Emphasis

/// What a side should light up right now.
///
/// The board works this out once per side from the engine's own legality checks,
/// so a highlighted card is always a card the engine will actually accept.
struct BoardEmphasis: Equatable {

    /// Ring the characters that may still declare an attack this turn.
    var attackers = false

    /// Ring the enemy board because an attacker is looking for a target.
    var targets = false

    /// Ring the characters that could answer a declared attack.
    var blockers = false

    /// The bodies an armed Leader ability may legally be pointed at, taken from
    /// `legalLeaderAbilities`. A ringed body is one the engine will accept.
    var abilityTargets: Set<UUID> = []

    /// A Leader ability is waiting for its target, so everything that is not a
    /// legal target steps back out of the way.
    var isTargeting = false

    /// The character the player has already chosen.
    var selected: UUID? = nil

    /// The Leader is a legal target for the chosen attacker.
    var leaderIsTarget = false

    /// This Leader still has its once-a-turn ability in hand.
    var leaderIsReady = false

    /// This Leader has already spent its ability this turn.
    var leaderIsSpent = false
}

// MARK: - Side

/// Draws every zone belonging to one `PlayerSlot`.
///
/// The view reads the engine but never mutates it: taps are reported upwards and
/// `GameBoardView` decides what, if anything, they mean.
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
    /// colour; the player's `SettingsStore.chakraCardID` preference is honoured
    /// here, at render time, rather than by changing the rules.
    let chakraFace: Card?

    /// A long press anywhere on the side sends the card to the reader.
    let onRead: (Card) -> Void

    /// A tap on a body — attacker choice, target choice or block answer.
    let onSelectCharacter: (CharacterInPlay) -> Void

    /// A tap on the Leader: its own ability button, or an attack target.
    let onSelectLeader: () -> Void

    private var side: PlayerSide { engine.side(slot) }

    /// How far back anything that is not a legal target fades while a Leader
    /// ability is choosing one. Matches the dim `CardFaceView` applies itself.
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

    private var characterRow: some View {
        HStack(spacing: layout.gap) {
            ForEach(0..<GameRules.maxCharacters, id: \.self) { index in
                if index < side.characters.count {
                    characterSlot(side.characters[index])
                } else {
                    emptySlot(width: layout.slotWidth, label: "Empty character slot")
                }
            }
        }
        .frame(height: layout.slotHeight)
    }

    /// The five printed Support slots. A Support card played from hand lands in
    /// the first free one and stays there, so this row is no longer decorative.
    private var supportRow: some View {
        HStack(spacing: layout.gap) {
            ForEach(Array(side.support.enumerated()), id: \.offset) { entry in
                supportSlot(entry.element, number: entry.offset + 1)
            }
        }
        .frame(height: layout.slotHeight)
    }

    /// The Summon zone shares this row rather than taking a row of its own —
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

    // MARK: Slots

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
            // A rested body lies on its side, and shrinks to the aspect ratio so
            // the turned card still occupies exactly one slot.
            .rotationEffect(.degrees(character.isRested ? 90 : 0))
            .scaleEffect(character.isRested ? Metrics.cardAspect : 1)
            .animation(.easeOut(duration: 0.22), value: character.isRested)

            if let card, character.damageTaken > 0 {
                healthBadge(character.remainingHealth(of: card))
            }

            // A modified body has to read as the number combat will use, not
            // as the number printed on the card.
            if let card, character.powerBonus != 0 {
                powerBadge(character.effectivePower(of: card), bonus: character.powerBonus)
            }

            if character.summonedThisTurn {
                sicknessMark
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

    /// One Support slot. `nil` keeps the empty treatment, so an unused zone
    /// still reads as a zone rather than as a gap in the mat.
    @ViewBuilder
    private func supportSlot(_ placed: PlacedCard?, number: Int) -> some View {
        if let placed, let card = engine.card(for: placed) {
            BoardCardFace(card: card, width: layout.slotWidth, isDimmed: emphasis.isTargeting)
                .contentShape(Rectangle())
                .onTapGesture { onRead(card) }
                .accessibilityElement(children: .ignore)
                .accessibilityAddTraits(.isButton)
                .accessibilityLabel("Support slot \(number), \(card.name)")
        } else {
            emptySlot(width: layout.slotWidth, label: "Support slot \(number), empty")
        }
    }

    private func chakraSlot(_ chakra: ChakraCard) -> some View {
        Group {
            if chakra.isRested {
                CardBackView(tint: Palette.textSecondary)
                    .frame(width: layout.chakraWidth)
            } else if let face = chakraFace ?? engine.card(for: chakra) {
                BoardCardFace(card: face, width: layout.chakraWidth)
            } else {
                CardBackView(tint: Palette.accent)
                    .frame(width: layout.chakraWidth)
            }
        }
        .opacity(emphasis.isTargeting ? Self.pushedBackOpacity : 1)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(chakra.isRested ? "Chakra, rested" : "Chakra, ready")
    }

    @ViewBuilder
    private var summonSlot: some View {
        if let placed = side.summon, let card = engine.card(for: placed) {
            BoardCardFace(card: card, width: layout.slotWidth, isDimmed: emphasis.isTargeting)
                .contentShape(Rectangle())
                .onTapGesture { onRead(card) }
                .accessibilityElement(children: .ignore)
                .accessibilityAddTraits(.isButton)
                .accessibilityLabel("Summon zone, \(card.name)")
        } else {
            emptySlot(width: layout.slotWidth, label: "Summon zone, empty")
        }
    }

    /// A dashed outline. Empty zones still have to read as zones, otherwise the
    /// board looks broken rather than uncontested.
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
            abilityBadge
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
        // A pool imported without a Leader leaves the side anchored to nothing,
        // so the card back stands in rather than the board collapsing.
        if let leader = engine.leaderCard(for: slot) {
            BoardCardFace(
                card: leader,
                width: layout.leaderWidth,
                isDimmed: emphasis.isTargeting && !emphasis.leaderIsReady,
                highlight: leaderHighlight
            )
            .overlay(alignment: .topTrailing) {
                if emphasis.leaderIsReady { abilityMark }
            }
            .contentShape(Rectangle())
            .onTapGesture { onSelectLeader() }
            .onLongPressGesture { onRead(leader) }
            .accessibilityElement(children: .ignore)
            .accessibilityAddTraits(leaderIsInteractive ? [.isButton] : [])
            .accessibilityLabel(leaderDescription(leader))
        } else {
            CardBackView(tint: Palette.border)
                .frame(width: layout.leaderWidth)
                .accessibilityLabel("\(title) has no Leader in the pool")
        }
    }

    /// The Leader answers a tap as an ability button or as an attack target.
    /// Once its ability is spent it is inert for the rest of the turn — a tap
    /// still puts it in the reader, but it is no longer a control.
    private var leaderIsInteractive: Bool {
        emphasis.leaderIsReady || emphasis.leaderIsTarget
    }

    /// A target ring beats an "ability ready" ring: being attacked is the more
    /// urgent thing to notice. A spent Leader keeps a ring, dimmed, so the card
    /// still reads as the control it was rather than as an ordinary card.
    private var leaderHighlight: Color? {
        if emphasis.leaderIsTarget { return Palette.negative }
        if emphasis.leaderIsReady { return Palette.accent }
        if emphasis.leaderIsSpent { return Palette.border }
        return nil
    }

    /// Marks a Leader whose once-a-turn ability has not been spent.
    private var abilityMark: some View {
        Image(systemName: "sparkles")
            .font(.system(size: 8, weight: .bold))
            .foregroundStyle(Palette.textOnAccent)
            .padding(3)
            .background(Palette.accent, in: Circle())
            .padding(2)
            .accessibilityHidden(true)
    }

    /// Says what the Leader does, under the card.
    ///
    /// The ability is the one control on the mat with nothing printed to
    /// explain it, so it names itself rather than relying on the ring alone —
    /// and says so plainly once it has been spent.
    @ViewBuilder
    private var abilityBadge: some View {
        if let text = abilityBadgeText {
            Text(text)
                .font(Typeface.label(layout.leaderWidth < 64 ? 8 : 10))
                .tracking(0.6)
                .textCase(.uppercase)
                .foregroundStyle(emphasis.leaderIsReady ? Palette.textOnAccent : Palette.textSecondary)
                .multilineTextAlignment(.center)
                .lineLimit(3)
                .minimumScaleFactor(0.55)
                .padding(.horizontal, 3)
                .padding(.vertical, 3)
                .frame(maxWidth: .infinity)
                .background(
                    emphasis.leaderIsReady ? Palette.accent : Palette.surface,
                    in: NotchedRectangle(notch: 5, corners: .diagonal)
                )
                .accessibilityHidden(true)
        }
    }

    private var abilityBadgeText: String? {
        if emphasis.leaderIsReady {
            guard let ability = engine.leaderCard(for: slot)?.leaderAbility else { return nil }
            return emphasis.isTargeting ? "Tap to cancel" : ability.summary
        }
        return emphasis.leaderIsSpent ? "Used this turn" : nil
    }

    private func leaderDescription(_ leader: Card) -> String {
        var parts = ["\(title) Leader", leader.name, "\(side.life) life"]
        if let ability = leader.leaderAbility {
            if emphasis.leaderIsReady {
                parts.append(
                    emphasis.isTargeting
                        ? "choosing a target for \(ability.summary), double tap to cancel"
                        : "ability ready, \(ability.summary)"
                )
            } else if emphasis.leaderIsSpent {
                parts.append("ability used this turn")
            }
        }
        return parts.joined(separator: ", ")
    }

    /// The counters wrap onto two lines if they are allowed to, which throws
    /// the column out of alignment.
    private func counterPill(_ label: String, _ value: Int) -> some View {
        CountPill(label: label, value: "\(value)")
            .lineLimit(1)
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

    /// Remaining health after this turn's battle damage. Damage heals during
    /// cleanup, so the badge only ever appears mid-turn.
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

    /// Power after a Leader ability has moved it, drawn over the printed value
    /// the way the health badge covers printed health. The marker says how far
    /// it moved, tinted for the direction, and expires with the turn.
    private func powerBadge(_ power: Int, bonus: Int) -> some View {
        HStack(spacing: 1.5) {
            Text("\(power)")
                .font(Typeface.numeric(9, weight: .bold))
            Text(bonus > 0 ? "+\(bonus)" : "\(bonus)")
                .font(Typeface.numeric(7, weight: .bold))
        }
        .foregroundStyle(Palette.textOnAccent)
        .padding(.horizontal, 3)
        .padding(.vertical, 1)
        .background(
            bonus > 0 ? Palette.positive : Palette.negative,
            in: RoundedRectangle(cornerRadius: 3)
        )
        .padding(2)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
        .accessibilityHidden(true)
    }

    /// Marks a body that arrived this turn and therefore cannot attack yet.
    private var sicknessMark: some View {
        Circle()
            .fill(Palette.warning)
            .frame(width: 5, height: 5)
            .padding(3)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .accessibilityHidden(true)
    }

    // MARK: Highlighting

    /// The one place a slot's ring colour is decided, so selection, attack and
    /// block emphasis can never fight each other.
    private func highlight(for character: CharacterInPlay) -> Color? {
        if emphasis.selected == character.id { return Palette.accent }
        if emphasis.abilityTargets.contains(character.id) { return Palette.warning }
        if emphasis.isTargeting { return nil }
        if emphasis.blockers, character.isReady { return Palette.positive }
        if emphasis.attackers, character.canAttack { return Palette.accentMuted }
        if emphasis.targets { return Palette.negative }
        return nil
    }

    /// Anything an armed ability cannot legally be pointed at steps back, so
    /// the legal targets are the only lit cards on the mat.
    private func isPushedBack(_ character: CharacterInPlay) -> Bool {
        emphasis.isTargeting && !emphasis.abilityTargets.contains(character.id)
    }

    private func description(of character: CharacterInPlay, card: Card?) -> String {
        var parts = [card?.name ?? character.cardID]
        if let card {
            if card.power != nil { parts.append("power \(character.effectivePower(of: card))") }
            if character.powerBonus != 0 {
                let sign = character.powerBonus > 0 ? "+\(character.powerBonus)" : "\(character.powerBonus)"
                parts.append("\(sign) this turn")
            }
            parts.append("health \(character.remainingHealth(of: card))")
        }
        parts.append(character.isRested ? "rested" : "ready")
        if character.summonedThisTurn { parts.append("summoned this turn") }
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
        emphasis: BoardEmphasis(attackers: true, leaderIsReady: true),
        chakraFace: database.chakraCards.first,
        onRead: { _ in },
        onSelectCharacter: { _ in },
        onSelectLeader: {}
    )
    .padding()
    .background(Palette.backdrop)
    .environment(database)
}

#Preview("Leader already spent") {
    let database = CardDatabase()
    let engine = BoardPreview.engine(database: database)

    BoardSideView(
        slot: .player,
        title: "P1",
        isNear: true,
        isActive: true,
        layout: BoardPreview.wideLayout,
        engine: engine,
        emphasis: BoardEmphasis(leaderIsSpent: true),
        chakraFace: database.chakraCards.first,
        onRead: { _ in },
        onSelectCharacter: { _ in },
        onSelectLeader: {}
    )
    .padding()
    .background(Palette.backdrop)
    .environment(database)
}

#Preview("Far side, mirrored") {
    let database = CardDatabase()
    let engine = BoardPreview.engine(database: database)

    BoardSideView(
        slot: .opponent,
        title: "P2",
        isNear: false,
        isActive: false,
        layout: BoardPreview.wideLayout,
        engine: engine,
        emphasis: BoardEmphasis(targets: true, leaderIsTarget: true),
        chakraFace: database.chakraCards.first,
        onRead: { _ in },
        onSelectCharacter: { _ in },
        onSelectLeader: {}
    )
    .padding()
    .background(Palette.backdrop)
    .environment(database)
}
