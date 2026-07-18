---
name: liquid-glass
description: Build or convert a NeuroSync UI component using Apple's Liquid Glass design system (macOS 26), routed through this repo's centralized design system. Use when adding or restyling any SwiftUI surface here.
---

# Skill: liquid-glass

Generate or convert the requested component using **Apple Liquid Glass** (macOS 26 / iOS 26),
following NeuroSync's centralized design system rather than sprinkling raw effects.

## The project rule (non-negotiable here)

**Everything routes through the one design system — never hardcode.**

- Colors, radii, spacing, type: use `Ink.*`, `Space.*`, `Font.data/label` from `UI/Theme.swift`.
  Never a raw `Color(red:…)`, hex, or literal radius. Every `Ink` token is already adaptive
  Light/Dark + Increase-Contrast.
- Glass: use the helpers in `UI/Glass.swift` — `.glassCard()`, `.glassControl()`, `.glassField()`,
  `GlassGroup { … }`, and the `InstrumentButton` style. **Do not call `.glassEffect` directly** at a
  call site; if you need a new glass recipe, add it to `Glass.swift` so the Reduce-Transparency
  fallback and tinting stay in one place.
- Panels use the `Panel(title:symbol:trailing:)` primitive (a glass card with a `SectionCaption`).

## Technical constraints

1. **Native APIs, via the helpers.** Under the hood the helpers use `glassEffect(_:in:)`,
   `GlassEffectContainer`, `Glass.regular/.tint(_:)/.interactive()`, and `.buttonStyle` — the real
   macOS 26 surface. Deployment target is 26.1, so **no `if #available` guards** are needed.
2. **Hierarchy.** Glass is a floating layer. Group nearby glass shapes in a `GlassGroup` (it wraps
   `GlassEffectContainer`) so they render together — glass can't sample glass. Don't nest a glass
   chip inside a glass bar; put a tint highlight on the bar instead.
3. **Legibility over data.** Behind a Canvas/plot, add `Ink.plotBacking` (see `.plotInset()` in
   `ContentView.swift`) so traces stay crisp over glass.
4. **Accessibility.** The helpers already fall back to a solid `Ink.panel` card under Reduce
   Transparency and mute morphs under Reduce Motion — keep new glass going through them so this holds.
   Text on glass uses the vibrant `Ink` text tokens (≥ 4.5:1 in both appearances). Text on the amber
   accent uses `Ink.onAccent`.
5. **Adaptability.** Do not force a color scheme; the tokens follow the system automatically.
6. **Iconography.** Prefer SF Symbols (`Image(systemName:)`, `Label(_:systemImage:)`) — the app's
   clinical instrument tone uses symbols, not emoji.

## Voice (when the component has copy)

Lead with help/outcome for founders protecting deep work; recovery framing, never shame or
surveillance. Keep the honest *behavior* (gates, withheld scores) but don't sell "honesty" as a pitch.

## Workflow

When asked for something non-trivial, `--plan` the files you intend to touch first, then implement.
Verify with a build + the light/dark snapshot tests in `neurosyncTests/Snapshots.swift`.

> Example: `/liquid-glass Create a settings navigation panel.`
