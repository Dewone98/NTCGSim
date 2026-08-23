//
//  SharinganEffect.swift
//  NTCGSimulator
//
//  Shisui's eye, drawn rather than imported. Like the lightning next door it
//  ships no art: an iris is a stack of radial gradients, the tomoe are three
//  copies of one `Path`, and the whole thing scales to any size because nothing
//  in it is a pixel.
//
//  Two pieces of maths hold it up.
//
//  Placement is parametric-on-a-circle: tomoe *i* sits at angle
//  `theta + i * 2pi / count` on a shared orbit of radius `orbit * irisRadius`,
//  at `centre + R * (cos, sin)`. Count and radius are therefore knobs, not a
//  rewrite — three is canon, but the geometry has no opinion.
//
//  The spin is a *trapezoidal angular-velocity profile*: omega ramps from 0 to
//  its peak, holds, then falls back to 0. The angle is the integral of that
//  profile, worked out in closed form per phase (see `SharinganSpin`) rather
//  than accumulated as `theta += omega * dt` across frames — an accumulator
//  drifts with frame rate, cannot be scrubbed to an arbitrary instant, and
//  makes the still-frame previews impossible. A constant spin would read as a
//  loading indicator; starting fast and settling is what makes it read as an
//  eye that just woke up.
//
//  Reduce Motion keeps the eye, the colour and the fade, and drops the spin and
//  the pulse: the board still shows whose ability just went off, and nothing
//  rotates or throbs. Low Power Mode takes the identical exit, because a spin
//  the player did not ask for is a poor use of a battery the phone is trying to
//  save.
//
//  Nothing here blurs and nothing here casts a shadow — the softness is all
//  radial gradients, which the GPU draws in one pass instead of sampling a
//  surface twice. What the eye *did* cost was repetition: iris, fibres, rim and
//  pupil are identical in every frame of the effect, and they were redrawn
//  alongside the tomoe on each one. They are a separate, `Equatable` plate now,
//  so they rasterise once and the animated layer is two draws — the comma ring
//  and the catchlight over it. The spin then rides on a `scaleEffect` and a
//  transform, which are the cheap properties.
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

    /// Open, spin, settle, close.
    static let duration: Double = 1.5

    /// Fraction of the life spent fading in, and the point the fade-out starts.
    static let fadeIn: Double = 0.12
    static let fadeOut: Double = 0.76

    /// How long the Reduce Motion still eye takes to appear and to leave.
    static let stillFade: Double = 0.24
}

// MARK: - Spin

/// The angular-velocity profile the tomoe orbit on.
///
/// `omega(t)` is a trapezoid: a linear ramp up over `rampUp`, a flat hold, then
/// a linear ramp down over `rampDown` — constant deceleration, which is what an
/// ease-out *is*. Integrating each phase gives the angle in closed form:
///
///     phase 1, t < a:      theta = peak * t^2 / 2a
///     phase 2, a <= t < b: theta = peak * (a/2 + (t - a))
///     phase 3, t >= b:     theta = theta(b) + peak * ((t-b) - (t-b)^2 / 2c)
///
/// with `b = 1 - c`. The total sweep is `peak * (1 - a/2 - c/2)`, so `peak` is
/// solved backwards from the number of revolutions asked for — the caller says
/// how far it turns, not how fast, because "two and a bit turns" is a thing you
/// can art-direct and "eleven radians a second" is not.
struct SharinganSpin: Equatable {

    /// Total turns over the life of the effect.
    var revolutions: Double = 2.4

    /// Fraction of the life spent getting up to speed. Short: the eye snaps on.
    var rampUp: Double = 0.16

    /// Fraction spent slowing down. Long, because the settle is the part that
    /// reads as deliberate rather than mechanical.
    var rampDown: Double = 0.44

    /// Peak angular velocity, in radians per unit of normalised time.
    var peak: Double {
        let a = min(max(rampUp, 0), 1)
        let c = min(max(rampDown, 0), 1 - a)
        let area = max(0.05, 1 - a / 2 - c / 2)
        return revolutions * 2 * .pi / area
    }

    /// The angle turned by time `t`, where `t` is 0...1 across the effect.
    func angle(at t: Double) -> Double {
        let clamped = min(max(t, 0), 1)
        let a = max(0.0001, min(max(rampUp, 0), 1))
        let c = max(0.0001, min(max(rampDown, 0), 1 - a))
        let b = 1 - c
        let omega = peak

        if clamped < a {
            return omega * clamped * clamped / (2 * a)
        }
        let upSweep = omega * a / 2
        if clamped < b {
            return upSweep + omega * (clamped - a)
        }
        let tail = clamped - b
        return upSweep + omega * (b - a) + omega * (tail - tail * tail / (2 * c))
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
    /// wired to a loop inside a draw call wants a stop on it.
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
    /// the same chord, `L^2 / 8R` — at these defaults, about 0.2 head radii,
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
/// The local frame is chosen so placement is a single rotation: **+x is
/// radially outward** from the pupil and **-y is the trailing direction**, so a
/// tomoe drawn here and rotated by its orbital angle already has its tail
/// behind it and its curl hooking inward.
///
/// The outline is one subpath: the head is a full circle by `addArc`, then the
/// tail leaves the two shoulders — the points where the circle is perpendicular
/// to the tail — as a pair of quadratic curves meeting at the tip. Both
/// subpaths are wound the same way (the tail runs shoulder-B to tip to
/// shoulder-A) so non-zero filling unions them; wound the other way the overlap
/// cancels and the head comes out with a bite missing.
enum TomoePath {

    /// A tomoe with a head of radius 1 centred on the origin. Scale it to size
    /// with a transform rather than rebuilding it.
    static func unit(tailLength: CGFloat, sweep: Double, curl: CGFloat) -> Path {
        let sweepRadians = sweep * .pi / 180
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
    /// orbit, and is rotated by that same angle — which is what keeps the tails
    /// tangential however many there are.
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
            // Applied right to left: scale to size, turn to face the orbit,
            // then move onto it.
            let transform = CGAffineTransform.identity
                .translatedBy(x: position.x, y: position.y)
                .rotated(by: CGFloat(phi))
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

    @MainActor
    private var spinAngle: Double {
        isStill ? 0 : geometry.spin.angle(at: progress)
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
    /// whole play, and the moving half is the two draws that actually move. The
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
            TomoeLayer(angle: spinAngle, geometry: geometry)
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

/// The comma ring and the catchlight over it — the only two draws in the eye
/// that change from one frame to the next.
///
/// Not `Equatable`: `angle` moves on every frame, which is the whole point of
/// the layer. Keeping it to two draws is what makes that affordable.
private struct TomoeLayer: View {

    /// How far round the orbit the commas have turned.
    let angle: Double

    let geometry: SharinganGeometry

    var body: some View {
        Canvas(opaque: false, colorMode: .extendedLinear, rendersAsynchronously: false) { context, size in
            let centre = CGPoint(x: size.width / 2, y: size.height / 2)
            let iris = min(size.width, size.height) / 2

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

/// The eye with a clock: opens, spins up, settles, closes, and reports back.
/// Drop it in an overlay and forget about it until `onFinished` arrives.
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
/// where a discharge is discrete, and at thirty the commas step fourteen
/// degrees at a time and start to read as sampled.
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

#Preview("Sharingan, frame by frame") {
    let steps: [Double] = [0.0, 0.08, 0.2, 0.35, 0.5, 0.65, 0.85, 0.97]

    ScrollView {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 110), spacing: Metrics.spacingS)],
                  spacing: Metrics.spacingS) {
            ForEach(steps, id: \.self) { step in
                VStack(spacing: Metrics.spacingXS) {
                    SharinganFrame(progress: step, dimsBackground: false)
                        .frame(width: 110, height: 110)
                        .background(Palette.surface.opacity(0.5))

                    Text(String(format: "%.2f", step)).sectionLabel()
                }
            }
        }
        .padding(Metrics.spacingL)
    }
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
                    SharinganFrame(progress: 0.4, geometry: variant.1, dimsBackground: false)
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

#Preview("Spin profile") {
    let spin = SharinganSpin()
    let samples = stride(from: 0.0, through: 1.0, by: 0.05).map { $0 }

    VStack(alignment: .leading, spacing: Metrics.spacingM) {
        Text("Turns completed against time").sectionLabel()

        Canvas { context, size in
            let total = max(0.001, spin.angle(at: 1))
            var path = Path()
            for (index, t) in samples.enumerated() {
                let point = CGPoint(
                    x: size.width * CGFloat(t),
                    y: size.height * (1 - CGFloat(spin.angle(at: t) / total))
                )
                if index == 0 { path.move(to: point) } else { path.addLine(to: point) }
            }
            context.stroke(path, with: .color(Palette.accent), lineWidth: 2)
        }
        .frame(height: 160)
        .notchedPanel(notch: 8, fill: Palette.panel.opacity(0.6))

        Text("Steep at the start, flat at the end — fast then settling")
            .font(Typeface.body(13))
            .foregroundStyle(Palette.textSecondary)
    }
    .padding(Metrics.spacingL)
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .background(AmbientBackground())
}
