//
//  StageScene.swift
//  NTCGSimulator
//
//  The camera and the clock behind the field stage — the 3D backdrop that sits
//  underneath the 2D board, in the manner of Master Duel's duel fields.
//
//  What that reference actually does, and why this file copies the shape of it
//  rather than the engine: Master Duel's field is a raked mat — a platform
//  viewed from a raised camera pitched steeply down, so the far edge is higher
//  on screen, narrower, and visibly converging — floating as a diorama over an
//  environment that shows *behind and below* it. The camera drifts very slowly
//  in idle, and the environment layers slide against each other at rates set
//  by their distance, which is what makes the backdrop read as a place rather
//  than a picture. Crucially, none of the playable UI lives in that
//  projection: the cards and buttons are screen-space 2D drawn over the top,
//  which is why they stay pixel-crisp while the world behind them has depth.
//  This stage keeps that split absolute — it renders under the board, takes no
//  touches, and never transforms a card.
//
//  Why this is a SwiftUI composition and not an `SCNView`: everything the
//  stage shows is a billboard — a sky gradient, silhouette bands, a ground
//  plane. SceneKit would render those same textured quads, but through a
//  continuously scheduled Metal view whose slowest steady rate is a divisor of
//  the display's, with its own drawable memory and a second render pass the
//  compositor then blends anyway. A ground plane under a pinhole camera has a
//  closed-form projection (derived below), so the trapezoid, the grid and
//  every parallax rate can be *computed* and handed to the compositor as
//  ordinary layers. `TimelineView(.periodic)` then caps the idle clock at an
//  exact rate SceneKit cannot express (8 fps), and pausing is free: no ticks,
//  no invalidation, a wholly static layer tree.
//
//  The projection, in full, because these five lines are the whole illusion.
//  World space: x lateral, y up, z forward along the ground; the ground is
//  y = 0 and the camera sits at (0, h, 0) pitched down by θ with vertical
//  field of view 2φ. A ground point (x, 0, z) relative to the camera is
//  (x, −h, z); against the pitched camera basis its optical depth and vertical
//  offset are
//
//      Z = h·sinθ + z·cosθ          V = z·sinθ − h·cosθ
//
//  and the normalised image point, in units of half the view height, is
//
//      x' = x / (Z·tanφ)            y' = V / (Z·tanφ)
//
//  As z → ∞, y' → tanθ/tanφ: the horizon. With the chosen pitch that limit is
//  1.5 — *above the top of the screen* — which is deliberate. A horizon in
//  frame turns any ground plane into a road to infinity, because the last few
//  degrees of elevation hold unbounded depth; keeping the vanishing point
//  off-screen is what makes the mat read as a raked table (near edge ~1.8x
//  the width of the far edge) instead of a runway, and it is exactly the
//  framing the reference uses. The environment is therefore not "ground
//  reaching the horizon" but a stack of upright backdrop layers standing
//  beyond the platform's far edge — which is also what makes the supplied-art
//  path in `StageBackdrop` honest: an illustration *is* an upright layer.
//
//  Parallax falls straight out of the same projection instead of being tuned
//  by hand. Slide the camera by Δx and every point shifts on screen by
//  Δx/(Z·tanφ) — rate proportional to 1/Z, nothing else to choose. For the
//  ground plane specifically the derivation collapses further: subtracting
//  y' from the horizon gives y'ₕ − y' = h/(cosθ·Z·tanφ), so the shift of any
//  ground point is (Δx·cosθ/h)·(y'ₕ − y') — *exactly* a shear about the
//  horizon line. The ground layer is therefore rasterised once and its whole
//  parallax is a per-tick affine transform, which is how the stage moves
//  without redrawing a single pixel.
//

import SwiftUI

// MARK: - Stage metrics

/// Every number the stage is built from, with the reasoning that produced it.
enum FieldStageMetrics {

    // MARK: Camera

    /// Vertical field of view, degrees. Wide enough that the near/far scale
    /// change across the mat is obvious — a narrow lens flattens the rake into
    /// a skewed rectangle — without the edge stretch a phone-held wide-angle
    /// shot shows.
    static let verticalFOVDegrees: Double = 55

    /// Camera pitch below horizontal, degrees. The one aesthetic camera knob:
    /// 38° puts the ground plane's vanishing point about a quarter of a screen
    /// *above* the top edge (tan38°/tan27.5° ≈ 1.5 in half-height units), so
    /// the mat converges visibly but never collapses to a point in frame, and
    /// lands the platform's far edge at `platformFarFraction` with a near:far
    /// width ratio of ~1.8 — the raked-table framing the reference uses.
    static let pitchDegrees: Double = 38

    /// Camera height above the mat, in world units. The projection is scale
    /// invariant — doubling `h` and every distance reproduces the same image —
    /// so this only fixes the unit; distances below are expressed against it.
    static let cameraHeight: CGFloat = 3

    /// Where the platform's far edge sits on screen, as a fraction of height
    /// from the bottom. Just above the midline: low enough that the far half
    /// of the screen belongs to the environment, high enough that the mat is
    /// still the subject.
    static let platformFarFraction: CGFloat = 0.555

    /// How far past the bottom edge the platform's near edge starts, as a
    /// multiplier on the distance that would land it exactly on the edge.
    /// A mat cut off precisely at the bezel reads as cropped; bleeding it
    /// keeps the cut invisible under the sway.
    static let nearOvershoot: CGFloat = 0.94

    /// Extra width the near edge carries beyond what covering the viewport
    /// requires, so the sway never drags a mat corner into view.
    static let platformBleed: CGFloat = 1.05

    // MARK: Idle clock

    /// Ticks per second while the stage is alive. The sway crosses ~14pt in a
    /// 26s period — under 2pt/s — so 8 ticks a second moves layers by fractions
    /// of a point per frame; anything faster is heat with no visible payoff,
    /// and between ticks the layer tree is static so ProMotion can idle.
    static let idleTickRate: Double = 8

    /// The reduced rate under `.fair` thermal state — half speed before the
    /// stage gives up motion entirely at `.serious`.
    static let easedTickRate: Double = 4

    // MARK: Idle motion

    /// Camera sway amplitude, world units. At the derived rates this is ~14pt
    /// at the very bottom of a phone screen and under 3pt for the environment
    /// bands — motion the eye registers as life, not as an animation playing.
    static let swayAmplitude: CGFloat = 0.05

    /// Seconds per full sway cycle. Long enough that the drift is never the
    /// thing being watched.
    static let swayPeriod: Double = 26

    /// Cloud drift amplitude, screen points. Wind is motion *of* the clouds,
    /// not of the camera, so it is authored in screen space at cloud depth
    /// rather than derived — the one motion constant that is aesthetic.
    static let windAmplitude: CGFloat = 12

    /// Seconds per full wind cycle, deliberately co-prime-ish with the sway so
    /// the two never visibly synchronise.
    static let windPeriod: Double = 53

    // MARK: Depth assignments (forward distance z, world units)

    /// The nearest environment band, standing just beyond the platform edge.
    static let ridgeDistance: CGFloat = 18

    /// The middle skyline band — where a supplied backdrop illustration sits.
    static let skylineDistance: CGFloat = 32

    /// The farthest silhouette band.
    static let farHillDistance: CGFloat = 55

    /// The cloud layer. Nearly static under parallax, as clouds are.
    static let cloudDistance: CGFloat = 80

    // MARK: Ground detail

    /// World spacing between the mat's column lines. At the near edge this
    /// projects to ~70pt on a phone — zone-sized panels, not graph paper.
    static let gridColumnSpacing: CGFloat = 0.27

    /// World spacing between the mat's row lines; the perspective-correct
    /// crowding of these toward the far edge is what sells the rake.
    static let gridRowSpacing: CGFloat = 0.55

    // MARK: Cost ceilings

    /// The most grid lines the mat may draw either way, whatever a viewport's
    /// arithmetic asks for. Both are headroom, not working limits — a phone
    /// draws ~7 columns and ~6 rows — and exist for the same reason the effect
    /// caps do: a count derived from a view size must not be unbounded on the
    /// one screen nobody measured.
    static let maxGridColumns = 41
    static let maxGridRows = 24

    /// Horizontal overdraw on every moving layer, points per side. It must
    /// exceed the largest shift any layer can take: the sway maxes at ~14pt at
    /// the screen's bottom corner and the wind at 12pt.
    static let overscan: CGFloat = 24
}

// MARK: - Camera

/// The pinhole camera the stage is projected through. All of the maths lives
/// here so the ground plane, the parallax rates and the shear are provably the
/// same projection — the header derivation, executable.
struct StageCamera: Equatable {

    /// tan of half the vertical field of view.
    let tanHalfFOV: CGFloat

    /// Pitch below horizontal, radians, with its trig precomputed because
    /// every projected point uses both.
    let pitch: CGFloat
    let sinPitch: CGFloat
    let cosPitch: CGFloat

    /// Camera height above the ground plane, world units.
    let height: CGFloat

    /// Forward distance to the platform's near edge — the row that projects
    /// just past the bottom of the screen.
    let platformNear: CGFloat

    /// Forward distance to the platform's far edge — the row that projects at
    /// `FieldStageMetrics.platformFarFraction` of the screen height.
    let platformFar: CGFloat

    /// The one camera the stage uses. Built from the metrics rather than
    /// stored as numbers so changing a token re-derives everything downstream.
    static let standard: StageCamera = {
        let fov = FieldStageMetrics.verticalFOVDegrees * .pi / 180
        let pitch = FieldStageMetrics.pitchDegrees * .pi / 180
        let tanHalf = CGFloat(tan(fov / 2))
        let h = FieldStageMetrics.cameraHeight

        // Near edge: the ray through the bottom of the frame is depressed by
        // (pitch + halfFOV), and meets the ground at h/tan of that angle.
        let bottomRay = pitch + atan(Double(tanHalf))
        let near = h / CGFloat(tan(bottomRay)) * FieldStageMetrics.nearOvershoot

        // Far edge: invert y' = (z·sinθ − h·cosθ)/((h·sinθ + z·cosθ)·tanφ)
        // for the designed screen fraction. With t = y'·tanφ:
        //     z = h·(cosθ + t·sinθ) / (sinθ − t·cosθ)
        let ndc = FieldStageMetrics.platformFarFraction * 2 - 1
        let t = ndc * tanHalf
        let s = CGFloat(sin(pitch)), c = CGFloat(cos(pitch))
        let far = h * (c + t * s) / (s - t * c)

        return StageCamera(
            tanHalfFOV: tanHalf,
            pitch: CGFloat(pitch),
            sinPitch: s,
            cosPitch: c,
            height: h,
            platformNear: near,
            platformFar: far
        )
    }()

    // MARK: Projection

    /// Optical depth of a ground point at forward distance `z` — the `Z` of
    /// the header derivation, and the only number parallax depends on.
    func opticalDepth(forward z: CGFloat) -> CGFloat {
        height * sinPitch + z * cosPitch
    }

    /// Projects the ground point (x, 0, z) into view coordinates. `size` is
    /// the stage's frame; y grows downward as screen points do.
    func project(x: CGFloat, z: CGFloat, in size: CGSize) -> CGPoint {
        let depth = opticalDepth(forward: z)
        let vertical = z * sinPitch - height * cosPitch
        let half = size.height / 2
        return CGPoint(
            x: size.width / 2 + x / (depth * tanHalfFOV) * half,
            y: half - vertical / (depth * tanHalfFOV) * half
        )
    }

    /// Screen y of the ground plane's horizon — the pivot of the shear. With
    /// the standard pitch it is *negative*: about a quarter of a screen above
    /// the top edge, off-frame by design (see the header).
    func horizonY(in size: CGSize) -> CGFloat {
        size.height / 2 * (1 - (sinPitch / cosPitch) / tanHalfFOV)
    }

    // MARK: Parallax

    /// Screen shift of a layer at forward distance `z` when the camera slides
    /// by `offset` world units: Δx' = −Δx/(Z·tanφ), in half-height units.
    /// This is the projection differentiated, not a tuned rate — every layer's
    /// speed comes from its depth and nowhere else.
    func parallaxShift(forward z: CGFloat, cameraOffset offset: CGFloat, in size: CGSize) -> CGFloat {
        -offset / (opticalDepth(forward: z) * tanHalfFOV) * size.height / 2
    }

    /// The shear slope that re-images the *entire* ground plane after a
    /// camera slide of `offset`: x' = x + m·(y − yₕ) with m = −Δx·cosθ/h.
    /// Exact for every ground point (the header shows the two-line proof), so
    /// the mat's parallax costs one affine transform and zero redraws.
    func groundShear(cameraOffset offset: CGFloat) -> CGFloat {
        -offset * cosPitch / height
    }

    /// The mat half-width that keeps the near edge bleeding past both sides
    /// of the viewport, overscan included, on any aspect ratio.
    func platformHalfWidth(in size: CGSize) -> CGFloat {
        let halfScreen = size.width / 2 + FieldStageMetrics.overscan
        guard size.height > 0 else { return 0 }
        return halfScreen / (size.height / 2)
            * opticalDepth(forward: platformNear) * tanHalfFOV
            * FieldStageMetrics.platformBleed
    }
}

// MARK: - Idle drift

/// The stage's idle motion, as pure functions of wall-clock time. Phases are
/// measured from the reference date so a stage that pauses and resumes picks
/// up where the clock is, not where it left off — no stored animation state,
/// nothing to leak, nothing to reset.
enum StageDrift {

    /// Lateral camera offset, world units.
    static func cameraOffset(at date: Date) -> CGFloat {
        let t = date.timeIntervalSinceReferenceDate
        return FieldStageMetrics.swayAmplitude
            * CGFloat(sin(t * 2 * .pi / FieldStageMetrics.swayPeriod))
    }

    /// Cloud wind offset, screen points, phase-shifted off the sway so the
    /// two motions never visibly lock together.
    static func windOffset(at date: Date) -> CGFloat {
        let t = date.timeIntervalSinceReferenceDate
        return FieldStageMetrics.windAmplitude
            * CGFloat(sin(t * 2 * .pi / FieldStageMetrics.windPeriod + 0.7))
    }
}

// MARK: - Thermal monitor

/// The device's thermal state, as something a view can watch.
///
/// Same shape and same reasoning as `EffectPowerMonitor`: `ProcessInfo`
/// answers but does not publish, so this listens for the change notification
/// and republishes through Observation. One shared instance because the state
/// belongs to the device, and main-thread only because the notification is
/// delivered on the main queue and the only readers are view bodies.
@Observable
final class StageThermalMonitor {

    static let shared = StageThermalMonitor()

    /// The current thermal state. `.fair` slows the stage; `.serious` and
    /// above stop it.
    private(set) var state: ProcessInfo.ThermalState

    @ObservationIgnored
    private var observer: NSObjectProtocol?

    private init() {
        state = ProcessInfo.processInfo.thermalState
        observer = NotificationCenter.default.addObserver(
            forName: ProcessInfo.thermalStateDidChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.state = ProcessInfo.processInfo.thermalState
        }
    }

    deinit {
        if let observer { NotificationCenter.default.removeObserver(observer) }
    }
}

// MARK: - Pulse

/// What the stage's clock may do right now, given everything that can ask it
/// to stop. One verdict rather than five scattered checks, for the same
/// reason `EffectBudget` collapses its two switches: every condition wants
/// the same response — hold still — and a stage that honoured some of them
/// would be exactly as hot on the device that could least afford it.
struct StagePulse: Equatable {

    /// Seconds between ticks, or nil to hold a single static frame.
    let tickInterval: Double?

    /// The current verdict. Stillness wins whenever any voice asks for it:
    /// the player (Reduce Motion, the stage toggle handles off entirely), the
    /// battery (Low Power Mode), the chassis (thermal), or the board itself
    /// (`isPaused` — a jutsu effect playing, or the scene not active).
    @MainActor
    static func current(reduceMotion: Bool, isPaused: Bool) -> StagePulse {
        if isPaused || reduceMotion || EffectPowerMonitor.shared.isLowPower {
            return StagePulse(tickInterval: nil)
        }
        switch StageThermalMonitor.shared.state {
        case .nominal:
            return StagePulse(tickInterval: 1 / FieldStageMetrics.idleTickRate)
        case .fair:
            return StagePulse(tickInterval: 1 / FieldStageMetrics.easedTickRate)
        default:
            return StagePulse(tickInterval: nil)
        }
    }
}

// MARK: - Scene

/// The composed stage: environment behind, raked mat in front, one clock over
/// both. Layers are rasterised once (each is `Equatable`, so a tick that only
/// moves them never re-runs a draw closure) and the per-tick work is a handful
/// of offsets and one shear — transforms the compositor applies, not pixels
/// the app repaints.
struct StageScene: View {

    /// External stop signal — the board raises it while a jutsu effect is
    /// playing and while the scene is not active.
    var isPaused: Bool = false

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// The timeline's epoch, captured at install like every effect clock in
    /// the app; phases still come from absolute time via `StageDrift`.
    @State private var mounted = Date.now

    var body: some View {
        GeometryReader { geo in
            let pulse = StagePulse.current(reduceMotion: reduceMotion, isPaused: isPaused)

            Group {
                if let interval = pulse.tickInterval {
                    TimelineView(.periodic(from: mounted, by: interval)) { context in
                        frame(at: context.date, in: geo.size)
                    }
                } else {
                    // A held frame re-centres the sway rather than freezing
                    // mid-phase: storing the pause instant would exist only to
                    // hide a sub-15pt settle, and every pause trigger arrives
                    // either under a full-screen effect or off-screen.
                    frame(at: nil, in: geo.size)
                }
            }
        }
        .clipped()
        .allowsHitTesting(false)
        .accessibilityHidden(true)
        .task { StageArtLibrary.shared.prepareIfNeeded() }
    }

    // MARK: One frame

    /// The layer stack at one instant. `date == nil` is the still frame.
    private func frame(at date: Date?, in size: CGSize) -> some View {
        let camera = StageCamera.standard
        let sway: CGFloat
        let wind: CGFloat
        if let date {
            sway = StageDrift.cameraOffset(at: date)
            wind = StageDrift.windOffset(at: date)
        } else {
            sway = 0
            wind = 0
        }
        let shear = camera.groundShear(cameraOffset: sway)

        return ZStack {
            StageBackdrop(
                camera: camera,
                stageSize: size,
                cameraOffset: sway,
                windOffset: wind
            )

            StageGroundPlane(camera: camera, stageSize: size)
                .equatable()
                // The exact ground-plane parallax: a shear about the horizon
                // line (x' = x + m·(y − yₕ)), per the header derivation.
                .transformEffect(CGAffineTransform(
                    a: 1, b: 0,
                    c: shear, d: 1,
                    tx: -shear * camera.horizonY(in: size), ty: 0
                ))
        }
        .frame(width: size.width, height: size.height)
    }
}

// MARK: - Ground plane

/// The raked mat: a trapezoid solved by `StageCamera`, shaded and gridded,
/// rasterised once per size. Everything inside is projected geometry — the
/// converging column lines and the rows crowding toward the far edge are the
/// same `project` call the corners use, which is what makes the rake read as
/// depth rather than as a skewed rectangle.
struct StageGroundPlane: View, Equatable {

    let camera: StageCamera
    let stageSize: CGSize

    /// Screen depth of the platform's front face — the sliver of "thickness"
    /// under the far edge that makes the mat a floating slab, not a decal.
    private static let faceDrop: CGFloat = 10

    /// Vertical margin above the far edge kept inside the canvas so the rim
    /// light is not clipped.
    private static let rimHeadroom: CGFloat = 24

    var body: some View {
        let farY = stageSize.height * (1 - FieldStageMetrics.platformFarFraction)
        let top = max(0, farY - Self.rimHeadroom)
        let width = stageSize.width + FieldStageMetrics.overscan * 2
        let height = max(1, stageSize.height - top)

        Canvas { context, _ in
            draw(in: context, canvasTop: top)
        }
        .frame(width: width, height: height)
        .position(x: stageSize.width / 2, y: top + height / 2)
    }

    /// Draws in stage coordinates shifted by (`overscan`, `canvasTop`).
    private func draw(in context: GraphicsContext, canvasTop: CGFloat) {
        let halfW = camera.platformHalfWidth(in: stageSize)
        guard halfW > 0 else { return }

        func point(x: CGFloat, z: CGFloat) -> CGPoint {
            var p = camera.project(x: x, z: z, in: stageSize)
            p.x += FieldStageMetrics.overscan
            p.y -= canvasTop
            return p
        }

        let nearL = point(x: -halfW, z: camera.platformNear)
        let nearR = point(x: halfW, z: camera.platformNear)
        let farL = point(x: -halfW, z: camera.platformFar)
        let farR = point(x: halfW, z: camera.platformFar)

        // The platform's front face, drawn first so the top overlaps it.
        var face = Path()
        face.move(to: farL)
        face.addLine(to: farR)
        face.addLine(to: CGPoint(x: farR.x, y: farR.y + Self.faceDrop))
        face.addLine(to: CGPoint(x: farL.x, y: farL.y + Self.faceDrop))
        face.closeSubpath()
        context.fill(face, with: .color(FieldStagePalette.platformFace))

        // The mat surface, lit from the far edge: distance-fades toward the
        // viewer the way a stage floor falls off from its key light.
        var mat = Path()
        mat.move(to: nearL)
        mat.addLine(to: farL)
        mat.addLine(to: farR)
        mat.addLine(to: nearR)
        mat.closeSubpath()
        context.fill(mat, with: .linearGradient(
            Gradient(colors: [FieldStagePalette.matFar, FieldStagePalette.matNear]),
            startPoint: CGPoint(x: (farL.x + farR.x) / 2, y: farL.y),
            endPoint: CGPoint(x: (nearL.x + nearR.x) / 2, y: nearL.y)
        ))

        // A soft pool of light where the action sits, centred mid-mat.
        let centre = point(x: 0, z: (camera.platformNear + camera.platformFar) / 2)
        let glowRadius = (nearR.x - nearL.x) * 0.34
        context.fill(
            Path(ellipseIn: CGRect(
                x: centre.x - glowRadius, y: centre.y - glowRadius * 0.55,
                width: glowRadius * 2, height: glowRadius * 1.1
            )),
            with: .radialGradient(
                Gradient(colors: [FieldStagePalette.matGlow.opacity(0.16), .clear]),
                center: centre, startRadius: 0, endRadius: glowRadius
            )
        )

        // Grid: column lines converge toward the (off-screen) vanishing point
        // and row lines crowd toward the far edge — both are projected world
        // lines, so the convergence is the camera's, not an approximation.
        var grid = Path()
        var columns = 0
        var x: CGFloat = 0
        while x <= halfW, columns < FieldStageMetrics.maxGridColumns {
            grid.move(to: point(x: x, z: camera.platformNear))
            grid.addLine(to: point(x: x, z: camera.platformFar))
            columns += 1
            if x > 0, columns < FieldStageMetrics.maxGridColumns {
                grid.move(to: point(x: -x, z: camera.platformNear))
                grid.addLine(to: point(x: -x, z: camera.platformFar))
                columns += 1
            }
            x += FieldStageMetrics.gridColumnSpacing
        }
        var rows = 0
        var z = camera.platformFar
        while z >= camera.platformNear, rows < FieldStageMetrics.maxGridRows {
            grid.move(to: point(x: -halfW, z: z))
            grid.addLine(to: point(x: halfW, z: z))
            rows += 1
            z -= FieldStageMetrics.gridRowSpacing
        }
        context.stroke(grid, with: .color(FieldStagePalette.gridLine.opacity(0.13)), lineWidth: 1)

        // Side edges, barely there — they close the slab's silhouette.
        var edges = Path()
        edges.move(to: nearL)
        edges.addLine(to: farL)
        edges.move(to: nearR)
        edges.addLine(to: farR)
        context.stroke(edges, with: .color(FieldStagePalette.gridLine.opacity(0.22)), lineWidth: 1)

        // Rim light along the far edge: the one warm accent, the line the eye
        // reads as "the mat ends and the world begins".
        var rim = Path()
        rim.move(to: farL)
        rim.addLine(to: farR)
        context.stroke(rim, with: .color(Palette.accent.opacity(0.45)), lineWidth: 1.5)
    }
}

// MARK: - Previews

#Preview("Stage scene") {
    StageScene()
        .background(Palette.backdrop)
}

#Preview("Stage scene, held still") {
    StageScene(isPaused: true)
        .background(Palette.backdrop)
}

#Preview("Stage scene, light") {
    StageScene()
        .background(Palette.backdrop)
        .preferredColorScheme(.light)
}
