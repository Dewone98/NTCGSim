//
//  CardZoomOverlay.swift
//  NTCGSimulator
//
//  The full-screen card viewer. The reference lets a player pull any card up
//  large in the middle of a game — a board slot is forty points across and the
//  printed rules text on it is unreadable, so "what does that card actually
//  say" has to be answerable without leaving the mat.
//
//  It is an overlay rather than a sheet for two reasons. A sheet on a phone
//  keeps a drag indicator and a card-shaped hole above it, which wastes the
//  height the card wants; and a sheet's dismissal is a system gesture, whereas
//  the thing a player reaches for here is tapping the dimmed board they can
//  still see behind the card. So the backdrop is the dismiss control, a
//  downward swipe is the second one, and both are named for VoiceOver.
//
//  One rule the viewer cannot break: an opposing face-down Support is hidden
//  information. `BoardSideView.canInspect` is what decides whether a card ever
//  reaches the reader, and the board only ever zooms a card that got that far —
//  so a back stays a back. The viewer takes a `Card`, never a slot, precisely
//  so it cannot be handed something it should not show.
//

import SwiftUI

// MARK: - Request

/// A card the board has been asked to show full-screen.
///
/// The identity is per *request* rather than per card, so asking for the same
/// card twice replays the entrance instead of silently reusing the view that is
/// already on screen.
struct ZoomedCard: Identifiable {

    let id = UUID()

    let card: Card

    init(_ card: Card) {
        self.card = card
    }
}

// MARK: - Overlay

/// Shows one card at reading size over a dimmed board.
///
/// The artwork is decoded at full resolution here — `CardFaceSize.large` sets
/// no downsampling budget — which is correct in exactly this one place: the
/// card is the only thing on screen, and the printed rules text is pixels in
/// the illustration rather than type this view draws.
struct CardZoomOverlay: View {

    let card: Card

    /// Called once the exit animation has finished, so the board can drop the
    /// overlay rather than tearing it off mid-flight.
    let onDismiss: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Drives the entrance and the exit. False on both sides of the animation.
    @State private var isShowing = false

    /// How far the swipe-down has travelled, in points.
    @State private var drag: CGFloat = 0

    // MARK: Tuning

    /// How much of the screen's width the card may take. Short of all of it,
    /// so the dimmed board stays visible down both sides as the thing the
    /// backdrop tap will return to.
    private static let widthFraction: CGFloat = 0.84

    /// How much of the height the card itself may take, leaving the rest for
    /// the caption underneath.
    private static let heightFraction: CGFloat = 0.78

    /// A card wider than this stops reading as a card and starts reading as a
    /// poster, which matters on an iPad.
    private static let maximumWidth: CGFloat = 460

    /// Travel past which letting go dismisses.
    private static let dismissDistance: CGFloat = 120

    /// The scale the card enters from and leaves to.
    private static let entryScale: CGFloat = 0.86

    private var spring: Animation { .spring(response: 0.34, dampingFraction: 0.82) }

    private var fade: Animation { .easeOut(duration: 0.2) }

    var body: some View {
        GeometryReader { geo in
            ZStack {
                backdrop

                column(in: geo.size)
                    .offset(y: drag)
                    .scaleEffect(scale)
                    .opacity(isShowing ? 1 : 0)
                    .gesture(swipe)
            }
            .frame(width: geo.size.width, height: geo.size.height)
        }
        .ignoresSafeArea()
        .accessibilityAddTraits(.isModal)
        .accessibilityAction(.escape) { dismiss() }
        .onAppear {
            withAnimation(reduceMotion ? fade : spring) { isShowing = true }
        }
    }

    // MARK: Backdrop

    /// The dimmed board. It is the dismiss control, so it is a button rather
    /// than a decorated rectangle — VoiceOver has to be able to find it.
    private var backdrop: some View {
        Palette.backdrop
            .opacity(isShowing ? 0.92 : 0)
            .ignoresSafeArea()
            .contentShape(Rectangle())
            .onTapGesture { dismiss() }
            .accessibilityAddTraits(.isButton)
            .accessibilityLabel("Close the card viewer")
    }

    // MARK: Card

    /// The card itself, sized from whichever of the two edges runs out first,
    /// with the caption underneath sharing the same column.
    private func column(in size: CGSize) -> some View {
        let byWidth = size.width * Self.widthFraction
        let byHeight = size.height * Self.heightFraction * Metrics.cardAspect
        let width = min(Self.maximumWidth, max(120, min(byWidth, byHeight)))

        return VStack(spacing: Metrics.spacingM) {
            CardFaceView(card: card, size: .large)
                .frame(width: width, height: width / Metrics.cardAspect)

            caption(width: width)
        }
        .padding(Metrics.spacingL)
    }

    /// Name, type line and the way out. The face already prints the name, but
    /// a printed name bar is part of an illustration and can be any size, any
    /// colour and any language — the caption is the one readable copy.
    private func caption(width: CGFloat) -> some View {
        VStack(spacing: Metrics.spacingXS) {
            Text(card.name)
                .font(Typeface.display(20, weight: .bold))
                .foregroundStyle(Palette.textPrimary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)

            Text("\(card.type.title) · \(card.color.title) · \(card.id)")
                .font(Typeface.label(10))
                .tracking(1.2)
                .textCase(.uppercase)
                .foregroundStyle(Palette.accent)

            Text("Tap the background or swipe down to close")
                .font(Typeface.body(12))
                .foregroundStyle(Palette.textSecondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: width)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(card.name), \(card.type.title), \(card.color.title)")
    }

    // MARK: Gestures

    /// Swipe down to close. Upward travel is clamped away, so the card cannot
    /// be dragged off the top of the screen and left there.
    private var swipe: some Gesture {
        DragGesture(minimumDistance: 12)
            .onChanged { value in
                drag = max(0, value.translation.height)
            }
            .onEnded { value in
                guard value.translation.height > Self.dismissDistance else {
                    withAnimation(spring) { drag = 0 }
                    return
                }
                dismiss()
            }
    }

    /// The entrance and exit scale. Reduce Motion keeps the fade and drops the
    /// travel, so the card appears where it will stay.
    private var scale: CGFloat {
        guard !reduceMotion else { return 1 }
        return isShowing ? 1 : Self.entryScale
    }

    // MARK: Dismissal

    /// Plays the exit and reports back when it has finished, so the board can
    /// drop the overlay without cutting the animation off.
    private func dismiss() {
        withAnimation(reduceMotion ? fade : spring) {
            isShowing = false
            drag = 0
        } completion: {
            onDismiss()
        }
    }
}

// MARK: - Previews

#Preview("A card in hand") {
    @Previewable @State var zoomed: ZoomedCard?
    let database = CardDatabase()
    let card = database.cards.first(where: \.hasSupportLine) ?? database.cards[0]

    ZStack {
        AmbientBackground()

        VStack(spacing: Metrics.spacingL) {
            BoardCardFace(card: card, size: .small, width: 110)
            WideButton(title: "Card details", style: .primary) {
                zoomed = ZoomedCard(card)
            }
            .frame(width: 240)
        }
    }
    .overlay {
        if let request = zoomed {
            CardZoomOverlay(card: request.card) { zoomed = nil }
        }
    }
    .environment(database)
}

#Preview("A Leader") {
    let database = CardDatabase()

    ZStack {
        AmbientBackground()
        if let leader = database.leaders.first {
            CardZoomOverlay(card: leader) {}
        }
    }
    .environment(database)
}
