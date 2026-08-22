//
//  GameAction.swift
//  NTCGSimulator
//
//  Everything a player is allowed to attempt — the reference engine's full
//  input alphabet — and every reason the engine can turn an attempt down. The
//  UI and the AI both speak to the engine in these terms; nothing else is
//  allowed to touch the board.
//

import Foundation

// MARK: - Attack target

/// What an attack is declared against. The enemy Leader is always legal; an
/// enemy character only while it is rested — there is no blocking and no
/// taunt, so going face is always allowed.
enum AttackTarget: Hashable, Codable {
    /// The defending Leader — the only target that costs life.
    case leader

    /// A rested enemy character, addressed by its in-play identity.
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

// MARK: - Play mode

/// The three things a card in hand can be used for.
///
/// Support is a *mode*, not a card type: a card printing a SUPPORT bar may be
/// set face-down instead of being summoned, or — on your own turn only —
/// activated straight from hand through a free slot. The same card can still
/// be summoned as a body.
enum CardPlayMode: String, Codable, Hashable, CaseIterable, Identifiable {

    /// Onto the Characters row. One normal summon per turn; EX Characters pay
    /// their printed Summon Requirements instead, without limit.
    case summon

    /// Face-down into a numbered Support slot. Free, unlimited, and it opens
    /// no response window.
    case setAsSupport

    /// Activate the card's Support line from hand: it transits through a free
    /// slot, pays its chakra, and goes on the chain. Active player only.
    case jutsu

    var id: String { rawValue }

    /// Label for the action panel.
    var title: String {
        switch self {
        case .summon:       return "Summon"
        case .setAsSupport: return "Set as support"
        case .jutsu:        return "Activate support"
        }
    }
}

// MARK: - Action

/// One player decision. `GameEngine.apply(_:by:)` is the only way a decision
/// reaches the board, and it validates before it mutates.
enum GameAction: Hashable, Codable, Identifiable {

    /// Answer the opening mulligan — second player only. `keep: false` puts
    /// the hand back, reshuffles the whole deck and draws five new.
    case mulligan(keep: Bool)

    /// Summon the card at `handIndex`: the turn's one normal summon for a
    /// character, or the Summon Requirements path for an EX Character.
    case summon(handIndex: Int)

    /// Set the card at `handIndex` face-down into the first free Support
    /// slot. Free, uncapped, no window.
    case setSupport(handIndex: Int)

    /// Activate the face-down Support in `slotIndex`, paying its chakra and
    /// pushing it onto the chain.
    case activateSupport(slotIndex: Int)

    /// Activate a Support straight from hand — active player only; the card
    /// transits through a free slot.
    case activateSupportFromHand(handIndex: Int)

    /// Use a character's printed Activate: Main — Ino's team boost.
    case activateCharacter(UUID)

    /// Use the Leader's printed Activate: Main. Does not rest the Leader.
    case leaderEffect

    /// Rest the Leader and turn every chakra face-up. From game turn 2, on
    /// your own turn, while the Leader stands and no chakra lock bites.
    case recovery

    /// Declare an attack with the Leader or one of your characters, at the
    /// enemy Leader or a rested enemy character.
    case declareAttack(attacker: AttackerReference, target: AttackTarget)

    /// Decline to answer the open counter window. Two passes in a row — or
    /// one against an empty chain — resolve it.
    case passCounter

    /// Answer the open prompt with the chosen option keys. Empty keys cancel
    /// a cancellable prompt.
    case resolveChoice(keys: [String])

    /// Finish the turn and pass to the other player.
    case endTurn

    /// Give the game to the other player. The reference engine has no concede
    /// of its own — quitting lives outside its reducer — so this is the app's
    /// offline stand-in. /// UNSURE how the reference reports an online concede.
    case concede

    /// Stable identity so lists of legal actions can be rendered directly.
    var id: String {
        switch self {
        case .mulligan(let keep):
            return "mulligan-\(keep)"
        case .summon(let index):
            return "summon-\(index)"
        case .setSupport(let index):
            return "set-\(index)"
        case .activateSupport(let slotIndex):
            return "activate-slot-\(slotIndex)"
        case .activateSupportFromHand(let index):
            return "activate-hand-\(index)"
        case .activateCharacter(let id):
            return "activate-character-\(id.uuidString)"
        case .leaderEffect:
            return "leader-effect"
        case .recovery:
            return "recovery"
        case .declareAttack(let attacker, let target):
            let who = attacker.characterID?.uuidString ?? "leader"
            let what = target.characterID?.uuidString ?? "leader"
            return "attack-\(who)-\(what)"
        case .passCounter:
            return "pass"
        case .resolveChoice(let keys):
            return "choice-\(keys.joined(separator: ","))"
        case .endTurn:
            return "end-turn"
        case .concede:
            return "concede"
        }
    }

    /// Short, user-readable label. The board decorates it with card names
    /// where it has them; the engine deliberately knows nothing about art.
    var title: String {
        switch self {
        case .mulligan(let keep):
            return keep ? "Keep this hand" : "Take a mulligan"
        case .summon:
            return "Summon"
        case .setSupport:
            return "Set as support"
        case .activateSupport(let slotIndex):
            return "Activate support slot \(slotIndex + 1)"
        case .activateSupportFromHand:
            return "Activate support from hand"
        case .activateCharacter:
            return "Use character ability"
        case .leaderEffect:
            return "Use Leader ability"
        case .recovery:
            return "Recovery"
        case .declareAttack(let attacker, let target):
            let who = attacker == .leader ? "Leader attacks" : "Attack"
            return target == .leader ? "\(who) the Leader" : "\(who) a character"
        case .passCounter:
            return "Pass"
        case .resolveChoice(let keys):
            return keys.isEmpty ? "Cancel" : "Choose"
        case .endTurn:
            return "End turn"
        case .concede:
            return "Concede"
        }
    }
}

// MARK: - Errors

/// Every reason the engine rejects an action. The cases mirror the
/// reference's own block codes — `timing`, `noChakra`, `noSlot`, `noTarget`,
/// `alreadyUsed`, `conditionUnmet` for Supports; `tooEarly`, `rested`,
/// `summoningSickness`, `noAttackLeft`, `frozen` for attacks; `chakraLocked`
/// for Recovery — plus the engine-level guards around them. Each carries copy
/// that is safe to show the player as-is.
enum GameError: Error, Hashable, LocalizedError {

    /// The game has already been decided.
    case gameOver

    /// It is the other player's turn, or their priority.
    case notYourTurn

    /// The action is not available at this moment — the reference's `timing`.
    case wrongMoment

    /// A prompt is open and must be answered first.
    case choicePending

    /// The open prompt belongs to the other player.
    case notYourChoice

    /// The answer names keys the prompt does not offer, repeats one, or
    /// declines a prompt that cannot be declined.
    case invalidChoice

    /// Attacking and Recovery are barred this early — the reference's
    /// `tooEarly`: no attacks on game turn 1, no Recovery before turn 2.
    case tooEarly

    /// The attacker or Leader is rested — `rested`.
    case rested

    /// The character arrived this turn and has no Rush — `summoningSickness`.
    case summoningSickness

    /// The attacker has already used its attack this turn — `noAttackLeft`.
    case noAttackLeft

    /// A freeze is holding the attacker back — `frozen`.
    case frozen

    /// A chakra lock is blocking Recovery — `chakraLocked`.
    case chakraLocked

    /// The one normal summon has already been taken this turn.
    case summonAlreadyUsed

    /// This Support has already been activated — `alreadyUsed`.
    case alreadyUsed

    /// The action needs a target and no legal one exists — `noTarget`.
    case noValidTarget

    /// Not enough face-up chakra to pay the cost — `noChakra`.
    case noChakra(required: Int, available: Int)

    /// No free Support slot for a from-hand activation — `noSlot`.
    case noSlot

    /// A printed condition is not met — `conditionUnmet`: Ino without her
    /// team, a card with no Support half, an ability the card does not print.
    case conditionUnmet

    /// Both opening hands must be settled before the first turn begins.
    case awaitingMulligan

    /// The mulligan belongs to the second player, once.
    case mulliganUnavailable

    /// No card sits at that position in hand.
    case invalidHandIndex

    /// The card number is not in the active pool.
    case unknownCard(String)

    /// Leaders and Chakra cards are never played from hand.
    case notPlayableFromHand(String)

    /// The chosen target is not on the board, or not legal for this attack.
    case invalidTarget

    /// That Support slot holds no face-down card.
    case supportSlotEmpty(Int)

    /// The card's printed Summon Requirements cannot be paid.
    case summonRequirementUnpaid(String)

    /// There is no counter window open, or it is not yours to pass.
    case noCounterWindow

    /// Sentence shown to the player when their tap is refused. The first two
    /// quoted lines are the reference's own disabled-button copy.
    var message: String {
        switch self {
        case .gameOver:
            return "This game has already finished."
        case .notYourTurn:
            return "It is not your turn."
        case .wrongMoment:
            return "Wrong moment"
        case .noValidTarget:
            return "No valid target"
        case .choicePending:
            return "Answer the open prompt first."
        case .notYourChoice:
            return "That prompt is not yours to answer."
        case .invalidChoice:
            return "That is not one of the offered options."
        case .tooEarly:
            return "Not this early in the game."
        case .rested:
            return "That card is rested."
        case .summoningSickness:
            return "That character was summoned this turn and has no Rush."
        case .noAttackLeft:
            return "That card has already attacked this turn."
        case .frozen:
            return "That card cannot attack right now."
        case .chakraLocked:
            return "You cannot turn your chakra face-up right now."
        case .summonAlreadyUsed:
            return "Summon already used this turn"
        case .alreadyUsed:
            return "That has already been used."
        case .noChakra(let required, let available):
            return "That costs \(required) chakra and you have \(available) face-up."
        case .noSlot:
            return "No free Support slot."
        case .conditionUnmet:
            return "The card's condition is not met."
        case .awaitingMulligan:
            return "The opening hand must be settled first."
        case .mulliganUnavailable:
            return "The mulligan is not yours to take."
        case .invalidHandIndex:
            return "That card is no longer in your hand."
        case .unknownCard(let cardID):
            return "Card \(cardID) is missing from the card pool."
        case .notPlayableFromHand(let name):
            return "\(name) cannot be played from your hand."
        case .invalidTarget:
            return "That is not a legal target."
        case .supportSlotEmpty(let slotIndex):
            return "Support slot \(slotIndex + 1) is empty."
        case .summonRequirementUnpaid(let name):
            return "\(name) cannot pay its Summon Requirements."
        case .noCounterWindow:
            return "There is nothing to answer right now."
        }
    }

    var errorDescription: String? { message }
}
