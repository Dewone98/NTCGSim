//
//  BoardCard3DGeometryTests.swift
//  NTCGSimulatorTests
//
//  Pins the one property the 3D board cards live or die on: a slab lands
//  exactly on the slot the 2D layout drew for it.
//
//  That is not a cosmetic claim. Every badge, damage number, target ring and
//  tap target on the board is positioned from the slot's frame, so a slab
//  placed anywhere else would put the card under one rect and its stats,
//  highlight and touch target under another — a card the player can see but
//  cannot reliably hit. `BoardCard3DProjection` guarantees it by inverting
//  the stage camera rather than by tuning, and these tests check the
//  inversion by PROJECTING THE RESULT BACK independently: the helper below
//  re-derives the pinhole from `FieldStageMetrics` and pushes all four
//  corners of the placed slab through it, so a sign error in the production
//  maths cannot be reproduced by the test that is meant to catch it.
//
//  The second property covered here is uniform foreshortening. A card lying
//  dead flat on this mat projects to anything from its full height at the
//  near edge to a fifth of it at the top of the opponent's row, which is why
//  slabs are raked; the tests hold every card on the board to the same
//  `BoardCard3DMetrics.foreshortening` whatever row it sits in.
//

import Testing
import Foundation
import CoreGraphics
import simd
import SwiftUI
@testable import NTCGSimulator

// MARK: - Independent pinhole

/// The stage camera, re-derived from its published tokens, used to project
/// finished placements back to the screen.
///
/// Deliberately NOT a call into `StageCamera.project`: that only handles
/// points on the ground plane, and a raked slab has corners above and below
/// it. This is the general form of the same pinhole — world x lateral, y up
/// from the mat, f forward away from the reader.
private struct TestPinhole {

    let camera = StageCamera.standard
    let size: CGSize

    /// Focal length in screen points.
    var focal: CGFloat { size.height / 2 / camera.tanHalfFOV }

    func project(x: CGFloat, y: CGFloat, forward f: CGFloat) -> CGPoint {
        let depth = (camera.height - y) * camera.sinPitch + f * camera.cosPitch
        let vertical = (y - camera.height) * camera.cosPitch + f * camera.sinPitch
        return CGPoint(
            x: size.width / 2 + focal * x / depth,
            y: size.height / 2 - focal * vertical / depth
        )
    }

    // MARK: Slab geometry

    /// The slab's own axes in the scene's coordinates: yaw about the up axis
    /// first, then the lean about the lateral axis — the order
    /// `Card3DNode.apply` composes them in.
    private func axes(of placement: Card3DPlacement) -> (width: SIMD3<Double>, length: SIMD3<Double>) {
        func rotate(_ v: SIMD3<Double>) -> SIMD3<Double> {
            let cy = cos(placement.yaw.radians), sy = sin(placement.yaw.radians)
            let yawed = SIMD3(v.x * cy + v.z * sy, v.y, -v.x * sy + v.z * cy)
            let cl = cos(placement.lean.radians), sl = sin(placement.lean.radians)
            return SIMD3(yawed.x, yawed.y * cl - yawed.z * sl, yawed.y * sl + yawed.z * cl)
        }
        // A slab laid flat has its width along +x and its height running away
        // from the reader, which is -z in the scene's convention.
        return (rotate(SIMD3(1, 0, 0)), rotate(SIMD3(0, 0, -1)))
    }

    /// Projects a point offset from the slab's centre by scene-space `offset`.
    private func project(_ placement: Card3DPlacement, offset: SIMD3<Double>) -> CGPoint {
        let thickness = Card3DMetrics.localThickness * placement.width
        return project(
            x: placement.x + CGFloat(offset.x),
            y: thickness / 2 + CGFloat(offset.y),
            // The scene looks down -z, so the stage's forward distance is the
            // negated scene z.
            forward: placement.forward - CGFloat(offset.z)
        )
    }

    /// The centre of the slab, on screen.
    func centre(of placement: Card3DPlacement) -> CGPoint {
        project(placement, offset: .zero)
    }

    /// The slab's on-screen footprint, measured through its own centre lines
    /// rather than as a bounding box: the mid-line is what the 2D slot's
    /// width and height mean, and a bounding box would also carry the
    /// keystone the perspective is supposed to produce.
    func footprint(of placement: Card3DPlacement, isRested: Bool) -> CGSize {
        let axis = axes(of: placement)
        let halfWidth = Double(placement.width) / 2
        let halfLength = Double(placement.width / Metrics.cardAspect) / 2

        // A rested card is turned a quarter, so its LENGTH is the axis that
        // runs across the screen and its width is the one that recedes.
        let lateral = isRested ? axis.length : axis.width
        let receding = isRested ? axis.width : axis.length
        let halfLateral = isRested ? halfLength : halfWidth
        let halfReceding = isRested ? halfWidth : halfLength

        let left = project(placement, offset: lateral * -halfLateral)
        let right = project(placement, offset: lateral * halfLateral)
        let near = project(placement, offset: receding * -halfReceding)
        let far = project(placement, offset: receding * halfReceding)

        return CGSize(width: abs(right.x - left.x), height: abs(near.y - far.y))
    }
}

// MARK: - Fixtures

/// A card with nothing interesting on it: these tests are about where a slab
/// goes, never about what is printed on it.
private func testCard(_ id: String = "T-001") -> Card {
    Card(id: id, name: "Test Body", type: .character, color: .red,
         rarity: .common, setCode: "T1", cost: 1, power: 5, damage: 1, health: 4)
}

private func subject(
    id: String = "s",
    isRested: Bool = false,
    anchor: BoardCardAnchor = .character(UUID()),
    confined: Bool = true
) -> BoardCard3DSubject {
    BoardCard3DSubject(
        id: id,
        anchor: anchor,
        slot: .player,
        card: testCard(),
        isRested: isRested,
        isConfinedToRows: confined
    )
}

/// A phone-sized stage, and slot rects at the rows a compact board actually
/// puts them at: the opponent's three rows in the top third, the near
/// player's three in the band below the status strip.
private let phone = CGSize(width: 393, height: 852)

private func slot(atX x: CGFloat, y: CGFloat, width: CGFloat = 55) -> CGRect {
    CGRect(x: x - width / 2, y: y - width / Metrics.cardAspect / 2,
           width: width, height: width / Metrics.cardAspect)
}

/// Every row the board draws, top of the far side to the near player's
/// Chakra — the full span the placement maths has to hold over.
private let boardRows: [CGFloat] = [60, 140, 220, 470, 550, 630, 700]

// MARK: - Landing on the slot

@Suite("3D card placement lands on its slot")
struct BoardCard3DPlacementTests {

    @Test("A slab's centre projects back onto the centre of the slot it was placed from")
    func centreRoundTrip() throws {
        let pinhole = TestPinhole(size: phone)

        for y in boardRows {
            for x in [40.0, 196.5, 350.0] as [CGFloat] {
                let rect = slot(atX: x, y: y)
                let placement = try #require(
                    BoardCard3DProjection.placement(
                        for: subject(), rect: rect, stageSize: phone
                    )
                )
                let landed = pinhole.centre(of: placement)
                #expect(abs(landed.x - rect.midX) < 0.5)
                #expect(abs(landed.y - rect.midY) < 0.5)
            }
        }
    }

    @Test("A slab is exactly as wide on screen as the slot it stands in")
    func widthMatchesTheSlot() throws {
        let pinhole = TestPinhole(size: phone)

        for y in boardRows {
            let rect = slot(atX: 196.5, y: y)
            let placement = try #require(
                BoardCard3DProjection.placement(
                    for: subject(), rect: rect, stageSize: phone
                )
            )
            let size = pinhole.footprint(of: placement, isRested: false)
            #expect(abs(size.width - rect.width) < rect.width * 0.005)
        }
    }

    @Test("Every row foreshortens by the same rake, near edge to far")
    func foreshorteningIsUniform() throws {
        let pinhole = TestPinhole(size: phone)
        let expected = BoardCard3DMetrics.foreshortening

        for y in boardRows {
            let rect = slot(atX: 196.5, y: y)
            let placement = try #require(
                BoardCard3DProjection.placement(
                    for: subject(), rect: rect, stageSize: phone
                )
            )
            let size = pinhole.footprint(of: placement, isRested: false)
            let ratio = size.height / rect.height
            // A hair of second-order keystone over a finite card, and nothing
            // else: the whole point is that this number does not drift with
            // the row.
            #expect(abs(ratio - expected) < 0.02)
        }
    }

    @Test("A flat card would NOT be uniform — which is why the rake exists")
    func flatCardsCollapseAtTheFarRow() throws {
        // The regression this guards is the tempting simplification: drop the
        // rake and lay every slab on the mat. The opponent's rows would then
        // project to a fraction of their printed height. Measured here so the
        // reason for `lean` is in the suite rather than only in a comment.
        let pinhole = TestPinhole(size: phone)

        func flatHeightRatio(atY y: CGFloat) throws -> CGFloat {
            let rect = slot(atX: 196.5, y: y)
            var placement = try #require(
                BoardCard3DProjection.placement(
                    for: subject(), rect: rect, stageSize: phone
                )
            )
            placement.lean = .zero
            return pinhole.footprint(of: placement, isRested: false).height / rect.height
        }

        #expect(try flatHeightRatio(atY: 700) > 0.80)
        #expect(try flatHeightRatio(atY: 60) < 0.35)
    }

    @Test("Slots side by side do not overlap on screen")
    func neighboursStayApart() throws {
        let pinhole = TestPinhole(size: phone)
        let left = slot(atX: 120, y: 550)
        let right = slot(atX: 180, y: 550)

        let a = try #require(
            BoardCard3DProjection.placement(for: subject(), rect: left, stageSize: phone)
        )
        let b = try #require(
            BoardCard3DProjection.placement(for: subject(), rect: right, stageSize: phone)
        )
        let aRight = pinhole.centre(of: a).x + pinhole.footprint(of: a, isRested: false).width / 2
        let bLeft = pinhole.centre(of: b).x - pinhole.footprint(of: b, isRested: false).width / 2
        #expect(aRight <= bLeft + 0.5)
    }
}

// MARK: - Rested cards

@Suite("Rested 3D cards")
struct BoardCard3DRestedTests {

    @Test("A rested slab turns the same way the 2D mat turns a rested card")
    func yawMatchesTheMat() throws {
        let placement = try #require(
            BoardCard3DProjection.placement(
                for: subject(isRested: true), rect: slot(atX: 196.5, y: 550), stageSize: phone
            )
        )
        // The mat rests a card with `.rotationEffect(.degrees(90))`, which is
        // clockwise on screen. A positive yaw about the stage's up axis swings
        // the card's top edge the other way, so the placement must be negative.
        #expect(placement.yaw == .degrees(-90))
    }

    @Test("A rested slab fills exactly what the turned, scaled 2D card fills")
    func restedFootprintMatchesTheMat() throws {
        let pinhole = TestPinhole(size: phone)
        let rect = slot(atX: 196.5, y: 550)
        let placement = try #require(
            BoardCard3DProjection.placement(
                for: subject(isRested: true), rect: rect, stageSize: phone
            )
        )
        let size = pinhole.footprint(of: placement, isRested: true)

        // The mat turns the card a quarter and scales it by the card ratio, so
        // it occupies the slot's width by that same ratio of the width.
        #expect(abs(size.width - rect.width) < rect.width * 0.005)
        let expectedHeight = rect.width * Metrics.cardAspect * BoardCard3DMetrics.foreshortening
        #expect(abs(size.height - expectedHeight) < expectedHeight * 0.02)
    }

    @Test("A rested slab is the standing one scaled by the card ratio")
    func restedIsTheSameSlab() throws {
        let rect = slot(atX: 196.5, y: 550)
        let standing = try #require(
            BoardCard3DProjection.placement(for: subject(), rect: rect, stageSize: phone)
        )
        let rested = try #require(
            BoardCard3DProjection.placement(
                for: subject(isRested: true), rect: rect, stageSize: phone
            )
        )
        #expect(abs(rested.width - standing.width * Metrics.cardAspect) < 0.0001)
        // Same place on the mat, same lean: only the posture changed.
        #expect(abs(rested.x - standing.x) < 0.0001)
        #expect(abs(rested.forward - standing.forward) < 0.0001)
        #expect(rested.lean == standing.lean)
    }
}

// MARK: - The rake itself

@Suite("3D card rake")
struct BoardCard3DRakeTests {

    @Test("Cards further up the screen have to stand up further")
    func leanGrowsWithDistance() {
        let camera = StageCamera.standard
        // Elevation ratios from the bottom of a phone frame to the top.
        let ratios: [CGFloat] = [-0.45, -0.2, 0, 0.2, 0.45]
        let leans = ratios.map { BoardCard3DProjection.lean(atRatio: $0, camera: camera).degrees }

        for (previous, next) in zip(leans, leans.dropFirst()) {
            #expect(next > previous)
        }
    }

    @Test("Near the bottom of the frame the lean turns slightly negative")
    func nearRowsTipAway() {
        // A card lying flat at the very bottom of a 38-degree mat is already
        // more than square-on to the reader, so holding the board's one
        // foreshortening means tipping it a couple of degrees AWAY. The sign
        // is load-bearing: forcing it positive would make the near player's
        // Chakra row taller than every other row.
        let lean = BoardCard3DProjection.lean(atRatio: -0.5).degrees
        #expect(lean < 0)
        #expect(lean > -20)
    }

    @Test("A card in the middle of the mat is raked by roughly the design angle")
    func midMatSitsAtTheDesignRake() {
        // On the optical axis the geometry reduces to exactly
        // 90 - pitch - rake, which is the plainest statement of what the
        // number means.
        let lean = BoardCard3DProjection.lean(atRatio: 0).degrees
        let expected = 90 - FieldStageMetrics.pitchDegrees - BoardCard3DMetrics.rakeDegrees
        #expect(abs(lean - expected) < 0.001)
    }
}

// MARK: - Degenerate geometry

@Suite("3D card placement refusals")
struct BoardCard3DRefusalTests {

    @Test("A stage with no size places nothing")
    func zeroStage() {
        #expect(BoardCard3DProjection.placement(
            for: subject(), rect: slot(atX: 100, y: 100), stageSize: .zero
        ) == nil)
    }

    @Test("A slot with no width places nothing")
    func zeroSlot() {
        let empty = CGRect(x: 100, y: 100, width: 0, height: 0)
        #expect(BoardCard3DProjection.placement(
            for: subject(), rect: empty, stageSize: phone
        ) == nil)
    }

    @Test("A slot above the ground plane's horizon places nothing")
    func aboveTheHorizon() {
        // The horizon sits about a quarter of a screen ABOVE the top edge, so
        // this is a rect that is not on screen at all. It refuses rather than
        // solving for a point behind the camera.
        let offScreen = CGRect(x: 180, y: -400, width: 55, height: 77)
        #expect(BoardCard3DProjection.placement(
            for: subject(), rect: offScreen, stageSize: phone
        ) == nil)
    }

    @Test("Depth is capped rather than allowed to run away toward the horizon")
    func depthCeiling() throws {
        let camera = StageCamera.standard
        let ceiling = camera.platformFar * BoardCard3DMetrics.depthCeiling
        // Just under the horizon, where the inversion diverges.
        let nearHorizon = CGRect(x: 180, y: -180, width: 55, height: 77)
        let placement = try #require(
            BoardCard3DProjection.placement(
                for: subject(), rect: nearHorizon, stageSize: phone
            )
        )
        #expect(placement.forward == ceiling)
    }

    @Test("A subject whose frame has not been published yet is skipped, not guessed at")
    func missingFrame() {
        let placements = BoardCard3DProjection.placements(
            for: [subject(), subject()], frames: [:], stageSize: phone
        )
        #expect(placements.isEmpty)
    }

    @Test("A body scrolled off its own row is clipped, exactly as the mat clips it")
    func scrolledOffTheRow() {
        // The Characters row scrolls once effects flood a side past its five
        // printed slots, and the 2D mat clips what leaves it. A slab is drawn
        // by a scene with no scroll view in it, so the band does the clipping.
        let rows = CGRect(x: 90, y: 460, width: 250, height: 250)
        let inside = subject(id: "on-row", anchor: .character(UUID()))
        let outside = subject(id: "scrolled-off", anchor: .character(UUID()))

        let frames: [BoardCardAnchor: CGRect] = [
            inside.anchor: slot(atX: 200, y: 550),
            outside.anchor: slot(atX: 20, y: 550),
            .playRegion(.player): rows,
        ]
        let placements = BoardCard3DProjection.placements(
            for: [inside, outside], frames: frames, stageSize: phone
        )
        #expect(placements.count == 1)
        #expect(placements.first?.id == inside.id)
    }

    @Test("A Leader is placed even though it stands outside the rows band")
    func leadersAreNotConfined() {
        // The Leader lives in the label column, outside the band by
        // construction. Confining it would leave a side with no Leader on the
        // field at all.
        let leader = subject(anchor: .leader(.player), confined: false)
        let frames: [BoardCardAnchor: CGRect] = [
            leader.anchor: slot(atX: 20, y: 550),
            .playRegion(.player): CGRect(x: 90, y: 460, width: 250, height: 250),
        ]
        #expect(BoardCard3DProjection.placements(
            for: [leader], frames: frames, stageSize: phone
        ).count == 1)
    }
}

// MARK: - iPad

@Suite("3D cards on a regular-width board")
struct BoardCard3DPadTests {

    private let pad = CGSize(width: 1024, height: 1366)

    @Test("A larger board places its slabs on its own slots just as exactly")
    func padSlotsRoundTrip() throws {
        let pinhole = TestPinhole(size: pad)

        for y in [120.0, 340.0, 780.0, 1080.0] as [CGFloat] {
            let rect = slot(atX: 512, y: y, width: 110)
            let placement = try #require(
                BoardCard3DProjection.placement(
                    for: subject(), rect: rect, stageSize: pad
                )
            )
            let landed = pinhole.centre(of: placement)
            #expect(abs(landed.x - rect.midX) < 0.5)
            #expect(abs(landed.y - rect.midY) < 0.5)

            let size = pinhole.footprint(of: placement, isRested: false)
            #expect(abs(size.width - rect.width) < rect.width * 0.005)
        }
    }

    @Test("The world size of a slab follows the slot it stands in, not the screen")
    func widerSlotsGetWiderSlabs() throws {
        let narrow = try #require(
            BoardCard3DProjection.placement(
                for: subject(), rect: slot(atX: 512, y: 780, width: 60), stageSize: pad
            )
        )
        let wide = try #require(
            BoardCard3DProjection.placement(
                for: subject(), rect: slot(atX: 512, y: 780, width: 120), stageSize: pad
            )
        )
        // Same row, double the slot: double the card.
        #expect(abs(wide.width - narrow.width * 2) < 0.0001)
    }
}

// MARK: - Cast

@Suite("3D card cast")
@MainActor
struct BoardCard3DCastTests {

    /// A Classic game on the shipped pool, settled past the opening mulligan.
    /// The real pool rather than a fixture, because the cast's whole job is to
    /// pick cards out of a position the shipped game can actually reach.
    private static func startedEngine() -> (engine: GameEngine, summon: Card?) {
        let database = CardDatabase()
        let engine = GameEngine(
            configuration: GameConfiguration(
                mode: .soloVersusSelf,
                format: .classic,
                playerDeckID: nil,
                opponentDeckID: nil,
                fixedDeckColor: .red
            ),
            database: database,
            decks: DeckStore(),
            seed: 7
        )
        if let second = engine.state.awaitingMulligan {
            engine.apply(.mulligan(keep: true), by: second)
        }
        return (engine, database.cards.first { $0.type == .summon })
    }

    @Test("An opening board casts both Leaders and both Summon markers, and nothing else")
    func openingCast() throws {
        let game = Self.startedEngine()
        let summon = try #require(game.summon)
        let cast = BoardCard3DCast.subjects(
            engine: game.engine, summonCard: summon, reveals: []
        )

        #expect(cast.count == 4)
        #expect(cast.contains { $0.anchor == .leader(.player) })
        #expect(cast.contains { $0.anchor == .leader(.opponent) })
        #expect(cast.contains { $0.anchor == .summon(.player) })
        #expect(cast.contains { $0.anchor == .summon(.opponent) })
        // Nothing is in play and nothing has been set, so no card in a zone
        // row is entitled to a slab yet.
        #expect(!cast.contains { if case .character = $0.anchor { return true } else { return false } })
        #expect(!cast.contains { if case .support = $0.anchor { return true } else { return false } })
        // An opening board has nothing rested.
        #expect(cast.allSatisfy { !$0.isRested })
    }

    @Test("A pool with no Summon card casts no marker rather than an empty slab")
    func noSummonCard() {
        let game = Self.startedEngine()
        let cast = BoardCard3DCast.subjects(
            engine: game.engine, summonCard: nil, reveals: []
        )
        #expect(cast.count == 2)
        #expect(!cast.contains { if case .summon = $0.anchor { return true } else { return false } })
    }

    @Test("The node cap drops the least important cards, never a Leader")
    func capKeepsLeaders() {
        let game = Self.startedEngine()
        let cast = BoardCard3DCast.subjects(
            engine: game.engine, summonCard: game.summon, reveals: [], limit: 2
        )

        #expect(cast.count == 2)
        #expect(cast.allSatisfy { if case .leader = $0.anchor { return true } else { return false } })
    }

    @Test("A cap of nothing casts nothing, which is the whole 2D fallback")
    func zeroCap() {
        let game = Self.startedEngine()
        #expect(BoardCard3DCast.subjects(
            engine: game.engine, summonCard: game.summon, reveals: [], limit: 0
        ).isEmpty)
    }

    @Test("Identities are stable across passes, so slabs are never rebuilt for nothing")
    func stableIdentities() {
        let game = Self.startedEngine()
        let first = BoardCard3DCast.subjects(
            engine: game.engine, summonCard: game.summon, reveals: []
        )
        let second = BoardCard3DCast.subjects(
            engine: game.engine, summonCard: game.summon, reveals: []
        )
        #expect(first == second)
    }
}
