//
//  Card3DView.swift
//  NTCGSimulator
//
//  The SwiftUI face of the 3D cards: one `SCNView` rendering every card
//  slab on the mat, through the SAME camera the field stage is projected
//  with.
//
//  The one structural rule, inherited from the stage: there is exactly one
//  3D space. `FieldStageMetrics` documents the stage's pinhole camera —
//  pitch 38 degrees, vertical FOV 55, height 3 world units above the mat,
//  vanishing point off the top of frame — and `StageCamera.standard`
//  derives the mat's near and far rows from it. This view builds its
//  `SCNCamera` from those SAME tokens and lays slabs on the SAME ground
//  plane, so a 3D card, the drawn mat under it and the holograms above it
//  all foreshorten identically. A second camera that "looked about right"
//  would disagree with the stage by a few degrees everywhere, and the two
//  spaces would visibly shear against each other the moment anything
//  moved. (Coordinate note: the stage's maths uses z forward-positive,
//  SceneKit looks down -Z, so world z here is the negated stage forward —
//  a mirror-free relabelling that leaves every projected point identical.)
//
//  Cost discipline, concretely:
//  * ONE `SCNView` for the whole board. Nodes are a transform and three
//    draw calls; views are a Metal layer, a drawable pool and a compositor
//    surface each. The view renders at most `Card3DSceneMetrics.maxNodes`
//    slabs — twelve covers both sides' five character rows and two
//    leaders, and the cap means a caller bug can never scale the scene.
//  * The view only runs its render loop while something moves. Live, it
//    plays at 30 fps (the specular sweep is the only continuous motion —
//    half the display's rate, and SceneKit idles the GPU between frames).
//    Still, `isPlaying` is false and SceneKit renders single frames on
//    scene changes only: a motionless board costs zero GPU.
//  * The degradation ladder collapses every stop signal the same way the
//    stage's `StagePulse` does, in `Card3DBudget`:
//      - master switch off (`Card3DDefaults.enabledKey`) — no scene at
//        all; the board's 2D cards are exactly what they were.
//      - thermal `.serious`+ — the view renders NOTHING and the board
//        falls back to its 2D cards wholesale: the cheapest 3D card is
//        the one that is not there.
//      - Low Power Mode or `.fair` thermal — still frame AND simplified
//        (unlit) materials: same cards, lighting bill removed.
//      - Reduce Motion, a full-screen effect, or an inactive scene — a
//        held frame with full materials: stillness is a presentation
//        here, not a degradation.
//
//  The board composes this ABOVE the stage and BELOW its 2D chrome, and
//  chooses which cards live here versus in the 2D layer; a placement is
//  deliberately just "this card, lying here" so that choice stays the
//  board's.
//

import SceneKit
import SwiftUI

// MARK: - Defaults

/// Persistence for the 3D cards' master switch. A namespace rather than a
/// value on `SettingsStore` so Settings, the board and a debug tool all
/// bind the same key without a schema change — the same contract as
/// `FieldStageDefaults` and `HologramDefaults`.
enum Card3DDefaults {

    /// Master switch. When false no 3D card renders at all — not a paused
    /// scene, no scene — and the board shows its 2D cards exactly as it
    /// did before this file existed.
    static let enabledKey = "ncg.cards3d.enabled"
}

// MARK: - Scene metrics

/// The scene-level numbers: where cards may lie and what the scene may
/// cost. Geometry proportions live in `Card3DMetrics`, surface numbers in
/// `Card3DMaterialMetrics`.
enum Card3DSceneMetrics {

    /// Default card width, world units. The stage's mat draws its zone
    /// columns `FieldStageMetrics.gridColumnSpacing` (0.27) apart, so a
    /// 0.22 card sits in a zone with a visible gutter — the same relation
    /// a printed mat gives a sleeve.
    static let cardWidth: CGFloat = 0.22

    /// Half the playable field's lateral extent, world units. Five zone
    /// columns at 0.27 spacing span 1.35; placements built from fractions
    /// map -1...1 across it.
    static let fieldHalfWidth: CGFloat = 0.675

    /// The most slabs the scene will render, whatever it is handed.
    ///
    /// A full board is two Leaders, two Summon markers, ten character slots
    /// and the Supports both players have turned face-up — twenty covers
    /// every position the mat can legally reach with room for a face-up
    /// Support on each side. The cap exists because a count that arrives
    /// from a caller must not be unbounded on the one frame nobody measured:
    /// the Characters row itself is unbounded, since an effect can flood a
    /// side past its printed five slots.
    static let maxNodes = 20

    /// Longest edge, pixels, a face's artwork is decoded at. A board slab
    /// projects to under ~100 pt; 320 px covers a 3x phone with margin,
    /// and the size-aware database call keeps a full printing's bitmap
    /// from ever existing for a board decoration.
    static let artPixelSize = 320

    /// Frame rate while the sweep runs. Half the display's base rate: the
    /// only continuous motion is a light easing through a few degrees, and
    /// 30 Hz renders that without a visible step. Stillness does not tick
    /// at all — `isPlaying` goes false instead.
    static let liveFrameRate = 30

    /// Camera clip planes, world units. The mat's rows lie roughly 1.3 to
    /// 4.3 units out; both planes carry lazy margin, and the ratio is
    /// small enough that depth precision is never in play.
    static let cameraNearClip: Double = 0.05
    static let cameraFarClip: Double = 50
}

// MARK: - Placement

/// One card on the mat: which card, where it lies, and how.
///
/// Coordinates are the STAGE'S ground plane, in its world units — x
/// lateral from the centre line, `forward` the distance the mat's own rows
/// are measured in (`StageCamera.standard.platformNear` is the row just
/// past the screen's bottom edge, `.platformFar` the mat's far edge). The
/// fraction initialiser below maps onto that span so callers can think in
/// "how far across, how deep" without touching the projection.
struct Card3DPlacement: Identifiable, Equatable {

    /// Stable identity for diffing — the board's slot or instance id, not
    /// the card id, so two copies of one card are two placements.
    let id: String

    /// The card whose printing the slab wears.
    let card: Card

    /// Lateral position, world units, positive right.
    var x: CGFloat

    /// Forward distance along the mat, world units (stage convention).
    var forward: CGFloat

    /// Rotation about the mat's normal. Zero faces the card's top edge
    /// away from the viewer, as a card laid on a table is read; a quarter
    /// turn is the classic sideways rest position.
    var yaw: Angle = .zero

    /// How far the card's far edge is raised out of the mat, about the
    /// stage's lateral axis. Zero is a card lying flat on the ground plane.
    ///
    /// It is applied OUTSIDE the yaw, so a rested card still leans back
    /// toward the reader rather than tipping onto one of its long edges —
    /// the lean belongs to the mat's geometry, the yaw to the card's own
    /// posture, and mixing them would make the two states disagree.
    ///
    /// The reason a caller ever wants one: a card lying dead flat
    /// foreshortens by the sine of the ray's depression, which at the top of
    /// a steeply raked mat is close to nothing. Raking a slab up toward the
    /// reader trades a little literalism for a card that can still be read
    /// and aimed at — see `BoardCard3DProjection`, which derives the angle
    /// from this same camera.
    var lean: Angle = .zero

    /// Face-down cards show the shared back; the printing never renders.
    var isFaceDown: Bool = false

    /// Card width, world units.
    var width: CGFloat = Card3DSceneMetrics.cardWidth

    init(
        id: String,
        card: Card,
        x: CGFloat,
        forward: CGFloat,
        yaw: Angle = .zero,
        lean: Angle = .zero,
        isFaceDown: Bool = false,
        width: CGFloat = Card3DSceneMetrics.cardWidth
    ) {
        self.id = id
        self.card = card
        self.x = x
        self.forward = forward
        self.yaw = yaw
        self.lean = lean
        self.isFaceDown = isFaceDown
        self.width = width
    }

    /// Places by fractions of the mat: `across` -1...1 maps left edge to
    /// right edge of the playable field, `depth` 0...1 maps the mat's near
    /// row to its far edge. The mid-depths are the playable rows; 0 starts
    /// just below the screen's bottom edge by the stage's own overshoot.
    init(
        id: String,
        card: Card,
        across: CGFloat,
        depth: CGFloat,
        yaw: Angle = .zero,
        lean: Angle = .zero,
        isFaceDown: Bool = false,
        width: CGFloat = Card3DSceneMetrics.cardWidth
    ) {
        let camera = StageCamera.standard
        self.init(
            id: id,
            card: card,
            x: across * Card3DSceneMetrics.fieldHalfWidth,
            forward: camera.platformNear
                + (camera.platformFar - camera.platformNear) * depth,
            yaw: yaw,
            lean: lean,
            isFaceDown: isFaceDown,
            width: width
        )
    }
}

// MARK: - Budget

/// What the 3D cards may spend right now, given everything that can ask
/// them to stop. One verdict rather than four scattered checks, exactly as
/// `StagePulse` collapses the same voices for the stage — and the same
/// voices answer here: the player (Reduce Motion; the master switch is
/// checked before this), the battery (Low Power Mode), the chassis
/// (thermal), and the board (`isPaused` — an effect playing, or the scene
/// not active).
struct Card3DBudget: Equatable {

    /// False drops 3D cards wholesale — the view renders nothing and the
    /// board's 2D cards stand alone.
    var rendersCards: Bool

    /// Whether the render loop runs (the specular sweep). False is a held
    /// single frame — zero GPU between changes.
    var isAnimated: Bool

    /// Whether materials drop to the unlit tier. See `Card3DSurface`.
    var simplifiedMaterials: Bool

    /// The current verdict.
    @MainActor
    static func current(reduceMotion: Bool, isPaused: Bool) -> Card3DBudget {
        var budget = Card3DBudget(
            rendersCards: true, isAnimated: true, simplifiedMaterials: false
        )
        switch StageThermalMonitor.shared.state {
        case .nominal:
            break
        case .fair:
            budget.isAnimated = false
            budget.simplifiedMaterials = true
        default:
            // `.serious` and hotter (and any future case): no 3D at all.
            budget.rendersCards = false
            return budget
        }
        if EffectPowerMonitor.shared.isLowPower {
            budget.isAnimated = false
            budget.simplifiedMaterials = true
        }
        if reduceMotion || isPaused {
            budget.isAnimated = false
        }
        return budget
    }
}

// MARK: - Card 3D view

/// The board-facing layer: hand it the placements, tell it when the board
/// is busy, and it renders them as slabs in the stage's space — or renders
/// nothing at all when the device, the player or the switch says so.
struct Card3DView: View {

    /// The cards to lay on the mat. Order is the tie-break at the cap:
    /// the first `Card3DSceneMetrics.maxNodes` render.
    let cards: [Card3DPlacement]

    /// True while a full-screen effect is playing over the board — the
    /// slabs hold still for it, the same contract as `FieldStage`.
    var isPaused: Bool = false

    @AppStorage(Card3DDefaults.enabledKey) private var isEnabled = true
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase
    @Environment(CardDatabase.self) private var database

    var body: some View {
        if isEnabled {
            let budget = Card3DBudget.current(
                reduceMotion: reduceMotion,
                isPaused: isPaused || scenePhase != .active
            )
            if budget.rendersCards {
                Card3DSceneView(
                    placements: Array(cards.prefix(Card3DSceneMetrics.maxNodes)),
                    database: database,
                    isAnimated: budget.isAnimated,
                    simplified: budget.simplifiedMaterials
                )
                .allowsHitTesting(false)
                .accessibilityHidden(true)
            }
        }
    }
}

// MARK: - Scene view

/// The `UIViewRepresentable` around the one `SCNView`. The coordinator
/// owns the scene graph and diffs placements into nodes by id; SwiftUI
/// re-renders only hand it value changes.
private struct Card3DSceneView: UIViewRepresentable {

    let placements: [Card3DPlacement]
    let database: CardDatabase
    let isAnimated: Bool
    let simplified: Bool

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeUIView(context: Context) -> SCNView {
        let view = SCNView()
        view.scene = context.coordinator.scene
        view.pointOfView = context.coordinator.cameraNode
        view.backgroundColor = .clear
        view.isOpaque = false
        view.allowsCameraControl = false
        view.autoenablesDefaultLighting = false
        view.rendersContinuously = false
        view.preferredFramesPerSecond = Card3DSceneMetrics.liveFrameRate
        view.isUserInteractionEnabled = false
        sync(view, coordinator: context.coordinator)
        return view
    }

    func updateUIView(_ view: SCNView, context: Context) {
        sync(view, coordinator: context.coordinator)
    }

    /// Brings the scene graph up to date with the current values. Shared
    /// by make and update so there is exactly one truth about what the
    /// scene looks like.
    private func sync(_ view: SCNView, coordinator: Coordinator) {
        coordinator.sync(
            placements: placements,
            database: database,
            simplified: simplified
        )

        // Play only while animated: `isPlaying` is the render loop, and a
        // still scene renders one frame per change instead.
        Card3DLighting.setSweeping(coordinator.lightRig, active: isAnimated)
        view.isPlaying = isAnimated
        coordinator.scene.isPaused = !isAnimated

        // Multisampling is worth four samples on a live edge-on slab;
        // the simplified tier gives it back.
        view.antialiasingMode = simplified ? .none : .multisampling4X
    }

    // MARK: Coordinator

    @MainActor
    final class Coordinator {

        let scene = SCNScene()
        let cameraNode: SCNNode
        let lightRig = Card3DLighting.rig()

        /// Live nodes by placement id.
        private var nodes: [String: Card3DNode] = [:]

        /// The material tier the current nodes were built at, so a tier
        /// change re-skins them exactly once.
        private var builtSimplified = false

        init() {
            // THE SHARED CAMERA. Every number here is a
            // `FieldStageMetrics` token — the stage's pinhole, re-expressed
            // as an `SCNCamera`. Position: on the centre line at the
            // stage's height. Pitch: the stage's, negative about x because
            // SceneKit looks down -Z. FOV: the stage's vertical field,
            // declared vertical explicitly so aspect changes never
            // reinterpret it.
            let camera = SCNCamera()
            camera.fieldOfView = FieldStageMetrics.verticalFOVDegrees
            camera.projectionDirection = .vertical
            camera.zNear = Card3DSceneMetrics.cameraNearClip
            camera.zFar = Card3DSceneMetrics.cameraFarClip
            cameraNode = SCNNode()
            cameraNode.camera = camera
            cameraNode.position = SCNVector3(
                0, Float(FieldStageMetrics.cameraHeight), 0
            )
            cameraNode.eulerAngles.x = -Float(
                FieldStageMetrics.pitchDegrees * .pi / 180
            )

            scene.rootNode.addChildNode(cameraNode)
            scene.rootNode.addChildNode(lightRig)
            scene.background.contents = UIColor.clear
        }

        /// Diffs placements into the node table: remove the departed, move
        /// the moved, build the new. Materials are baked per node, so a
        /// placement whose CARD changed under the same id is a
        /// remove-and-rebuild, not a repaint.
        func sync(
            placements: [Card3DPlacement],
            database: CardDatabase,
            simplified: Bool
        ) {
            if simplified != builtSimplified {
                builtSimplified = simplified
                for node in nodes.values {
                    node.setSimplified(simplified)
                }
            }

            var seen = Set<String>()
            seen.reserveCapacity(placements.count)
            for placement in placements {
                seen.insert(placement.id)
                if let node = nodes[placement.id], node.cardID == placement.card.id {
                    node.apply(placement)
                    continue
                }
                nodes[placement.id]?.removeFromParentNode()
                let node = Card3DNode(
                    placement: placement,
                    faceArtwork: placement.isFaceDown
                        // A face-down slab never shows its printing, and a
                        // back that hides the picture has no business
                        // decoding it — the same rule `CardFaceView`
                        // applies to hidden 2D cards.
                        ? nil
                        : database.artwork(
                            for: placement.card,
                            maxPixelSize: Card3DSceneMetrics.artPixelSize
                        ),
                    backTexture: Card3DBackTexture.image(),
                    simplified: simplified
                )
                nodes[placement.id] = node
                scene.rootNode.addChildNode(node)
            }

            for (id, node) in nodes where !seen.contains(id) {
                node.removeFromParentNode()
                nodes[id] = nil
            }
        }
    }
}

// MARK: - Previews

/// Real collector numbers, so the previews render the bundled artwork the
/// shipping app renders.
private func card3DPreviewPool() -> [Card] {
    [
        Card(id: "N-001", name: "Naruto Uzumaki", type: .leader, color: .red,
             rarity: .leader, setCode: "01", power: 3, damage: 1, life: 15),
        Card(id: "K-039", name: "Kakashi Hatake", type: .character, color: .red,
             rarity: .common, setCode: "01", cost: 1, power: 7, damage: 1, health: 4),
        Card(id: "N-014", name: "Sasuke Uchiha", type: .exCharacter, color: .blue,
             rarity: .rare, setCode: "01", cost: 3, power: 5, damage: 1, health: 5),
        Card(id: "N-005", name: "Gamabunta", type: .exCharacter, color: .red,
             rarity: .superRare, setCode: "01", cost: 3, power: 6, damage: 1, health: 5),
    ]
}

/// A near row, a far row, a face-down support and a sideways card — the
/// postures the board actually deals — over the live stage, to check the
/// one property that matters: slab, mat and backdrop share a camera.
private func card3DPreviewPlacements() -> [Card3DPlacement] {
    let pool = card3DPreviewPool()
    return [
        Card3DPlacement(id: "leader", card: pool[0], across: 0, depth: 0.82),
        Card3DPlacement(id: "near-1", card: pool[1], across: -0.45, depth: 0.3),
        Card3DPlacement(id: "near-2", card: pool[2], across: 0, depth: 0.3,
                        yaw: .degrees(90)),
        Card3DPlacement(id: "far-1", card: pool[3], across: 0.45, depth: 0.62),
        Card3DPlacement(id: "support", card: pool[1], across: 0.45, depth: 0.3,
                        isFaceDown: true),
    ]
}

#Preview("Cards on the stage") {
    ZStack {
        AmbientBackground()
        FieldStage()
        Card3DView(cards: card3DPreviewPlacements())
    }
    .ignoresSafeArea()
    .environment(CardDatabase(cards: card3DPreviewPool()))
}

#Preview("Held still (effect playing)") {
    ZStack {
        AmbientBackground()
        FieldStage(isEffectPlaying: true)
        Card3DView(cards: card3DPreviewPlacements(), isPaused: true)
    }
    .ignoresSafeArea()
    .environment(CardDatabase(cards: card3DPreviewPool()))
}
