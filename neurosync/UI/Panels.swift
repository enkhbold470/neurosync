//
//  Panels.swift
//  neurosync
//

import SwiftUI

// MARK: - Gate banner

/// The gates are not error states — they are the product. A score that appears when the
/// electrode is off a head is worth nothing, so we say plainly why we are withholding it.
struct GateBanner: View {
    let gate: Gate
    var onFixRate: (() -> Void)?

    private var tint: Color {
        switch gate.kind {
        case .rate, .signal: return Ink.warn
        case .calibrating, .warmup: return Ink.amber
        }
    }

    private var symbol: String {
        switch gate.kind {
        case .rate: return "speedometer"
        case .signal: return "sensor.tag.radiowaves.forward.fill"
        case .calibrating: return "hourglass"
        case .warmup: return "waveform.badge.magnifyingglass"
        }
    }

    var body: some View {
        HStack(alignment: .top, spacing: Space.md) {
            Image(systemName: symbol)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: 20)

            VStack(alignment: .leading, spacing: 4) {
                Text(gate.title)
                    .font(.data(10, .bold))
                    .tracking(1.4)
                    .foregroundStyle(tint)
                Text(gate.detail)
                    .font(.label(12))
                    .foregroundStyle(Ink.dim)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 8)

            if gate.kind == .rate, let onFixRate {
                Button {
                    onFixRate()
                } label: {
                    Label("Set 175 SPS", systemImage: "gauge.with.dots.needle.67percent")
                }
                .buttonStyle(InstrumentButton())
            }
        }
        .padding(Space.lg)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassCard(radius: Ink.radiusCard, tint: tint)
    }
}

// MARK: - Focus

struct FocusPanel: View {
    let metrics: FocusMetrics
    let withheld: Bool
    let onRecalibrate: () -> Void

    var body: some View {
        Panel(title: "FOCUS", symbol: "gauge.with.needle", trailing: "β / (α + θ)") {
            VStack(alignment: .leading, spacing: 14) {
                ZStack {
                    Circle()
                        .stroke(Ink.rule, lineWidth: 10)
                    if !withheld {
                        Circle()
                            .trim(from: 0, to: metrics.focus / 100)
                            .stroke(Ink.amber, style: StrokeStyle(lineWidth: 10, lineCap: .round))
                            .rotationEffect(.degrees(-90))
                            .animation(.easeOut(duration: 0.35), value: metrics.focus)
                    }

                    if withheld {
                        Text("—")
                            .font(.data(38, .semibold))
                            .foregroundStyle(Ink.muted)
                    } else {
                        HStack(alignment: .firstTextBaseline, spacing: 1) {
                            Text("\(Int(metrics.focus.rounded()))")
                                .font(.data(40, .bold))
                                .foregroundStyle(Ink.text)
                                .contentTransition(.numericText())
                            Text("%")
                                .font(.data(16))
                                .foregroundStyle(Ink.muted)
                        }
                    }
                }
                .frame(width: 132, height: 132)
                .frame(maxWidth: .infinity)

                if withheld {
                    Text("No score yet — waiting for a clean signal. It'll pick up the moment the gate above clears.")
                        .font(.label(11))
                        .foregroundStyle(Ink.muted)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    HStack(spacing: 6) {
                        Circle()
                            .fill(metrics.inFlow ? Ink.amber : Ink.muted)
                            .frame(width: 5, height: 5)
                        Text(metrics.inFlow ? "IN FLOW" : "BELOW FLOW LINE")
                            .font(.data(10, .semibold))
                            .tracking(1.2)
                            .foregroundStyle(metrics.inFlow ? Ink.amber : Ink.muted)
                        Spacer()
                        Button("Recalibrate", action: onRecalibrate)
                            .buttonStyle(InstrumentButton())
                    }
                }

                Divider().overlay(Ink.rule)

                // What the number means — stays on screen, not a tooltip. Kept plain and useful
                // rather than sold as a virtue.
                VStack(alignment: .leading, spacing: 3) {
                    Text("50 is your own baseline — where you were in the first 20 seconds.")
                    Text("It only makes sense within this session, and only for you.")
                    Text("A clenched jaw reads like focus here, so a tense jaw can nudge it up.")
                }
                .font(.label(10))
                .foregroundStyle(Ink.muted)
                .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

// MARK: - Berger / alpha

/// The Berger test — Hans Berger, 1929: occipital alpha rises when the eyes close.
///
/// This is the honest proof that the electrode is on a brain and not on a table, and unlike
/// the focus score it is valid from 45 SPS up (it only needs 13 Hz of bandwidth). It is the
/// thing to put on camera.
struct BergerPanel: View {
    let metrics: FocusMetrics
    let alphaHistory: [Double]
    let live: Bool

    private var alphaPower: Double { metrics.bands[.alpha] ?? 0 }

    var body: some View {
        Panel(title: "ALPHA — BERGER TEST", symbol: "eye", trailing: "8–13 Hz") {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .top, spacing: 20) {
                    Readout(
                        label: "PEAK",
                        value: metrics.alphaPeak.map { String(format: "%.1f", $0) } ?? "—",
                        unit: "Hz",
                        emphasis: true
                    )
                    Readout(
                        label: "POWER",
                        value: live ? String(format: "%.1f", alphaPower) : "—",
                        unit: "µV²/Hz"
                    )
                }

                Sparkline(values: alphaHistory, color: Ink.amber)
                    .frame(height: 44)
                    .padding(Space.sm)
                    .background(Ink.plotBacking, in: RoundedRectangle(cornerRadius: Ink.radius, style: .continuous))

                Text("Close your eyes for 10 s. Alpha should rise and the peak should settle near 10 Hz. If it doesn't, the electrode isn't reading a brain — and nothing else on this screen means anything.")
                    .font(.label(10))
                    .foregroundStyle(Ink.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

// MARK: - Signal

struct SignalPanel: View {
    let snap: VertexSnapshot
    let onDiag: () -> Void

    var body: some View {
        Panel(title: "SIGNAL", symbol: "dot.radiowaves.up.forward", trailing: snap.metrics.signalOk ? "CONTACT" : "NO CONTACT") {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 12) {
                    Readout(label: "RMS", value: String(format: "%.2f", snap.metrics.rmsUv), unit: "µV")
                    Readout(label: "BLINKS", value: "\(snap.metrics.blinks)")
                    Readout(label: "DROPPED", value: "\(snap.droppedFrames)")
                }

                if let d = snap.diag {
                    HStack(spacing: 6) {
                        Text("DIAG")
                            .font(.data(9, .semibold))
                            .foregroundStyle(Ink.muted)
                        Text(d.error ?? d.verdict)
                            .font(.data(10, .semibold))
                            .foregroundStyle(d.verdict == "OK" ? Ink.amber : Ink.warn)
                        Spacer()
                    }
                }

                HStack {
                    Text("Contact gate: > 1.5 µV RMS")
                        .font(.label(10))
                        .foregroundStyle(Ink.muted)
                    Spacer()
                    Button("Run DIAG", action: onDiag)
                        .buttonStyle(InstrumentButton())
                }
            }
        }
    }
}

// MARK: - Chrome

/// A thin live-status strip. The wall of hardware specs moved onto the ⓘ hover — still one hover away
/// (the "single around-ear channel" disclosure is a claim we keep honest), just off the face of the app.
struct SpecStrip: View {
    let snap: VertexSnapshot

    private var connected: Bool { snap.info != nil }

    var body: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(connected ? Ink.amber : Ink.muted)
                .frame(width: 6, height: 6)
            if let info = snap.info {
                Text("\(info.fw) · \(info.sps) SPS")
                    .font(.data(9)).foregroundStyle(Ink.dim)
            } else {
                Text("no board").font(.data(9)).foregroundStyle(Ink.muted)
            }

            Spacer()

            Image(systemName: "info.circle")
                .font(.system(size: 10))
                .foregroundStyle(Ink.muted)
                .help("Single around-ear dry channel · ADS1220 24-bit · 60 Hz notch · bci-mcp open protocol")
        }
        .padding(.horizontal, Space.xl)
        .padding(.vertical, 7)
        .glassControl(radius: 0)
        .overlay(Rectangle().frame(height: 1).foregroundStyle(Ink.rule), alignment: .top)
    }
}
