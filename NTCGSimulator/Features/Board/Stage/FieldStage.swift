//
//  FieldStage.swift
//  NTCGSimulator
//
//  The field stage the board composes — a Master Duel-style 3D backdrop that
//  sits UNDER the 2D play area and never touches it.
//
//  The reference's one structural idea, kept absolute here: the 3D world and
//  the playable UI live in different spaces. Master Duel's mat and environment
//  have depth, drift and parallax, but every card and button is screen-space
//  2D composited on top, which is why the game stays readable over a moving
//  diorama. `FieldStage` is therefore a pure backdrop layer: it takes no
//  touches, publishes nothing to accessibility, moves nothing the board owns,
//  and the board slots it between `AmbientBackground` and its own content —
//
//      ZStack {
//          AmbientBackground()
//          FieldStage(isEffectPlaying: jutsuPlaying != nil)
//          // ...the existing board, unchanged, on top...
//      }
//
//  The stage is subordinate to everything else on the device. It holds still
//  — one static frame, still visible — under Reduce Motion, in Low Power
//  Mode, at `.serious` thermal state or worse, while the scene is not active,
//  and while a jutsu effect is playing (the board flags that through
//  `isEffectPlaying`; the full-screen effect deserves the whole frame budget
//  and would visually bury a 2pt drift anyway). At `.fair` thermal it ticks
//  at half rate before giving up motion entirely. And it can be switched off
//  wholesale: `FieldStageDefaults.enabledKey` is a plain `UserDefaults` bool
//  a Settings toggle can bind to with `@AppStorage`, kept outside
//  `SettingsStore`'s snapshot on purpose so the kill switch works — and can
//  be flipped — without touching the store's persisted format.
//

import SwiftUI

// MARK: - Defaults

/// Persistence for the stage's own switches. A namespace rather than values
/// on `SettingsStore` so the Settings screen, the board and a debug tool all
/// bind the same key without a schema change.
enum FieldStageDefaults {

    /// Master switch. When false the stage renders nothing at all — not a
    /// paused stage, no stage — and the board shows `AmbientBackground`
    /// exactly as it did before the stage existed.
    static let enabledKey = "ncg.stage.enabled"
}

// MARK: - Field stage

/// The backdrop layer. Fills whatever space the board gives it (the board
/// passes its full bounds), edge to edge under every safe area, because a
/// stage with a letterbox is scenery with a seam.
struct FieldStage: View {

    /// True while a full-screen effect is playing over the board. The stage
    /// holds still for it — pausing is how a backdrop yields the frame budget
    /// to the foreground.
    var isEffectPlaying: Bool = false

    @AppStorage(FieldStageDefaults.enabledKey) private var isEnabled = true

    /// Backgrounded and inactive scenes stop the clock: nothing behind the
    /// app switcher earns a tick.
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        if isEnabled {
            StageScene(isPaused: isEffectPlaying || scenePhase != .active)
                .ignoresSafeArea()
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        }
    }
}

// MARK: - Previews

#Preview("Field stage") {
    FieldStage()
        .background(Palette.backdrop)
}

#Preview("Under a board") {
    // A stand-in for the 2D play area, to check the one property the stage
    // must guarantee: card chrome stays fully legible over it.
    ZStack {
        AmbientBackground()
        FieldStage()
        VStack(spacing: Metrics.spacingS) {
            ForEach(0..<2, id: \.self) { _ in
                HStack(spacing: Metrics.spacingS) {
                    ForEach(0..<5, id: \.self) { _ in
                        RoundedRectangle(cornerRadius: Metrics.spacingXS)
                            .fill(Palette.panel)
                            .overlay(
                                RoundedRectangle(cornerRadius: Metrics.spacingXS)
                                    .strokeBorder(Palette.border)
                            )
                            .aspectRatio(Metrics.cardAspect, contentMode: .fit)
                    }
                }
            }
            Text("Support Row")
                .sectionLabel()
            Spacer()
            Text("Hand")
                .sectionLabel()
        }
        .padding(Metrics.spacingL)
    }
}

#Preview("Effect playing (held)") {
    FieldStage(isEffectPlaying: true)
        .background(Palette.backdrop)
}

#Preview("Light") {
    FieldStage()
        .background(Palette.backdrop)
        .preferredColorScheme(.light)
}
