//
//  HologramProjection.swift
//  NTCGSimulator
//
//  The hologram that floats above a face-up card — the card's own artwork
//  cast upward as a plane of light, standing in the same 3D space as the
//  field stage behind the board.
//
//  What the named references actually put above a card, and what survives
//  here. YGO Omega's 3D field view makes the card's printed image the object
//  in the scene — no character models, the *picture* is the monster. Master
//  Duel keeps every card screen-space 2D over its diorama (the split this
//  app's `FieldStage` already copies) and spends its drama on light around
//  the card rather than on burying it. Duel Links' alternate field view and
//  Dueling Nexus's hologram option both describe the exact shape used here:
//  the art cropped out of the card, hovering above it "as in the anime",
//  connected to the card by the beam projecting it. So the achievable —
//  and faithful — version is: a lit, translucent billboard of the card's
//  artwork, a tapered cone of light casting it up from the card, a glow
//  where the beam leaves the card face, and a few motes drifting up the
//  beam. The card underneath stays fully readable: the hologram sits
//  *above* its top edge, never over its stat line.
//
//  The geometry is borrowed, not invented. `StageCamera.standard` — the one
//  pinhole camera the field stage is projected through (pitch 38 degrees,
//  vertical FOV 55 degrees, height 3 world units) — supplies two things:
//
//  * BILLBOARD TILT. An upright billboard standing on the ground plane,
//    yawed to face the viewer, makes exactly the camera's pitch angle with
//    the image plane. So the plane is tipped top-away by
//    `FieldStageMetrics.pitchDegrees` about its bottom edge: the dominant
//    cue is the cos(38) vertical foreshortening, which is exact; the small
//    keystone (top edge a few percent narrower) comes from the rotation's
//    perspective term. SwiftUI's `perspective` parameter is relative to the
//    view rather than to the screen, so the pinhole's eye distance (about
//    0.96 screen heights, from halfHeight / tan(halfFOV)) cannot be written
//    down directly; `billboardPerspective` is calibrated to land the
//    keystone near the ~7 percent that distance produces on a board-sized
//    plane.
//
//  * PERSPECTIVE SCALE. The board's cards are screen-space 2D and all the
//    same size, but the stage under them converges, so a hologram's size is
//    what re-attaches each card to its depth: invert the stage projection
//    at the card's screen y to recover its ground distance z (the same
//    formula `StageCamera` uses to place the platform's far edge, run
//    backwards), then scale by opticalDepth(zRef) / opticalDepth(z) — the
//    projection's own 1/Z law, with zRef at mid-mat so a centre-board
//    hologram is scale 1. The result is clamped: unclamped 1/Z would shrink
//    a far hologram twice as much as its (un-shrunk) card, and the pair
//    would visibly disagree. The clamp keeps near and far holograms ordered
//    the way the stage orders its mat rows without breaking their bond to
//    the cards casting them.
//
//  Motion is a slow vertical bob — sine over wall-clock time, with a phase
//  salted per hologram so a row of them never pulses in unison — plus the
//  material's scanline drift and irregular flicker. Everything ticks on one
//  `.periodic` timeline per hologram at 12Hz (6Hz under `.fair` thermal),
//  far below display refresh, because nothing here has more than a few
//  distinct states a second to show.
//
//  Cost discipline, concretely:
//  * At most `HologramMetrics.maxSimultaneous` (4) holograms render at
//    once; `HologramCast` keeps the nearest (largest on the stage's camera)
//    and skips the rest. Four is where the arithmetic and the look agree:
//    steady-state cost is ~3 cached-texture composites and one ~6-fill mote
//    canvas per hologram per tick — comfortably under a millisecond of
//    work at 12Hz for all four together — and a fifth floating plane starts
//    burying the board it decorates.
//  * The material rasterises its static plate once (`drawingGroup`) and a
//    tick only moves transforms and opacities; the cone is an `Equatable`
//    canvas drawn once per geometry; only the motes redraw per tick.
//  * Reduce Motion: the hologram stands perfectly still — no bob, no
//    flicker, no motes, no ticking clock at all — and fades rather than
//    rises. Low Power Mode and `.serious`-or-worse thermal state drop the
//    projection entirely, leaving the flat card exactly as it was: the
//    cheapest hologram is the one that is not there.
//  * Master off switch: `HologramDefaults.enabledKey`, a plain UserDefaults
//    bool a Settings toggle can bind with `@AppStorage`, outside
//    `SettingsStore`'s snapshot for the same reason the stage's switch is —
//    the kill switch must work without a schema change.
//
//  The board wires it up from the frames the mat publishes as
//  `BoardCardAnchor`s — each candidate's card frame, and the rows band of the
//  side it stands on:
//
//      .overlayPreferenceValue(BoardCardAnchorKey.self) { anchors in
//          GeometryReader { proxy in
//              let frames = anchors.mapValues { proxy[$0] }
//              HologramLayer(candidates: subjects.compactMap { subject in
//                  guard let rect = frames[subject.anchor],
//                        let region = region(for: subject.slot, in: frames)
//                  else { return nil }
//                  return HologramCandidate(
//                      id: subject.id, card: subject.card,
//                      anchorRect: rect, region: region
//                  )
//              })
//          }
//      }
//
//  The region is the contract that keeps decoration off the game state. A
//  projection fits itself inside the region it is given: it shrinks toward
//  its card, sinks at most onto the card's own art panel, and below
//  `minFitScale` it does not render — because the alternative, observed on a
//  device, was planes standing on the status strip, the side labels and the
//  life pills. The region must come from the board's layout (the rects it
//  publishes), never from this layer's own bounds: the layer spans the whole
//  board, chrome included, so its bounds are exactly the wrong answer.
//

import SwiftUI
import UIKit

// MARK: - Defaults

/// Persistence for the hologram layer's own switch. A namespace rather than
/// a value on `SettingsStore` so Settings, the board and a debug tool all
/// bind the same key without a schema change — the same contract as
/// `FieldStageDefaults`.
enum HologramDefaults {

    /// Master switch. When false no hologram renders at all — not a paused
    /// hologram, no hologram — and every card face looks exactly as it did
    /// before this file existed.
    static let enabledKey = "ncg.holograms.enabled"
}

// MARK: - Hologram metrics

/// Every number the projection is built from, with the reasoning.
enum HologramMetrics {

    // MARK: Plane

    /// Plane width as a multiple of the card's width, before perspective.
    /// Wider than the card — the projection outgrows its source, which is
    /// most of why it reads as a hologram and not as a second card — but
    /// narrow enough that neighbours in a five-slot row only brush.
    static let planeWidthFactor: CGFloat = 1.15

    /// Plane aspect, width over height. Portrait-ish, matching the framing
    /// of the card art it carries; taller than the 5:7 card would be at
    /// this width so the figure gains headroom.
    static let planeAspect: CGFloat = 0.82

    /// Corner rounding on the plane and its rim light.
    static let planeCornerRadius: CGFloat = 8

    /// Longest edge, in pixels, the plane's artwork is decoded at. The
    /// widest plane the app draws is ~160pt; 512px covers that at 3x, and
    /// the size-aware database call keeps a full-resolution bitmap from
    /// ever existing for a board decoration.
    static let artPixelSize = 512

    /// The keystone term of the billboard tilt. See the header: SwiftUI's
    /// perspective is view-relative, so this is calibrated to the ~7
    /// percent top-edge shrink the stage's true eye distance produces on a
    /// board-sized plane, rather than derived symbolically.
    static let billboardPerspective: CGFloat = 0.18

    // MARK: Placement

    /// Gap between the card's top edge and the plane's base, as a fraction
    /// of card height (perspective-scaled with the plane). Enough air that
    /// the beam visibly *carries* the image; little enough that plane and
    /// card read as one object.
    static let elevationFactor: CGFloat = 0.32

    /// Where the beam leaves the card, as a fraction of card height below
    /// its top edge — the art panel of the face, not the stat line, so the
    /// glow never sits on the numbers the player needs.
    static let coneBaseYFactor: CGFloat = 0.30

    /// Half-width of the beam at the card, as a fraction of card width,
    /// and at the plane, as a fraction of the plane's half-width. The beam
    /// fans *outward* going up — light spreading from a small emitter to a
    /// large image, which is the anime's projector grammar.
    static let coneBaseWidthFactor: CGFloat = 0.34
    static let coneTopWidthFactor: CGFloat = 0.72

    /// How far the beam tucks up behind the plane's base, and how far its
    /// base glow spills down the card, points. Both exist to hide seams:
    /// a beam that stops exactly at either end reads as a drawn triangle.
    static let coneOverlap: CGFloat = 4
    static let coneSpill: CGFloat = 16

    /// Beam opacity at the card end (it fades to clear at the plane) and
    /// the base glow's peak opacity. Brighter at the base: the light is
    /// densest where it has not yet spread.
    static let coneBaseOpacity: Double = 0.34
    static let coneGlowOpacity: Double = 0.3

    /// Slack added around the composed hologram's local frame so rim glow
    /// and bob never clip.
    static let frameMargin: CGFloat = 10

    /// The smallest fit the projection will render at when its region forces
    /// it to shrink — see `HologramProjection.fit`. Below this the plane is
    /// smaller than a fingertip and reads as noise over the card rather than
    /// as a projection above it, so the hologram is dropped instead: the same
    /// answer thermal pressure gives, for the same reason.
    static let minFitScale: CGFloat = 0.4

    // MARK: Perspective scale

    /// Clamp on the 1/Z scale. See the header: the cards themselves do not
    /// shrink with depth, so a fully honest 1/Z (about 1.4 near, 0.55 far
    /// on a phone board) would detach far holograms from their own cards.
    /// This range keeps the ordering the stage establishes while staying
    /// believable against uniform cards.
    static let minScale: CGFloat = 0.62
    static let maxScale: CGFloat = 1.2

    /// Ceiling on the recovered ground distance, as a multiple of the
    /// platform's far edge. Screen points above the mat would otherwise
    /// invert to arbitrarily deep ground on their way to the (off-screen)
    /// horizon.
    static let depthCeilingFactor: CGFloat = 1.6

    // MARK: Float

    /// Bob amplitude, points (perspective-scaled), and period, seconds.
    /// Two or three points either way over nearly five seconds is presence,
    /// not animation; the period is deliberately co-prime-ish with the
    /// material's 1.15s flicker window and the stage's 26s sway so nothing
    /// ever locks step.
    static let bobAmplitude: CGFloat = 3
    static let bobPeriod: Double = 4.7

    // MARK: Clock

    /// Ticks per second while alive, and the `.fair`-thermal rate. Twelve
    /// covers everything shown: the scanlines crawl at 7pt/s, the bob
    /// crosses ~6pt in 2.35s, and a flicker lasting 50-160ms still lands
    /// at least one frame. Faster is heat with no visible payoff.
    static let tickRate: Double = 12
    static let easedTickRate: Double = 6

    // MARK: Entry and exit

    /// The rise-and-resolve on becoming face-up, the collapse on leaving,
    /// and the plain crossfade Reduce Motion gets instead of either.
    static let riseDuration: Double = 0.5
    static let collapseDuration: Double = 0.35
    static let stillFade: Double = 0.25

    /// Where the entry scale starts: mostly collapsed vertically (rising
    /// out of the card) with a slight horizontal pinch, both pivoting at
    /// the card so growth reads as projection, not inflation.
    static let riseFloorY: CGFloat = 0.45
    static let riseFloorX: CGFloat = 0.88

    // MARK: Cost ceilings

    /// The most holograms rendered at once, and the `.fair`-thermal count.
    /// The arithmetic behind four is in the header; two under thermal
    /// pressure keeps the player's nearest pair — the ones being looked at
    /// — and sheds the rest.
    static let maxSimultaneous = 4
    static let easedSimultaneous = 2

    /// Motes riding the beam: exactly this many, forever. Each is one
    /// filled circle per tick.
    static let moteCount = 6

    /// Mote climb speed, points per second, and size, points. Slow and
    /// small: dust in a light beam, not particles in an effect.
    static let moteSpeed: ClosedRange<Double> = 12...26
    static let moteRadius: ClosedRange<Double> = 1.0...2.0

    /// Peak mote opacity, at the base of the beam; they thin as they climb.
    static let moteOpacity: Double = 0.5
}

// MARK: - Seeding

/// Stable per-hologram identity, for flicker salt and bob phase. FNV-1a
/// rather than `Hasher` because `Hasher` is seeded per launch and a
/// hologram should stutter the same way every time the same card is looked
/// at.
enum HologramSeed {

    /// A salt from any stable string id — a board instance UUID string, or
    /// a card's collector number.
    static func salt(for id: String) -> UInt64 {
        var hash: UInt64 = 0xCBF2_9CE4_8422_2325
        for byte in id.utf8 {
            hash = (hash ^ UInt64(byte)) &* 0x0000_0100_0000_01B3
        }
        return hash | 1
    }

    /// The bob's phase offset, radians, spread over the full circle so a
    /// row of holograms breathes out of step.
    static func bobPhase(_ salt: UInt64) -> Double {
        Double(salt % 1024) / 1024 * 2 * .pi
    }
}

// MARK: - Perspective

/// The stage camera's maths, run backwards: from a card's place on screen
/// to its depth on the mat, to the scale its hologram should take. All of
/// it goes through `StageCamera.standard`, so holograms and stage can never
/// disagree about where the vanishing point is.
enum HologramPerspective {

    /// The ground distance z whose projection lands at screen `y`. Inverts
    /// `StageCamera.project` for the ground plane — the same inversion the
    /// camera itself uses to place the platform's far edge:
    ///
    ///     y' = (z sin(p) - h cos(p)) / ((h sin(p) + z cos(p)) tan(f))
    ///     =>  z = h (cos(p) + t sin(p)) / (sin(p) - t cos(p)),  t = y' tan(f)
    ///
    /// With the standard pitch the horizon sits above the screen, so every
    /// on-screen y is below it and the denominator stays positive; the
    /// guard and clamp are for the geometry nobody measured.
    static func groundDepth(
        atScreenY y: CGFloat,
        stageHeight: CGFloat,
        camera: StageCamera = .standard
    ) -> CGFloat {
        let ceiling = camera.platformFar * HologramMetrics.depthCeilingFactor
        guard stageHeight > 0 else { return camera.platformFar }

        let fromBottom = 1 - y / stageHeight
        let t = (fromBottom * 2 - 1) * camera.tanHalfFOV
        let denominator = camera.sinPitch - t * camera.cosPitch
        guard denominator > 0.0001 else { return ceiling }

        let z = camera.height * (camera.cosPitch + t * camera.sinPitch) / denominator
        return min(max(z, camera.platformNear), ceiling)
    }

    /// The hologram's scale for a card whose frame is `rect` on a stage of
    /// `stageSize`: the projection's own 1/Z law, referenced to mid-mat so
    /// a centre-board hologram is scale 1, then clamped for the reason the
    /// metrics give.
    static func relativeScale(
        forAnchor rect: CGRect,
        in stageSize: CGSize,
        camera: StageCamera = .standard
    ) -> CGFloat {
        let zReference = (camera.platformNear + camera.platformFar) / 2
        let z = groundDepth(atScreenY: rect.midY, stageHeight: stageSize.height, camera: camera)
        let scale = camera.opticalDepth(forward: zReference) / camera.opticalDepth(forward: z)
        return min(max(scale, HologramMetrics.minScale), HologramMetrics.maxScale)
    }
}

// MARK: - Pulse

/// What a hologram may do right now — one verdict, same shape as
/// `StagePulse`, because every voice that can object (the player, the
/// battery, the chassis) wants one of the same two answers: hold still, or
/// do not exist.
struct HologramPulse: Equatable {

    /// Seconds between ticks, or nil to hold a single static frame.
    let tickInterval: Double?

    /// Whether a hologram should render at all. False is the Low Power /
    /// thermal answer: the flat card, untouched, is the degraded mode.
    let isProjecting: Bool

    @MainActor
    static func current(reduceMotion: Bool) -> HologramPulse {
        guard !EffectPowerMonitor.shared.isLowPower else {
            return HologramPulse(tickInterval: nil, isProjecting: false)
        }
        switch StageThermalMonitor.shared.state {
        case .nominal:
            return HologramPulse(
                tickInterval: reduceMotion ? nil : 1 / HologramMetrics.tickRate,
                isProjecting: true
            )
        case .fair:
            return HologramPulse(
                tickInterval: reduceMotion ? nil : 1 / HologramMetrics.easedTickRate,
                isProjecting: true
            )
        default:
            return HologramPulse(tickInterval: nil, isProjecting: false)
        }
    }
}

// MARK: - Casting

/// One card that could carry a hologram: a stable identity (the board
/// instance's UUID string, so two copies of the same card desynchronise),
/// the card, and its frame in the overlay's space.
struct HologramCandidate: Identifiable, Equatable {
    let id: String
    let card: Card
    let anchorRect: CGRect

    /// Set false to collapse the hologram before removing the candidate;
    /// removing it outright skips the exit.
    var isPresented: Bool = true

    /// The region this card's projection must stay inside, in the same space
    /// as `anchorRect` — the board hands each candidate its own side's rows
    /// band. `.infinite` means unconstrained, which is what the previews want.
    var region: CGRect = .infinite
}

/// Decides which candidates actually project, holding the simultaneous
/// count under the ceiling. Nearest first — largest under the stage's
/// camera, lowest on screen — because the near rows are where the player
/// is looking and where a hologram's size earns its cost.
enum HologramCast {

    /// How many holograms the device should carry right now.
    @MainActor
    static var limit: Int {
        guard !EffectPowerMonitor.shared.isLowPower else { return 0 }
        switch StageThermalMonitor.shared.state {
        case .nominal: return HologramMetrics.maxSimultaneous
        case .fair:    return HologramMetrics.easedSimultaneous
        default:       return 0
        }
    }

    /// The candidates that make the cut, in a stable order.
    @MainActor
    static func select(from candidates: [HologramCandidate]) -> [HologramCandidate] {
        let allowed = limit
        guard allowed > 0 else { return [] }
        guard candidates.count > allowed else { return candidates }
        let ranked = candidates.sorted { lhs, rhs in
            if lhs.anchorRect.midY != rhs.anchorRect.midY {
                return lhs.anchorRect.midY > rhs.anchorRect.midY
            }
            return lhs.id < rhs.id
        }
        return Array(ranked.prefix(allowed))
    }
}

/// The one view the board mounts: give it every face-up candidate and it
/// applies the master switch, the device budget and the ceiling, then
/// projects what survives. Lives in the board's anchor overlay so the
/// rects the cards published resolve in the same space the holograms draw
/// in.
///
/// Each candidate arrives carrying its own clamp region. The layer used to
/// derive one region from its own bounds, and that was the bug the board
/// fixed by publishing regions instead: the layer spans the whole board,
/// chrome included, so "inside the layer" never kept a plane off the status
/// strip or the life pills.
struct HologramLayer: View {

    var candidates: [HologramCandidate]

    @AppStorage(HologramDefaults.enabledKey) private var isEnabled = true

    var body: some View {
        if isEnabled {
            ZStack {
                ForEach(HologramCast.select(from: candidates)) { candidate in
                    HologramProjection(
                        bounds: candidate.region,
                        card: candidate.card,
                        anchorRect: candidate.anchorRect,
                        isPresented: candidate.isPresented,
                        salt: HologramSeed.salt(for: candidate.id)
                    )
                }
            }
            .allowsHitTesting(false)
            .accessibilityHidden(true)
        }
    }
}

// MARK: - Projection

/// One hologram: the beam, the motes and the artwork plane, composed in a
/// local frame and placed over the card at `anchorRect`. Fills whatever
/// container it is put in (the board's anchor overlay) and positions
/// itself, so several can stack in one ZStack without any coordinate
/// bookkeeping.
struct HologramProjection: View {

    /// The region the projection may occupy, in the same space as
    /// `anchorRect` — the board hands each card its own side's rows band, so
    /// a plane can never stand on the status strip, a side's name and life,
    /// or the counters. The projection makes itself fit: it shrinks toward
    /// its card and sinks at most onto the card's own art panel (see `fit`),
    /// leans inward rather than hanging over the region's sides (see
    /// `clamped`), and refuses to render at all below `minFitScale` — a
    /// plane that small is noise, and covering game state to stay big was
    /// the bug this exists to fix. `.infinite` means "do not constrain",
    /// which is what the previews want.
    var bounds: CGRect = .infinite


    let card: Card

    /// The card's frame, in the coordinate space of the overlay this view
    /// fills — exactly what `ProjectileAnchorKey` resolves to.
    let anchorRect: CGRect

    /// True while the card is face-up. Flipping it false collapses the
    /// hologram over `collapseDuration`; the caller removes the view after.
    var isPresented: Bool = true

    /// De-synchronises flicker and bob between holograms. Zero (the
    /// default) falls back to a salt from the card's collector number, so
    /// direct use still never pulses in unison across different cards.
    var salt: UInt64 = 0

    @Environment(CardDatabase.self) private var database
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase
    @AppStorage(HologramDefaults.enabledKey) private var isEnabled = true

    /// Entry/exit progress, 0 collapsed to 1 resolved. Animated by
    /// `sweepReveal`, read only through animatable modifiers so the rise
    /// and collapse interpolate.
    @State private var reveal: CGFloat = 0

    /// Keeps the subtree mounted through the collapse: the state animation
    /// targets 0 immediately, and a condition on `reveal` alone would
    /// unmount the view before the exit played.
    @State private var isMounted = false

    /// The timeline's epoch, captured at install like every effect clock in
    /// the app.
    @State private var mounted = Date.now

    var body: some View {
        GeometryReader { geo in
            let pulse = HologramPulse.current(reduceMotion: reduceMotion)

            if isEnabled, pulse.isProjecting,
               isMounted || isPresented,
               anchorRect.width > 0,
               let artwork = database.artwork(for: card, maxPixelSize: HologramMetrics.artPixelSize) {

                // Backgrounded scenes stop the clock, same as the stage:
                // nothing behind the app switcher earns a tick.
                let interval = scenePhase == .active ? pulse.tickInterval : nil

                if let interval {
                    TimelineView(.periodic(from: mounted, by: interval)) { context in
                        hologram(
                            artwork: artwork,
                            time: context.date.timeIntervalSince(mounted),
                            animated: true,
                            stageSize: geo.size
                        )
                    }
                } else {
                    hologram(artwork: artwork, time: 0, animated: false, stageSize: geo.size)
                }
            }
            // A card with no artwork casts nothing: a projector with no
            // slide is off, and a placeholder hologram would decorate the
            // one card that has nothing to show.
        }
        .allowsHitTesting(false)
        // Decoration over cards the board already narrates; a floating
        // plane would only steal VoiceOver focus from the card that owns it.
        .accessibilityHidden(true)
        .task(id: isPresented) { await sweepReveal() }
    }

    // MARK: One frame

    /// The hologram at one instant, composed in a local frame so the entry
    /// scale can pivot at the card and the canvases never see `reveal`
    /// (animatable modifiers interpolate; canvas parameters would jump).
    @ViewBuilder
    private func hologram(
        artwork: UIImage,
        time: Double,
        animated: Bool,
        stageSize: CGSize
    ) -> some View {
        let perspective = HologramPerspective.relativeScale(forAnchor: anchorRect, in: stageSize)
        let room = HologramProjection.fit(
            forAnchor: anchorRect,
            perspectiveScale: perspective,
            within: bounds
        )

        if room.scale >= HologramMetrics.minFitScale {
            fittedHologram(
                artwork: artwork,
                time: time,
                animated: animated,
                scale: perspective * room.scale,
                sink: room.sink
            )
        }
        // A card whose region leaves no worthwhile room casts nothing — the
        // cheapest hologram is the one that is not there, and a plane forced
        // under `minFitScale` would be decoration too small to decorate.
    }

    /// The composition at its fitted size, with the beam sunk `sink` points
    /// further down the card face when the region demanded it.
    private func fittedHologram(
        artwork: UIImage,
        time: Double,
        animated: Bool,
        scale: CGFloat,
        sink: CGFloat
    ) -> some View {
        // Plane and beam geometry, all at full extent — entry and exit are
        // transforms on the finished composition, not re-derived shapes. The
        // on-card measures (where the beam leaves the face, how far its glow
        // spills) deliberately stay unscaled: the card has not shrunk, so the
        // light on it must not either.
        let planeWidth = anchorRect.width * HologramMetrics.planeWidthFactor * scale
        let planeSize = CGSize(width: planeWidth, height: planeWidth / HologramMetrics.planeAspect)
        let gap = anchorRect.height * HologramMetrics.elevationFactor * scale
        let baseDrop = anchorRect.height * HologramMetrics.coneBaseYFactor
        let baseHalfWidth = anchorRect.width * HologramMetrics.coneBaseWidthFactor
        let topHalfWidth = planeWidth / 2 * HologramMetrics.coneTopWidthFactor

        // The local frame: plane on top, then the gap the beam crosses,
        // then the run down the card to the beam's base and its spill.
        let localWidth = max(planeWidth, max(baseHalfWidth, topHalfWidth) * 2)
            + HologramMetrics.frameMargin * 2
        let localHeight = planeSize.height + gap + baseDrop + HologramMetrics.coneSpill
        let planeBaseLocalY = planeSize.height
        let coneBaseLocalY = planeSize.height + gap + baseDrop

        let effectiveSalt = salt != 0 ? salt : HologramSeed.salt(for: card.id)
        let bob: CGFloat = animated
            ? HologramMetrics.bobAmplitude * scale * CGFloat(
                sin(2 * .pi * time / HologramMetrics.bobPeriod + HologramSeed.bobPhase(effectiveSalt))
            )
            : 0
        let growth = reduceMotion ? 1 : reveal

        return ZStack {
            HologramCone(
                size: CGSize(width: localWidth, height: localHeight),
                topY: planeBaseLocalY - HologramMetrics.coneOverlap,
                baseY: coneBaseLocalY,
                topHalfWidth: topHalfWidth,
                baseHalfWidth: baseHalfWidth,
                tint: HologramPalette.beam
            )
            .equatable()
            .position(x: localWidth / 2, y: localHeight / 2)

            if animated {
                HologramMotes(
                    size: CGSize(width: localWidth, height: localHeight),
                    topY: planeBaseLocalY,
                    baseY: coneBaseLocalY,
                    topHalfWidth: topHalfWidth,
                    baseHalfWidth: baseHalfWidth,
                    tint: HologramPalette.beam,
                    time: time,
                    salt: effectiveSalt
                )
                .position(x: localWidth / 2, y: localHeight / 2)
            }

            HologramPlane(
                artwork: artwork,
                size: planeSize,
                time: time,
                salt: effectiveSalt,
                isAnimated: animated
            )
            // The billboard tilt: top tipped away by the stage camera's
            // pitch, about the plane's base, with the calibrated keystone.
            // See the header for why this is exactly an upright world
            // billboard under that camera.
            .rotation3DEffect(
                .degrees(FieldStageMetrics.pitchDegrees),
                axis: (x: 1, y: 0, z: 0),
                anchor: .bottom,
                perspective: HologramMetrics.billboardPerspective
            )
            .position(x: localWidth / 2, y: planeBaseLocalY - planeSize.height / 2)
            .offset(y: bob)
        }
        .frame(width: localWidth, height: localHeight)
        // Entry and exit: grows up out of the card and collapses back into
        // it, pivoting at the beam's base. Reduce Motion holds the scale
        // and leaves only the crossfade.
        .scaleEffect(
            x: HologramMetrics.riseFloorX + (1 - HologramMetrics.riseFloorX) * growth,
            y: HologramMetrics.riseFloorY + (1 - HologramMetrics.riseFloorY) * growth,
            anchor: .bottom
        )
        .opacity(Double(reveal))
        // The local frame's bottom sits at the beam's base on the card; the
        // whole composition is placed so that point lands where the beam
        // leaves the card face — lowered by `sink` when the region asked for
        // it, which slides the beam's base further down the card's art panel
        // and never onto its stat line (`fit` caps the sink at `baseDrop`).
        .position(
            HologramProjection.clamped(
                x: anchorRect.midX,
                y: anchorRect.minY + baseDrop + sink + HologramMetrics.coneSpill - localHeight / 2,
                size: CGSize(width: localWidth, height: localHeight),
                within: bounds
            )
        )
    }

    // MARK: Fit

    /// How a projection makes room for itself under the chrome above its
    /// card: how much of its natural size survives, and how far its beam has
    /// to sink down the card face.
    struct RegionFit: Equatable {

        /// Multiplier on the perspective scale, 0 through 1. One means the
        /// region never touched the projection.
        let scale: CGFloat

        /// Extra points the whole composition is lowered by, at most the
        /// beam's own `coneBaseYFactor` drop — the beam base lands on the
        /// card's art panel, never on its stat line.
        let sink: CGFloat

        static let free = RegionFit(scale: 1, sink: 0)
    }

    /// The rise of the composition above the card's top edge — the plane and
    /// the air the beam crosses — at a given scale. This is the part of the
    /// projection the region can refuse; everything below the card's top edge
    /// is on the card.
    static func riseHeight(forAnchor rect: CGRect, scale: CGFloat) -> CGFloat {
        rect.width * HologramMetrics.planeWidthFactor * scale / HologramMetrics.planeAspect
            + rect.height * HologramMetrics.elevationFactor * scale
    }

    /// Fits the projection under its region's top edge.
    ///
    /// The budget is the air between the card's top and the region's top —
    /// less the bob's amplitude, so the float never pokes out — plus one
    /// `coneBaseYFactor` of the card's own face: a projection short of air
    /// may sink onto its card's art panel, which the beam's base glow already
    /// sits on, but no further, because below that live the numbers the
    /// player reads. Shrinking and sinking are solved together: the plane
    /// shrinks until it fits the budget, and sinks only by what shrinking
    /// alone could not recover.
    ///
    /// Pure, so the geometry is testable without a board.
    static func fit(
        forAnchor rect: CGRect,
        perspectiveScale: CGFloat,
        within region: CGRect
    ) -> RegionFit {
        // `.infinite` is the "do not constrain" sentinel; a degenerate region
        // constrains nothing either, matching `clamped`'s permissiveness.
        guard !region.isNull, !region.isEmpty,
              region.origin.y.isFinite, region.size.height.isFinite,
              rect.width > 0, rect.height > 0
        else { return .free }

        let rise = riseHeight(forAnchor: rect, scale: perspectiveScale)
        guard rise > 0 else { return .free }

        let bobAllowance = HologramMetrics.bobAmplitude * perspectiveScale
        let headroom = rect.minY - region.minY - bobAllowance
        guard headroom < rise else { return .free }

        let maxSink = rect.height * HologramMetrics.coneBaseYFactor
        let budget = headroom + maxSink
        guard budget > 0 else { return RegionFit(scale: 0, sink: 0) }

        let scale = min(1, budget / rise)
        let sink = min(max(0, rise * scale - headroom), maxSink)
        return RegionFit(scale: scale, sink: sink)
    }

    /// Keeps a composition of `size` centred as near its wanted point as the
    /// region allows.
    ///
    /// Clamping the centre rather than dropping the hologram matters: a card at
    /// the edge still gets its projection, just leaning inward instead of
    /// hanging over the chrome. A region smaller than the composition centres
    /// it rather than fighting itself.
    static func clamped(x: CGFloat, y: CGFloat, size: CGSize, within region: CGRect) -> CGPoint {
        // CGRect.isFinite is package-protected, so finiteness is checked on the
        // components, where it is public. `.infinite` is the "do not clamp"
        // sentinel and must fall through here.
        guard !region.isNull, !region.isEmpty,
              region.origin.x.isFinite, region.origin.y.isFinite,
              region.size.width.isFinite, region.size.height.isFinite
        else {
            return CGPoint(x: x, y: y)
        }
        func clamp(_ value: CGFloat, _ lower: CGFloat, _ upper: CGFloat) -> CGFloat {
            lower <= upper ? Swift.min(Swift.max(value, lower), upper) : (lower + upper) / 2
        }
        return CGPoint(
            x: clamp(x, region.minX + size.width / 2, region.maxX - size.width / 2),
            y: clamp(y, region.minY + size.height / 2, region.maxY - size.height / 2)
        )
    }

    // MARK: Reveal

    /// Runs the entry or the exit for the current `isPresented`, and keeps
    /// the subtree mounted until the exit has finished. A cancelled sleep
    /// means presentation flipped again mid-collapse; the replacement task
    /// remounts, so there is nothing to clean up.
    @MainActor
    private func sweepReveal() async {
        if isPresented {
            isMounted = true
            if reduceMotion {
                withAnimation(.easeOut(duration: HologramMetrics.stillFade)) { reveal = 1 }
            } else {
                withAnimation(.spring(
                    response: HologramMetrics.riseDuration,
                    dampingFraction: 0.78
                )) { reveal = 1 }
            }
        } else {
            let exit = reduceMotion
                ? HologramMetrics.stillFade
                : HologramMetrics.collapseDuration
            withAnimation(reduceMotion ? .easeOut(duration: exit) : .easeIn(duration: exit)) {
                reveal = 0
            }
            do {
                try await Task.sleep(for: .seconds(exit))
            } catch {
                return
            }
            if !isPresented { isMounted = false }
        }
    }
}

// MARK: - Plane

/// The floating image: the card's artwork clipped to a soft rectangle and
/// run through the hologram material. Its clock is its parent's — one
/// timeline per hologram, not one per layer.
private struct HologramPlane: View {

    let artwork: UIImage
    let size: CGSize
    let time: Double
    let salt: UInt64
    let isAnimated: Bool

    var body: some View {
        Image(uiImage: artwork)
            .resizable()
            .scaledToFill()
            .frame(width: size.width, height: size.height)
            .clipShape(RoundedRectangle(cornerRadius: HologramMetrics.planeCornerRadius))
            .hologramMaterial(
                cornerRadius: HologramMetrics.planeCornerRadius,
                time: time,
                salt: salt,
                isAnimated: isAnimated
            )
    }
}

// MARK: - Cone

/// The beam: a trapezoid from the card up to the plane, brightest at the
/// card, plus the pool of light where it leaves the face. Drawn in local
/// coordinates, `Equatable`, rasterised once per geometry — a tick never
/// touches it.
private struct HologramCone: View, Equatable {

    let size: CGSize
    let topY: CGFloat
    let baseY: CGFloat
    let topHalfWidth: CGFloat
    let baseHalfWidth: CGFloat
    let tint: Color

    var body: some View {
        Canvas { context, _ in
            let centreX = size.width / 2
            context.blendMode = .plusLighter

            // The beam, dense at the emitter and dissolving upward into the
            // image it carries.
            var beam = Path()
            beam.move(to: CGPoint(x: centreX - baseHalfWidth, y: baseY))
            beam.addLine(to: CGPoint(x: centreX - topHalfWidth, y: topY))
            beam.addLine(to: CGPoint(x: centreX + topHalfWidth, y: topY))
            beam.addLine(to: CGPoint(x: centreX + baseHalfWidth, y: baseY))
            beam.closeSubpath()
            context.fill(beam, with: .linearGradient(
                Gradient(colors: [
                    tint.opacity(HologramMetrics.coneBaseOpacity),
                    tint.opacity(HologramMetrics.coneBaseOpacity * 0.3),
                    .clear,
                ]),
                startPoint: CGPoint(x: centreX, y: baseY),
                endPoint: CGPoint(x: centreX, y: topY)
            ))

            // The pool on the card face — flattened by the same pitch that
            // rakes the mat, so the glow lies on the card rather than
            // standing on it.
            let glowRX = baseHalfWidth * 1.5
            let glowRY = glowRX * 0.38
            let glowCentre = CGPoint(x: centreX, y: baseY)
            context.fill(
                Path(ellipseIn: CGRect(
                    x: glowCentre.x - glowRX, y: glowCentre.y - glowRY,
                    width: glowRX * 2, height: glowRY * 2
                )),
                with: .radialGradient(
                    Gradient(colors: [
                        tint.opacity(HologramMetrics.coneGlowOpacity),
                        .clear,
                    ]),
                    center: glowCentre,
                    startRadius: 0,
                    endRadius: glowRX
                )
            )
        }
        .frame(width: size.width, height: size.height)
        .allowsHitTesting(false)
    }
}

// MARK: - Motes

/// Dust riding the beam: a fixed handful of dots climbing from the card to
/// the plane, thinning as they go. Each mote's attributes are seeded once
/// from its index so nothing boils between frames; its position is pure
/// arithmetic on the clock, so the redraw is `moteCount` fills and nothing
/// else. Skipped entirely for still frames.
private struct HologramMotes: View {

    let size: CGSize
    let topY: CGFloat
    let baseY: CGFloat
    let topHalfWidth: CGFloat
    let baseHalfWidth: CGFloat
    let tint: Color
    let time: Double
    let salt: UInt64

    var body: some View {
        Canvas { context, _ in
            let centreX = size.width / 2
            let travel = Double(baseY - topY)
            guard travel > 1 else { return }
            context.blendMode = .plusLighter

            for index in 0..<HologramMetrics.moteCount {
                var rng = SeededGenerator(
                    seed: (salt &+ UInt64(index) &* 0x9E37_79B9) | 1
                )
                let speed = Double.random(in: HologramMetrics.moteSpeed, using: &rng)
                let lane = Double.random(in: -1...1, using: &rng)
                let radius = CGFloat(Double.random(in: HologramMetrics.moteRadius, using: &rng))
                let start = Double.random(in: 0..<travel, using: &rng)

                // Climb, wrapping back to the base — a beam always has dust
                // somewhere along it.
                let climbed = (time * speed + start).truncatingRemainder(dividingBy: travel)
                let u = CGFloat(climbed / travel)
                let y = baseY - CGFloat(climbed)

                // Confined to the beam: the lane is a fraction of the
                // beam's half-width *at this height*, so motes follow the
                // taper instead of drifting out of the light.
                let halfWidth = baseHalfWidth + (topHalfWidth - baseHalfWidth) * u
                let x = centreX + CGFloat(lane) * halfWidth * 0.8

                let fade = HologramMetrics.moteOpacity * Double(1 - u * 0.8)
                context.fill(
                    Path(ellipseIn: CGRect(
                        x: x - radius, y: y - radius,
                        width: radius * 2, height: radius * 2
                    )),
                    with: .color(tint.opacity(fade))
                )
            }
        }
        .frame(width: size.width, height: size.height)
        .allowsHitTesting(false)
    }
}

// MARK: - Previews

/// Real collector numbers, so the previews project the bundled artwork the
/// shipping app projects.
private func hologramPreviewCards() -> [Card] {
    [
        Card(id: "K-039", name: "Kakashi Hatake", type: .character, color: .red,
             rarity: .common, setCode: "01", cost: 1, power: 7, damage: 1, health: 4),
        Card(id: "N-014", name: "Sasuke Uchiha", type: .exCharacter, color: .blue,
             rarity: .rare, setCode: "01", cost: 3, power: 5, damage: 1, health: 5),
        Card(id: "N-005", name: "Gamabunta", type: .exCharacter, color: .red,
             rarity: .superRare, setCode: "01", cost: 3, power: 6, damage: 1, health: 5),
    ]
}

/// A card-shaped block standing where the board would put a real face.
private struct HologramCardStandIn: View {
    let rect: CGRect
    let colour: CardColor

    var body: some View {
        RoundedRectangle(cornerRadius: Metrics.spacingXS)
            .fill(colour.deepTint)
            .overlay(
                RoundedRectangle(cornerRadius: Metrics.spacingXS)
                    .strokeBorder(Palette.border)
            )
            .frame(width: rect.width, height: rect.height)
            .position(x: rect.midX, y: rect.midY)
    }
}

#Preview("Holograms over the stage") {
    GeometryReader { geo in
        let cards = hologramPreviewCards()
        let width: CGFloat = 74
        let height = width / Metrics.cardAspect

        // A near row and a far row, to show the perspective scale: the far
        // hologram is visibly smaller through the same camera.
        let rects = [
            CGRect(x: geo.size.width * 0.28 - width / 2,
                   y: geo.size.height * 0.62, width: width, height: height),
            CGRect(x: geo.size.width * 0.62 - width / 2,
                   y: geo.size.height * 0.62, width: width, height: height),
            CGRect(x: geo.size.width * 0.45 - width / 2,
                   y: geo.size.height * 0.24, width: width, height: height),
        ]

        ZStack {
            AmbientBackground()
            FieldStage()
            ForEach(rects.indices, id: \.self) { index in
                HologramCardStandIn(rect: rects[index], colour: cards[index].color)
            }
            HologramLayer(candidates: rects.indices.map { index in
                HologramCandidate(
                    id: "preview-\(index)",
                    card: cards[index],
                    anchorRect: rects[index]
                )
            })
        }
    }
    .ignoresSafeArea()
    .environment(CardDatabase(cards: hologramPreviewCards()))
}

#Preview("Rise and collapse") {
    @Previewable @State var isPresented = true

    GeometryReader { geo in
        let card = hologramPreviewCards()[0]
        let width: CGFloat = 90
        let rect = CGRect(
            x: geo.size.width / 2 - width / 2,
            y: geo.size.height * 0.55,
            width: width,
            height: width / Metrics.cardAspect
        )

        ZStack {
            AmbientBackground()
            HologramCardStandIn(rect: rect, colour: card.color)
            HologramProjection(card: card, anchorRect: rect, isPresented: isPresented)

            VStack {
                Spacer()
                Button(isPresented ? "Collapse" : "Project") {
                    isPresented.toggle()
                }
                .font(Typeface.label())
                .padding(Metrics.spacingM)
            }
        }
    }
    .ignoresSafeArea()
    .environment(CardDatabase(cards: hologramPreviewCards()))
}

#Preview("Fitted under a chrome band") {
    GeometryReader { geo in
        let card = hologramPreviewCards()[2]
        let width: CGFloat = 74
        let height = width / Metrics.cardAspect

        // A band of "chrome" sits directly above the card's row, the way the
        // status strip sits against the near Characters row: the left card is
        // unconstrained and stands at full height; the right one is fitted to
        // the region below the band — shrunk toward its card, its beam sunk
        // onto the art panel, and the band's text left untouched.
        let bandBottom = geo.size.height * 0.34
        let region = CGRect(
            x: 0, y: bandBottom + 4,
            width: geo.size.width, height: geo.size.height - bandBottom - 4
        )
        let rects = [
            CGRect(x: geo.size.width * 0.25 - width / 2,
                   y: geo.size.height * 0.62, width: width, height: height),
            CGRect(x: geo.size.width * 0.72 - width / 2,
                   y: bandBottom + 18, width: width, height: height),
        ]

        ZStack {
            AmbientBackground()
            Rectangle()
                .fill(Palette.panel)
                .frame(height: bandBottom)
                .overlay(
                    Text("STATUS BAND — MUST STAY READABLE")
                        .font(Typeface.label(11))
                        .foregroundStyle(Palette.textPrimary)
                )
                .frame(maxHeight: .infinity, alignment: .top)
            ForEach(rects.indices, id: \.self) { index in
                HologramCardStandIn(rect: rects[index], colour: card.color)
            }
            HologramLayer(candidates: [
                HologramCandidate(id: "free", card: card, anchorRect: rects[0]),
                HologramCandidate(id: "fitted", card: card, anchorRect: rects[1], region: region),
            ])
        }
    }
    .ignoresSafeArea()
    .environment(CardDatabase(cards: hologramPreviewCards()))
}

#Preview("Ceiling: five candidates, four projected") {
    GeometryReader { geo in
        let cards = hologramPreviewCards()
        let width: CGFloat = 64
        let height = width / Metrics.cardAspect

        let rects = (0..<5).map { index in
            CGRect(
                x: geo.size.width * (0.12 + 0.19 * CGFloat(index)),
                y: geo.size.height * 0.55 + CGFloat(index % 2) * 40,
                width: width,
                height: height
            )
        }

        ZStack {
            AmbientBackground()
            FieldStage()
            ForEach(rects.indices, id: \.self) { index in
                HologramCardStandIn(rect: rects[index], colour: cards[index % cards.count].color)
            }
            HologramLayer(candidates: rects.indices.map { index in
                HologramCandidate(
                    id: "cap-\(index)",
                    card: cards[index % cards.count],
                    anchorRect: rects[index]
                )
            })
        }
    }
    .ignoresSafeArea()
    .environment(CardDatabase(cards: hologramPreviewCards()))
}
