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
///
/// Abilities are addressed by `AbilitySource` rather than by a Leader-only flag,
/// because every card in play may print one: a side's Leader is `.leader` and
/// each body is `.character(id)`, and the sets below are always read against the
/// side they were built for.
struct BoardEmphasis: Equatable {

    /// Ring the characters that may still declare an attack this turn.
    var attackers = false

    /// Ring the enemy board because an attacker is looking for a target.
    var targets = false

    /// Ring the characters that could answer a declared attack.
    var blockers = false

    /// The bodies an armed ability may legally be pointed at, taken from
    /// `legalAbilities`. A ringed body is one the engine will accept.
    var abilityTargets: Set<UUID> = []

    /// An ability is waiting for its target, so everything that is not a legal
    /// target steps back out of the way.
    var isTargeting = false

    /// The card that asked the question, kept lit while it waits for an answer.
    var armedSource: AbilitySource? = nil

    /// Cards on this side that can activate a printed box right now.
    var readyAbilities: Set<AbilitySource> = []

    /// Cards on this side that have already spent a box this turn.
    var spentAbilities: Set<AbilitySource> = []

    /// Cards printing an activated box the app displays without resolving every
    /// step of. Marked on the mat rather than left to be discovered mid-game.
    var partialAbilities: Set<AbilitySource> = []

    /// The line drawn under the Leader: what its next activation costs, or that
    /// it has already gone this turn.
    var leaderAbilityNote: String? = nil

    /// The character the player has already chosen.
    var selected: UUID? = nil

    /// The Leader is a legal target for the chosen attacker.
    var leaderIsTarget = false
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

    /// A tap on a body — its ability picker, attacker choice, target choice or
    /// block answer, depending on what the board is waiting for.
    let onSelectCharacter: (CharacterInPlay) -> Void

    /// A tap on the Leader: its own ability picker, or an attack target.
    let onSelectLeader: () -> Void

    private var side: PlayerSide { engine.side(slot) }

    /// How far back anything that is not a legal target fades while an ability
    /// is choosing one. Matches the dim `CardFaceView` applies itself.
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
        let source = AbilitySource.character(character.id)

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

            if let card {
                modifierStrip(character, card: card)
            }

            if character.summonedThisTurn {
                sicknessMark
            }

            if emphasis.readyAbilities.contains(source) {
                abilityMark(isPartial: emphasis.partialAbilities.contains(source))
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
            ZStack(alignment: .topTrailing) {
                BoardCardFace(
                    card: leader,
                    width: layout.leaderWidth,
                    isDimmed: emphasis.isTargeting && !leaderIsArmed,
                    highlight: leaderHighlight
                )
                // Several cards print "rest this card" on a Leader, so a Leader
                // is turned on its side exactly as a body is — the mat already
                // has one way of saying rested and does not need a second.
                .rotationEffect(.degrees(side.leaderIsRested ? 90 : 0))
                .scaleEffect(side.leaderIsRested ? Metrics.cardAspect : 1)
                .animation(.easeOut(duration: 0.22), value: side.leaderIsRested)

                if leaderHasReadyAbility {
                    abilityMark(isPartial: emphasis.partialAbilities.contains(.leader))
                        .padding(2)
                }
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

    /// This Leader can activate at least one of its printed boxes right now.
    private var leaderHasReadyAbility: Bool {
        emphasis.readyAbilities.contains(.leader)
    }

    /// This Leader has already spent one of its boxes this turn.
    private var leaderHasSpentAbility: Bool {
        emphasis.spentAbilities.contains(.leader)
    }

    /// This Leader is the card currently waiting for a target.
    private var leaderIsArmed: Bool {
        emphasis.armedSource == .leader
    }

    /// The Leader answers a tap as its own ability picker or as an attack
    /// target. It is otherwise inert — a tap still puts it in the reader.
    private var leaderIsInteractive: Bool {
        leaderHasReadyAbility || leaderIsArmed || emphasis.leaderIsTarget
    }

    /// A target ring beats an "ability ready" ring: being attacked is the more
    /// urgent thing to notice. A spent Leader keeps a ring, dimmed, so the card
    /// still reads as the control it was rather than as an ordinary card.
    private var leaderHighlight: Color? {
        if emphasis.leaderIsTarget { return Palette.negative }
        if leaderIsArmed { return Palette.accentMuted }
        if leaderHasReadyAbility { return Palette.accent }
        if leaderHasSpentAbility { return Palette.border }
        return nil
    }

    /// Marks a card in play that can activate a printed box right now.
    ///
    /// The warning form says the box is one the app will show and only partly
    /// resolve. That is the thing a player most needs to know before pressing
    /// it, and a board slot has no room for a sentence.
    private func abilityMark(isPartial: Bool) -> some View {
        HStack(spacing: 1) {
            Image(systemName: "sparkles")
            if isPartial {
                Image(systemName: "exclamationmark.triangle.fill")
            }
        }
        .font(.system(size: 7, weight: .bold))
        .foregroundStyle(Palette.textOnAccent)
        .padding(.horizontal, 3)
        .padding(.vertical, 2)
        .background(isPartial ? Palette.warning : Palette.accent, in: Capsule())
        .accessibilityHidden(true)
    }

    /// Says what the Leader's next activation costs, under the card.
    ///
    /// The price is the part a player has to know before pressing anything, and
    /// the printed text is one tap away in the picker — so this carries the
    /// price rather than an abbreviated rules line that would fit nowhere.
    @ViewBuilder
    private var abilityBadge: some View {
        if let text = emphasis.leaderAbilityNote {
            Text(text)
                .font(Typeface.label(layout.leaderWidth < 64 ? 8 : 10))
                .tracking(0.6)
                .textCase(.uppercase)
                .foregroundStyle(leaderHasReadyAbility ? Palette.textOnAccent : Palette.textSecondary)
                .multilineTextAlignment(.center)
                .lineLimit(3)
                .minimumScaleFactor(0.55)
                .padding(.horizontal, 3)
                .padding(.vertical, 3)
                .frame(maxWidth: .infinity)
                .background(
                    leaderHasReadyAbility ? Palette.accent : Palette.surface,
                    in: NotchedRectangle(notch: 5, corners: .diagonal)
                )
                .accessibilityHidden(true)
        }
    }

    private func leaderDescription(_ leader: Card) -> String {
        var parts = ["\(title) Leader", leader.name, "\(side.life) life"]
        if side.leaderIsRested { parts.append("rested") }

        if leaderIsArmed {
            parts.append("choosing a target for its ability")
        } else if let note = emphasis.leaderAbilityNote {
            parts.append(leaderHasReadyAbility ? "ability ready, \(note)" : note.lowercased())
        }

        if leader.hasUnimplementedRules {
            parts.append("prints rules the app does not fully apply")
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

    // MARK: Modifiers

    /// One temporary modifier, drawn as a chip on the body it belongs to.
    private struct ModifierChip: Identifiable {

        let id: String

        /// A glyph for a keyword. `nil` on a numeric chip.
        let symbol: String?

        /// The value combat will use and how far an ability moved it. `nil` on
        /// a keyword chip.
        let text: String?

        let tint: Color
    }

    /// Everything an ability did to a body that the printed face cannot show.
    ///
    /// Power and damage are drawn as the numbers combat will actually use, not
    /// as the numbers printed on the card; Rush and an attack ban are keywords
    /// with nothing printed anywhere. All of it expires with the turn, and a
    /// player who cannot see it cannot plan around it.
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

        if character.hasRush {
            chips.append(ModifierChip(id: "rush", symbol: "bolt.fill",
                                      text: nil, tint: Palette.accent))
        }
        if character.isBarredFromAttacking {
            chips.append(ModifierChip(id: "barred", symbol: "nosign",
                                      text: nil, tint: Palette.negative))
        }
        if character.powerBonus != 0 {
            chips.append(ModifierChip(
                id: "power",
                symbol: nil,
                text: "P\(character.effectivePower(of: card)) \(signed(character.powerBonus))",
                tint: character.powerBonus > 0 ? Palette.positive : Palette.negative
            ))
        }
        if character.damageBonus != 0 {
            chips.append(ModifierChip(
                id: "damage",
                symbol: nil,
                text: "D\(character.effectiveDamage(of: card)) \(signed(character.damageBonus))",
                tint: character.damageBonus > 0 ? Palette.positive : Palette.negative
            ))
        }
        return chips
    }

    private func modifierChip(_ chip: ModifierChip) -> some View {
        HStack(spacing: 1.5) {
            if let symbol = chip.symbol {
                Image(systemName: symbol)
                    .font(.system(size: 6.5, weight: .black))
            }
            if let text = chip.text {
                Text(text)
                    .font(Typeface.numeric(8, weight: .bold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
            }
        }
        .foregroundStyle(Palette.textOnAccent)
        .padding(.horizontal, 2.5)
        .padding(.vertical, 0.5)
        .background(chip.tint, in: RoundedRectangle(cornerRadius: 3))
    }

    private func signed(_ amount: Int) -> String {
        amount > 0 ? "+\(amount)" : "\(amount)"
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

    /// The one place a slot's ring colour is decided, so selection, attack,
    /// block and ability emphasis can never fight each other.
    ///
    /// Targeting comes first because it is the question the board is asking;
    /// an "ability ready" ring comes last because it is the only one that is
    /// not about a decision already in progress.
    private func highlight(for character: CharacterInPlay) -> Color? {
        if emphasis.selected == character.id { return Palette.accent }
        if emphasis.abilityTargets.contains(character.id) { return Palette.warning }
        if emphasis.armedSource == .character(character.id) { return Palette.accentMuted }
        if emphasis.isTargeting { return nil }
        if emphasis.blockers, character.isReady { return Palette.positive }
        if emphasis.attackers, character.canAttack { return Palette.accentMuted }
        if emphasis.targets { return Palette.negative }
        if emphasis.readyAbilities.contains(.character(character.id)) { return Palette.accent }
        return nil
    }

    /// Anything an armed ability cannot legally be pointed at steps back, so
    /// the legal targets are the only lit cards on the mat. The card asking the
    /// question stays where it is, so the player can see what they chose.
    private func isPushedBack(_ character: CharacterInPlay) -> Bool {
        guard emphasis.isTargeting else { return false }
        if emphasis.armedSource == .character(character.id) { return false }
        return !emphasis.abilityTargets.contains(character.id)
    }

    private func description(of character: CharacterInPlay, card: Card?) -> String {
        var parts = [card?.name ?? character.cardID]
        if let card {
            if card.power != nil { parts.append("power \(character.effectivePower(of: card))") }
            if character.powerBonus != 0 {
                parts.append("\(signed(character.powerBonus)) power this turn")
            }
            if card.damage != nil { parts.append("damage \(character.effectiveDamage(of: card))") }
            if character.damageBonus != 0 {
                parts.append("\(signed(character.damageBonus)) damage this turn")
            }
            parts.append("health \(character.remainingHealth(of: card))")
        }
        parts.append(character.isRested ? "rested" : "ready")
        if character.summonedThisTurn { parts.append("summoned this turn") }
        if character.hasRush { parts.append("has Rush") }
        if character.isBarredFromAttacking { parts.append("cannot attack this turn") }

        let source = AbilitySource.character(character.id)
        if emphasis.armedSource == source {
            parts.append("choosing a target for its ability")
        } else if emphasis.readyAbilities.contains(source) {
            parts.append("ability ready")
        } else if emphasis.spentAbilities.contains(source) {
            parts.append("ability used this turn")
        }
        if emphasis.abilityTargets.contains(character.id) {
            parts.append("legal target for the chosen ability")
        }
        if card?.hasUnimplementedRules == true {
            parts.append("prints rules the app does not fully apply")
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
            attackers: true,
            readyAbilities: [.leader],
            leaderAbilityNote: "Activate: Main — 1 chakra"
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
        emphasis: BoardEmphasis(
            spentAbilities: [.leader],
            leaderAbilityNote: "Used this turn"
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
