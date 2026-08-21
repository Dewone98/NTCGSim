//
//  Theme.swift
//  NTCGSimulator
//
//  Design tokens for the simulator. Every colour, radius and type ramp used by
//  the app is declared here so the whole UI can be re-skinned from one file.
//

import SwiftUI

// MARK: - Appearance

/// User-facing theme preference. `.system` follows the device setting.
enum AppearanceMode: String, CaseIterable, Codable, Identifiable {
    case system, light, dark

    var id: String { rawValue }

    var title: String {
        switch self {
        case .system: return "System"
        case .light:  return "Light"
        case .dark:   return "Dark"
        }
    }

    var colorScheme: ColorScheme? {
        switch self {
        case .system: return nil
        case .light:  return .light
        case .dark:   return .dark
        }
    }
}

// MARK: - Palette

/// Colour tokens. Each token resolves against the active `ColorScheme`, so the
/// same token name is correct in both light and dark.
enum Palette {

    // Backgrounds ---------------------------------------------------------

    /// The deepest layer — behind everything, including the ambient wash.
    static let backdrop = adaptive(dark: 0x140F17, light: 0xF2EEF3)

    /// Standard screen background.
    static let surface = adaptive(dark: 0x1E1722, light: 0xFFFFFF)

    /// A raised panel sitting on `surface` (menu tiles, cards, sheets).
    static let panel = adaptive(dark: 0x2C2333, light: 0xFFFFFF)

    /// A panel in its pressed / selected state.
    static let panelActive = adaptive(dark: 0x3A2F42, light: 0xF0EAF2)

    /// Hairline borders and dividers.
    static let border = adaptive(dark: 0x3D3247, light: 0xDED5E3)

    // Accent --------------------------------------------------------------

    /// The signature orange used for the primary action and brand marks.
    static let accent = adaptive(dark: 0xE8641E, light: 0xD9540F)

    /// A dimmer accent for hover states and secondary emphasis.
    static let accentMuted = adaptive(dark: 0xB44A15, light: 0xE8814A)

    // Text ----------------------------------------------------------------

    static let textPrimary   = adaptive(dark: 0xFFFFFF, light: 0x1C1520)
    static let textSecondary = adaptive(dark: 0xA396AC, light: 0x6B5F73)
    static let textOnAccent  = Color.white

    // Semantic ------------------------------------------------------------

    static let positive = adaptive(dark: 0x4CAF6D, light: 0x2E7D4F)
    static let negative = adaptive(dark: 0xE05252, light: 0xC03A3A)
    static let warning  = adaptive(dark: 0xE0A32E, light: 0xB8801A)

    // MARK: Helper

    /// Builds a colour that resolves differently per appearance.
    static func adaptive(dark: UInt32, light: UInt32) -> Color {
        Color(UIColor { traits in
            traits.userInterfaceStyle == .dark
                ? UIColor(hex: dark)
                : UIColor(hex: light)
        })
    }
}

// MARK: - Card colours

extension CardColor {
    /// The identity colour printed on the card.
    var tint: Color {
        switch self {
        case .red:   return Palette.adaptive(dark: 0xD4443C, light: 0xC0332B)
        case .blue:  return Palette.adaptive(dark: 0x3D82D6, light: 0x2A66B0)
        case .green: return Palette.adaptive(dark: 0x3EA268, light: 0x2C8050)
        }
    }

    /// A darkened variant used for card backgrounds and gradients.
    var deepTint: Color {
        switch self {
        case .red:   return Palette.adaptive(dark: 0x5C1F1C, light: 0x8E2822)
        case .blue:  return Palette.adaptive(dark: 0x1B3A5E, light: 0x1F4C82)
        case .green: return Palette.adaptive(dark: 0x1B4430, light: 0x1F5C3C)
        }
    }
}

// MARK: - Typography

/// Type ramp. The site leans on wide-tracked uppercase for headings, which
/// `Typeface.display` reproduces via `.tracking`.
enum Typeface {

    /// Large uppercase brand/heading type.
    static func display(_ size: CGFloat, weight: Font.Weight = .heavy) -> Font {
        .system(size: size, weight: weight, design: .default)
    }

    /// Section labels — small, uppercase, widely tracked.
    static func label(_ size: CGFloat = 12) -> Font {
        .system(size: size, weight: .bold, design: .default)
    }

    /// Body copy.
    static func body(_ size: CGFloat = 15) -> Font {
        .system(size: size, weight: .regular, design: .default)
    }

    /// Numeric stat readouts on cards and the board.
    static func numeric(_ size: CGFloat, weight: Font.Weight = .heavy) -> Font {
        .system(size: size, weight: weight, design: .rounded)
    }
}

// MARK: - Metrics

/// Spacing, corner and sizing constants.
enum Metrics {
    static let spacingXS: CGFloat = 4
    static let spacingS:  CGFloat = 8
    static let spacingM:  CGFloat = 14
    static let spacingL:  CGFloat = 22
    static let spacingXL: CGFloat = 34

    /// Diagonal cut on panel corners — the site's signature shape.
    static let notch: CGFloat = 14

    /// Playing cards are printed at a 5:7 ratio.
    static let cardAspect: CGFloat = 5.0 / 7.0

    /// Standard tappable height, comfortably above the 44pt minimum.
    static let controlHeight: CGFloat = 52
}

// MARK: - UIColor hex

extension UIColor {
    /// Builds a colour from a `0xRRGGBB` literal.
    convenience init(hex: UInt32) {
        self.init(
            red:   CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue:  CGFloat(hex & 0xFF) / 255,
            alpha: 1
        )
    }
}

// MARK: - Text conveniences

extension Text {
    /// Applies the uppercase, wide-tracked treatment used for section labels.
    func sectionLabel() -> some View {
        self.font(Typeface.label())
            .tracking(1.6)
            .textCase(.uppercase)
            .foregroundStyle(Palette.textSecondary)
    }

    /// Applies the heading treatment used for screen titles.
    func screenTitle() -> some View {
        self.font(Typeface.display(30))
            .tracking(2.4)
            .textCase(.uppercase)
            .foregroundStyle(Palette.textPrimary)
    }
}
