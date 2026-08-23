//
//  AttackProjectile.swift
//  NTCGSimulator
//
//  The shot that crosses the mat when an attack is declared. A declaration is
//  the one moment in a turn where two cards on opposite sides of the board are
//  part of the same event, and a number changing on the far card is a poor way
//  to say so — something has to travel between them.
//
//  Three bits of maths, all of them chosen so a frame can be drawn from the
//  clock alone with no state carried between frames:
//
//  * The flight is a quadratic Bézier, `B(u) = (1-u)^2 P0 + 2(1-u)u C + u^2 P1`,
//    with the control point pushed off the chord's midpoint along its normal. A
//    straight line between two cards reads as a ruler; a slight arc reads as a
//    throw. The heading comes from the derivative,
//    `B'(u) = 2(1-u)(C - P0) + 2u(P1 - C)`, which is what points the head and
//    launches the sparks backwards.
//
//  * The trail is ballistic. The discrete form of it is the one everybody
//    writes — `velocity += acceleration * dt; position += velocity * dt`, with
//    drag as `velocity -= drag * velocity * dt` — but stepping that per frame
//    means storing every particle and makes the trail depend on frame rate. The
//    same motion has a closed form (see `Ballistics`), so a particle's position
//    is a pure function of its age: no storage, no drift, and the effect can be
//    scrubbed to any instant for a still preview.
//
//  * Spawn jitter. Particles are laid along the path at even times and then
//    pushed off it by a seeded random offset with a randomised launch velocity.
//    Even spacing alone gives a dotted line; jitter is what turns it into a
//    spray. It is seeded rather than random so a given particle sits in the
//    same place every frame instead of boiling.
//
//  Under Reduce Motion nothing travels: the same flight path is drawn once as a
//  static arrow from attacker to target, which says the same thing — who is
//  hitting whom — and then fades. Low Power Mode takes the identical exit.
//  `onFinished` arrives on the same schedule either way, so the board's
//  sequencing is identical.
//
//  When it does travel it travels on a `.periodic` clock capped at sixty, not
//  on `.animation`, which follows the display and would have drawn eighty small
//  additive fills a hundred and twenty times a second on a ProMotion phone. The
//  cap is sixty rather than the thirty the arcs get because the head crosses the
//  whole mat in half a second and a fast-moving object is where a low sample
//  rate shows: thirty frames of that reads as a strobe, sixty does not. Nothing
//  in the effect blurs or casts a shadow — the softness is radial gradients,
//  which cost one pass rather than sampling a whole surface twice — so halving
//  the frame count halves very nearly the whole bill.
//

import SwiftUI

// MARK: - Timing

/// How long a shot takes. The board sequences around these, so they live
/// together rather than inside the view.
enum ProjectileTiming {

    /// Attacker to target. Long enough to follow, short enough that nobody is
    /// waiting on it.
    static let travel: Double = 0.5

    /// The burst at the destination, which starts the instant the head lands.
    static let impact: Double = 0.26

    /// The whole life of the effect.
    static var total: Double { travel + impact }

    /// Reduce Motion: how long the static arrow takes to appear and to leave.
    static let arrowFade: Double = 0.18

    // MARK: Cost ceilings

    /// The most particles one trail may carry, whatever a style asks for.
    ///
    /// The styles ask for thirty and thirty-eight, so this is headroom; it is
    /// here because a trail is a loop inside a draw call and a loop inside a
    /// draw call wants a stop on it.
    static let maxParticles = 48

    /// Points of flight each particle is worth.
    ///
    /// The second, scaling half of the cap. A shot across the whole mat is six
    /// hundred points long and gets every particle its style asks for; a shot
    /// between two adjacent slots is a hundred, and thirty-eight sparks along
    /// it would sit on top of one another and cost seventy-six fills to look
    /// like twelve. Eight points is about the diameter of a fresh ember, which
    /// is the distance at which two of them stop being two.
    static let pointsPerParticle: CGFloat = 8

    /// Straight segments the flown arc is sampled into: the ceiling, the floor,
    /// and the points of arc each one in between is worth.
    ///
    /// A quadratic Bézier has no cheap exact split, so the wake is sampled —
    /// and twenty segments is already far smoother than a three-point stroke
    /// can show on a short hop. Scaling with the distance keeps a long shot
    /// smooth without paying for detail a short one cannot display; the floor
    /// keeps the shortest hop from going visibly polygonal, because the bow is
    /// proportional to the distance and a short arc is still an arc.
    static let maxWakeSegments = 24
    static let minWakeSegments = 8
    static let pointsPerWakeSegment: CGFloat = 24
}

// MARK: - Flight path

/// The arc a shot flies along.
///
/// The control point sits at the chord's midpoint pushed along the chord's
/// normal, so the bow is proportional to the distance travelled and the shape
/// is the same whichever way round the two cards are. The normal is picked to
/// point up the screen — a shot that arcs downward reads as a dropped ball —
/// and a dead-vertical shot, where neither normal is more "up" than the other,
/// breaks the tie toward the leading edge so the arc is still visible.
struct ProjectileFlight {
    let start: CGPoint
    let end: CGPoint
    let control: CGPoint

    /// Bow height as a fraction of the distance covered, and the ceiling on it.
    /// Without the cap a full-board shot loops like a mortar.
    static let bowFraction: CGFloat = 0.2
    static let bowLimit: CGFloat = 110

    init(from start: CGPoint, to end: CGPoint) {
        self.start = start
        self.end = end

        let dx = end.x - start.x
        let dy = end.y - start.y
        let length = max(0.001, hypot(dx, dy))

        // (-dy, dx) / length is one unit normal; the other is its negation.
        var normal = CGPoint(x: -dy / length, y: dx / length)
        if normal.y > 0 || (normal.y == 0 && normal.x > 0) {
            normal = CGPoint(x: -normal.x, y: -normal.y)
        }

        let bow = min(length * Self.bowFraction, Self.bowLimit)
        control = CGPoint(
            x: (start.x + end.x) / 2 + normal.x * bow,
            y: (start.y + end.y) / 2 + normal.y * bow
        )
    }

    /// `B(u)` — where the shot is, `u` running 0 at the attacker to 1 at the
    /// target.
    func point(at u: CGFloat) -> CGPoint {
        let t = min(max(u, 0), 1)
        let inverse = 1 - t
        return CGPoint(
            x: inverse * inverse * start.x + 2 * inverse * t * control.x + t * t * end.x,
            y: inverse * inverse * start.y + 2 * inverse * t * control.y + t * t * end.y
        )
    }

    /// `B'(u)`, normalised — the heading at a point on the flight.
    func heading(at u: CGFloat) -> CGPoint {
        let t = min(max(u, 0), 1)
        let inverse = 1 - t
        let dx = 2 * inverse * (control.x - start.x) + 2 * t * (end.x - control.x)
        let dy = 2 * inverse * (control.y - start.y) + 2 * t * (end.y - control.y)
        let length = max(0.001, hypot(dx, dy))
        return CGPoint(x: dx / length, y: dy / length)
    }

    /// How far the shot travels in a straight line, which is what both the
    /// particle count and the wake's smoothness are scaled against.
    var span: CGFloat {
        hypot(end.x - start.x, end.y - start.y)
    }

    /// The flown part of the arc, as a path. Sampled rather than clipped
    /// because a Bézier has no cheap exact split, and sampled at a count that
    /// falls with the distance because twenty segments is already smoother than
    /// a three-point stroke can show on a short hop.
    func trace(to u: CGFloat, segments: Int? = nil) -> Path {
        let wanted = segments ?? Int(span / ProjectileTiming.pointsPerWakeSegment)
        let steps = max(ProjectileTiming.minWakeSegments,
                        min(ProjectileTiming.maxWakeSegments, wanted))

        var path = Path()
        for index in 0...steps {
            let point = point(at: u * CGFloat(index) / CGFloat(steps))
            if index == 0 { path.move(to: point) } else { path.addLine(to: point) }
        }
        return path
    }
}

// MARK: - Ballistics

/// Motion under constant acceleration and linear drag, solved rather than
/// stepped.
///
/// The step everybody writes is
///
///     velocity += (acceleration - drag * velocity) * dt
///     position += velocity * dt
///
/// which is Euler integration of `dv/dt = a - k v`. That equation has an exact
/// solution, and using it is strictly better here: a particle's state depends
/// only on how old it is, so nothing has to be stored between frames, the trail
/// looks identical at 30fps and 120fps, and any instant of the effect can be
/// drawn on demand.
///
///     terminal velocity  v_inf = a / k
///     v(t) = v_inf + (v0 - v_inf) * e^(-kt)
///     x(t) = x0 + v_inf * t + (v0 - v_inf) * (1 - e^(-kt)) / k
///
/// With no drag the exponential degenerates, so that case falls back to the
/// schoolbook `x0 + v0 t + a t^2 / 2`.
enum Ballistics {

    /// Where a particle launched at `velocity` from `origin` has got to after
    /// `age` seconds.
    static func position(
        origin: CGPoint,
        velocity: CGPoint,
        acceleration: CGPoint,
        drag: CGFloat,
        age: Double
    ) -> CGPoint {
        let t = CGFloat(max(0, age))
        guard drag > 0.0001 else {
            return CGPoint(
                x: origin.x + velocity.x * t + acceleration.x * t * t / 2,
                y: origin.y + velocity.y * t + acceleration.y * t * t / 2
            )
        }
        let decay = CGFloat(exp(Double(-drag * t)))
        let terminalX = acceleration.x / drag
        let terminalY = acceleration.y / drag
        return CGPoint(
            x: origin.x + terminalX * t + (velocity.x - terminalX) * (1 - decay) / drag,
            y: origin.y + terminalY * t + (velocity.y - terminalY) * (1 - decay) / drag
        )
    }

    /// How fast it is going after `age` seconds. Used to point streaks along
    /// their own direction of travel.
    static func velocity(
        velocity: CGPoint,
        acceleration: CGPoint,
        drag: CGFloat,
        age: Double
    ) -> CGPoint {
        let t = CGFloat(max(0, age))
        guard drag > 0.0001 else {
            return CGPoint(x: velocity.x + acceleration.x * t, y: velocity.y + acceleration.y * t)
        }
        let decay = CGFloat(exp(Double(-drag * t)))
        let terminalX = acceleration.x / drag
        let terminalY = acceleration.y / drag
        return CGPoint(
            x: terminalX + (velocity.x - terminalX) * decay,
            y: terminalY + (velocity.y - terminalY) * decay
        )
    }
}

// MARK: - Anchors

/// Something on the mat a shot can fly from or to.
enum ProjectileAnchor: Hashable {
    case character(UUID)
    case leader(PlayerSlot)
}

/// Collects the frames of everything that marked itself as a projectile
/// endpoint, so the board can fire between two cards without either of them
/// knowing where the other one is.
///
///     card.projectileAnchor(.character(id))
///     …
///     .overlayPreferenceValue(ProjectileAnchorKey.self) { anchors in
///         GeometryReader { proxy in
///             if let shot, let a = anchors[shot.from], let b = anchors[shot.to] {
///                 AttackProjectileView(
///                     from: proxy.projectileCentre(of: a),
///                     to: proxy.projectileCentre(of: b),
///                     style: .fireball
///                 ) { self.shot = nil }
///             }
///         }
///     }
struct ProjectileAnchorKey: PreferenceKey {
    static var defaultValue: [ProjectileAnchor: Anchor<CGRect>] { [:] }

    static func reduce(
        value: inout [ProjectileAnchor: Anchor<CGRect>],
        nextValue: () -> [ProjectileAnchor: Anchor<CGRect>]
    ) {
        value.merge(nextValue()) { _, latest in latest }
    }
}

extension View {
    /// Publishes this view's frame as a projectile endpoint.
    func projectileAnchor(_ anchor: ProjectileAnchor) -> some View {
        anchorPreference(key: ProjectileAnchorKey.self, value: .bounds) { [anchor: $0] }
    }
}

extension GeometryProxy {
    /// Where an anchored frame's middle lands in this proxy's space. An anchor
    /// resolves to a rectangle and a shot needs a point, and doing the
    /// conversion here keeps the board from repeating it at both ends.
    func projectileCentre(of anchor: Anchor<CGRect>) -> CGPoint {
        let frame = self[anchor]
        return CGPoint(x: frame.midX, y: frame.midY)
    }
}

// MARK: - Projectile

/// The shot itself: a head that flies from one card to another, a trail of
/// particles falling away behind it, and a burst where it lands.
///
/// `from` and `to` are in the coordinate space of whatever this view is laid
/// over — put it in an overlay that fills the board and hand it two points in
/// that overlay's space.
///
/// It plays once on installation and calls `onFinished` after the burst has
/// faded, so a second shot in the same slot needs its own identity — `.id` on
/// the declaration — or the clock will not restart.
struct AttackProjectileView: View {
    let from: CGPoint
    let to: CGPoint
    let style: Style

    /// Salt for the spawn jitter, so two shots in the same turn do not throw
    /// the identical spray.
    var salt: UInt64 = 0

    let onFinished: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Captured when the view is installed; every frame is measured from it.
    @State private var began = Date.now

    /// Static arrow only — its fade.
    @State private var isShowing = false

    /// What the player and the battery have asked of this effect. `play()`
    /// reads the same property, because the arrow is faded in by `isShowing`
    /// and would otherwise be mounted invisible.
    @MainActor
    private var budget: EffectBudget {
        EffectBudget.current(reduceMotion: reduceMotion)
    }

    // MARK: Style

    /// What kind of shot it is. The two differ in more than colour: a fireball
    /// falls and burns out, while energy flies straight and shears into
    /// streaks, which is what keeps them apart at a glance.
    enum Style: Hashable, CaseIterable {
        case fireball
        case energy
    }

    var body: some View {
        Group {
            if budget.prefersStill {
                ProjectileArrow(flight: ProjectileFlight(from: from, to: to), style: style)
                    .opacity(isShowing ? 1 : 0)
            } else {
                TimelineView(.periodic(from: began, by: 1 / EffectMetrics.maxFrameRate)) { context in
                    ProjectileFrame(
                        flight: ProjectileFlight(from: from, to: to),
                        style: style,
                        time: context.date.timeIntervalSince(began),
                        salt: salt
                    )
                }
            }
        }
        .allowsHitTesting(false)
        // Transient decoration. The journal narrates an attack; this is only
        // the picture of it, and a view that appears mid-turn and vanishes
        // only steals VoiceOver focus.
        .accessibilityHidden(true)
        .task { await play() }
    }

    /// Runs the effect's lifetime. A cancelled sleep reports nothing: the board
    /// tore the shot down itself, so there is nothing to report.
    @MainActor
    private func play() async {
        began = .now

        // Captured once, so a setting toggled mid-flight cannot leave a static
        // arrow that was never faded in.
        let isStill = budget.prefersStill

        if isStill {
            withAnimation(.easeOut(duration: ProjectileTiming.arrowFade)) { isShowing = true }
        }

        do {
            try await Task.sleep(for: .seconds(ProjectileTiming.total))
        } catch {
            return
        }

        if isStill {
            withAnimation(.easeIn(duration: ProjectileTiming.arrowFade)) { isShowing = false }
            do {
                try await Task.sleep(for: .seconds(ProjectileTiming.arrowFade))
            } catch {
                return
            }
        }

        onFinished()
    }
}

// MARK: - Style tuning

extension AttackProjectileView.Style {

    /// The body of the shot.
    var tint: Color {
        switch self {
        case .fireball: return Palette.accent
        case .energy:   return EffectPalette.electric
        }
    }

    /// The white-hot centre.
    var core: Color {
        switch self {
        case .fireball: return EffectPalette.projectileEmber
        case .energy:   return EffectPalette.electricCore
        }
    }

    /// Radius of the head, before the flare it puts on at launch.
    var headRadius: CGFloat {
        switch self {
        case .fireball: return 13
        case .energy:   return 10
        }
    }

    /// How many particles are laid along the flight, before the ceilings in
    /// `ProjectileTiming` narrow it to what the distance can actually show.
    ///
    /// Cheap — they are filled circles in one canvas — but never free: every
    /// live particle is one or two fills a frame, so a full trail is the
    /// difference between eighty draws in a frame and twenty. Past a couple of
    /// dozen they also stop reading as individual sparks, so the ceiling costs
    /// the effect nothing it was getting.
    var trailCount: Int {
        switch self {
        case .fireball: return 38
        case .energy:   return 30
        }
    }

    /// How long a particle lives, in seconds.
    var particleLife: Double {
        switch self {
        case .fireball: return 0.42
        case .energy:   return 0.26
        }
    }

    /// Starting size of a particle.
    var particleRadius: CGFloat {
        switch self {
        case .fireball: return 5.5
        case .energy:   return 3.4
        }
    }

    /// How hard a particle is thrown backwards out of the head, in points per
    /// second, and how far sideways it may wander.
    var backwash: ClosedRange<CGFloat> {
        switch self {
        case .fireball: return 40...150
        case .energy:   return 70...220
        }
    }

    var spread: CGFloat {
        switch self {
        case .fireball: return 90
        case .energy:   return 45
        }
    }

    /// How far off the flight line a particle is born.
    var spawnJitter: CGFloat {
        switch self {
        case .fireball: return 8
        case .energy:   return 4
        }
    }

    /// Constant acceleration on a particle. Embers fall; energy does not.
    var gravity: CGPoint {
        switch self {
        case .fireball: return CGPoint(x: 0, y: 260)
        case .energy:   return .zero
        }
    }

    /// Linear drag coefficient, per second. High drag stops a particle almost
    /// where it was born, which is what makes a trail hang in the air rather
    /// than scatter across the board.
    var drag: CGFloat {
        switch self {
        case .fireball: return 3.4
        case .energy:   return 6.5
        }
    }

    /// Whether particles are drawn as streaks along their velocity.
    var streaks: Bool {
        switch self {
        case .fireball: return false
        case .energy:   return true
        }
    }

    /// Whether the head is wrapped in arcs.
    var crackles: Bool {
        switch self {
        case .fireball: return false
        case .energy:   return true
        }
    }

    /// How far the impact ring sweeps out.
    var burstRadius: CGFloat {
        switch self {
        case .fireball: return 62
        case .energy:   return 52
        }
    }
}

extension EffectPalette {

    /// The hot centre of a fireball. Not white — a flame's core is yellow, and
    /// a white one reads as electricity in the wrong colour.
    static let projectileEmber = Color(UIColor(hex: 0xFFE9A8))
}

// MARK: - One frame

/// A single frame of the shot: no clock, no state, everything derived from
/// `time`. One canvas draws the flown arc, every live particle, the head and
/// the burst, so the whole effect costs one layer.
private struct ProjectileFrame: View {
    let flight: ProjectileFlight
    let style: AttackProjectileView.Style
    let time: Double
    let salt: UInt64

    /// The shot leaves slowly and arrives fast. An exponent just over 1 is
    /// enough: ease *out* would have it gliding to a halt at the target, which
    /// is the opposite of an impact.
    private static let launchExponent: CGFloat = 1.22

    /// How far in front of the body the nose reaches, in body radii.
    private static let noseLength: CGFloat = 2.6

    /// The head's outline, with a body of radius 1 centred on the origin and a
    /// nose along +x. Built once and stamped with a transform, because it is
    /// the same shape at every size and on every frame.
    ///
    /// Same construction as a tomoe next door, and for the same reason: a full
    /// circle by `addArc`, then a nose subpath wound the *same* way so non-zero
    /// filling unions the two. Wound the other way — which is what an
    /// `addEllipse` body does — the overlap cancels and the head is drawn with
    /// two notches bitten out of it where the nose joins.
    private static let teardrop: Path = {
        var path = Path()
        path.addArc(center: .zero, radius: 1, startAngle: .zero, endAngle: .degrees(360), clockwise: false)
        path.move(to: CGPoint(x: 0, y: -1))
        path.addQuadCurve(
            to: CGPoint(x: noseLength, y: 0),
            control: CGPoint(x: noseLength * 0.45, y: -0.85)
        )
        path.addQuadCurve(
            to: CGPoint(x: 0, y: 1),
            control: CGPoint(x: noseLength * 0.45, y: 0.85)
        )
        path.closeSubpath()
        return path
    }()

    /// How many particles this shot is worth: what the style wants, capped
    /// absolutely, and capped again by the distance the trail has to fill.
    ///
    /// The floor of six is there so a shot between two touching slots is still
    /// a spray rather than a bead — an effect that vanishes when the board is
    /// crowded is worse than one that costs a few draws.
    ///
    /// The ceiling this puts on a frame is worth stating plainly, because the
    /// trail is the only unbounded-looking loop in the effect: at most
    /// `maxParticles` particles alive at once, at two fills each, plus the
    /// wake, the head and its two crackle arcs — a hundred draws in the very
    /// worst frame, and about eighty in the worst frame the app can actually
    /// produce.
    private var particleCount: Int {
        let byDistance = Int(flight.span / ProjectileTiming.pointsPerParticle)
        let ceiling = min(ProjectileTiming.maxParticles, byDistance)
        return max(6, min(style.trailCount, ceiling))
    }

    var body: some View {
        Canvas(opaque: false, colorMode: .extendedLinear, rendersAsynchronously: false) { context, _ in
            let travelled = min(max(time / ProjectileTiming.travel, 0), 1)
            let u = pow(CGFloat(travelled), Self.launchExponent)

            drawWake(in: &context, to: u, travelled: travelled)
            drawTrail(in: &context)

            if travelled < 1 {
                drawHead(in: &context, at: u, travelled: travelled)
            } else {
                drawImpact(in: &context)
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    // MARK: Layers

    /// A faint stroke down the part of the arc already flown. It is what makes
    /// the direction unmistakable in a still frame: the line is behind the
    /// head, never in front of it.
    private func drawWake(in context: inout GraphicsContext, to u: CGFloat, travelled: Double) {
        guard u > 0.02 else { return }
        let fade = 1 - travelled * 0.55
        context.blendMode = .plusLighter
        context.stroke(
            flight.trace(to: u),
            with: .color(style.tint.opacity(0.28 * fade)),
            style: StrokeStyle(lineWidth: 3, lineCap: .round)
        )
        context.blendMode = .normal
    }

    /// Every particle that is currently alive.
    ///
    /// Particle *i* is born at roughly an even fraction of the travel, so the
    /// trail is laid down as the head passes rather than all at once, and then
    /// jittered off the line. Its whole history is `Ballistics.position`, so
    /// this loop touches no state at all.
    ///
    /// Four things are jittered, and all four are needed: *when* it is born,
    /// *where* off the line, *how* it is thrown, and how big and how long-lived
    /// it is. Jitter only the launch and the trail comes out as evenly spaced
    /// beads of identical size on a string, which is what a spray never looks
    /// like.
    private func drawTrail(in context: inout GraphicsContext) {
        let count = particleCount
        context.blendMode = .plusLighter

        for index in 0..<count {
            var rng = SeededGenerator(seed: (salt &+ UInt64(index) &* 0x9E37_79B9) | 1)

            let slot = Double(index) + Double.random(in: -0.45...0.45, using: &rng)
            let birth = min(max(slot, 0), Double(count)) / Double(count) * ProjectileTiming.travel
            let span = style.particleLife * Double.random(in: 0.65...1.2, using: &rng)
            let age = time - birth
            guard age > 0, age < span else { continue }

            let u = pow(CGFloat(birth / ProjectileTiming.travel), Self.launchExponent)
            let seat = flight.point(at: u)
            let heading = flight.heading(at: u)
            let normal = CGPoint(x: -heading.y, y: heading.x)

            let sideways = CGFloat(Double.random(in: -1...1, using: &rng)) * style.spawnJitter
            let origin = CGPoint(
                x: seat.x + normal.x * sideways,
                y: seat.y + normal.y * sideways
            )

            let back = CGFloat(Double.random(in: Double(style.backwash.lowerBound)...Double(style.backwash.upperBound), using: &rng))
            let lateral = CGFloat(Double.random(in: -1...1, using: &rng)) * style.spread
            let launch = CGPoint(
                x: -heading.x * back + normal.x * lateral,
                y: -heading.y * back + normal.y * lateral
            )

            let position = Ballistics.position(
                origin: origin,
                velocity: launch,
                acceleration: style.gravity,
                drag: style.drag,
                age: age
            )

            let life = age / span
            let fade = (1 - life) * (1 - life)
            let grain = CGFloat(Double.random(in: 0.55...1.4, using: &rng))
            let radius = max(0.6, style.particleRadius * grain * CGFloat(1 - life * 0.7))

            if style.streaks {
                let motion = Ballistics.velocity(
                    velocity: launch,
                    acceleration: style.gravity,
                    drag: style.drag,
                    age: age
                )
                var streak = Path()
                streak.move(to: position)
                streak.addLine(to: CGPoint(
                    x: position.x - motion.x * 0.02,
                    y: position.y - motion.y * 0.02
                ))
                context.stroke(
                    streak,
                    with: .color(style.tint.opacity(0.85 * fade)),
                    style: StrokeStyle(lineWidth: radius, lineCap: .round)
                )
            } else {
                context.fill(
                    Path(ellipseIn: CGRect(
                        x: position.x - radius, y: position.y - radius,
                        width: radius * 2, height: radius * 2
                    )),
                    with: .color(style.tint.opacity(0.8 * fade))
                )
            }

            // Young particles keep a hot centre; old ones are just smoke.
            if life < 0.45 {
                let inner = radius * 0.45
                context.fill(
                    Path(ellipseIn: CGRect(
                        x: position.x - inner, y: position.y - inner,
                        width: inner * 2, height: inner * 2
                    )),
                    with: .color(style.core.opacity(0.9 * fade))
                )
            }
        }

        context.blendMode = .normal
    }

    /// The head: a glow, a teardrop pointing along the heading, and a hot dot.
    /// The teardrop is the direction cue — a round head could be flying either
    /// way along the arc.
    private func drawHead(in context: inout GraphicsContext, at u: CGFloat, travelled: Double) {
        let position = flight.point(at: u)
        let heading = flight.heading(at: u)
        let angle = atan2(heading.y, heading.x)

        // A brief flare as it leaves the attacker, so the shot has a muzzle.
        let launchFlare = 1 + 0.5 * CGFloat(max(0, 1 - travelled * 6))
        let radius = style.headRadius * launchFlare

        context.blendMode = .plusLighter

        let bloom = radius * 3
        context.fill(
            Path(ellipseIn: CGRect(
                x: position.x - bloom, y: position.y - bloom,
                width: bloom * 2, height: bloom * 2
            )),
            with: .radialGradient(
                Gradient(colors: [style.tint.opacity(0.55), style.tint.opacity(0.12), .clear]),
                center: position,
                startRadius: 0,
                endRadius: bloom
            )
        )

        // The teardrop, stretched along the heading and turned to face down the
        // arc. Scale and rotation both preserve the path's winding, so the
        // union of the body and the nose survives the transform.
        let placed = Self.teardrop.applying(
            CGAffineTransform.identity
                .translatedBy(x: position.x, y: position.y)
                .rotated(by: angle)
                .scaledBy(x: radius * 1.4, y: radius)
        )
        context.fill(placed, with: .color(style.tint.opacity(0.9)))

        let core = radius * 0.55
        context.fill(
            Path(ellipseIn: CGRect(
                x: position.x - core, y: position.y - core,
                width: core * 2, height: core * 2
            )),
            with: .color(style.core)
        )

        if style.crackles {
            drawCrackle(in: &context, at: position, radius: radius)
        }

        context.blendMode = .normal
    }

    /// Two short arcs whipping off an energy head. Midpoint displacement again,
    /// re-seeded every frame — electricity jumps, so this is the one thing in
    /// the effect that is deliberately not stable between frames.
    private func drawCrackle(in context: inout GraphicsContext, at position: CGPoint, radius: CGFloat) {
        var rng = SeededGenerator(seed: LightningGeometry.seed(
            at: Date(timeIntervalSinceReferenceDate: time),
            rate: EffectMetrics.flickerRate,
            salt: salt | 1
        ))

        var arcs = Path()
        for _ in 0..<2 {
            let angle = Double.random(in: 0..<(2 * .pi), using: &rng)
            let reach = radius * CGFloat(Double.random(in: 1.6...3.0, using: &rng))
            let tip = CGPoint(
                x: position.x + CGFloat(cos(angle)) * reach,
                y: position.y + CGFloat(sin(angle)) * reach
            )
            arcs.addLines(LightningGeometry.polyline(
                from: position,
                to: tip,
                levels: 3,
                jitter: reach * EffectMetrics.trunkJitter,
                rng: &rng
            ))
        }

        context.stroke(
            arcs,
            with: .color(style.core.opacity(0.75)),
            style: StrokeStyle(lineWidth: 1.4, lineCap: .round, lineJoin: .round)
        )
    }

    /// The burst at the destination: a flash, a ring sweeping outward, and a
    /// spray of shards. All three fade together over `impact`.
    private func drawImpact(in context: inout GraphicsContext) {
        let elapsed = time - ProjectileTiming.travel
        let phase = min(max(elapsed / ProjectileTiming.impact, 0), 1)
        guard phase < 1 else { return }

        // Ease out: the burst is fastest the instant it lands.
        let swell = CGFloat(1 - pow(1 - phase, 2.2))
        let fade = (1 - phase) * (1 - phase)
        let target = flight.end

        context.blendMode = .plusLighter

        let flash = style.burstRadius * (0.5 + swell * 0.5)
        context.fill(
            Path(ellipseIn: CGRect(
                x: target.x - flash, y: target.y - flash,
                width: flash * 2, height: flash * 2
            )),
            with: .radialGradient(
                Gradient(colors: [style.core.opacity(0.8 * fade),
                                  style.tint.opacity(0.35 * fade),
                                  .clear]),
                center: target,
                startRadius: 0,
                endRadius: flash
            )
        )

        let ring = style.burstRadius * (0.25 + swell)
        context.stroke(
            Path(ellipseIn: CGRect(
                x: target.x - ring, y: target.y - ring,
                width: ring * 2, height: ring * 2
            )),
            with: .color(style.core.opacity(0.7 * fade)),
            style: StrokeStyle(lineWidth: max(1, 4 * CGFloat(fade)))
        )

        var shards = Path()
        var rng = SeededGenerator(seed: (salt &+ 0x51E7) | 1)
        for index in 0..<10 {
            let angle = Double(index) * .pi / 5 + Double.random(in: -0.2...0.2, using: &rng)
            let inner = ring * 0.7
            let outer = inner + style.burstRadius * 0.45 * CGFloat(Double.random(in: 0.5...1, using: &rng))
            shards.move(to: CGPoint(
                x: target.x + CGFloat(cos(angle)) * inner,
                y: target.y + CGFloat(sin(angle)) * inner
            ))
            shards.addLine(to: CGPoint(
                x: target.x + CGFloat(cos(angle)) * outer,
                y: target.y + CGFloat(sin(angle)) * outer
            ))
        }
        context.stroke(
            shards,
            with: .color(style.tint.opacity(0.8 * fade)),
            style: StrokeStyle(lineWidth: 2.4, lineCap: .round)
        )

        context.blendMode = .normal
    }
}

// MARK: - Reduce Motion arrow

/// The still stand-in: the same flight path, drawn once, with a head on the
/// target end. Nothing travels and nothing flickers, and it still answers the
/// only question the effect exists to answer — who is attacking whom.
private struct ProjectileArrow: View {
    let flight: ProjectileFlight
    let style: AttackProjectileView.Style

    /// Length and half-width of the arrowhead.
    private static let head: CGFloat = 20
    private static let spread: CGFloat = 9

    var body: some View {
        Canvas(opaque: false, colorMode: .extendedLinear, rendersAsynchronously: false) { context, _ in
            context.blendMode = .plusLighter

            let shaft = flight.trace(to: 1)
            context.stroke(
                shaft,
                with: .color(style.tint.opacity(0.85)),
                style: StrokeStyle(lineWidth: 5, lineCap: .round)
            )
            context.stroke(
                shaft,
                with: .color(style.core.opacity(0.9)),
                style: StrokeStyle(lineWidth: 1.8, lineCap: .round)
            )

            // The head is built in a local frame pointing along +x and rotated
            // onto the arc's final heading, the same way the flying head is.
            let heading = flight.heading(at: 1)
            var arrow = Path()
            arrow.move(to: CGPoint(x: Self.head, y: 0))
            arrow.addLine(to: CGPoint(x: -Self.head * 0.2, y: -Self.spread))
            arrow.addLine(to: CGPoint(x: -Self.head * 0.2, y: Self.spread))
            arrow.closeSubpath()

            context.fill(
                arrow.applying(
                    CGAffineTransform.identity
                        .translatedBy(x: flight.end.x, y: flight.end.y)
                        .rotated(by: atan2(heading.y, heading.x))
                ),
                with: .color(style.tint)
            )
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

// MARK: - Previews

#Preview("Fireball, looping") {
    @Previewable @State var plays = 0

    ZStack {
        AmbientBackground()

        GeometryReader { geo in
            let attacker = CGPoint(x: geo.size.width * 0.22, y: geo.size.height * 0.78)
            let target = CGPoint(x: geo.size.width * 0.78, y: geo.size.height * 0.22)

            ZStack {
                CardStandIn(centre: attacker, colour: .red, label: "Attacker")
                CardStandIn(centre: target, colour: .blue, label: "Target")

                AttackProjectileView(
                    from: attacker,
                    to: target,
                    style: .fireball,
                    salt: UInt64(plays) &* 7717
                ) { plays += 1 }
                .id(plays)
            }
        }
    }
    .ignoresSafeArea()
}

#Preview("Energy, looping") {
    @Previewable @State var plays = 0

    ZStack {
        AmbientBackground()

        GeometryReader { geo in
            let attacker = CGPoint(x: geo.size.width * 0.5, y: geo.size.height * 0.84)
            let target = CGPoint(x: geo.size.width * 0.5, y: geo.size.height * 0.16)

            ZStack {
                CardStandIn(centre: attacker, colour: .green, label: "Attacker")
                CardStandIn(centre: target, colour: .red, label: "Target")

                AttackProjectileView(
                    from: attacker,
                    to: target,
                    style: .energy,
                    salt: UInt64(plays) &* 4211
                ) { plays += 1 }
                .id(plays)
            }
        }
    }
    .ignoresSafeArea()
}

#Preview("Flight, frame by frame") {
    let steps: [Double] = [0.04, 0.16, 0.3, 0.44, 0.5, 0.56, 0.64, 0.74]

    ScrollView {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: Metrics.spacingS)],
                  spacing: Metrics.spacingS) {
            ForEach(steps, id: \.self) { step in
                VStack(spacing: Metrics.spacingXS) {
                    ProjectileFrame(
                        flight: ProjectileFlight(
                            from: CGPoint(x: 24, y: 96),
                            to: CGPoint(x: 126, y: 24)
                        ),
                        style: .fireball,
                        time: step,
                        salt: 0x1234
                    )
                    .frame(width: 150, height: 120)
                    .background(Palette.surface.opacity(0.5))

                    Text(String(format: "%.2fs", step)).sectionLabel()
                }
            }
        }
        .padding(Metrics.spacingL)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .background(AmbientBackground())
}

#Preview("Reduce Motion arrow") {
    VStack(spacing: Metrics.spacingM) {
        ForEach([AttackProjectileView.Style.fireball, .energy], id: \.self) { style in
            ProjectileArrow(
                flight: ProjectileFlight(
                    from: CGPoint(x: 40, y: 110),
                    to: CGPoint(x: 260, y: 30)
                ),
                style: style
            )
            .frame(height: 150)
            .notchedPanel(notch: 8, fill: Palette.panel.opacity(0.5))
        }
    }
    .padding(Metrics.spacingL)
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .background(AmbientBackground())
}

/// A card-shaped block, so the previews can show a shot leaving one card and
/// landing on another without a game running.
private struct CardStandIn: View {
    let centre: CGPoint
    let colour: CardColor
    let label: String

    var body: some View {
        VStack(spacing: Metrics.spacingXS) {
            RoundedRectangle(cornerRadius: 6)
                .fill(colour.deepTint)
                .frame(width: 76, height: 76 / Metrics.cardAspect)
            Text(label).sectionLabel()
        }
        .position(centre)
    }
}
