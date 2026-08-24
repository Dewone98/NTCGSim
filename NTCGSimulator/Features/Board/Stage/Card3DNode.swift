//
//  Card3DNode.swift
//  NTCGSimulator
//
//  A card as real geometry: an extruded rounded-rectangle slab with the
//  card's printing on its face, the card back on its reverse, and bare
//  stock along its edges — the object YGO Omega puts in its 3D field view.
//
//  What the named references actually render, from researching both:
//
//  * YGO Omega's 3D field view (one of its three camera views since the
//    0.85 release added the zoomed-out 3D angle) makes the CARD the object
//    in the scene — printed stock lying on the mat under a perspective
//    camera, no character meshes anywhere. The monster *is* the card's own
//    printing; everything three-dimensional about it is the thin slab of
//    the card itself catching the scene's light as it moves.
//  * Master Duel, by contrast, keeps duel cards screen-space 2D over its
//    diorama — but its premium card treatments prove the other half of the
//    lesson: "Glossy" finish is a plain silvery specular sheen and "Royal"
//    is a prismatic sweep, and both are SURFACE treatments on the same flat
//    card. What reads as a premium physical card is material response, not
//    extra geometry. `Card3DMaterial` carries that half; this file carries
//    the slab.
//  * Real card stock (per card-manufacture references): 63.5 x 88.9 mm,
//    0.30-0.35 mm thick, corners die-cut at roughly 3.5 mm. Thickness is
//    ~0.4% of height — a proportion, not a look, and getting it right is
//    what sells the object: visibly thicker reads as acrylic, thinner
//    vanishes into a decal. The tokens below keep those ratios exactly.
//
//  THE MESH, and why it is generated rather than extruded. The two obvious
//  SceneKit routes both fail a card:
//
//  * `SCNShape` (rounded `UIBezierPath`, extruded, chamfered) produces the
//    right silhouette but the wrong UVs: its face texture coordinates live
//    in the path's own coordinate space rather than 0...1, and the extruded
//    side wall shares the face material's mapping — which is exactly the
//    classic failure the face must avoid, artwork smeared into stripes
//    along the card's edge.
//  * `SCNBox` gives clean per-face materials but its `chamferRadius` is
//    capped by the box's smallest dimension — the 0.006-unit thickness —
//    so the face outline can never round. A card with square corners reads
//    as a photograph of a card.
//
//  So the slab is built by hand as one `SCNGeometry` with THREE elements
//  over a shared vertex pool, giving each region its own material and its
//  own deliberate UVs:
//
//    1. FACE  — a triangle fan over the rounded-rect outline (the outline
//               is convex, so a fan from the centre is exact), normals
//               +Z, UVs mapping the card rect square onto 0...1. Artwork
//               lands print-true and cannot reach the sides, because the
//               sides are a different element with a different material.
//    2. BACK  — the same fan mirrored (wound for -Z), with U flipped so
//               the card back reads unmirrored when actually viewed from
//               behind — the detail extrusion tools always get wrong.
//    3. RIM   — a quad strip around the perimeter, normals radiating
//               outward (exact arc normals at the corners, so the edge
//               shades smoothly), UVs running arc-length x thickness. It
//               carries the pale stock material: the paper core a real
//               card shows on its cut edge.
//
//  The whole slab is ~116 vertices and three draw calls, built once and
//  shared: every node copies the master geometry (`copy()` shares the
//  vertex buffers) and swaps in its own three materials.
//

import SceneKit
import SwiftUI
import UIKit

// MARK: - Geometry metrics

/// The card slab's proportions. Everything is a ratio off the real printed
/// object, expressed against a local width of 1 so a node scales to any
/// world size with a single uniform scale.
enum Card3DMetrics {

    /// Local model width. The unit everything else is measured against;
    /// nodes scale this to their world width.
    static let localWidth: CGFloat = 1

    /// Local model height, from the design system's one card ratio — the
    /// same 5:7 every 2D face in the app is drawn at.
    static let localHeight: CGFloat = localWidth / Metrics.cardAspect

    /// Thickness as a fraction of height: 0.35 mm of stock against an
    /// 88.9 mm card. This proportion is the whole reason the slab reads as
    /// a card — thicker is acrylic, thinner is a decal.
    static let thicknessRatio: CGFloat = 0.35 / 88.9

    /// Local model thickness.
    static let localThickness: CGFloat = localHeight * thicknessRatio

    /// Corner radius as a fraction of width: the ~3.5 mm die-cut round on
    /// a 63.5 mm card.
    static let cornerRadiusRatio: CGFloat = 3.5 / 63.5

    /// Local model corner radius.
    static let localCornerRadius: CGFloat = localWidth * cornerRadiusRatio

    /// Segments per quarter-circle corner. Six puts perimeter points about
    /// every 15 degrees of arc — at board card sizes (under ~100 pt) the
    /// corner is visually a true curve, and the whole slab still counts
    /// its vertices in the low hundreds.
    static let cornerSegments = 6
}

// MARK: - Mesh

/// Builds the one card slab every node shares.
enum Card3DMesh {

    /// The master geometry, built once. Nodes never render this directly —
    /// they take `instance()` so each can carry its own materials.
    private static let master: SCNGeometry = build()

    /// A copy sharing the master's vertex buffers but owning its own
    /// materials array — SceneKit's supported idiom for "same mesh, many
    /// appearances", and why a full board of cards uploads one vertex pool.
    static func instance() -> SCNGeometry {
        // The force-cast is the documented contract of `NSCopying` here:
        // `SCNGeometry.copy()` returns `SCNGeometry`.
        let copy = master.copy() as! SCNGeometry
        copy.materials = [SCNMaterial(), SCNMaterial(), SCNMaterial()]
        return copy
    }

    /// Index of each element in the geometry — the order materials must be
    /// assigned in.
    enum Element: Int {
        case face = 0
        case back = 1
        case rim = 2
    }

    // MARK: Outline

    /// One point of the rounded-rect outline with its exact outward normal
    /// — arc points know their angle, so corner shading is round rather
    /// than faceted.
    private struct OutlinePoint {
        let point: CGPoint
        let normal: CGPoint
    }

    /// The rounded-rectangle outline, counterclockwise viewed from +Z
    /// (the face side), starting at the bottom of the bottom-right corner.
    /// Four sampled quarter-arcs; the straight edges are the implicit
    /// segments between consecutive arc endpoints.
    private static func outline() -> [OutlinePoint] {
        let hw = Card3DMetrics.localWidth / 2
        let hh = Card3DMetrics.localHeight / 2
        let r = Card3DMetrics.localCornerRadius
        let segments = Card3DMetrics.cornerSegments

        // Corner centres paired with the start angle of their quarter-arc,
        // in counterclockwise order.
        let corners: [(centre: CGPoint, startAngle: CGFloat)] = [
            (CGPoint(x: hw - r, y: -hh + r), -.pi / 2), // bottom-right
            (CGPoint(x: hw - r, y: hh - r), 0),         // top-right
            (CGPoint(x: -hw + r, y: hh - r), .pi / 2),  // top-left
            (CGPoint(x: -hw + r, y: -hh + r), .pi),     // bottom-left
        ]

        var points: [OutlinePoint] = []
        points.reserveCapacity(corners.count * (segments + 1))
        for corner in corners {
            for step in 0...segments {
                let angle = corner.startAngle
                    + .pi / 2 * CGFloat(step) / CGFloat(segments)
                let normal = CGPoint(x: cos(angle), y: sin(angle))
                points.append(OutlinePoint(
                    point: CGPoint(
                        x: corner.centre.x + r * normal.x,
                        y: corner.centre.y + r * normal.y
                    ),
                    normal: normal
                ))
            }
        }
        return points
    }

    // MARK: Assembly

    /// Builds the slab: shared vertex/normal/UV pools, three index
    /// elements. Layout, in pool order:
    ///
    ///     [0]                 face centre
    ///     [1 ... P]           face perimeter
    ///     [P+1]               back centre
    ///     [P+2 ... 2P+1]      back perimeter
    ///     [2P+2 ... 2P+3+2P]  rim columns (front, back) x (P+1) —
    ///                         the extra column duplicates the first so
    ///                         the arc-length U can close at exactly 1.
    private static func build() -> SCNGeometry {
        let rimLine = outline()
        let count = rimLine.count
        let h = Card3DMetrics.localHeight
        let halfT = Float(Card3DMetrics.localThickness / 2)

        var vertices: [SCNVector3] = []
        var normals: [SCNVector3] = []
        var uvs: [CGPoint] = []

        // FACE: fan centre plus perimeter, normal +Z. U maps the card's
        // width onto 0...1; V runs top-of-card = 0 downward, matching how
        // SceneKit lays an image onto its parametric primitives, so the
        // printing stands upright. Verified empirically with an offscreen
        // SceneKit render of this exact mesh (orientation quadrants on
        // face and back, magenta on the rim): print-true face, unmirrored
        // back, and not one textured pixel on the edge element.
        vertices.append(SCNVector3(0, 0, halfT))
        normals.append(SCNVector3(0, 0, 1))
        uvs.append(CGPoint(x: 0.5, y: 0.5))
        for sample in rimLine {
            vertices.append(SCNVector3(
                Float(sample.point.x), Float(sample.point.y), halfT
            ))
            normals.append(SCNVector3(0, 0, 1))
            uvs.append(CGPoint(
                x: sample.point.x + 0.5,
                y: 0.5 - sample.point.y / h
            ))
        }

        // BACK: the same fan at -Z with U mirrored, so a viewer actually
        // behind the card reads the back unflipped.
        let backCentre = vertices.count
        vertices.append(SCNVector3(0, 0, -halfT))
        normals.append(SCNVector3(0, 0, -1))
        uvs.append(CGPoint(x: 0.5, y: 0.5))
        for sample in rimLine {
            vertices.append(SCNVector3(
                Float(sample.point.x), Float(sample.point.y), -halfT
            ))
            normals.append(SCNVector3(0, 0, -1))
            uvs.append(CGPoint(
                x: 0.5 - sample.point.x,
                y: 0.5 - sample.point.y / h
            ))
        }

        // RIM: two rows (front z, back z) per outline point, plus one
        // duplicated seam column. U is normalised arc length; V crosses
        // the thickness. The material here is flat stock colour, but sane
        // UVs mean a texture *could* band the edge (a foil edge, say)
        // without touching the mesh.
        let rimBase = vertices.count
        var arcLengths: [CGFloat] = [0]
        var total: CGFloat = 0
        for index in 0..<count {
            let a = rimLine[index].point
            let b = rimLine[(index + 1) % count].point
            total += hypot(b.x - a.x, b.y - a.y)
            arcLengths.append(total)
        }
        for column in 0...count {
            let sample = rimLine[column % count]
            let u = total > 0 ? arcLengths[column] / total : 0
            let outward = SCNVector3(
                Float(sample.normal.x), Float(sample.normal.y), 0
            )
            vertices.append(SCNVector3(
                Float(sample.point.x), Float(sample.point.y), halfT
            ))
            normals.append(outward)
            uvs.append(CGPoint(x: u, y: 0))
            vertices.append(SCNVector3(
                Float(sample.point.x), Float(sample.point.y), -halfT
            ))
            normals.append(outward)
            uvs.append(CGPoint(x: u, y: 1))
        }

        // Indices. Windings are counterclockwise seen from outside each
        // surface, which is what SceneKit's default back-face culling
        // expects.
        var faceIndices: [Int32] = []
        var backIndices: [Int32] = []
        var rimIndices: [Int32] = []
        for index in 0..<count {
            let next = (index + 1) % count
            faceIndices.append(contentsOf: [
                0, Int32(1 + index), Int32(1 + next),
            ])
            backIndices.append(contentsOf: [
                Int32(backCentre),
                Int32(backCentre + 1 + next),
                Int32(backCentre + 1 + index),
            ])
            let frontA = Int32(rimBase + 2 * index)
            let backA = frontA + 1
            let frontB = Int32(rimBase + 2 * (index + 1))
            let backB = frontB + 1
            rimIndices.append(contentsOf: [
                frontA, backA, backB,
                frontA, backB, frontB,
            ])
        }

        let geometry = SCNGeometry(
            sources: [
                SCNGeometrySource(vertices: vertices),
                SCNGeometrySource(normals: normals),
                SCNGeometrySource(textureCoordinates: uvs),
            ],
            elements: [
                SCNGeometryElement(indices: faceIndices, primitiveType: .triangles),
                SCNGeometryElement(indices: backIndices, primitiveType: .triangles),
                SCNGeometryElement(indices: rimIndices, primitiveType: .triangles),
            ]
        )
        return geometry
    }
}

// MARK: - Node

/// One card on the mat: the shared slab geometry under this card's own
/// materials, laid flat on the ground plane, flippable face-down, yawable
/// for sideways positions.
///
/// The node tree separates the rotations so none of them fight:
///
///     Card3DNode          position on the mat, yaw about the mat normal,
///                         then the placement's lean about the mat's
///                         lateral axis — in that order, so a rested card
///                         leans back rather than onto its long edge
///       └─ layNode        pitches the upright slab flat (face up)
///           └─ bodyNode   the geometry; rotates half a turn about the
///                         card's long axis when face-down
///
/// The node rests ON the mat rather than in it: its y is half the world
/// thickness, which is also what lets the rim catch a sliver of light at
/// grazing angles — the cue that there is an edge at all.
final class Card3DNode: SCNNode {

    /// The placement identity this node renders — the coordinator's diff
    /// key.
    let placementID: String

    /// The card whose materials are baked onto the slab. If a placement's
    /// card changes under the same id, the owner replaces the node rather
    /// than repainting it — materials are per-card, transforms are not.
    private(set) var cardID: String

    private let card: Card
    private let faceArtwork: UIImage?
    private let backTexture: UIImage?
    private let layNode = SCNNode()
    private let bodyNode = SCNNode()

    /// Builds the node with its materials baked.
    ///
    /// - Parameters:
    ///   - placement: where the card sits and how it lies.
    ///   - faceArtwork: the card's printing, already decoded at board
    ///     resolution by the caller (the view owns the database; the node
    ///     stays a pure SceneKit object).
    ///   - backTexture: the shared card-back render.
    ///   - simplified: true for the degraded material set — see
    ///     `Card3DSurface`.
    init(
        placement: Card3DPlacement,
        faceArtwork: UIImage?,
        backTexture: UIImage?,
        simplified: Bool
    ) {
        placementID = placement.id
        cardID = placement.card.id
        card = placement.card
        self.faceArtwork = faceArtwork
        self.backTexture = backTexture
        super.init()

        bodyNode.geometry = Card3DMesh.instance()
        bodyNode.castsShadow = false
        layNode.eulerAngles.x = -.pi / 2
        layNode.addChildNode(bodyNode)
        addChildNode(layNode)
        castsShadow = false

        applyMaterials(simplified: simplified)
        apply(placement)
    }

    /// Nodes are only ever built in code; there is nothing to decode.
    required init?(coder: NSCoder) { nil }

    // MARK: Placement

    /// Moves the node to a placement's transform. Cheap enough to call on
    /// every diff — four scalar assignments, no material work.
    func apply(_ placement: Card3DPlacement) {
        let worldThickness = Card3DMetrics.localThickness * placement.width
        position = SCNVector3(
            Float(placement.x),
            Float(worldThickness / 2),
            Float(-placement.forward)
        )
        // Yaw first, in the card's own plane, then lean the whole thing back
        // about the mat's lateral axis. Written as a quaternion product
        // rather than as euler angles because the order is the point:
        // `q1 * q2` rotates by q2 and then by q1, so the lean is applied in
        // the PARENT's frame and a rested card leans the same way an upright
        // one does. Euler angles compose in that order too, but only by
        // convention — this says it.
        simdOrientation = simd_mul(
            simd_quatf(angle: Float(placement.lean.radians), axis: SIMD3(1, 0, 0)),
            simd_quatf(angle: Float(placement.yaw.radians), axis: SIMD3(0, 1, 0))
        )
        let uniform = Float(placement.width)
        scale = SCNVector3(uniform, uniform, uniform)
        bodyNode.eulerAngles.y = placement.isFaceDown ? .pi : 0
    }

    // MARK: Materials

    /// Swaps between the full and degraded material sets in place, so a
    /// thermal or power change never rebuilds geometry.
    func setSimplified(_ simplified: Bool) {
        applyMaterials(simplified: simplified)
    }

    private func applyMaterials(simplified: Bool) {
        bodyNode.geometry?.materials = [
            Card3DSurface.face(
                artwork: faceArtwork, rarity: card.rarity, simplified: simplified
            ),
            Card3DSurface.back(texture: backTexture, simplified: simplified),
            Card3DSurface.edge(simplified: simplified),
        ]
    }
}

// MARK: - Previews

/// A close look at the raw slab, off the stage: face tipped toward a key
/// light so the specular response and the rounded, stock-coloured edge can
/// be judged on their own.
@MainActor
private func cardNodeInspectionScene(faceDown: Bool) -> SCNScene {
    let scene = SCNScene()
    scene.background.contents = UIColor(hex: 0x140F17)

    let card = Card(
        id: "K-039", name: "Kakashi Hatake", type: .character, color: .red,
        rarity: .superRare, setCode: "01", cost: 1, power: 7, damage: 1, health: 4
    )
    let database = CardDatabase(cards: [card])
    let placement = Card3DPlacement(
        id: "inspect", card: card, x: 0, forward: 0, isFaceDown: faceDown
    )
    let node = Card3DNode(
        placement: placement,
        faceArtwork: database.artwork(for: card, maxPixelSize: 512),
        backTexture: Card3DBackTexture.image(),
        simplified: false
    )
    // Straight-on inspection framing rather than the stage camera: undo the
    // lay-flat so the face looks at the lens, then tilt a little so the
    // highlight lands mid-face and the rim shows.
    node.position = SCNVector3(0, 0, 0)
    node.eulerAngles = SCNVector3(Float.pi / 2 - 0.35, 0.25, 0)
    scene.rootNode.addChildNode(node)

    scene.rootNode.addChildNode(Card3DLighting.rig())

    let cameraNode = SCNNode()
    cameraNode.camera = SCNCamera()
    cameraNode.camera?.fieldOfView = FieldStageMetrics.verticalFOVDegrees
    cameraNode.position = SCNVector3(0, 0.4, 2.2)
    cameraNode.eulerAngles.x = -0.18
    scene.rootNode.addChildNode(cameraNode)
    return scene
}

#Preview("Slab, face up") {
    SceneView(scene: cardNodeInspectionScene(faceDown: false))
        .ignoresSafeArea()
}

#Preview("Slab, face down") {
    SceneView(scene: cardNodeInspectionScene(faceDown: true))
        .ignoresSafeArea()
}
