//
//  SharinganEffect.swift
//  NTCGSimulator
//
//  Shisui's eye, drawn rather than imported. Like the lightning next door it
//  ships no art: an iris is a stack of radial gradients, the tomoe are three
//  copies of one `Path`, and the whole thing scales to any size because nothing
//  in it is a pixel.
//
//  Three pieces of maths hold it up.
//
//  Placement is parametric-on-a-circle: tomoe *i* sits at angle
//  `theta + i * 2pi / count` on a shared orbit of radius `orbit * irisRadius`,
//  at `centre + R * (cos, sin)`. Count and radius are therefore knobs, not a
//  rewrite — three is canon, but the geometry has no opinion.
//
//  Orientation is derived from that placement rather than asserted next to it.
//  A tomoe is a comet: the round head leads and the tapering tail trails. Which
//  way "leads" points is not a matter of taste, it is the derivative of the
//  placement — so `TomoePath.heading(at:)` differentiates the orbit and
//  `TomoePath.facing(at:)` turns that into the shape's own rotation. Nothing in
//  this file writes a bare angle into a transform, because a bare angle is how
//  a tomoe ends up 180 degrees out and nobody can see from the code that it is.
//
//  The spin is genuine angular ACCELERATION, not an eased position. Omega
//  starts at a walking pace and climbs linearly — `omega(t) = omega0 + alpha t`
//  — and the angle is its integral, `omega0 t + alpha t^2 / 2`, in closed form
//  rather than accumulated as `theta += omega * dt` across frames. An
//  accumulator drifts with frame rate, cannot be scrubbed to an arbitrary
//  instant, and makes the still-frame previews impossible. The old profile
//  ramped up, held and eased out, which reads as a machine reaching its set
//  speed; a speed that never stops building reads as something winding up, and
//  it is the build that the reference is actually made of.
//
//  Building speed costs legibility, so the commas grow a motion trail: ghosts
//  of each tomoe laid back along the arc it has just travelled, at decaying
//  opacity. The trail is derived from omega, not from the clock, so it is
//  absent at the start, appears as the eye winds up, and at full speed smears
//  the three commas into one continuous ring. It is also what makes the comet
//  convention *visible* — a lone comma on a still iris is ambiguous, a comma
//  with its own wake is not.
//
//  Everything is bounded. Omega has a ceiling, the trail has a maximum arc (one
//  tomoe spacing, so a ghost can never overtake the next comma) and a maximum
//  sample count, and that count falls again as the device heats up. Reduce
//  Motion keeps the eye, the colour and the fade, and drops the spin, the trail
//  and the pulse: the board still shows whose ability just went off, and
//  nothing rotates or throbs. Low Power Mode takes the identical exit, because
//  a spin the player did not ask for is a poor use of a battery the phone is
//  trying to save. On both paths omega is zero, so the trail costs nothing to
//  switch off — it simply is not there.
//
//  Nothing here blurs and nothing here casts a shadow — the softness is all
//  radial gradients, which the GPU draws in one pass instead of sampling a
//  surface twice. What the eye *did* cost was repetition: iris, fibres, rim and
//  pupil are identical in every frame of the effect, and they were redrawn
//  alongside the tomoe on each one. They are a separate, `Equatable` plate now,
//  so they rasterise once and the animated layer is the comma ring, its ghosts
//  and the catchlight over them.
//

import SwiftUI

// MARK: - Palette

/// The eye's colours. They extend the effect palette rather than `Palette`
/// because, like the arcs, they are light values layered over artwork rather
/// than UI chrome — and they deliberately do not follow the colour scheme: a
/// Sharingan is the same red in a light room.
extension EffectPalette {

    /// The hot band of the iris, a little way out from the pupil.
    static let sharinganIris = Color(UIColor(hex: 0xD8202E))

    /// The iris where it meets the pupil — darker, so the pupil does not sit on
    /// a flat field.
    static let sharinganIrisDeep = Color(UIColor(hex: 0x7A0B14))

    /// The rim around the eye and the shadow the pupil casts into the iris.
    static let sharinganRim = Color(UIColor(hex: 0x2A0308))

    /// Pupil and tomoe. Not pure black — a hair of blue keeps it from looking
    /// like a hole punched in the screen.
    static let sharinganInk = Color(UIColor(hex: 0x0A0206))

    /// The bloom thrown off the eye.
    static let sharinganGlow = Color(UIColor(hex: 0xFF3B4A))

    /// The catchlight on the iris — a cold white, because it is a reflection of
    /// the room rather than part of the eye.
    static let sharinganHighlight = Color(UIColor(hex: 0xFFF2F2))
}

// MARK: - Timing

/// How long the eye runs, and the shape of its fade.
enum SharinganTiming {

    /// Open, wind up, whip away.
    static let duration: Double = 1.5

    /// Fraction of the life spent fading in, and the point the fade-out starts.
    ///
    /// The fade-out is late on purpose. The spin never stops accelerating, so
    /// the fastest, most smeared frames of the effect are its last ones; a
    /// fade that began at three-quarters would dissolve the eye before the
    /// smear it has spent the whole play building ever arrived.
    static let fadeIn: Double = 0.12
    static let fadeOut: Double = 0.82

    /// How long the Reduce Motion still eye takes to appear and to leave.
    static let stillFade: Double = 0.24
}

// MARK: - Spin

/// The angular-velocity profile the tomoe orbit on: constant angular
/// acceleration from a walking start, with a ceiling.
///
/// The motion is described by its *acceleration* and then integrated, rather
/// than by easing a position, because "keeps getting faster" is a statement
/// about `d(omega)/dt` and any position curve that ends flat has, by
/// definition, stopped accelerating. So:
///
///     alpha(t) = alpha                        constant
///     omega(t) = min(omega0 + alpha t, cap)   the integral of alpha
///     theta(t) = omega0 t + alpha t^2 / 2     the integral of omega
///
/// with `t` normalised to 0...1 across the effect's life and angles in radians.
/// Past the cap — if it is ever reached — omega is flat and theta continues
/// linearly from wherever it had got to, which keeps `angle(at:)` continuous
/// across the join instead of stepping.
///
/// `alpha` is solved backwards from the turns asked for, because "three and a
/// bit turns" is a thing that can be art-directed and "thirty-six radians per
/// unit time squared" is not. Integrating the uncapped profile over the full
/// life gives `theta(1) = omega0 + alpha / 2`, so
/// `alpha = 2 * (2pi * revolutions - omega0)`.
///
/// Everything clamps to non-negative. That is not defensive tidying: the tomoe
/// are oriented from the *direction* of travel, and a negative omega would turn
/// every comma tail-first without anything in the drawing code looking wrong.
/// The ring turns one way, forever, and this is where that is enforced.
struct SharinganSpin: Equatable {

    /// How fast the ring is already turning at the instant the eye opens, in
    /// turns per unit of normalised time. Not zero: an eye that starts from a
    /// dead stop spends its first fifth of a second looking like a sticker.
    var initialTurnRate: Double = 0.35

    /// Turns completed over the life of the effect, if the cap never engages.
    /// At the default profile it does not — see `maxAngularVelocity`.
    var revolutions: Double = 3.2

    /// The ceiling on angular velocity, in radians per unit of normalised time.
    ///
    /// A true safety rail rather than part of the art direction: the default
    /// profile peaks at about 38, so the cap is never reached by anything that
    /// ships and the motion the player sees is pure acceleration all the way to
    /// the end. It exists because `revolutions` is a knob, and a knob wired to
    /// an angular velocity wants a stop on it — both so the trail's arc stays
    /// bounded (it is `omega * persistence`) and because past a few turns a
    /// second the ring stops being three commas and becomes a grey annulus.
    static let maxAngularVelocity: Double = 44

    /// Angular velocity at `t = 0`, in radians per unit of normalised time.
    var initialVelocity: Double { 2 * .pi * max(0, initialTurnRate) }

    /// The constant angular acceleration, solved from the turns asked for.
    ///
    /// Clamped at zero so a `revolutions` set below what the starting rate
    /// already delivers coasts rather than braking — this profile accelerates
    /// or holds, and never decelerates.
    var acceleration: Double {
        max(0, 2 * (2 * .pi * max(0, revolutions) - initialVelocity))
    }

    /// The instant omega meets the ceiling, or `infinity` if it never does.
    var saturationTime: Double {
        guard acceleration > 0 else { return .infinity }
        return max(0, (Self.maxAngularVelocity - initialVelocity) / acceleration)
    }

    /// Angular velocity at time `t`, where `t` is 0...1 across the effect.
    func velocity(at t: Double) -> Double {
        let clamped = min(max(t, 0), 1)
        return min(initialVelocity + acceleration * clamped, Self.maxAngularVelocity)
    }

    /// The angle turned by time `t` — the integral of `velocity(at:)`.
    func angle(at t: Double) -> Double {
        let clamped = min(max(t, 0), 1)
        let cap = saturationTime

        // Before the ceiling: the plain quadratic.
        if clamped <= cap {
            return initialVelocity * clamped + acceleration * clamped * clamped / 2
        }

        // After it: whatever had been turned by then, plus a constant rate.
        let atCap = initialVelocity * cap + acceleration * cap * cap / 2
        return atCap + Self.maxAngularVelocity * (clamped - cap)
    }
}

// MARK: - Motion trail

/// The smear that appears as the ring winds up: how far back it reaches, how
/// many ghosts it is made of, and how strongly it registers.
///
/// Derived from omega rather than from the clock, which is what makes it a
/// *motion* trail and not a timed flourish — it is absent while the eye is
/// slow, grows as the eye accelerates, and is simply not there at all on the
/// Reduce Motion and Low Power paths, where omega is zero.
///
/// The arc is `omega * persistence`: a persistence-of-vision window, the same
/// reasoning as a camera's shutter angle. Everything about it is bounded, and
/// the two bounds do different jobs — `maxArc` is about legibility, `maxSamples`
/// about cost.
struct SharinganTrail: Equatable {

    /// How far back along the orbit the smear reaches, in radians.
    var arc: Double

    /// How many ghosts that arc is drawn with.
    var samples: Int

    /// How strongly the whole trail registers, 0...1 — the fade-in that keeps
    /// the first ghost from popping into existence at the onset speed.
    var strength: Double

    // MARK: Tuning

    /// Angular velocity below which there is no trail at all, and the velocity
    /// at which it is at full strength, in radians per unit of normalised time.
    ///
    /// With the default spin the onset lands about a quarter of the way in, so
    /// the eye is unmistakably a set of three commas before it is ever a smear.
    static let onsetVelocity: Double = 12
    static let fullVelocity: Double = 20

    /// The persistence-of-vision window, in units of normalised time.
    ///
    /// Chosen against the default profile: peak omega is about 38, and
    /// `38 * 0.055` is a hair under `2pi / 3`, so at the very fastest frame the
    /// smear reaches almost exactly the next comma's position and the three
    /// tomoe close into one continuous ring — which is the pattern the whole
    /// acceleration is building towards.
    static let persistence: Double = 0.055

    /// How much arc each ghost is worth. Below about this spacing successive
    /// ghosts land on top of each other and cost a draw to change nothing.
    static let radiansPerSample: Double = 0.42

    /// The most ghosts the trail is ever drawn with.
    ///
    /// Five is the ceiling on an already-bounded number: the arc caps at one
    /// tomoe spacing and each ghost is worth `radiansPerSample` of it, so at
    /// three tomoe the arithmetic asks for five and gets five. It is written
    /// down anyway because `tomoeCount` is a knob, and at twelve tomoe the
    /// spacing is small but the *count* of paths in a frame is what matters,
    /// and that is `(samples + 1) * tomoeCount`.
    static let maxSamples = 5

    /// How fast the ghosts fade back along the arc, and how solid the nearest
    /// one is allowed to be.
    ///
    /// The exponent is above 1 so the fall is steepest nearest the comma: a
    /// linear ramp leaves the far ghosts too readable and the ring counts as
    /// eight commas rather than three with a wake. The peak keeps even the
    /// closest ghost visibly lighter than the comma casting it, for the same
    /// reason.
    static let falloff: Double = 1.6
    static let peakOpacity: Double = 0.55

    // MARK: Resolution

    /// The trail for a given angular velocity, or `nil` for no trail at all.
    ///
    /// `ceiling` is the device's own budget — see `ceiling(for:)` — and a
    /// ceiling of zero is a complete answer, not a degenerate one: the ring
    /// still turns, it simply stops leaving a wake.
    static func resolve(velocity: Double, tomoeCount: Int, ceiling: Int) -> SharinganTrail? {
        guard ceiling > 0, velocity > onsetVelocity else { return nil }

        let count = min(max(1, tomoeCount), SharinganGeometry.maxTomoeCount)
        let spacing = 2 * .pi / Double(count)
        let arc = min(velocity * persistence, spacing)
        guard arc > 0 else { return nil }

        let wanted = Int((arc / radiansPerSample).rounded())
        let samples = min(max(1, wanted), min(maxSamples, ceiling))

        return SharinganTrail(
            arc: arc,
            samples: samples,
            strength: Curve.smoothstep(onsetVelocity, fullVelocity, velocity)
        )
    }

    /// How much trail the device can afford right now.
    ///
    /// The thermal ladder is the same one the AI's search budget answers to, so
    /// a phone that is getting warm loses the expensive half of this effect at
    /// the same moment it loses search depth, rather than each subsystem
    /// discovering the heat separately. Critical means no ghosts at all: the
    /// eye is then exactly as cheap as it was before the trail existed.
    static func ceiling(for thermal: ProcessInfo.ThermalState) -> Int {
        switch thermal {
        case .nominal: return maxSamples
        case .fair: return 4
        case .serious: return 2
        case .critical: return 0
        @unknown default: return 2
        }
    }

    /// The angle and opacity of ghost `index`, counting 1 as the one nearest
    /// the comma and `samples` as the furthest back.
    ///
    /// Ghosts lie *behind* the comma, so the offset is subtracted from the
    /// ring's angle — "behind" being the negative heading direction, which is
    /// the same sign convention the tail itself is built on.
    func ghost(_ index: Int, ringAngle: Double) -> (angle: Double, opacity: Double) {
        let steps = max(1, samples)
        let back = arc * Double(index) / Double(steps)
        let remaining = Double(steps + 1 - index) / Double(steps + 1)
        return (ringAngle - back, strength * Self.peakOpacity * pow(remaining, Self.falloff))
    }
}

// MARK: - Geometry

/// Every dimension of the eye, as fractions of the iris radius. Nothing here is
/// a point value, so one struct describes the eye at any size — and tomoe
/// count, orbit and spin can all be retuned without touching a `Path`.
///
/// `Equatable` because the static half of the eye is drawn by a view that skips
/// its own redraw while these figures hold still, which is most of the time.
struct SharinganGeometry: Equatable {

    /// How much of the shorter side of the view the iris spans, edge to edge.
    var eyeFraction: CGFloat = 0.52

    /// Canon is three. The placement maths does not care.
    var tomoeCount: Int = 3

    /// The most commas the ring will place, whatever `tomoeCount` says.
    ///
    /// Twelve is already a daisy rather than an eye, so this is a guard on
    /// arithmetic rather than an art direction: the count is a knob, and a knob
    /// wired to a loop inside a draw call wants a stop on it. It bounds the
    /// trail too — a frame draws at most `(maxSamples + 1) * maxTomoeCount`
    /// commas, which is 72, once, at the hottest instant of the fastest spin.
    static let maxTomoeCount = 12

    /// Orbit radius, as a fraction of the iris radius.
    var orbit: CGFloat = 0.62

    /// The head of a tomoe, as a fraction of the iris radius.
    var headRadius: CGFloat = 0.125

    /// Tail length and tip sweep, in head radii and degrees. The sweep is what
    /// turns a teardrop into a comma: the tip swings toward the pupil instead
    /// of pointing straight back.
    var tailLength: CGFloat = 3.2
    var tailSweep: Double = 18

    /// How far the tail's edges bow inward, in head radii. Bowing both edges by
    /// the same amount curves the tail without thinning it.
    ///
    /// A quadratic's midpoint sits at `(P0 + 2C + P2) / 4`, so shifting both
    /// control points by `curl` bows the tail's centreline by `curl / 2`. The
    /// tail follows the orbit when that bow matches the orbit's sagitta over
    /// the same chord, `L^2 / 8R` — at these defaults, about 0.26 head radii,
    /// which is why the setting is a little over it: enough to read as a hook
    /// rather than as a bent stick.
    var tailCurl: CGFloat = 0.85

    /// Pupil radius and the width of the dark rim, as fractions of the iris.
    var pupilRadius: CGFloat = 0.24
    var rimWidth: CGFloat = 0.075

    /// Faint radial fibres in the iris. Cheap texture — without them the iris
    /// is a flat disc, and a flat disc reads as a sticker.
    var fibreCount: Int = 28

    /// The most fibres the iris will stroke, and how much iris each one needs
    /// to be worth stroking.
    ///
    /// Both halves matter. The ceiling stops a knob from becoming a loop with
    /// no end; the radius rule stops a 40pt eye on a board slot from stroking
    /// twenty-eight hairlines into a circle eighty points around, where they
    /// would land inside a line width of each other and cost a draw to produce
    /// a flat disc anyway. At the canon size — a 100pt iris — the rule allows
    /// fifty and the count asks for twenty-eight, so the eye the player sees is
    /// unchanged.
    static let maxFibreCount = 48
    static let pointsPerFibre: CGFloat = 2

    /// The spin profile.
    var spin = SharinganSpin()

    /// Depth of the iris pulse and how many times it breathes over the life of
    /// the effect. Subtle on purpose: past about 5% it reads as a wobble.
    var pulseDepth: CGFloat = 0.035
    var pulseCycles: Double = 2.5
}

// MARK: - Tomoe path

/// The comma. Built once in a local frame and stamped `tomoeCount` times.
///
/// ## The convention, in one paragraph
///
/// A tomoe is a comet. The filled round head **leads** and the tapering tail
/// **trails behind it**, along the arc the comma has just come from — never
/// ahead of it. That is the whole rule, and everything below exists so it
/// cannot be got wrong by accident.
///
/// ## Which way is forward
///
/// Forward is not a matter of taste, it is a derivative. A tomoe at orbital
/// angle `phi` sits at `centre + R * (cos phi, sin phi)`; differentiating with
/// respect to `phi` gives its velocity, `R * (-sin phi, cos phi)`, whose angle
/// is `phi + pi/2`. The ring only ever turns towards increasing `phi` —
/// `SharinganSpin` clamps omega non-negative precisely so that stays true — so
/// that tangent *is* the direction of travel. In SwiftUI's y-down space
/// increasing `phi` reads as clockwise on screen, but the derivation never
/// needs to know that, which is the point of doing it this way.
///
/// ## The local frame
///
/// `unit(...)` draws the comma with its head centred on the origin and its tail
/// running out along **local -y**. So **local +y is the nose**, the heading, the
/// direction of travel; **local -y is where the tail goes**, because the tail
/// trails; and **local +x is radially outward** from the pupil, which is what
/// lets `tailCurl` bow the tail inward along the orbit by pushing toward -x.
///
/// `facing(at:)` is then the only place the two meet: it rotates the local nose
/// onto the heading. No caller writes a bare angle into a transform, so a tomoe
/// cannot come out 180 degrees round without someone deliberately editing a
/// documented derivation — which is the failure this arrangement is here to
/// prevent, because a reversed comma is perfectly plausible-looking on a still
/// frame and only reads as wrong once it moves.
///
/// ## The outline
///
/// One subpath: the head is a full circle by `addArc`, then the tail leaves the
/// two shoulders — the points where the circle is perpendicular to the tail —
/// as a pair of quadratic curves meeting at the tip. Both subpaths are wound
/// the same way (the tail runs shoulder-B to tip to shoulder-A) so non-zero
/// filling unions them; wound the other way the overlap cancels and the head
/// comes out with a wedge bitten from it.
enum TomoePath {

    /// The direction of travel of a tomoe at orbital angle `phi`, as an angle.
    ///
    /// The tangent to the orbit, `phi + pi/2` — see the type's notes. This is
    /// the single definition of "forward" in the file.
    static func heading(at phi: Double) -> Double { phi + .pi / 2 }

    /// The rotation that puts a unit tomoe's nose on its heading.
    ///
    /// The unit comma's nose is local +y, which lies at angle `pi/2`. Rotating
    /// the local frame by `r` carries that axis to `pi/2 + r`, so aligning it
    /// with `heading(at: phi)` needs `r = heading(at: phi) - pi/2`. That works
    /// out to `phi` — but it is written as the subtraction rather than as the
    /// answer, because the answer alone is indistinguishable from `phi + pi`
    /// to anyone reading it later, and `phi + pi` is exactly the bug.
    static func facing(at phi: Double) -> Double { heading(at: phi) - .pi / 2 }

    /// A tomoe with a head of radius 1 centred on the origin. Scale it to size
    /// with a transform rather than rebuilding it.
    ///
    /// The tail is laid out along -y — behind the nose — and the tip is swung
    /// toward -x, the inward side, by `sweep`.
    static func unit(tailLength: CGFloat, sweep: Double, curl: CGFloat) -> Path {
        let sweepRadians = sweep * .pi / 180

        // Straight back is -y; the sweep swings the tip inward, toward -x.
        let tip = CGPoint(
            x: -tailLength * CGFloat(sin(sweepRadians)),
            y: -tailLength * CGFloat(cos(sweepRadians))
        )

        // Perpendicular to the tail's base direction (0, -1).
        let shoulderA = CGPoint(x: 1, y: 0)
        let shoulderB = CGPoint(x: -1, y: 0)

        // Both control points pushed toward -x, the inward side, by the same
        // amount: the tail bends as a whole instead of tapering unevenly.
        let controlA = CGPoint(x: (shoulderA.x + tip.x) / 2 - curl, y: (shoulderA.y + tip.y) / 2)
        let controlB = CGPoint(x: (shoulderB.x + tip.x) / 2 - curl, y: (shoulderB.y + tip.y) / 2)

        var path = Path()
        path.addArc(
            center: .zero,
            radius: 1,
            startAngle: .zero,
            endAngle: .degrees(360),
            clockwise: false
        )
        path.move(to: shoulderB)
        path.addQuadCurve(to: tip, control: controlB)
        path.addQuadCurve(to: shoulderA, control: controlA)
        path.closeSubpath()
        return path
    }

    /// Every tomoe for one frame, already placed and oriented, as one path.
    ///
    /// Parametric placement: tomoe *i* sits at `angle + i * 2pi / count` on the
    /// orbit, and is turned by `facing(at:)` of that same angle — which is what
    /// keeps every head leading and every tail tangential, however many there
    /// are and wherever the ring has got to.
    static func ring(
        centre: CGPoint,
        irisRadius: CGFloat,
        angle: Double,
        geometry: SharinganGeometry
    ) -> Path {
        let count = min(max(1, geometry.tomoeCount), SharinganGeometry.maxTomoeCount)
        let head = irisRadius * geometry.headRadius
        let orbit = irisRadius * geometry.orbit
        let base = unit(
            tailLength: geometry.tailLength,
            sweep: geometry.tailSweep,
            curl: geometry.tailCurl
        )

        var ring = Path()
        for index in 0..<count {
            let phi = angle + Double(index) * 2 * .pi / Double(count)
            let position = CGPoint(
                x: centre.x + orbit * CGFloat(cos(phi)),
                y: centre.y + orbit * CGFloat(sin(phi))
            )
            // Applied right to left: scale to size, turn the nose onto the
            // heading, then move onto the orbit.
            let transform = CGAffineTransform.identity
                .translatedBy(x: position.x, y: position.y)
                .rotated(by: CGFloat(facing(at: phi)))
                .scaledBy(x: head, y: head)
            ring.addPath(base.applying(transform))
        }
        return ring
    }
}

// MARK: - Frame

/// One still frame of the eye at a normalised progress through its life, with
/// no clock of its own.
///
/// Splitting the frame from the clock is what lets the jutsu overlay drive the
/// eye from the timeline it is already running — one redraw per frame for the
/// whole overlay — and lets a preview point at any instant of the effect.
struct SharinganFrame: View {

    /// 0 at the moment the eye opens, 1 as it finishes closing.
    var progress: Double

    var geometry = SharinganGeometry()

    /// Whether to darken the rest of the screen behind the eye. On by default:
    /// a red iris over a lit board is a shape, and a red iris over a dimmed
    /// board is a stare.
    var dimsBackground: Bool = true

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        GeometryReader { geo in
            let side = min(geo.size.width, geo.size.height) * geometry.eyeFraction
            let radius = side / 2

            ZStack {
                if dimsBackground {
                    vignette(in: geo.size, radius: radius)
                }
                bloom(radius: radius)
                eye(radius: radius)
                    .scaleEffect(openScale * pulseScale)
            }
            .frame(width: geo.size.width, height: geo.size.height)
        }
        .opacity(fade)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    // MARK: Envelope

    /// Global fade: in fast, out over the tail. Squared on the way out so the
    /// eye lingers and then goes, rather than dissolving evenly.
    private var fade: Double {
        let t = min(max(progress, 0), 1)
        let rising = Curve.smoothstep(0, SharinganTiming.fadeIn, t)
        let falling = Curve.smoothstep(SharinganTiming.fadeOut, 1, t)
        return rising * (1 - falling * falling)
    }

    /// Whether the eye should hold perfectly still. Reduce Motion and Low Power
    /// Mode both say so, and the frame answers to both wherever it is driven
    /// from — the jutsu overlay's clock as readily as its own.
    @MainActor
    private var isStill: Bool {
        EffectBudget.current(reduceMotion: reduceMotion).prefersStill
    }

    /// The eye opening: a quick push from just-under to full size. A still eye
    /// holds at full size the whole way through.
    @MainActor
    private var openScale: CGFloat {
        guard !isStill else { return 1 }
        return 0.84 + 0.16 * CGFloat(Curve.smoothstep(0, 0.2, progress))
    }

    /// The breath. A cosine so it starts at the top of the cycle instead of
    /// stepping up from nothing on the first frame.
    @MainActor
    private var pulseScale: CGFloat {
        guard !isStill else { return 1 }
        let phase = progress * geometry.pulseCycles * 2 * .pi
        return 1 + geometry.pulseDepth * CGFloat(cos(phase))
    }

    /// How far round the orbit the commas have turned by now.
    @MainActor
    private var spinAngle: Double {
        isStill ? 0 : geometry.spin.angle(at: progress)
    }

    /// The smear, if the eye is moving fast enough to have earned one and the
    /// device is cool enough to pay for it.
    ///
    /// The still check comes first so the Reduce Motion and Low Power paths
    /// never even ask about thermals — a still eye cannot have a motion trail
    /// no matter how cold the phone is, and the cheap path should be cheap all
    /// the way down rather than cheap only in what it finally draws.
    ///
    /// `DeviceConditions.current` is the process-wide cache the AI's search
    /// budget already keeps fresh off the OS notifications, so reading it per
    /// frame is a lock and two loads rather than a trip to the kernel — and the
    /// effect layer does not have to stand up a second thermal observer to
    /// learn something the app already knows.
    @MainActor
    private var trail: SharinganTrail? {
        guard !isStill else { return nil }
        return SharinganTrail.resolve(
            velocity: geometry.spin.velocity(at: progress),
            tomoeCount: geometry.tomoeCount,
            ceiling: SharinganTrail.ceiling(for: DeviceConditions.current.thermalState)
        )
    }

    // MARK: Layers

    /// Darkens everything but the eye. Drawn as one radial gradient rather than
    /// as a blurred mask: same falloff, no per-frame blur pass.
    private func vignette(in size: CGSize, radius: CGFloat) -> some View {
        RadialGradient(
            colors: [.clear, EffectPalette.outline.opacity(0.72)],
            center: .center,
            startRadius: radius * 0.9,
            endRadius: max(size.width, size.height) * 0.62
        )
    }

    /// The red glow the eye throws. Two stops and a scale, blended additively
    /// so it brightens the board underneath instead of tinting it.
    @MainActor
    private func bloom(radius: CGFloat) -> some View {
        Circle()
            .fill(
                RadialGradient(
                    colors: [EffectPalette.sharinganGlow.opacity(0.5),
                             EffectPalette.sharinganGlow.opacity(0.14),
                             .clear],
                    center: .center,
                    startRadius: 0,
                    endRadius: radius * 1.5
                )
            )
            .frame(width: radius * 3, height: radius * 3)
            .scaleEffect(0.8 + 0.2 * pulseScale)
            .blendMode(.plusLighter)
    }

    /// Iris, fibres, rim, pupil and tomoe — in two canvases, not one.
    ///
    /// It was one, on the reasoning that a single canvas collapses six layers
    /// the compositor would otherwise blend separately into a single pass. That
    /// is true and it is still the reason there are two rather than seven; but
    /// it hid the more expensive fact, which is that four of those six draws are
    /// gradients that are *identical in every frame of the effect*, and putting
    /// them in the same canvas as the tomoe meant re-issuing all four every time
    /// the commas moved a degree.
    ///
    /// So the still half is its own `Equatable` view and rasterises once for the
    /// whole play, and the moving half is the draws that actually move. The
    /// catchlight stays with the tomoe because it sits on top of them and
    /// z-order is not negotiable; one soft gradient a frame is the price of
    /// keeping the eye wet.
    ///
    /// The cost of the split is one extra composited layer — a blit of a region
    /// the size of the iris — against four gradient fills, two strokes and a
    /// fifty-six point path build saved on every frame. It is not close.
    @MainActor
    private func eye(radius: CGFloat) -> some View {
        ZStack {
            IrisPlate(radius: radius, geometry: geometry).equatable()
            TomoeLayer(angle: spinAngle, trail: trail, geometry: geometry)
        }
        .frame(width: radius * 2, height: radius * 2)
    }
}

// MARK: - Still half

/// Iris, fibres, rim and pupil: everything about the eye that does not move.
///
/// `Equatable` on the radius and the geometry, neither of which changes during
/// a play, so SwiftUI draws this once and leaves it alone while the tomoe turn
/// above it.
///
/// The radius is carried as a stored property purely so it is part of that
/// comparison. The canvas reads its real size from layout and would very
/// probably re-render on a rotation without it — but "very probably" is not a
/// thing to leave holding up an eye that would otherwise be frozen at the
/// wrong size, and a `CGFloat` costs nothing to compare.
private struct IrisPlate: View, Equatable {

    /// Half the iris, in points. Not read by the drawing; see above.
    let radius: CGFloat

    let geometry: SharinganGeometry

    var body: some View {
        Canvas(opaque: false, colorMode: .extendedLinear, rendersAsynchronously: false) { context, size in
            let centre = CGPoint(x: size.width / 2, y: size.height / 2)
            let iris = min(size.width, size.height) / 2
            let pupil = iris * geometry.pupilRadius

            drawIris(in: &context, centre: centre, radius: iris)
            drawFibres(in: &context, centre: centre, radius: iris, pupil: pupil)
            drawRim(in: &context, centre: centre, radius: iris)
            drawPupil(in: &context, centre: centre, radius: iris, pupil: pupil)
        }
    }

    private func drawIris(in context: inout GraphicsContext, centre: CGPoint, radius: CGFloat) {
        let disc = Path(ellipseIn: CGRect(
            x: centre.x - radius, y: centre.y - radius,
            width: radius * 2, height: radius * 2
        ))
        // Hot a little way out from the pupil and deep at both ends: the eye
        // reads as curved rather than as a flat swatch.
        context.fill(
            disc,
            with: .radialGradient(
                Gradient(stops: [
                    .init(color: EffectPalette.sharinganIrisDeep, location: 0),
                    .init(color: EffectPalette.sharinganIris, location: 0.55),
                    .init(color: EffectPalette.sharinganIrisDeep, location: 0.88),
                    .init(color: EffectPalette.sharinganRim, location: 1)
                ]),
                center: centre,
                startRadius: 0,
                endRadius: radius
            )
        )
    }

    private func drawFibres(
        in context: inout GraphicsContext,
        centre: CGPoint,
        radius: CGFloat,
        pupil: CGFloat
    ) {
        // Capped absolutely, and again by how much iris there is to stroke
        // them into — see `SharinganGeometry.maxFibreCount`.
        let byRadius = Int(radius / SharinganGeometry.pointsPerFibre)
        let count = min(geometry.fibreCount, min(SharinganGeometry.maxFibreCount, byRadius))
        guard count > 0 else { return }

        var fibres = Path()
        for index in 0..<count {
            let phi = Double(index) * 2 * .pi / Double(count)
            let direction = CGPoint(x: CGFloat(cos(phi)), y: CGFloat(sin(phi)))
            fibres.move(to: CGPoint(
                x: centre.x + direction.x * pupil * 1.05,
                y: centre.y + direction.y * pupil * 1.05
            ))
            fibres.addLine(to: CGPoint(
                x: centre.x + direction.x * radius * 0.96,
                y: centre.y + direction.y * radius * 0.96
            ))
        }
        context.stroke(
            fibres,
            with: .color(EffectPalette.sharinganRim.opacity(0.3)),
            style: StrokeStyle(lineWidth: max(0.5, radius * 0.012), lineCap: .round)
        )
    }

    private func drawRim(in context: inout GraphicsContext, centre: CGPoint, radius: CGFloat) {
        let width = radius * geometry.rimWidth
        let inset = radius - width / 2
        let ring = Path(ellipseIn: CGRect(
            x: centre.x - inset, y: centre.y - inset,
            width: inset * 2, height: inset * 2
        ))
        context.stroke(
            ring,
            with: .color(EffectPalette.sharinganRim),
            style: StrokeStyle(lineWidth: width)
        )
    }

    private func drawPupil(
        in context: inout GraphicsContext,
        centre: CGPoint,
        radius: CGFloat,
        pupil: CGFloat
    ) {
        // A soft shadow first, so the pupil is set into the iris rather than
        // laid on top of it.
        let shadowRadius = pupil * 1.8
        context.fill(
            Path(ellipseIn: CGRect(
                x: centre.x - shadowRadius, y: centre.y - shadowRadius,
                width: shadowRadius * 2, height: shadowRadius * 2
            )),
            with: .radialGradient(
                Gradient(colors: [EffectPalette.sharinganRim.opacity(0.85), .clear]),
                center: centre,
                startRadius: pupil * 0.85,
                endRadius: shadowRadius
            )
        )
        context.fill(
            Path(ellipseIn: CGRect(
                x: centre.x - pupil, y: centre.y - pupil,
                width: pupil * 2, height: pupil * 2
            )),
            with: .color(EffectPalette.sharinganInk)
        )
    }
}

// MARK: - Moving half

/// The comma ring, its motion trail and the catchlight over them — the only
/// draws in the eye that change from one frame to the next.
///
/// Not `Equatable`: `angle` moves on every frame, which is the whole point of
/// the layer. Keeping it to a bounded handful of fills is what makes that
/// affordable — one ring, at most `SharinganTrail.maxSamples` ghosts behind it,
/// and one gradient, with the ghost count falling to zero on a hot or
/// conserving device.
private struct TomoeLayer: View {

    /// How far round the orbit the commas have turned.
    let angle: Double

    /// The smear behind them, or `nil` when the ring is too slow to have one.
    let trail: SharinganTrail?

    let geometry: SharinganGeometry

    var body: some View {
        Canvas(opaque: false, colorMode: .extendedLinear, rendersAsynchronously: false) { context, size in
            let centre = CGPoint(x: size.width / 2, y: size.height / 2)
            let iris = min(size.width, size.height) / 2

            drawTrail(in: &context, centre: centre, radius: iris)

            context.fill(
                TomoePath.ring(
                    centre: centre,
                    irisRadius: iris,
                    angle: angle,
                    geometry: geometry
                ),
                with: .color(EffectPalette.sharinganInk)
            )

            drawHighlight(in: &context, centre: centre, radius: iris)
        }
    }

    /// The ghosts, furthest back first so the nearest ones land on top and the
    /// smear reads as fading away from the comma rather than towards it.
    private func drawTrail(in context: inout GraphicsContext, centre: CGPoint, radius: CGFloat) {
        guard let trail else { return }

        for index in stride(from: trail.samples, through: 1, by: -1) {
            let ghost = trail.ghost(index, ringAngle: angle)
            context.fill(
                TomoePath.ring(
                    centre: centre,
                    irisRadius: radius,
                    angle: ghost.angle,
                    geometry: geometry
                ),
                with: .color(EffectPalette.sharinganInk.opacity(ghost.opacity))
            )
        }
    }

    /// The wet catchlight. One soft off-centre ellipse, and the eye stops being
    /// a diagram.
    private func drawHighlight(in context: inout GraphicsContext, centre: CGPoint, radius: CGFloat) {
        let size = radius * 0.42
        let rect = CGRect(
            x: centre.x - radius * 0.52,
            y: centre.y - radius * 0.62,
            width: size,
            height: size * 0.72
        )
        context.fill(
            Path(ellipseIn: rect),
            with: .radialGradient(
                Gradient(colors: [EffectPalette.sharinganHighlight.opacity(0.35), .clear]),
                center: CGPoint(x: rect.midX, y: rect.midY),
                startRadius: 0,
                endRadius: size * 0.6
            )
        )
    }
}

/// The one easing curve the eye needs. A private twin of the jutsu overlay's,
/// so neither file has to be imported into the other to fade something.
private enum Curve {

    /// Hermite ease between two thresholds: flat 0 below `from`, flat 1 above
    /// `to`, no corner at either end.
    static func smoothstep(_ from: Double, _ to: Double, _ t: Double) -> Double {
        guard to > from else { return t >= to ? 1 : 0 }
        let x = min(max((t - from) / (to - from), 0), 1)
        return x * x * (3 - 2 * x)
    }
}

// MARK: - Self-running effect

/// The eye with a clock: opens, winds up, whips away, and reports back. Drop it
/// in an overlay and forget about it until `onFinished` arrives.
///
/// It is what the board plays through `JutsuEffectView(effect: .sharingan)`;
/// this type exists on its own so the eye can also be shown outside the jutsu
/// pipeline — and so it can be judged in a preview without a game running.
///
/// The clock starts when the view is installed, so give each play its own
/// identity if two run back to back in the same slot.
///
/// The clock is `.periodic` rather than `.animation`, because `.animation`
/// follows the display and would turn the eye a hundred and twenty times a
/// second to show a spin that is perfectly legible at sixty. Sixty is the
/// ceiling here rather than the thirty the arcs get: a rotation is continuous
/// where a discharge is discrete. It is also why the trail exists — at the top
/// of the acceleration the ring turns about thirty-six degrees between frames,
/// and a comma that jumps that far reads as sampled unless something bridges
/// the gap. The ghosts are that bridge, and they are cheapest exactly when the
/// eye is slow enough not to need them.
struct SharinganEffectView: View {
    var geometry = SharinganGeometry()
    var duration: Double = SharinganTiming.duration
    var dimsBackground: Bool = true
    let onFinished: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Captured when the view is installed; every frame is measured from it.
    @State private var began = Date.now

    /// Still eye only — its fade.
    @State private var isShowing = false

    /// What the player and the battery have asked of this effect. `play()`
    /// reads the same property, because the still eye is faded in by
    /// `isShowing` and would otherwise be mounted invisible.
    @MainActor
    private var budget: EffectBudget {
        EffectBudget.current(reduceMotion: reduceMotion)
    }

    var body: some View {
        Group {
            if budget.prefersStill {
                // Held at the instant the eye is fully open, faded by the
                // system's own animation instead of by the timeline.
                SharinganFrame(progress: 0.4, geometry: geometry, dimsBackground: dimsBackground)
                    .opacity(isShowing ? 1 : 0)
            } else {
                TimelineView(.periodic(from: began, by: 1 / EffectMetrics.maxFrameRate)) { context in
                    SharinganFrame(
                        progress: context.date.timeIntervalSince(began) / max(0.1, duration),
                        geometry: geometry,
                        dimsBackground: dimsBackground
                    )
                }
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
        .task { await play() }
    }

    /// Runs the effect's lifetime. A cancelled sleep reports nothing: the
    /// caller tore the effect down itself, so there is nothing to report.
    @MainActor
    private func play() async {
        began = .now

        // Captured once, so a setting toggled mid-play cannot leave a still eye
        // that was never faded in.
        let isStill = budget.prefersStill

        if isStill {
            withAnimation(.easeOut(duration: SharinganTiming.stillFade)) { isShowing = true }
        }

        do {
            try await Task.sleep(for: .seconds(duration))
        } catch {
            return
        }

        if isStill {
            withAnimation(.easeIn(duration: SharinganTiming.stillFade)) { isShowing = false }
            do {
                try await Task.sleep(for: .seconds(SharinganTiming.stillFade))
            } catch {
                return
            }
        }

        onFinished()
    }
}

// MARK: - Orientation proof

/// A tomoe ring with its orbit drawn and an arrow on every comma pointing the
/// way that comma is travelling — the comet convention, made checkable.
///
/// It exists for the previews rather than for the game. The head-leads rule is
/// invisible on a still frame, which is exactly why it was worth getting wrong;
/// this draws the derivative that defines it next to the shape that obeys it,
/// so a later edit that reverses either can be seen to be wrong in a second
/// without launching a game or trusting a comment.
private struct TomoeHeadingProof: View {

    var geometry = SharinganGeometry()

    /// Where the ring has turned to, in radians.
    var angle: Double = 0

    var body: some View {
        Canvas(opaque: false, colorMode: .extendedLinear, rendersAsynchronously: false) { context, size in
            let centre = CGPoint(x: size.width / 2, y: size.height / 2)
            let iris = min(size.width, size.height) / 2 * 0.86
            let orbit = iris * geometry.orbit

            drawOrbit(in: &context, centre: centre, orbit: orbit)

            context.fill(
                TomoePath.ring(centre: centre, irisRadius: iris, angle: angle, geometry: geometry),
                with: .color(EffectPalette.sharinganInk)
            )

            drawHeadings(in: &context, centre: centre, iris: iris, orbit: orbit)
        }
    }

    private func drawOrbit(in context: inout GraphicsContext, centre: CGPoint, orbit: CGFloat) {
        context.stroke(
            Path(ellipseIn: CGRect(
                x: centre.x - orbit, y: centre.y - orbit,
                width: orbit * 2, height: orbit * 2
            )),
            with: .color(Palette.textSecondary.opacity(0.35)),
            style: StrokeStyle(lineWidth: 1, dash: [3, 4])
        )
    }

    /// One arrow per comma, laid on the heading and starting at the head, so
    /// the arrow leaves the nose and the tail goes the other way.
    private func drawHeadings(
        in context: inout GraphicsContext,
        centre: CGPoint,
        iris: CGFloat,
        orbit: CGFloat
    ) {
        let count = min(max(1, geometry.tomoeCount), SharinganGeometry.maxTomoeCount)
        let length = iris * 0.3
        let barb = iris * 0.075

        var arrows = Path()
        for index in 0..<count {
            let phi = angle + Double(index) * 2 * .pi / Double(count)
            let heading = TomoePath.heading(at: phi)
            let forward = CGPoint(x: CGFloat(cos(heading)), y: CGFloat(sin(heading)))
            let side = CGPoint(x: -forward.y, y: forward.x)

            let root = CGPoint(
                x: centre.x + orbit * CGFloat(cos(phi)) + forward.x * iris * 0.16,
                y: centre.y + orbit * CGFloat(sin(phi)) + forward.y * iris * 0.16
            )
            let tip = CGPoint(x: root.x + forward.x * length, y: root.y + forward.y * length)

            arrows.move(to: root)
            arrows.addLine(to: tip)
            arrows.move(to: CGPoint(x: tip.x - forward.x * barb + side.x * barb,
                                    y: tip.y - forward.y * barb + side.y * barb))
            arrows.addLine(to: tip)
            arrows.addLine(to: CGPoint(x: tip.x - forward.x * barb - side.x * barb,
                                       y: tip.y - forward.y * barb - side.y * barb))
        }

        context.stroke(
            arrows,
            with: .color(Palette.accent),
            style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round)
        )
    }
}

// MARK: - Previews

#Preview("Sharingan, looping") {
    @Previewable @State var plays = 0

    ZStack {
        AmbientBackground()

        RoundedRectangle(cornerRadius: 6)
            .fill(CardColor.red.deepTint)
            .frame(width: 150, height: 150 / Metrics.cardAspect)

        SharinganEffectView { plays += 1 }
            .id(plays)

        VStack {
            Spacer()
            Text("Play \(plays + 1)").sectionLabel()
        }
        .padding(Metrics.spacingL)
    }
    .ignoresSafeArea()
}

#Preview("Orientation: heads lead") {
    let spin = SharinganSpin()
    let stops: [Double] = [0, 0.25, 0.5, 0.75]

    ScrollView {
        VStack(alignment: .leading, spacing: Metrics.spacingM) {
            Text("Arrow = direction of travel, from the orbit's derivative")
                .sectionLabel()

            LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: Metrics.spacingM)],
                      spacing: Metrics.spacingM) {
                ForEach(stops, id: \.self) { stop in
                    VStack(spacing: Metrics.spacingXS) {
                        TomoeHeadingProof(angle: spin.angle(at: stop))
                            .frame(width: 150, height: 150)
                            .notchedPanel(notch: 8, fill: Palette.panel.opacity(0.6))

                        Text(String(format: "t %.2f", stop)).sectionLabel()
                    }
                }
            }

            Text("Every round head sits ahead of its own tail along the arrow. "
                 + "A comma pointing the other way is the bug this preview exists to catch.")
                .font(Typeface.body(13))
                .foregroundStyle(Palette.textSecondary)
        }
        .padding(Metrics.spacingL)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .background(AmbientBackground())
}

#Preview("Acceleration and smear") {
    let steps: [Double] = [0.0, 0.14, 0.28, 0.42, 0.56, 0.70, 0.84, 0.96]
    let spin = SharinganSpin()

    ScrollView {
        VStack(alignment: .leading, spacing: Metrics.spacingM) {
            Text("The trail appears only once omega passes the onset")
                .sectionLabel()

            LazyVGrid(columns: [GridItem(.adaptive(minimum: 110), spacing: Metrics.spacingS)],
                      spacing: Metrics.spacingS) {
                ForEach(steps, id: \.self) { step in
                    VStack(spacing: Metrics.spacingXS) {
                        SharinganFrame(progress: step, dimsBackground: false)
                            .frame(width: 110, height: 110)
                            .background(Palette.surface.opacity(0.5))

                        Text(String(format: "%.2f", step)).sectionLabel()
                        Text(String(format: "w %.0f", spin.velocity(at: step)))
                            .font(Typeface.body(11))
                            .foregroundStyle(Palette.textSecondary)
                    }
                }
            }

            Text(String(
                format: "omega0 %.1f, alpha %.1f, peak %.1f rad per unit time — %.1f turns",
                spin.initialVelocity,
                spin.acceleration,
                spin.velocity(at: 1),
                spin.angle(at: 1) / (2 * .pi)
            ))
            .font(Typeface.body(13))
            .foregroundStyle(Palette.textSecondary)
        }
        .padding(Metrics.spacingL)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .background(AmbientBackground())
}

#Preview("Spin profile") {
    let spin = SharinganSpin()
    let samples = stride(from: 0.0, through: 1.0, by: 0.02).map { $0 }

    VStack(alignment: .leading, spacing: Metrics.spacingM) {
        Text("Angular velocity and angle against time").sectionLabel()

        Canvas { context, size in
            let peak = max(0.001, spin.velocity(at: 1))
            let total = max(0.001, spin.angle(at: 1))

            var velocity = Path()
            var angle = Path()
            for (index, t) in samples.enumerated() {
                let x = size.width * CGFloat(t)
                let v = CGPoint(x: x, y: size.height * (1 - CGFloat(spin.velocity(at: t) / peak)))
                let a = CGPoint(x: x, y: size.height * (1 - CGFloat(spin.angle(at: t) / total)))
                if index == 0 {
                    velocity.move(to: v)
                    angle.move(to: a)
                } else {
                    velocity.addLine(to: v)
                    angle.addLine(to: a)
                }
            }
            context.stroke(angle, with: .color(Palette.textSecondary), lineWidth: 1.5)
            context.stroke(velocity, with: .color(Palette.accent), lineWidth: 2.5)
        }
        .frame(height: 170)
        .notchedPanel(notch: 8, fill: Palette.panel.opacity(0.6))

        Text("Accent: omega, a straight line climbing to the last frame — the "
             + "motion never stops building. Grey: the angle, its integral, a "
             + "parabola. Neither ever flattens, which is the difference from "
             + "an ease-out.")
            .font(Typeface.body(13))
            .foregroundStyle(Palette.textSecondary)
    }
    .padding(Metrics.spacingL)
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .background(AmbientBackground())
}

#Preview("Geometry knobs") {
    let variants: [(String, SharinganGeometry)] = [
        ("Canon", SharinganGeometry()),
        ("Six tomoe", {
            var geometry = SharinganGeometry()
            geometry.tomoeCount = 6
            geometry.headRadius = 0.1
            return geometry
        }()),
        ("Wide orbit", {
            var geometry = SharinganGeometry()
            geometry.orbit = 0.76
            geometry.pupilRadius = 0.18
            return geometry
        }()),
        ("Long tails", {
            var geometry = SharinganGeometry()
            geometry.tailLength = 5
            geometry.tailCurl = 1.1
            geometry.tailSweep = 46
            return geometry
        }())
    ]

    ScrollView {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 140), spacing: Metrics.spacingM)],
                  spacing: Metrics.spacingM) {
            ForEach(variants, id: \.0) { variant in
                VStack(spacing: Metrics.spacingXS) {
                    SharinganFrame(progress: 0.7, geometry: variant.1, dimsBackground: false)
                        .frame(width: 140, height: 140)

                    Text(variant.0).sectionLabel()
                }
            }
        }
        .padding(Metrics.spacingL)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .background(AmbientBackground())
}
