//
//  DamageFeedback.swift
//  NTCGSimulator
//
//  What a hit looks like. Two treatments, both of which exist because a number
//  changing in a stat cell is invisible in the middle of a turn:
//
//  `DamageNumberView` is the floating "-3" thrown off the card that was hit. It
//  rises, punches past its final size and settles, then fades — the overshoot is
//  what makes it read as an impact rather than as a label sliding around. It is
//  drawn with a ring of dark copies behind the glyph rather than a shadow alone,
//  because it lands on card artwork of every brightness and a soft shadow
//  disappears over a dark illustration.
//
//  `HealthCounterView` is the card's own readout during the hit: a brief red
//  flash, and a value that counts down to its new number. Counting is the point
//  — a figure that snaps from 7 to 4 tells you the number changed, while one
//  that runs down tells you by how much, which is the question a player actually
//  has.
//
//  Both honour Reduce Motion by keeping the colour and losing the travel.
//

import SwiftUI

// MARK: - Timing

/// How long each part of the feedback runs. Kept together because the board
/// sequences around these: a floating number must outlive the flash under it.
private enum Timing {

    /// The whole life of a floating number, rise and fade included.
    static let float: Double = 0.9

    /// How long a health readout takes to run down to its new value.
    static let count: Double = 0.45

    /// The red flash: sharp in, slower out.
    static let flashIn: Double = 0.07
    static let flashOut: Double = 0.38
}

// MARK: - Floating number

/// The combat number thrown off a card. Drop it in an overlay positioned over
/// the card that was hit; it plays once and, if given `onFinished`, says when it
/// can be removed.
///
/// It plays on installation, so a second hit in the same slot needs its own
/// identity — `.id` on the hit — or the animation will not restart.
struct DamageNumberView: View {

    /// Which side of the ledger the number is on.
    enum Kind {
        case damage
        case heal

        var tint: Color {
            switch self {
            case .damage: return Palette.negative
            case .heal:   return Palette.positive
            }
        }

        /// Always signed, even for a heal — the sign is doing as much work as
        /// the colour for anyone who cannot rely on the colour.
        var sign: String {
            switch self {
            case .damage: return "-"
            case .heal:   return "+"
            }
        }
    }

    let amount: Int
    let kind: Kind

    /// Point size of the figure. The board uses the default; the inspector and
    /// the previews ask for larger.
    var size: CGFloat = 30

    /// Called once the number has finished fading, so the board can drop it.
    /// Defaulted, so a caller that owns the lifetime itself can ignore it.
    var onFinished: (() -> Void)? = nil

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        // Reduce Motion keeps the number and the colour and drops the travel
        // and the punch: it still fades in and out where the hit landed.
        let travel: CGFloat = reduceMotion ? 0 : -Metrics.spacingXL
        let overshoot: CGFloat = reduceMotion ? 1 : 1.22
        let settle: CGFloat = reduceMotion ? 1 : 0.96

        KeyframeAnimator(
            initialValue: DamageFrame(scale: reduceMotion ? 1 : 0.6),
            repeating: false
        ) { frame in
            OutlinedNumber(
                text: label,
                font: Typeface.numeric(size, weight: .black),
                fill: kind.tint
            )
            .scaleEffect(frame.scale)
            .offset(y: frame.rise)
            .opacity(frame.opacity)
        } keyframes: { _ in
            KeyframeTrack(\.rise) {
                LinearKeyframe(travel * 0.16, duration: 0.12)
                CubicKeyframe(travel * 0.68, duration: 0.38)
                CubicKeyframe(travel, duration: 0.40)
            }
            KeyframeTrack(\.scale) {
                SpringKeyframe(overshoot, duration: 0.16, spring: .snappy)
                SpringKeyframe(1, duration: 0.20, spring: .bouncy)
                LinearKeyframe(settle, duration: 0.54)
            }
            KeyframeTrack(\.opacity) {
                LinearKeyframe(1, duration: 0.10)
                LinearKeyframe(1, duration: 0.45)
                LinearKeyframe(0, duration: 0.35)
            }
        }
        .allowsHitTesting(false)
        // Transient decoration. The journal is what narrates a hit, and a view
        // that appears and vanishes mid-turn only steals VoiceOver focus.
        .accessibilityHidden(true)
        .task {
            do {
                try await Task.sleep(for: .seconds(Timing.float))
            } catch {
                return
            }
            onFinished?()
        }
    }

    private var label: String {
        "\(kind.sign)\(abs(amount))"
    }
}

/// The three things a floating number animates. Kept as one value so a single
/// `KeyframeAnimator` drives all of them off one clock.
private struct DamageFrame {
    var rise: CGFloat = 0
    var scale: CGFloat = 0.6
    var opacity: Double = 0
}

// MARK: - Health readout

/// A card's health figure, treated for the moment it changes: a red flash, and
/// a value that runs down to its new number instead of snapping to it.
///
/// It holds its own displayed value, so the board can hand it the model number
/// and forget about it — every change animates from wherever the readout had
/// got to, including a second hit landing mid-count.
struct HealthCounterView: View {
    let value: Int
    var size: CGFloat = 16

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// What is on screen right now, which trails `value` while counting.
    @State private var displayed: Double

    /// 0 at rest, 1 at the peak of the flash.
    @State private var flash: Double = 0

    init(value: Int, size: CGFloat = 16) {
        self.value = value
        self.size = size
        _displayed = State(initialValue: Double(value))
    }

    var body: some View {
        CountingNumber(
            value: displayed,
            font: Typeface.numeric(size),
            tint: Palette.textPrimary
        )
        .shadow(color: Palette.negative.opacity(flash), radius: size * 0.4)
        .background {
            Circle()
                .fill(
                    RadialGradient(
                        colors: [Palette.negative.opacity(0.7 * flash), .clear],
                        center: .center,
                        startRadius: 0,
                        endRadius: size
                    )
                )
                .frame(width: size * 2.6, height: size * 2.6)
                .allowsHitTesting(false)
        }
        .onChange(of: value) { previous, current in
            if current < previous { pulse() }
            // Counting up is a heal and gets no flash, but it still counts
            // rather than snapping, for the same reason.
            withAnimation(.easeOut(duration: reduceMotion ? 0 : Timing.count)) {
                displayed = Double(current)
            }
        }
        .accessibilityLabel("\(value) health")
    }

    /// The flash is a colour change rather than movement, so it plays the same
    /// way under Reduce Motion.
    private func pulse() {
        withAnimation(.easeOut(duration: Timing.flashIn)) { flash = 1 }
        withAnimation(.easeIn(duration: Timing.flashOut).delay(Timing.flashIn)) { flash = 0 }
    }
}

/// A figure that can be interpolated. `Animatable` is what lets SwiftUI hand it
/// every value between the old number and the new one; the view rounds each of
/// those to an integer, which is the count-down.
private struct CountingNumber: View, Animatable {
    var value: Double
    var font: Font
    var tint: Color

    var animatableData: Double {
        get { value }
        set { value = newValue }
    }

    var body: some View {
        Text("\(Int(value.rounded()))")
            // Monospaced digits, or the readout jitters as it counts through
            // narrow and wide glyphs.
            .font(font.monospacedDigit())
            .foregroundStyle(tint)
    }
}

// MARK: - Card flash

extension View {
    /// Flashes the receiver red whenever `value` drops — the whole-card half of
    /// the health treatment, for the moment a body takes a hit.
    ///
    /// The shape is passed in so the flash follows the same silhouette the card
    /// is clipped to instead of squaring off its notched corners.
    func damageFlash<S: Shape>(for value: Int, in shape: S) -> some View {
        modifier(DamageFlashModifier(value: value, shape: shape))
    }

    /// The same flash on the standard notched card silhouette.
    func damageFlash(for value: Int) -> some View {
        damageFlash(for: value, in: NotchedRectangle(notch: Metrics.notch, corners: .diagonal))
    }
}

private struct DamageFlashModifier<S: Shape>: ViewModifier {
    let value: Int
    let shape: S

    @State private var flash: Double = 0

    func body(content: Content) -> some View {
        content
            .overlay {
                ZStack {
                    shape.fill(Palette.negative.opacity(0.4 * flash))
                    shape.stroke(Palette.negative.opacity(0.9 * flash), lineWidth: 2)
                }
                .allowsHitTesting(false)
            }
            .onChange(of: value) { previous, current in
                guard current < previous else { return }
                withAnimation(.easeOut(duration: Timing.flashIn)) { flash = 1 }
                withAnimation(.easeIn(duration: Timing.flashOut).delay(Timing.flashIn)) { flash = 0 }
            }
    }
}

// MARK: - Outlined glyphs

/// A figure with a hard dark outline. Eight offset copies behind the glyph beat
/// a shadow: the outline has to survive landing on a bright illustration, and a
/// blurred shadow simply does not.
private struct OutlinedNumber: View {
    let text: String
    let font: Font
    let fill: Color
    var thickness: CGFloat = 1.5

    /// The ring of offsets, on the axes and the diagonals.
    private static let ring: [CGSize] = [
        CGSize(width: -1, height: 0),
        CGSize(width: 1, height: 0),
        CGSize(width: 0, height: -1),
        CGSize(width: 0, height: 1),
        CGSize(width: -0.7, height: -0.7),
        CGSize(width: 0.7, height: -0.7),
        CGSize(width: -0.7, height: 0.7),
        CGSize(width: 0.7, height: 0.7)
    ]

    var body: some View {
        ZStack {
            ForEach(Self.ring, id: \.self) { offset in
                Text(text)
                    .font(font)
                    .foregroundStyle(EffectPalette.outline)
                    .offset(x: offset.width * thickness, y: offset.height * thickness)
            }

            Text(text)
                .font(font)
                .foregroundStyle(fill)
        }
        .fixedSize()
        .compositingGroup()
        .shadow(color: EffectPalette.outline.opacity(0.55), radius: 3, y: 1)
    }
}

// MARK: - Previews

#Preview("Floating numbers, looping") {
    @Previewable @State var plays = 0

    let samples: [(title: String, kind: DamageNumberView.Kind, amount: Int)] = [
        ("Damage", .damage, 3),
        ("Big hit", .damage, 12),
        ("Heal", .heal, 2)
    ]

    ZStack {
        AmbientBackground()

        HStack(spacing: Metrics.spacingXL) {
            ForEach(samples.indices, id: \.self) { index in
                VStack(spacing: Metrics.spacingM) {
                    Text(samples[index].title).sectionLabel()

                    ZStack {
                        RoundedRectangle(cornerRadius: 6)
                            .fill(CardColor.green.deepTint)
                            .frame(width: 90, height: 90 / Metrics.cardAspect)

                        // Only the first number drives the loop, or every
                        // sample would restart the others as it finished.
                        DamageNumberView(
                            amount: samples[index].amount,
                            kind: samples[index].kind,
                            onFinished: index == 0 ? { plays += 1 } : nil
                        )
                        .id(plays)
                    }
                }
            }
        }
    }
}

#Preview("Health counter and card flash") {
    @Previewable @State var health = 12

    ZStack {
        AmbientBackground()

        VStack(spacing: Metrics.spacingL) {
            Text("Counts down, flashes on the way").sectionLabel()

            VStack(spacing: Metrics.spacingS) {
                HealthCounterView(value: health, size: 34)
                Text("Health").sectionLabel()
            }
            .frame(width: 140, height: 140 / Metrics.cardAspect)
            .background(CardColor.red.deepTint)
            .damageFlash(for: health)
            .clipShape(NotchedRectangle(notch: Metrics.notch, corners: .diagonal))

            HStack(spacing: Metrics.spacingS) {
                WideButton(title: "Hit for 3", style: .destructive) { health = max(0, health - 3) }
                WideButton(title: "Heal 2") { health += 2 }
                WideButton(title: "Reset") { health = 12 }
            }
        }
        .padding(Metrics.spacingL)
    }
}

#Preview("Outline over bright and dark") {
    HStack(spacing: 0) {
        ForEach([Color.white, CardColor.blue.tint, Palette.backdrop], id: \.self) { ground in
            ZStack {
                ground
                DamageNumberView(amount: 7, kind: .damage, size: 34)
            }
            .frame(width: 110, height: 150)
        }
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .background(AmbientBackground())
}
