//
//  Watermark.swift
//  neurosync
//
//  The wall.
//
//  Synthetic sessions are allowed to exist in this app on exactly one condition: that nobody can
//  look at one — or screenshot one, or paste one into a deck — and mistake it for a brain. This file
//  is that condition, and it is why the compromise in Synthetic/ is a compromise and not a breach.
//
//  Two pieces, and they are deliberately impossible to omit by accident:
//
//    .syntheticWatermark(_:)  a diagonal hatch across the whole surface. Applied at the ROOT of the
//                             day, so every lane, panel, number and finding inside it is under the
//                             hatch. There is no "just this panel" path that could quietly escape it.
//
//    SyntheticBadge           an inline label, for lists where the hatch would be unreadable (the
//                             day-selector tabs use it).
//
//  The loud full-width banner was removed at the owner's request (2026-07-14) — they take on verbal
//  disclosure. The data-level flags are untouched and remain the real guarantee: `synthetic: true`
//  in the JSON, the `SYNTHETIC--` filename, `Store.write` refusing an unprovenance'd synthetic
//  record, and the menu-bar/aggregate ban. The hatch and badge are what remains on screen.
//

import SwiftUI

// MARK: - Hatch

/// 45° hairlines. Cheap, unmistakable, and it survives a screenshot, a crop and a projector.
private struct Hatch: View {
    var spacing: CGFloat = 9
    var opacity: Double = 0.05

    var body: some View {
        Canvas { ctx, size in
            var path = Path()
            let reach = size.width + size.height
            var x = -size.height
            while x < reach {
                path.move(to: CGPoint(x: x, y: 0))
                path.addLine(to: CGPoint(x: x + size.height, y: size.height))
                x += spacing
            }
            ctx.stroke(path, with: .color(Ink.amber.opacity(opacity)), lineWidth: 1)
        }
        .allowsHitTesting(false)
    }
}

// MARK: - Banner

struct SyntheticBadge: View {
    var body: some View {
        Text("SYNTHETIC")
            .font(.data(8, .bold))
            .tracking(1.2)
            .foregroundStyle(Ink.bg)
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
            .background(Ink.amber)
    }
}

// MARK: - Modifier

private struct SyntheticWatermark: ViewModifier {
    let active: Bool

    func body(content: Content) -> some View {
        if active {
            content
                .overlay(Hatch())
                .overlay(Rectangle().strokeBorder(Ink.amber.opacity(0.35), lineWidth: 1))
        } else {
            content
        }
    }
}

extension View {
    /// Stamp a surface as generated. Applied at the root of anything that renders a synthetic `Day`.
    func syntheticWatermark(_ active: Bool) -> some View {
        modifier(SyntheticWatermark(active: active))
    }
}
