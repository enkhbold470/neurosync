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

    /// The day-timeline state palette. Desaturated on purpose — this is a lane on an instrument,
    /// not a productivity app's mood ring. Amber is still the only saturated colour, and it is
    /// still reserved for the one thing worth reading: engagement.
    static func state(_ s: BrainState) -> Color {
        switch s {
        case .focused: return amber
        case .daydream: return Color(red: 0.478, green: 0.494, blue: 0.667)   // cool slate-violet
        case .calm: return Color(red: 0.416, green: 0.545, blue: 0.545)       // muted teal
        case .clenched: return warn
        case .neutral: return Color(red: 0.290, green: 0.286, blue: 0.318)
        case .withheld: return Color.white.opacity(0.05)
        }
    }

    static func activity(_ k: ActivityKind) -> Color {
        switch k {
        case .coding: return Color(red: 0.945, green: 0.698, blue: 0.478).opacity(0.55)
        case .design: return Color(red: 0.588, green: 0.545, blue: 0.741).opacity(0.55)
        case .meeting: return Color(red: 0.416, green: 0.588, blue: 0.647).opacity(0.55)
        case .onCall: return Color(red: 0.859, green: 0.463, blue: 0.408).opacity(0.5)
        case .comms: return Color(red: 0.478, green: 0.522, blue: 0.478).opacity(0.5)
        case .reading: return Color(red: 0.596, green: 0.612, blue: 0.522).opacity(0.5)
        case .browsing: return Color.white.opacity(0.12)
        case .breakTime, .walk: return Color(red: 0.416, green: 0.545, blue: 0.545).opacity(0.45)
        case .unknown: return Color.white.opacity(0.08)
        }
    }

    static func tone(_ t: FindingTone) -> Color {
        switch t {
        case .bad: return warn
        case .good: return amber
        case .caution: return Color(red: 0.792, green: 0.678, blue: 0.443)
        case .neutral: return dim
        }
    }
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
