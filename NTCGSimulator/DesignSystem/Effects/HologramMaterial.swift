//
//  HologramMaterial.swift
//  NTCGSimulator
//
//  The holographic treatment — what turns a flat picture into something that
//  reads as *projected light*. `HologramProjection` applies it to card
//  artwork, but it is written against any content on purpose: a material is a
//  surface quality, not a feature of one effect.
//
//  What the references actually do, and which parts survive here. The look
//  the owner named — YGO Omega's field presentation, Master Duel's staging,
//  and the anime "Solid Vision" projections both are quoting — presents a
//  card's image as emissive, slightly translucent light: it glows from
//  within rather than being lit from outside, its edges bleed a little
//  (bloom), thin horizontal interference lines crawl over it (the CRT/
//  projector scanline cliché every screen hologram uses because it is read
//  instantly), the colour channels split faintly at the rim the way a cheap
//  lens fringes, and every so often the whole image stutters — because a
//  *stable* projection stops reading as a projection and starts reading as a
//  sticker. Dueling Nexus's hologram mode describes the same recipe in one
//  line: animated floating renders above the card, "similar to their
//  depiction in the anime".
//
//  Every layer is SwiftUI compositing — copies, blend modes, gradients, one
//  Canvas — because a Metal shader file would complicate the build for an
//  effect whose parts are all expressible as layers. The cost shape matters
//  more than the layer list:
//
//  * The base plate (tinted content, chromatic fringe, rim glow, bloom) does
//    not depend on time. It is flattened with `drawingGroup()` and therefore
//    rasterised once; SwiftUI's tree diffing never re-renders it on a tick.
//  * The scanlines are rasterised once into a band one period taller than
//    the content and *translated* per tick — the drift is a compositor
//    transform, never a redraw.
//  * Flicker and jitter are an opacity and an offset on the flattened result
//    — again transforms, again free.
//
//  So a ticking material costs the compositor a few cached-texture blends
//  and the CPU nothing at all, which is what lets several holograms share a
//  phone screen.
//

import SwiftUI

// MARK: - Hologram palette

/// Colour tokens for the hologram treatment. Beside the effects rather than
/// in `Palette` for the usual reason: nothing else draws with them, and they
/// are tuned to read as *light* over artwork rather than as UI chrome.
enum HologramPalette {

    /// The default projection colour — the cyan every screen hologram since
    /// the first sci-fi HUD has used, because a cool, slightly green blue is
    /// the one hue that never occurs as ambient room light and therefore
    /// always reads as artificial. Kept close to `EffectPalette.electric` so
    /// holograms and jutsu arcs feel lit by the same technology.
    static let beam = Palette.adaptive(dark: 0x74DCFF, light: 0x1E9BD7)

    /// The channel isolators for chromatic fringe. Deliberately *not*
    /// adaptive: they exist to multiply the content down to one colour
    /// channel each (red, and green+blue), which is arithmetic, not theming.
    /// A red fringe on one side and a cyan one on the other is what a real
    /// lens does — the channels are complementary, so where the copies still
    /// overlap they sum back toward the original and the split only shows
    /// where they part: at the edges.
    static let fringeRed = Color(UIColor(hex: 0xFF2A2A))
    static let fringeCyan = Color(UIColor(hex: 0x2AF6FF))
}

// MARK: - Hologram material metrics

/// Every number the treatment is built from, with the reasoning.
enum HologramMaterialMetrics {

    // MARK: Scanlines

    /// Distance between scanlines, in points — *points*, not a fraction of
    /// the content, so the pattern has the same physical pitch on a thumbnail
    /// and a zoomed plane and never beats against the artwork's own pixel
    /// grid into moire. Six points is coarse enough that a 1.2pt line is
    /// unmistakably a line at any rendering scale.
    static let scanlineSpacing: CGFloat = 6

    /// Thickness of one scanline. Above a point so it cannot alias away on a
    /// 2x screen, well under half the spacing so the image stays dominant.
    static let scanlineThickness: CGFloat = 1.2

    /// Default upward drift, points per second. Slow: at 7pt/s a line takes
    /// most of a second to cross one spacing, which the eye registers as a
    /// live signal rather than as movement worth watching. (Upward because
    /// the projector is *below* — the image is being pushed up out of it.)
    static let scanlineRate: Double = 7

    /// Peak scanline opacity at full intensity. The lines are additive
    /// brightenings, not black bars: a projection is made of light, and dark
    /// stripes would read as venetian blinds in front of it.
    static let scanlineOpacity: Double = 0.16

    /// The most lines the band may draw whatever size it is given. ~64 lines
    /// cover the tallest plane the app produces; the cap exists because a
    /// line count derived from a view size must not be unbounded on the one
    /// screen nobody measured.
    static let maxScanlines = 400

    // MARK: Chromatic fringe

    /// How far the red and cyan copies are scaled off the original, as a
    /// scale delta about the centre. A scale *is* the required displacement
    /// law: scaling about the centre moves every pixel radially by
    /// `r x delta` — zero at the centre, maximal at the corners — which is
    /// exactly "offset derived from distance-to-centre" with no per-pixel
    /// work at all. 1.2% of the half-diagonal is ~2pt on a board plane:
    /// visible as a coloured lining, not as a double image.
    static let fringeScale: CGFloat = 0.012

    /// Opacity of each fringe copy at full intensity. Low, because the
    /// copies are additive and sit over the base — they should stain the
    /// rim, not restate the picture.
    static let fringeOpacity: Double = 0.4

    /// Where the radial mask that confines the fringe begins and ends, as
    /// fractions of the content's half-extent. Fully clear to 45% out, fully
    /// present by 90%: the centre of the image stays clean and readable.
    static let fringeMaskStart: CGFloat = 0.45
    static let fringeMaskEnd: CGFloat = 0.9

    // MARK: Rim and bloom

    /// The three rim strokes, inner to outer: a hot 1pt line and two wider,
    /// fainter halos. Three widening strokes are the classic cheap bloom —
    /// paint that already happened, where a real blur would be a GPU
    /// resample of the whole surface on every composite.
    static let rimWidths: [CGFloat] = [1, 3, 6]
    static let rimOpacities: [Double] = [0.8, 0.3, 0.12]

    /// Opacity of the additive centre bloom that makes the plate emissive —
    /// the difference between artwork that *is* light and artwork with a
    /// border drawn on it.
    static let bloomOpacity: Double = 0.16

    /// How translucent the base plate is. A hologram you cannot faintly see
    /// through is a poster; below ~0.8 the artwork starts losing its own
    /// colours to whatever is behind it.
    static let plateOpacity: Double = 0.88

    /// How far the base content's saturation is pulled toward the tint's
    /// monochrome. Projected light shifts everything toward the beam colour;
    /// keeping ~70% of the original saturation lets the card art stay
    /// recognisable underneath the cast.
    static let plateSaturation: Double = 0.7

    /// Opacity of the tint wash screened over the base.
    static let tintWashOpacity: Double = 0.22

    /// Corner rounding the rim strokes follow by default. Matches the soft
    /// rectangle the projection clips its artwork to.
    static let cornerRadius: CGFloat = 8

    // MARK: Vertical fade

    /// Where the top dissolve ends and the bottom one begins, as fractions
    /// of height, and what opacity the bottom edge keeps. The top vanishes
    /// completely — that is the projection running out of throw. The bottom
    /// only thins, because it meets the projection cone's light and a fully
    /// clear base would detach the image from the beam casting it.
    static let topFadeEnd: CGFloat = 0.12
    static let bottomFadeStart: CGFloat = 0.9
    static let bottomFadeOpacity: Double = 0.3

    // MARK: Flicker

    /// Length of one flicker window, seconds. In each window the material
    /// *may* glitch once, at a random moment — a chance per window rather
    /// than a repeating cycle, because a metronome reads as an animation and
    /// a projection should misbehave, not perform. 1.15s is deliberately
    /// co-prime-ish with the projection's 4.7s bob so the two never lock.
    static let flickerWindow: Double = 1.15

    /// Probability that a given window contains a glitch. About one visible
    /// stutter every three seconds — often enough to register as a live
    /// signal, rare enough never to be the subject.
    static let flickerChance: Double = 0.35

    /// How long a glitch lasts. Brief: a real dropout is frames, not beats.
    static let flickerDuration: ClosedRange<Double> = 0.05...0.16

    /// How far the brightness dips during a glitch (fraction removed) and
    /// how far the image may jump sideways, points.
    static let flickerDip: ClosedRange<Double> = 0.25...0.55
    static let flickerJitter: CGFloat = 1.5
}

// MARK: - Flicker

/// The glitch schedule, as a pure function of time — no stored state, so a
/// frame can be drawn for any instant and two holograms with different salts
/// never stutter together.
enum HologramFlicker {

    /// What the material should do right now.
    struct State: Equatable {
        /// Brightness multiplier, 1 when steady.
        var brightness: Double
        /// Horizontal jump, points, 0 when steady.
        var jitter: CGFloat

        static let steady = State(brightness: 1, jitter: 0)
    }

    /// The state at `time` seconds for a hologram salted with `salt`.
    ///
    /// Time is cut into fixed windows; each window seeds its own generator
    /// from the window index and the salt, rolls once for whether a glitch
    /// happens at all, and if so places it at a random moment inside the
    /// window. Everything is derived, so the same instant always answers the
    /// same way — the flicker can be scrubbed, paused and resumed for free.
    static func state(at time: Double, salt: UInt64) -> State {
        guard time >= 0 else { return .steady }
        let window = (time / HologramMaterialMetrics.flickerWindow).rounded(.down)
        var rng = SeededGenerator(
            seed: (salt ^ (UInt64(window) &* 0x9E37_79B9_7F4A_7C15)) | 1
        )

        guard Double.random(in: 0..<1, using: &rng) < HologramMaterialMetrics.flickerChance else {
            return .steady
        }

        let duration = Double.random(in: HologramMaterialMetrics.flickerDuration, using: &rng)
        let start = Double.random(
            in: 0...(HologramMaterialMetrics.flickerWindow - duration),
            using: &rng
        )
        let local = time - window * HologramMaterialMetrics.flickerWindow
        guard local >= start, local < start + duration else { return .steady }

        let dip = Double.random(in: HologramMaterialMetrics.flickerDip, using: &rng)
        let jitter = CGFloat(Double.random(in: -1...1, using: &rng))
            * HologramMaterialMetrics.flickerJitter
        return State(brightness: 1 - dip, jitter: jitter)
    }
}

// MARK: - Material

/// The treatment itself. Apply with `.hologramMaterial(...)`.
///
/// The caller owns the clock: pass a `time` that advances (from a periodic
/// timeline, well below display refresh) and the scanlines drift and the
/// image occasionally glitches; pass a constant `time` with
/// `isAnimated: false` and the result is a perfectly still hologram — which
/// is the Reduce Motion presentation, not a degraded one.
struct HologramMaterial: ViewModifier {

    /// Overall strength, 0...1. Scales the wash, fringe, scanlines, rim and
    /// bloom together so the treatment can be turned down without unpicking
    /// its layers.
    var intensity: Double = 1

    /// The projection colour.
    var tint: Color = HologramPalette.beam

    /// Scanline drift, points per second upward.
    var scanlineRate: Double = HologramMaterialMetrics.scanlineRate

    /// Corner rounding the rim strokes follow — match it to however the
    /// content itself is clipped.
    var cornerRadius: CGFloat = HologramMaterialMetrics.cornerRadius

    /// Seconds on the caller's clock. Only its rate of change matters.
    var time: Double = 0

    /// De-synchronises flicker between holograms; derive it from a stable
    /// identity so a given hologram stutters reproducibly.
    var salt: UInt64 = 1

    /// False for a still frame: no drift, no flicker, same plate.
    var isAnimated: Bool = true

    func body(content: Content) -> some View {
        let flicker = isAnimated
            ? HologramFlicker.state(at: time, salt: salt)
            : .steady

        plate(content)
            .overlay {
                HologramScanDrift(
                    tint: tint,
                    intensity: intensity,
                    offset: scanOffset
                )
            }
            .mask { verticalFade }
            .compositingGroup()
            .opacity(flicker.brightness)
            .offset(x: flicker.jitter)
    }

    // MARK: Static plate

    /// Everything that does not depend on time: the tinted base, the two
    /// fringe copies, the rim and the bloom. Flattened with `drawingGroup()`
    /// so it is rasterised once and the ticking layers above composite over
    /// a cached texture.
    private func plate(_ content: Content) -> some View {
        ZStack {
            // Base: the artwork pulled toward the beam — desaturated a step,
            // washed with tint via screen so light is *added*, never inked.
            content
                .saturation(1 - (1 - HologramMaterialMetrics.plateSaturation) * intensity)
                .overlay {
                    tint
                        .opacity(HologramMaterialMetrics.tintWashOpacity * intensity)
                        .blendMode(.screen)
                }

            // Chromatic fringe: the same content isolated to opposing
            // channels and scaled apart about the centre. The scale *is* the
            // distance-to-centre law — displacement r x delta, zero in the
            // middle, maximal at the corners — and the radial mask keeps
            // even the faint central overlap from tinting the readable core.
            fringeCopy(content, channel: HologramPalette.fringeRed, scale: 1 + HologramMaterialMetrics.fringeScale)
            fringeCopy(content, channel: HologramPalette.fringeCyan, scale: 1 - HologramMaterialMetrics.fringeScale)

            // Rim: three widening strokes standing in for a glow blur, plus
            // an additive centre bloom that makes the plate emissive.
            rim
        }
        .compositingGroup()
        .drawingGroup()
        .opacity(1 - (1 - HologramMaterialMetrics.plateOpacity) * intensity)
    }

    /// One channel-isolated, scaled copy of the content, confined to the rim
    /// by a relative radial mask (no geometry needed — the fractions follow
    /// the content's own extent).
    private func fringeCopy(_ content: Content, channel: Color, scale: CGFloat) -> some View {
        content
            .scaleEffect(scale)
            .colorMultiply(channel)
            .blendMode(.plusLighter)
            .opacity(HologramMaterialMetrics.fringeOpacity * intensity)
            .mask {
                EllipticalGradient(
                    colors: [.clear, .white],
                    center: .center,
                    startRadiusFraction: HologramMaterialMetrics.fringeMaskStart,
                    endRadiusFraction: HologramMaterialMetrics.fringeMaskEnd
                )
            }
    }

    /// The edge light and the bloom.
    private var rim: some View {
        ZStack {
            EllipticalGradient(
                colors: [tint.opacity(HologramMaterialMetrics.bloomOpacity * intensity), .clear],
                center: .center,
                startRadiusFraction: 0.1,
                endRadiusFraction: 0.75
            )

            ForEach(HologramMaterialMetrics.rimWidths.indices, id: \.self) { index in
                RoundedRectangle(cornerRadius: cornerRadius)
                    .strokeBorder(
                        tint.opacity(HologramMaterialMetrics.rimOpacities[index] * intensity),
                        lineWidth: HologramMaterialMetrics.rimWidths[index]
                    )
            }
        }
        .blendMode(.plusLighter)
    }

    // MARK: Time-derived pieces

    /// How far the scan band has crawled into its (one-period) cycle.
    private var scanOffset: CGFloat {
        guard isAnimated else { return 0 }
        let travelled = CGFloat(time * scanlineRate)
        return travelled.truncatingRemainder(dividingBy: HologramMaterialMetrics.scanlineSpacing)
    }

    /// The dissolve at both ends: gone at the top (the projection running
    /// out of throw), thinned at the bottom where it meets the cone's light.
    private var verticalFade: some View {
        LinearGradient(
            stops: [
                .init(color: .clear, location: 0),
                .init(color: .white, location: HologramMaterialMetrics.topFadeEnd),
                .init(color: .white, location: HologramMaterialMetrics.bottomFadeStart),
                .init(color: .white.opacity(HologramMaterialMetrics.bottomFadeOpacity), location: 1),
            ],
            startPoint: .top,
            endPoint: .bottom
        )
    }
}

extension View {
    /// Applies the holographic treatment. See `HologramMaterial` for what
    /// each knob does and who should own the clock.
    func hologramMaterial(
        intensity: Double = 1,
        tint: Color = HologramPalette.beam,
        scanlineRate: Double = HologramMaterialMetrics.scanlineRate,
        cornerRadius: CGFloat = HologramMaterialMetrics.cornerRadius,
        time: Double = 0,
        salt: UInt64 = 1,
        isAnimated: Bool = true
    ) -> some View {
        modifier(HologramMaterial(
            intensity: intensity,
            tint: tint,
            scanlineRate: scanlineRate,
            cornerRadius: cornerRadius,
            time: time,
            salt: salt,
            isAnimated: isAnimated
        ))
    }
}

// MARK: - Scanlines

/// The drifting scanline layer: a band rasterised once, one period taller
/// than the content, and translated by the caller's phase. The translation
/// is a compositor transform, so a tick never redraws a line.
private struct HologramScanDrift: View {

    let tint: Color
    let intensity: Double

    /// Phase within one spacing, 0..<spacing. Applied as a negative y
    /// offset, so growing phase moves the lines *up* — the image being
    /// pushed out of a projector below it.
    let offset: CGFloat

    var body: some View {
        GeometryReader { geo in
            HologramScanBand(size: geo.size, tint: tint, intensity: intensity)
                .equatable()
                .offset(y: -offset)
        }
        .clipped()
        .blendMode(.plusLighter)
        .allowsHitTesting(false)
    }
}

/// The rasterised band itself. `Equatable`, so a tick that only moves it
/// never re-runs the draw closure.
private struct HologramScanBand: View, Equatable {

    let size: CGSize
    let tint: Color
    let intensity: Double

    var body: some View {
        let spacing = HologramMaterialMetrics.scanlineSpacing

        Canvas { context, _ in
            let opacity = HologramMaterialMetrics.scanlineOpacity * intensity
            var y: CGFloat = 0
            var drawn = 0
            // One extra period below the visible extent, so the upward slide
            // always has a line ready to enter from the bottom.
            while y <= size.height + spacing, drawn < HologramMaterialMetrics.maxScanlines {
                context.fill(
                    Path(CGRect(
                        x: 0, y: y,
                        width: size.width,
                        height: HologramMaterialMetrics.scanlineThickness
                    )),
                    with: .color(tint.opacity(opacity))
                )
                y += spacing
                drawn += 1
            }
        }
        .frame(width: size.width, height: size.height + spacing)
    }
}

// MARK: - Previews

/// A stand-in picture, so the material can be previewed without the card
/// database: a warm-to-cool gradient with a disc, enough structure to show
/// the fringe, the wash and the scanlines doing their jobs.
private struct MaterialStandIn: View {
    var body: some View {
        ZStack {
            LinearGradient(
                colors: [Palette.accent, CardColor.blue.deepTint],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            Circle()
                .fill(Palette.textPrimary.opacity(0.85))
                .padding(Metrics.spacingXL)
        }
        .clipShape(RoundedRectangle(cornerRadius: HologramMaterialMetrics.cornerRadius))
    }
}

#Preview("Material, live") {
    TimelineView(.periodic(from: .now, by: 1 / 12)) { context in
        MaterialStandIn()
            .frame(width: 180, height: 240)
            .hologramMaterial(
                time: context.date.timeIntervalSinceReferenceDate,
                salt: 0x51E7
            )
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .background(Palette.backdrop)
}

#Preview("Material, still (Reduce Motion presentation)") {
    MaterialStandIn()
        .frame(width: 180, height: 240)
        .hologramMaterial(isAnimated: false)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Palette.backdrop)
}

#Preview("Intensity ramp") {
    HStack(spacing: Metrics.spacingL) {
        ForEach([0.4, 0.7, 1.0], id: \.self) { strength in
            VStack(spacing: Metrics.spacingS) {
                MaterialStandIn()
                    .frame(width: 110, height: 150)
                    .hologramMaterial(intensity: strength, isAnimated: false)
                Text(String(format: "%.1f", strength)).sectionLabel()
            }
        }
    }
    .padding(Metrics.spacingL)
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .background(Palette.backdrop)
}
