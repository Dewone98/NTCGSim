//
//  StageBackdrop.swift
//  NTCGSimulator
//
//  The environment behind and below the field stage's mat — the part of a
//  Master Duel field that makes it a *place*: sky above, silhouetted distance
//  in the middle band, and a drop into shadow under the platform's edge.
//
//  Two sources, one contract. The owner will supply a village illustration;
//  the app must not ship a modelled imitation of it, so nothing procedural
//  here attempts buildings, rooftops or anything village-shaped — the built-in
//  environment is deliberately abstract (a gradient sky, drifting cloud
//  shapes, three bands of rolling silhouette). When art *is* dropped into
//  `Resources/Stage/`, it replaces those bands: split into `far` / `mid` /
//  `near` files it becomes three independently sliding depth layers, and as a
//  single `backdrop` file it stands in as one mid-depth layer. Either way the
//  stage looks finished today and simply gets better when the art lands,
//  with no code change and no re-tuning — the parallax rates come from each
//  layer's assigned distance through `StageCamera`, not from the artwork.
//
//  Why the environment is upright billboards rather than more ground: the
//  camera in `StageScene` deliberately keeps the ground plane's horizon
//  off-screen, so there is no "distance along the ground" left to draw — and
//  an illustration is a flat picture anyway. Billboard layers at assigned
//  depths are the one representation that treats the procedural fallback and
//  the supplied painting identically: both slide at 1/Z of the camera sway
//  and neither is ever perspective-warped, which keeps supplied art crisp.
//
//  Cost shape: every band is rasterised once per size (each layer view is
//  `Equatable`, so the idle tick moves them without re-running a single draw
//  closure), bands are cut to the height they occupy rather than the whole
//  screen, and the moving layers carry `FieldStageMetrics.overscan` of extra
//  width so the sway never reveals an edge. Nothing here allocates, decodes
//  or draws per frame.
//

import SwiftUI
import UIKit
import ImageIO

// MARK: - Stage palette

/// Colour tokens for the stage. They live beside the stage rather than in
/// `Palette` for the same reason `EffectPalette` does: nothing else in the
/// app draws with them, and they are tuned to sit *behind* the board's chrome
/// — always a step darker and softer than the UI so the card faces above stay
/// the brightest thing on screen.
enum FieldStagePalette {

    // Sky ------------------------------------------------------------------

    /// The top of the sky, darkest in dark mode so the status band above the
    /// board never fights a bright backdrop.
    static let skyHigh = Palette.adaptive(dark: 0x0F0B1D, light: 0xC9D7EE)

    /// The warm band low in the sky, just above the silhouettes — the stage's
    /// light source, implied rather than drawn.
    static let skyGlow = Palette.adaptive(dark: 0x3B2C55, light: 0xF0E2D5)

    /// What the sky settles to behind the silhouette bands.
    static let envDeep = Palette.adaptive(dark: 0x171126, light: 0xA9AECB)

    // Environment ----------------------------------------------------------

    /// The three silhouette bands, far to near. Nearer is darker: depth in a
    /// backdrop is contrast against the sky, and the nearest band must also
    /// read as "below" the lit mat behind it.
    static let hillFar  = Palette.adaptive(dark: 0x2C2247, light: 0xAAB4D6)
    static let hillMid  = Palette.adaptive(dark: 0x241B39, light: 0x8E96BD)
    static let hillNear = Palette.adaptive(dark: 0x191129, light: 0x6E749B)

    /// Cloud bodies. Pale violet in the dark scheme — white clouds on a dark
    /// sky read as holes, not weather.
    static let cloud = Palette.adaptive(dark: 0x8E7FB8, light: 0xFFFFFF)

    /// The warm haze where the silhouettes meet the light.
    static let haze = Palette.adaptive(dark: 0xB68A5C, light: 0xFFE7C7)

    /// The shadow the world falls into under the platform's edge.
    static let dropShade = Palette.adaptive(dark: 0x0C0814, light: 0x6A6080)

    // Mat ------------------------------------------------------------------

    /// The mat surface, near (viewer's) end and far (lit) end.
    static let matNear = Palette.adaptive(dark: 0x1D1528, light: 0xE9E1EE)
    static let matFar  = Palette.adaptive(dark: 0x392D4E, light: 0xF7F1F9)

    /// The pool of light mid-mat.
    static let matGlow = Palette.adaptive(dark: 0xC08A50, light: 0xE8B27E)

    /// Zone lines on the mat.
    static let gridLine = Palette.adaptive(dark: 0x9C8ABE, light: 0x6F5F86)

    /// The platform's front face — its "thickness" below the far edge.
    static let platformFace = Palette.adaptive(dark: 0x0D0916, light: 0xB8AEC6)
}

// MARK: - Backdrop layout

/// Vertical design lines of the environment, as fractions of the stage height
/// measured from the top. They are design decisions, not projections: the
/// camera keeps the true horizon off-screen (see `StageScene`), so where the
/// silhouettes stand is composition, chosen to leave the platform's far edge
/// (at 44.5% from the top) a visible gap to fall away into.
private enum BackdropLayout {

    /// The baseline the silhouette bands stand on.
    static let envBase: CGFloat = 0.38

    /// Where the environment bands stop and the under-platform shadow is
    /// fully saturated — everything below is the drop.
    static let envFillBottom: CGFloat = 0.62

    /// Where the sky gradient has fully warmed into `skyGlow`.
    static let skyGlowLine: CGFloat = 0.40

    /// Supplied-art layers are bottom-anchored here: past the silhouette base
    /// so the drop shadow swallows their bottom edge instead of a hard cut.
    static let artBottom: CGFloat = 0.50

    /// The haze band across the silhouette base.
    static let hazeTop: CGFloat = 0.32
    static let hazeBottom: CGFloat = 0.48

    /// The drop-shadow band, clear at the silhouettes and saturated by
    /// `envFillBottom`.
    static let dropTop: CGFloat = 0.40

    /// The cloud band.
    static let cloudTop: CGFloat = 0.04
    static let cloudHeight: CGFloat = 0.26
}

// MARK: - Supplied art

/// The depth slots a supplied environment image may fill, named by file stem:
/// `Resources/Stage/far.png`, `mid`, `near`, or a single `backdrop` (a
/// `stage-` / `stage_` prefix is also accepted). Any common raster extension
/// works, AVIF included, matching the card art pipeline.
enum StageArtSlot: String, CaseIterable {

    case backdrop, far, mid, near

    /// The forward distance the slot's layer stands at — the number its
    /// parallax rate is derived from. A single `backdrop` rides at skyline
    /// depth: one picture is one middle-distance.
    var forwardDistance: CGFloat {
        switch self {
        case .backdrop: return FieldStageMetrics.skylineDistance
        case .far:      return FieldStageMetrics.farHillDistance
        case .mid:      return FieldStageMetrics.skylineDistance
        case .near:     return FieldStageMetrics.ridgeDistance
        }
    }

    /// The band height the image fills, as a fraction of stage height. Deeper
    /// layers stand taller — a far layer owns the sky, a near one is a fringe.
    var bandHeightFraction: CGFloat {
        switch self {
        case .backdrop: return 0.50
        case .far:      return 0.40
        case .mid:      return 0.28
        case .near:     return 0.18
        }
    }
}

/// The bundled stage art, decoded once and republished through Observation.
///
/// Same shape as `CardArtStore`'s manifest but far smaller in scope: at most
/// four images, looked up once, decoded once, kept forever. The lookup and
/// decode happen off the main thread because an AVIF decode is milliseconds
/// the first board presentation should not pay; until it lands the stage
/// draws its procedural environment, which is also the permanent answer when
/// no art ships. Main-thread only, like the effect monitors: `prepare` is
/// called from view `task`s and the only readers are view bodies.
@Observable
final class StageArtLibrary {

    static let shared = StageArtLibrary()

    /// Decoded images by slot. Empty until prepared, and empty forever when
    /// the bundle carries no stage art — which is the shipping state today.
    private(set) var slots: [StageArtSlot: UIImage] = [:]

    @ObservationIgnored
    private var started = false

    /// Folder inside the bundle the art is looked for in, with the same
    /// flattened-bundle fallback the card art uses. The root fallback is safe
    /// here because only exact slot stems are accepted — a card's `N-004`
    /// can never be mistaken for a stage layer.
    private static let subdirectory = "Stage"

    /// Extensions accepted, matching `CardArtStore` so the owner's export
    /// pipeline needs no second rule.
    private static let supportedExtensions = [
        "avif", "AVIF", "png", "PNG", "jpg", "JPG", "jpeg", "heic", "HEIC", "webp",
    ]

    /// Longest-edge ceiling for the decode. 2048px covers a 3x phone stage
    /// band with margin; a poster-sized source is downsampled at decode time
    /// so its full bitmap never exists in memory.
    private static let maxPixelSize = 2048

    private init() {}

    /// Kicks off the one-time lookup. Idempotent; call from any view's task.
    func prepareIfNeeded() {
        guard !started else { return }
        started = true

        DispatchQueue.global(qos: .utility).async {
            let found = Self.loadSlots()
            guard !found.isEmpty else { return }
            DispatchQueue.main.async { [weak self] in
                self?.slots = found
            }
        }
    }

    /// Scans the bundle and decodes whatever slots are present.
    private static func loadSlots() -> [StageArtSlot: UIImage] {
        var candidates: [URL] = []
        for ext in supportedExtensions {
            let urls = Bundle.main.urls(
                forResourcesWithExtension: ext,
                subdirectory: subdirectory
            ) ?? []
            let flattened = urls.isEmpty
                ? (Bundle.main.urls(forResourcesWithExtension: ext, subdirectory: nil) ?? [])
                : urls
            candidates.append(contentsOf: flattened)
        }

        var found: [StageArtSlot: UIImage] = [:]
        for url in candidates {
            guard let slot = slot(for: url), found[slot] == nil else { continue }
            if let image = downsampled(url) { found[slot] = image }
        }
        return found
    }

    /// Which slot a file names, if any.
    private static func slot(for url: URL) -> StageArtSlot? {
        var stem = url.deletingPathExtension().lastPathComponent.lowercased()
        for prefix in ["stage-", "stage_"] where stem.hasPrefix(prefix) {
            stem = String(stem.dropFirst(prefix.count))
        }
        return StageArtSlot(rawValue: stem)
    }

    /// Decodes at most `maxPixelSize` on the longest edge, via ImageIO so the
    /// downsample happens inside the decoder rather than after a full decode.
    private static func downsampled(_ url: URL) -> UIImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
        ]
        guard let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            return nil
        }
        return UIImage(cgImage: cg)
    }
}

// MARK: - Backdrop

/// The environment stack: sky, then either supplied art layers or the
/// procedural bands, then the haze and the drop into shadow. Every moving
/// layer's offset is `StageCamera.parallaxShift` at its assigned distance —
/// the rates are the projection's, not this file's.
struct StageBackdrop: View {

    let camera: StageCamera
    let stageSize: CGSize

    /// Lateral camera offset this frame, world units.
    let cameraOffset: CGFloat

    /// Cloud wind this frame, screen points.
    let windOffset: CGFloat

    var body: some View {
        let art = StageArtLibrary.shared.slots

        ZStack {
            StageSky(stageSize: stageSize)
                .equatable()

            if let single = art[.backdrop] {
                artBand(single, slot: .backdrop)
            } else {
                layer(art, slot: .far, fallback: .far)
                layer(art, slot: .mid, fallback: .skyline)
                layer(art, slot: .near, fallback: .ridge)

                // Clouds belong to the abstract sky only: over an owner's
                // painting they would be a second weather system.
                if art.isEmpty {
                    StageCloudBand(stageSize: stageSize)
                        .equatable()
                        .offset(x: shift(FieldStageMetrics.cloudDistance) + windOffset)
                }
            }

            haze
            dropShade
        }
    }

    // MARK: Layers

    /// One depth layer: the supplied image when present, the silhouette band
    /// when not. Both take the same derived shift, so dropping art in changes
    /// pixels and nothing else.
    @ViewBuilder
    private func layer(
        _ art: [StageArtSlot: UIImage],
        slot: StageArtSlot,
        fallback profile: StageHillProfile
    ) -> some View {
        if let image = art[slot] {
            artBand(image, slot: slot)
        } else {
            StageHillBand(profile: profile, stageSize: stageSize)
                .equatable()
                .offset(x: shift(profile.forwardDistance))
        }
    }

    private func artBand(_ image: UIImage, slot: StageArtSlot) -> some View {
        StageArtBand(
            image: image,
            width: stageSize.width + FieldStageMetrics.overscan * 2,
            height: stageSize.height * slot.bandHeightFraction
        )
        .equatable()
        .position(
            x: stageSize.width / 2,
            y: stageSize.height * BackdropLayout.artBottom
                - stageSize.height * slot.bandHeightFraction / 2
        )
        .offset(x: shift(slot.forwardDistance))
    }

    private func shift(_ forward: CGFloat) -> CGFloat {
        camera.parallaxShift(forward: forward, cameraOffset: cameraOffset, in: stageSize)
    }

    // MARK: Atmosphere

    /// The warm band where silhouettes meet the light — it also swallows the
    /// seam between supplied art and the procedural sky.
    private var haze: some View {
        let top = stageSize.height * BackdropLayout.hazeTop
        let height = stageSize.height * (BackdropLayout.hazeBottom - BackdropLayout.hazeTop)
        return LinearGradient(
            stops: [
                .init(color: .clear, location: 0),
                .init(color: FieldStagePalette.haze.opacity(0.24), location: 0.55),
                .init(color: .clear, location: 1),
            ],
            startPoint: .top, endPoint: .bottom
        )
        .frame(width: stageSize.width, height: height)
        .position(x: stageSize.width / 2, y: top + height / 2)
        .allowsHitTesting(false)
    }

    /// The fall into shadow under the platform: clear at the silhouettes,
    /// saturated below their fill line, so whatever shows beside the mat's
    /// far edge reads as depth below the stage rather than as more backdrop.
    private var dropShade: some View {
        let top = stageSize.height * BackdropLayout.dropTop
        let height = stageSize.height - top
        let saturation = (BackdropLayout.envFillBottom - BackdropLayout.dropTop)
            / (1 - BackdropLayout.dropTop)
        return LinearGradient(
            stops: [
                .init(color: .clear, location: 0),
                .init(color: FieldStagePalette.dropShade.opacity(0.9), location: saturation),
                .init(color: FieldStagePalette.dropShade.opacity(0.9), location: 1),
            ],
            startPoint: .top, endPoint: .bottom
        )
        .frame(width: stageSize.width, height: height)
        .position(x: stageSize.width / 2, y: top + height / 2)
        .allowsHitTesting(false)
    }
}

// MARK: - Sky

/// The sky gradient. Static and full-frame: it is the layer at infinity, and
/// a layer at infinite depth has parallax rate zero — it never moves, which
/// is itself a depth cue against everything that does.
private struct StageSky: View, Equatable {

    let stageSize: CGSize

    var body: some View {
        LinearGradient(
            stops: [
                .init(color: FieldStagePalette.skyHigh, location: 0),
                .init(color: FieldStagePalette.skyGlow, location: BackdropLayout.skyGlowLine),
                .init(color: FieldStagePalette.envDeep, location: 0.72),
                .init(color: FieldStagePalette.envDeep, location: 1),
            ],
            startPoint: .top, endPoint: .bottom
        )
        .frame(width: stageSize.width, height: stageSize.height)
    }
}

// MARK: - Clouds

/// A fixed handful of soft cloud shapes, drawn once into a band and moved as
/// one layer. Radial-gradient blobs rather than blurred views: a blur is a
/// per-composite GPU pass, a gradient is paint that already happened.
private struct StageCloudBand: View, Equatable {

    let stageSize: CGSize

    /// The cloud field: centre x/y (fractions of stage width / height), radii
    /// (fractions of width / height) and opacity. Authored, not random — the
    /// same sky on every launch, and exactly five shapes forever.
    private static let blobs: [(cx: CGFloat, cy: CGFloat, rx: CGFloat, ry: CGFloat, alpha: CGFloat)] = [
        (0.18, 0.11, 0.16, 0.030, 0.32),
        (0.52, 0.07, 0.20, 0.026, 0.26),
        (0.80, 0.14, 0.14, 0.024, 0.30),
        (0.36, 0.19, 0.11, 0.018, 0.20),
        (0.68, 0.23, 0.13, 0.020, 0.16),
    ]

    var body: some View {
        let top = stageSize.height * BackdropLayout.cloudTop
        let height = stageSize.height * BackdropLayout.cloudHeight
        let width = stageSize.width + FieldStageMetrics.overscan * 2

        Canvas { context, _ in
            for blob in Self.blobs {
                let centre = CGPoint(
                    x: blob.cx * stageSize.width + FieldStageMetrics.overscan,
                    y: blob.cy * stageSize.height - top
                )
                let rx = blob.rx * stageSize.width
                let ry = blob.ry * stageSize.height
                context.fill(
                    Path(ellipseIn: CGRect(
                        x: centre.x - rx, y: centre.y - ry,
                        width: rx * 2, height: ry * 2
                    )),
                    with: .radialGradient(
                        Gradient(colors: [
                            FieldStagePalette.cloud.opacity(blob.alpha),
                            .clear,
                        ]),
                        center: centre, startRadius: 0, endRadius: rx
                    )
                )
            }
        }
        .frame(width: width, height: height)
        .position(x: stageSize.width / 2, y: top + height / 2)
    }
}

// MARK: - Silhouette bands

/// The three procedural distance bands. Abstract on purpose: rolling mixed
/// sines, no structure that could read as an imitation of the owner's
/// village art. Each band's waveform is deterministic — the same skyline on
/// every launch — because a backdrop that reshuffles is a backdrop noticed.
enum StageHillProfile: Equatable {

    case far, skyline, ridge

    /// How far above the environment baseline the band's midline rides, as a
    /// fraction of stage height. Farther bands stand higher — that is what
    /// standing behind something means on screen.
    var lift: CGFloat {
        switch self {
        case .far:     return 0.045
        case .skyline: return 0.020
        case .ridge:   return 0
        }
    }

    /// Half-range of the waveform, fraction of stage height. The middle band
    /// is boldest; the near ridge is a broad, calm shoulder under it.
    var amplitude: CGFloat {
        switch self {
        case .far:     return 0.028
        case .skyline: return 0.042
        case .ridge:   return 0.030
        }
    }

    /// Base wavelength, fraction of stage width.
    var wavelength: CGFloat {
        switch self {
        case .far:     return 0.62
        case .skyline: return 0.36
        case .ridge:   return 0.85
        }
    }

    /// Phase shift so the three bands never crest together.
    var phase: CGFloat {
        switch self {
        case .far:     return 0
        case .skyline: return 2.1
        case .ridge:   return 4.2
        }
    }

    /// The distance the band stands at — its parallax identity.
    var forwardDistance: CGFloat {
        switch self {
        case .far:     return FieldStageMetrics.farHillDistance
        case .skyline: return FieldStageMetrics.skylineDistance
        case .ridge:   return FieldStageMetrics.ridgeDistance
        }
    }

    var color: Color {
        switch self {
        case .far:     return FieldStagePalette.hillFar
        case .skyline: return FieldStagePalette.hillMid
        case .ridge:   return FieldStagePalette.hillNear
        }
    }
}

/// One silhouette band, rasterised once at its own height.
private struct StageHillBand: View, Equatable {

    let profile: StageHillProfile
    let stageSize: CGSize

    /// Sampling step for the ridge line, points. Fine enough that the curve
    /// is smooth at any width, coarse enough that a band is ~60 segments.
    private static let sampleStep: CGFloat = 8

    /// Headroom above the tallest crest kept inside the canvas.
    private static let crestMargin: CGFloat = 8

    var body: some View {
        let h = stageSize.height
        let top = (BackdropLayout.envBase - profile.lift - profile.amplitude) * h
            - Self.crestMargin
        let bottom = BackdropLayout.envFillBottom * h
        let width = stageSize.width + FieldStageMetrics.overscan * 2
        let height = max(1, bottom - top)

        Canvas { context, canvasSize in
            let baseline = (BackdropLayout.envBase - profile.lift) * h - top
            var path = Path()
            path.move(to: CGPoint(x: 0, y: crest(atCanvasX: 0, baseline: baseline)))
            var x = Self.sampleStep
            while x < canvasSize.width {
                path.addLine(to: CGPoint(x: x, y: crest(atCanvasX: x, baseline: baseline)))
                x += Self.sampleStep
            }
            path.addLine(to: CGPoint(
                x: canvasSize.width,
                y: crest(atCanvasX: canvasSize.width, baseline: baseline)
            ))
            path.addLine(to: CGPoint(x: canvasSize.width, y: canvasSize.height))
            path.addLine(to: CGPoint(x: 0, y: canvasSize.height))
            path.closeSubpath()
            context.fill(path, with: .color(profile.color))
        }
        .frame(width: width, height: height)
        .position(x: stageSize.width / 2, y: top + height / 2)
    }

    /// The ridge line: three mixed sines at related but non-integer
    /// frequencies, which rolls without visibly repeating across any width
    /// the app runs at.
    private func crest(atCanvasX x: CGFloat, baseline: CGFloat) -> CGFloat {
        let u = (x - FieldStageMetrics.overscan)
            / (stageSize.width * profile.wavelength) * 2 * .pi + profile.phase
        let wave = 0.55 * sin(u) + 0.30 * sin(2.7 * u + 1.7) + 0.15 * sin(5.3 * u + 0.4)
        return baseline - profile.amplitude * stageSize.height * wave
    }
}

// MARK: - Art band

/// One supplied-art layer: aspect-filled into its band, clipped, never
/// warped. Compared by image identity — the library decodes each slot once,
/// so identity is the cheap and correct equality.
private struct StageArtBand: View, Equatable {

    let image: UIImage
    let width: CGFloat
    let height: CGFloat

    static func == (lhs: StageArtBand, rhs: StageArtBand) -> Bool {
        lhs.image === rhs.image && lhs.width == rhs.width && lhs.height == rhs.height
    }

    var body: some View {
        Image(uiImage: image)
            .resizable()
            .scaledToFill()
            .frame(width: width, height: height)
            .clipped()
    }
}

// MARK: - Previews

#Preview("Backdrop, procedural") {
    GeometryReader { geo in
        StageBackdrop(
            camera: .standard,
            stageSize: geo.size,
            cameraOffset: 0,
            windOffset: 0
        )
    }
    .background(Palette.backdrop)
    .ignoresSafeArea()
}

#Preview("Backdrop, mid-sway") {
    GeometryReader { geo in
        StageBackdrop(
            camera: .standard,
            stageSize: geo.size,
            cameraOffset: FieldStageMetrics.swayAmplitude,
            windOffset: FieldStageMetrics.windAmplitude
        )
    }
    .background(Palette.backdrop)
    .ignoresSafeArea()
}
