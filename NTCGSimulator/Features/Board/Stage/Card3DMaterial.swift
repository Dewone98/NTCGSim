//
//  Card3DMaterial.swift
//  NTCGSimulator
//
//  The surface and lighting work for 3D cards, kept apart from the
//  geometry so the look can be tuned without touching a vertex.
//
//  What the research says a premium card LOOKS like, independent of shape.
//  Master Duel's card finishes are the cleanest statement of it: "Glossy"
//  is a plain silvery specular sheen over the printing, "Royal" adds a
//  prismatic sweep — both are material response on a flat card, nothing
//  geometric. YGO Omega's 3D field view shows the complement: an ordinary
//  matte card reads as *stock* precisely because its face catches a soft
//  moving highlight while the printing stays dominant. So the recipe here
//  is: albedo first (the printing must always win), a low-gloss specular
//  lobe that travels as card or light tilts, and rarity expressed as a
//  step change in that gloss — the Glossy/Royal ladder rebuilt out of two
//  numbers.
//
//  Concretely, physically based materials throughout (the lighting model
//  SceneKit's punctual lights feed correctly), with:
//
//  * ROUGHNESS in the matte-varnish range. Card faces are printed paper
//    under a thin coat: roughness ~0.4 gives a broad, soft gleam. Plastic
//    film — the failure mode — is a tight mirror streak, which is what
//    roughness under ~0.15 produces; the ladder floors at 0.2.
//  * METALNESS near zero for common stock (paper is a dielectric) and
//    raised modestly for foil rarities: metal tint is what makes a foil's
//    highlight take the colour of the print under it, which is exactly how
//    foil layers behave. It stays under ~0.35 because SceneKit metals draw
//    their reflections from the scene environment, and this scene
//    deliberately has none (see below) — high metalness without an
//    environment map goes black, not shiny.
//  * NO environment map, NO shadows. An image-based-lighting cube adds a
//    texture fetch to every lit fragment, and a shadow map is a second
//    render pass of every slab per frame — both for effects invisible at
//    board card sizes (the 2D board already paints contact shadows under
//    its cards). The entire lighting bill is ONE directional key and ONE
//    ambient: the key makes the sweep, the ambient guarantees the printing
//    never falls into shadow — the readability trick, since a face lit
//    mostly by uniform ambient keeps its albedo whatever the slab is doing.
//  * THE SPECULAR SWEEP. The key light's rig yaws a few degrees back and
//    forth on a slow ease, so the highlight travels across the lying cards
//    the way a held card catches the room light — and because the light
//    moves rather than the cards, the printing never shifts a pixel. A
//    card the board tilts (a flip, a raise) sweeps the same highlight by
//    plain physics against the still key. Animating one light transform
//    costs the CPU one node update per frame and the GPU nothing extra.
//

import SceneKit
import SwiftUI
import UIKit

// MARK: - Card 3D palette

/// Colour tokens for the card slab and its lights. Local to the 3D cards
/// for the usual reason: nothing else draws with them. `UIColor` rather
/// than `Color` because SceneKit consumes them directly — and deliberately
/// non-adaptive: a physical card is the same object in either appearance,
/// and the scene's lights, not the UI theme, decide how it reads.
enum Card3DPalette {

    /// The cut edge of the stock — the pale paper core a real card shows
    /// on its side. A step warmer than white so it reads as paper, not as
    /// a glowing outline.
    static let stockEdge = UIColor(hex: 0xE7E0D2)

    /// Key light colour: warm white, matching the stage's implied low sun
    /// (`FieldStagePalette.skyGlow` warms the same corner of the scene).
    static let keyLight = UIColor(hex: 0xFFF1DE)

    /// Ambient colour: cool and faintly violet, the stage's sky bounced
    /// back down. Complementary to the key so the sheen registers as a
    /// *change* of light, not just more brightness.
    static let ambientLight = UIColor(hex: 0xC9CBE0)

    /// Face colour when a card has no artwork. Matches the panel tone the
    /// 2D missing-art face uses, and is effectively unreachable in the
    /// shipping app — `BundledCardArtTests` fails the build if any pool
    /// card lacks its illustration.
    static let missingFace = UIColor(hex: 0x2C2333)

    /// The ground the card-back render is composited over, so the baked
    /// texture is fully opaque out to the slab's rounded corners.
    static let backUnderlay = UIColor(hex: 0x1B1322)
}

// MARK: - Material metrics

/// Every number the surface work is built from, with the reasoning.
enum Card3DMaterialMetrics {

    // MARK: Face finish ladder

    /// Roughness and metalness per rarity — the Glossy/Royal ladder as two
    /// numbers. Commons and Leaders are matte print stock; Rare gains a
    /// noticeable gloss; Super Rare and Secret Box step into foil, where
    /// the highlight tightens and takes the print's colour (metalness).
    /// The floor of 0.2 roughness and ceiling of 0.32 metalness are the
    /// plastic-film and black-metal failure modes, kept out of reach.
    static func faceFinish(for rarity: Rarity) -> (roughness: CGFloat, metalness: CGFloat) {
        switch rarity {
        case .common, .leader: return (0.42, 0.02)
        case .rare:            return (0.34, 0.06)
        case .superRare:       return (0.26, 0.22)
        case .secretBox:       return (0.20, 0.32)
        }
    }

    /// The back's finish: every card wears the same back, so it gets the
    /// common-stock varnish regardless of what the face is worth.
    static let backRoughness: CGFloat = 0.4
    static let backMetalness: CGFloat = 0.04

    /// The cut edge: raw paper core, no varnish at all — the one matte
    /// surface on the object, which is itself a cue that the face is
    /// coated.
    static let edgeRoughness: CGFloat = 0.85
    static let edgeMetalness: CGFloat = 0

    // MARK: Lights

    /// Key and ambient intensities (SceneKit photometric lumens; 1000 is
    /// the framework's neutral). Ambient runs close behind the key on
    /// purpose: the ambient term is what keeps the printing readable at
    /// every slab angle, and the key only has to win by enough to make a
    /// visible sheen.
    static let keyIntensity: CGFloat = 850
    static let ambientIntensity: CGFloat = 700

    /// Key elevation above the mat, degrees. Chosen against the stage
    /// camera's 38-degree pitch: the mirror bounce of that view off a flat
    /// card rises at 38 degrees, so a key in the mid-50s sits close enough
    /// to the mirror lobe that lying cards show a broad gleam, without
    /// blowing a hotspot at the exact centre.
    static let keyElevationDegrees: Double = 55

    /// Key azimuth at rest, degrees off dead-ahead. Off-centre so the
    /// sheen enters faces asymmetrically — a centred highlight reads as a
    /// rendering artefact, an offset one as a room.
    static let keyAzimuthDegrees: Double = -18

    // MARK: Sweep

    /// Total yaw travel of the sweep, degrees, and seconds per full
    /// there-and-back. A few degrees over ~11 s moves the highlight
    /// perceptibly without ever being the thing watched — presence, not
    /// animation — and the period is deliberately co-prime-ish with the
    /// stage's 26 s sway and the holograms' 4.7 s bob so nothing locks.
    static let sweepArcDegrees: Double = 16
    static let sweepPeriod: Double = 11

    // MARK: Card back texture

    /// Width, points, the shared card back is rendered at (5:7 tall, at 2x
    /// scale — 512 px across). Board cards draw under ~100 pt, so this
    /// covers 3x phones with margin for one texture the whole scene
    /// shares.
    static let backTextureWidth: CGFloat = 256
}

// MARK: - Surfaces

/// Builds the three materials a card slab wears. Two tiers:
///
/// * FULL — physically based, per the header: the moving sheen, the foil
///   ladder, the matte edge.
/// * SIMPLIFIED — `constant` (unlit) shading, diffuse only: the same
///   textures with the entire lighting bill removed. This is the Low
///   Power / warm-thermal presentation, and it is deliberately still a
///   correct card — print, back and stock edge all read; only the light
///   response is gone.
enum Card3DSurface {

    /// The printed face.
    static func face(artwork: UIImage?, rarity: Rarity, simplified: Bool) -> SCNMaterial {
        let material = base(simplified: simplified)
        material.diffuse.contents = artwork ?? Card3DPalette.missingFace
        material.diffuse.wrapS = .clamp
        material.diffuse.wrapT = .clamp
        // Trilinear minification: board cards render well under the
        // texture's native size and at a raked angle, which is exactly
        // where un-mipped sampling shimmers.
        material.diffuse.mipFilter = .linear
        if !simplified {
            let finish = Card3DMaterialMetrics.faceFinish(for: rarity)
            material.roughness.contents = finish.roughness
            material.metalness.contents = finish.metalness
        }
        return material
    }

    /// The card back.
    static func back(texture: UIImage?, simplified: Bool) -> SCNMaterial {
        let material = base(simplified: simplified)
        material.diffuse.contents = texture ?? Card3DPalette.backUnderlay
        material.diffuse.wrapS = .clamp
        material.diffuse.wrapT = .clamp
        material.diffuse.mipFilter = .linear
        if !simplified {
            material.roughness.contents = Card3DMaterialMetrics.backRoughness
            material.metalness.contents = Card3DMaterialMetrics.backMetalness
        }
        return material
    }

    /// The cut edge — flat stock colour, no texture to fetch.
    static func edge(simplified: Bool) -> SCNMaterial {
        let material = base(simplified: simplified)
        material.diffuse.contents = Card3DPalette.stockEdge
        if !simplified {
            material.roughness.contents = Card3DMaterialMetrics.edgeRoughness
            material.metalness.contents = Card3DMaterialMetrics.edgeMetalness
        }
        return material
    }

    /// The shared skeleton: single-sided (the mesh closes the slab, so
    /// interior faces never show and culling them is free), opaque, and on
    /// the tier's lighting model.
    private static func base(simplified: Bool) -> SCNMaterial {
        let material = SCNMaterial()
        material.lightingModel = simplified ? .constant : .physicallyBased
        material.isDoubleSided = false
        return material
    }
}

// MARK: - Card back texture

/// The one card-back bitmap every slab shares, rendered from the same
/// `CardBackView` the 2D board shows — one visual identity for a hidden
/// card, whichever renderer draws it.
///
/// Rendered once and cached forever: the back never varies per card, so a
/// full board of face-down slabs costs one 512 px texture. Composited over
/// an opaque underlay because the 2D back's notched corners carry
/// transparency, and an alpha-fringed texture on an opaque slab would
/// punch see-through nicks in the geometry's own rounded corners.
@MainActor
enum Card3DBackTexture {

    private static var cached: UIImage?

    /// The shared back, or nil in the unlikely event rendering fails —
    /// materials then fall back to the underlay colour, a plain dark back.
    static func image() -> UIImage? {
        if let cached { return cached }
        let width = Card3DMaterialMetrics.backTextureWidth
        let renderer = ImageRenderer(
            content: ZStack {
                Color(Card3DPalette.backUnderlay)
                CardBackView(tint: Palette.accentMuted)
            }
            .frame(width: width, height: width / Metrics.cardAspect)
        )
        renderer.scale = 2
        renderer.isOpaque = true
        cached = renderer.uiImage
        return cached
    }
}

// MARK: - Lighting

/// The scene's whole lighting bill: one warm directional key on a slowly
/// sweeping rig, one cool ambient. No shadows, no environment — the
/// reasoning is in the file header, the receipts are in the metrics.
enum Card3DLighting {

    /// Action key for the sweep, so it can be found and removed.
    private static let sweepActionKey = "card3d.sweep"

    /// The rig: an outer node that yaws (rest azimuth, and the sweep when
    /// it runs) carrying the pitched key light and the ambient.
    static func rig() -> SCNNode {
        let rig = SCNNode()
        rig.eulerAngles.y = Float(
            Card3DMaterialMetrics.keyAzimuthDegrees * .pi / 180
        )

        let key = SCNNode()
        key.light = SCNLight()
        key.light?.type = .directional
        key.light?.color = Card3DPalette.keyLight
        key.light?.intensity = Card3DMaterialMetrics.keyIntensity
        key.light?.castsShadow = false
        // A directional light points down its node's -Z. Pitching by
        // -(180 - elevation) aims the beam from high in front of the
        // camera down toward it — the same corner of the sky the stage's
        // warm glow implies.
        key.eulerAngles.x = -Float(
            (180 - Card3DMaterialMetrics.keyElevationDegrees) * .pi / 180
        )
        rig.addChildNode(key)

        let ambient = SCNNode()
        ambient.light = SCNLight()
        ambient.light?.type = .ambient
        ambient.light?.color = Card3DPalette.ambientLight
        ambient.light?.intensity = Card3DMaterialMetrics.ambientIntensity
        rig.addChildNode(ambient)

        return rig
    }

    /// Starts or stops the specular sweep on a rig built above.
    ///
    /// Stopping also re-centres the rig at its rest azimuth, so a still
    /// frame is always the same still frame — the same rule the stage's
    /// sway follows when it pauses.
    static func setSweeping(_ rig: SCNNode, active: Bool) {
        if active {
            guard rig.action(forKey: sweepActionKey) == nil else { return }
            let halfArc = CGFloat(
                Card3DMaterialMetrics.sweepArcDegrees * .pi / 180 / 2
            )
            let halfPeriod = Card3DMaterialMetrics.sweepPeriod / 2
            let sweepOut = SCNAction.rotateBy(
                x: 0, y: halfArc * 2, z: 0, duration: halfPeriod
            )
            sweepOut.timingMode = .easeInEaseOut
            let sweepBack = SCNAction.rotateBy(
                x: 0, y: -halfArc * 2, z: 0, duration: halfPeriod
            )
            sweepBack.timingMode = .easeInEaseOut
            // Ease into the first half-swing from centre so the sweep
            // starts from the rest pose without a jump.
            let lead = SCNAction.rotateBy(
                x: 0, y: -halfArc, z: 0, duration: halfPeriod / 2
            )
            lead.timingMode = .easeInEaseOut
            rig.runAction(
                SCNAction.sequence([
                    lead,
                    SCNAction.repeatForever(
                        SCNAction.sequence([sweepOut, sweepBack])
                    ),
                ]),
                forKey: sweepActionKey
            )
        } else {
            rig.removeAction(forKey: sweepActionKey)
            rig.eulerAngles.y = Float(
                Card3DMaterialMetrics.keyAzimuthDegrees * .pi / 180
            )
        }
    }
}

// MARK: - Previews

/// The finish ladder, three slabs side by side under the standard rig:
/// common matte on the left, rare gloss centre, secret-box foil right.
/// Tilted toward the key so the specular difference is the subject.
@MainActor
private func finishLadderScene() -> SCNScene {
    let scene = SCNScene()
    scene.background.contents = UIColor(hex: 0x140F17)

    let cards: [Card] = [
        Card(id: "K-039", name: "Kakashi Hatake", type: .character, color: .red,
             rarity: .common, setCode: "01", cost: 1, power: 7, damage: 1, health: 4),
        Card(id: "N-014", name: "Sasuke Uchiha", type: .exCharacter, color: .blue,
             rarity: .rare, setCode: "01", cost: 3, power: 5, damage: 1, health: 5),
        Card(id: "N-005", name: "Gamabunta", type: .exCharacter, color: .red,
             rarity: .secretBox, setCode: "01", cost: 3, power: 6, damage: 1, health: 5),
    ]
    let database = CardDatabase(cards: cards)

    for (index, card) in cards.enumerated() {
        let placement = Card3DPlacement(
            id: card.id, card: card,
            x: CGFloat(index - 1) * 1.2, forward: 0
        )
        let node = Card3DNode(
            placement: placement,
            faceArtwork: database.artwork(for: card, maxPixelSize: 512),
            backTexture: Card3DBackTexture.image(),
            simplified: false
        )
        node.position = SCNVector3(Float(index - 1) * 1.2, 0, 0)
        node.eulerAngles = SCNVector3(Float.pi / 2 - 0.4, 0, 0)
        scene.rootNode.addChildNode(node)
    }

    let rig = Card3DLighting.rig()
    Card3DLighting.setSweeping(rig, active: true)
    scene.rootNode.addChildNode(rig)

    let cameraNode = SCNNode()
    cameraNode.camera = SCNCamera()
    cameraNode.camera?.fieldOfView = FieldStageMetrics.verticalFOVDegrees
    cameraNode.position = SCNVector3(0, 0.5, 3.4)
    cameraNode.eulerAngles.x = -0.15
    scene.rootNode.addChildNode(cameraNode)
    return scene
}

#Preview("Finish ladder, sweeping key") {
    // `rendersContinuously` here only: the preview exists to watch the
    // sweep travel; the app's own view plays through `SCNView.isPlaying`
    // under `Card3DBudget`'s control instead.
    SceneView(scene: finishLadderScene(), options: [.rendersContinuously])
        .ignoresSafeArea()
}
