//
//  HologramGeometryTests.swift
//  NTCGSimulatorTests
//
//  Covers the pure geometry that keeps holograms off the game state: the
//  clamp that leans a projection inside its region, the fit that shrinks and
//  sinks it under the chrome above its card, and the board's derivation of
//  each side's region from the rects the layout publishes. All of it was
//  written after two placement bugs observed on a device — planes standing on
//  the status strip and labels, and the Summon marker's plane parked two rows
//  from its card — so these tests pin the exact behaviours that fixed them.
//

import Testing
import Foundation
import CoreGraphics
@testable import NTCGSimulator

// MARK: - Clamp

@Suite("Hologram clamp")
struct HologramClampTests {

    private let region = CGRect(x: 10, y: 10, width: 380, height: 700)
    private let size = CGSize(width: 100, height: 150)

    @Test("A point that already fits is returned untouched")
    func passthrough() {
        let point = HologramProjection.clamped(x: 200, y: 400, size: size, within: region)
        #expect(point == CGPoint(x: 200, y: 400))
    }

    @Test("A composition hanging over an edge is pulled back inside")
    func clampsAtEdges() {
        let low = HologramProjection.clamped(x: 0, y: 0, size: size, within: region)
        #expect(low == CGPoint(x: 60, y: 85))

        let high = HologramProjection.clamped(x: 500, y: 900, size: size, within: region)
        #expect(high == CGPoint(x: 340, y: 635))
    }

    @Test("The infinite region is the do-not-clamp sentinel")
    func infiniteRegionPassesThrough() {
        let point = HologramProjection.clamped(x: -50, y: 9999, size: size, within: .infinite)
        #expect(point == CGPoint(x: -50, y: 9999))
    }

    @Test("A region smaller than the composition centres it instead of oscillating")
    func degenerateRegionCentres() {
        let tiny = CGRect(x: 100, y: 100, width: 40, height: 40)
        let point = HologramProjection.clamped(x: 0, y: 0, size: size, within: tiny)
        // Lower bound above upper bound on both axes: the midpoint of the two.
        #expect(point == CGPoint(x: 120, y: 120))
    }

    @Test("A null or empty region clamps nothing")
    func nullRegionPassesThrough() {
        let point = HologramProjection.clamped(x: 33, y: 44, size: size, within: .null)
        #expect(point == CGPoint(x: 33, y: 44))
        let empty = HologramProjection.clamped(x: 33, y: 44, size: size, within: .zero)
        #expect(empty == CGPoint(x: 33, y: 44))
    }
}

// MARK: - Fit

@Suite("Hologram region fit")
struct HologramFitTests {

    /// A slot-sized card, the shape the board actually publishes.
    private let card = CGRect(x: 63, y: 447, width: 46, height: 65)

    /// The rise the projection wants above the card at scale one.
    private var rise: CGFloat {
        HologramProjection.riseHeight(forAnchor: card, scale: 1)
    }

    @Test("The rise is linear in scale, so the fit's closed form is exact")
    func riseIsLinear() {
        let atOne = HologramProjection.riseHeight(forAnchor: card, scale: 1)
        let atHalf = HologramProjection.riseHeight(forAnchor: card, scale: 0.5)
        #expect(abs(atHalf * 2 - atOne) < 0.0001)
    }

    @Test("A region with generous headroom never touches the projection")
    func freeWhenRoomy() {
        let region = CGRect(x: 0, y: 0, width: 400, height: 600)
        let fit = HologramProjection.fit(forAnchor: card, perspectiveScale: 1, within: region)
        #expect(fit == .free)
    }

    @Test("The infinite region constrains nothing")
    func freeWhenInfinite() {
        let fit = HologramProjection.fit(forAnchor: card, perspectiveScale: 1, within: .infinite)
        #expect(fit == .free)
    }

    @Test("A degenerate region constrains nothing, matching the clamp")
    func freeWhenDegenerate() {
        #expect(HologramProjection.fit(forAnchor: card, perspectiveScale: 1, within: .null) == .free)
        #expect(HologramProjection.fit(forAnchor: card, perspectiveScale: 1, within: .zero) == .free)
    }

    @Test("Slightly short headroom sinks the beam before it shrinks the plane")
    func partialRoomSinksFirst()  {
        // Headroom a few points short of the full rise: the whole shortfall
        // fits inside the sink allowance, so the plane keeps its size.
        let bob = HologramMetrics.bobAmplitude
        let region = CGRect(x: 0, y: card.minY - rise - bob + 8, width: 400, height: 600)
        let fit = HologramProjection.fit(forAnchor: card, perspectiveScale: 1, within: region)
        #expect(fit.scale == 1)
        #expect(abs(fit.sink - 8) < 0.0001)
    }

    @Test("A hard ceiling shrinks the plane and caps the sink at the art panel")
    func hardCeilingShrinksAndCapsSink() {
        // The region's top sits at half the rise above the card.
        let region = CGRect(x: 0, y: card.minY - rise / 2, width: 400, height: 600)
        let fit = HologramProjection.fit(forAnchor: card, perspectiveScale: 1, within: region)
        let maxSink = card.height * HologramMetrics.coneBaseYFactor

        #expect(fit.scale < 1)
        #expect(fit.sink <= maxSink + 0.0001)

        // The invariant the whole mechanism exists for: the fitted plane's
        // top edge stays at or below the region's top, bob included.
        let planeTop = card.minY + fit.sink - rise * fit.scale
        #expect(planeTop >= region.minY + HologramMetrics.bobAmplitude - 0.0001)
    }

    @Test("No budget at all refuses to render rather than covering the chrome")
    func noBudgetSuppresses() {
        // The region starts below the card's art panel: even a full sink
        // cannot buy any room.
        let region = CGRect(x: 0, y: card.minY + card.height, width: 400, height: 600)
        let fit = HologramProjection.fit(forAnchor: card, perspectiveScale: 1, within: region)
        #expect(fit.scale == 0)
        #expect(fit.scale < HologramMetrics.minFitScale)
    }

    @Test("The near-character squeeze measured on a phone renders, shrunk and sunk",
          arguments: [CGFloat(0.8), 1.0])
    func phoneSqueezeSurvives(scale: CGFloat) {
        // The shape of the real bug: roughly eighteen points of air between
        // the card row and the status band, at the perspective scales the
        // near row actually takes. The projection must neither cover the
        // band nor vanish.
        let region = CGRect(x: 0, y: card.minY - 18, width: 400, height: 600)
        let fit = HologramProjection.fit(forAnchor: card, perspectiveScale: scale, within: region)

        #expect(fit.scale >= HologramMetrics.minFitScale)
        let fittedRise = HologramProjection.riseHeight(forAnchor: card, scale: scale * fit.scale)
        let planeTop = card.minY + fit.sink - fittedRise
        #expect(planeTop >= region.minY - 0.0001)
    }
}

// MARK: - Region derivation

@Suite("Board hologram regions")
struct BoardHologramRegionTests {

    private let rows = CGRect(x: 59, y: 305, width: 257, height: 208)
    private let band = CGRect(x: 8, y: 223, width: 386, height: 66)

    @Test("No rows published, no region — the candidate simply does not cast")
    func nilRowsMeansNoRegion() {
        #expect(BoardHologramRegion.region(rows: nil, statusBand: band, isNear: true) == nil)
    }

    @Test("Without a band to measure against, the rows are the whole region")
    func rowsAloneAreTheRegion() {
        let region = BoardHologramRegion.region(rows: rows, statusBand: nil, isNear: true)
        #expect(region == rows)
    }

    @Test("The near half may rise only to the band's bottom edge")
    func nearStopsAtBandBottom() {
        let region = BoardHologramRegion.region(rows: rows, statusBand: band, isNear: true)
        #expect(region?.minY == band.maxY + BoardHologramRegion.bandClearance)
        #expect(region?.maxY == rows.maxY)
        #expect(region?.minX == rows.minX)
        #expect(region?.maxX == rows.maxX)
    }

    @Test("The far half may fall only to the band's top edge")
    func farStopsAtBandTop() {
        let farRows = CGRect(x: 59, y: 8, width: 257, height: 200)
        let region = BoardHologramRegion.region(rows: farRows, statusBand: band, isNear: false)
        // Upward it may use the overlay's own top: the overlay already
        // excludes the safe areas, so zero is chrome-free.
        #expect(region?.minY == 0)
        #expect(region?.maxY == band.minY - BoardHologramRegion.bandClearance)
        #expect(region?.minX == farRows.minX)
        #expect(region?.maxX == farRows.maxX)
    }

    @Test("A band overlapping the rows never inverts the region")
    func overlappingBandKeepsRowsBounds() {
        let touching = CGRect(x: 8, y: 250, width: 386, height: 80)
        let near = BoardHologramRegion.region(rows: rows, statusBand: touching, isNear: true)
        #expect(near?.minY == rows.minY)

        let farRows = CGRect(x: 59, y: 8, width: 257, height: 260)
        let far = BoardHologramRegion.region(rows: farRows, statusBand: touching, isNear: false)
        #expect(far?.maxY == farRows.maxY)
    }
}

// MARK: - Perspective sanity

@Suite("Hologram perspective")
struct HologramPerspectiveTests {

    @Test("Scale is clamped to the range the metrics promise")
    func scaleStaysClamped() {
        let stage = CGSize(width: 402, height: 778)
        for y in stride(from: CGFloat(0), through: stage.height, by: 50) {
            let rect = CGRect(x: 100, y: y, width: 46, height: 65)
            let scale = HologramPerspective.relativeScale(forAnchor: rect, in: stage)
            #expect(scale >= HologramMetrics.minScale)
            #expect(scale <= HologramMetrics.maxScale)
        }
    }

    @Test("Lower on the stage is nearer the camera, so never smaller")
    func scaleGrowsDownScreen() {
        let stage = CGSize(width: 402, height: 778)
        var previous: CGFloat = 0
        for y in stride(from: CGFloat(0), through: stage.height, by: 50) {
            let rect = CGRect(x: 100, y: y, width: 46, height: 65)
            let scale = HologramPerspective.relativeScale(forAnchor: rect, in: stage)
            #expect(scale >= previous)
            previous = scale
        }
    }
}
