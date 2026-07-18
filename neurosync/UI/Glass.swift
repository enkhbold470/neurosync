//
//  Glass.swift
//  neurosync
//
//  The Liquid Glass layer, in ONE place. Every glass surface in the app routes through the
//  helpers here — no raw `.glassEffect` at call sites, no hardcoded radii. The deployment target
//  is macOS 26.1, so the glass APIs are unconditionally available (no `#available` guards).
//
//  Accessibility is handled here, once: when Reduce Transparency is on, every glass surface falls
//  back to a solid `Ink.panel` fill + hairline so text and waveforms stay legible. That single
//  fallback is what lets the app wear glass on data cards without hurting readability.
//

import SwiftUI

// MARK: - Glass recipes

enum AppGlass {
    /// Standard glass for cards and controls. Regular adapts luminosity to keep content legible.
    static var regular: Glass { .regular }
    /// A tinted glass — used sparingly, to carry meaning (a warning gate, the primary action).
    static func tinted(_ color: Color) -> Glass { .regular.tint(color) }
    /// Interactive glass for controls that should respond to press.
    static var interactive: Glass { .regular.interactive() }
    static func interactiveTinted(_ color: Color) -> Glass { .regular.tint(color).interactive() }
}

// MARK: - Surface modifier (card / control / field)

/// One modifier backs every glass surface. `radius` picks the corner scale; `tint` carries meaning;
/// `interactive` is for controls. Reduce-Transparency swaps the glass for a solid card.
private struct GlassSurface: ViewModifier {
    var radius: CGFloat
    var tint: Color?
    var interactive: Bool
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        if reduceTransparency {
            let fill: Color = tint.map { $0.opacity(0.16) } ?? Ink.panel
            let stroke: Color = tint.map { $0.opacity(0.5) } ?? Ink.rule
            content
                .background(fill, in: shape)
                .overlay(shape.strokeBorder(stroke, lineWidth: 1))
        } else {
            let glass: Glass = {
                switch (tint, interactive) {
                case let (c?, true): return AppGlass.interactiveTinted(c)
                case let (c?, false): return AppGlass.tinted(c)
                case (nil, true): return AppGlass.interactive
                case (nil, false): return AppGlass.regular
                }
            }()
            content.glassEffect(glass, in: shape)
        }
    }
}

extension View {
    /// A content card (large radius). The default instrument-panel surface.
    func glassCard(radius: CGFloat = Ink.radiusCard, tint: Color? = nil) -> some View {
        modifier(GlassSurface(radius: radius, tint: tint, interactive: false))
    }
    /// A chrome control surface (small radius) — headers, pickers, footers.
    func glassControl(radius: CGFloat = Ink.radius, tint: Color? = nil) -> some View {
        modifier(GlassSurface(radius: radius, tint: tint, interactive: false))
    }
    /// An interactive field/chip that reacts to press.
    func glassField(radius: CGFloat = Ink.radius, tint: Color? = nil) -> some View {
        modifier(GlassSurface(radius: radius, tint: tint, interactive: true))
    }
}

// MARK: - Grouping

/// Wrap clusters of nearby glass shapes so they render together (glass can't sample glass) and can
/// blend/morph. Collapses to a plain container when Reduce Transparency drops the glass entirely.
struct GlassGroup<Content: View>: View {
    var spacing: CGFloat?
    @ViewBuilder var content: Content
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    init(spacing: CGFloat? = nil, @ViewBuilder content: () -> Content) {
        self.spacing = spacing
        self.content = content()
    }

    var body: some View {
        if reduceTransparency {
            content
        } else {
            GlassEffectContainer(spacing: spacing) { content }
        }
    }
}

// MARK: - Buttons

/// The app's one button language, now glass-backed. Secondary buttons read as an amber-outlined
/// glass chip; `prominent` fills with tinted glass for the single primary action on a screen
/// (the Connect CTA). Keeping the name means every existing `.buttonStyle(InstrumentButton())`
/// call site upgrades to glass with no churn.
struct InstrumentButton: ButtonStyle {
    var prominent: Bool = false
    var size: ControlScale = .regular

    enum ControlScale { case regular, large }

    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        let hPad: CGFloat = size == .large ? 22 : 14
        let vPad: CGFloat = size == .large ? 12 : 7
        let font: Font = size == .large ? .data(14, .semibold) : .data(11, .semibold)
        let shape = RoundedRectangle(cornerRadius: size == .large ? Ink.radiusCard : Ink.radius,
                                     style: .continuous)
        let pressed = configuration.isPressed

        return configuration.label
            .font(font)
            .tracking(0.6)
            .foregroundStyle(prominent ? Ink.onAccent : Ink.amber)
            .padding(.horizontal, hPad)
            .padding(.vertical, vPad)
            .modifier(GlassSurface(radius: size == .large ? Ink.radiusCard : Ink.radius,
                                   tint: prominent ? Ink.amber : nil,
                                   interactive: true))
            .overlay(prominent ? nil : shape.strokeBorder(Ink.amber.opacity(0.45), lineWidth: 1))
            .contentShape(shape)
            .opacity(isEnabled ? (pressed ? 0.82 : 1) : 0.4)
            .scaleEffect(pressed && !reduceTransparency ? 0.97 : 1)
            .animation(.easeOut(duration: 0.12), value: pressed)
    }
}
