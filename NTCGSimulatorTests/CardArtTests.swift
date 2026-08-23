//
//  CardArtTests.swift
//  NTCGSimulatorTests
//
//  Guards the bundled artwork.
//
//  Art ships inside the app so every install looks identical. That guarantee is
//  only worth having if it is checked: a card whose file is missing, misnamed or
//  silently dropped from the bundle would fall back to a blank face on some
//  screens and nowhere else. These tests fail loudly instead.
//

import Testing
import Foundation
import UIKit
@testable import NTCGSimulator

@Suite("Bundled card art")
struct BundledCardArtTests {

    private let store = CardArtStore()
    private let database = CardDatabase()

    // MARK: Name matching

    @Test("Separators and case are ignored when matching a card id",
          arguments: ["N-004", "n-004", "N_004", "n 004", "N004", "  N-004  "])
    func normalisationIsForgiving(spelling: String) {
        #expect(store.normalize(spelling) == "N004")
    }

    @Test("Normalisation keeps letters and digits only")
    func normalisationStripsPunctuation() {
        #expect(store.normalize("CP-001") == "CP001")
        #expect(store.normalize("SMP-15") == "SMP15")
        #expect(store.normalize("!!!") == "")
    }

    // MARK: The uniformity guarantee

    @Test("The bundle carries artwork")
    func bundleIsNotEmpty() {
        #expect(store.installedCount > 0,
                "no artwork reached the app bundle — every card would render a generated face")
    }

    @Test("EVERY card in the shipped pool has bundled artwork")
    func everyCardHasArt() {
        // Reported one card per line rather than as an #expect message: the
        // failing ids are the whole diagnostic, and Swift Testing's message
        // parameter takes a literal, not a string built at runtime.
        for card in database.cards where !store.hasArt(forCardID: card.id) {
            Issue.record("\(card.id) \(card.name) has no bundled artwork")
        }
        #expect(database.cards.allSatisfy { store.hasArt(forCardID: $0.id) })
    }

    @Test("Artwork actually decodes, not just resolves to a path")
    func artworkDecodes() throws {
        let card = try #require(database.cards.first)
        let image = try #require(database.artwork(for: card))
        #expect(image.size.width > 0 && image.size.height > 0)
    }

    @Test("Downsampling returns a smaller image than the full decode")
    func downsamplingShrinks() throws {
        let card = try #require(database.cards.first { store.hasArt(forCardID: $0.id) })
        let full = try #require(database.artwork(for: card))
        let small = try #require(database.artwork(for: card, maxPixelSize: 120))
        #expect(max(small.size.width, small.size.height) <= max(full.size.width, full.size.height))
    }

    // MARK: Data integrity

    @Test("No two cards collapse to the same artwork key")
    func noFilenameCollisions() {
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
