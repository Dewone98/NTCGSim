//
//  CardFaceView.swift
//  NTCGSimulator
//
//  Draws a card: its printed artwork, and nothing else.
//
//  Every card in the set ships with its illustration inside the app bundle, and
//  the printing already carries the damage banner, the power and health cells,
//  the name bar, the trait line and the type. So a face is that picture, edge
//  to edge, with nothing drawn over it — anything this view added would print
//  every number twice, in the wrong place. The only marks it makes of its own
//  are the selection ring and the dimming, neither of which is printed on
//  anything.
//
//  There used to be a second source here: a procedural illustration for cards
//  with no file, complete with its own drawn banner and name bar. It is gone.
//  `BundledCardArtTests` fails the build if any card in the pool lacks
//  artwork, so a missing file is a bug and nothing else — and the placeholder
//  below is drawn to look like one. Inventing a picture in its place hid the
//  fault behind something a player would read as a card.
//
//  The one place a face has to be careful is a card lying face down, because
//  what it may show depends on who is looking. That rule is set out in
//  `FaceDownStyle`, and a caller has to name the case it wants.
//

import Foundation
import SwiftUI

// MARK: - Face-down treatment

/// How a card lying face down is drawn — and, more to the point, how much of
/// its printing the viewer is entitled to see.
///
/// The distinction is an information rule, not a visual preference. A player
/// may look at their own set Supports whenever they like, so drawing one as its
/// real illustration under a blur is honest: it reads as a real card turned
/// over, and its activation is the same picture coming back into focus. An
/// opponent's set Support and every card in an opponent's hand are secret, and
/// a blur is not a redaction — thirty-five printings are told apart at a glance
/// by colour and silhouette alone, so a blurred opponent card gives the game
/// away as surely as a clear one would.
///
/// The two are therefore cases a caller has to name, and the one that costs
/// nothing to write is the safe one: `.hidden` takes no argument, while showing
/// a real printing means spelling out both `blurredKnown` and how far the card
/// has been turned back up.
enum FaceDownStyle: Equatable {

    /// An opaque back. Nothing of the printing survives it — the case for an
    /// opponent's set Supports, an opponent's hand, and the decks.
    case hidden

    /// The card's own illustration, blurred. Only ever for a card this viewer
    /// already knows: their own set Supports.
    ///
    /// `reveal` runs from 0, fully turned over, to 1, the clear printing. It is
    /// interpolated rather than switched, so a Support activating on the chain
    /// comes into focus inside the caller's own `withAnimation` instead of
    /// snapping.
    case blurredKnown(reveal: Double)
}

// MARK: - Size

/// How large a card face is drawn. The size decides how much artwork is worth
/// decoding, how hard a turned card has to be blurred to read as turned, and
/// how much lettering the missing-art panel has room for.
enum CardFaceSize {
    case tiny     // board slots and deck-list rows
    case small    // hand, collection grid
    case medium   // deck builder
    case large    // full-card inspector

    /// Diagonal cut on the card's own outline.
    var notch: CGFloat {
        switch self {
        case .tiny: return 4
        case .small: return 7
        case .medium: return 9
        case .large: return 14
        }
    }

    /// How far the missing-art panel's keyline and lettering sit inside the
    /// card edge.
    var padding: CGFloat {
        switch self {
        case .tiny: return 3
        case .small: return 5
        case .medium: return 8
        case .large: return 14
        }
    }

    /// The collector number on the missing-art panel — the one thing that panel
    /// exists to say.
    var idSize: CGFloat {
        switch self {
        case .tiny: return 7
        case .small: return 10
        case .medium: return 13
        case .large: return 20
        }
    }

    /// Micro-lettering under the collector number.
    var microSize: CGFloat {
        switch self {
        case .tiny: return 5.5
        case .small: return 7
        case .medium: return 9
        case .large: return 11
        }
    }

    /// Whether the missing-art panel has room for words as well as the number.
    /// A 44pt board slot has room for one of the two, and the number is the one
    /// worth keeping.
    var showsMissingArtLabel: Bool { self != .tiny }

    /// The blur a fully turned card is drawn under.
    ///
    /// A blur radius is in points, so it has to climb with the face: four
    /// points leaves a board slot unreadable, and those same four points across
    /// an inspector card would read as a focus error rather than as a card
    /// deliberately lying face down.
    var faceDownBlur: CGFloat {
        switch self {
        case .tiny: return 4
        case .small: return 7
        case .medium: return 10
        case .large: return 18
        }
    }

    // MARK: Artwork budget

    /// The widest, in points, this size is ever drawn anywhere in the app.
    ///
    /// This is what decides how much of a printed illustration is worth
    /// decoding. The shipped art measures 744x1039 for most of the set and
    /// 875x1177 at its largest, and a board slot is around fifty points across,
    /// so decoding the printing whole costs five times the memory the slot can
    /// show — enough that a board's worth of cards no longer fits in the art
    /// cache and every one of them is decoded again on the next render pass.
    /// Each figure below is the real ceiling of its size, checked against the
    /// layout that produces it, and rounded up a little:
    ///
    ///   - `.tiny`   the largest slot `BoardLayout` can solve for, on an iPad
    ///   - `.small`  the Collection grid's widest adaptive column
    ///   - `.medium` the featured Leader on the regular-width Home screen
    ///   - `.large`  the inspector, which is given the printing itself
    ///
    /// Zero means "do not downsample". Overshooting here is harmless for decode
    /// *time* — that is set by the source bitstream, which has to be read
    /// whichever thumbnail size is asked for — but it is not harmless for
    /// memory, and memory is what evicts a screen's own working set and turns
    /// a scroll back into a decode per cell. Undershooting is worse again: it
    /// would soften the name bar and the printed numbers, which are pixels in
    /// the illustration and not text this view draws.
    ///
    /// What each figure actually resolves to, once `artPixelSize` has divided
    /// by the card ratio, multiplied by the display scale and rounded up the
    /// bucket ladder in `CardArtStore` — the number that matters is the bucket,
    /// because that is the cache key and the backing store:
    ///
    ///     size      3x phone           2x iPad            bytes decoded
    ///     .tiny     404px -> 512       269px -> 512       366x512x4  = 0.75 MB
    ///     .small    639px -> 768       426px -> 512       549x768x4  = 1.69 MB
    ///     .medium   740px -> 768       493px -> 512
    ///     .large    the printing itself                   875x1177x4 = 4.12 MB
    ///
    /// The ladder is coarse on purpose, and the coarseness is what absorbs the
    /// gap between a ceiling and the width a slot really solved for: an iPad
    /// leader is 141pt against `.tiny`'s 96, and both land on 512.
    var artDrawWidth: CGFloat {
        switch self {
        case .tiny: return 96
        case .small: return 152
        case .medium: return 176
        case .large: return 0
        }
    }
}

// MARK: - Card face

/// A single card, at a given size.
struct CardFaceView: View {
    let card: Card
    var size: CardFaceSize = .small

    /// Dims the card when it cannot legally be acted on right now.
    var isDimmed: Bool = false

    /// Draws the accent ring used for selection and legal-target highlighting.
    var highlight: Color? = nil

    /// The width this face will actually be drawn at, in points, when the
    /// caller already knows it — a board slot does, a grid cell that sizes
    /// itself does not. It only ever narrows how much artwork is decoded; a
    /// caller that leaves it out falls back to the widest `size` is used at.
    var drawWidth: CGFloat? = nil

    /// Whether the card is turned over, and what the viewer may see of it.
    ///
    /// `nil` — the default — is a card lying face up, which is every screen but
    /// the mat. Anything else is a deliberate answer to "who is looking at
    /// this?", and the answers are not interchangeable: see `FaceDownStyle`.
    var faceDown: FaceDownStyle? = nil

    @Environment(CardDatabase.self) private var database

    /// Points to device pixels. Read from the environment rather than the
    /// screen so a 2x iPad decodes two thirds of what a 3x phone does for the
    /// same card, and so previews and tests see a sane value.
    @Environment(\.displayScale) private var displayScale

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        // Asked once per face, and not at all for a hidden one: the store
        // behind it can reach the disk, and a back that shows nothing has no
        // business decoding the picture it is there to hide.
        let artwork = isHidden
            ? nil
            : database.artwork(for: card, maxPixelSize: artPixelSize)
        let showsPlaceholder = !isHidden && artwork == nil

        // A Support coming into focus is the only per-frame blur outside the
        // effect layer, and a blur is an offscreen pass on every frame of the
        // reveal. Reduce Motion asks for no transition at all; Low Power Mode
        // gets the same treatment, because a card that is simply *there* costs
        // nothing and says the same thing.
        let snapsReveal = EffectBudget.current(reduceMotion: reduceMotion).prefersStill

        ZStack {
            if isHidden {
                CardBackView(tint: highlight ?? Palette.accentMuted)
            } else if let artwork {
                // Face-up and blurred deliberately share this branch: one view
                // identity means a reveal interpolates its blur, where two
                // branches would swap one subtree for another and cut.
                TurnedArt(image: artwork, turn: turn, blur: size.faceDownBlur)
                    .transaction { transaction in
                        // Coming into focus is a change of clarity rather than
                        // of place, so the reveal lands in a single step for
                        // anyone who has asked not to be shown the journey.
                        if snapsReveal { transaction.animation = nil }
                    }
            } else {
                missingArtPanel
            }
        }
        .aspectRatio(Metrics.cardAspect, contentMode: .fit)
        .notchedPanel(
            notch: size.notch,
            corners: notchCorners,
            fill: .clear,
            stroke: edgeStroke(showsPlaceholder: showsPlaceholder),
            lineWidth: highlight == nil ? 1 : 2.5
        )
        .opacity(isDimmed ? 0.45 : 1)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityDescription(hasArtwork: artwork != nil))
    }

    // MARK: Turn

    private var isHidden: Bool { faceDown == .hidden }

    /// How far over the card is: 0 the clear printing, 1 fully turned.
    ///
    /// The complement of `reveal`, because that is what the drawing wants —
    /// blur and shade both grow as the card turns away — while a caller thinks
    /// in terms of how much of the card it has given back.
    private var turn: Double {
        guard case .blurredKnown(let reveal)? = faceDown else { return 0 }
        return 1 - min(max(reveal, 0), 1)
    }

    // MARK: Artwork budget

    /// The bucket the store should decode this face's illustration into.
    ///
    /// The printed card is taller than it is wide, so the height is the edge
    /// that has to be satisfied — asking for the width would fetch something
    /// thirty percent too small and blur the name bar.
    private var artPixelSize: Int {
        Self.artPixelSize(for: size, drawWidth: drawWidth, displayScale: displayScale)
    }

    /// Shared with the screens that warm the cache before they draw, so a
    /// warm-up lands on exactly the key the face will later ask for. A bucket
    /// missed by one rung is a bucket warmed for nothing.
    ///
    /// That agreement is the whole guarantee, and it is fragile in one specific
    /// way: a warm-up that omits `drawWidth` while the face supplies it — or
    /// the other way about — mints two keys, decodes the pool twice, and leaves
    /// the scroll hitting the decoder anyway. So the rule is that a screen
    /// warming its own artwork must call *this* function with the same three
    /// arguments its faces will. Both warm-ups in the app do, and both
    /// currently pass no `drawWidth` at all, which is why every face in the app
    /// resolves to its size's ceiling rather than to the width it was drawn at.
    static func artPixelSize(for size: CardFaceSize,
                             drawWidth: CGFloat? = nil,
                             displayScale: CGFloat) -> Int {
        // The size's own ceiling wins whenever the caller asks for more, so a
        // mis-measured slot can never widen the budget past what it was set at.
        let ceiling = size.artDrawWidth
        let width = drawWidth.map { min($0, ceiling) } ?? ceiling
        guard width > 0 else { return 0 }
        let longestEdge = Int((width / Metrics.cardAspect * displayScale).rounded(.up))
        return CardArtStore.bucket(forLongestEdge: longestEdge)
    }

    // MARK: Missing artwork

    /// What a card draws when its file is not in the bundle.
    ///
    /// Deliberately barren: a flat panel, a dashed keyline and the collector
    /// number. `BundledCardArtTests` fails the build before a card without
    /// artwork can ship, so anything that reaches this panel is a fault in the
    /// bundle and it is drawn to read as one. The collector number is here
    /// because it is the only thing anyone chasing that fault needs.
    private var missingArtPanel: some View {
        ZStack {
            Rectangle()
                .fill(Palette.panel)

            NotchedRectangle(notch: max(2, size.notch - 2), corners: notchCorners)
                .stroke(Palette.border, style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
                .padding(size.padding)

            VStack(spacing: 2) {
                Text(card.id)
                    .font(Typeface.numeric(size.idSize, weight: .bold))
                    .foregroundStyle(Palette.textSecondary)
                if size.showsMissingArtLabel {
                    Text("Art missing")
                        .font(Typeface.label(size.microSize))
                        .tracking(1)
                        .textCase(.uppercase)
                        .foregroundStyle(Palette.negative)
                }
            }
            .lineLimit(1)
            // The panel is drawn at every size down to a board slot, so the
            // lettering shrinks rather than clipping the number it exists for.
            .minimumScaleFactor(0.5)
            .padding(size.padding * 2)
        }
        .allowsHitTesting(false)
    }

    /// A keyline is printed chrome, so a card showing its own illustration gets
    /// nothing but the highlight, and a back draws its own edge already. The
    /// missing-art panel is neither, and needs an edge of its own.
    private func edgeStroke(showsPlaceholder: Bool) -> Color {
        if let highlight { return highlight }
        return showsPlaceholder ? Palette.border : .clear
    }

    // MARK: Trim

    /// A card printing a SUPPORT bar is cut on all four corners, so the
    /// silhouette alone tells it apart from a plain body at board size.
    private var notchCorners: NotchedCorners {
        card.canSetAsSupport ? .all : .diagonal
    }

    // MARK: Accessibility

    /// Spoken in full at every size: a board slot shows a picture and no text
    /// at all, and the printing carries its numbers as pixels VoiceOver cannot
    /// read.
    ///
    /// The face-down rule applies here before anything else. Naming the card
    /// behind an opaque back would hand VoiceOver precisely what that back is
    /// drawn to keep, so a hidden card says only that it is one.
    private func accessibilityDescription(hasArtwork: Bool) -> String {
        guard !isHidden else { return "Face-down card" }

        var parts: [String] = []
        if faceDown != nil { parts.append("face-down") }
        if !hasArtwork { parts.append("artwork missing") }

        parts.append(contentsOf: [card.name, card.id, card.type.title,
                                  card.color.title, card.rarity.title])
        if !card.traits.isEmpty {
            parts.append(card.traits.joined(separator: ", "))
        }
        if let chakraDescription { parts.append(chakraDescription) }
        if let power = card.power { parts.append("power \(power)") }
        if let damage = card.damage { parts.append("damage \(damage)") }
        if let health = card.health { parts.append("health \(health)") }
        if let life = card.life { parts.append("life \(life)") }
        for ability in card.activatedAbilities {
            parts.append("activated ability, \(activationTerms(ability))")
        }
        if !card.effect.isEmpty { parts.append(card.effect) }
        return parts.joined(separator: ", ")
    }

    /// Worded for what the rules actually charge: summoning and setting are
    /// free, and chakra is spent on a jutsu play or on flipping the card
    /// face-up to answer.
    private var chakraDescription: String? {
        var phrases: [String] = []
        if card.type.isBody { phrases.append("free to summon") }
        if let jutsu = card.jutsuCost {
            phrases.append("\(jutsu) chakra as a jutsu")
        }
        if card.canSetAsSupport {
            phrases.append("free to set as a support")
        }
        return phrases.isEmpty ? nil : phrases.joined(separator: ", ")
    }

    /// "Activate: Main · 1 chakra · once per turn" — when the box may be used
    /// and what using it costs, in that order, because the first thing a player
    /// asks of an ability is whether they can reach it at all.
    private func activationTerms(_ ability: CardAbility) -> String {
        var parts = [ability.trigger.title]
        parts.append(ability.cost.isFree ? "no cost" : ability.cost.summary)
        if ability.oncePerTurn { parts.append("once per turn") }
        return parts.joined(separator: " · ")
    }
}

// MARK: - Turned card

/// The printing, at a given degree of turn.
///
/// Its own view, and an `Animatable` one, for a single reason: the blur has to
/// interpolate. SwiftUI animates a view's `animatableData`, so the figure that
/// moves has to belong to the smallest view that draws it — which also means a
/// Support revealing on the chain re-runs this body once a frame rather than
/// `CardFaceView`'s, and never re-asks the art store for its picture.
private struct TurnedArt: View, Animatable {
    let image: UIImage

    /// 0 is the clear printing, 1 the card fully turned over.
    var turn: Double

    /// The radius a turn of 1 reaches, set by the size the face is drawn at.
    let blur: CGFloat

    var animatableData: Double {
        get { turn }
        set { turn = newValue }
    }

    var body: some View {
        // The blur is applied only when there is one to apply. A zero-radius
        // blur is not free — it still hands the layer a filter and an offscreen
        // pass — and almost every face in the app is face up. Branching here
        // rather than in `CardFaceView` costs the reveal nothing: the
        // interpolation lives on `animatableData`, not on which shape this body
        // takes in a given frame.
        if turn > 0 {
            printing
                // `opaque` stops the blur sampling transparency in from outside
                // the card and feathering its own edges away.
                .blur(radius: blur * turn, opaque: true)
                // A turned card is a card in shadow as well as out of focus.
                // Blur on its own reads as a rendering fault; the shade is what
                // says the state is deliberate.
                .overlay(Color.black.opacity(0.32 * turn))
        } else {
            printing
        }
    }

    private var printing: some View {
        Image(uiImage: image)
            .resizable()
            .aspectRatio(contentMode: .fill)
            .allowsHitTesting(false)
    }
}

// MARK: - Grain

/// One small tile of static noise, built once and shared by every card back.
/// Tiling a bitmap is the only way to get real grain without doing per-pixel
/// work at draw time.
///
/// The values come from a counter-based hash rather than `Double.random`, so
/// the tile is identical on every launch and the back never shimmers between
/// one run of the app and the next.
private enum ArtTexture {
    static let grain = Image(uiImage: makeGrain())

    private static func makeGrain() -> UIImage {
        let side = 48
        var state: UInt64 = 0x9E37_79B9_7F4A_7C15

        /// SplitMix64, narrowed to `0..<1`.
        func nextUnit() -> Double {
            state = state &+ 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            z ^= z >> 31
            return Double(z >> 11) * (1.0 / 9_007_199_254_740_992.0)
        }

        let format = UIGraphicsImageRendererFormat.preferred()
        format.scale = 1
        format.opaque = false

        let renderer = UIGraphicsImageRenderer(
            size: CGSize(width: side, height: side),
            format: format
        )
        return renderer.image { context in
            let cg = context.cgContext
            for y in 0..<side {
                for x in 0..<side {
                    let value = nextUnit()
                    cg.setFillColor(gray: value > 0.5 ? 1 : 0,
                                    alpha: abs(value - 0.5) * 0.34)
                    cg.fill(CGRect(x: x, y: y, width: 1, height: 1))
                }
            }
        }
    }
}

// MARK: - Back shapes

/// Straight spokes fired out of a point.
private struct RadiatingSpokes: Shape {
    var count: Int
    var rotation: Double
    /// Half-width of one spoke, in degrees.
    var spread: Double
    /// Where the spokes begin, as a fraction of their length.
    var innerRatio: Double
    var centre: UnitPoint

    func path(in rect: CGRect) -> Path {
        var path = Path()
        guard count > 0, rect.width > 0, rect.height > 0 else { return path }

        let origin = centre.point(in: rect)
        let radius = Double(hypot(rect.width, rect.height))
        let inner = radius * innerRatio
        let step = 360 / Double(count)

        for index in 0..<count {
            let middle = rotation + step * Double(index)
            let leading = (middle - spread).radians
            let trailing = (middle + spread).radians
            path.move(to: origin.offset(by: inner, at: leading))
            path.addLine(to: origin.offset(by: radius, at: leading))
            path.addLine(to: origin.offset(by: radius, at: trailing))
            path.addLine(to: origin.offset(by: inner, at: trailing))
            path.closeSubpath()
        }
        return path
    }
}

/// A regular polygon, stacked into the seal at the centre of the card back.
private struct SigilPolygon: Shape {
    var sides: Int
    var rotation: Double
    /// Circumradius as a fraction of the short side.
    var radiusRatio: Double
    var centre: UnitPoint

    func path(in rect: CGRect) -> Path {
        var path = Path()
        guard sides >= 3, rect.width > 0, rect.height > 0 else { return path }

        let origin = centre.point(in: rect)
        let radius = Double(min(rect.width, rect.height)) * radiusRatio
        let step = 360 / Double(sides)

        for index in 0...sides {
            let point = origin.offset(by: radius, at: (rotation + step * Double(index)).radians)
            if index == 0 {
                path.move(to: point)
            } else {
                path.addLine(to: point)
            }
        }
        path.closeSubpath()
        return path
    }
}

// MARK: - Geometry helpers

private extension UnitPoint {
    /// This unit point resolved inside a rectangle.
    func point(in rect: CGRect) -> CGPoint {
        CGPoint(x: rect.minX + rect.width * x, y: rect.minY + rect.height * y)
    }
}

private extension CGPoint {
    /// The point `distance` away at `angle`, measured in radians.
    func offset(by distance: Double, at angle: Double) -> CGPoint {
        CGPoint(x: Double(x) + distance * cos(angle), y: Double(y) + distance * sin(angle))
    }
}

private extension Double {
    var radians: Double { self * .pi / 180 }
}

// MARK: - Card back

/// The reverse of a card — the one thing in the app that is drawn rather than
/// printed, because the set ships no picture of a card's back.
///
/// It stands wherever a card must give nothing away at all: an opponent's hand,
/// an opponent's set Supports, the decks, and a face-down Chakra. It is also
/// what `FaceDownStyle.hidden` renders, so the two can never drift apart.
/// Everything about it flattens to a single bitmap, because a deck stack draws
/// a great many of these at once.
struct CardBackView: View {
    var tint: Color = Palette.accent

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [Palette.adaptive(dark: 0x2A2033, light: 0x3A2E44),
                         Palette.adaptive(dark: 0x160F1C, light: 0x241A2C)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )

            EllipticalGradient(
                colors: [tint.opacity(0.35), .clear],
                center: .center,
                startRadiusFraction: 0,
                endRadiusFraction: 0.75
            )

            GeometryReader { geo in
                let unit = min(geo.size.width, geo.size.height)
                let middle = CGPoint(x: geo.size.width / 2, y: geo.size.height / 2)

                ZStack {
                    RadiatingSpokes(count: 12, rotation: 15, spread: 3.4,
                                    innerRatio: 0.2, centre: .center)
                        .fill(tint.opacity(0.2))
                    Circle()
                        .stroke(tint.opacity(0.55), lineWidth: unit * 0.035)
                        .frame(width: unit * 0.54, height: unit * 0.54)
                        .position(middle)
                    SigilPolygon(sides: 4, rotation: 45, radiusRatio: 0.27, centre: .center)
                        .stroke(tint.opacity(0.35), lineWidth: unit * 0.014)
                    SigilPolygon(sides: 4, rotation: 45, radiusRatio: 0.15, centre: .center)
                        .fill(tint.opacity(0.75))
                }
                .frame(width: geo.size.width, height: geo.size.height)
            }

            LinearGradient(
                stops: [
                    .init(color: .clear, location: 0),
                    .init(color: .white.opacity(0.12), location: 0.5),
                    .init(color: .clear, location: 1)
                ],
                startPoint: .top,
                endPoint: .bottom
            )
            .rotationEffect(.degrees(-28))
            .scaleEffect(1.9)

            EllipticalGradient(
                stops: [
                    .init(color: .clear, location: 0.35),
                    .init(color: .black.opacity(0.5), location: 1)
                ],
                center: .center,
                startRadiusFraction: 0,
                endRadiusFraction: 0.82
            )

            ArtTexture.grain
                .resizable(resizingMode: .tile)
                .opacity(0.45)

            NotchedRectangle(notch: 4, corners: .diagonal)
                .stroke(tint.opacity(0.3), lineWidth: 0.75)
                .padding(4)
        }
        .drawingGroup()
        .aspectRatio(Metrics.cardAspect, contentMode: .fit)
        .notchedPanel(notch: 6, corners: .diagonal, fill: .clear,
                      stroke: tint.opacity(0.45), lineWidth: 1)
    }
}

// MARK: - Previews

/// A hand-built pool, so the previews do not depend on the player's imported
/// set — but built from real collector numbers, because a face is now its
/// bundled artwork and an invented id would draw nothing but the missing-art
/// panel. `ZZ-999` is invented deliberately, to draw exactly that.
private func previewPool() -> [Card] {
    [
        Card(id: "N-001", name: "Naruto Uzumaki", type: .leader, color: .red,
             rarity: .leader, setCode: "01",
             traits: ["Wind", "Jinchuriki", "Hidden Leaf Village", "Team 7"],
             power: 3, damage: 1, life: 15,
             effect: "[Activate: Main] Flip 1 of your CHAKRA face-down and choose 1 Character: The chosen card gets +3 power during this turn.",
             abilities: [
                CardAbility(
                    trigger: .activateMain,
                    cost: AbilityCost(chakra: 1),
                    target: .anyCharacter,
                    text: "Flip 1 of your CHAKRA face-down and choose 1 Character: The chosen card gets +3 power during this turn.",
                    effects: [.boostChosenPower(3)]
                )
             ]),
        Card(id: "K-039", name: "Kakashi Hatake", type: .character, color: .red,
             rarity: .common, setCode: "01",
             traits: ["Lightning", "Hidden Leaf Village", "Team 7"],
             cost: 1, power: 7, damage: 1, health: 4,
             effect: "[Support Activated] Negate that card. Then, reduce your life by 2.",
             supportText: "Lightning Blade — Support Activated: Negate that card.",
             canSetAsSupport: true),
        Card(id: "N-005", name: "Gamabunta", type: .exCharacter, color: .red,
             rarity: .superRare, setCode: "01",
             traits: ["Summon", "Toad"],
             cost: 3, power: 6, damage: 1, health: 5,
             effect: "Cannot be blocked by Characters with 4 or less power."),
        Card(id: "N-014", name: "Sasuke Uchiha", type: .exCharacter, color: .blue,
             rarity: .rare, setCode: "01",
             traits: ["Uchiha Clan", "Team 7"],
             cost: 3, power: 5, damage: 1, health: 5,
             effect: "Rest 1 of your opponent's Characters."),
        Card(id: "C-001", name: "CHAKRA CARD", type: .chakra, color: .blue,
             rarity: .common, setCode: "01",
             traits: ["Special"],
             effect: "Turn this face up during Refresh to pay for a card."),
        Card(id: "CP-001", name: "CHAKRA CARD", type: .chakra, color: .red,
             rarity: .common, setCode: "01",
             traits: ["Special"],
             effect: "Turn this face up during Refresh to pay for a card."),
        Card(id: "S-001", name: "SUMMON CARD", type: .summon, color: .green,
             rarity: .secretBox, setCode: "01",
             traits: ["Special"],
             cost: 3,
             effect: "Place in the Summon zone."),
        Card(id: "ZZ-999", name: "Unshipped Card", type: .character, color: .green,
             rarity: .common, setCode: "99",
             traits: ["Special"],
             cost: 2, power: 4, damage: 1, health: 4,
             effect: "Never printed — stands in for a card whose file is missing.")
    ]
}

#Preview("Printed faces at every size") {
    let pool = previewPool()

    ScrollView {
        VStack(alignment: .leading, spacing: Metrics.spacingM) {
            ForEach([("Tiny · 44pt", CardFaceSize.tiny, CGFloat(44)),
                     ("Small · 78pt", .small, 78),
                     ("Medium · 124pt", .medium, 124)], id: \.0) { row in
                Text(row.0).sectionLabel()
                ScrollView(.horizontal) {
                    HStack(alignment: .top, spacing: Metrics.spacingS) {
                        ForEach(pool) { card in
                            CardFaceView(card: card, size: row.1)
                                .frame(width: row.2)
                        }
                    }
                }
                .scrollIndicators(.hidden)
            }
        }
        .padding(Metrics.spacingM)
    }
    .background(AmbientBackground())
    .environment(CardDatabase(cards: pool))
}

#Preview("Leader and Support, large") {
    let pool = previewPool()

    HStack(spacing: Metrics.spacingM) {
        ForEach(pool.filter { $0.type == .leader || $0.canSetAsSupport }) { card in
            CardFaceView(card: card, size: .large)
                .frame(width: 200)
        }
    }
    .padding(Metrics.spacingL)
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .background(AmbientBackground())
    .environment(CardDatabase(cards: pool))
}

/// The information rule, side by side. The top row is one player's own set
/// Support coming back into focus as it activates; the bottom row is the same
/// card on the other side of the mat, which is a back and stays one.
#Preview("Face-down: mine, then theirs") {
    let pool = previewPool()
    let support = pool.first { $0.canSetAsSupport } ?? pool[0]

    VStack(alignment: .leading, spacing: Metrics.spacingM) {
        Text("Mine · set, revealing, revealed").sectionLabel()
        HStack(spacing: Metrics.spacingS) {
            ForEach([0.0, 0.5, 1.0], id: \.self) { reveal in
                CardFaceView(card: support, size: .small,
                             faceDown: .blurredKnown(reveal: reveal))
                    .frame(width: 110)
            }
        }

        Text("Theirs · never the printing").sectionLabel()
        HStack(spacing: Metrics.spacingS) {
            CardFaceView(card: support, size: .small, faceDown: .hidden)
                .frame(width: 110)
            CardFaceView(card: support, size: .small,
                         highlight: Palette.accent, faceDown: .hidden)
                .frame(width: 110)
        }
    }
    .padding(Metrics.spacingL)
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    .background(AmbientBackground())
    .environment(CardDatabase(cards: pool))
}

/// What a bundle fault looks like. Nothing here should ever reach a player —
/// `BundledCardArtTests` fails the build first — which is the whole reason it
/// is drawn as a panel and not as a picture.
#Preview("Missing artwork") {
    let pool = previewPool()
    let unshipped = pool.first { $0.id == "ZZ-999" } ?? pool[0]

    HStack(alignment: .top, spacing: Metrics.spacingM) {
        CardFaceView(card: unshipped, size: .tiny).frame(width: 44)
        CardFaceView(card: unshipped, size: .small).frame(width: 110)
        CardFaceView(card: unshipped, size: .large).frame(width: 200)
    }
    .padding(Metrics.spacingL)
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .background(AmbientBackground())
    .environment(CardDatabase(cards: pool))
}

#Preview("Card back") {
    HStack(spacing: Metrics.spacingM) {
        CardBackView().frame(width: 44)
        CardBackView(tint: Palette.textSecondary).frame(width: 78)
        CardBackView(tint: Palette.border).frame(width: 140)
    }
    .padding(Metrics.spacingL)
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .background(AmbientBackground())
}
