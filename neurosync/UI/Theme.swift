//
//  Theme.swift
//  neurosync
//
//  The design system, in one place. Every colour, radius, space and type role the app uses is a
//  token here; surfaces pull from these and from `Glass.swift`, never from hardcoded values.
//
//  Colours are ADAPTIVE — each resolves per system appearance (Light/Dark, with Increase-Contrast
//  variants). Because the whole app already flows colour through `Ink.*`, this file is the single
//  lever that turns NeuroSync from dark-only into a Liquid-Glass instrument that follows the system.
//

import SwiftUI
import AppKit

// MARK: - Adaptive colour plumbing

private func srgb(_ r: Double, _ g: Double, _ b: Double, _ a: Double = 1) -> NSColor {
    NSColor(srgbRed: r, green: g, blue: b, alpha: a)
}

extension Color {
    /// Resolves to `light`/`dark` per appearance; the optional HC values feed Increase Contrast.
    static func adaptive(light: NSColor, dark: NSColor,
                         lightHC: NSColor? = nil, darkHC: NSColor? = nil) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let name = appearance.bestMatch(from: [
                .aqua, .darkAqua,
                .accessibilityHighContrastAqua, .accessibilityHighContrastDarkAqua
            ]) ?? .aqua
            switch name {
            case .accessibilityHighContrastAqua:     return lightHC ?? light
            case .accessibilityHighContrastDarkAqua: return darkHC ?? dark
            case .darkAqua:                           return dark
            default:                                  return light
            }
        })
    }
}

// MARK: - Tokens

enum Ink {
    // Surfaces
    static let bg = Color.adaptive(light: srgb(0.949, 0.949, 0.965), dark: srgb(0.020, 0.020, 0.024))
    /// Solid card fill — also the Reduce-Transparency fallback for glass cards.
    static let panel = Color.adaptive(light: srgb(1, 1, 1), dark: srgb(0.059, 0.059, 0.075))
    /// A quiet solid inset behind Canvas plots so traces stay crisp over glass.
    static let plotBacking = Color.adaptive(light: srgb(1, 1, 1), dark: srgb(0.039, 0.039, 0.051))

    // Accent (the one saturated colour — engagement)
    static let amber = Color.adaptive(light: srgb(0.663, 0.416, 0.090), dark: srgb(0.945, 0.698, 0.478))
    /// Text/icon colour placed ON the amber accent.
    static let onAccent = Color.adaptive(light: srgb(1, 1, 1), dark: srgb(0.020, 0.020, 0.024))

    // Text
    static let text = Color.adaptive(light: srgb(0.063, 0.063, 0.078), dark: srgb(0.980, 0.980, 0.980),
                                     lightHC: srgb(0, 0, 0), darkHC: srgb(1, 1, 1))
    static let dim = Color.adaptive(light: srgb(0.333, 0.333, 0.373), dark: srgb(0.635, 0.627, 0.671),
                                    lightHC: srgb(0.20, 0.20, 0.24), darkHC: srgb(0.80, 0.80, 0.84))
    static let muted = Color.adaptive(light: srgb(0.424, 0.424, 0.463), dark: srgb(0.435, 0.427, 0.471),
                                      lightHC: srgb(0.28, 0.28, 0.32), darkHC: srgb(0.62, 0.61, 0.66))
    static let rule = Color.adaptive(light: srgb(0, 0, 0, 0.10), dark: srgb(1, 1, 1, 0.08))

    /// The one non-amber signal colour, for a withheld/failed gate. A warning, not decoration.
    static let warn = Color.adaptive(light: srgb(0.769, 0.239, 0.180), dark: srgb(0.859, 0.463, 0.408))

    // Corner radii — small elements vs. content cards.
    static let radiusCard: CGFloat = 20
    static let radius: CGFloat = 11

    // The day-timeline state palette. Desaturated on purpose; amber stays the only saturated colour.
    static func state(_ s: BrainState) -> Color {
        switch s {
        case .focused:  return amber
        case .daydream: return .adaptive(light: srgb(0.357, 0.369, 0.549), dark: srgb(0.478, 0.494, 0.667))
        case .calm:     return .adaptive(light: srgb(0.184, 0.431, 0.431), dark: srgb(0.416, 0.545, 0.545))
        case .clenched: return warn
        case .neutral:  return .adaptive(light: srgb(0.639, 0.635, 0.675), dark: srgb(0.290, 0.286, 0.318))
        case .withheld: return .adaptive(light: srgb(0, 0, 0, 0.06), dark: srgb(1, 1, 1, 0.05))
        }
    }

    static func activity(_ k: ActivityKind) -> Color {
        switch k {
        case .coding:   return .adaptive(light: srgb(0.663, 0.416, 0.090, 0.50), dark: srgb(0.945, 0.698, 0.478, 0.55))
        case .design:   return .adaptive(light: srgb(0.435, 0.376, 0.616, 0.50), dark: srgb(0.588, 0.545, 0.741, 0.55))
        case .meeting:  return .adaptive(light: srgb(0.239, 0.416, 0.478, 0.50), dark: srgb(0.416, 0.588, 0.647, 0.55))
        case .onCall:   return .adaptive(light: srgb(0.706, 0.298, 0.243, 0.50), dark: srgb(0.859, 0.463, 0.408, 0.50))
        case .comms:    return .adaptive(light: srgb(0.318, 0.361, 0.318, 0.50), dark: srgb(0.478, 0.522, 0.478, 0.50))
        case .reading:  return .adaptive(light: srgb(0.408, 0.427, 0.333, 0.50), dark: srgb(0.596, 0.612, 0.522, 0.50))
        case .browsing: return .adaptive(light: srgb(0, 0, 0, 0.14), dark: srgb(1, 1, 1, 0.12))
        case .breakTime, .walk: return .adaptive(light: srgb(0.184, 0.431, 0.431, 0.45), dark: srgb(0.416, 0.545, 0.545, 0.45))
        case .unknown:  return .adaptive(light: srgb(0, 0, 0, 0.10), dark: srgb(1, 1, 1, 0.08))
        }
    }

    static func tone(_ t: FindingTone) -> Color {
        switch t {
        case .bad:     return warn
        case .good:    return amber
        case .caution: return .adaptive(light: srgb(0.616, 0.478, 0.157), dark: srgb(0.792, 0.678, 0.443))
        case .neutral: return dim
        }
    }
}

/// The spacing scale. Use these instead of ad-hoc literals.
enum Space {
    static let xs: CGFloat = 4
    static let sm: CGFloat = 8
    static let md: CGFloat = 12
    static let lg: CGFloat = 14
    static let xl: CGFloat = 18
    static let xxl: CGFloat = 22
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

// MARK: - Primitives

/// A monospace section caption with an optional SF Symbol mark and trailing note.
struct SectionCaption: View {
    let title: String
    var symbol: String?
    var trailing: String?

    var body: some View {
        HStack(spacing: 6) {
            if let symbol {
                Image(systemName: symbol)
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(Ink.muted)
            }
            Text(title)
                .font(.data(10, .semibold))
                .tracking(1.4)
                .foregroundStyle(Ink.muted)
            Spacer(minLength: 8)
            if let trailing {
                Text(trailing)
                    .font(.data(10))
                    .tracking(0.8)
                    .foregroundStyle(Ink.muted)
            }
        }
    }
}

/// A glass instrument panel with a captioned header.
struct Panel<Content: View>: View {
    let title: String
    var symbol: String?
    var trailing: String?
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: Space.md) {
            SectionCaption(title: title, symbol: symbol, trailing: trailing)
            content
        }
        .padding(Space.xl)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassCard()
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
