//
//  Shapes.swift
//  NTCGSimulator
//
//  The angular panel silhouette the simulator uses throughout: rectangles with
//  one or more corners sliced off on the diagonal.
//

import SwiftUI

/// Which corners of a `NotchedRectangle` are cut on the diagonal.
struct NotchedCorners: OptionSet {
    let rawValue: Int

    static let topLeading     = NotchedCorners(rawValue: 1 << 0)
    static let topTrailing    = NotchedCorners(rawValue: 1 << 1)
    static let bottomTrailing = NotchedCorners(rawValue: 1 << 2)
    static let bottomLeading  = NotchedCorners(rawValue: 1 << 3)

    /// The default treatment: opposite corners cut, which reads as "angled".
    static let diagonal: NotchedCorners = [.topTrailing, .bottomLeading]
    static let all: NotchedCorners = [.topLeading, .topTrailing, .bottomTrailing, .bottomLeading]
}

/// A rectangle with diagonal cuts instead of rounded corners.
struct NotchedRectangle: Shape {
    var notch: CGFloat = Metrics.notch
    var corners: NotchedCorners = .diagonal

    func path(in rect: CGRect) -> Path {
        // Never let the cut exceed half the smallest side, or the shape inverts.
        let n = min(notch, min(rect.width, rect.height) / 2)
        var path = Path()

        // Top-leading
        if corners.contains(.topLeading) {
            path.move(to: CGPoint(x: rect.minX, y: rect.minY + n))
            path.addLine(to: CGPoint(x: rect.minX + n, y: rect.minY))
        } else {
            path.move(to: CGPoint(x: rect.minX, y: rect.minY))
        }

        // Top-trailing
        if corners.contains(.topTrailing) {
            path.addLine(to: CGPoint(x: rect.maxX - n, y: rect.minY))
            path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY + n))
        } else {
            path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
        }

        // Bottom-trailing
        if corners.contains(.bottomTrailing) {
            path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY - n))
            path.addLine(to: CGPoint(x: rect.maxX - n, y: rect.maxY))
        } else {
            path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
        }

        // Bottom-leading
        if corners.contains(.bottomLeading) {
            path.addLine(to: CGPoint(x: rect.minX + n, y: rect.maxY))
            path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY - n))
        } else {
            path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
        }

        path.closeSubpath()
        return path
    }
}

/// The ambient background wash: a dark base with two soft off-screen glows,
/// echoing the sweeping curve behind the site's menu.
struct AmbientBackground: View {
    var body: some View {
        ZStack {
            Palette.backdrop
                .ignoresSafeArea()

            GeometryReader { geo in
                let w = geo.size.width
                let h = geo.size.height

                // Cool glow, upper leading.
                Circle()
                    .fill(
                        RadialGradient(
                            colors: [Palette.adaptive(dark: 0x2A3A6B, light: 0xD8E0F5).opacity(0.55),
                                     .clear],
                            center: .center,
                            startRadius: 0,
                            endRadius: w * 0.75
                        )
                    )
                    .frame(width: w * 1.5, height: w * 1.5)
                    .position(x: w * 0.05, y: h * 0.18)

                // Warm glow, lower trailing — picks up the accent.
                Circle()
                    .fill(
                        RadialGradient(
                            colors: [Palette.accent.opacity(0.20), .clear],
                            center: .center,
                            startRadius: 0,
                            endRadius: w * 0.7
                        )
                    )
                    .frame(width: w * 1.3, height: w * 1.3)
                    .position(x: w * 0.95, y: h * 0.82)
            }
            .ignoresSafeArea()
            .allowsHitTesting(false)
        }
    }
}

// MARK: - View sugar

extension View {
    /// Clips the view to the notched silhouette and strokes its edge.
    func notchedPanel(
        notch: CGFloat = Metrics.notch,
        corners: NotchedCorners = .diagonal,
        fill: Color = Palette.panel,
        stroke: Color = Palette.border,
        lineWidth: CGFloat = 1
    ) -> some View {
        let shape = NotchedRectangle(notch: notch, corners: corners)
        return self
            .background(shape.fill(fill))
            .overlay(shape.stroke(stroke, lineWidth: lineWidth))
            .clipShape(shape)
            .contentShape(shape)
    }
}
