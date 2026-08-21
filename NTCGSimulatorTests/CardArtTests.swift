//
//  CardArtTests.swift
//  NTCGSimulatorTests
//
//  Covers filename-to-card matching. This is the rule that decides whether a
//  folder of imported images lands on the right cards, and it is forgiving by
//  design — so it needs to be pinned down.
//

import Testing
import Foundation
@testable import NTCGSimulator

@Suite("Card art filename matching")
struct CardArtMatchingTests {

    /// A store instance is enough to reach the matching rules; none of these
    /// tests touch the filesystem.
    private let store = CardArtStore()

    /// The pool a real import would build: normalised id -> canonical id.
    private var pool: [String: String] {
        let ids = ["N-001", "N-004", "N-104", "K-039", "C-001", "CP-001", "S-001"]
        return Dictionary(ids.map { (store.normalize($0), $0) },
                          uniquingKeysWith: { first, _ in first })
    }

    // MARK: Normalisation

    @Test("Separators and case are ignored when comparing names",
          arguments: ["N-004", "n-004", "N_004", "n 004", "N004", "  N-004  "])
    func normalisationIsForgiving(spelling: String) {
        #expect(store.normalize(spelling) == "N004")
    }

    @Test("Normalisation keeps letters and digits only")
    func normalisationStripsPunctuation() {
        #expect(store.normalize("CP-001") == "CP001")
        #expect(store.normalize("!!!") == "")
    }

    // MARK: Matching

    @Test("A filename matching a card exactly resolves to it",
          arguments: ["N-004.png", "n-004.PNG", "N_004.jpg", "N004.heic"])
    func exactNamesMatch(filename: String) {
        #expect(store.matchCardID(filename: filename, in: pool) == "N-004")
    }

    @Test("A decorated filename still resolves to its card",
          arguments: ["N-004_alt.png", "N-004-full-art.jpg", "N-004 v2.png"])
    func decoratedNamesMatch(filename: String) {
        #expect(store.matchCardID(filename: filename, in: pool) == "N-004")
    }

    @Test("The longest matching id wins, so a similar shorter id cannot steal a file")
    func longestPrefixWins() {
        // "N104" starts with "N1"-style prefixes; it must not resolve to N-001.
        #expect(store.matchCardID(filename: "N-104.png", in: pool) == "N-104")
        #expect(store.matchCardID(filename: "CP-001.png", in: pool) == "CP-001")
    }

    @Test("A filename matching nothing is reported rather than guessed at")
    func unmatchedNamesReturnNil() {
        #expect(store.matchCardID(filename: "random-picture.png", in: pool) == nil)
        #expect(store.matchCardID(filename: "untitled.jpg", in: pool) == nil)
    }

    @Test("The file extension never affects which card is chosen")
    func extensionIsIgnored() {
        for ext in ["png", "jpg", "jpeg", "heic", "webp"] {
            #expect(store.matchCardID(filename: "K-039.\(ext)", in: pool) == "K-039")
        }
    }

    // MARK: Pool integration

    @Test("Every card in the shipped pool can be targeted by a plain filename")
    func shippedPoolIsAddressable() {
        let database = CardDatabase()
        let livePool = Dictionary(
            database.cards.map { (store.normalize($0.id), $0.id) },
            uniquingKeysWith: { first, _ in first }
        )

        for card in database.cards {
            let filename = "\(card.id).png"
            #expect(store.matchCardID(filename: filename, in: livePool) == card.id,
                    "\(card.id) could not be matched by its own filename")
        }
    }

    @Test("No two cards in the shipped pool collapse to the same filename key")
    func shippedPoolHasNoCollisions() {
        let database = CardDatabase()
        var seen: [String: String] = [:]

        for card in database.cards {
            let key = store.normalize(card.id)
            if let clash = seen[key] {
                Issue.record("\(card.id) and \(clash) both normalise to \(key)")
            }
            seen[key] = card.id
        }
    }
}
