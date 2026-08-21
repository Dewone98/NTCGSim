//
//  Components.swift
//  NTCGSimulator
//
//  Shared building blocks: the menu tile, buttons, chips, headers and the
//  screen scaffold every feature is laid out inside.
//

import SwiftUI

// MARK: - Menu tile

/// A tile on the main menu. The primary tile is filled with the accent colour;
/// the rest are translucent panels.
struct MenuTile: View {
    let title: String
    var badge: String? = nil
    var isPrimary: Bool = false
    var isEnabled: Bool = true
    let action: () -> Void

    @State private var isPressed = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: Metrics.spacingS) {
                Text(title)
                    .font(Typeface.display(isPrimary ? 17 : 15, weight: .heavy))
                    .tracking(1.8)
                    .textCase(.uppercase)
                    .foregroundStyle(foreground)

                Spacer(minLength: 0)

                if let badge {
                    Text(badge)
                        .font(Typeface.numeric(11, weight: .bold))
                        .foregroundStyle(isPrimary ? Palette.textOnAccent.opacity(0.85)
                                                   : Palette.accent)
                }
            }
            .padding(.horizontal, Metrics.spacingM)
            .frame(height: isPrimary ? 58 : Metrics.controlHeight)
            .frame(maxWidth: .infinity, alignment: .leading)
            .notchedPanel(
                notch: Metrics.notch,
                corners: isPrimary ? [.topTrailing, .bottomLeading] : [.bottomLeading],
                fill: background,
                stroke: isPrimary ? .clear : Palette.border
            )
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        .opacity(isEnabled ? 1 : 0.45)
        .scaleEffect(isPressed ? 0.98 : 1)
        .animation(.spring(response: 0.25, dampingFraction: 0.7), value: isPressed)
        .simultaneousGesture(
            DragGesture(minimumDistance: 0)
                .onChanged { _ in isPressed = true }
                .onEnded { _ in isPressed = false }
        )
        .accessibilityLabel(badge.map { "\(title), \($0)" } ?? title)
    }

    private var background: Color {
        isPrimary ? Palette.accent : Palette.panel
    }

    private var foreground: Color {
        isPrimary ? Palette.textOnAccent : Palette.textPrimary
    }
}

// MARK: - Buttons

/// The wide, uppercase action button used for primary confirmations.
struct WideButton: View {
    let title: String
    var style: Style = .secondary
    var isEnabled: Bool = true
    let action: () -> Void

    enum Style { case primary, secondary, destructive }

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(Typeface.label(13))
                .tracking(1.8)
                .textCase(.uppercase)
                .foregroundStyle(foreground)
                .frame(maxWidth: .infinity)
                .frame(height: Metrics.controlHeight)
                .notchedPanel(
                    notch: 10,
                    corners: .diagonal,
                    fill: background,
                    stroke: style == .secondary ? Palette.border : .clear
                )
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        .opacity(isEnabled ? 1 : 0.4)
    }

    private var background: Color {
        switch style {
        case .primary:     return Palette.accent
        case .secondary:   return Palette.panel
        case .destructive: return Palette.negative
        }
    }

    private var foreground: Color {
        style == .secondary ? Palette.textPrimary : Palette.textOnAccent
    }
}

// MARK: - Chips

/// A small toggleable filter chip, used across Collection and Deck Builder.
struct FilterChip: View {
    let title: String
    let isOn: Bool
    var tint: Color = Palette.accent
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(Typeface.label(11))
                .tracking(1.2)
                .textCase(.uppercase)
                .foregroundStyle(isOn ? Palette.textOnAccent : Palette.textSecondary)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .notchedPanel(
                    notch: 6,
                    corners: .diagonal,
                    fill: isOn ? tint : Palette.panel,
                    stroke: isOn ? .clear : Palette.border
                )
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isOn ? [.isSelected] : [])
    }
}

// MARK: - Segmented option row

/// The two-or-three-way choice used all over the Settings screen.
struct OptionPicker<T: Hashable>: View {
    let options: [(value: T, title: String)]
    @Binding var selection: T

    var body: some View {
        HStack(spacing: Metrics.spacingS) {
            ForEach(options, id: \.value) { option in
                FilterChip(
                    title: option.title,
                    isOn: selection == option.value
                ) {
                    withAnimation(.easeOut(duration: 0.15)) { selection = option.value }
                }
            }
        }
    }
}

// MARK: - Screen scaffold

/// Standard screen chrome: ambient background, an uppercase title, an optional
/// subtitle, and a back affordance.
struct ScreenScaffold<Content: View>: View {
    let title: String
    var subtitle: String? = nil
    var onBack: (() -> Void)? = nil
    @ViewBuilder var content: () -> Content

    var body: some View {
        ZStack {
            AmbientBackground()

            VStack(alignment: .leading, spacing: Metrics.spacingM) {
                header
                content()
            }
            .padding(.horizontal, Metrics.spacingL)
            .padding(.top, Metrics.spacingM)
        }
        .navigationBarBackButtonHidden(onBack != nil)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: Metrics.spacingXS) {
            if let onBack {
                Button(action: onBack) {
                    HStack(spacing: 4) {
                        Image(systemName: "chevron.left")
                        Text("Back to the menu")
                            .font(Typeface.label(11))
                            .tracking(1.2)
                            .textCase(.uppercase)
                    }
                    .foregroundStyle(Palette.textSecondary)
                }
                .buttonStyle(.plain)
                .padding(.bottom, Metrics.spacingXS)
            }

            Text(title).screenTitle()

            if let subtitle {
                Text(subtitle)
                    .font(Typeface.body(14))
                    .foregroundStyle(Palette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

// MARK: - Empty state

/// The "not built yet" panel, matching how the site handles Sealed.
struct EmptyStatePanel: View {
    let headline: String
    let message: String

    var body: some View {
        VStack(spacing: Metrics.spacingS) {
            Text(headline)
                .font(Typeface.display(18))
                .tracking(1.6)
                .textCase(.uppercase)
                .foregroundStyle(Palette.accent)

            Text(message)
                .font(Typeface.body(14))
                .foregroundStyle(Palette.textSecondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity)
        .padding(Metrics.spacingL)
        .notchedPanel()
    }
}

// MARK: - Count pill

/// A small labelled counter — deck size, trash count, hand size.
struct CountPill: View {
    let label: String
    let value: String

    var body: some View {
        VStack(spacing: 1) {
            Text(label)
                .font(Typeface.label(8))
                .tracking(0.8)
                .textCase(.uppercase)
                .foregroundStyle(Palette.textSecondary)
            Text(value)
                .font(Typeface.numeric(13))
                .foregroundStyle(Palette.textPrimary)
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 3)
        .background(Palette.panel.opacity(0.9), in: RoundedRectangle(cornerRadius: 4))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(label), \(value)")
    }
}
