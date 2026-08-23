//
//  LightningEffect.swift
//  NTCGSimulator
//
//  Electricity, drawn rather than filmed. The simulator ships no video and no
//  image assets, so every arc on the board is generated here: a polyline built
//  by midpoint displacement — subdivide, push each new midpoint sideways, halve
//  the push at every level — then branched a couple of generations deep and
//  stroked three times over. The three strokes are the whole trick. A wide
//  blurred halo, a saturated body and a thin near-white core read as a light
//  source; one stroke of one colour reads as a scribble.
//
//  The geometry is deterministic for a given seed, so a bolt is stable across
//  redraws and can be regenerated instead of stored. Motion comes from
//  re-seeding a dozen or so times a second rather than from tweening, because
//  electricity jumps rather than glides — and because a bolt that is stable
//  between ticks lets the renderer sit idle in between. Reduce Motion drops the
//  timeline entirely and leaves a static glow standing in for the arc.
//
//  `LightningBurst` is the screen-scale version: several *planes* of arcs, each
//  with its own thickness, brightness and reach, drawn by one `Canvas` in one
//  pass. Depth in a drawing of light comes from thin-and-dim behind thick-and-
//  hot, and from only the front planes carrying a halo — a flat scribble is what
//  you get when every arc is the same weight. Doing it inside a single canvas
//  rather than by stacking views is what keeps the cost down: N planes cost N
//  cheap polyline passes and at most a couple of blurs, not N layers for the
//  compositor to blend.
//
//  Everything here is drawn on a phone that is held in a hand, so every knob a
//  caller can turn has a ceiling above it — bolt count, branch depth,
//  subdivision passes, strands per plane, planes per burst, and the rate any of
//  it may tick at. They live together under "Cost ceilings" in `EffectMetrics`
//  with the arithmetic that produced them. None of them fires on anything that
//  ships; they are there because the alternative to a cap is an unbounded loop
//  inside a draw call, and the device that finds the unbounded case is the
//  owner's.
//

import SwiftUI

// MARK: - Effect palette

/// Colour tokens for the effect layer. They live beside the effects instead of
/// in `Palette` because nothing else in the app draws with them, and they are
/// deliberately hotter than the UI tokens: an arc has to read as a light source
/// lying on top of card artwork, not as another piece of chrome.
enum EffectPalette {

    /// The body of an electric arc.
    static let electric = Palette.adaptive(dark: 0x6FC6FF, light: 0x2C88EA)

    /// The white-hot centre line running down an arc.
    static let electricCore = Palette.adaptive(dark: 0xF4FBFF, light: 0xFFFFFF)

    /// The halo around a gathered ball of chakra — bluer and darker than the
    /// arc itself, so the ball has depth behind the sparks.
    static let electricHalo = Palette.adaptive(dark: 0x3F76FF, light: 0x2E5FD6)

    /// The outline drawn behind floating combat numbers. Effects land on top of
    /// artwork of any brightness, so the outline stays dark in both appearances
    /// rather than following the scheme.
    static let outline = Palette.adaptive(dark: 0x080510, light: 0x14101A)
}

// MARK: - Effect metrics

/// Sizing and timing constants for the effect layer.
enum EffectMetrics {

    /// Width of an arc's saturated body, before the per-generation falloff.
    static let boltWidth: CGFloat = 2.2

    /// Blur radius of the halo pass.
    static let glowRadius: CGFloat = 7

    /// Subdivision passes. Each one doubles the segment count, so 4 levels is a
    /// sixteen-segment arc — enough to look torn, cheap enough to regenerate
    /// every tick.
    static let boltLevels = 4

    /// How far a midpoint may be pushed off its segment at the first level, as
    /// a fraction of the arc's span. Much under this and the arc reads as a
    /// bent wire rather than as a discharge tearing through the air.
    static let trunkJitter: CGFloat = 0.18

    /// Re-seeds per second. Below about ten the arc reads as a slideshow;
    /// above twenty the eye stops resolving individual shapes.
    static let flickerRate: Double = 14

    /// How much dimmer and thinner each branch generation is than its parent.
    static let branchFalloff = 0.6
    static let branchWidthFalloff = 0.68

    /// Probability that a candidate fork actually spawns, at the first
    /// generation. Each generation multiplies by it again, so a bolt sheds
    /// branches quickly at the trunk and rarely deep in: 0.8 → 0.64 → 0.51.
    ///
    /// Below about 0.5 the arc reads as a bent wire; at 1 every candidate
    /// always forks and the bolt turns into a bush, which is what makes a
    /// discharge look like a plant rather than like light.
    static let branchChance: Double = 0.8

    /// How far past the edge of the view a screen-spanning bolt starts and
    /// ends, as a fraction of the span. A bolt that stops exactly on the edge
    /// reads as a line someone drew; one that runs off the edge reads as part
    /// of something bigger than the screen.
    static let edgeOvershoot: CGFloat = 0.06

    // MARK: Cost ceilings

    /// The fastest any effect timeline is allowed to tick, in frames a second.
    ///
    /// `TimelineView(.animation)` redraws at the *display's* rate, which is
    /// 120Hz on a ProMotion iPhone. Nothing drawn in this folder has 120
    /// distinct states a second to show: an arc re-seeds at `flickerRate` and
    /// everything else is a gradient sliding. The other sixty frames are heat
    /// and nothing else, and heat is the one thing a phone in a hand cannot
    /// hide.
    ///
    /// Sixty is the ceiling rather than thirty because a shot crossing the mat
    /// covers the board in half a second, and thirty frames of that reads as a
    /// strobe. Layers whose content is genuinely discrete — every arc canvas —
    /// are capped far lower again, at their own flicker rate.
    static let maxFrameRate: Double = 60

    /// The most bolts one plane may carry, whatever a caller asks for.
    ///
    /// Sixteen is the most anything in the app actually asks for — the
    /// chidori's back plane, at twice `chidoriDensity` — so this is headroom
    /// and not a clamp that fires in practice. It exists because a bolt count
    /// is arithmetic on a view size, and arithmetic on a view size is exactly
    /// what puts a thousand bolts on the one screen nobody measured.
    static let maxBoltCount = 24

    /// Points of the view's shorter side each bolt is worth.
    ///
    /// The second half of the same cap, and the half that scales: a full-screen
    /// burst on a 393pt phone is allowed all twenty-four bolts, while a 70pt
    /// preview panel is allowed seven, because the other seventeen would land
    /// inside a line width of each other.
    static let pointsPerBolt: CGFloat = 10

    /// Generations of forking. Three is already a bush; the app asks for two.
    static let maxBranchDepth = 3

    /// Subdivision passes, so a strand can never exceed `2^6 + 1` = 65 points.
    static let maxLevels = 6

    /// Strands one plane may generate, branches included.
    ///
    /// The front chidori plane averages 37 and can reach 56, so this is the
    /// same kind of headroom as `maxBoltCount`. Taken together with the two
    /// caps above and `maxPlanes`, the ceiling on a single frame of *any*
    /// burst in the app is 4 x 64 x 65 = 16,640 points — bounded, countable,
    /// and reached by nothing that ships.
    static let maxStrandsPerPlane = 64

    /// Planes one burst may stack. The chidori uses exactly four.
    static let maxPlanes = 4
}

// MARK: - Power budget

/// Whether the device is in Low Power Mode, as something a view can watch.
///
/// `ProcessInfo` answers the question but does not publish the answer, so a
/// view that read it directly would keep whatever it happened to see when it
/// was first built. This listens for `NSProcessInfoPowerStateDidChange` and
/// republishes it through Observation, so an effect drops to its cheap variant
/// the moment the battery saver comes on — which is the moment the owner most
/// wants it to.
///
/// One shared instance, because the state is a property of the device rather
/// than of a view, and because a hundred card faces registering a hundred
/// notification observers is a hundred ways to leak one.
///
/// Only ever read and written on the main thread: the notification is delivered
/// on the main queue and the only readers are view bodies.
@Observable
final class EffectPowerMonitor {

    static let shared = EffectPowerMonitor()

    /// True while the system is conserving power.
    private(set) var isLowPower: Bool

    @ObservationIgnored
    private var observer: NSObjectProtocol?

    private init() {
        isLowPower = ProcessInfo.processInfo.isLowPowerModeEnabled
        observer = NotificationCenter.default.addObserver(
            forName: .NSProcessInfoPowerStateDidChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            // `queue: .main` is what makes this a plain assignment rather than
            // a hop: the only writer and every reader are on the same thread.
            self?.isLowPower = ProcessInfo.processInfo.isLowPowerModeEnabled
        }
    }

    deinit {
        if let observer { NotificationCenter.default.removeObserver(observer) }
    }
}

/// What an effect may spend, given what the player and the battery have asked
/// for.
///
/// The two switches collapse to one decision on purpose. Reduce Motion and Low
/// Power want the same thing of an effect — stop moving — for entirely
/// different reasons, and an effect that honoured one and not the other would
/// be exactly as hot on the device that could least afford it. Every effect in
/// this folder therefore asks `prefersStill` rather than either switch, and the
/// *playback* code has to ask the same question as the *drawing* code, or a
/// still frame is mounted with nothing to fade it in.
struct EffectBudget {

    /// The accessibility setting, read from the environment by the view.
    var reduceMotion: Bool

    /// The battery setting, read from `EffectPowerMonitor`.
    var lowPower: Bool

    /// Reads both at once. The environment value has to come from the caller
    /// because only a view can hold an `@Environment`.
    @MainActor
    static func current(reduceMotion: Bool) -> EffectBudget {
        EffectBudget(reduceMotion: reduceMotion, lowPower: EffectPowerMonitor.shared.isLowPower)
    }

    /// Whether this effect should stand still rather than animate at all.
    var prefersStill: Bool { reduceMotion || lowPower }

    /// A wanted tick rate, clamped to what the device should be asked to do.
    func rate(_ preferred: Double) -> Double {
        min(max(1, preferred), EffectMetrics.maxFrameRate)
    }
}

// MARK: - Route

/// Where an arc runs inside the view drawing it.
enum LightningRoute: Equatable {

    /// One arc strung between two points and torn along its length — a bolt
    /// jumping from a card to a target.
    case between(UnitPoint, UnitPoint)

    /// Arcs thrown outward from a ring around a point, as fractions of the
    /// smaller half-dimension of the view: the lower bound is the ring the arcs
    /// start on, the upper is as far as they reach. Rooting them on a ring
    /// rather than on the exact centre is what keeps a ball of chakra from
    /// looking like a spoked wheel pinned to one pixel.
    ///
    /// The radii are *not* clamped to 1. The unit is half the shorter side, so
    /// covering a whole portrait viewport needs to reach the corner —
    /// `hypot(w, h) / min(w, h)`, about 2.4 on a 393×852 phone. Anything past
    /// that simply runs off the edge, which is exactly what a discharge bigger
    /// than the screen should do.
    case radiating(from: UnitPoint, radius: ClosedRange<CGFloat>)

    /// A sheet of arcs torn across the whole view: bolts strung from one edge
    /// to the opposite one along `axis`, spread over `band` of the other axis
    /// (0...1 being the full extent).
    ///
    /// This is the route that makes an effect read as covering the *field*
    /// rather than a spot on it — a burst radiating from the middle still
    /// leaves the far corners of a two-sided board untouched, and a couple of
    /// arcs running the full width tie both halves into the same event.
    case across(axis: Axis, band: ClosedRange<CGFloat>)
}

// MARK: - Geometry

/// One generated arc. `generation` is 0 for a trunk and counts up per branch;
/// brightness and width fall off with it, which is also what lets the renderer
/// batch a whole generation into a single stroked path.
struct LightningStrand {
    var points: [CGPoint]
    var generation: Int
}

/// Builds the polylines. Pure geometry — no drawing, no state, no clock — so
/// the same seed always yields the same bolt, and the renderer stays a thin
/// layer of strokes over it.
enum LightningGeometry {

    // MARK: Seeding

    /// The seed for a given instant, quantised to the flicker rate. Between
    /// ticks the value is unchanged, so the bolt holds its shape and then jumps
    /// — the difference between electricity and a slithering worm.
    static func seed(at date: Date, rate: Double, salt: UInt64) -> UInt64 {
        let tick = UInt64(max(0, date.timeIntervalSinceReferenceDate * max(1, rate)))
        return tick &* 0x2545_F491_4F6C_DD1D &+ salt
    }

    /// The instant the tick containing `date` began.
    ///
    /// The seed above already holds still between ticks, but a bolt's *reach*
    /// and *brightness* come from an envelope running on wall-clock time, and
    /// those slide continuously — so an arc canvas driven from the raw date
    /// redraws on every single display frame even though its shape only changes
    /// a dozen or twenty times a second. Quantising the envelope to the same
    /// tick as the seed is what lets the renderer genuinely sit idle in
    /// between: identical inputs, no redraw, and no blur pass.
    ///
    /// It also reads *better*, not merely cheaper. Electricity that jumps to a
    /// new shape while smoothly getting longer looks like a shape being
    /// stretched; jumping to a new shape at a new length looks like a discharge.
    static func tick(at date: Date, rate: Double) -> Date {
        let rate = max(1, rate)
        let elapsed = date.timeIntervalSinceReferenceDate
        return Date(timeIntervalSinceReferenceDate: (elapsed * rate).rounded(.down) / rate)
    }

    /// The most bolts worth drawing in a view of this size.
    ///
    /// Two ceilings at once: an absolute one, and one that falls with the view,
    /// because bolts closer together than a line width are heat rather than
    /// detail. A full-screen phone burst clears both and is never clipped; a
    /// preview panel is.
    static func boltCeiling(in size: CGSize) -> Int {
        let shorter = min(size.width, size.height)
        let byExtent = Int(shorter / EffectMetrics.pointsPerBolt)
        return max(1, min(EffectMetrics.maxBoltCount, byExtent))
    }

    // MARK: Bolts

    /// Generates every strand for a route: `boltCount` trunks plus their
    /// branches, laid out in the given size.
    ///
    /// Every one of the four knobs is clamped on the way in — see the cost
    /// ceilings in `EffectMetrics` — and the recursion runs against a strand
    /// budget as well, because branching is the one part of this that is
    /// probabilistic and a probability has no upper bound of its own. The
    /// worst frame this function can produce is `maxStrandsPerPlane` strands of
    /// `2^maxLevels + 1` points: 64 x 65, or 4,160 points. Nothing in the app
    /// asks for a quarter of that.
    static func strands(
        route: LightningRoute,
        in size: CGSize,
        seed: UInt64,
        levels: Int,
        branchDepth: Int,
        boltCount: Int,
        branchChance: Double = EffectMetrics.branchChance
    ) -> [LightningStrand] {
        guard size.width > 1, size.height > 1 else { return [] }

        // `| 1` keeps a zero seed from degenerating the generator's first draw.
        var rng = SeededGenerator(seed: seed | 1)
        let bolts = min(max(1, boltCount), boltCeiling(in: size))
        let depth = min(max(0, branchDepth), EffectMetrics.maxBranchDepth)
        let passes = min(max(1, levels), EffectMetrics.maxLevels)

        // Spent by `append`, one per strand, trunks and branches alike.
        var budget = EffectMetrics.maxStrandsPerPlane

        var strands: [LightningStrand] = []
        strands.reserveCapacity(min(bolts * (depth + 1) * 2, budget))

        switch route {
        case let .between(from, to):
            let start = from.resolved(in: size)
            let end = to.resolved(in: size)
            let span = distance(start, end)
            for _ in 0..<bolts {
                append(
                    from: start, to: end,
                    jitter: span * EffectMetrics.trunkJitter,
                    levels: passes, generation: 0, branchDepth: depth,
                    branchChance: branchChance,
                    rng: &rng, budget: &budget, into: &strands
                )
            }

        case let .radiating(origin, radius):
            let centre = origin.resolved(in: size)
            let unit = min(size.width, size.height) / 2
            let low = Double(min(radius.lowerBound, radius.upperBound))
            let high = Double(max(radius.lowerBound, radius.upperBound))
            let step = (2 * Double.pi) / Double(bolts)

            for index in 0..<bolts {
                // Even spacing keeps the ball from going bald on one side; the
                // nudge keeps it from looking machined.
                let angle = step * (Double(index) + Double.random(in: -0.35...0.35, using: &rng))
                let inner = CGFloat(low) * unit
                let outer = max(inner + 2, CGFloat(Double.random(in: low...high, using: &rng)) * unit)
                guard outer - inner > 1 else { continue }

                let direction = CGPoint(x: CGFloat(cos(angle)), y: CGFloat(sin(angle)))
                let root = CGPoint(x: centre.x + direction.x * inner, y: centre.y + direction.y * inner)
                let tip = CGPoint(x: centre.x + direction.x * outer, y: centre.y + direction.y * outer)

                append(
                    from: root, to: tip,
                    jitter: (outer - inner) * EffectMetrics.trunkJitter,
                    levels: passes, generation: 0, branchDepth: depth,
                    branchChance: branchChance,
                    rng: &rng, budget: &budget, into: &strands
                )
            }

        case let .across(axis, band):
            let low = min(band.lowerBound, band.upperBound)
            let high = max(band.lowerBound, band.upperBound)
            let span = axis == .horizontal ? size.width : size.height
            let cross = axis == .horizontal ? size.height : size.width
            let overshoot = span * EffectMetrics.edgeOvershoot

            for index in 0..<bolts {
                // Evenly spaced lanes with at most half a lane of wander, so
                // the sheet never leaves a bald stripe and never stacks two
                // bolts on the same line.
                let centre = (Double(index) + 0.5) / Double(bolts)
                let wander = Double.random(in: -0.5...0.5, using: &rng) / Double(bolts)
                let lane = CGFloat(min(max(centre + wander, 0), 1))

                // The two ends sit on slightly different lanes, so the bolt
                // crosses the view on a slope instead of lying dead level.
                let entry = low + (high - low) * lane
                let exit = entry + CGFloat(Double.random(in: -0.09...0.09, using: &rng))

                let start: CGPoint
                let end: CGPoint
                switch axis {
                case .horizontal:
                    start = CGPoint(x: -overshoot, y: entry * cross)
                    end = CGPoint(x: span + overshoot, y: exit * cross)
                case .vertical:
                    start = CGPoint(x: entry * cross, y: -overshoot)
                    end = CGPoint(x: exit * cross, y: span + overshoot)
                }

                append(
                    from: start, to: end,
                    jitter: (span + 2 * overshoot) * EffectMetrics.trunkJitter * 0.5,
                    levels: passes, generation: 0, branchDepth: depth,
                    branchChance: branchChance,
                    rng: &rng, budget: &budget, into: &strands
                )
            }
        }

        return strands
    }

    /// Adds one arc and, unless it has run out of depth, up to two children
    /// forking off its midpoints. More than two candidates per generation turns
    /// the bolt into a bush.
    ///
    /// Each candidate is rolled against `branchChance ^ (generation + 1)`:
    /// forks are common off the trunk and rare off a fork's fork. A fixed
    /// count would give every bolt the same silhouette; a probability is what
    /// makes one arc fork twice and its neighbour run clean.
    ///
    /// `budget` is the ceiling that makes a probability safe to run inside a
    /// draw call. One strand costs one unit, trunk or branch, and a plane that
    /// spends its budget simply stops forking — the trunks that are already
    /// down still read as a discharge, which is more than can be said for a
    /// frame that took forty milliseconds to generate.
    private static func append(
        from start: CGPoint,
        to end: CGPoint,
        jitter: CGFloat,
        levels: Int,
        generation: Int,
        branchDepth: Int,
        branchChance: Double,
        rng: inout SeededGenerator,
        budget: inout Int,
        into strands: inout [LightningStrand]
    ) {
        guard budget > 0 else { return }
        budget -= 1

        let points = polyline(from: start, to: end, levels: levels, jitter: jitter, rng: &rng)
        strands.append(LightningStrand(points: points, generation: generation))

        guard budget > 0, generation < branchDepth, points.count >= 4 else { return }

        let chance = pow(min(max(branchChance, 0), 1), Double(generation + 1))
        for _ in 0..<2 {
            guard budget > 0 else { return }
            guard Double.random(in: 0..<1, using: &rng) < chance else { continue }
            let index = Int.random(in: 1...(points.count - 2), using: &rng)
            let anchor = points[index]

            // Fork away from the local heading rather than from the straight
            // line, so a branch leaves its parent at a believable angle.
            let before = points[index - 1]
            let after = points[index + 1]
            let heading = atan2(Double(after.y - before.y), Double(after.x - before.x))
            let turn = Double.random(in: 0.4...1.0, using: &rng) * (Bool.random(using: &rng) ? 1 : -1)
            let length = distance(anchor, end) * CGFloat(Double.random(in: 0.35...0.75, using: &rng))
            guard length > 2 else { continue }

            let tip = CGPoint(
                x: anchor.x + CGFloat(cos(heading + turn)) * length,
                y: anchor.y + CGFloat(sin(heading + turn)) * length
            )
            append(
                from: anchor, to: tip,
                jitter: jitter * 0.55,
                levels: max(1, levels - 1),
                generation: generation + 1,
                branchDepth: branchDepth,
                branchChance: branchChance,
                rng: &rng, budget: &budget, into: &strands
            )
        }
    }

    /// Midpoint displacement. Every pass inserts a midpoint per segment, pushed
    /// perpendicular to that segment by a random amount, and then halves the
    /// amount — which is what produces detail at every scale instead of one
    /// even wobble.
    static func polyline(
        from start: CGPoint,
        to end: CGPoint,
        levels: Int,
        jitter: CGFloat,
        rng: inout SeededGenerator
    ) -> [CGPoint] {
        var points = [start, end]
        var amplitude = jitter

        for _ in 0..<max(0, levels) {
            var next: [CGPoint] = []
            next.reserveCapacity(points.count * 2)

            for index in 0..<(points.count - 1) {
                let a = points[index]
                let b = points[index + 1]
                next.append(a)

                let dx = b.x - a.x
                let dy = b.y - a.y
                let length = max(0.001, hypot(dx, dy))
                let offset = CGFloat(Double.random(in: -1...1, using: &rng)) * amplitude

                // (-dy, dx) / length is the unit normal of the segment.
                next.append(CGPoint(
                    x: (a.x + b.x) / 2 - dy / length * offset,
                    y: (a.y + b.y) / 2 + dx / length * offset
                ))
            }

            next.append(points[points.count - 1])
            points = next
            amplitude *= 0.5
        }

        return points
    }

    private static func distance(_ a: CGPoint, _ b: CGPoint) -> CGFloat {
        hypot(b.x - a.x, b.y - a.y)
    }
}

private extension UnitPoint {
    /// The point this unit position lands on inside a concrete size.
    func resolved(in size: CGSize) -> CGPoint {
        CGPoint(x: x * size.width, y: y * size.height)
    }
}

// MARK: - Depth planes

/// One plane of a layered discharge: a route, how densely it is populated, and
/// how far forward it sits.
///
/// `width`, `brightness` and `glow` are the depth cues, and they have to move
/// together — a thin arc that is as bright as a thick one reads as a scratch on
/// the lens rather than as something further away. `glow` at 0 skips the halo
/// pass for that plane entirely, which is how a back plane can afford twice the
/// bolt count of the front one.
struct LightningTier {
    var route: LightningRoute
    var boltCount: Int = 3
    var branchDepth: Int = 2
    var levels: Int = EffectMetrics.boltLevels

    /// Multiplier on the burst's base line width.
    var width: CGFloat = 1

    /// Multiplier on the burst's intensity.
    var brightness: Double = 1

    /// Multiplier on the burst's halo radius. 0 draws no halo.
    var glow: CGFloat = 1

    /// Offsets this plane's seed so two planes sharing a clock never draw the
    /// same shape at two thicknesses, which reads as a double-struck line.
    var salt: UInt64 = 0
}

extension LightningTier {

    /// Three planes of a radiating discharge, back to front.
    ///
    /// The back plane carries twice the bolts at less than half the width and
    /// no halo — cheap, and it is what fills the corners of the viewport. The
    /// front plane is the one with the hot core and the heavy bloom. `reach` is
    /// the middle plane's span in units of half the shorter side; the back
    /// plane runs a quarter further so its arcs leave the frame.
    static func depthStack(
        from origin: UnitPoint = .center,
        reach: ClosedRange<CGFloat>,
        density: Int = 6
    ) -> [LightningTier] {
        let near = max(1, density)
        let inner = reach.lowerBound
        let outer = max(inner + 0.05, reach.upperBound)

        return [
            LightningTier(
                route: .radiating(from: origin, radius: (inner * 1.15)...(outer * 1.28)),
                boltCount: near * 2, branchDepth: 1, levels: EffectMetrics.boltLevels,
                width: 0.45, brightness: 0.4, glow: 0, salt: 0x0B0B
            ),
            LightningTier(
                route: .radiating(from: origin, radius: (inner * 0.9)...outer),
                boltCount: near + 2, branchDepth: 2, levels: EffectMetrics.boltLevels + 1,
                width: 0.8, brightness: 0.72, glow: 0.55, salt: 0x1C1C
            ),
            LightningTier(
                route: .radiating(from: origin, radius: (inner * 0.6)...(outer * 0.82)),
                boltCount: near, branchDepth: 2, levels: EffectMetrics.boltLevels + 1,
                width: 1.4, brightness: 1, glow: 1, salt: 0x2D2D
            )
        ]
    }
}

// MARK: - Renderer

/// One frame of layered lightning and nothing else: no clock, no state.
/// `LightningEffect` drives it on a schedule of its own; the jutsu overlay
/// drives it from the timeline it is already running, so the whole effect ticks
/// once per frame instead of once per layer.
///
/// Every plane is stroked out of at most `branchDepth + 1` paths — one per
/// branch generation, each drawn as a body and a core — so bolt count buys
/// shape rather than draw calls, and the planes share one canvas so they cost
/// one compositor layer between them.
///
/// The halo is the expensive part and there is exactly one of it: every plane
/// that asked for a glow strokes into the *same* blurred layer, at its own
/// width, instead of each opening a blur pass of its own. A blur is a
/// full-surface GPU pass, so the difference between one and four of them is the
/// difference between an effect that can cover the screen and one that cannot.
/// Halo *size* still varies by plane, because it comes from the stroke width
/// under the blur rather than from the blur radius.
///
/// Give it more room than the arcs need: a canvas clips at its own edge, and
/// branches fork sideways out of a route while the halo blurs past it. A
/// screen-filling burst wants the whole screen and reaches past it on purpose.
struct LightningBurst: View {
    var tiers: [LightningTier]
    var seed: UInt64 = 0
    var color: Color = EffectPalette.electric
    var coreColor: Color = EffectPalette.electricCore

    /// 0 draws nothing, 1 is a full-strength arc. Callers animate this rather
    /// than the view's opacity so the core stays hot while the halo drops away.
    var intensity: Double = 1

    var lineWidth: CGFloat = EffectMetrics.boltWidth
    var glowRadius: CGFloat = EffectMetrics.glowRadius

    var body: some View {
        Canvas(opaque: false, colorMode: .extendedLinear, rendersAsynchronously: false) { context, size in
            let strength = min(max(intensity, 0), 1)
            guard strength > 0.01, !tiers.isEmpty else { return }

            // One blur pass is affordable and four are not, and a plane that
            // asked for a halo is a plane that strokes into that one pass — so
            // the plane count is capped here rather than trusted from a caller.
            let planes = tiers.prefix(EffectMetrics.maxPlanes).compactMap { plane(for: $0, in: size) }
            guard !planes.isEmpty else { return }

            haloPass(planes, strength: strength, into: &context)

            // Additive for the sharp passes too: overlapping arcs pile up
            // towards white in the middle instead of muddying into flat blue.
            context.blendMode = .plusLighter
            for plane in planes {
                strokePass(plane, strength: strength, into: &context)
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    /// One plane's generated geometry, batched into one path per branch
    /// generation so a whole generation is a single stroke.
    private struct Plane {
        let tier: LightningTier
        let generations: [Path]
    }

    private func plane(for tier: LightningTier, in size: CGSize) -> Plane? {
        let depth = max(0, tier.branchDepth)
        let strands = LightningGeometry.strands(
            route: tier.route,
            in: size,
            seed: seed &+ tier.salt,
            levels: tier.levels,
            branchDepth: depth,
            boltCount: tier.boltCount
        )
        guard !strands.isEmpty else { return nil }

        var byGeneration = [Path](repeating: Path(), count: depth + 1)
        for strand in strands where strand.generation < byGeneration.count {
            byGeneration[strand.generation].addLines(strand.points)
        }
        return Plane(tier: tier, generations: byGeneration)
    }

    /// The bloom for every plane at once, in one blurred layer, under
    /// everything sharp.
    private func haloPass(_ planes: [Plane], strength: Double, into context: inout GraphicsContext) {
        let glowing = planes.filter { $0.tier.glow > 0 }
        guard !glowing.isEmpty else { return }

        context.drawLayer { layer in
            layer.addFilter(.blur(radius: glowRadius))
            layer.blendMode = .plusLighter
            for plane in glowing {
                var union = Path()
                for path in plane.generations { union.addPath(path) }

                let level = strength * plane.tier.brightness
                let width = lineWidth * plane.tier.width * 3.2 * plane.tier.glow
                layer.stroke(
                    union,
                    with: .color(color.opacity(0.55 * level)),
                    style: StrokeStyle(lineWidth: width, lineCap: .round, lineJoin: .round)
                )
            }
        }
    }

    /// One plane's body and core, generation by generation.
    private func strokePass(_ plane: Plane, strength: Double, into context: inout GraphicsContext) {
        let level = strength * plane.tier.brightness
        let width = lineWidth * plane.tier.width

        for (generation, path) in plane.generations.enumerated() where !path.isEmpty {
            let falloff = pow(EffectMetrics.branchFalloff, Double(generation))
            let stroke = width * CGFloat(pow(EffectMetrics.branchWidthFalloff, Double(generation)))

            context.stroke(
                path,
                with: .color(color.opacity(0.9 * level * falloff)),
                style: StrokeStyle(lineWidth: stroke * 1.7, lineCap: .round, lineJoin: .round)
            )
            context.stroke(
                path,
                with: .color(coreColor.opacity(0.95 * level * falloff)),
                style: StrokeStyle(lineWidth: max(0.7, stroke * 0.7), lineCap: .round, lineJoin: .round)
            )
        }
    }
}

/// A single-plane burst, which is what most callers want: one route, one
/// weight. It is `LightningBurst` with one tier, so there is still exactly one
/// renderer in the app.
struct LightningCanvas: View {
    var route: LightningRoute = .radiating(from: .center, radius: 0.3...0.95)
    var seed: UInt64 = 0
    var color: Color = EffectPalette.electric
    var coreColor: Color = EffectPalette.electricCore
    var intensity: Double = 1
    var boltCount: Int = 3
    var branchDepth: Int = 2
    var levels: Int = EffectMetrics.boltLevels
    var lineWidth: CGFloat = EffectMetrics.boltWidth
    var glowRadius: CGFloat = EffectMetrics.glowRadius

    var body: some View {
        LightningBurst(
            tiers: [
                LightningTier(
                    route: route,
                    boltCount: boltCount,
                    branchDepth: branchDepth,
                    levels: levels
                )
            ],
            seed: seed,
            color: color,
            coreColor: coreColor,
            intensity: intensity,
            lineWidth: lineWidth,
            glowRadius: glowRadius
        )
    }
}

// MARK: - Animated effect

/// A self-running arc: the renderer plus a schedule that re-seeds it. Drop it
/// into an overlay and it crackles for as long as it is on screen.
///
/// The schedule is `.periodic` and never `.animation`, which is the whole
/// difference between an arc and a heater. `.animation` follows the display, so
/// on a ProMotion iPhone it would redraw — and re-blur — a hundred and twenty
/// times a second to show fourteen distinct shapes. The periodic schedule draws
/// each of those shapes exactly once.
///
/// Under Reduce Motion, and equally under Low Power Mode, the timeline is
/// removed and a single dim, heavily blurred bolt is left in place — the board
/// still shows *something* happened at that spot, without anything strobing and
/// without a clock running.
struct LightningEffect: View {
    var route: LightningRoute = .radiating(from: .center, radius: 0.3...0.95)
    var color: Color = EffectPalette.electric
    var intensity: Double = 1
    var boltCount: Int = 3
    var branchDepth: Int = 2
    var lineWidth: CGFloat = EffectMetrics.boltWidth
    var flickerRate: Double = EffectMetrics.flickerRate

    /// Salt for the seed, so two arcs sharing a frame and a clock do not draw
    /// the identical shape.
    var salt: UInt64 = 0

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let budget = EffectBudget.current(reduceMotion: reduceMotion)

        if budget.prefersStill {
            LightningCanvas(
                route: route,
                seed: salt &+ 1,
                color: color,
                intensity: intensity * 0.5,
                boltCount: boltCount,
                branchDepth: max(0, branchDepth - 1),
                lineWidth: lineWidth,
                glowRadius: EffectMetrics.glowRadius * 2.6
            )
        } else {
            let rate = budget.rate(flickerRate)
            TimelineView(.periodic(from: .now, by: 1 / rate)) { context in
                LightningCanvas(
                    route: route,
                    seed: LightningGeometry.seed(at: context.date, rate: rate, salt: salt),
                    color: color,
                    intensity: intensity,
                    boltCount: boltCount,
                    branchDepth: branchDepth,
                    lineWidth: lineWidth
                )
            }
        }
    }
}

// MARK: - Previews

#Preview("Arc between two points") {
    VStack(alignment: .leading, spacing: Metrics.spacingM) {
        Text("Card to card").sectionLabel()
        LightningEffect(
            route: .between(UnitPoint(x: 0.08, y: 0.8), UnitPoint(x: 0.92, y: 0.2)),
            boltCount: 2
        )
        .frame(height: 160)
        .notchedPanel(fill: Palette.panel.opacity(0.6))

        Text("Straight across, single bolt, no branches").sectionLabel()
        LightningEffect(route: .between(.leading, .trailing), boltCount: 1, branchDepth: 0)
            .frame(height: 90)
            .notchedPanel(fill: Palette.panel.opacity(0.6))
    }
    .padding(Metrics.spacingL)
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .background(AmbientBackground())
}

#Preview("Radiating burst") {
    HStack(spacing: Metrics.spacingM) {
        ForEach([1, 3, 6], id: \.self) { count in
            LightningEffect(
                route: .radiating(from: .center, radius: 0.25...0.95),
                boltCount: count,
                salt: UInt64(count) &* 977
            )
            .frame(width: 110, height: 110)
            .notchedPanel(fill: Palette.panel.opacity(0.6))
        }
    }
    .padding(Metrics.spacingL)
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .background(AmbientBackground())
}

#Preview("Branch depth and intensity") {
    VStack(spacing: Metrics.spacingM) {
        ForEach(0..<3) { depth in
            HStack(spacing: Metrics.spacingM) {
                Text("Depth \(depth)").sectionLabel().frame(width: 70, alignment: .leading)
                ForEach([0.35, 0.7, 1.0], id: \.self) { level in
                    LightningEffect(
                        route: .between(.leading, .trailing),
                        intensity: level,
                        boltCount: 1,
                        branchDepth: depth,
                        salt: UInt64(depth) &* 31 &+ UInt64(level * 100)
                    )
                    .frame(height: 70)
                    .notchedPanel(notch: 8, fill: Palette.panel.opacity(0.6))
                }
            }
        }
    }
    .padding(Metrics.spacingL)
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .background(AmbientBackground())
}

#Preview("Screen-scale layered burst") {
    TimelineView(.periodic(from: .now, by: 1 / 18)) { context in
        LightningBurst(
            tiers: LightningTier.depthStack(reach: 0.2...2.5, density: 7),
            seed: LightningGeometry.seed(at: context.date, rate: 18, salt: 0xC1D0),
            lineWidth: 3.2,
            glowRadius: 16
        )
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .background(AmbientBackground())
    .ignoresSafeArea()
}

#Preview("Depth planes, one at a time") {
    let planes = LightningTier.depthStack(reach: 0.2...2.5, density: 7)

    VStack(spacing: Metrics.spacingS) {
        ForEach(Array(planes.enumerated()), id: \.offset) { index, tier in
            LightningBurst(
                tiers: [tier],
                seed: 0xBEEF &+ UInt64(index),
                lineWidth: 3.2,
                glowRadius: 16
            )
            .frame(height: 150)
            .notchedPanel(notch: 8, fill: Palette.panel.opacity(0.5))
        }
    }
    .padding(Metrics.spacingL)
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .background(AmbientBackground())
}

#Preview("Sheet across the field") {
    TimelineView(.periodic(from: .now, by: 1 / 16)) { context in
        LightningCanvas(
            route: .across(axis: .horizontal, band: 0.06...0.94),
            seed: LightningGeometry.seed(at: context.date, rate: 16, salt: 0x5EA7),
            boltCount: 5,
            branchDepth: 1,
            lineWidth: 2.6,
            glowRadius: 12
        )
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .background(AmbientBackground())
    .ignoresSafeArea()
}

#Preview("Static geometry, one seed") {
    VStack(spacing: Metrics.spacingM) {
        Text("The same seed always draws the same bolt").sectionLabel()
        ForEach(0..<3) { _ in
            LightningCanvas(
                route: .between(.leading, .trailing),
                seed: 0xC0FF_EE00,
                boltCount: 1,
                branchDepth: 2
            )
            .frame(height: 80)
            .notchedPanel(notch: 8, fill: Palette.panel.opacity(0.6))
        }
    }
    .padding(Metrics.spacingL)
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .background(AmbientBackground())
}
