//
//  Visuals.swift
//  neurosync
//
//  The glanceable layer. Humans read a filled bar or an arc at a glance; the exact number and the
//  paragraph of caveats stay on screen for the reader who wants them (and for an agent parsing the
//  view). Icon + meter for people, text for machines — both, never one instead of the other.
//

import SwiftUI

/// An icon in a tinted chip. The activity/state badge that leads a row.
struct IconChip: View {
    let system: String
    var tint: Color
    var size: CGFloat = 30

    var body: some View {
        Image(systemName: system)
            .font(.system(size: size * 0.42, weight: .semibold))
            .foregroundStyle(tint)
            .frame(width: size, height: size)
            .background(tint.opacity(0.14))
            .overlay(Rectangle().strokeBorder(tint.opacity(0.5), lineWidth: 1))
    }
}

/// A labelled metric: the number, big and tinted, over a thin fill bar. `value` is 0…1 fill.
/// An optional `baseline` draws a tick (focus sits against a baseline of 50).
struct MetricCell: View {
    let label: String
    let display: String
    let value: Double
    var tint: Color = Ink.text
    var baseline: Double?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label)
                .font(.data(10, .semibold))
                .tracking(0.8)
                .foregroundStyle(Ink.muted)
            Text(display)
                .font(.data(17, .bold))
                .foregroundStyle(tint)
            GeometryReader { g in
                ZStack(alignment: .leading) {
                    Rectangle().fill(Ink.rule)
                    Rectangle().fill(tint)
                        .frame(width: g.size.width * min(1, max(0, value)))
                    if let b = baseline {
                        Rectangle().fill(Ink.dim)
                            .frame(width: 1)
                            .offset(x: g.size.width * min(1, max(0, b)))
                    }
                }
            }
            .frame(height: 4)
        }
        .frame(width: 88, alignment: .leading)
    }
}

/// A circular arc gauge with the value in the middle. For the proxy panels.
struct RingGauge: View {
    let value: Double            // 0…1
    let center: String
    var unit: String?
    var tint: Color = Ink.amber
    var size: CGFloat = 92

    var body: some View {
        ZStack {
            Circle().stroke(Ink.rule, lineWidth: 7)
            Circle()
                .trim(from: 0, to: min(1, max(0, value)))
                .stroke(tint, style: StrokeStyle(lineWidth: 7, lineCap: .round))
                .rotationEffect(.degrees(-90))
            VStack(spacing: 0) {
                Text(center)
                    .font(.data(24, .bold))
                    .foregroundStyle(tint)
                if let unit {
                    Text(unit)
                        .font(.data(10))
                        .foregroundStyle(Ink.muted)
                }
            }
        }
        .frame(width: size, height: size)
    }
}
