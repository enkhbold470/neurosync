//
//  Scope.swift
//  neurosync
//
//  The traces. Everything drawn here is measured; nothing is generated.
//

import SwiftUI

/// Live band-passed EEG, electrode-referred µV. Autoscaled, with the scale printed —
/// an unlabelled autoscaled axis is a way of hiding that the signal is noise.
struct ScopeView: View {
    let samples: [Double]
    let live: Bool

    var body: some View {
        Canvas { ctx, size in
            let mid = size.height / 2

            // Zero line
            var axis = Path()
            axis.move(to: CGPoint(x: 0, y: mid))
            axis.addLine(to: CGPoint(x: size.width, y: mid))
            ctx.stroke(axis, with: .color(Ink.rule), lineWidth: 1)

            guard samples.count > 1 else {
                // No probe attached: a flat line, not a pretty sine wave.
                return
            }

            let peak = max(samples.map { abs($0) }.max() ?? 1, 1e-6)
            let amp = mid * 0.88 / peak
            let dx = size.width / CGFloat(samples.count - 1)

            var path = Path()
            for (i, v) in samples.enumerated() {
                let p = CGPoint(x: CGFloat(i) * dx, y: mid - CGFloat(v) * amp)
                if i == 0 { path.move(to: p) } else { path.addLine(to: p) }
            }
            ctx.stroke(
                path,
                with: .color(live ? Ink.amber : Ink.muted),
                style: StrokeStyle(lineWidth: 1.4, lineCap: .round, lineJoin: .round)
            )
        }
        .overlay(alignment: .topLeading) {
            if let peak = samples.map({ abs($0) }).max(), samples.count > 1 {
                Text(String(format: "±%.1f µV", peak))
                    .font(.data(9))
                    .foregroundStyle(Ink.muted)
                    .padding(6)
            }
        }
        .overlay(alignment: .center) {
            if samples.count <= 1 {
                Text("NO SIGNAL")
                    .font(.data(10, .semibold))
                    .tracking(2)
                    .foregroundStyle(Ink.muted)
            }
        }
    }
}

/// Power spectral density, 0–45 Hz, with the alpha band called out.
///
/// This is where the Berger test is won or lost: eyes closed, a bump appears at ~10 Hz.
struct SpectrumView: View {
    let psd: Psd?
    let alphaPeak: Double?
    let live: Bool

    private let fMax = 45.0

    /// Room under the plot for the frequency axis, so ticks never sit on the trace.
    private let axisHeight: CGFloat = 14

    var body: some View {
        Canvas { ctx, size in
            let plotH = max(size.height - axisHeight, 1)
            let x = { (f: Double) in size.width * CGFloat(f / self.fMax) }

            // Frequency axis. Drawn at true positions, not evenly spaced slots — a Hz label
            // that is 2 Hz off is a lie about where alpha is.
            for hz in [0.0, 10, 20, 30, 40] {
                let t = ctx.resolve(
                    Text("\(Int(hz))").font(.data(8)).foregroundStyle(Ink.muted)
                )
                ctx.draw(t, at: CGPoint(x: x(hz), y: size.height - axisHeight / 2),
                         anchor: hz == 0 ? .leading : .center)
            }

            guard let psd, psd.freqs.count > 2, live else { return }

            let bins = zip(psd.freqs, psd.psd).filter { $0.0 <= fMax }
            guard bins.count > 2 else { return }
            let peak = max(bins.map(\.1).max() ?? 1, 1e-12)

            // sqrt compresses the 1/f slope enough to see beta without a log axis and its
            // negative-power edge cases.
            let y = { (p: Double) in
                plotH - plotH * CGFloat((p / peak).squareRoot()) * 0.92
            }

            // Alpha band 8–13 Hz
            let aRect = CGRect(x: x(8), y: 0, width: x(13) - x(8), height: plotH)
            ctx.fill(Path(aRect), with: .color(Ink.amber.opacity(0.10)))

            // Beta band 13–30 Hz — the focus numerator
            let bRect = CGRect(x: x(13), y: 0, width: x(30) - x(13), height: plotH)
            ctx.fill(Path(bRect), with: .color(Ink.dim.opacity(0.10)))

            var path = Path()
            for (i, bin) in bins.enumerated() {
                let p = CGPoint(x: x(bin.0), y: y(bin.1))
                if i == 0 { path.move(to: p) } else { path.addLine(to: p) }
            }
            ctx.stroke(path, with: .color(Ink.amber),
                       style: StrokeStyle(lineWidth: 1.4, lineJoin: .round))

            if let alphaPeak, alphaPeak >= 6, alphaPeak <= 14 {
                var marker = Path()
                marker.move(to: CGPoint(x: x(alphaPeak), y: 0))
                marker.addLine(to: CGPoint(x: x(alphaPeak), y: plotH))
                ctx.stroke(marker, with: .color(Ink.amber.opacity(0.55)),
                           style: StrokeStyle(lineWidth: 1, dash: [2, 3]))
            }
        }
        .overlay(alignment: .topTrailing) {
            Text("α 8–13    β 13–30 Hz")
                .font(.data(8))
                .foregroundStyle(Ink.muted)
                .padding(6)
        }
    }
}

/// A bare trace. Used for the alpha (Berger) history and the session focus line.
struct Sparkline: View {
    let values: [Double]
    var color: Color = Ink.amber
    /// When set, the y-axis is pinned rather than autoscaled.
    var range: ClosedRange<Double>?
    /// Draws a horizontal reference line at this value (e.g. the flow line, or the baseline).
    var reference: Double?

    var body: some View {
        Canvas { ctx, size in
            guard values.count > 1 else { return }

            let lo = range?.lowerBound ?? (values.min() ?? 0)
            let hi = range?.upperBound ?? (values.max() ?? 1)
            let span = max(hi - lo, 1e-9)

            let y = { (v: Double) in
                size.height - size.height * CGFloat((v - lo) / span) * 0.94 - 2
            }
            let dx = size.width / CGFloat(values.count - 1)

            if let reference, reference >= lo, reference <= hi {
                var r = Path()
                r.move(to: CGPoint(x: 0, y: y(reference)))
                r.addLine(to: CGPoint(x: size.width, y: y(reference)))
                ctx.stroke(r, with: .color(Ink.rule),
                           style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
            }

            var path = Path()
            for (i, v) in values.enumerated() {
                let p = CGPoint(x: CGFloat(i) * dx, y: y(v))
                if i == 0 { path.move(to: p) } else { path.addLine(to: p) }
            }
            ctx.stroke(path, with: .color(color),
                       style: StrokeStyle(lineWidth: 1.4, lineCap: .round, lineJoin: .round))
        }
    }
}
