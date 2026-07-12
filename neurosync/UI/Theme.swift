//
//  Theme.swift
//  neurosync
//
//  "Instrument, not gadget. No RGB. No mysticism. Lab-bench honesty in consumer hardware.
//   If it wouldn't look at home next to an oscilloscope, it doesn't wear the name."
//   — NeuroFocus Manifesto IV
//
//  Hence: one accent colour, hairline rules, monospace for every number, and no gradient,
//  glow or glass anywhere. Colours carried over from the NeuroFocus design system.
//

import SwiftUI

enum Ink {
    static let bg = Color(red: 0.020, green: 0.020, blue: 0.024)        // #050506
    static let panel = Color(red: 0.039, green: 0.039, blue: 0.047)     // #0a0a0c
    static let amber = Color(red: 0.945, green: 0.698, blue: 0.478)     // #F1B27A
    static let text = Color(red: 0.980, green: 0.980, blue: 0.980)      // #fafafa
    static let dim = Color(red: 0.635, green: 0.627, blue: 0.671)       // #a2a0ab
    static let muted = Color(red: 0.435, green: 0.427, blue: 0.471)     // #6f6d78
    static let rule = Color.white.opacity(0.08)

    /// The one non-amber signal colour, used only to mark a withheld/failed gate.
    /// It is a warning, not decoration.
    static let warn = Color(red: 0.859, green: 0.463, blue: 0.408)
}

extension Font {
    /// Every number in this app is monospaced. Digits that jitter as they change read as a toy.
    static func data(_ size: CGFloat, _ weight: Font.Weight = .medium) -> Font {
        .system(size: size, weight: weight, design: .monospaced)
    }
    static func label(_ size: CGFloat, _ weight: Font.Weight = .medium) -> Font {
        .system(size: size, weight: weight)
    }
}

/// A bordered instrument panel with a monospace caption.
struct Panel<Content: View>: View {
    let title: String
    var trailing: String?
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(title)
                    .font(.data(10, .semibold))
                    .tracking(1.4)
                    .foregroundStyle(Ink.muted)
                Spacer()
                if let trailing {
                    Text(trailing)
                        .font(.data(10))
                        .tracking(0.8)
                        .foregroundStyle(Ink.muted)
                }
            }
            content
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Ink.panel)
        .overlay(Rectangle().strokeBorder(Ink.rule, lineWidth: 1))
    }
}

/// Label + value, monospaced, for the stat rows.
struct Readout: View {
    let label: String
    let value: String
    var unit: String?
    var emphasis: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label)
                .font(.data(9))
                .tracking(1.0)
                .foregroundStyle(Ink.muted)
            HStack(alignment: .firstTextBaseline, spacing: 3) {
                Text(value)
                    .font(.data(emphasis ? 20 : 15, .semibold))
                    .foregroundStyle(emphasis ? Ink.amber : Ink.text)
                if let unit {
                    Text(unit)
                        .font(.data(9))
                        .foregroundStyle(Ink.muted)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
