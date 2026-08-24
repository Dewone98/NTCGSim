//
//  BoardCard3DLayer.swift
//  NTCGSimulator
//
//  The join between the 2D mat and the 3D card renderer: it decides WHICH
//  cards in play become slabs, and works out WHERE each slab has to sit in
//  the stage's world so that it lands exactly on the slot the board already
//  laid out for it.
//
//  Why the placement is derived rather than authored. `Card3DView` takes
//  world coordinates on the stage's ground plane, and the board's layout is
//  screen points solved by `BoardLayout`. Authoring a mat of world rows and
//  hoping it lined up with the layout would be two independent truths about
//  where a card is — and every badge, damage number, target ring and tap
//  target on this board is positioned from the layout's truth. So the layout
//  wins outright: every card publishes its frame as a `BoardCardAnchor`, and
//  this file runs `StageCamera`'s projection BACKWARDS to find the world
//  point that projects onto that frame. There is one camera, one space, and
//  the slab is guaranteed to be under the tap that selects it because both
//  come from the same rect.
//
//  THE RAKE, which is the one judgement call here. A card lying dead flat on
//  the ground plane foreshortens by the sine of the ray's depression angle,
//  and on this board that angle runs from about 52 degrees at the near
//  player's Chakra row to about 13 degrees at the top of the opponent's
//  Characters row. Flat, the opponent's cards would project to a FIFTH of
//  their printed height — unreadable, and nothing a player could aim at. So
//  a slab is not laid flat: it is raked up out of the mat by exactly the
//  angle that leaves it `rakeDegrees` short of square-on to the reader, which
//  makes every card on the board foreshorten by the same cos(rake) — a few
//  percent, uniform from the far row to the near one. The card is still an
//  object standing on the mat at a real world point, still lit by the scene's
//  one key, still keystoned by its own perspective; it is simply propped
//  toward the reader rather than face down on the table. Legibility is a
//  stated requirement of this board and it outranks literalism about a plane.
//
//  What is deliberately NOT here:
//
//  * Cards in hand. A hand card is UI to be read and chosen between, drawn
//    larger than a board card for exactly that reason; putting it through a
//    perspective camera would cost sharpness to buy nothing.
//  * Face-down Supports, either side's. The information rule in
//    `FaceDownStyle` is that your own set card may show its blurred printing
//    and an opponent's may show nothing at all, and both of those are drawn
//    by the 2D face today. A slab that tried to reproduce them would be a
//    second implementation of the one rule on this board that decides games,
//    so face-down Supports keep the face they already have.
//  * A Support in the act of turning face-up. That reveal is a focus pull the
//    2D face owns; the card joins the slab layer once it is simply face-up.
//  * Chakra. They are markers rather than cards being read, and they are
//    drawn at a fraction of a slot's width.
//

import CoreGraphics
import Foundation
import SwiftUI

// MARK: - Metrics

/// The numbers the slab layer is built from, with the reasoning that produced
/// them.
enum BoardCard3DMetrics {

    /// How far a slab leans back from square-on to the reader, degrees.
    ///
    /// This is the whole look knob. Zero would be a billboard — pixel-exact
    /// with the 2D slot and completely flat, with no keystone and no edge.
    /// Large angles read as a card lying on a table but shrink the printing
    /// (the card foreshortens by cos of this angle) and start to cost
    /// legibility. 22 degrees costs 7% of a card's height — under three points
    /// on a phone slot — and buys a visible keystone across the card and a
    /// face angled into the key light.
    static let rakeDegrees: Double = 22

    /// The rake in radians.
    static var rake: CGFloat { CGFloat(rakeDegrees) * .pi / 180 }

    /// Fraction of the printed height a slab keeps once raked. Written out
    /// because the 2D stand-in and the tests both need the same number the
    /// projection uses.
    static var foreshortening: CGFloat { CGFloat(cos(Double(rake))) }

    /// How far past the drawn platform's far edge a slab may be placed, as a
    /// multiple of `StageCamera.platformFar`.
    ///
    /// The opponent's half of the board is drawn ABOVE the mat's far edge, so
    /// its cards genuinely belong on the ground plane's continuation beyond
    /// the drawn platform — roughly three times as far out. The ceiling is
    /// insurance for a rect that somehow resolved near the horizon, where the
    /// inversion runs away: a slab pinned at the ceiling is a few points out
    /// of place, where an unbounded one would be a card the size of a
    /// mountain.
    static let depthCeiling: CGFloat = 6

    /// How dark the stepped-back veil is over a slab whose card is not a
    /// legal answer to the open question. It replaces the 45% opacity the 2D
    /// face fades itself to — the slab is behind the mat's own chrome, so the
    /// only way to push it back is to lay something over it.
    static let steppedBackVeil: Double = 0.55

    /// The quarter turn a rested card is drawn at.
    ///
    /// NEGATIVE ninety, because the 2D mat rests a card with
    /// `.rotationEffect(.degrees(90))` — clockwise on screen, top edge to the
    /// right — and a positive yaw about the stage's up axis would swing the
    /// top edge the other way. A rested slab reading mirror-image of the
    /// rested 2D card next to it is exactly the kind of disagreement between
    /// two spaces this file exists to prevent.
    static let restedYaw = Angle.degrees(-90)
}

// MARK: - Cast

/// One card in play that the board is drawing as a slab.
///
/// Identity is the placement id the 3D scene diffs on, and it is the in-play
/// instance rather than the printing — two copies of one card are two slabs,
/// and a card that stays in its slot keeps its node across every unrelated
/// change to the position.
struct BoardCard3DSubject: Identifiable, Equatable {

    let id: String

    /// The frame the layout publishes for this card. It is both how the slab
    /// is placed and how the 2D face knows to stand aside.
    let anchor: BoardCardAnchor

    /// The half of the mat the card stands on, which names the band its slab
    /// is confined to.
    let slot: PlayerSlot

    let card: Card

    /// Rested cards lie on their side, on the mat and in the scene alike.
    let isRested: Bool

    /// Whether the card lives inside its side's three zone rows.
    ///
    /// The Characters row SCROLLS — an effect can flood a side past its
    /// printed five slots — and the 2D mat clips a body that has been pushed
    /// off the row's edge. A slab has no such clip: it is drawn by a scene
    /// that knows nothing about a scroll view, so a body scrolled out of its
    /// row would go on standing over the counters beside it. Cards in the
    /// rows are therefore held to the `playRegion` band their side publishes,
    /// exactly as holograms are. Leaders are not: they live in the label
    /// column, outside that band by construction, and nothing clips them.
    let isConfinedToRows: Bool
}

/// Works out which cards on the field become slabs.
///
/// The list is derived from the POSITION rather than from the geometry, so
/// the 2D faces can be told to stand aside in the same render pass that
/// publishes the frames the slabs will be placed from — there is no way for
/// the two to disagree about which cards the slab layer owns.
enum BoardCard3DCast {

    /// Every card on the field entitled to a slab, most important first.
    ///
    /// The order is the tie-break at the node cap, and it is importance
    /// rather than reading order: an effect can flood a Characters row past
    /// its printed five slots, and the two Leaders and the two Summon markers
    /// are the last things that should drop out when it does. Truncation is a
    /// soft landing anyway — a card that misses the cap is drawn by the 2D
    /// face, which differs from a slab by a few percent of its height.
    ///
    /// `summonCard` is handed in rather than looked up, because the mat draws
    /// its marker from `BoardPoolLookup` and the two have to be the same card
    /// or the same absence — a slab standing on a marker the row is not
    /// drawing would be a card floating in an empty zone.
    static func subjects(
        engine: GameEngine,
        summonCard: Card?,
        reveals: [SupportReveal],
        limit: Int = Card3DSceneMetrics.maxNodes
    ) -> [BoardCard3DSubject] {
        var subjects: [BoardCard3DSubject] = []

        for slot in PlayerSlot.allCases {
            guard let leader = engine.leaderCard(for: slot) else { continue }
            subjects.append(BoardCard3DSubject(
                id: "leader.\(slot)",
                anchor: .leader(slot),
                slot: slot,
                card: leader,
                isRested: engine.side(slot).leaderRested,
                isConfinedToRows: false
            ))
        }

        if let summon = summonCard {
            for slot in PlayerSlot.allCases {
                subjects.append(BoardCard3DSubject(
                    id: "summon.\(slot)",
                    anchor: .summon(slot),
                    slot: slot,
                    card: summon,
                    isRested: engine.side(slot).summonRested,
                    isConfinedToRows: true
                ))
            }
        }

        for slot in PlayerSlot.allCases {
            for character in engine.side(slot).characters {
                guard let card = engine.card(for: character) else { continue }
                subjects.append(BoardCard3DSubject(
                    id: character.id.uuidString,
                    anchor: .character(character.id),
                    slot: slot,
                    card: card,
                    isRested: character.isRested,
                    isConfinedToRows: true
                ))
            }
        }

        for slot in PlayerSlot.allCases {
            subjects.append(contentsOf: faceUpSupports(on: slot, engine: engine, reveals: reveals))
        }

        return Array(subjects.prefix(max(0, limit)))
    }

    /// The Supports on one side that are simply face-up.
    ///
    /// "Simply" is doing work: a slot in the middle of a reveal is excluded,
    /// because the reveal is a blur clearing on the 2D face and swapping the
    /// card for a slab halfway through would cut the shot. A face-down card
    /// is excluded for the reason the file header gives — the information
    /// rule that draws it belongs to exactly one renderer.
    private static func faceUpSupports(
        on slot: PlayerSlot,
        engine: GameEngine,
        reveals: [SupportReveal]
    ) -> [BoardCard3DSubject] {
        let supports = engine.side(slot).supports

        return supports.indices.compactMap { index -> BoardCard3DSubject? in
            guard !reveals.contains(where: { $0.slot == slot && $0.slotIndex == index }) else {
                return nil
            }
            guard let placed = supports[index],
                  placed.isRevealed,
                  let card = engine.card(for: placed)
            else { return nil }

            return BoardCard3DSubject(
                id: placed.id.uuidString,
                anchor: .support(slot, index),
                slot: slot,
                card: card,
                isRested: false,
                isConfinedToRows: true
            )
        }
    }
}

// MARK: - Budget

/// Whether the board may draw slabs at all right now.
///
/// One verdict, asked once per render pass and handed both to the 2D faces
/// (so they stand aside) and to the scene (so it draws) — the two can never
/// disagree, which is what makes the fallback seamless rather than a hole in
/// the mat.
///
/// It is deliberately STRICTER than `Card3DBudget`, and in two places:
///
/// * Low Power Mode drops slabs entirely rather than simplifying them. That
///   is the same answer `HologramPulse` gives, and for the same reason — the
///   flat card is a complete card, so the cheapest presentation is not a
///   cheaper renderer but no renderer.
/// * Reduce Motion drops them too. A slab's whole payoff is light travelling
///   across it and the parallax it earns against the stage; held still it is
///   a slightly foreshortened picture of a card that costs a Metal surface,
///   so the honest answer to "reduce motion" here is the printed face.
enum BoardCard3DBudget {

    /// The verdict. `isEnabled` is the player's own switch, read by the
    /// caller from `Card3DDefaults.enabledKey`.
    @MainActor
    static func rendersSlabs(isEnabled: Bool, reduceMotion: Bool) -> Bool {
        guard isEnabled, !reduceMotion else { return false }
        guard !EffectPowerMonitor.shared.isLowPower else { return false }
        // The renderer's own ceiling has the last word, so a thermal state it
        // refuses to draw at can never leave the board waiting for slabs that
        // are not coming.
        return Card3DBudget.current(reduceMotion: reduceMotion, isPaused: false).rendersCards
    }
}

// MARK: - Projection

/// `StageCamera`'s ground projection, run backwards, plus the rake that keeps
/// the result readable.
///
/// The derivation, in the camera's own terms. Write `k = (H/2)/tan(φ)` for
/// the pinhole's focal length in screen points, `q` for a point's optical
/// depth and `qᵤ` for its height against the camera's up axis. `StageCamera`
/// projects a ground point to
///
///     screenX = W/2 + k·x/q          screenY = H/2 − k·qᵤ/q
///
/// so a screen point fixes the two RATIOS u = x/q and v = qᵤ/q, and nothing
/// else. Substituting the ground plane's own qᵤ = f·sinθ − h·cosθ and
/// q = h·sinθ + f·cosθ and solving for the forward distance f gives
///
///     f = h·(cosθ + v·sinθ) / (sinθ − v·cosθ)
///
/// — the same inversion `HologramPerspective.groundDepth` runs, which is why
/// a slab and the hologram standing over it agree about depth. `x = u·q`
/// follows, and a card of world width W then projects to k·W/q screen points
/// across, which is what fixes the scale.
///
/// The rake falls out of the same algebra. A segment of the card running away
/// from the reader at δ above the mat projects to a screen height
/// proportional to sin(α + δ)/cos(ψ), where ψ = atan(v) is the point's
/// elevation off the optical axis and α = θ − ψ is the ray's depression below
/// horizontal. Setting that equal to cos(rake) — the uniform foreshortening
/// this layer wants — and solving for δ is the whole of `lean`.
enum BoardCard3DProjection {

    /// Places every subject whose frame the layout has published.
    ///
    /// A subject with no frame yet is skipped rather than guessed at: the
    /// only moment that happens is the first pass of a fresh layout, before
    /// preferences have travelled, and one frame of a flat card is cheaper
    /// than a card placed where the board is not.
    static func placements(
        for subjects: [BoardCard3DSubject],
        frames: [BoardCardAnchor: CGRect],
        stageSize: CGSize,
        camera: StageCamera = .standard
    ) -> [Card3DPlacement] {
        subjects.compactMap { subject in
            guard let rect = frames[subject.anchor] else { return nil }
            // A card the mat has scrolled off its own row is clipped there and
            // has to be clipped here too — see `isConfinedToRows`. The test is
            // the card's centre against its side's band, which is the same
            // test the hologram layer applies to the same rects.
            if subject.isConfinedToRows,
               let region = frames[.playRegion(subject.slot)],
               !region.contains(CGPoint(x: rect.midX, y: rect.midY)) {
                return nil
            }
            return placement(for: subject, rect: rect, stageSize: stageSize, camera: camera)
        }
    }

    /// The world placement whose projection lands on `rect`.
    ///
    /// Returns nil only for geometry that cannot be projected at all — a
    /// stage with no height, a card with no width, or a rect resolved above
    /// the ground plane's horizon (which sits off the top of the screen by
    /// design, so it means the card is not on screen either).
    static func placement(
        for subject: BoardCard3DSubject,
        rect: CGRect,
        stageSize: CGSize,
        camera: StageCamera = .standard
    ) -> Card3DPlacement? {
        guard stageSize.height > 0, stageSize.width > 0, rect.width > 0 else { return nil }

        // The pinhole's focal length in screen points, and the two ratios the
        // card's centre fixes.
        let k = stageSize.height / 2 / camera.tanHalfFOV
        let u = (rect.midX - stageSize.width / 2) / k
        let v = (stageSize.height / 2 - rect.midY) / k

        // Ground depth. The denominator is the horizon test: it vanishes on
        // the vanishing point and goes negative above it.
        let denominator = camera.sinPitch - v * camera.cosPitch
        guard denominator > 0.0001 else { return nil }
        let unbounded = camera.height * (camera.cosPitch + v * camera.sinPitch) / denominator
        let forward = min(unbounded, camera.platformFar * BoardCard3DMetrics.depthCeiling)

        let depth = camera.opticalDepth(forward: forward)
        guard depth > 0 else { return nil }

        // World size. `width` is the card's own printed width, so a rested
        // card — turned a quarter and drawn at the card ratio, exactly as the
        // 2D mat draws it — is the same slab scaled by that ratio.
        let lateral = rect.width / k * depth
        let width = subject.isRested ? lateral * Metrics.cardAspect : lateral

        return Card3DPlacement(
            id: subject.id,
            card: subject.card,
            x: u * depth,
            forward: forward,
            yaw: subject.isRested ? BoardCard3DMetrics.restedYaw : .zero,
            lean: lean(atRatio: v, camera: camera),
            width: width
        )
    }

    /// How far a slab at elevation ratio `v` has to be raked up out of the
    /// mat to foreshorten by exactly `BoardCard3DMetrics.foreshortening`.
    ///
    /// Near the bottom of the frame the answer is slightly NEGATIVE — a card
    /// lying flat down there is already more than square-on to the reader, so
    /// keeping the board's one foreshortening means tipping it a couple of
    /// degrees away rather than toward. That is the formula being honest, not
    /// a sign error, and it is what keeps the near player's Chakra row the
    /// same size as everything else.
    static func lean(atRatio v: CGFloat, camera: StageCamera = .standard) -> Angle {
        let elevation = atan(Double(v))
        let depression = Double(camera.pitch) - elevation
        // cos(elevation) is the off-axis correction: a card at the edge of a
        // 55-degree frame is seen a little obliquely even before it is raked.
        let target = min(1, Double(BoardCard3DMetrics.foreshortening) * cos(elevation))
        return .radians(asin(target) - depression)
    }
}

// MARK: - Layer

/// The slab layer the board composes between the field stage and its own 2D
/// chrome.
///
/// It is a thin wrapper on purpose: everything interesting is the projection
/// above, and everything expensive is `Card3DView`'s single `SCNView`. The
/// layer takes no touches at all — every tap on the board is answered by the
/// 2D slot the slab is standing in, which is the same rect the slab was
/// placed from.
struct BoardCard3DLayer: View {

    /// The cards to lay out, most important first.
    let subjects: [BoardCard3DSubject]

    /// Where the layout says each card is, in this layer's own coordinate
    /// space.
    let frames: [BoardCardAnchor: CGRect]

    /// The layer's size, which is the space the shared camera is projected
    /// through.
    let stageSize: CGSize

    /// True while a full-screen effect is playing — the slabs hold still for
    /// it, the same contract the stage keeps.
    var isPaused: Bool = false

    var body: some View {
        Card3DView(
            cards: BoardCard3DProjection.placements(
                for: subjects,
                frames: frames,
                stageSize: stageSize
            ),
            isPaused: isPaused
        )
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}
