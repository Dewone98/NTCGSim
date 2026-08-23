//
//  JutsuEffectView.swift
//  NTCGSimulator
//
//  The overlay that plays when a jutsu resolves. It owns its own clock, plays
//  once, and reports back — the board only has to put it on screen and take it
//  off again when `onFinished` fires.
//
//  Chidori is the effect this file exists for, and it is deliberately the
//  loudest thing in the app: it takes the whole screen, reaches past all four
//  corners, throws a sheet of arcs across both halves of the field, and runs
//  for 1.4 seconds — gather, discharge, dissipate. A jutsu that empties the
//  board of Characters should not be a badge in the middle of the mat.
//
//  It is assembled out of `LightningBurst` and a few radial gradients blended
//  additively, because that is what makes a drawing read as light: overlapping
//  passes pile up towards white in the middle instead of muddying. Depth comes
//  from the burst's planes — thin, dim and far behind; thick, hot and haloed in
//  front — rather than from more bolts, which is also what keeps it affordable.
//  The gradients are flattened into one rasterised pass; only the arcs are
//  redrawn from scratch each frame, because only the arcs change shape.
//
//  Everything is driven from a single `TimelineView` and a set of envelope
//  curves, rather than from a stack of `withAnimation` calls. One clock means
//  one redraw per frame for the whole effect, the flicker seed and the glow
//  stay in step, and a progress value can be pointed at any instant of the
//  effect — which is what the still-frame preview at the bottom does.
//
//  That clock is `.periodic` and deliberately not `.animation`. `.animation`
//  follows the display, so on a ProMotion iPhone this effect redrew — and
//  re-blurred a screen-sized layer — a hundred and twenty times a second to
//  show twenty distinct shapes. It runs at `stageRate` now, and the arc layer
//  runs slower still: its inputs are quantised to the flicker tick and it is
//  wrapped in an `EquatableView`, so on the frames where the bolts have not
//  changed SwiftUI skips it entirely and the full-screen blur does not happen
//  at all. That single change is the difference between the loudest thing in
//  the app costing 120 blur passes a second and costing 20.
//
//  Reduce Motion and Low Power Mode take the same exit: a still glow, no clock
//  at all, and `onFinished` on the identical schedule so the board's sequencing
//  never depends on which of the three paths ran.
//
//  Sharingan is the other named effect, and it lives in `SharinganEffect.swift`
//  because an eye has nothing in common with an arc. This file only owns its
//  place in the queue and its slice of the clock.
//

import SwiftUI

// MARK: - Effect

/// The named effects the board can play.
enum JutsuEffect: String, CaseIterable, Identifiable {

    /// A discharge of lightning chakra that takes the whole screen.
    case chidori

    /// An eye that opens, spins up and settles — a genjutsu going off.
    case sharingan

    /// The fallback flare, used by any jutsu without art direction of its own.
    case generic

    var id: String { rawValue }

    /// How long the effect runs, fade-out included.
    ///
    /// Chidori is the long one on purpose: three beats need time to be read as
    /// three beats, and under about a second a gather-and-discharge collapses
    /// into a single flash.
    var duration: Double {
        switch self {
        case .chidori:   return 1.4
        case .sharingan: return SharinganTiming.duration
        case .generic:   return 0.9
        }
    }
}

// MARK: - Overlay

/// Plays one jutsu effect over whatever it is layered on and calls `onFinished`
/// when it is done. It never blocks touches and is hidden from VoiceOver: the
/// journal is what narrates a jutsu, this is only the picture of it.
///
/// It takes the whole screen, safe areas included, whatever it is overlaid on.
/// An effect that stops at the safe area has a visible straight edge across the
/// top of the phone, which is the one thing guaranteed to break the illusion
/// that something is happening *to* the board rather than *on* it.
///
/// Under Reduce Motion the timeline is dropped for a still glow that fades in
/// and out, and `onFinished` still arrives on the same schedule, so the board's
/// sequencing is identical either way.
///
/// The clock starts when the view is installed, so give each play its own
/// identity — `.id(playCount)` or a per-play token — if two effects run back to
/// back in the same slot. Reusing one identity keeps the first clock.
struct JutsuEffectView: View {
    let effect: JutsuEffect
    let onFinished: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Captured when the view is installed; every frame is measured from it.
    @State private var began = Date.now

    /// Reduce Motion only — the still glow's fade.
    @State private var isShowing = false

    /// What the player and the battery have asked of this effect.
    ///
    /// A computed property rather than a value read in `body`, because
    /// `play()` has to reach the same verdict: a still stage is faded in by
    /// `isShowing`, and a stage that draws itself still while playback thinks
    /// it is animating never fades in at all.
    @MainActor
    private var budget: EffectBudget {
        EffectBudget.current(reduceMotion: reduceMotion)
    }

    var body: some View {
        Group {
            if budget.prefersStill {
                stillStage
            } else {
                TimelineView(.periodic(from: began, by: 1 / budget.rate(effect.stageRate))) { context in
                    stage(at: context.date)
                }
            }
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
        .accessibilityHidden(true)
        .task { await play() }
    }

    // MARK: Stages

    @ViewBuilder
    private func stage(at date: Date) -> some View {
        let progress = min(max(date.timeIntervalSince(began) / effect.duration, 0), 1)
        let envelope = JutsuEnvelope(progress: progress, effect: effect)

        switch effect {
        case .chidori:   ChidoriStage(envelope: envelope, arcs: arcState(at: date))
        case .sharingan: SharinganFrame(progress: progress)
        case .generic:   ChakraFlareStage(envelope: envelope, arcs: arcState(at: date))
        }
    }

    /// Everything the arc layer reads, held still between flicker ticks.
    ///
    /// The seed already held still — that is what makes a bolt jump rather than
    /// slither — but reach and brightness came off an envelope running on
    /// wall-clock time, so they slid on every single frame and dragged the
    /// whole canvas, halo blur included, along with them. Sampling the envelope
    /// at the tick instead means the arc layer's inputs are byte-identical
    /// between ticks, which is what lets `EquatableView` throw the redraw away.
    ///
    /// It reads better as well as cheaper: an arc that changes shape *and*
    /// length at the same instant is a discharge, where one that changes shape
    /// while smoothly lengthening is a shape being stretched.
    private func arcState(at date: Date) -> ArcState {
        let tick = LightningGeometry.tick(at: date, rate: effect.flickerRate)
        let elapsed = tick.timeIntervalSince(began) / effect.duration
        let held = JutsuEnvelope(progress: min(max(elapsed, 0), 1), effect: effect)

        return ArcState(
            seed: LightningGeometry.seed(at: date, rate: effect.flickerRate, salt: effect.salt),
            intensity: held.arcs,
            reach: CGFloat(held.reach),
            expansion: held.expansion
        )
    }

    /// The Reduce Motion stand-in: the same colour and the same footprint,
    /// with nothing that strobes or travels.
    ///
    /// The eye keeps its own still frame rather than being replaced by a glow —
    /// it is legible standing perfectly still, and swapping it for a red blob
    /// would tell a player who needs Reduce Motion strictly less than it tells
    /// everybody else.
    @ViewBuilder
    private var stillStage: some View {
        if effect == .sharingan {
            SharinganFrame(progress: 0.4)
                .opacity(isShowing ? 1 : 0)
        } else {
            GeometryReader { geo in
                let side = min(geo.size.width, geo.size.height) * effect.stillFraction
                Circle()
                    .fill(
                        RadialGradient(
                            colors: [effect.coreColour.opacity(0.9),
                                     effect.tint.opacity(0.45),
                                     .clear],
                            center: .center,
                            startRadius: 0,
                            endRadius: side * 0.5
                        )
                    )
                    .frame(width: side, height: side)
                    .frame(width: geo.size.width, height: geo.size.height)
            }
            .opacity(isShowing ? 1 : 0)
        }
    }

    // MARK: Playback

    /// Runs the effect's lifetime. `.task` cancels this when the overlay is
    /// removed, and a cancelled sleep returns without reporting completion —
    /// the board tore the effect down itself, so there is nothing to report.
    @MainActor
    private func play() async {
        began = .now

        // Captured once: a player toggling Low Power Mode mid-effect must not
        // leave a still stage that was never faded in, or an animated one
        // waiting on a fade that will never come.
        let isStill = budget.prefersStill

        if isStill {
            withAnimation(.easeOut(duration: StageMetrics.stillFade)) { isShowing = true }
        }

        do {
            try await Task.sleep(for: .seconds(effect.duration))
        } catch {
            return
        }

        if isStill {
            withAnimation(.easeIn(duration: StageMetrics.stillFade)) { isShowing = false }
            do {
                try await Task.sleep(for: .seconds(StageMetrics.stillFade))
            } catch {
                return
            }
        }

        onFinished()
    }
}

// MARK: - Effect tuning

private extension JutsuEffect {

    /// When the gather is complete, as a fraction of the effect.
    ///
    /// Chidori's three beats are laid out on its 1.4 seconds as roughly
    /// 0.5s gathering, a discharge peaking at 0.65s, and a dissipation that
    /// starts at 0.9s and runs to the end.
    var gatherEnd: Double {
        switch self {
        case .chidori:   return 0.34
        case .sharingan: return 0.30
        case .generic:   return 0.30
        }
    }

    /// Where the discharge peaks, and how wide the spike is at its base.
    var dischargeAt: Double {
        switch self {
        case .chidori:   return 0.46
        case .sharingan: return 0.40
        case .generic:   return 0.42
        }
    }

    var dischargeWidth: Double {
        switch self {
        case .chidori:   return 0.16
        case .sharingan: return 0.20
        case .generic:   return 0.20
        }
    }

    /// Where the whole thing starts dying away.
    var decayStart: Double {
        switch self {
        case .chidori:   return 0.62
        case .sharingan: return 0.70
        case .generic:   return 0.58
        }
    }

    /// Chidori crackles faster than a generic flare — it is meant to sound like
    /// a thousand birds, not like a torch being lit.
    var flickerRate: Double {
        switch self {
        case .chidori:   return 20
        case .sharingan: return 8
        case .generic:   return 11
        }
    }

    /// How many times a second this effect's stage redraws.
    ///
    /// A whole multiple of the effect's own flicker wherever there *is* one, so
    /// the arcs re-seed on the same frame of every cycle rather than on a
    /// lopsided 3-2-3 pattern — the gradient layers get the frames in between
    /// to slide the wash, the core and the rings smoothly.
    ///
    /// The eye is the exception because it has no flicker to be a multiple of:
    /// it turns two and a bit revolutions in a second and a half, which is
    /// fourteen degrees a frame at sixty and a visibly stepped twenty-eight at
    /// thirty. Sixty is where a spin stops looking sampled, and it is still
    /// half of what a ProMotion display would have asked for.
    var stageRate: Double {
        switch self {
        case .chidori:   return flickerRate * 2
        case .sharingan: return EffectMetrics.maxFrameRate
        case .generic:   return flickerRate * 3
        }
    }

    /// Keeps two effects that share a clock from drawing the same bolt.
    var salt: UInt64 {
        switch self {
        case .chidori:   return 0x00C1_D081
        case .sharingan: return 0x005A_A1AA
        case .generic:   return 0x00A1_1E55
        }
    }

    var tint: Color {
        switch self {
        case .chidori:   return EffectPalette.electric
        case .sharingan: return EffectPalette.sharinganGlow
        case .generic:   return Palette.accent
        }
    }

    var coreColour: Color {
        switch self {
        case .chidori:   return EffectPalette.electricCore
        case .sharingan: return EffectPalette.sharinganIris
        case .generic:   return Palette.textOnAccent
        }
    }

    /// How much of the screen the Reduce Motion still glow covers. Chidori's is
    /// wider than the others because the moving version is a screen-filling
    /// event, and a still stand-in the size of a card would misreport its
    /// scale.
    var stillFraction: CGFloat {
        switch self {
        case .chidori:   return 1.4
        case .sharingan: return StageMetrics.fieldFraction
        case .generic:   return StageMetrics.fieldFraction
        }
    }
}

// MARK: - Envelope

/// The shape of a jutsu in time. Every layer of every stage reads its levels
/// from here, so the gather, the flare and the fade stay welded together
/// instead of drifting apart across half a dozen animations.
private struct JutsuEnvelope {

    /// Global fade: in quickly, out over the tail of the effect.
    let opacity: Double

    /// How gathered the ball is — drives the core's size and heat.
    let core: Double

    /// How strongly the arcs read.
    let arcs: Double

    /// Fraction of the available radius the arcs cover. Short while gathering,
    /// longest as it lets go.
    let reach: Double

    /// The discharge bloom: a short spike either side of the peak.
    let flash: Double

    /// The shock ring, 0 before the discharge and 1 once it has swept out.
    let expansion: Double

    /// A second, slower sweep for a trailing ring. It is deliberately scaled to
    /// finish past the end of the effect, so the outer ring is still travelling
    /// when it fades — a ring that visibly stops reads as a drawn circle.
    let expansionTrail: Double

    init(progress: Double, effect: JutsuEffect) {
        let t = min(max(progress, 0), 1)
        let gathered = Curve.smoothstep(0, effect.gatherEnd, t)
        let spike = Curve.bell(effect.dischargeAt, effect.dischargeWidth, t)
        let dying = Curve.smoothstep(effect.decayStart, 1, t)

        opacity = min(Curve.smoothstep(0, 0.08, t), 1 - dying)
        core = min(1, gathered * 0.8 + spike * 0.5)
        arcs = min(1, 0.22 + gathered * 0.68 + spike * 0.45) * max(1 - dying, 0.12)
        reach = min(1, 0.3 + gathered * 0.4 + spike * 0.18 + dying * 0.22)
        flash = spike
        expansion = Curve.smoothstep(effect.dischargeAt - effect.dischargeWidth, 1, t)
        expansionTrail = Curve.smoothstep(effect.dischargeAt, 1.45, t)
    }
}

/// Everything the arc layer of a stage reads, sampled at one flicker tick.
///
/// Its whole reason for existing is `Equatable`. The arc canvas is the one
/// layer in the app that opens a blur pass over the entire screen, and a blur
/// is a full-surface GPU pass — so the difference between redrawing it at the
/// stage rate and redrawing it only when the bolts actually change is the
/// difference between a phone that warms and one that does not. Gathering the
/// four figures into a value SwiftUI can compare is what makes that skip
/// possible; scattered across a view's arguments they would be compared by
/// SwiftUI's own reflection, which cannot see past the canvas's closure.
private struct ArcState: Equatable {

    /// The flicker seed for this tick — the shape of every bolt.
    var seed: UInt64

    /// How strongly the arcs read, held still across the tick.
    var intensity: Double

    /// Fraction of the available radius they cover.
    var reach: CGFloat

    /// How far the discharge has swept out, which is the field sheet's cue to
    /// arrive: the ball has to let go before the board lights up.
    var expansion: Double
}

/// The two easing curves the envelope is built from.
private enum Curve {

    /// Hermite ease between two thresholds: flat 0 below `from`, flat 1 above
    /// `to`, no corner at either end.
    static func smoothstep(_ from: Double, _ to: Double, _ t: Double) -> Double {
        guard to > from else { return t >= to ? 1 : 0 }
        let x = min(max((t - from) / (to - from), 0), 1)
        return x * x * (3 - 2 * x)
    }

    /// A single bump peaking at `centre` and reaching 0 `width` either side.
    static func bell(_ centre: Double, _ width: Double, _ t: Double) -> Double {
        guard width > 0 else { return 0 }
        let x = min(max((t - centre) / width, -1), 1)
        let value = cos(x * .pi / 2)
        return value * value
    }
}

// MARK: - Stage metrics

private enum StageMetrics {

    /// A local effect covers this fraction of the shorter side of whatever it
    /// is overlaid on, so it reads as something happening at a place on the
    /// board. Chidori ignores it: it is not a place on the board.
    static let fieldFraction: CGFloat = 0.62

    /// How much wider than the ball the arc canvas is drawn, so branches and
    /// the blurred halo have somewhere to go before the canvas clips them.
    static let canvasOvershoot: CGFloat = 1.6

    /// Bolts in the front plane of the chidori burst. The back planes are
    /// multiples of it, so this one number sets the density of the whole
    /// discharge. A handful of bolts with a good halo beats a hundred
    /// hairlines, and it is what keeps this at two blurred layers per frame.
    static let chidoriDensity = 8

    /// Bolts in the sheet thrown across the field. Few and wide: the sheet is
    /// there to tie the two halves of the board into one event, not to compete
    /// with the burst.
    static let fieldSheetBolts = 4

    static let genericBolts = 4

    /// The chidori's core ball and its wash, as fractions of the shorter side
    /// of the screen.
    static let coreFraction: CGFloat = 0.34
    static let washFraction: CGFloat = 0.78

    /// Peak opacity of the screen-wide flash at the discharge. One short spike
    /// per play, never a repeat: it is the loudest thing in the app and Reduce
    /// Motion removes it entirely.
    static let flashPeak: Double = 0.42

    /// How long the Reduce Motion still glow takes to appear and to leave.
    static let stillFade: Double = 0.22
}

// MARK: - Chidori

/// The chidori: a wash, a screen-wide flash, three planes of arcs radiating
/// past the corners, a sheet of arcs across both halves of the field, a
/// white-hot core and two shock rings, stacked back to front and blended
/// additively.
///
/// The geometry hangs off two numbers taken from the screen it is handed.
/// `unit` is half the shorter side, which is the unit `.radiating` measures its
/// radii in; `corner` is `hypot(w, h) / 2 / unit`, the reach at which an arc
/// lands exactly in a corner — about 2.4 on a 393×852 phone and nearer 1.6 on
/// an iPad. Multiplying the envelope's reach by it is what makes "cover the
/// screen" mean the same thing on both.
private struct ChidoriStage: View {
    let envelope: JutsuEnvelope

    /// The arc layer's inputs, already quantised to the flicker tick.
    let arcs: ArcState

    var body: some View {
        GeometryReader { geo in
            let size = geo.size
            let unit = max(1, min(size.width, size.height) / 2)
            let corner = hypot(size.width, size.height) / 2 / unit

            ZStack {
                // Gradients only. Every one of them slides on every stage
                // frame, so this is not a cache — it is a way of paying for
                // five overlapping additive layers with one rasterised pass
                // instead of five the compositor has to blend in turn.
                radiance(size: size)
                    .drawingGroup(opaque: false, colorMode: .extendedLinear)
                    .blendMode(.plusLighter)

                // The expensive layer, and the one that is allowed to skip.
                // `.equatable()` is load-bearing: between flicker ticks every
                // figure below is unchanged, SwiftUI leaves the canvas alone,
                // and the screen-wide halo blur inside it never runs.
                ChidoriArcs(state: arcs, unit: unit, corner: corner)
                    .equatable()
            }
            .frame(width: size.width, height: size.height)
        }
        .compositingGroup()
        .opacity(envelope.opacity)
    }

    // MARK: Light

    /// Everything that is a gradient: the flash, the blue field the sparks sit
    /// in, the core, and the two rings.
    private func radiance(size: CGSize) -> some View {
        let side = min(size.width, size.height)
        let diagonal = hypot(size.width, size.height)

        return ZStack {
            screenFlash
            wash(side: side)
            core(side: side)
            shockRing(
                diameter: side * 0.5,
                sweep: envelope.expansion,
                travel: diagonal / (side * 0.5),
                weight: 1
            )
            shockRing(
                diameter: side * 0.34,
                sweep: envelope.expansionTrail,
                travel: diagonal / (side * 0.34) * 1.2,
                weight: 0.55
            )
        }
    }

    /// The whole viewport going white for a moment at the discharge. Raised to
    /// a power so the spike is narrower than the bell that drives it: a wide
    /// flash reads as a fade, and a fade is not a discharge.
    private var screenFlash: some View {
        Rectangle()
            .fill(EffectPalette.electricCore)
            .opacity(StageMetrics.flashPeak * pow(envelope.flash, 1.7))
    }

    /// The soft blue field. It swells with the gather and jumps again on the
    /// discharge, and it is what stops the arcs reading as wire on a dark
    /// background.
    private func wash(side: CGFloat) -> some View {
        let span = side * StageMetrics.washFraction

        return Circle()
            .fill(
                RadialGradient(
                    colors: [EffectPalette.electricHalo.opacity(0.6),
                             EffectPalette.electricHalo.opacity(0.18),
                             .clear],
                    center: .center,
                    startRadius: 0,
                    endRadius: span
                )
            )
            .frame(width: span * 2, height: span * 2)
            .scaleEffect(0.5 + envelope.core * 0.4 + envelope.flash * 0.5)
            .opacity(0.2 + envelope.core * 0.8)
            .blendMode(.plusLighter)
    }

    /// Two nested gradients rather than a blurred disc: the same soft falloff
    /// for none of the per-frame blur passes.
    private func core(side: CGFloat) -> some View {
        let ball = side * StageMetrics.coreFraction

        return ZStack {
            Circle()
                .fill(
                    RadialGradient(
                        colors: [EffectPalette.electric.opacity(0.9),
                                 EffectPalette.electric.opacity(0.25),
                                 .clear],
                        center: .center,
                        startRadius: 0,
                        endRadius: ball * 0.5
                    )
                )
                .frame(width: ball, height: ball)

            Circle()
                .fill(
                    RadialGradient(
                        colors: [EffectPalette.electricCore,
                                 EffectPalette.electricCore.opacity(0.7),
                                 .clear],
                        center: .center,
                        startRadius: 0,
                        endRadius: ball * 0.24
                    )
                )
                .frame(width: ball * 0.48, height: ball * 0.48)
        }
        .scaleEffect(0.25 + envelope.core * 0.85 + envelope.flash * 0.6)
        .blendMode(.plusLighter)
    }

    /// A ring the discharge sheds. `travel` is how many multiples of its own
    /// diameter it has to cross to leave the screen, so both rings run off the
    /// edge whatever shape the screen is; the alpha falls as it goes, because a
    /// shockwave spends its energy on the way out.
    private func shockRing(
        diameter: CGFloat,
        sweep: Double,
        travel: CGFloat,
        weight: Double
    ) -> some View {
        Circle()
            .strokeBorder(
                EffectPalette.electricCore.opacity(weight * (1 - sweep) * (0.35 + 0.65 * envelope.flash)),
                lineWidth: max(1, diameter * 0.05 * CGFloat(1 - sweep * 0.7))
            )
            .frame(width: diameter, height: diameter)
            .scaleEffect(0.3 + CGFloat(sweep) * travel)
            .blendMode(.plusLighter)
    }

}

// MARK: - Chidori arcs

/// The discharge itself: three planes radiating from the middle, the furthest
/// reaching past every corner, plus a fourth strung right across the board from
/// edge to edge.
///
/// All four are one `LightningBurst` — one canvas, one blur — rather than a
/// stack of views. The canvas is the whole screen; bolts that run off it are
/// clipped at the edge, which is the point. The effect is bigger than the
/// viewport rather than fitted to it.
///
/// It is its own `Equatable` view for one reason, and the reason is heat. Four
/// planes of arcs regenerate a couple of thousand displaced points and stroke
/// them twenty times over, under a blur that covers the entire screen — and all
/// of it changes exactly `flickerRate` times a second, however often the stage
/// around it redraws. Declaring what the layer actually depends on lets SwiftUI
/// prove nothing has changed and leave the canvas untouched, so at the chidori's
/// twenty hertz on a hundred-and-twenty hertz display, five frames in six cost
/// nothing at all here.
private struct ChidoriArcs: View, Equatable {

    /// Quantised to the flicker tick by `JutsuEffectView`.
    let state: ArcState

    /// Half the shorter side of the screen — the unit `.radiating` measures in.
    let unit: CGFloat

    /// The reach at which an arc lands exactly in a corner.
    let corner: CGFloat

    /// Compared by hand rather than synthesised, so it is obvious that this is
    /// the whole dependency list and that adding a fifth figure to the drawing
    /// without adding it here would freeze the layer on a stale frame.
    static func == (lhs: ChidoriArcs, rhs: ChidoriArcs) -> Bool {
        lhs.state == rhs.state && lhs.unit == rhs.unit && lhs.corner == rhs.corner
    }

    var body: some View {
        let reach = state.reach * corner
        var tiers = LightningTier.depthStack(
            reach: (reach * 0.12)...reach,
            density: StageMetrics.chidoriDensity
        )
        tiers.insert(fieldSheet, at: 1)

        return LightningBurst(
            tiers: tiers,
            seed: state.seed,
            color: EffectPalette.electric,
            coreColor: EffectPalette.electricCore,
            intensity: state.intensity,
            lineWidth: max(1.6, unit * 0.022),
            glowRadius: max(6, unit * 0.06)
        )
    }

    /// Arcs strung right across the board, one edge to the other. They arrive
    /// with the discharge rather than during the gather — the ball has to let
    /// go before the field lights up — which is what the expansion in the
    /// brightness is doing, and they are what makes the effect span both
    /// players' halves instead of blooming in the middle of the mat.
    ///
    /// Second from the back: behind the two hot planes, in front of the far
    /// one, so the sheet reads as something happening across the room rather
    /// than as a wire laid over the board.
    private var fieldSheet: LightningTier {
        LightningTier(
            route: .across(axis: .horizontal, band: 0.06...0.94),
            boltCount: StageMetrics.fieldSheetBolts,
            branchDepth: 1,
            levels: EffectMetrics.boltLevels + 1,
            width: 0.7,
            brightness: state.expansion * 0.85,
            glow: 0.6,
            salt: 0x5EA7
        )
    }
}

// MARK: - Generic flare

/// The fallback: a chakra flare in the accent colour. Same envelope, warmer
/// palette, fewer and softer arcs, so it never upstages a named effect.
private struct ChakraFlareStage: View {
    let envelope: JutsuEnvelope

    /// The arc layer's inputs, already quantised to the flicker tick.
    let arcs: ArcState

    var body: some View {
        GeometryReader { geo in
            let side = min(geo.size.width, geo.size.height) * StageMetrics.fieldFraction

            ZStack {
                wash(side: side)
                // Same skip as the chidori's, for the same reason: this arc
                // canvas carries a blur too, and the flare re-seeds eleven
                // times a second whatever the display is doing.
                FlareArcs(state: arcs, side: side).equatable()
                ring(side: side)
            }
            .frame(width: geo.size.width, height: geo.size.height)
        }
        .compositingGroup()
        .opacity(envelope.opacity)
    }

    private func wash(side: CGFloat) -> some View {
        Circle()
            .fill(
                RadialGradient(
                    colors: [Palette.textOnAccent.opacity(0.55 * envelope.core),
                             Palette.accent.opacity(0.5),
                             .clear],
                    center: .center,
                    startRadius: 0,
                    endRadius: side * 0.5
                )
            )
            .frame(width: side * 1.2, height: side * 1.2)
            .scaleEffect(0.5 + envelope.core * 0.5 + envelope.flash * 0.4)
            .blendMode(.plusLighter)
    }

    private func ring(side: CGFloat) -> some View {
        Circle()
            .strokeBorder(
                Palette.accent.opacity(0.75 * envelope.flash),
                lineWidth: max(1, side * 0.018)
            )
            .frame(width: side * 0.55, height: side * 0.55)
            .scaleEffect(0.45 + envelope.expansion * 1.6)
            .blendMode(.plusLighter)
    }
}

/// The flare's arcs, split out and made `Equatable` for the same reason the
/// chidori's are: one canvas, one halo blur, and eleven distinct shapes a
/// second however fast the display runs.
///
/// The canvas is drawn wider than the flare so branches and the blurred halo
/// have somewhere to go before it clips them, and the reach is scaled back down
/// by the same factor so the arcs still stop where the flare does.
private struct FlareArcs: View, Equatable {
    let state: ArcState

    /// The flare's own diameter, before the canvas overshoot.
    let side: CGFloat

    static func == (lhs: FlareArcs, rhs: FlareArcs) -> Bool {
        lhs.state == rhs.state && lhs.side == rhs.side
    }

    var body: some View {
        let canvas = side * StageMetrics.canvasOvershoot
        let reach = state.reach * side / canvas

        return LightningCanvas(
            route: .radiating(from: .center, radius: (reach * 0.35)...(reach * 0.95)),
            seed: state.seed,
            color: Palette.accent,
            coreColor: Palette.textOnAccent,
            intensity: state.intensity * 0.85,
            boltCount: StageMetrics.genericBolts,
            branchDepth: 1,
            levels: EffectMetrics.boltLevels - 1,
            lineWidth: max(1.2, side * 0.016),
            glowRadius: max(4, side * 0.06)
        )
        .frame(width: canvas, height: canvas)
    }
}

// MARK: - Previews

#Preview("Chidori, looping") {
    @Previewable @State var plays = 0

    ZStack {
        AmbientBackground()

        // Two rows of cards, so it is obvious that the effect reaches both
        // halves of the field rather than blooming over one card.
        VStack(spacing: Metrics.spacingXL) {
            ForEach([CardColor.red, CardColor.blue], id: \.self) { colour in
                HStack(spacing: Metrics.spacingM) {
                    ForEach(0..<3) { _ in
                        RoundedRectangle(cornerRadius: 6)
                            .fill(colour.deepTint)
                            .frame(width: 84, height: 84 / Metrics.cardAspect)
                    }
                }
            }
        }

        JutsuEffectView(effect: .chidori) { plays += 1 }
            .id(plays)

        VStack {
            Spacer()
            Text("Play \(plays + 1)").sectionLabel()
        }
        .padding(Metrics.spacingL)
    }
    .ignoresSafeArea()
}

#Preview("Sharingan, looping") {
    @Previewable @State var plays = 0

    ZStack {
        AmbientBackground()

        RoundedRectangle(cornerRadius: 6)
            .fill(CardColor.blue.deepTint)
            .frame(width: 150, height: 150 / Metrics.cardAspect)

        JutsuEffectView(effect: .sharingan) { plays += 1 }
            .id(plays)

        VStack {
            Spacer()
            Text("Play \(plays + 1)").sectionLabel()
        }
        .padding(Metrics.spacingL)
    }
    .ignoresSafeArea()
}

#Preview("Generic flare, looping") {
    @Previewable @State var plays = 0

    ZStack {
        AmbientBackground()

        RoundedRectangle(cornerRadius: 6)
            .fill(CardColor.red.deepTint)
            .frame(width: 150, height: 150 / Metrics.cardAspect)

        JutsuEffectView(effect: .generic) { plays += 1 }
            .id(plays)

        VStack {
            Spacer()
            Text("Play \(plays + 1)").sectionLabel()
        }
        .padding(Metrics.spacingL)
    }
}

#Preview("Chidori, frame by frame") {
    let steps: [Double] = [0.0, 0.12, 0.28, 0.40, 0.46, 0.55, 0.72, 0.92]

    ScrollView {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: Metrics.spacingS)],
                  spacing: Metrics.spacingS) {
            ForEach(steps, id: \.self) { step in
                VStack(spacing: Metrics.spacingXS) {
                    let envelope = JutsuEnvelope(progress: step, effect: .chidori)
                    ChidoriStage(
                        envelope: envelope,
                        arcs: ArcState(
                            seed: UInt64(step * 1000) &+ 7,
                            intensity: envelope.arcs,
                            reach: CGFloat(envelope.reach),
                            expansion: envelope.expansion
                        )
                    )
                    .frame(width: 150, height: 150)
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
