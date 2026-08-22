//
//  GameAction.swift
//  NTCGSimulator
//
//  Everything a player is allowed to attempt, and every reason the engine can
//  turn an attempt down. The UI and the AI both speak to the engine in these
//  terms — nothing else is allowed to touch the board.
//

import Foundation

// MARK: - Attack target

/// What an attack was declared against, before any block is announced.
enum AttackTarget: Hashable, Codable {
    /// The defending Leader — the only target that costs life.
    case leader

    /// A specific enemy character, addressed by its in-play identity.
    case character(UUID)

    /// The targeted character, when the attack was not aimed at the Leader.
    var characterID: UUID? {
        if case .character(let id) = self { return id }
        return nil
    }

    /// Short label for confirmation prompts.
    var title: String {
        switch self {
        case .leader:    return "Leader"
        case .character: return "Character"
        }
    }
}

// MARK: - Ability source

/// Which card an activation is addressed to.
///
/// A side only ever has one Leader, so a Leader is named by its role rather
/// than by an in-play identity it does not have. Everything else on the board
/// that prints an ability is a body in the Characters row, addressed by the
/// identity it was given when it arrived.
enum AbilitySource: Hashable, Codable {

    /// The activating player's own Leader.
    case leader

    /// A body in the activating player's Characters row.
    case character(UUID)

    /// The in-play identity, when the source is a body on the board.
    var characterID: UUID? {
        if case .character(let id) = self { return id }
        return nil
    }

    /// Short label for confirmation prompts and the log.
    var title: String {
        switch self {
        case .leader:    return "Leader"
        case .character: return "Character"
        }
    }

    /// Stable key used to build `GameAction.id`.
    var key: String {
        switch self {
        case .leader:            return "leader"
        case .character(let id): return id.uuidString
        }
    }
}

// MARK: - Action

/// One player decision. `GameEngine.apply(_:by:)` is the only way a decision
/// reaches the board, and it validates before it mutates.
enum GameAction: Hashable, Codable, Identifiable {

    /// Answer the opening mulligan: `true` shuffles back and draws five new.
    case mulligan(Bool)

    /// Play the card at `handIndex`. `asJutsu` uses the card's support line and
    /// sends it to the Trash instead of summoning it as a body.
    case playCard(handIndex: Int, asJutsu: Bool)

    /// Declare an attack with one of your ready characters.
    case attack(attackerID: UUID, target: AttackTarget)

    /// Answer a declared attack. `nil` takes the attack unblocked.
    case declareBlock(blockerID: UUID?)

    /// Activate one printed ability box on a card you control.
    ///
    /// `abilityIndex` is the box's position in the card's printed order, so the
    /// same card can offer several activations at once. `targetID` names the
    /// card the ability acts on, when its scope asks the player to choose one.
    case useAbility(source: AbilitySource, abilityIndex: Int, targetID: UUID?)

    /// Move from main to attack, or from attack to end.
    case endPhase

    /// Finish the turn from any phase and pass to the other player.
    case endTurn

    /// Give the game to the other player.
    case concede

    /// Stable identity so lists of legal actions can be rendered directly.
    var id: String {
        switch self {
        case .mulligan(let redraw):
            return "mulligan-\(redraw)"
        case .playCard(let index, let asJutsu):
            return "play-\(index)-\(asJutsu)"
        case .attack(let attacker, let target):
            return "attack-\(attacker.uuidString)-\(target.characterID?.uuidString ?? "leader")"
        case .declareBlock(let blocker):
            return "block-\(blocker?.uuidString ?? "none")"
        case .useAbility(let source, let index, let target):
            return "ability-\(source.key)-\(index)-\(target?.uuidString ?? "none")"
        case .endPhase:
            return "end-phase"
        case .endTurn:
            return "end-turn"
        case .concede:
            return "concede"
        }
    }

    /// Short, user-readable label. The board decorates it with card names where
    /// it has them; the engine deliberately knows nothing about card art.
    var title: String {
        switch self {
        case .mulligan(let redraw):
            return redraw ? "Take a mulligan" : "Keep this hand"
        case .playCard(_, let asJutsu):
            return asJutsu ? "Play as a jutsu" : "Play card"
        case .attack(_, let target):
            return target == .leader ? "Attack the Leader" : "Attack a character"
        case .declareBlock(let blocker):
            return blocker == nil ? "Take it on the Leader" : "Block"
        case .useAbility(let source, _, _):
            return source == .leader ? "Use Leader ability" : "Use character ability"
        case .endPhase:
            return "End phase"
        case .endTurn:
            return "End turn"
        case .concede:
            return "Concede"
        }
    }
}

// MARK: - Errors

/// Every reason the engine rejects an action. Each case carries copy that is
/// safe to show the player as-is.
enum GameError: Error, Hashable, LocalizedError {

    /// The game has already been decided.
    case gameOver

    /// It is the other player's turn.
    case notYourTurn

    /// The action is not available in the phase the turn is currently in.
    case wrongPhase(GamePhase)

    /// Both opening hands must be settled before the first turn begins.
    case awaitingMulligan

    /// The one mulligan has already been taken or declined.
    case mulliganUnavailable

    /// No card sits at that position in hand.
    case invalidHandIndex

    /// The card number is not in the active pool.
    case unknownCard(String)

    /// Not enough ready Chakra to pay the cost.
    case notEnoughChakra(required: Int, available: Int)

    /// The Characters row already holds the maximum number of bodies.
    case charactersRowFull

    /// Only one EX Character may be in play at a time.
    case exCharacterAlreadyInPlay

    /// The Summon zone already holds a card.
    case summonZoneOccupied

    /// Every Support slot is occupied.
    case supportRowFull

    /// Leaders and Chakra cards are never played from hand.
    case notPlayableFromHand(String)

    /// The card has no support line, so it cannot be played as a jutsu.
    case noSupportLine(String)

    /// The chosen attacker is rested, newly summoned, or not in play.
    case attackerUnavailable

    /// The chosen target is not on the defending board.
    case invalidTarget

    /// There is no declared attack to answer.
    case noAttackPending

    /// An attack is waiting on a block decision and must be settled first.
    case attackAlreadyPending

    /// The chosen blocker is rested or not in play.
    case blockerUnavailable

    /// The card that would use the ability has left the board, or was never on
    /// the activating player's side of it.
    case abilitySourceNotInPlay

    /// The card does not print an ability box at that position.
    case noSuchAbility(String)

    /// The ability resolves by itself — a passive rule, or a trigger the engine
    /// fires — so there is nothing for the player to press.
    case abilityNotActivated(String)

    /// A "Once Per Turn" ability has already been used by this card this turn.
    case abilityAlreadyUsed(String)

    /// The cost asks for more of your own Characters than you have that can
    /// legally pay it.
    case notEnoughCharactersToTrash(required: Int, available: Int)

    /// The card prints Summon Requirements, so it never reaches the board by
    /// being summoned normally.
    case cannotBeSummonedNormally(String)

    /// The ability needs a target and none was supplied, or the one supplied
    /// is not legal for the ability's scope.
    case abilityNeedsTarget

    /// Sentence shown to the player when their tap is refused.
    var message: String {
        switch self {
        case .gameOver:
            return "This game has already finished."
        case .notYourTurn:
            return "It is not your turn."
        case .wrongPhase(let phase):
            return "You cannot do that during the \(phase.title.lowercased()) phase."
        case .awaitingMulligan:
            return "Both players must settle their opening hand first."
        case .mulliganUnavailable:
            return "You have already answered the mulligan."
        case .invalidHandIndex:
            return "That card is no longer in your hand."
        case .unknownCard(let cardID):
            return "Card \(cardID) is missing from the card pool."
        case .notEnoughChakra(let required, let available):
            return "That costs \(required) chakra and you have \(available) ready."
        case .charactersRowFull:
            return "Your Characters row is full."
        case .exCharacterAlreadyInPlay:
            return "You may only have one EX Character in play."
        case .summonZoneOccupied:
            return "Your Summon zone is already occupied."
        case .supportRowFull:
            return "All five of your Support slots are full."
        case .notPlayableFromHand(let name):
            return "\(name) cannot be played from your hand."
        case .noSupportLine(let name):
            return "\(name) has no support line to play as a jutsu."
        case .attackerUnavailable:
            return "That character cannot attack right now."
        case .invalidTarget:
            return "That is not a legal target."
        case .noAttackPending:
            return "There is no attack to answer."
        case .attackAlreadyPending:
            return "Settle the declared attack first."
        case .blockerUnavailable:
            return "That character cannot block right now."
        case .abilitySourceNotInPlay:
            return "That card is not in play on your side of the board."
        case .noSuchAbility(let name):
            return "\(name) does not print that ability."
        case .abilityNotActivated(let name):
            return "That \(name) ability resolves on its own — there is nothing to press."
        case .abilityAlreadyUsed(let name):
            return "\(name) has already used that ability this turn."
        case .notEnoughCharactersToTrash(let required, let available):
            let bodies = required == 1 ? "character" : "characters"
            return "That costs \(required) of your own \(bodies) and only \(available) can pay it."
        case .cannotBeSummonedNormally(let name):
            return "\(name) cannot be summoned normally — it has Summon Requirements."
        case .abilityNeedsTarget:
            return "Choose a card for that ability."
        }
    }

    var errorDescription: String? { message }
}
